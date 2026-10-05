import 'dart:math' as math;

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/services/routing/route_scoring.dart';
import 'package:flutter_test/flutter_test.dart';

const origin = GeoPoint(48.0, 2.0);

/// Ligne plein est de [lengthM], avec un écart latéral (m) en fonction de x.
List<GeoPoint> road(double lengthM, double Function(double x) lateral, {double step = 10}) {
  final pts = <GeoPoint>[];
  for (var x = 0.0; x <= lengthM; x += step) {
    final p = Geo.destination(origin, 90, x);
    final y = lateral(x);
    pts.add(y == 0 ? p : Geo.destination(p, y > 0 ? 0 : 180, y.abs()));
  }
  return pts;
}

void main() {
  group('Sinuosité', () {
    test('ligne droite ≈ 0', () {
      final s = RouteScoring.curvatureScore(road(10000, (_) => 0));
      expect(s, lessThan(1));
    });

    test('micro-zigzags ignorés', () {
      final rnd = math.Random(42);
      // Bruit de ±3 m tous les 25 m (numérisation / GPS).
      final s = RouteScoring.curvatureScore(road(10000, (_) => (rnd.nextDouble() - 0.5) * 6, step: 25));
      expect(s, lessThan(12));
    });

    test('ondulation douce < virolos < épingles', () {
      final gentle = RouteScoring.curvatureScore(road(10000, (x) => 60 * math.sin(2 * math.pi * x / 1500)));
      final twisty = RouteScoring.curvatureScore(road(10000, (x) => 120 * math.sin(2 * math.pi * x / 500)));
      final hairpins = RouteScoring.curvatureScore(road(10000, (x) => 80 * math.sin(2 * math.pi * x / 250)));
      expect(gentle, lessThan(15));
      expect(twisty, greaterThan(55));
      expect(hairpins, greaterThan(80));
      expect(hairpins, lessThanOrEqualTo(100));
      expect(twisty, greaterThan(gentle + 30));
    });

    test('lignes trop courtes', () {
      expect(RouteScoring.curvatureScore(const [origin]), 0);
      expect(RouteScoring.curvatureScore([origin, Geo.destination(origin, 90, 30)]), 0);
    });
  });

  group('Dénivelé', () {
    test('D+ / D− avec hystérésis', () {
      final s = RouteScoring.elevationStats([100, 101, 102, 100, 110, 105, 120], hysteresisM: 3);
      expect(s.gainM, 25);
      expect(s.lossM, 5);
      expect(s.minM, 100);
      expect(s.maxM, 120);
      expect(RouteScoring.elevationStats([]).gainM, 0);
      expect(RouteScoring.elevationStats([double.nan, 50, 60]).gainM, 10);
    });

    test('platitude et grimpette', () {
      expect(RouteScoring.flatnessScore(0, 100000), 100);
      expect(RouteScoring.flatnessScore(300, 100000), greaterThan(RouteScoring.flatnessScore(1500, 100000)));
      expect(RouteScoring.climbScore(2500, 100000), greaterThan(80));
      expect(RouteScoring.climbScore(0, 100000), 0);
    });

    test('échantillonnage', () {
      final d = RouteScoring.sampleDistances(10500, stepM: 1000);
      expect(d.first, 0);
      expect(d.last, 10500);
      expect(d, hasLength(12));
      final capped = RouteScoring.sampleDistances(400000, stepM: 1000, maxPoints: 200);
      expect(capped, hasLength(200));
      expect(capped.last, 400000);
    });
  });

  group('Adéquation au style', () {
    RouteMetrics m({double curv = 30, int dur = 3600, double dist = 60000, double? gain = 400, int pois = 0}) =>
        RouteMetrics(distanceM: dist, durationS: dur, curvature: curv, elevationGainM: gain, poiCount: pois);

    test('sinueux préfère les virolos', () {
      expect(
        RouteScoring.styleFit(RouteStyle.sinueux, m(curv: 80)),
        greaterThan(RouteScoring.styleFit(RouteStyle.sinueux, m(curv: 20))),
      );
    });

    test('rapide préfère une bonne moyenne', () {
      expect(
        RouteScoring.styleFit(RouteStyle.rapide, m(dur: 2700)), // 80 km/h
        greaterThan(RouteScoring.styleFit(RouteStyle.rapide, m(dur: 5400))),
      ); // 40 km/h
    });

    test('plat préfère peu de D+', () {
      expect(
        RouteScoring.styleFit(RouteStyle.plat, m(gain: 100)),
        greaterThan(RouteScoring.styleFit(RouteStyle.plat, m(gain: 1500))),
      );
    });

    test('forêt / cols récompensent les points visés', () {
      expect(
        RouteScoring.styleFit(RouteStyle.foret, m(pois: 2)),
        greaterThan(RouteScoring.styleFit(RouteStyle.foret, m(pois: 0)) + 30),
      );
      expect(
        RouteScoring.styleFit(RouteStyle.cols, m(pois: 3, gain: 1800)),
        greaterThan(RouteScoring.styleFit(RouteStyle.cols, m(pois: 0, gain: 200))),
      );
    });

    test('pénalité si la distance dérape', () {
      final ok = RouteScoring.styleFit(RouteStyle.sinueux, m(curv: 70, dist: 100000), targetDistanceM: 100000);
      final off = RouteScoring.styleFit(RouteStyle.sinueux, m(curv: 70, dist: 150000), targetDistanceM: 100000);
      expect(ok - off, closeTo(24, 0.5));
      for (final s in RouteStyle.values) {
        final v = RouteScoring.styleFit(s, m());
        expect(v, inInclusiveRange(0, 100));
      }
    });
  });

  group('Badges', () {
    test('très sinueux qui grimpe', () {
      final b = RouteScoring.badges(
        const RouteMetrics(distanceM: 100000, durationS: 7200, curvature: 72, elevationGainM: 854),
      );
      expect(b.map((e) => e.label).toList(), ['Très sinueux', '+850 m D+']);
    });

    test('plat, rapide, forêts', () {
      final b = RouteScoring.badges(
        const RouteMetrics(distanceM: 120000, durationS: 5400, curvature: 10, elevationGainM: 200, poiCount: 2),
        style: RouteStyle.foret,
      );
      expect(b.map((e) => e.label).toList(), ['Tout droit', '2 forêts', 'Plutôt plat', 'Rapide']);
    });

    test('cols et ça grimpe', () {
      final b = RouteScoring.badges(
        const RouteMetrics(distanceM: 80000, durationS: 7200, curvature: 50, elevationGainM: 2100, poiCount: 1),
        style: RouteStyle.cols,
      );
      expect(b.first.label, 'Sinueux');
      expect(b.map((e) => e.label), containsAll(['1 col', '+2 100 m D+', 'Ça grimpe']));
    });

    test('format des mètres', () {
      expect(RouteScoring.formatMeters(1254), '1 250');
      expect(RouteScoring.formatMeters(854), '850');
      expect(RouteScoring.formatMeters(12345), '12 350');
    });
  });
}
