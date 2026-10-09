import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/features/history/ride_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Trace rectiligne vers le nord : un point toutes les secondes à [speedMs].
List<TrackPoint> straightTrack(
  int n, {
  double speedMs = 20,
  double Function(int i)? lean,
  double? Function(int i)? alt,
}) {
  final t0 = DateTime.utc(2026, 10, 5, 9);
  final dLat = speedMs / Geo.metersPerDegreeLat;
  return [
    for (var i = 0; i < n; i++)
      TrackPoint(
        time: t0.add(Duration(seconds: i)),
        lat: 45 + i * dLat,
        lng: 5,
        speedMs: speedMs,
        leanDeg: lean?.call(i) ?? 0,
        altitude: alt?.call(i),
      ),
  ];
}

void main() {
  setUpAll(initTestLocale);

  group('séries vitesse / angle / altitude', () {
    test('sous-échantillonnage par distance et extrêmes d’angle conservés', () {
      final pts = straightTrack(1000, lean: (i) => i == 500 ? -47 : (i % 7) - 3.0, alt: (i) => 200 + i / 10);
      final s = buildRideSeries(pts, maxPoints: 100);
      expect(s.totalKm, closeTo(999 * 20 / 1000, 0.05));
      expect(s.speed.length, lessThanOrEqualTo(100));
      expect(s.speed.length, greaterThan(90));
      expect(s.speed.every((p) => (p.value - 72).abs() < 1e-6), isTrue);
      expect(s.lean.map((p) => p.value).reduce((a, b) => a < b ? a : b), -47);
      expect(s.hasLean, isTrue);
      expect(s.hasAltitude, isTrue);
      expect(s.altitude.first.value, lessThan(s.altitude.last.value));
      // abscisses croissantes
      for (var i = 1; i < s.speed.length; i++) {
        expect(s.speed[i].km, greaterThan(s.speed[i - 1].km));
      }
    });

    test('arrêts exclus de la vitesse moyenne', () {
      final pts = [
        ...straightTrack(10),
        for (var i = 0; i < 5; i++)
          TrackPoint(time: DateTime.utc(2026, 10, 5, 9, 1, i), lat: 45.0016, lng: 5, speedMs: 0),
      ];
      final s = buildRideSeries(pts, maxPoints: 1);
      expect(s.speed.single.value, closeTo(72, 1e-6));
    });

    test('trace trop courte', () {
      expect(buildRideSeries(straightTrack(1)).speed, isEmpty);
      expect(buildRideSeries(const []).totalKm, 0);
    });
  });

  test('histogramme des angles depuis les points', () {
    final pts = straightTrack(11, lean: (i) => i <= 5 ? 5 : 33);
    expect(leanHistogramFromPoints(pts), {0: 5, 30: 5});
  });

  group('coloration de la trace', () {
    test('tranches', () {
      expect(bucketFor(10, leanBucketThresholds), 0);
      expect(bucketFor(15, leanBucketThresholds), 1);
      expect(bucketFor(45, leanBucketThresholds), 3);
      expect(bucketFor(55, leanBucketThresholds), 4);
    });

    test('morceaux contigus qui se rejoignent', () {
      final pts = straightTrack(30, lean: (i) => i < 10 ? 5 : (i < 20 ? 35 : 5));
      final runs = colorRuns(pts, (p) => p.leanDeg.abs(), leanBucketThresholds);
      expect(runs.map((r) => r.bucket), [0, 2, 0]);
      expect(runs[0].points.last, runs[1].points.first);
      expect(runs[1].points.last, runs[2].points.first);
      expect(runs.last.points.last, pts.last.point);
      final total = runs.fold<int>(0, (s, r) => s + r.points.length);
      expect(total, 30 + 2, reason: 'les jonctions sont dupliquées');
    });

    test('allègement des longues traces', () {
      final pts = straightTrack(10000, lean: (i) => i == 5003 ? 50 : 0);
      final runs = colorRuns(pts, (p) => p.leanDeg.abs(), leanBucketThresholds, maxPoints: 500);
      final n = runs.fold<int>(0, (s, r) => s + r.points.length);
      expect(n, lessThan(520));
      expect(runs.any((r) => r.bucket == 4), isTrue, reason: 'le pic est conservé');
    });
  });

  group('coût de la balade', () {
    test('pleins + dépenses, par km et par personne', () {
      final c = computeRideCost(
        fuel: [FuelEntry(id: 'f', date: DateTime.utc(2026), liters: 12, pricePerLiter: 1.85)],
        expenses: [
          Expense(id: 'e1', date: DateTime.utc(2026), amount: 8.6, category: ExpenseCategory.peage),
          Expense(id: 'e2', date: DateTime.utc(2026), amount: 24, category: ExpenseCategory.resto),
        ],
        distanceKm: 200,
        consumptionL100: 5,
        pricePerLiter: 1.9,
      );
      expect(c.fuelTotal, closeTo(22.2, 1e-9));
      expect(c.expensesTotal, closeTo(32.6, 1e-9));
      expect(c.fuelIsEstimated, isFalse);
      expect(c.estimatedFuel, isNull);
      expect(c.total, closeTo(54.8, 1e-9));
      expect(c.perKm, closeTo(0.274, 1e-9));
      expect(c.perPerson(4), closeTo(13.7, 1e-9));
      expect(c.perPerson(0), c.total);
    });

    test('essence estimée sans plein lié', () {
      final c = computeRideCost(
        fuel: const [],
        expenses: const [],
        distanceKm: 150,
        consumptionL100: 6,
        pricePerLiter: 1.8,
      );
      expect(c.fuelIsEstimated, isTrue);
      expect(c.estimatedFuel, closeTo(16.2, 1e-9));
      expect(c.total, closeTo(16.2, 1e-9));
      expect(c.isEmpty, isFalse);
      final none = computeRideCost(fuel: const [], expenses: const [], distanceKm: 150);
      expect(none.isEmpty, isTrue);
      expect(none.perKm, isNull);
    });
  });

  group('refaire la balade', () {
    final track = straightTrack(600, lean: (i) => 0);
    final ride = Ride(
      id: 'r1',
      name: 'Tour du Vercors',
      startedAt: DateTime.utc(2026, 10, 4, 9),
      endedAt: DateTime.utc(2026, 10, 4, 12),
      stats: const RideStats(distanceM: 12000, movingTimeS: 600, elevationGainM: 400, curveCount: 9),
    );

    test('PlannedRoute source recorded avec la trace simplifiée', () {
      final r = plannedRouteFromRide(ride, track, id: 'p1', now: DateTime.utc(2026, 10, 5));
      expect(r.id, 'p1');
      expect(r.source, RouteSource.recorded);
      expect(r.name, 'Tour du Vercors');
      expect(r.points.length, lessThan(10), reason: 'ligne droite simplifiée');
      expect(r.points.first, track.first.point);
      expect(r.points.last, track.last.point);
      expect(r.distanceM, 12000);
      expect(r.durationS, 600);
      expect(r.elevationGainM, 400);
      expect(r.waypoints.length, greaterThanOrEqualTo(2));
      // Points de passage serrés (≤ 2 km) : le recalcul colle à la route suivie.
      for (var i = 1; i < r.waypoints.length; i++) {
        expect(Geo.distance(r.waypoints[i - 1], r.waypoints[i]), lessThanOrEqualTo(2001));
      }
      expect(r.description, contains('Balade enregistrée le'));
      // Aller-retour JSON (stockage) sans perte.
      final back = PlannedRoute.fromJson(r.toJson());
      expect(back.points.length, r.points.length);
    });

    test('repli sur l’aperçu si pas de points', () {
      final preview = Geo.encodePolyline([const GeoPoint(45, 5), const GeoPoint(45.1, 5.1), const GeoPoint(45.2, 5)]);
      final r = plannedRouteFromRide(
        ride.copyWith(previewPolyline: preview),
        const [],
        id: 'p2',
        now: DateTime.utc(2026, 10, 5),
      );
      expect(r.points, hasLength(3));
    });

    test('style deviné', () {
      expect(guessRouteStyle(const RideStats(distanceM: 100000, elevationGainM: 3000)), RouteStyle.cols);
      expect(
        guessRouteStyle(const RideStats(distanceM: 100000, curveCount: 80, elevationGainM: 800)),
        RouteStyle.sinueux,
      );
      expect(guessRouteStyle(const RideStats(distanceM: 100000, curveCount: 10, elevationGainM: 200)), RouteStyle.plat);
      expect(
        guessRouteStyle(const RideStats(distanceM: 100000, movingTimeS: 3600, curveCount: 10, elevationGainM: 900)),
        RouteStyle.rapide,
      );
    });
  });

  test('nom de fichier sûr', () {
    expect(safeFileName('Tour du Vercors — été 2026 !'), 'tour-du-vercors-ete-2026');
    expect(safeFileName('   '), 'balade');
  });
}
