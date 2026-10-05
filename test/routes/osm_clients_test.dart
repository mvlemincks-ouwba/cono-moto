import 'dart:convert';

import 'package:cono_moto/core/config.dart';
import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/services/routing/elevation_client.dart';
import 'package:cono_moto/services/routing/geocoder.dart';
import 'package:cono_moto/services/routing/http_support.dart';
import 'package:cono_moto/services/routing/overpass_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

http.Response jsonResponse(String body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(body), status, headers: {'content-type': 'application/json'});

void main() {
  group('Overpass', () {
    test('forêts regroupées par nom', () {
      final pois = OverpassClient.parseForests(fixtureJson('overpass_forests.json'));
      expect(pois.map((p) => p.name).toSet(), {
        'Forêt domaniale de Rambouillet',
        'Bois de la Celle',
        'Forêt de Port-Royal',
        'Bois Brûlé',
      });
      final ramb = pois.firstWhere((p) => p.name.contains('Rambouillet'));
      expect(ramb.pieces, 2);
      expect(ramb.point.lat, closeTo((48.6497215 + 48.6602113) / 2, 1e-6));
      expect(ramb.isMajorForest, isTrue);
      expect(ramb.shortName, 'Rambouillet');
      final celle = pois.firstWhere((p) => p.name == 'Bois de la Celle');
      expect(celle.isMajorForest, isFalse);
      expect(celle.shortName, 'Celle');
      expect(pois.firstWhere((p) => p.name == 'Bois Brûlé').point.lng, closeTo(1.9122, 1e-6));
    });

    test('cols routiers', () {
      final pois = OverpassClient.parsePasses(fixtureJson('overpass_passes.json'));
      expect(pois.map((p) => p.name).toList(), ['Col de la Schlucht', 'Col du Calvaire', 'Col du Herrenberg']);
      expect(pois[0].elevationM, 1139);
      expect(pois[1].elevationM, 1144);
      expect(pois[2].elevationM, isNull);
      expect(pois[0].kind, PoiKind.pass);
      expect(pois[0].shortName, 'Schlucht');
    });

    test('requêtes Overpass QL', () {
      final q = OverpassClient.forestQuery(const [GeoPoint(48.6, 1.8), GeoPoint(48.7, 1.9)], 8000);
      expect(q, contains('[out:json]'));
      expect(q, contains('nwr["landuse"="forest"]["name"](around:8000,48.60000,1.80000);'));
      expect(q, contains('nwr["natural"="wood"]["name"](around:8000,48.70000,1.90000);'));
      expect(q, endsWith('out center tags;'));
      final p = OverpassClient.passQuery(const GeoBounds(south: 47.9, west: 6.9, north: 48.2, east: 7.2));
      expect(p, contains('node["mountain_pass"="yes"]["name"](47.90000,6.90000,48.20000,7.20000)->.passes;'));
      expect(
        p,
        contains(
          'way(bn.passes)["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential)(_link)?\$"]->.roads;',
        ),
      );
      expect(p, contains('node.passes(w.roads);'));
    });

    test('client : POST data= et erreurs', () async {
      late http.Request sent;
      final c = OverpassClient(
        client: MockClient((req) async {
          sent = req;
          return jsonResponse(fixture('overpass_passes.json'));
        }),
        limiter: RateLimiter(Duration.zero),
      );
      final pois = await c.mountainPasses(const GeoBounds(south: 47.9, west: 6.9, north: 48.2, east: 7.2));
      expect(pois, hasLength(3));
      expect(sent.method, 'POST');
      expect(sent.url.toString(), Endpoints.overpass);
      expect(sent.headers['User-Agent'], AppConfig.userAgent);
      expect(sent.bodyFields['data'], contains('mountain_pass'));

      final busy = OverpassClient(
        client: MockClient((_) async => jsonResponse(fixture('overpass_timeout.json'))),
        limiter: RateLimiter(Duration.zero),
      );
      await expectLater(
        busy.forestsAround(const [GeoPoint(48.6, 1.8)], 5000),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.server)),
      );
      final limited = OverpassClient(
        client: MockClient((_) async => http.Response('rate_limited', 429)),
        limiter: RateLimiter(Duration.zero),
      );
      await expectLater(
        limited.forestsAround(const [GeoPoint(48.6, 1.8)], 5000),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.rateLimited)),
      );
    });
  });

  group('Photon', () {
    test('analyse des résultats', () {
      final places = Geocoder.parse(fixtureJson('photon_search.json'));
      expect(places, hasLength(3));
      expect(places[0].name, 'Rambouillet');
      expect(places[0].city, 'Rambouillet');
      expect(places[0].detail, 'Yvelines');
      expect(places[0].point.lat, closeTo(48.6439, 1e-6));
      expect(places[0].point.lng, closeTo(1.8352, 1e-6));
      expect(places[1].name, '12 Rue Chasles');
      expect(places[1].label, '12 Rue Chasles, 78120 Rambouillet, Yvelines');
      expect(places[2].label, 'Bruxelles, Belgique');
    });

    test('URL de recherche et de recherche inverse', () async {
      late Uri url;
      final g = Geocoder(
        client: MockClient((req) async {
          url = req.url;
          expect(req.headers['User-Agent'], AppConfig.userAgent);
          return jsonResponse(fixture(req.url.path.contains('reverse') ? 'photon_reverse.json' : 'photon_search.json'));
        }),
      );
      final res = await g.search('rambouillet', near: const GeoPoint(48.6, 1.8));
      expect(res, isNotEmpty);
      expect(url.host, 'photon.komoot.io');
      expect(url.path, '/api/');
      expect(url.queryParameters['q'], 'rambouillet');
      expect(url.queryParameters['lang'], 'fr');
      expect(url.queryParameters['lat'], '48.6000');
      expect(await g.search('ra'), isEmpty);

      final place = await g.reverse(const GeoPoint(48.5291, 1.9516));
      expect(url.path, '/reverse');
      expect(place?.city, 'Dourdan');
      expect(place?.name, 'Route de Rochefort');
    });
  });

  group('Altitude Open-Meteo', () {
    test('analyse', () {
      expect(ElevationClient.parse(fixtureJson('open_meteo_elevation.json')), [162.0, 171.0, 185.0, 180.0, 203.0]);
      expect(ElevationClient.parse({'error': true}), isEmpty);
    });

    test('requêtes par paquets de 100 points', () async {
      final sizes = <int>[];
      final c = ElevationClient(
        client: MockClient((req) async {
          final lats = req.url.queryParameters['latitude']!.split(',');
          final lngs = req.url.queryParameters['longitude']!.split(',');
          expect(lats.length, lngs.length);
          sizes.add(lats.length);
          return jsonResponse(
            jsonEncode({
              'elevation': [for (var i = 0; i < lats.length; i++) 100.0 + i],
            }),
          );
        }),
      );
      final pts = [for (var i = 0; i < 250; i++) GeoPoint(48 + i * 0.001, 2)];
      final e = await c.elevations(pts);
      expect(sizes, [100, 100, 50]);
      expect(e, hasLength(250));
    });

    test('profil échantillonné ~1 km', () async {
      final c = ElevationClient(
        client: MockClient((req) async {
          final n = req.url.queryParameters['latitude']!.split(',').length;
          // Monte de 10 m par point.
          return jsonResponse(
            jsonEncode({
              'elevation': [for (var i = 0; i < n; i++) 100.0 + i * 10],
            }),
          );
        }),
      );
      // Ligne de ~11,1 km plein nord.
      final line = [const GeoPoint(48.0, 2.0), const GeoPoint(48.1, 2.0)];
      final p = await c.profile(line);
      expect(p.distancesM.length, 12);
      expect(p.distancesM.last, closeTo(Geo.length(line), 0.1));
      expect(p.stats.gainM, closeTo(110, 0.01));
      expect(p.stats.maxM, 210);
    });

    test('réponse incomplète', () async {
      final c = ElevationClient(client: MockClient((_) async => jsonResponse('{"elevation":[1.0]}')));
      await expectLater(c.elevations(const [GeoPoint(48, 2), GeoPoint(48.1, 2)]), throwsA(isA<RoutingException>()));
    });
  });
}
