import 'dart:math' as math;

import '../../core/geo.dart';
import '../../data/models/planned_route.dart';

/// Dénivelés d'un profil d'altitude.
class ElevationStats {
  const ElevationStats({required this.gainM, required this.lossM, required this.minM, required this.maxM});

  final double gainM;
  final double lossM;
  final double minM;
  final double maxM;

  static const empty = ElevationStats(gainM: 0, lossM: 0, minM: 0, maxM: 0);
}

/// Mesures d'un itinéraire, base du score et des badges.
class RouteMetrics {
  const RouteMetrics({
    required this.distanceM,
    required this.durationS,
    required this.curvature,
    this.elevationGainM,
    this.poiCount = 0,
    this.hasHighway = false,
  });

  final double distanceM;
  final int durationS;

  /// Sinuosité 0–100.
  final double curvature;

  /// D+ en mètres (null si inconnu).
  final double? elevationGainM;

  /// Nombre de forêts / cols visés traversés.
  final int poiCount;
  final bool hasHighway;

  double get distanceKm => distanceM / 1000;

  /// Vitesse moyenne prévue (km/h).
  double get avgSpeedKmh => durationS <= 0 ? 0 : distanceM / durationS * 3.6;

  /// D+ par kilomètre (null si inconnu).
  double? get gainPerKm => elevationGainM == null || distanceM <= 0 ? null : elevationGainM! / (distanceM / 1000);
}

/// Catégorie d'un badge (l'UI choisit icône et couleur).
enum BadgeKind { curvy, straight, climb, flat, fast, calm, forest, pass, highway }

/// Badge lisible affiché sur une balade (« Très sinueux », « +850 m D+ »…).
class RouteBadge {
  const RouteBadge(this.label, this.kind);

  final String label;
  final BadgeKind kind;

  @override
  bool operator ==(Object other) => other is RouteBadge && other.label == label && other.kind == kind;

  @override
  int get hashCode => Object.hash(label, kind);

  @override
  String toString() => 'RouteBadge($label)';
}

/// Calculs de score purs (aucune dépendance réseau ou plateforme).
class RouteScoring {
  RouteScoring._();

  /// Angle minimal (cumulé) d'un virage pour être compté : en dessous, ce
  /// sont des micro-zigzags de numérisation ou de bruit GPS.
  static const minTurnDeg = 15.0;

  /// Changement de cap cumulé en degrés par km (virages francs uniquement).
  static double turningDegreesPerKm(List<GeoPoint> points, {double stepM = 25}) {
    if (points.length < 3) return 0;
    final total = Geo.length(points);
    if (total < stepM * 3) return 0;
    final rs = Geo.resample(points, stepM);
    if (rs.length < 3) return 0;
    final bearings = <double>[];
    for (var i = 1; i < rs.length; i++) {
      if (Geo.distance(rs[i - 1], rs[i]) < stepM * 0.2) continue;
      bearings.add(Geo.bearing(rs[i - 1], rs[i]));
    }
    var sum = 0.0;
    var run = 0.0;
    var runSign = 0;
    var straight = 0;
    void flush() {
      if (run.abs() >= minTurnDeg) sum += run.abs();
      run = 0;
      runSign = 0;
    }

    for (var i = 1; i < bearings.length; i++) {
      final d = Geo.headingDelta(bearings[i - 1], bearings[i]);
      if (d.abs() < 1.0) {
        // Quasi tout droit : neutre, mais une longue ligne droite clôt le virage.
        if (++straight * stepM >= 100) flush();
        continue;
      }
      straight = 0;
      final sign = d > 0 ? 1 : -1;
      // Un changement de sens clôt le virage : les zigzags s'annulent.
      if (runSign != 0 && sign != runSign) flush();
      runSign = sign;
      run += d;
    }
    flush();
    return sum / (total / 1000);
  }

  /// Score de sinuosité 0–100 (≈ 15 : nationale, ≈ 40 : départementale
  /// qui tourne, ≥ 65 : vrais virolos).
  static double curvatureScore(List<GeoPoint> points, {double stepM = 25}) {
    final dpk = turningDegreesPerKm(points, stepM: stepM);
    return (100 * (1 - math.exp(-dpk / 300))).clamp(0, 100).toDouble();
  }

  /// D+ / D− avec hystérésis pour ignorer le bruit d'altitude.
  static ElevationStats elevationStats(List<double> elevations, {double hysteresisM = 3}) {
    final values = elevations.where((e) => e.isFinite).toList();
    if (values.isEmpty) return ElevationStats.empty;
    var gain = 0.0, loss = 0.0;
    var ref = values.first;
    var minV = ref, maxV = ref;
    for (final e in values.skip(1)) {
      minV = math.min(minV, e);
      maxV = math.max(maxV, e);
      final d = e - ref;
      if (d >= hysteresisM) {
        gain += d;
        ref = e;
      } else if (-d >= hysteresisM) {
        loss += -d;
        ref = e;
      }
    }
    return ElevationStats(gainM: gain, lossM: loss, minM: minV, maxM: maxV);
  }

  /// Platitude 0–100 (100 = billard).
  static double flatnessScore(double gainM, double distanceM) {
    if (distanceM <= 0) return 100;
    final perKm = gainM / (distanceM / 1000);
    return (100 * math.exp(-perKm / 10)).clamp(0, 100).toDouble();
  }

