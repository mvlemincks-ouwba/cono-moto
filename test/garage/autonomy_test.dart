import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/features/garage/autonomy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const bike = Bike(
    id: 'b',
    name: 'Tracer 9',
    tankLiters: 18,
    reserveLiters: 3.5,
    consumptionL100: 6,
    kmSinceFullTank: 100,
  );

  test('litres et km restants, ratio', () {
    final a = computeAutonomy(bike: bike, alertKm: 40);
    // 18 − 100 × 6/100 = 12 L → 200 km
    expect(a.remainingLiters, closeTo(12, 1e-9));
    expect(a.remainingKm, closeTo(200, 1e-9));
    expect(a.fillRatio, closeTo(12 / 18, 1e-9));
    expect(a.low, isFalse);
    expect(a.inReserve, isFalse);
    expect(a.tankLiters, 18);
    expect(a.consumptionL100, 6);
    expect(a.bikeName, 'Tracer 9');
  });

  test('la balade en cours est déduite', () {
    final a = computeAutonomy(bike: bike, rideKm: 150, alertKm: 40);
    // 18 − 250 × 0,06 = 3 L → 50 km, sous la réserve
    expect(a.remainingLiters, closeTo(3, 1e-9));
    expect(a.remainingKm, closeTo(50, 1e-9));
    expect(a.inReserve, isTrue);
    expect(a.low, isFalse);
    expect(computeAutonomy(bike: bike, rideKm: 150, alertKm: 60).low, isTrue);
  });

  test('borné à 0 et au réservoir plein', () {
    final empty = computeAutonomy(bike: bike, rideKm: 5000);
    expect(empty.remainingLiters, 0);
    expect(empty.remainingKm, 0);
    expect(empty.fillRatio, 0);
    expect(empty.low, isTrue);
    final full = computeAutonomy(bike: bike.copyWith(kmSinceFullTank: 0), rideKm: -20);
    expect(full.fillRatio, 1);
    expect(full.remainingKm, closeTo(300, 1e-9));
  });

  test('conso nulle : repli sur 5,5 L/100', () {
    final a = computeAutonomy(bike: bike.copyWith(consumptionL100: 0, kmSinceFullTank: 0));
    expect(a.remainingKm, closeTo(18 / 5.5 * 100, 1e-9));
  });
}
