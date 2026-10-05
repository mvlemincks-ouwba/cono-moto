import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/services/routing/guidance_engine.dart';
import 'package:cono_moto/services/routing/maneuver_kinds.dart';
import 'package:cono_moto/services/routing/valhalla_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

PlannedRoute fixtureRoute() {
  final v = ValhallaClient.parseResponse(fixtureJson('valhalla_route.json') as Map<String, dynamic>);
  return PlannedRoute(
    id: 'g1',
    name: 'Test',
    createdAt: DateTime.utc(2026, 10, 5),
    points: v.points,
    distanceM: v.distanceM,
    durationS: v.durationS,
    maneuvers: v.maneuvers,
  );
}

GeoPoint at(PlannedRoute r, double along) => Geo.pointAtDistance(r.points, along);

/// Point décalé de [meters] à droite de l'itinéraire.
GeoPoint offset(PlannedRoute r, double along, double meters) {
  final p = at(r, along);
  final ahead = at(r, along + 5);
  return Geo.destination(p, Geo.bearing(p, ahead) + 90, meters);
}

void main() {
  test('annonces à 500 m puis 100 m, sans répétition', () {
    final r = fixtureRoute();
    final g = GuidanceEngine(r);
    final turnAt = r.maneuvers[1].distanceAlongM; // ≈ 1014 m

    final s0 = g.update(at(r, 0), speedMs: 12);
    expect(s0.announcement, "C'est parti ! roule vers l'est sur Rue Chasles.");
    expect(s0.next?.type, ManeuverKind.left);
    expect(s0.distanceToNextM, closeTo(turnAt, 2));
    expect(g.update(at(r, 100), speedMs: 12).announcement, isNull);

    final far = g.update(at(r, turnAt - 490), speedMs: 12);
    expect(far.announcement, 'Dans 500 mètres, tourne à gauche sur D 906, puis prends le rond-point.');
    expect(g.update(at(r, turnAt - 450), speedMs: 12).announcement, isNull);

    final near = g.update(at(r, turnAt - 95), speedMs: 12);
    expect(near.announcement, 'Dans 100 mètres, tourne à gauche sur D 906, puis prends le rond-point.');
    expect(g.update(at(r, turnAt - 60), speedMs: 12).announcement, isNull);

    final after = g.update(at(r, turnAt + 30), speedMs: 12);
    expect(after.next?.type, ManeuverKind.roundabout);
    expect(after.following?.type, ManeuverKind.roundaboutExit);
    expect(after.offRoute, isFalse);
    expect(after.progressM, closeTo(turnAt + 30, 3));
    expect(after.remainingM, closeTo(r.distanceM - turnAt - 30, 10));
  });

  test('hors itinéraire après 3 positions à plus de 60 m, puis retour', () {
    final r = fixtureRoute();
    final g = GuidanceEngine(r);
    g.update(at(r, 200));
    expect(g.update(offset(r, 300, 100)).offRoute, isFalse);
    expect(g.update(offset(r, 320, 110)).offRoute, isFalse);
    final s = g.update(offset(r, 340, 120));
    expect(s.offRoute, isTrue);
    expect(s.announcement, "Tu as quitté l'itinéraire.");
    expect(s.distanceFromRouteM, greaterThan(100));
    expect(s.progressM, closeTo(200, 5)); // la progression ne saute pas
    expect(g.update(offset(r, 360, 120)).announcement, isNull);
    final back = g.update(at(r, 380));
    expect(back.offRoute, isFalse);
    expect(back.announcement, "De retour sur l'itinéraire, nickel.");
  });

  test('positions imprécises ignorées pour le hors-itinéraire', () {
    final r = fixtureRoute();
    final g = GuidanceEngine(r);
    g.update(at(r, 200));
    for (var i = 0; i < 5; i++) {
      expect(g.update(offset(r, 220, 90), accuracyM: 120).offRoute, isFalse);
    }
  });

  test('arrivée', () {
    final r = fixtureRoute();
    final g = GuidanceEngine(r);
    for (var d = 0.0; d < r.distanceM - 100; d += 150) {
      g.update(at(r, d), speedMs: 14);
    }
    final s = g.update(r.points.last);
    expect(s.arrived, isTrue);
    expect(s.announcement, 'Tu es arrivé ! Bien roulé.');
    expect(g.update(r.points.last).announcement, isNull);
  });

  test('boucle : au départ, on ne se croit pas arrivé', () {
    final base = fixtureRoute();
    final loop = PlannedRoute(
      id: 'loop',
      name: 'Boucle',
      createdAt: DateTime.utc(2026),
      points: [...base.points, ...base.points.reversed.skip(1)],
    );
    final g = GuidanceEngine(loop);
    final s = g.update(loop.points.first);
    expect(s.arrived, isFalse);
    expect(s.progressM, lessThan(20));
    // En avançant, la fenêtre glissante ne saute pas sur le retour.
    final mid = g.update(at(loop, 1500));
    expect(mid.progressM, closeTo(1500, 5));
  });

  test('points pour recalculer', () {
    final r = fixtureRoute();
    final g = GuidanceEngine(r);
    g.update(at(r, 500));
    final pts = g.remainingViaPoints(rejoinAheadM: 500);
    expect(pts.last, r.points.last);
    expect(pts.length, lessThanOrEqualTo(18));
    expect(Geo.distance(pts.first, at(r, 1000)), lessThan(5));
    expect(g.remainingViaPoints(fromM: r.distanceM - 100), [r.points.last]);
  });

  test('distances prononcées', () {
    expect(GuidanceEngine.spokenDistance(480), '500 mètres');
    expect(GuidanceEngine.spokenDistance(120), '100 mètres');
    expect(GuidanceEngine.spokenDistance(160), '150 mètres');
    expect(GuidanceEngine.spokenDistance(20), '50 mètres');
    expect(GuidanceEngine.spokenDistance(1200), '1 kilomètre');
    expect(GuidanceEngine.spokenDistance(1600), '1,5 kilomètre');
    expect(GuidanceEngine.spokenDistance(2600), '2,5 kilomètres');
  });
}
