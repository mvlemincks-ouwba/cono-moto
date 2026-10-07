import 'dart:math' as math;

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/services/ride/lean_angle.dart';
import 'package:flutter_test/flutter_test.dart';

/// Matrice 3×3 (lignes) pour simuler l'orientation du support de téléphone.
class Mat3 {
  const Mat3(this.r0, this.r1, this.r2);

  final Vec3 r0;
  final Vec3 r1;
  final Vec3 r2;

  Vec3 apply(Vec3 v) => Vec3(r0.dot(v), r1.dot(v), r2.dot(v));

  Mat3 operator *(Mat3 o) {
    final c0 = Vec3(o.r0.x, o.r1.x, o.r2.x);
    final c1 = Vec3(o.r0.y, o.r1.y, o.r2.y);
    final c2 = Vec3(o.r0.z, o.r1.z, o.r2.z);
    return Mat3(
      Vec3(r0.dot(c0), r0.dot(c1), r0.dot(c2)),
      Vec3(r1.dot(c0), r1.dot(c1), r1.dot(c2)),
      Vec3(r2.dot(c0), r2.dot(c1), r2.dot(c2)),
    );
  }

  static Mat3 rotX(double a) =>
      Mat3(const Vec3(1, 0, 0), Vec3(0, math.cos(a), -math.sin(a)), Vec3(0, math.sin(a), math.cos(a)));

  static Mat3 rotY(double a) =>
      Mat3(Vec3(math.cos(a), 0, math.sin(a)), const Vec3(0, 1, 0), Vec3(-math.sin(a), 0, math.cos(a)));

  static Mat3 rotZ(double a) =>
      Mat3(Vec3(math.cos(a), -math.sin(a), 0), Vec3(math.sin(a), math.cos(a), 0), const Vec3(0, 0, 1));
}

/// Simulateur de moto : repère moto (avant, gauche, haut), téléphone monté
/// avec une orientation quelconque [mount], capteurs à 50 Hz (une mesure toutes
/// les [sampleMs] ms), GPS à 1 Hz.
class BikeSim {
  BikeSim(
    this.est, {
    Mat3? mount,
    this.withSensors = true,
    this.noiseSeed,
    this.gyroBias = Vec3.zero,
    this.sampleMs = 20,
  }) : mount = mount ?? Mat3.rotZ(0.35) * Mat3.rotX(1.15) * Mat3.rotY(-0.2),
      _rnd = noiseSeed == null ? null : math.Random(noiseSeed);

  final LeanAngleEstimator est;
  final Mat3 mount;
  final bool withSensors;
  final int? noiseSeed;
  final Vec3 gyroBias;
  final int sampleMs;
  final math.Random? _rnd;

  DateTime t = DateTime.utc(2026, 6, 7, 9);
  double heading = 30;
  GeoPoint pos = const GeoPoint(45.0, 5.5);
  int _step = 0;

  /// Lean vrai du dernier pas (droite positif).
  double trueLeanDeg = 0;

