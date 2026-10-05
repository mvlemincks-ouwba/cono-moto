// Logique pure de l'historique : totaux, regroupement par mois, statistiques globales.
import 'dart:math' as math;

import '../../data/models/ride.dart';

DateTime _monthOf(DateTime d) {
  final l = d.toLocal();
  return DateTime(l.year, l.month);
}

/// Totaux affichés en tête de l'historique.
class HistoryTotals {
  const HistoryTotals({
    required this.kmThisMonth,
    required this.kmThisYear,
    required this.rideCount,
    required this.movingTime,
    required this.totalKm,
  });

  final double kmThisMonth;
  final double kmThisYear;
  final int rideCount;
  final Duration movingTime;
  final double totalKm;

  double get hours => movingTime.inSeconds / 3600;
}

HistoryTotals computeHistoryTotals(List<Ride> rides, {required DateTime now}) {
  final local = now.toLocal();
  var month = 0.0, year = 0.0, total = 0.0;
  var seconds = 0;
  for (final r in rides) {
    final d = r.startedAt.toLocal();
    final km = r.stats.distanceKm;
    total += km;
    seconds += r.stats.movingTimeS;
    if (d.year == local.year) {
      year += km;
      if (d.month == local.month) month += km;
    }
  }
  return HistoryTotals(
    kmThisMonth: month,
    kmThisYear: year,
    rideCount: rides.length,
    movingTime: Duration(seconds: seconds),
    totalKm: total,
  );
}

/// Balades d'un même mois.
class RideMonthGroup {
  const RideMonthGroup({required this.month, required this.rides});

  /// Premier jour du mois (heure locale).
  final DateTime month;

  /// Balades du mois, de la plus récente à la plus ancienne.
  final List<Ride> rides;

  double get totalKm => rides.fold<double>(0, (s, r) => s + r.stats.distanceKm);
}

/// Regroupe les balades par mois (le plus récent d'abord).
List<RideMonthGroup> groupRidesByMonth(List<Ride> rides) {
  final sorted = List.of(rides)..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  final groups = <RideMonthGroup>[];
  for (final r in sorted) {
    final m = _monthOf(r.startedAt);
    if (groups.isEmpty || groups.last.month != m) {
      groups.add(RideMonthGroup(month: m, rides: [r]));
    } else {
      groups.last.rides.add(r);
    }
  }
  return groups;
}

/// Km parcourus sur un mois.
class MonthKm {
  const MonthKm(this.month, this.km);

  final DateTime month;
  final double km;
}

/// Côté où le motard penche le plus.
enum LeanSide { left, right, balanced, unknown }

/// Statistiques globales (écran Stats).
class GlobalRideStats {
  const GlobalRideStats({
    required this.rideCount,
    required this.totalKm,
    required this.movingTime,
    required this.avgSpeedKmh,
    required this.hardBrakes,
    required this.hardBrakesPer100Km,
    required this.elevationGainM,
    required this.curveCount,
    required this.longest,
    required this.mostLeaned,
    required this.fastest,
    required this.mostClimbing,
    required this.leanHistogram,
    required this.kmPerMonth,
    required this.maxLeanLeftDeg,
    required this.maxLeanRightDeg,
    required this.avgMaxLeanLeftDeg,
    required this.avgMaxLeanRightDeg,
    required this.leanSide,
  });

  final int rideCount;
  final double totalKm;
  final Duration movingTime;

  /// Vitesse moyenne globale (distance totale / temps en mouvement total).
  final double avgSpeedKmh;
  final int hardBrakes;
  final double hardBrakesPer100Km;
  final double elevationGainM;
  final int curveCount;

  /// Records.
  final Ride? longest;
  final Ride? mostLeaned;
  final Ride? fastest;
  final Ride? mostClimbing;

  /// Temps (s) cumulé par tranche d'angle (clé = borne basse en degrés).
  final Map<int, int> leanHistogram;

  /// Km par mois sur les derniers mois (du plus ancien au plus récent).
  final List<MonthKm> kmPerMonth;

  /// Angles max absolus à gauche / à droite, toutes balades confondues.
  final double maxLeanLeftDeg;
  final double maxLeanRightDeg;

  /// Moyenne des angles max par balade (plus robuste qu'un record isolé).
  final double avgMaxLeanLeftDeg;
  final double avgMaxLeanRightDeg;
  final LeanSide leanSide;

