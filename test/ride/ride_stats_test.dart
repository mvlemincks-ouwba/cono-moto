import 'dart:math' as math;

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/services/ride/ride_stats.dart';
import 'package:flutter_test/flutter_test.dart';

/// Générateur de trace : on donne une vitesse par seconde, les positions sont
/// intégrées le long d'un cap.
class TrackBuilder {
  TrackBuilder({DateTime? start, GeoPoint? origin, this.bearing = 45})
    : t = start ?? DateTime.utc(2026, 6, 7, 9),
      pos = origin ?? const GeoPoint(45.0, 5.5);

  DateTime t;
  GeoPoint pos;
  double bearing;
  final List<TrackPoint> points = [];

  void add({
    required double speedKmh,
    double lean = 0,
    double? altitude,
    double accuracy = 5,
    double dtS = 1,
    GeoPoint? at,
  }) {
    final v = speedKmh / 3.6;
    if (points.isNotEmpty) {
      final prevV = points.last.speedMs;
      pos = Geo.destination(pos, bearing, (prevV + v) / 2 * dtS);
      t = t.add(Duration(milliseconds: (dtS * 1000).round()));
    }
    points.add(
      TrackPoint(
        time: t,
        lat: (at ?? pos).lat,
        lng: (at ?? pos).lng,
        speedMs: v,
        leanDeg: lean,
        altitude: altitude,
        accuracyM: accuracy,
      ),
    );
  }

  void cruise(double speedKmh, int seconds, {double lean = 0, double? altitude}) {
    for (var i = 0; i < seconds; i++) {
      add(speedKmh: speedKmh, lean: lean, altitude: altitude);
    }
  }

  /// Variation de vitesse à accélération constante (m/s²), un point par seconde.
  void ramp(double fromKmh, double toKmh, double accelMs2) {
    var v = fromKmh / 3.6;
    final target = toKmh / 3.6;
    final step = accelMs2.abs() * (target > v ? 1 : -1);
    while ((target - v).abs() > 1e-9) {
      v += step;
      if ((step > 0 && v > target) || (step < 0 && v < target)) v = target;
      add(speedKmh: v * 3.6);
    }
  }
}

RideStats statsOf(List<TrackPoint> pts, {RideStatsConfig config = const RideStatsConfig()}) =>
    (RideStatsCalculator(config: config)..addAll(pts)).stats;

