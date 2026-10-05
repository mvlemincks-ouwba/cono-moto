import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/services/routing/elevation_client.dart';
import 'package:cono_moto/services/routing/geocoder.dart';
import 'package:cono_moto/services/routing/http_support.dart';
import 'package:cono_moto/services/routing/overpass_client.dart';
import 'package:cono_moto/services/routing/route_generator.dart';
import 'package:cono_moto/services/routing/valhalla_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

const start = GeoPoint(48.6436, 1.8296);

/// Faux serveur Valhalla : relie les points demandés en ligne droite
/// (densifiée) et annonce une longueur = géométrie × [stretch].
class FakeValhalla {
  FakeValhalla({this.stretch = 1.3, this.failWith});

  double stretch;
  int calls = 0;
  final requests = <List<GeoPoint>>[];
  http.Response? Function(int call)? failWith;

  Future<http.Response> handle(http.Request req) async {
    calls++;
    final fail = failWith?.call(calls);
    if (fail != null) return fail;
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final locs = [
      for (final l in body['locations'] as List)
        GeoPoint(((l as Map)['lat'] as num).toDouble(), (l['lon'] as num).toDouble()),
    ];
    requests.add(locs);
    final pts = <GeoPoint>[locs.first];
    for (var i = 1; i < locs.length; i++) {
      final a = locs[i - 1], b = locs[i];
      final d = Geo.distance(a, b);
      final n = math.max(1, (d / 200).ceil());
      for (var k = 1; k <= n; k++) {
        pts.add(GeoPoint(a.lat + (b.lat - a.lat) * k / n, a.lng + (b.lng - a.lng) * k / n));
      }
    }
    final km = Geo.length(pts) * stretch / 1000;
    final json = {
      'trip': {
        'legs': [
          {
            'shape': Geo.encodePolyline(pts, precision: 6),
            'maneuvers': [
              {'type': 1, 'instruction': 'Conduisez vers le nord.', 'begin_shape_index': 0, 'end_shape_index': 1},
              {
                'type': 4,
                'instruction': 'Vous êtes arrivé à votre destination.',
                'begin_shape_index': pts.length - 1,
                'end_shape_index': pts.length - 1,
              },
            ],
          },
        ],
        'summary': {'length': km, 'time': km / 60 * 3600, 'has_highway': false},
        'status': 0,
      },
    };
    return http.Response.bytes(utf8.encode(jsonEncode(json)), 200);
  }

  ValhallaClient client() => ValhallaClient(client: MockClient(handle), limiter: RateLimiter(Duration.zero));
}

