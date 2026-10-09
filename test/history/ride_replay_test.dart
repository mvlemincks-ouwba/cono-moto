import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/database.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/data/repositories.dart';
import 'package:cono_moto/features/history/ride_replay.dart';
import 'package:cono_moto/features/routes/route_actions.dart';
import 'package:cono_moto/services/routing/http_support.dart';
import 'package:cono_moto/services/routing/valhalla_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import '../routes/fixtures.dart';

final _ride = Ride(
  id: 'r1',
  name: 'Boucle du club',
  startedAt: DateTime.utc(2026, 10, 4, 9),
  endedAt: DateTime.utc(2026, 10, 4, 10),
  stats: const RideStats(distanceM: 12000, movingTimeS: 900, elevationGainM: 150, curveCount: 6),
);

/// Boucle d'environ 12 km avec trois virages à droite à 90°.
List<TrackPoint> _track() {
  final t0 = DateTime.utc(2026, 10, 4, 9);
  final pts = <GeoPoint>[
    for (var i = 0; i <= 30; i++) GeoPoint(45 + i * 0.0009, 5),
    for (var i = 1; i <= 30; i++) GeoPoint(45.027, 5 + i * 0.00127),
    for (var i = 1; i <= 30; i++) GeoPoint(45.027 - i * 0.0009, 5.0381),
    for (var i = 1; i <= 30; i++) GeoPoint(45, 5.0381 - i * 0.00127),
  ];
  return [
    for (var i = 0; i < pts.length; i++)
      TrackPoint(time: t0.add(Duration(seconds: i * 7)), lat: pts[i].lat, lng: pts[i].lng, speedMs: 14),
  ];
}

/// Recalcul simulé : ajoute les consignes de la réponse Valhalla de test.
Future<PlannedRoute> _reroute(PlannedRoute r) async {
  final v = ValhallaClient.parseResponse(fixtureJson('valhalla_route.json') as Map<String, dynamic>);
  return r.copyWith(maneuvers: v.maneuvers);
}

Future<PlannedRoute> _offline(PlannedRoute r) async =>
    throw const RoutingException(RoutingErrorKind.offline, 'Pas de réseau.');

void main() {
  late AppDatabase db;
  late RouteRepository routes;
  setUpAll(initTestLocale);
  setUp(() async {
    db = await openTestDatabase();
    routes = RouteRepository(db);
  });
  tearDown(() => db.close());

  Future<ReplayPlan?> replay(Ride ride, Future<PlannedRoute> Function(PlannedRoute) reroute, {List<TrackPoint>? track}) =>
      prepareReplay(
        ride: ride,
        routes: routes,
        track: () async => track ?? _track(),
        reroute: reroute,
        now: DateTime.utc(2026, 10, 9),
      );

  test('balade libre : recalculée le long des routes, avec consignes de virage', () async {
    var rerouting = 0;
    final plan = await prepareReplay(
      ride: _ride,
      routes: routes,
      track: () async => _track(),
      reroute: _reroute,
      now: DateTime.utc(2026, 10, 9),
      onRerouting: () => rerouting++,
    );
    expect(rerouting, 1);
    expect(plan!.offlineError, isNull);
    expect(plan.route.id, 'replay-r1');
    expect(plan.route.source, RouteSource.recorded);
    expect(plan.route.maneuvers, isNotEmpty, reason: 'flèches, voix et roadbook');
    expect(canFollowRoads(plan.route), isFalse);
    final saved = await routes.get('replay-r1');
    expect(saved!.maneuvers, hasLength(plan.route.maneuvers.length));
  });

  test('deuxième fois : on reprend la balade déjà préparée, sans recalcul', () async {
    await replay(_ride, _reroute);
    var calls = 0;
    final plan = await replay(_ride, (r) async {
      calls++;
      return r;
    });
    expect(calls, 0);
    expect(plan!.route.maneuvers, isNotEmpty);
    expect(await routes.list(), hasLength(1), reason: 'pas de doublon');
  });

  test('sans réseau : trace gardée, « Suivre les routes » proposé, nouvel essai la fois suivante', () async {
    final plan = await replay(_ride, _offline);
    expect(plan!.offlineError?.message, 'Pas de réseau.');
    expect(plan.route.maneuvers, isEmpty);
    expect(plan.route.points.length, greaterThanOrEqualTo(2));
    expect(canFollowRoads(plan.route), isTrue);

    // Renommée et mise en favori entre-temps : on garde nom et étoile.
    await routes.upsert(plan.route.copyWith(name: 'Ma boucle', favorite: true));
    final again = await replay(_ride, _reroute);
    expect(again!.route.maneuvers, isNotEmpty);
    expect(again.route.name, 'Ma boucle');
    expect(again.route.favorite, isTrue);
    expect(await routes.list(), hasLength(1));
  });

  test('balade qui suivait un itinéraire : on reprend l’itinéraire d’origine', () async {
    final original = await _reroute(
      PlannedRoute(
        id: 'gen-1',
        name: 'Les gorges du Vercors',
        createdAt: DateTime.utc(2026, 10, 1),
        points: const [GeoPoint(45, 5), GeoPoint(45.1, 5.1)],
        style: RouteStyle.sinueux,
        source: RouteSource.generated,
        distanceM: 14000,
        durationS: 1200,
      ),
    );
    await routes.upsert(original);
    var calls = 0;
    final plan = await replay(_ride.copyWith(routeId: 'gen-1'), (r) async {
      calls++;
      return r;
    });
    expect(calls, 0);
    expect(plan!.route.id, 'gen-1');
    expect(await routes.get('replay-r1'), isNull, reason: 'pas de doublon');
  });

  test('itinéraire d’origine supprimé : repli sur la trace', () async {
    final plan = await replay(_ride.copyWith(routeId: 'disparu'), _reroute);
    expect(plan!.route.id, 'replay-r1');
    expect(plan.route.maneuvers, isNotEmpty);
  });

  test('pas de trace exploitable → null', () async {
    expect(await replay(_ride, _reroute, track: const []), isNull);
  });
}