void main() {
  test('ligne droite : distance, temps en mouvement, vitesses', () {
    final b = TrackBuilder()..cruise(72, 101);
    final s = statsOf(b.points);
    expect(s.distanceM, closeTo(2000, 10));
    expect(s.movingTimeS, 100);
    expect(s.totalTimeS, 100);
    expect(s.maxSpeedKmh, closeTo(72, 0.01));
    expect(s.avgMovingSpeedKmh, closeTo(72, 0.5));
    expect(s.speedHistogram, {60: 100});
    expect(s.leanHistogram, {0: 100});
    expect(s.hardBrakeCount, 0);
  });

  test('pics GPS aberrants : vitesse max lissée, pas de faux freinage', () {
    final b = TrackBuilder()..cruise(72, 30);
    b.add(speedKmh: 72);
    b.points[15] = TrackPoint(
      time: b.points[15].time,
      lat: b.points[15].lat,
      lng: b.points[15].lng,
      speedMs: 200 / 3.6,
      accuracyM: 5,
    );
    final calc = RideStatsCalculator()..addAll(b.points);
    expect(calc.stats.maxSpeedKmh, closeTo(72, 0.01));
    expect(calc.stats.hardBrakeCount, 0);
    expect(calc.stats.hardAccelCount, 0);
  });

  test('précision > 30 m et téléportations ignorées', () {
    final b = TrackBuilder()..cruise(50, 20);
    final good = statsOf(b.points).distanceM;
    final noisy = List<TrackPoint>.of(b.points);
    final p = noisy[10];
    noisy.insert(
      11,
      TrackPoint(
        time: p.time.add(const Duration(milliseconds: 500)),
        lat: p.lat + 0.01,
        lng: p.lng,
        speedMs: p.speedMs,
        accuracyM: 50,
      ),
    );
    noisy.insert(
      12,
      TrackPoint(
        time: p.time.add(const Duration(milliseconds: 700)),
        lat: p.lat + 0.05, // 5,5 km en 0,2 s
        lng: p.lng,
        speedMs: p.speedMs,
        accuracyM: 8,
      ),
    );
    final calc = RideStatsCalculator()..addAll(noisy);
    expect(calc.rejectedCount, 2);
    expect(calc.stats.distanceM, closeTo(good, 0.5));
  });

  test('à l\'arrêt, le bruit GPS ne fait pas de distance', () {
    final rnd = math.Random(7);
    final b = TrackBuilder();
    final center = b.pos;
    for (var i = 0; i < 120; i++) {
      final p = Geo.destination(center, rnd.nextDouble() * 360, rnd.nextDouble() * 7);
      b.add(speedKmh: rnd.nextDouble() * 1.5, at: p, accuracy: 8);
    }
    final s = statsOf(b.points);
    expect(s.distanceM, lessThan(1));
    expect(s.movingTimeS, 0);
    expect(s.totalTimeS, 119);
    expect(s.maxSpeedKmh, lessThan(2));
  });

  group('freinages et accélérations', () {
    test('freinage fort depuis 90 km/h compté une fois', () {
      final b = TrackBuilder()
        ..cruise(90, 10)
        ..ramp(90, 20, -6) // ≈ 0,61 g
        ..cruise(20, 10);
      final calc = RideStatsCalculator()..addAll(b.points);
      final s = calc.stats;
      expect(s.hardBrakeCount, 1);
      expect(s.maxDecelG, closeTo(6 / Geo.g, 0.02));
      final ev = calc.events.where((e) => e.type == 'hard_brake').toList();
      expect(ev, hasLength(1));
      expect(ev.single.value, closeTo(0.61, 0.02));
    });

    test('freinage doux ou depuis moins de 25 km/h : pas compté', () {
      final gentle = TrackBuilder()
        ..cruise(90, 5)
        ..ramp(90, 30, -2)
        ..cruise(30, 5);
      expect(statsOf(gentle.points).hardBrakeCount, 0);

      final slow = TrackBuilder()
        ..cruise(22, 5)
        ..ramp(22, 0, -6)
        ..cruise(0, 3);
      expect(statsOf(slow.points).hardBrakeCount, 0);
    });

    test('seuil de freinage paramétrable', () {
      final b = TrackBuilder()
        ..cruise(90, 5)
        ..ramp(90, 40, -3.5) // ≈ 0,36 g
        ..cruise(40, 5);
      expect(statsOf(b.points).hardBrakeCount, 0);
      expect(statsOf(b.points, config: const RideStatsConfig(hardBrakeThresholdG: 0.3)).hardBrakeCount, 1);
    });

    test('accélération forte', () {
      final b = TrackBuilder()
        ..cruise(10, 3)
        ..ramp(10, 100, 5) // ≈ 0,51 g
        ..cruise(100, 5);
      final s = statsOf(b.points);
      expect(s.hardAccelCount, 1);
      expect(s.maxAccelG, closeTo(5 / Geo.g, 0.02));
      expect(s.hardBrakeCount, 0);
    });

    test('épisode court (< 0,8 s) ignoré', () {
      final b = TrackBuilder();
      for (var i = 0; i < 20; i++) {
        b.add(speedKmh: 90, dtS: 0.2);
      }
      // 0,4 s à -6 m/s² puis stable.
      b.add(speedKmh: 90 - 6 * 0.2 * 3.6, dtS: 0.2);
      b.add(speedKmh: 90 - 6 * 0.4 * 3.6, dtS: 0.2);
      for (var i = 0; i < 20; i++) {
        b.add(speedKmh: 90 - 6 * 0.4 * 3.6, dtS: 0.2);
      }
      expect(statsOf(b.points).hardBrakeCount, 0);
    });
  });

  test('virages : épisodes > 15°, max G/D, moyenne en courbe', () {
    final leans = [0, 0, 20, 25, 18, 5, 0, -22, -30, -12, -8, 0, 16, 17, 12, 9, 0, 0];
    final b = TrackBuilder();
    for (final l in leans) {
      b.add(speedKmh: 60, lean: l.toDouble());
    }
    final calc = RideStatsCalculator()..addAll(b.points);
    final s = calc.stats;
    expect(s.curveCount, 3);
    expect(s.maxLeanLeftDeg, 30);
    expect(s.maxLeanRightDeg, 25);
    expect(s.maxLeanDeg, 30);
    expect(s.avgLeanInCurvesDeg, closeTo((25 + 30 + 17) / 3, 1e-9));
    expect(s.leanHistogram[20], 3); // 20, 25, -22 (le 30 est dans la tranche 30)
    expect(s.leanHistogram[30], 1);
    final maxEvents = calc.events.where((e) => e.type == 'max_lean').map((e) => e.value).toList();
    expect(maxEvents, containsAll([-30.0, 25.0]));
  });

  test('changement de côté direct (gauche → droite) = deux virages', () {
    final b = TrackBuilder();
    for (final l in [0, -20, -25, 22, 28, 0]) {
      b.add(speedKmh: 60, lean: l.toDouble());
    }
    expect(statsOf(b.points).curveCount, 2);
  });

  test('dénivelé avec hystérésis malgré le bruit GPS', () {
    final b = TrackBuilder();
    final rnd = math.Random(3);
    double noisy(double alt) => alt + (rnd.nextDouble() - 0.5) * 3;
    for (var i = 0; i <= 200; i++) {
      b.add(speedKmh: 50, altitude: noisy(100 + i * 0.5));
    }
    for (var i = 0; i < 30; i++) {
      b.add(speedKmh: 50, altitude: noisy(200));
    }
    for (var i = 0; i <= 100; i++) {
      b.add(speedKmh: 50, altitude: noisy(200 - i * 0.5));
    }
    for (var i = 0; i < 30; i++) {
      b.add(speedKmh: 50, altitude: noisy(150));
    }
    final s = statsOf(b.points);
    expect(s.elevationGainM, closeTo(100, 8));
    expect(s.elevationLossM, closeTo(50, 8));
    expect(s.maxAltitudeM, closeTo(200, 3));
  });

  test('pause : pas de distance ni de temps à travers la coupure', () {
    final b = TrackBuilder()..cruise(72, 51); // 1 km
    final firstPart = List<TrackPoint>.of(b.points);
    b.t = b.t.add(const Duration(minutes: 10));
    b.pos = Geo.destination(b.pos, 90, 5000);
    b.points.clear();
    b.cruise(72, 51); // 1 km
    final secondPart = List<TrackPoint>.of(b.points);

    final calc = RideStatsCalculator()
      ..addAll(firstPart)
      ..breakSegment()
      ..addAll(secondPart);
    expect(calc.stats.distanceM, closeTo(2000, 10));
    expect(calc.stats.totalTimeS, 100);

    final pauseStart = firstPart.last.time.add(const Duration(seconds: 2));
    final viaCompute = RideStatsCalculator.compute(
      [...firstPart, ...secondPart],
      pauses: RideStatsCalculator.pausesFromEvents([
        RideEvent(type: 'pause', time: pauseStart, lat: 0, lng: 0, value: 590),
      ]),
    );
    expect(viaCompute.stats.distanceM, closeTo(2000, 10));
    expect(viaCompute.stats.movingTimeS, 100);
  });

  test('trou GPS en roulant (tunnel) : distance et temps conservés', () {
    final b = TrackBuilder()..cruise(90, 21);
    // 60 s sans fix à 90 km/h.
    b.add(speedKmh: 90, dtS: 60);
    b.cruise(90, 20);
    final s = statsOf(b.points);
    expect(s.distanceM, closeTo(25 * 100, 15));
    expect(s.movingTimeS, 100);
  });

  test('le calcul incrémental = calcul complet', () {
    final b = TrackBuilder()
      ..cruise(0, 5)
      ..ramp(0, 80, 3)
      ..cruise(80, 20, lean: 22)
      ..ramp(80, 30, -5)
      ..cruise(30, 10, lean: -18)
      ..ramp(30, 0, -2);
    final live = RideStatsCalculator();
    for (final p in b.points) {
      live.add(p);
    }
    final full = RideStatsCalculator.compute(b.points);
    expect(live.stats.toJson(), full.stats.toJson());
    expect(live.events.length, full.events.length);
  });

  test('balade vide', () {
    final s = RideStatsCalculator().stats;
    expect(s.distanceM, 0);
    expect(s.avgMovingSpeedKmh, 0);
    expect(RideStatsCalculator.compute(const []).events, isEmpty);
  });
}
