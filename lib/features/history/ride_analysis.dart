// Logique pure du détail d'une balade : séries pour les graphes, coloration
// de la trace, coût de la balade, « Refaire cette balade ».
import 'dart:math' as math;

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../data/models/garage.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/ride.dart';

/// Point d'une série en fonction de la distance.
class SeriesPoint {
  const SeriesPoint(this.km, this.value);

  final double km;
  final double value;

  @override
  String toString() => 'SeriesPoint($km, $value)';
}

/// Séries sous-échantillonnées d'une balade.
class RideSeries {
  const RideSeries({required this.speed, required this.lean, required this.altitude, required this.totalKm});

  static const empty = RideSeries(speed: [], lean: [], altitude: [], totalKm: 0);

  /// Vitesse (km/h) moyenne par tronçon (arrêts exclus).
  final List<SeriesPoint> speed;

  /// Angle signé (négatif = gauche) : valeur la plus forte du tronçon.
  final List<SeriesPoint> lean;

  /// Altitude moyenne (m) ; vide si inconnue.
  final List<SeriesPoint> altitude;
  final double totalKm;

  bool get hasLean => lean.any((p) => p.value.abs() >= 1);
  bool get hasAltitude => altitude.length >= 2;
}

/// Construit les séries vitesse / angle / altitude en fonction de la distance,
/// sous-échantillonnées en [maxPoints] tronçons de distance égale.
RideSeries buildRideSeries(List<TrackPoint> points, {int maxPoints = 240}) {
  if (points.length < 2) return RideSeries.empty;
  final cum = Geo.cumulativeDistances([for (final p in points) p.point]);
  final totalKm = cum.last / 1000;
  if (totalKm <= 0) return RideSeries.empty;
  final buckets = math.max(1, math.min(maxPoints, points.length));
  final step = totalKm / buckets;

  final speedSum = List<double>.filled(buckets, 0);
  final speedN = List<int>.filled(buckets, 0);
  final leanExt = List<double>.filled(buckets, 0);
  final altSum = List<double>.filled(buckets, 0);
  final altN = List<int>.filled(buckets, 0);
  final seen = List<bool>.filled(buckets, false);

  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    final b = math.min(buckets - 1, (cum[i] / 1000 / step).floor());
    seen[b] = true;
    final v = p.speedKmh;
    if (v >= 2) {
      speedSum[b] += v;
      speedN[b]++;
    }
    if (p.leanDeg.abs() > leanExt[b].abs()) leanExt[b] = p.leanDeg;
    final alt = p.altitude;
    if (alt != null && alt.isFinite) {
      altSum[b] += alt;
      altN[b]++;
    }
  }

  final speed = <SeriesPoint>[];
  final lean = <SeriesPoint>[];
  final altitude = <SeriesPoint>[];
  for (var b = 0; b < buckets; b++) {
    if (!seen[b]) continue;
    final km = (b + 0.5) * step;
    speed.add(SeriesPoint(km, speedN[b] == 0 ? 0 : speedSum[b] / speedN[b]));
    lean.add(SeriesPoint(km, leanExt[b]));
    if (altN[b] > 0) altitude.add(SeriesPoint(km, altSum[b] / altN[b]));
  }
  return RideSeries(speed: speed, lean: lean, altitude: altitude, totalKm: totalKm);
}

/// Histogramme du temps (s) par tranche de 10° d'angle, calculé depuis les points
/// (repli quand les stats enregistrées n'en ont pas).
Map<int, int> leanHistogramFromPoints(List<TrackPoint> points) {
  final out = <int, int>{};
  for (var i = 1; i < points.length; i++) {
    final dt = points[i].time.difference(points[i - 1].time).inMilliseconds / 1000;
    if (dt <= 0 || dt > 10 || points[i].speedKmh < 5) continue;
    final bucket = (points[i].leanDeg.abs() ~/ 10) * 10;
    out[bucket] = (out[bucket] ?? 0) + dt.round();
  }
  return Map.fromEntries(out.entries.where((e) => e.value > 0).toList()..sort((a, b) => a.key.compareTo(b.key)));
}

// -----------------------------------------------------------------------------
// Coloration de la trace

/// Seuils d'angle alignés sur `CmColors.forLean` (0–15, 15–30, 30–40, 40–48, 48+).
const leanBucketThresholds = [15.0, 30.0, 40.0, 48.0];

/// Seuils de vitesse (km/h) pour la coloration de la trace.
const speedBucketThresholds = [50.0, 80.0, 110.0, 130.0];

int bucketFor(double value, List<double> thresholds) {
  for (var i = 0; i < thresholds.length; i++) {
    if (value < thresholds[i]) return i;
  }
  return thresholds.length;
}

/// Morceau de trace d'une même couleur.
class ColoredRun {
  const ColoredRun(this.bucket, this.points);

  final int bucket;
  final List<GeoPoint> points;
}

/// Découpe la trace en morceaux contigus de même tranche. Les morceaux partagent
/// leur point de jonction pour que la ligne reste continue. La trace est
/// d'abord allégée à [maxPoints] points (on garde la valeur la plus forte).
List<ColoredRun> colorRuns(
  List<TrackPoint> points,
  double Function(TrackPoint p) value,
  List<double> thresholds, {
  int maxPoints = 1500,
}) {
  if (points.length < 2) return const [];
  final step = math.max(1, (points.length / maxPoints).ceil());
  final pts = <GeoPoint>[];
  final buckets = <int>[];
  for (var i = 0; i < points.length; i += step) {
    var v = 0.0;
    for (var j = i; j < math.min(points.length, i + step); j++) {
      v = math.max(v, value(points[j]));
    }
    pts.add(points[i].point);
    buckets.add(bucketFor(v, thresholds));
  }
  if (pts.last != points.last.point) {
    pts.add(points.last.point);
    buckets.add(buckets.last);
  }
  final runs = <ColoredRun>[];
  var start = 0;
  for (var i = 1; i <= pts.length; i++) {
    if (i == pts.length || buckets[i] != buckets[start]) {
      final end = math.min(i, pts.length - 1);
      final seg = pts.sublist(start, end + 1);
      if (seg.length >= 2) runs.add(ColoredRun(buckets[start], seg));
      start = i;
    }
  }
  return runs;
}