void main() {
  group('Géométrie des boucles', () {
    test('rayon ≈ distance / (2π·1,3)', () {
      expect(RouteGenerator.loopRadiusM(100, RouteStyle.mixte), closeTo(100000 / (2 * math.pi * 1.3), 1));
      expect(
        RouteGenerator.loopRadiusM(100, RouteStyle.rapide),
        greaterThan(RouteGenerator.loopRadiusM(100, RouteStyle.cols)),
      );
    });

    test('points de passage sur le cercle, dans l\'ordre', () {
      const r = 15000.0;
      final center = RouteGenerator.circleCenter(start, r, 30);
      expect(Geo.distance(center, start), closeTo(r, 1));
      for (final cw in [true, false]) {
        final wps = RouteGenerator.loopWaypoints(start, r, 30, count: 4, clockwise: cw);
        expect(wps, hasLength(4));
        for (final w in wps) {
          expect(Geo.distance(center, w), closeTo(r, r * 0.01));
        }
        // Angles relatifs au départ, vus du centre : 72°, 144°, 216°, 288°.
        final startAngle = Geo.bearing(center, start);
        final rel = [for (final w in wps) ((Geo.bearing(center, w) - startAngle) * (cw ? 1 : -1)) % 360];
        expect(rel[0], closeTo(72, 1));
        expect(rel[3], closeTo(288, 1));
        for (var i = 1; i < rel.length; i++) {
          expect(rel[i], greaterThan(rel[i - 1]));
        }
      }
    });

    test('jitter reproductible', () {
      final a = RouteGenerator.loopWaypoints(start, 10000, 90, count: 3, jitter: math.Random(7));
      final b = RouteGenerator.loopWaypoints(start, 10000, 90, count: 3, jitter: math.Random(7));
      expect(a, b);
    });

    test('ajustement si écart > 25 %', () {
      expect(RouteGenerator.needsAdjustment(100000, 130000), isTrue);
      expect(RouteGenerator.needsAdjustment(100000, 70000), isTrue);
      expect(RouteGenerator.needsAdjustment(100000, 120000), isFalse);
      expect(RouteGenerator.rescaleRadius(10000, 100000, 200000), closeTo(5000, 0.01));
      expect(RouteGenerator.rescaleRadius(10000, 100000, 1000), 25000);
    });

    test('forêts choisies par secteur', () {
      const r = 12000.0;
      final geo = RouteGenerator.loopWaypoints(start, r, 0, count: 3, clockwise: true, jitter: math.Random(1));
      final nearSecond = RoutePoi(
        id: 'way/1',
        name: 'Forêt de Test',
        point: Geo.destination(geo[1], 45, 1500),
        kind: PoiKind.forest,
      );
      final farAway = RoutePoi(
        id: 'way/2',
        name: 'Bois Lointain',
        point: Geo.destination(start, 0, 90000),
        kind: PoiKind.forest,
      );
      final atStart = RoutePoi(
        id: 'way/3',
        name: 'Bois du Départ',
        point: Geo.destination(start, 90, 500),
        kind: PoiKind.forest,
      );
      final vias = RouteGenerator.planLoopVias(
        start,
        r,
        0,
        count: 3,
        clockwise: true,
        pool: [farAway, nearSecond, atStart],
        jitterSeed: 1,
      );
      expect(vias, hasLength(3));
      expect(vias[0].poi, isNull);
      expect(vias[1].poi?.name, 'Forêt de Test');
      expect(vias[2].poi, isNull);
      expect(vias[0].point, geo[0]);
    });

    test('cols : la boucle est orientée pour passer par le col', () {
      const r = 9000.0;
      final col = RoutePoi(
        id: 'n/1',
        name: 'Col du Test',
        point: Geo.destination(start, 50, 15000),
        kind: PoiKind.pass,
        elevationM: 1200,
      );
      final low = RoutePoi(
        id: 'n/2',
        name: 'Col Bas',
        point: Geo.destination(start, 60, 14000),
        kind: PoiKind.pass,
        elevationM: 400,
      );
      final far = RoutePoi(
        id: 'n/3',
        name: 'Col Lointain',
        point: Geo.destination(start, 200, 40000),
        kind: PoiKind.pass,
      );
      final other = RoutePoi(
        id: 'n/4',
        name: 'Col Ouest',
        point: Geo.destination(start, 270, 12000),
        kind: PoiKind.pass,
        elevationM: 900,
      );
      final targets = RouteGenerator.pickPassTargets(start, r, [low, far, col, other], 3);
      expect(targets.map((t) => t.name).toList(), ['Col du Test', 'Col Ouest']);
      for (final cw in [true, false]) {
        final bearing = RouteGenerator.bearingThrough(start, col.point, r, clockwise: cw);
        final center = RouteGenerator.circleCenter(start, r, bearing);
        expect(Geo.distance(center, col.point), closeTo(r, r * 0.02));
        final vias = RouteGenerator.planLoopVias(start, r, bearing, count: 3, clockwise: cw, pool: [col]);
        expect(vias.where((v) => v.poi != null).single.poi!.name, 'Col du Test');
      }
    });

    test('A→B : détours à gauche et à droite', () {
      const a = GeoPoint(48.0, 2.0), b = GeoPoint(48.0, 3.0);
      final left = RouteGenerator.sideOffset(a, b, left: true);
      final right = RouteGenerator.sideOffset(a, b, left: false);
      expect(left.lat, greaterThan(48.05)); // vers l'est, la gauche est au nord
      expect(right.lat, lessThan(47.95));
      final pool = [
        RoutePoi(id: 'n', name: 'Col Nord', point: const GeoPoint(48.1, 2.5), kind: PoiKind.pass),
        RoutePoi(id: 's', name: 'Col Sud', point: const GeoPoint(47.92, 2.4), kind: PoiKind.pass),
        RoutePoi(id: 'x', name: 'Col Hors Champ', point: const GeoPoint(49.5, 2.5), kind: PoiKind.pass),
      ];
      final (l, r) = RouteGenerator.pickAbPois(a, b, pool);
      expect(l?.name, 'Col Nord');
      expect(r?.name, 'Col Sud');
    });
  });

  group('Génération', () {
    test('3 boucles triées, sans réseau réel', () async {
      final fake = FakeValhalla(stretch: 1.3);
      final gen = RouteGenerator(valhalla: fake.client());
      final progress = <GenerationProgress>[];
      final res = await gen.generate(
        const RouteRequest(
          start: start,
          startLabel: 'Rambouillet',
          targetDistanceKm: 100,
          style: RouteStyle.sinueux,
          seed: 3,
        ),
        onProgress: progress.add,
      );
      expect(res.candidates, hasLength(3));
      expect(fake.calls, 3);
      for (final c in res.candidates) {
        expect(c.route.source, RouteSource.generated);
        expect(c.route.style, RouteStyle.sinueux);
        expect(c.route.waypoints.first, start);
        expect(c.route.waypoints.last, start);
        expect(c.route.waypoints, hasLength(6)); // départ + 4 + arrivée
        expect(c.route.distanceM, inInclusiveRange(75000, 125000));
        expect(c.route.maneuvers.last.instruction, 'Tu es arrivé à ta destination.');
        expect(c.route.name, startsWith('Virolos'));
        expect(c.route.description, startsWith('Boucle de'));
        expect(c.route.description, contains('au départ de Rambouillet'));
      }
      final scores = res.candidates.map((c) => c.score).toList();
      expect(scores, orderedEquals([...scores]..sort((a, b) => b.compareTo(a))));
      // Trois orientations différentes.
      final mids = res.candidates.map((c) => c.route.waypoints[2]).toSet();
      expect(mids, hasLength(3));
      expect(progress.last.fraction, 1);
      expect(progress.map((p) => p.message), contains('On trace un premier parcours…'));
      // Chaque requête : départ, 4 passages « through », arrivée.
      for (final r in fake.requests) {
        expect(r.first, r.last);
      }
    });

    test('boucle trop longue : rayon réduit puis nouvel essai', () async {
      final fake = FakeValhalla(stretch: 2.6); // 2× trop long
      final gen = RouteGenerator(valhalla: fake.client(), candidateCount: 1);
      final res = await gen.generate(const RouteRequest(start: start, targetDistanceKm: 60, seed: 1));
      expect(fake.calls, 2);
      final first = Geo.distance(start, fake.requests[0][1]);
      final second = Geo.distance(start, fake.requests[1][1]);
      expect(second, lessThan(first * 0.7));
      expect(res.candidates.single.route.distanceM, lessThan(90000));
    });

    test('A→B avec deux variantes', () async {
      final fake = FakeValhalla();
      final gen = RouteGenerator(valhalla: fake.client());
      final res = await gen.generate(
        const RouteRequest(
          start: start,
          destination: GeoPoint(48.4, 2.7),
          destinationLabel: 'Fontainebleau, Seine-et-Marne',
          style: RouteStyle.rapide,
        ),
      );
      expect(res.candidates, hasLength(3));
      expect(fake.requests.map((r) => r.length).toList(), [2, 3, 3]);
      expect(res.candidates.map((c) => c.route.name), everyElement(startsWith('Vers Fontainebleau')));
      expect(res.candidates.first.route.waypoints.last, const GeoPoint(48.4, 2.7));
    });

    test('forêts, altitude et noms de lieux', () async {
      final fake = FakeValhalla();
      final overpass = OverpassClient(
        client: MockClient((req) async {
          // Une grille de forêts couvrant la zone demandée ([bbox:s,w,n,e]).
          final q = req.bodyFields['data']!;
          final m = RegExp(r'\[bbox:([\d.\-]+),([\d.\-]+),([\d.\-]+),([\d.\-]+)\]').firstMatch(q)!;
          final s = double.parse(m.group(1)!), w = double.parse(m.group(2)!);
          final n = double.parse(m.group(3)!), e = double.parse(m.group(4)!);
          var i = 0;
          final elements = [
            for (var y = 0; y < 12; y++)
              for (var x = 0; x < 12; x++)
                {
                  'type': 'way',
                  'id': ++i,
                  'center': {'lat': s + (n - s) * (y + 0.5) / 12, 'lon': w + (e - w) * (x + 0.5) / 12},
                  'tags': {'landuse': 'forest', 'name': 'Forêt de F$i'},
                },
          ];
          return http.Response.bytes(utf8.encode(jsonEncode({'elements': elements})), 200);
        }),
        limiter: RateLimiter(Duration.zero),
      );
      final elevation = ElevationClient(
        client: MockClient((req) async {
          final n = req.url.queryParameters['latitude']!.split(',').length;
          return http.Response(
            jsonEncode({
              'elevation': [for (var i = 0; i < n; i++) 100.0 + (i % 10) * 20],
            }),
            200,
          );
        }),
      );
      final geocoder = Geocoder(
        client: MockClient((req) async => http.Response.bytes(utf8.encode(fixture('photon_reverse.json')), 200)),
      );
      final gen = RouteGenerator(valhalla: fake.client(), overpass: overpass, elevation: elevation, geocoder: geocoder);
      final res = await gen.generate(
        const RouteRequest(start: start, targetDistanceKm: 50, style: RouteStyle.foret, seed: 9),
      );
      expect(res.candidates, hasLength(3));
      for (final c in res.candidates) {
        expect(c.pois, isNotEmpty);
        expect(c.pois.first.kind, PoiKind.forest);
        expect(c.route.name, startsWith('Forêts : '));
        expect(c.route.description, contains('Forêt de F'));
        expect(c.profile, isNotNull);
        expect(c.route.elevationGainM, greaterThan(0));
        expect(c.badges.map((b) => b.label), anyElement(endsWith('forêts')));
      }
    });

    test('cols : chaque proposition vise un col', () async {
      final fake = FakeValhalla();
      final passes = [
        for (final (i, b) in [(1, 20.0), (2, 140.0), (3, 260.0)].indexed)
          {
            'type': 'node',
            'id': i,
            'lat': Geo.destination(start, b.$2, 12000).lat,
            'lon': Geo.destination(start, b.$2, 12000).lng,
            'tags': {'mountain_pass': 'yes', 'name': 'Col n°${b.$1}', 'ele': '${1000 + i * 100}'},
          },
      ];
      final overpass = OverpassClient(
        client: MockClient((_) async => http.Response.bytes(utf8.encode(jsonEncode({'elements': passes})), 200)),
        limiter: RateLimiter(Duration.zero),
      );
      final gen = RouteGenerator(valhalla: fake.client(), overpass: overpass);
      final res = await gen.generate(
        const RouteRequest(start: start, targetDistanceKm: 100, style: RouteStyle.cols, seed: 5),
      );
      final visited = {for (final c in res.candidates) ...c.pois.map((p) => p.name)};
      expect(visited, hasLength(3));
      for (final c in res.candidates) {
        expect(c.route.name, startsWith('Par le col'));
        expect(c.badges.map((b) => b.label), anyElement(matches(RegExp(r'^\d cols?$'))));
      }
    });

    test('cols introuvables : repli géométrique + note', () async {
      final fake = FakeValhalla();
      final overpass = OverpassClient(
        client: MockClient((_) async => http.Response('{"elements":[]}', 200)),
        limiter: RateLimiter(Duration.zero),
      );
      final gen = RouteGenerator(
        valhalla: fake.client(),
        overpass: overpass,
        geocoder: Geocoder(
          client: MockClient((_) async => http.Response.bytes(utf8.encode(fixture('photon_reverse.json')), 200)),
        ),
      );
      final res = await gen.generate(const RouteRequest(start: start, targetDistanceKm: 80, style: RouteStyle.cols));
      expect(res.candidates, hasLength(3));
      expect(res.notes.join(' '), contains('Pas de col'));
      expect(res.candidates.first.route.name, 'Grimpette vers Dourdan');
    });

    test('erreurs : pas de route / hors-ligne / annulation', () async {
      final noRoute = FakeValhalla(failWith: (_) => http.Response(fixture('valhalla_error_442.json'), 400));
      await expectLater(
        RouteGenerator(valhalla: noRoute.client()).generate(const RouteRequest(start: start)),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.noRoute)),
      );
      expect(noRoute.calls, 3);

      final offline = FakeValhalla(failWith: (_) => throw const SocketException('down'));
      await expectLater(
        RouteGenerator(valhalla: offline.client()).generate(const RouteRequest(start: start)),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.offline)),
      );
      expect(offline.calls, 1);

      final partial = FakeValhalla(failWith: (c) => c == 2 ? http.Response('{"error_code":442}', 400) : null);
      final res = await RouteGenerator(valhalla: partial.client()).generate(const RouteRequest(start: start));
      expect(res.candidates, hasLength(2));
      expect(res.notes, isNotEmpty);

      await expectLater(
        RouteGenerator(valhalla: FakeValhalla().client())
            .generate(const RouteRequest(start: start), isCancelled: () => true),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.cancelled)),
      );
    });

    test('429 : une pause puis on retente', () async {
      final fake = FakeValhalla(failWith: (c) => c == 1 ? http.Response('slow down', 429) : null);
      final gen = RouteGenerator(valhalla: fake.client(), candidateCount: 1, rateLimitPause: Duration.zero);
      final res = await gen.generate(const RouteRequest(start: start, targetDistanceKm: 40));
      expect(res.candidates, hasLength(1));
      expect(fake.calls, 2);
    });
  });
}
