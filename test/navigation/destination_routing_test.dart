import 'dart:convert';

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/features/navigation/destination_routing.dart';
import 'package:cono_moto/features/navigation/navigation_providers.dart';
import 'package:cono_moto/features/routes/routes_providers.dart';
import 'package:cono_moto/services/routing/geocoder.dart';
import 'package:cono_moto/services/routing/guidance_engine.dart';
import 'package:cono_moto/services/routing/http_support.dart';
import 'package:cono_moto/services/routing/valhalla_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../routes/fixtures.dart';

void main() {
  const start = GeoPoint(48.6436, 1.8296);
  const place = Place(name: 'Dourdan', detail: '91410', point: GeoPoint(48.6648, 1.8439));
  final now = DateTime.utc(2026, 10, 5, 12);
  final v = ValhallaClient.parseResponse(fixtureJson('valhalla_route.json') as Map<String, dynamic>);
  final v2 = ValhallaClient.parseResponse(fixtureJson('valhalla_two_legs.json') as Map<String, dynamic>);

  test('options : préférences Valhalla et style mémorisé', () {
    final fast = DestinationOption.fastest.costing.toJson();
    final small = DestinationOption.smallRoads.costing.toJson();
    expect(fast['use_highways'], 1.0);
    expect(small['use_highways'], 0.0);
    expect(small['use_primary'], lessThan(fast['use_primary'] as double));
    expect(small['use_tolls'], 0.0);
    expect(DestinationOption.fromStyle(DestinationOption.fastest.style), DestinationOption.fastest);
    expect(DestinationOption.fromStyle(DestinationOption.smallRoads.style), DestinationOption.smallRoads);
  });

  test('itinéraire vers une destination', () {
    final r = buildDestinationRoute(
      v: v,
      start: start,
      destination: place,
      option: DestinationOption.smallRoads,
      now: now,
    );
    expect(isDestinationRoute(r), isTrue);
    expect(r.name, 'Vers Dourdan');
    expect(r.source, RouteSource.manual);
    expect(r.style, RouteStyle.sinueux);
    expect(r.waypoints, [start, place.point]);
    expect(r.distanceM, v.distanceM);
    expect(r.durationS, v.durationS);
    expect(r.maneuvers, isNotEmpty);
    // Aller-retour JSON (balade suivie gardée en base) : toujours une destination.
    expect(isDestinationRoute(PlannedRoute.fromJson(r.toJson())), isTrue);
    expect(isDestinationRoute(PlannedRoute(id: 'p1', name: 'Boucle', createdAt: now, points: v.points)), isFalse);
  });

  test('assemblage : option identique retirée, échec partiel signalé', () {
    final same = assemblePlans(start: start, destination: place, now: now, fastest: v, smallRoads: v);
    expect(same.plans.map((p) => p.option), [DestinationOption.fastest]);
    expect(same.notes.single, contains('même trajet'));

    final both = assemblePlans(start: start, destination: place, now: now, fastest: v, smallRoads: v2);
    expect(both.plans.map((p) => p.option), [DestinationOption.fastest, DestinationOption.smallRoads]);
    expect(both.notes, isEmpty);
    expect(both.plans.first.arrivalFrom(now), now.add(Duration(seconds: v.durationS)));

    final partial = assemblePlans(
      start: start,
      destination: place,
      now: now,
      smallRoads: v2,
      fastestError: 'Serveur saturé.',
    );
    expect(partial.plans.single.option, DestinationOption.smallRoads);
    expect(partial.notes.single, 'Le plus rapide : Serveur saturé.');
  });

  test('itinéraires presque identiques', () {
    expect(sameItinerary(v, v), isTrue);
    expect(sameItinerary(v, v2), isFalse);
  });

  test('recalcul : vers la destination, ou la suite de la balade', () {
    final dest = buildDestinationRoute(
      v: v,
      start: start,
      destination: place,
      option: DestinationOption.fastest,
      now: now,
    );
    expect(rerouteTargets(dest, GuidanceEngine(dest)), [place.point]);
    expect(rerouteCosting(dest).toJson(), DestinationOption.fastest.costing.toJson());

    final balade = PlannedRoute(
      id: 'b',
      name: 'Boucle',
      createdAt: now,
      points: v.points,
      style: RouteStyle.foret,
      maneuvers: v.maneuvers,
    );
    final engine = GuidanceEngine(balade);
    expect(rerouteTargets(balade, engine), engine.remainingViaPoints());
    expect(rerouteCosting(balade).toJson(), MotorcycleCosting.forStyle(RouteStyle.foret).toJson());
  });

  group('calcul des deux options', () {
    ProviderContainer container(Future<http.Response> Function(http.Request) handler) {
      final c = ProviderContainer(
        overrides: [
          valhallaClientProvider.overrideWithValue(
            ValhallaClient(client: MockClient(handler), limiter: RateLimiter(Duration.zero)),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    const query = DestinationQuery(start: start, destination: place);

    test('le plus rapide puis par les petites routes', () async {
      final bodies = <Map<String, dynamic>>[];
      final c = container((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        final file = bodies.length == 1 ? 'valhalla_route.json' : 'valhalla_two_legs.json';
        return http.Response.bytes(utf8.encode(fixture(file)), 200);
      });
      final sub = c.listen(destinationPlansProvider(query), (_, _) {});
      addTearDown(sub.close);
      final plans = await c.read(destinationPlansProvider(query).future);
      expect(bodies, hasLength(2));
      final opts = bodies.map((b) => (b['costing_options'] as Map)['motorcycle'] as Map).toList();
      expect(opts.first['use_highways'], 1.0);
      expect(opts.last['use_highways'], 0.0);
      expect(plans.plans.map((p) => p.option), [DestinationOption.fastest, DestinationOption.smallRoads]);
      expect(plans.plans.first.route.name, 'Vers Dourdan');
    });

    test('pas de réseau : erreur claire, un seul essai', () async {
      var calls = 0;
      final c = container((req) async {
        calls++;
        throw http.ClientException('hors ligne');
      });
      final sub = c.listen(destinationPlansProvider(query), (_, _) {});
      addTearDown(sub.close);
      await expectLater(
        c.read(destinationPlansProvider(query).future),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.offline)),
      );
      expect(calls, 1);
    });

    test('même départ à 5 m près : même demande', () {
      final a = DestinationQuery(start: start, destination: place);
      final b = DestinationQuery(start: Geo.destination(start, 45, 3), destination: place);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == DestinationQuery(start: Geo.destination(start, 0, 500), destination: place), isFalse);
    });
  });
}