// -----------------------------------------------------------------------------
// Coût de la balade

class RideCost {
  const RideCost({required this.fuel, required this.expenses, required this.distanceKm, this.estimatedFuel});

  final List<FuelEntry> fuel;
  final List<Expense> expenses;
  final double distanceKm;

  /// Essence estimée (conso × prix) quand aucun plein n'est lié à la balade.
  final double? estimatedFuel;

  double get fuelTotal => fuel.fold<double>(0, (s, f) => s + f.total);
  double get expensesTotal => expenses.fold<double>(0, (s, e) => s + e.amount);

  /// L'essence est estimée (aucun plein lié).
  bool get fuelIsEstimated => fuel.isEmpty && (estimatedFuel ?? 0) > 0;

  double get fuelForTotal => fuel.isNotEmpty ? fuelTotal : (estimatedFuel ?? 0);
  double get total => fuelForTotal + expensesTotal;

  double? get perKm => distanceKm >= 1 && total > 0 ? total / distanceKm : null;

  double perPerson(int riders) => riders <= 1 ? total : total / riders;

  bool get isEmpty => fuel.isEmpty && expenses.isEmpty && !fuelIsEstimated;
}

/// Coût d'une balade : pleins et dépenses liés, et une estimation de l'essence
/// (km × conso × prix) si aucun plein n'a été saisi.
RideCost computeRideCost({
  required List<FuelEntry> fuel,
  required List<Expense> expenses,
  required double distanceKm,
  double? consumptionL100,
  double? pricePerLiter,
}) {
  double? estimate;
  if (fuel.isEmpty && distanceKm > 0 && (consumptionL100 ?? 0) > 0 && (pricePerLiter ?? 0) > 0) {
    estimate = distanceKm * consumptionL100! / 100 * pricePerLiter!;
  }
  return RideCost(fuel: fuel, expenses: expenses, distanceKm: distanceKm, estimatedFuel: estimate);
}

// -----------------------------------------------------------------------------
// Refaire cette balade

/// Type de tracé deviné d'après les stats de la balade.
RouteStyle guessRouteStyle(RideStats s) {
  final km = s.distanceKm;
  if (km < 1) return RouteStyle.mixte;
  final gainPerKm = s.elevationGainM / km;
  final curvesPer100 = s.curveCount / km * 100;
  if (gainPerKm >= 25) return RouteStyle.cols;
  if (curvesPer100 >= 60) return RouteStyle.sinueux;
  if (s.avgMovingSpeedKmh >= 85 && curvesPer100 < 25) return RouteStyle.rapide;
  if (gainPerKm < 6 && curvesPer100 < 25) return RouteStyle.plat;
  return RouteStyle.mixte;
}

/// Balade planifiée (source « enregistrée ») à partir d'une balade de l'historique.
/// La trace est simplifiée (~10 m) ; à défaut, l'aperçu enregistré est utilisé.
PlannedRoute plannedRouteFromRide(Ride ride, List<TrackPoint> track, {required String id, required DateTime now}) {
  final raw = track.isNotEmpty ? [for (final p in track) p.point] : ride.previewPoints;
  final points = raw.length > 2 ? Geo.simplify(raw, 10) : List.of(raw);
  final length = points.length >= 2 ? Geo.length(points) : ride.stats.distanceM;
  final waypoints = points.length >= 2 ? Geo.resample(points, math.max(5000, length / 12)) : points;
  final s = ride.stats;
  final curvesPer100 = s.distanceKm > 0 ? s.curveCount / s.distanceKm * 100 : 0.0;
  return PlannedRoute(
    id: id,
    name: ride.name,
    createdAt: now.toUtc(),
    points: points,
    style: guessRouteStyle(s),
    source: RouteSource.recorded,
    waypoints: waypoints,
    distanceM: s.distanceM > 0 ? s.distanceM : length,
    durationS: s.movingTimeS > 0 ? s.movingTimeS : s.totalTimeS,
    curvatureScore: (curvesPer100 * 1.2).clamp(0, 100).toDouble(),
    elevationGainM: s.elevationGainM,
    description: 'Balade enregistrée le ${Fmt.date(ride.startedAt)} · ${Fmt.distance(s.distanceM)}',
  );
}

/// Nom de fichier sûr pour un export (« Tour du Vercors » → « tour-du-vercors »).
String safeFileName(String name, {String fallback = 'balade'}) {
  const accents = {
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'á': 'a',
    'ç': 'c',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'î': 'i',
    'ï': 'i',
    'í': 'i',
    'ô': 'o',
    'ö': 'o',
    'ó': 'o',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ú': 'u',
    'ÿ': 'y',
    'ñ': 'n',
    'œ': 'oe',
    'æ': 'ae',
  };
  final lower = name.toLowerCase().split('').map((c) => accents[c] ?? c).join();
  final slug = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.isEmpty) return fallback;
  return slug.length > 60 ? slug.substring(0, 60) : slug;
}
