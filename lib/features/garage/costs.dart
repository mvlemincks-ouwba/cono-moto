// Logique pure : ce que coûte la moto (essence, dépenses, entretien).
import 'dart:math' as math;

import '../../data/models/garage.dart';

/// Répartition d'un coût.
class CostBreakdown {
  const CostBreakdown({this.fuel = 0, this.expenses = 0, this.maintenance = 0});

  final double fuel;
  final double expenses;
  final double maintenance;

  double get total => fuel + expenses + maintenance;

  CostBreakdown operator +(CostBreakdown o) =>
      CostBreakdown(fuel: fuel + o.fuel, expenses: expenses + o.expenses, maintenance: maintenance + o.maintenance);
}

/// Coût d'un mois (heure locale).
class MonthlyCost {
  const MonthlyCost(this.month, this.costs);

  /// Premier jour du mois.
  final DateTime month;
  final CostBreakdown costs;
}

/// Synthèse des coûts d'une moto.
class BikeCostSummary {
  const BikeCostSummary({required this.total, required this.months, required this.km, required this.liters});

  final CostBreakdown total;

  /// Mois les plus récents, du plus ancien au plus récent (mois vides inclus).
  final List<MonthlyCost> months;

  /// Km servant de base au coût au km.
  final double km;

  /// Litres d'essence mis au total.
  final double liters;

  /// Coût au km (essence + dépenses + entretien), null si pas assez de km.
  double? get perKm => km >= 50 && total.total > 0 ? total.total / km : null;

  /// Coût de l'essence au km.
  double? get fuelPerKm => km >= 50 && total.fuel > 0 ? total.fuel / km : null;

  /// Moyenne mensuelle sur les mois ayant au moins une dépense.
  double get monthlyAverage {
    final active = months.where((m) => m.costs.total > 0).toList();
    if (active.isEmpty) return 0;
    return active.fold<double>(0, (s, m) => s + m.costs.total) / active.length;
  }
}

DateTime monthOf(DateTime d) {
  final l = d.toLocal();
  return DateTime(l.year, l.month);
}

/// Les [count] derniers mois jusqu'à [now] inclus, du plus ancien au plus récent.
List<DateTime> lastMonths(DateTime now, int count) {
  final m = monthOf(now);
  return [for (var i = count - 1; i >= 0; i--) DateTime(m.year, m.month - i)];
}

/// Calcule les coûts d'une moto.
///
/// Base kilométrique : le plus grand entre les km des balades enregistrées
/// avec cette moto ([ridesKm]) et l'écart entre le plus petit et le plus grand
/// relevé de compteur connu (pleins, entretiens, compteur actuel).
/// Les dépenses de catégorie « Entretien » comptent dans l'entretien.
BikeCostSummary computeBikeCosts({
  required Bike bike,
  required List<FuelEntry> fuel,
  required List<Expense> expenses,
  required List<MaintenanceLog> logs,
  double ridesKm = 0,
  required DateTime now,
  int months = 12,
}) {
  var total = const CostBreakdown();
  final byMonth = <DateTime, CostBreakdown>{};
  void add(DateTime date, CostBreakdown c) {
    total = total + c;
    final m = monthOf(date);
    byMonth[m] = (byMonth[m] ?? const CostBreakdown()) + c;
  }

  var liters = 0.0;
  for (final f in fuel) {
    liters += f.liters;
    add(f.date, CostBreakdown(fuel: f.total));
  }
  for (final e in expenses) {
    add(
      e.date,
      e.category == ExpenseCategory.entretien
          ? CostBreakdown(maintenance: e.amount)
          : CostBreakdown(expenses: e.amount),
    );
  }
  for (final l in logs) {
    if ((l.cost ?? 0) > 0) add(l.date, CostBreakdown(maintenance: l.cost!));
  }

  final readings = <double>[
    if (bike.odometerKm > 0) bike.odometerKm,
    for (final f in fuel)
      if ((f.odometerKm ?? 0) > 0) f.odometerKm!,
    for (final l in logs)
      if ((l.odometerKm ?? 0) > 0) l.odometerKm!,
  ];
  final span = readings.length >= 2 ? readings.reduce(math.max) - readings.reduce(math.min) : 0.0;

  return BikeCostSummary(
    total: total,
    months: [for (final m in lastMonths(now, months)) MonthlyCost(m, byMonth[m] ?? const CostBreakdown())],
    km: math.max(ridesKm, span),
    liters: liters,
  );
}