  bool get isEmpty => rideCount == 0;

  /// Verdict gauche / droite.
  String get leanVerdict => switch (leanSide) {
    LeanSide.right => 'Tu penches plus à droite !',
    LeanSide.left => 'Tu penches plus à gauche !',
    LeanSide.balanced => 'Pile équilibré : autant à gauche qu\'à droite.',
    LeanSide.unknown => 'Pas encore assez de virages enregistrés.',
  };

  /// Part du temps passé dans chaque tranche d'angle (0..1).
  Map<int, double> get leanShare {
    final total = leanHistogram.values.fold<int>(0, (s, v) => s + v);
    if (total == 0) return const {};
    return {for (final e in leanHistogram.entries) e.key: e.value / total};
  }
}

/// Écart (degrés) en dessous duquel on considère gauche et droite équilibrés.
const leanBalanceToleranceDeg = 2.0;

GlobalRideStats computeGlobalStats(List<Ride> rides, {required DateTime now, int months = 12}) {
  var km = 0.0, gain = 0.0;
  var moving = 0, brakes = 0, curves = 0;
  Ride? longest, leaned, fastest, climbing;
  final hist = <int, int>{};
  var maxL = 0.0, maxR = 0.0, sumL = 0.0, sumR = 0.0;
  var nLean = 0;
  final byMonth = <DateTime, double>{};

  for (final r in rides) {
    final s = r.stats;
    km += s.distanceKm;
    moving += s.movingTimeS;
    brakes += s.hardBrakeCount;
    curves += s.curveCount;
    gain += s.elevationGainM;
    if (longest == null || s.distanceM > longest.stats.distanceM) longest = r;
    if (s.maxLeanDeg > 0 && (leaned == null || s.maxLeanDeg > leaned.stats.maxLeanDeg)) leaned = r;
    if (s.maxSpeedKmh > 0 && (fastest == null || s.maxSpeedKmh > fastest.stats.maxSpeedKmh)) fastest = r;
    if (s.elevationGainM > 0 && (climbing == null || s.elevationGainM > climbing.stats.elevationGainM)) {
      climbing = r;
    }
    for (final e in s.leanHistogram.entries) {
      hist[e.key] = (hist[e.key] ?? 0) + e.value;
    }
    if (s.maxLeanLeftDeg > 0 || s.maxLeanRightDeg > 0) {
      maxL = math.max(maxL, s.maxLeanLeftDeg);
      maxR = math.max(maxR, s.maxLeanRightDeg);
      sumL += s.maxLeanLeftDeg;
      sumR += s.maxLeanRightDeg;
      nLean++;
    }
    final m = _monthOf(r.startedAt);
    byMonth[m] = (byMonth[m] ?? 0) + s.distanceKm;
  }

  final avgL = nLean == 0 ? 0.0 : sumL / nLean;
  final avgR = nLean == 0 ? 0.0 : sumR / nLean;
  final LeanSide side;
  if (nLean == 0) {
    side = LeanSide.unknown;
  } else if ((avgR - avgL).abs() < leanBalanceToleranceDeg) {
    side = LeanSide.balanced;
  } else {
    side = avgR > avgL ? LeanSide.right : LeanSide.left;
  }

  final current = _monthOf(now);
  final monthsList = [for (var i = months - 1; i >= 0; i--) DateTime(current.year, current.month - i)];

  return GlobalRideStats(
    rideCount: rides.length,
    totalKm: km,
    movingTime: Duration(seconds: moving),
    avgSpeedKmh: moving > 0 ? km / (moving / 3600) : 0,
    hardBrakes: brakes,
    hardBrakesPer100Km: km > 0 ? brakes / km * 100 : 0,
    elevationGainM: gain,
    curveCount: curves,
    longest: longest,
    mostLeaned: leaned,
    fastest: fastest,
    mostClimbing: climbing,
    leanHistogram: Map.fromEntries(hist.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
    kmPerMonth: [for (final m in monthsList) MonthKm(m, byMonth[m] ?? 0)],
    maxLeanLeftDeg: maxL,
    maxLeanRightDeg: maxR,
    avgMaxLeanLeftDeg: avgL,
    avgMaxLeanRightDeg: avgR,
    leanSide: side,
  );
}
