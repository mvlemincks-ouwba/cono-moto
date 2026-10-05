import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/services/ride/crash_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pilote une détection : GPS à 1 Hz, accéléromètre à 50 Hz (1 g au repos).
class CrashSim {
  CrashSim([CrashDetectorConfig config = const CrashDetectorConfig()]) : det = CrashDetector(config: config);

  final CrashDetector det;
  DateTime t = DateTime.utc(2026, 6, 7, 10);
  int _ms = 0;
  bool fired = false;
  DateTime? firedAt;

  void _record(bool f) {
    if (f && !fired) {
      fired = true;
      firedAt = t;
    }
  }

  /// Avance de [seconds] à vitesse constante ([gps] = false : pas de fix).
  void ride(double kmh, double seconds, {bool gps = true}) {
    final steps = (seconds * 50).round();
    for (var i = 0; i < steps; i++) {
      t = t.add(const Duration(milliseconds: 20));
      _ms += 20;
      _record(det.onAccelerometer(t, 0, 0, Geo.g));
      if (_ms % 1000 == 0) {
        if (gps) _record(det.onSpeed(t, kmh / 3.6));
        _record(det.tick(t));
      }
    }
  }

  /// Choc de [g] pendant [samples] échantillons consécutifs.
  void shock(double g, {int samples = 4}) {
    for (var i = 0; i < samples; i++) {
      t = t.add(const Duration(milliseconds: 20));
      _ms += 20;
      _record(det.onAccelerometer(t, g * Geo.g * 0.6, g * Geo.g * 0.8, 0));
    }
  }
}

void main() {
  test('chute : choc à 50 km/h, arrêt, immobile 15 s → alerte', () {
    final sim = CrashSim()..ride(50, 10);
    final impactAt = sim.t;
    sim.shock(6);
    expect(sim.det.phase, CrashPhase.impact);
    expect(sim.det.speedBeforeKmh, closeTo(50, 0.01));
    sim.ride(25, 1);
    sim.ride(8, 1);
    sim.ride(0, 10);
    expect(sim.fired, isFalse);
    expect(sim.det.phase, CrashPhase.immobile);
    sim.ride(0, 10);
    expect(sim.fired, isTrue);
    expect(sim.det.phase, CrashPhase.suspected);
    final delay = sim.firedAt!.difference(impactAt).inSeconds;
    expect(delay, inInclusiveRange(16, 19));
    expect(sim.det.impactG, closeTo(6, 0.01));
  });

  test('nid-de-poule : choc mais on continue de rouler → rien', () {
    final sim = CrashSim()..ride(70, 10);
    sim.shock(5);
    expect(sim.det.phase, CrashPhase.impact);
    sim.ride(68, 30);
    expect(sim.fired, isFalse);
    expect(sim.det.phase, CrashPhase.monitoring);
  });

  test('nid-de-poule puis arrêt au feu quelques secondes après → rien', () {
    final sim = CrashSim()..ride(50, 10);
    sim.shock(5);
    sim.ride(48, 2);
    sim.ride(35, 2);
    sim.ride(20, 1);
    sim.ride(10, 1);
    sim.ride(0, 40);
    expect(sim.fired, isFalse);
  });

  test('téléphone qui tombe / béquille : vitesse faible avant le choc → rien', () {
    final sim = CrashSim()..ride(4, 10);
    sim.shock(8);
    expect(sim.det.phase, CrashPhase.monitoring);
    sim.ride(0, 30);
    expect(sim.fired, isFalse);
  });

  test('pic isolé (vibration) : pas un choc', () {
    final sim = CrashSim()..ride(90, 5);
    sim.shock(6, samples: 1);
    sim.ride(90, 1);
    expect(sim.det.phase, CrashPhase.monitoring);
  });

  test('GPS perdu après le choc : considéré immobile → alerte', () {
    final sim = CrashSim()..ride(60, 10);
    sim.shock(7);
    sim.ride(0, 25, gps: false);
    expect(sim.fired, isTrue);
  });

  test('le motard repart avant les 15 s → annulé', () {
    final sim = CrashSim()..ride(60, 10);
    sim.shock(6);
    sim.ride(0, 8);
    expect(sim.det.phase, CrashPhase.immobile);
    sim.ride(25, 5);
    expect(sim.det.phase, CrashPhase.monitoring);
    sim.ride(0, 30);
    expect(sim.fired, isFalse);
  });

  test('une lecture GPS bruitée à l\'arrêt n\'interrompt pas le décompte', () {
    final sim = CrashSim()..ride(60, 10);
    sim.shock(6);
    sim.ride(0, 6);
    sim.ride(5, 1); // une seule lecture à 5 km/h
    sim.ride(0, 12);
    expect(sim.fired, isTrue);
  });

  test('reset après « Je vais bien » : nouvelle détection possible', () {
    final sim = CrashSim()..ride(60, 5);
    sim.shock(6);
    sim.ride(0, 20);
    expect(sim.fired, isTrue);
    sim.det.reset();
    expect(sim.det.phase, CrashPhase.monitoring);
    sim.fired = false;
    sim.ride(60, 5);
    sim.shock(6);
    sim.ride(0, 20);
    expect(sim.fired, isTrue);
  });

  test('seuil de choc paramétrable', () {
    final sim = CrashSim(const CrashDetectorConfig(shockThresholdG: 3))..ride(60, 5);
    sim.shock(3.5);
    expect(sim.det.phase, CrashPhase.impact);
    final strict = CrashSim()..ride(60, 5);
    strict.shock(3.5);
    expect(strict.det.phase, CrashPhase.monitoring);
  });
}
