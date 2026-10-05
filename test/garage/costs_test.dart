import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/features/garage/costs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 15, 12);
  const bike = Bike(id: 'b', name: 'MT-07', odometerKm: 11000);

  test('répartition, coût au km et mois', () {
    final s = computeBikeCosts(
      bike: bike,
      fuel: [
        FuelEntry(id: 'f1', date: DateTime(2026, 9, 2), liters: 10, pricePerLiter: 2, odometerKm: 10000),
        FuelEntry(id: 'f2', date: DateTime(2026, 10, 3), liters: 12, pricePerLiter: 1.5, odometerKm: 10500),
      ],
      expenses: [
        Expense(id: 'e1', date: DateTime(2026, 10, 4), amount: 15, category: ExpenseCategory.peage),
        Expense(id: 'e2', date: DateTime(2026, 10, 5), amount: 40, category: ExpenseCategory.entretien),
      ],
      logs: [
        MaintenanceLog(id: 'l1', itemId: 'i', bikeId: 'b', date: DateTime(2026, 8, 1), cost: 85, odometerKm: 9800),
        MaintenanceLog(id: 'l2', itemId: 'i', bikeId: 'b', date: DateTime(2026, 8, 2)),
      ],
      ridesKm: 700,
      now: now,
    );
    expect(s.total.fuel, closeTo(38, 1e-9));
    expect(s.total.expenses, 15);
    expect(s.total.maintenance, 125);
    expect(s.total.total, closeTo(178, 1e-9));
    expect(s.liters, 22);
    // compteur : 9 800 → 11 000 = 1 200 km > 700 km de balades
    expect(s.km, 1200);
    expect(s.perKm, closeTo(178 / 1200, 1e-9));
    expect(s.fuelPerKm, closeTo(38 / 1200, 1e-9));
    expect(s.months, hasLength(12));
    expect(s.months.last.month, DateTime(2026, 10));
    expect(s.months.first.month, DateTime(2025, 11));
    expect(s.months.last.costs.total, closeTo(18 + 15 + 40, 1e-9));
    expect(s.months[s.months.length - 3].costs.maintenance, 85);
    expect(s.monthlyAverage, closeTo(178 / 3, 1e-9));
  });

  test('pas assez de km : pas de coût au km', () {
    final s = computeBikeCosts(
      bike: const Bike(id: 'b', name: 'x'),
      fuel: [FuelEntry(id: 'f', date: DateTime(2026, 10, 1), liters: 10, pricePerLiter: 2)],
      expenses: const [],
      logs: const [],
      ridesKm: 20,
      now: now,
    );
    expect(s.perKm, isNull);
    expect(s.km, 20);
  });

  test('derniers mois à cheval sur une année', () {
    final m = lastMonths(DateTime(2026, 2, 10), 4);
    expect(m, [DateTime(2025, 11), DateTime(2025, 12), DateTime(2026, 1), DateTime(2026, 2)]);
  });
}