  double _gauss(double sigma) {
    final r = _rnd;
    if (r == null || sigma == 0) return 0;
    final u1 = math.max(r.nextDouble(), 1e-12);
    final u2 = r.nextDouble();
    return sigma * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  /// [yawRate] en rad/s (anti-horaire positif = virage à gauche).
  /// [rollRate] : rotation parasite autour de l'axe avant (rad/s), fonction du temps.
  void run({
    required double speedMs,
    double yawRate = 0,
    required double seconds,
    double Function(double t)? rollRate,
    double gyroNoise = 0,
    double accNoise = 0,
    bool gpsHeading = true,
  }) {
    final dt = sampleMs / 1000;
    final steps = (seconds / dt).round();
    for (var i = 0; i < steps; i++) {
      _step++;
      t = t.add(Duration(milliseconds: sampleMs));
      final phi = math.atan(-speedMs * yawRate / Geo.g);
      trueLeanDeg = phi * 180 / math.pi;
      if (withSensors) {
        final accBody = Vec3(0, 0, Geo.g / math.cos(phi));
        final roll = rollRate?.call(_step * dt) ?? 0;
        final gyroBody = Vec3(roll, yawRate * math.sin(phi), yawRate * math.cos(phi));
        final a = mount.apply(accBody);
        final g = mount.apply(gyroBody) + gyroBias;
        est.addAccelerometer(t, a.x + _gauss(accNoise), a.y + _gauss(accNoise), a.z + _gauss(accNoise));
        est.addGyroscope(t, g.x + _gauss(gyroNoise), g.y + _gauss(gyroNoise), g.z + _gauss(gyroNoise));
      }
      heading = (heading - yawRate * dt * 180 / math.pi) % 360;
      if (speedMs > 0) pos = Geo.destination(pos, heading, speedMs * dt);
      if (_step % (1000 ~/ sampleMs) == 0) {
        est.addGps(t, speedMs, headingDeg: gpsHeading ? heading : null, position: pos);
      }
    }
  }
}

const kmh60 = 60 / 3.6;
final expected60r50 = math.atan(kmh60 * kmh60 / (50 * Geo.g)) * 180 / math.pi; // ≈ 29,5°

void main() {
  test('référence physique : 60 km/h, rayon 50 m ≈ 29,5°', () {
    expect(expected60r50, closeTo(29.5, 0.1));
  });

  group('gyroscope + GPS', () {
    test('calibre l\'axe haut quel que soit le support', () {
      final est = LeanAngleEstimator();
      final sim = BikeSim(est);
      sim.run(speedMs: 0, seconds: 3);
      expect(est.calibrated, isTrue);
      final trueUp = sim.mount.apply(const Vec3(0, 0, 1));
      expect(est.upAxis!.dot(trueUp), greaterThan(0.999));
    });

    test('virage à droite 60 km/h, R = 50 m → ≈ +29,5°', () {
      final est = LeanAngleEstimator();
      final sim = BikeSim(est);
      sim.run(speedMs: 0, seconds: 4);
      sim.run(speedMs: kmh60, seconds: 3);
      expect(est.leanDeg.abs(), lessThan(1));
      sim.run(speedMs: kmh60, yawRate: -kmh60 / 50, seconds: 6);
      expect(est.source, LeanSource.gyroscope);
      expect(est.leanDeg, closeTo(expected60r50, 1.0));
    });

    test('capteurs ralentis (≈ 15 Hz, écran éteint) : même angle à ±1°', () {
      for (final right in [true, false]) {
        final est = LeanAngleEstimator();
        final sim = BikeSim(est, sampleMs: 66, noiseSeed: 7);
        sim.run(speedMs: 0, seconds: 4, gyroNoise: 0.01, accNoise: 0.05);
        expect(est.calibrated, isTrue);
        sim.run(speedMs: kmh60, seconds: 3, gyroNoise: 0.01, accNoise: 0.05);
        final yaw = (right ? -1 : 1) * kmh60 / 50;
        sim.run(speedMs: kmh60, yawRate: yaw, seconds: 6, gyroNoise: 0.01, accNoise: 0.05);
        expect(est.source, LeanSource.gyroscope);
        expect(est.leanDeg, closeTo((right ? 1 : -1) * expected60r50, 1.0));
      }
    });

    test('virage à gauche → angle négatif', () {
      final est = LeanAngleEstimator();
      final sim = BikeSim(est);
      sim.run(speedMs: 0, seconds: 4);
      sim.run(speedMs: kmh60, seconds: 2);
      sim.run(speedMs: kmh60, yawRate: kmh60 / 50, seconds: 6);
      expect(est.leanDeg, closeTo(-expected60r50, 1.0));
      // Retour en ligne droite : l'angle revient vers 0 rapidement.
      sim.run(speedMs: kmh60, seconds: 2);
      expect(est.leanDeg.abs(), lessThan(1));
    });

    test('virage serré à 90 km/h (≈ 45°) avec un autre support', () {
      final est = LeanAngleEstimator();
      final sim = BikeSim(est, mount: Mat3.rotY(1.5) * Mat3.rotX(-0.4));
      const v = 25.0; // 90 km/h
      final r = v * v / Geo.g; // tan φ = 1
      sim.run(speedMs: 0, seconds: 4);
      sim.run(speedMs: v, seconds: 2);
      sim.run(speedMs: v, yawRate: -v / r, seconds: 6);
      expect(est.leanDeg, closeTo(45, 1.0));
    });

    test('le roulis et le tangage (bosses) ne créent pas d\'angle en ligne droite', () {
      final est = LeanAngleEstimator();
      final sim = BikeSim(est);
      sim.run(speedMs: 0, seconds: 4);
      sim.run(speedMs: kmh60, seconds: 6, rollRate: (t) => 0.8 * math.sin(2 * math.pi * 0.7 * t));
      expect(est.leanDeg.abs(), lessThan(0.5));
    });

    test('robuste au bruit et au biais du gyroscope', () {
      final est = LeanAngleEstimator();
      final sim = BikeSim(est, noiseSeed: 42, gyroBias: const Vec3(0.008, -0.006, 0.01));
      sim.run(speedMs: 0, seconds: 8, gyroNoise: 0.02, accNoise: 0.8);
      sim.run(speedMs: kmh60, seconds: 3, gyroNoise: 0.02, accNoise: 0.8);
      expect(est.leanDeg.abs(), lessThan(3));
      sim.run(speedMs: kmh60, yawRate: -kmh60 / 50, seconds: 6, gyroNoise: 0.02, accNoise: 0.8);
      expect(est.leanDeg, closeTo(expected60r50, 2.5));
    });

    test('forcé à 0 sous 12 km/h et borné à ±65°', () {
      final est = LeanAngleEstimator();
      final sim = BikeSim(est);
      sim.run(speedMs: 0, seconds: 4);
      sim.run(speedMs: 10 / 3.6, yawRate: 0.8, seconds: 4);
      expect(est.leanDeg, 0);
      // 108 km/h dans un rayon de 30 m : physiquement ≈ 72°, borné à 65°.
      sim.run(speedMs: 30, seconds: 2);
      sim.run(speedMs: 30, yawRate: -1, seconds: 4);
      expect(est.leanDeg, closeTo(65, 0.01));
    });
  });

  group('repli sans gyroscope (cap GPS)', () {
    test('virage à droite 60 km/h, R = 50 m', () {
      final est = LeanAngleEstimator();
      final sim = BikeSim(est, withSensors: false);
      sim.run(speedMs: kmh60, seconds: 3);
      sim.run(speedMs: kmh60, yawRate: -kmh60 / 50, seconds: 6);
      expect(est.source, LeanSource.gpsHeading);
      expect(est.leanDeg, closeTo(expected60r50, 1.5));
    });

    test('cap déduit des positions quand le GPS ne donne pas de cap', () {
      final est = LeanAngleEstimator();
      final sim = BikeSim(est, withSensors: false);
      sim.run(speedMs: kmh60, seconds: 3, gpsHeading: false);
      sim.run(speedMs: kmh60, yawRate: kmh60 / 50, seconds: 6, gpsHeading: false);
      expect(est.leanDeg, closeTo(-expected60r50, 2.5));
    });

    test('GPS perdu : angle à 0 après quelques secondes', () {
      final est = LeanAngleEstimator();
      final sim = BikeSim(est, withSensors: false);
      sim.run(speedMs: kmh60, seconds: 3);
      sim.run(speedMs: kmh60, yawRate: -kmh60 / 50, seconds: 4);
      expect(est.leanAt(sim.t), greaterThan(20));
      expect(est.leanAt(sim.t.add(const Duration(seconds: 6))), 0);
    });
  });

  test('vitesse extrapolée entre deux fixes', () {
    final est = LeanAngleEstimator();
    final t0 = DateTime.utc(2026);
    est.addGps(t0, 10);
    est.addGps(t0.add(const Duration(seconds: 1)), 12);
    expect(est.speedAt(t0.add(const Duration(milliseconds: 1500))), closeTo(13, 1e-9));
    // Extrapolation limitée à 1 s.
    expect(est.speedAt(t0.add(const Duration(seconds: 4))), closeTo(14, 1e-9));
    // Fix trop ancien : vitesse inconnue.
    expect(est.speedAt(t0.add(const Duration(seconds: 10))), 0);
  });
}