  /// Grimpette 0–100 (inverse de la platitude, saturant plus tard).
  static double climbScore(double gainM, double distanceM) {
    if (distanceM <= 0) return 0;
    final perKm = gainM / (distanceM / 1000);
    return (100 * (1 - math.exp(-perKm / 15))).clamp(0, 100).toDouble();
  }

  /// Rapidité 0–100 d'après la moyenne prévue (40 km/h → 0, 85 km/h → 100).
  static double speedScore(double avgKmh) => ((avgKmh - 40) / 45 * 100).clamp(0, 100).toDouble();

  /// Points de passage ciblés (forêts/cols) atteints : 0 → 0, 2+ → 100.
  static double poiScore(int count) => (count / 2 * 100).clamp(0, 100).toDouble();

  /// Pénalité (en points) si la distance s'écarte de la cible.
  static double distancePenalty(double distanceM, double? targetM) {
    if (targetM == null || targetM <= 0) return 0;
    final dev = (distanceM - targetM).abs() / targetM;
    return math.min(40, dev * 100) * 0.6;
  }

  /// Adéquation 0–100 entre l'itinéraire et le style demandé.
  static double styleFit(RouteStyle style, RouteMetrics m, {double? targetDistanceM}) {
    final curv = m.curvature;
    final speed = speedScore(m.avgSpeedKmh);
    final gain = m.elevationGainM;
    final climb = gain == null ? 50.0 : climbScore(gain, m.distanceM);
    final flat = gain == null ? 50.0 : flatnessScore(gain, m.distanceM);
    final poi = poiScore(m.poiCount);
    final base = switch (style) {
      RouteStyle.sinueux => 0.85 * curv + 0.15 * (100 - speed),
      RouteStyle.foret => 0.55 * poi + 0.45 * curv,
      RouteStyle.cols => 0.45 * poi + 0.35 * climb + 0.2 * curv,
      RouteStyle.plat => 0.7 * flat + 0.3 * (100 - speed),
      RouteStyle.rapide => 0.75 * speed + 0.25 * (100 - curv),
      RouteStyle.mixte => 0.45 * curv + 0.25 * climb + 0.3 * (100 - (speed - 50).abs() * 2).clamp(0, 100),
    };
    final penalty = distancePenalty(m.distanceM, targetDistanceM);
    return (base - penalty).clamp(0, 100).toDouble();
  }

  /// Badges lisibles, du plus parlant au moins parlant (max [max]).
  static List<RouteBadge> badges(RouteMetrics m, {RouteStyle? style, int max = 4}) {
    final out = <RouteBadge>[];
    if (m.curvature >= 65) {
      out.add(const RouteBadge('Très sinueux', BadgeKind.curvy));
    } else if (m.curvature >= 40) {
      out.add(const RouteBadge('Sinueux', BadgeKind.curvy));
    } else if (m.curvature < 15 && m.distanceM > 0) {
      out.add(const RouteBadge('Tout droit', BadgeKind.straight));
    }
    if (style == RouteStyle.foret && m.poiCount > 0) {
      out.add(RouteBadge(m.poiCount == 1 ? '1 forêt' : '${m.poiCount} forêts', BadgeKind.forest));
    }
    if (style == RouteStyle.cols && m.poiCount > 0) {
      out.add(RouteBadge(m.poiCount == 1 ? '1 col' : '${m.poiCount} cols', BadgeKind.pass));
    }
    final gain = m.elevationGainM;
    final perKm = m.gainPerKm;
    if (gain != null && perKm != null) {
      if (perKm < 6) {
        out.add(const RouteBadge('Plutôt plat', BadgeKind.flat));
      } else if (gain >= 150) {
        out.add(RouteBadge('+${formatMeters(gain)} m D+', BadgeKind.climb));
      }
      if (perKm >= 20 && gain >= 150) {
        out.add(const RouteBadge('Ça grimpe', BadgeKind.climb));
      }
    }
    final avg = m.avgSpeedKmh;
    if (avg >= 70) {
      out.add(const RouteBadge('Rapide', BadgeKind.fast));
    } else if (avg > 0 && avg < 45) {
      out.add(const RouteBadge('Tranquille', BadgeKind.calm));
    }
    if (m.hasHighway) out.add(const RouteBadge('Un bout d\'autoroute', BadgeKind.highway));
    return out.take(max).toList();
  }

  /// « 1 250 » (arrondi à la dizaine, espace fine insécable).
  static String formatMeters(double m) {
    final v = (m / 10).round() * 10;
    final s = v.toString();
    final sb = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) sb.write(' ');
      sb.write(s[i]);
    }
    return sb.toString();
  }

  /// Distances d'échantillonnage le long d'une ligne : pas ≈ [stepM], au plus
  /// [maxPoints] points (extrémités incluses).
  static List<double> sampleDistances(double totalM, {double stepM = 1000, int maxPoints = 300}) {
    if (totalM <= 0) return const [0];
    var step = stepM;
    if (totalM / step + 1 > maxPoints) step = totalM / (maxPoints - 1);
    final out = <double>[];
    for (var d = 0.0; d < totalM - step * 0.3; d += step) {
      out.add(d);
    }
    out.add(totalM);
    return out;
  }
}
