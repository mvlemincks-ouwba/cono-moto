import 'dart:convert';
import 'dart:io';

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
      expect(q, startsWith('[out:json][timeout:20][bbox:'));
      // Une seule zone englobante (pas de filtre « around » par point, trop lourd).
      expect(q, isNot(contains('around')));
      final bbox = RegExp(r'\[bbox:([\d.\-]+),([\d.\-]+),([\d.\-]+),([\d.\-]+)\]').firstMatch(q)!;
      expect(double.parse(bbox.group(1)!), closeTo(48.6 - 8000 / 111320, 1e-4));
      expect(double.parse(bbox.group(3)!), closeTo(48.7 + 8000 / 111320, 1e-4));
      expect(q, contains('way["landuse"="forest"]["name"];'));
      expect(q, contains('relation["natural"="wood"]["name"];'));
      expect(q, endsWith('out tags center 200;'));
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
        usePhotonFallback: false,
      );
      final pois = await c.mountainPasses(const GeoBounds(south: 47.9, west: 6.9, north: 48.2, east: 7.2));
      expect(pois, hasLength(3));
      expect(sent.method, 'POST');
      expect(sent.url.toString(), Endpoints.overpassMirrors.first);
      expect(sent.headers['User-Agent'], AppConfig.userAgent);
      expect(sent.bodyFields['data'], contains('mountain_pass'));

      final busy = OverpassClient(
        client: MockClient((_) async => jsonResponse(fixture('overpass_timeout.json'))),
        limiter: RateLimiter(Duration.zero),
        usePhotonFallback: false,
      );
      await expectLater(
        busy.forestsAround(const [GeoPoint(48.6, 1.8)], 5000),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.server)),
      );
      final limited = OverpassClient(
        client: MockClient((_) async => http.Response('rate_limited', 429)),
        limiter: RateLimiter(Duration.zero),
        usePhotonFallback: false,
      );
      await expectLater(
        limited.forestsAround(const [GeoPoint(48.6, 1.8)], 5000),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.rateLimited)),
      );
    });
  });

  group('Overpass : serveurs de secours et repli Photon', () {
    String forestsJson(List<(String, double, double)> forests) => jsonEncode({
          'elements': [
            for (final (i, f) in forests.indexed)
              {
                'type': 'way',
                'id': i + 1,
                'center': {'lat': f.$2, 'lon': f.$3},
                'tags': {'landuse': 'forest', 'name': f.$1},
              },
          ],
        });

    test('serveur principal saturé : le miroir suivant répond', () async {
      final hosts = <String>[];
      final c = OverpassClient(
        client: MockClient((req) async {
          hosts.add(req.url.host);
          if (req.url.host == 'overpass-api.de') return http.Response('rate_limited', 429);
          return http.Response.bytes(utf8.encode(forestsJson([('Forêt de Rambouillet', 48.65, 1.82)])), 200);
        }),
        limiter: RateLimiter(Duration.zero),
      );
      final pois = await c.forestsAround(const [GeoPoint(48.6, 1.8)], 10000);
      expect(pois.map((p) => p.name), ['Forêt de Rambouillet']);
      expect(hosts, ['overpass-api.de', 'overpass.private.coffee']);
    });

    test('délai dépassé (remarque runtime error) puis 504 : troisième serveur', () async {
      final hosts = <String>[];
      final c = OverpassClient(
        client: MockClient((req) async {
          hosts.add(req.url.host);
          return switch (req.url.host) {
            'overpass-api.de' => jsonResponse(fixture('overpass_timeout.json')),
            'overpass.private.coffee' => http.Response('<html>Gateway Timeout</html>', 504),
            _ => http.Response.bytes(utf8.encode(forestsJson([('Bois de Meudon', 48.61, 1.81)])), 200),
          };
        }),
        limiter: RateLimiter(Duration.zero),
      );
      final pois = await c.forestsAround(const [GeoPoint(48.6, 1.8)], 10000);
      expect(pois.single.name, 'Bois de Meudon');
      expect(hosts, ['overpass-api.de', 'overpass.private.coffee', 'overpass.kumi.systems']);
    });

    test('les forêts hors des cercles demandés sont écartées', () async {
      final c = OverpassClient(
        client: MockClient((_) async => http.Response.bytes(
              utf8.encode(forestsJson([('Forêt proche', 48.62, 1.8), ('Forêt dans le coin de la zone', 48.69, 1.89)])),
              200,
            )),
        limiter: RateLimiter(Duration.zero),
      );
      final pois = await c.forestsAround(const [GeoPoint(48.6, 1.8)], 8000);
      expect(pois.map((p) => p.name), ['Forêt proche']);
    });

    test('tous les serveurs Overpass en échec : repli sur Photon', () async {
      final photonQueries = <Uri>[];
      final c = OverpassClient(
        client: MockClient((req) async {
          if (req.method == 'POST') return http.Response('rate_limited', 429);
          photonQueries.add(req.url);
          final isWood = req.url.queryParameters['q'] == 'bois';
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'type': 'FeatureCollection',
              'features': [
                {
                  'type': 'Feature',
                  'geometry': {
                    'type': 'Point',
                    'coordinates': isWood ? [1.83, 48.63] : [1.82, 48.64],
                  },
                  'properties': {
                    'osm_type': 'R',
                    'osm_id': isWood ? 2 : 1,
                    'osm_key': isWood ? 'natural' : 'landuse',
                    'osm_value': isWood ? 'wood' : 'forest',
                    'name': isWood ? 'Bois des Gaules' : 'Forêt domaniale de Rambouillet',
                  },
                },
                // Hors zone : Photon peut renvoyer des résultats en dehors de la bbox.
                {
                  'type': 'Feature',
                  'geometry': {'type': 'Point', 'coordinates': [5.0, 45.0]},
                  'properties': {'osm_type': 'W', 'osm_id': 9, 'name': 'Forêt lointaine'},
                },
              ],
            })),
            200,
          );
        }),
        limiter: RateLimiter(Duration.zero),
      );
      final pois = await c.forestsAround(const [GeoPoint(48.6, 1.8)], 10000);
      expect(pois.map((p) => p.name).toSet(), {'Forêt domaniale de Rambouillet', 'Bois des Gaules'});
      expect(pois.every((p) => p.kind == PoiKind.forest), isTrue);
      expect(photonQueries.map((u) => u.queryParameters['q']), ['forêt', 'bois']);
      final first = photonQueries.first;
      expect(first.queryParametersAll['osm_tag'], ['landuse:forest', 'natural:wood']);
      expect(first.queryParameters['bbox']!.split(','), hasLength(4));
    });

    test('cols : repli Photon si Overpass ne répond pas', () async {
      final c = OverpassClient(
        client: MockClient((req) async {
          if (req.method == 'POST') return http.Response('busy', 503);
          expect(req.url.queryParameters['q'], 'col');
          expect(req.url.queryParametersAll['osm_tag'], ['mountain_pass']);
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'features': [
                {
                  'geometry': {'type': 'Point', 'coordinates': [6.95, 48.05]},
                  'properties': {'osm_type': 'N', 'osm_id': 7, 'name': 'Col de la Schlucht', 'ele': '1139'},
                },
              ],
            })),
            200,
          );
        }),
        limiter: RateLimiter(Duration.zero),
      );
      final pois = await c.mountainPasses(const GeoBounds(south: 47.9, west: 6.9, north: 48.2, east: 7.2));
      expect(pois.single.name, 'Col de la Schlucht');
      expect(pois.single.elevationM, 1139);
      expect(pois.single.kind, PoiKind.pass);
    });

    test('Overpass et Photon en échec : erreur Overpass d\'origine', () async {
      final c = OverpassClient(
        client: MockClient((_) async => http.Response('rate_limited', 429)),
        limiter: RateLimiter(Duration.zero),
      );
      await expectLater(
        c.forestsAround(const [GeoPoint(48.6, 1.8)], 5000),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.rateLimited)),
      );
    });

    test('sans réseau : pas d\'essais inutiles sur les autres serveurs', () async {
      var calls = 0;
      final c = OverpassClient(
        client: MockClient((_) async {
          calls++;
          throw const SocketException('Network is unreachable');
        }),
        limiter: RateLimiter(Duration.zero),
      );
      await expectLater(
        c.forestsAround(const [GeoPoint(48.6, 1.8)], 5000),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.offline)),
      );
      expect(calls, 1);
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
