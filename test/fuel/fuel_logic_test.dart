import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/data/models/shared.dart';
import 'package:cono_moto/features/fuel/fuel_logic.dart';
import 'package:cono_moto/features/fuel/navigation_links.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime.utc(2026, 10, 5, 12);

FuelStation station(String id, {double? sp98, double? e10, double dist = 1000, DateTime? maj, Set<FuelType>? off}) =>
    FuelStation(
      id: id,
      location: const GeoPoint(45, 5),
      address: 'Adresse $id',
      city: 'Ville',
      prices: {FuelType.sp98: ?sp98, FuelType.e10: ?e10},
      updatedAt: {FuelType.sp98: maj ?? now.subtract(const Duration(hours: 2))},
      unavailable: off ?? const {},
      distanceM: dist,
    );

FuelEntry fuel(String id, DateTime date, double liters, {bool full = true, double? odo, double price = 1.8}) =>
    FuelEntry(id: id, date: date, liters: liters, pricePerLiter: price, bikeId: 'b', odometerKm: odo, fullTank: full);

void main() {
  group('fraîcheur des prix', () {
    test('frais / récent / périmé / inconnu', () {
      expect(priceFreshness(now.subtract(const Duration(hours: 3)), now: now), PriceFreshness.fresh);
      expect(priceFreshness(now.subtract(const Duration(days: 2)), now: now), PriceFreshness.recent);
      expect(priceFreshness(now.subtract(const Duration(days: 4)), now: now), PriceFreshness.stale);
      expect(priceFreshness(null, now: now), PriceFreshness.unknown);
      expect(isPriceStale(now.subtract(const Duration(days: 3, hours: 1)), now: now), isTrue);
    });
  });

  group('résumé des prix', () {
    test('moins cher, moyenne, économie', () {
      final entries = [
        StationEntry(station('a', sp98: 1.90, dist: 500)),
        StationEntry(station('b', sp98: 1.80, dist: 3000)),
        StationEntry(station('c', sp98: 1.85, dist: 1000)),
        StationEntry(station('d', e10: 1.70)),
      ];
      final s = summarizePrices(entries, FuelType.sp98, now: now)!;
      expect(s.count, 3);
      expect(s.min, 1.80);
      expect(s.max, 1.90);
      expect(s.average, closeTo(1.85, 1e-9));
      expect(s.cheapest.station.id, 'b');
      expect(s.savingPerLiter(1.80), closeTo(0.05, 1e-9));
      expect(s.savingFor(1.80, 15), closeTo(0.75, 1e-9));
    });

    test('à prix égal, la plus proche gagne', () {
      final s = summarizePrices(
        [StationEntry(station('loin', sp98: 1.80, dist: 5000)), StationEntry(station('pres', sp98: 1.80, dist: 800))],
        FuelType.sp98,
        now: now,
      )!;
      expect(s.cheapest.station.id, 'pres');
    });

    test('les prix périmés sont écartés s’il reste des prix frais', () {
      final s = summarizePrices(
        [
          StationEntry(station('vieux', sp98: 1.50, maj: now.subtract(const Duration(days: 10)))),
          StationEntry(station('frais', sp98: 1.85)),
        ],
        FuelType.sp98,
        now: now,
      )!;
      expect(s.cheapest.station.id, 'frais');
      expect(s.count, 1);
    });

    test('rupture → ignoré ; aucun prix → null', () {
      expect(
        summarizePrices(
          [
            StationEntry(station('a', sp98: 1.8, off: {FuelType.sp98})),
          ],
          FuelType.sp98,
          now: now,
        ),
        isNull,
      );
    });
  });

  group('tri des stations', () {
    final entries = [
      StationEntry(station('cher-proche', sp98: 1.95, dist: 300)),
      StationEntry(station('sans-prix', dist: 100)),
      StationEntry(station('pas-cher-loin', sp98: 1.75, dist: 8000)),
      StationEntry(station('moyen', sp98: 1.85, dist: 2000)),
    ];

    test('par prix (sans prix à la fin)', () {
      expect(sortStations(entries, FuelType.sp98, StationSort.price).map((e) => e.station.id), [
        'pas-cher-loin',
        'moyen',
        'cher-proche',
        'sans-prix',
      ]);
    });

    test('par distance', () {
      expect(sortStations(entries, FuelType.sp98, StationSort.distance).map((e) => e.station.id), [
        'sans-prix',
        'cher-proche',
        'moyen',
        'pas-cher-loin',
      ]);
    });

    test('dans l’ordre du trajet, détour comme proximité', () {
      final route = [
        StationEntry(station('km50', sp98: 1.8), distanceAlongM: 50000, offRouteM: 200),
        StationEntry(station('km10', sp98: 1.9), distanceAlongM: 10000, offRouteM: 2500),
      ];
      expect(sortStations(route, FuelType.sp98, StationSort.route).first.station.id, 'km10');
      expect(sortStations(route, FuelType.sp98, StationSort.distance).first.station.id, 'km50');
      expect(route[1].detourM, 5000);
      expect(route[1].onRoute, isTrue);
    });

    test('arrondi de la position de recherche', () {
      expect(roundForStationQuery(const GeoPoint(45.18779, 5.72449)), const GeoPoint(45.19, 5.72));
    });
  });

  group('saisie d’un plein', () {
    test('total dans les deux sens', () {
      expect(fuelTotal(12.5, 1.8), closeTo(22.5, 1e-9));
      expect(litersFromTotal(22.5, 1.8), closeTo(12.5, 1e-9));
      expect(priceFromTotal(22.5, 12.5), closeTo(1.8, 1e-9));
      expect(litersFromTotal(10, 0), isNull);
    });

    test('lecture des nombres saisis', () {
      expect(parseUserNumber('12,5'), 12.5);
      expect(parseUserNumber(' 1 234,5 '), 1234.5);
      expect(parseUserNumber('1.849 €'), 1.849);
      expect(parseUserNumber(''), isNull);
      expect(parseUserNumber('abc'), isNull);
    });
  });

  group('consommation plein à plein', () {
    final d0 = DateTime.utc(2026, 9, 1);

    test('premier plein : rien à mesurer', () {
      final e = fuel('1', d0, 14, odo: 10000);
      expect(fullToFullConsumption(entry: e, history: [e]), isNull);
    });

    test('litres depuis le plein complet précédent / km × 100, appoints compris', () {
      final history = [
        fuel('1', d0, 14, odo: 10000),
        fuel('2', d0.add(const Duration(days: 3)), 4, full: false, odo: 10120),
        fuel('3', d0.add(const Duration(days: 7)), 9, odo: 10250),
      ];
      // (4 + 9) L / 250 km = 5,2 L/100
      expect(fullToFullConsumption(entry: history[2], history: history), closeTo(5.2, 1e-9));
    });

    test('repli sur les km depuis le plein si pas de compteur ; trop peu de km → null', () {
      final prev = fuel('1', d0, 14);
      final e = fuel('2', d0.add(const Duration(days: 2)), 11);
      expect(fullToFullConsumption(entry: e, history: [prev, e], kmFallback: 200), closeTo(5.5, 1e-9));
      expect(fullToFullConsumption(entry: e, history: [prev, e], kmFallback: 10), isNull);
      expect(fullToFullConsumption(entry: e, history: [prev, e]), isNull);
    });

    test('appliquer un plein complet : lissage, remise à zéro, compteur', () {
      const bike = Bike(id: 'b', name: 'MT-07', consumptionL100: 5.0, kmSinceFullTank: 240, odometerKm: 10240);
      final history = [fuel('1', d0, 14, odo: 10000)];
      final e = fuel('2', d0.add(const Duration(days: 5)), 15, odo: 10250); // 6 L/100
      final out = applyFuelEntry(bike: bike, entry: e, history: history);
      expect(out.measuredL100, closeTo(6.0, 1e-9));
      expect(out.consumptionUpdated, isTrue);
      expect(out.bike.consumptionL100, closeTo(5.4, 1e-9)); // 5×0,6 + 6×0,4
      expect(out.bike.kmSinceFullTank, 0);
      expect(out.bike.odometerKm, 10250);
    });

    test('plein complet en route : km de la balade reportés avant la mise à zéro', () {
      // 200 km depuis le plein, 50 km de balade avant le plein, compteur saisi
      // (30 050) qui compte déjà ces 50 km.
      const bike = Bike(id: 'b', name: 'GS', consumptionL100: 5.0, kmSinceFullTank: 200, odometerKm: 30000);
      final history = [fuel('1', d0, 18)];
      final e = fuel('2', d0.add(const Duration(days: 1)), 12.5, odo: 30050);
      final out = applyFuelEntry(bike: bike, entry: e, history: history, rideKm: 50);
      expect(out.bike.kmSinceFullTank, 0);
      expect(out.bike.odometerKm, 30050);
      // 12,5 L pour 250 km (200 + 50 de la balade) = 5 L/100.
      expect(out.measuredL100, closeTo(5.0, 1e-9));
      // Sans compteur saisi : le compteur avance quand même des km de balade.
      final noOdo = applyFuelEntry(bike: bike, entry: fuel('3', d0, 12.5), history: const [], rideKm: 50);
      expect(noOdo.bike.odometerKm, 30050);
    });

    test('appoint en route : km de la balade comptés, puis recul de l’équivalent', () {
      const bike = Bike(id: 'b', name: 'GS', consumptionL100: 5.0, kmSinceFullTank: 200, odometerKm: 30000);
      final out = applyFuelEntry(bike: bike, entry: fuel('2', d0, 5, full: false), history: const [], rideKm: 50);
      expect(out.bike.kmSinceFullTank, 150); // 200 + 50 − 100
      expect(out.bike.odometerKm, 30050);
    });

    test('mesure aberrante ignorée (hors 2–15 L/100)', () {
      const bike = Bike(id: 'b', name: 'MT-07', consumptionL100: 5.0, kmSinceFullTank: 50);
      final history = [fuel('1', d0, 14, odo: 10000)];
      final e = fuel('2', d0.add(const Duration(days: 1)), 14, odo: 10050); // 28 L/100
      final out = applyFuelEntry(bike: bike, entry: e, history: history);
      expect(out.measuredL100, closeTo(28, 1e-9));
      expect(out.consumptionUpdated, isFalse);
      expect(out.bike.consumptionL100, 5.0);
      expect(out.bike.kmSinceFullTank, 0);
    });

    test('appoint : recule de l’équivalent en km, pas de mesure', () {
      const bike = Bike(id: 'b', name: 'MT-07', consumptionL100: 5.0, kmSinceFullTank: 200, odometerKm: 5000);
      final e = fuel('2', d0, 5, full: false, odo: 4990);
      final out = applyFuelEntry(bike: bike, entry: e, history: const []);
      expect(out.bike.kmSinceFullTank, 100); // 5 L à 5 L/100 = 100 km
      expect(out.bike.odometerKm, 5000, reason: 'le compteur ne recule jamais');
      expect(out.measuredL100, isNull);
      final big = applyFuelEntry(bike: bike, entry: fuel('3', d0, 50, full: false), history: const []);
      expect(big.bike.kmSinceFullTank, 0);
    });

    test('plein complet sans compteur : km depuis le plein + appoints réintégrés', () {
      // Plein complet, 150 km, appoint de 3 L (kmSinceFull recule de 60 km), 100 km, plein.
      const bike = Bike(id: 'b', name: 'MT-07', consumptionL100: 5.0, kmSinceFullTank: 190);
      final history = [fuel('1', d0, 14), fuel('2', d0.add(const Duration(days: 1)), 3, full: false)];
      final e = fuel('3', d0.add(const Duration(days: 2)), 9.5);
      final out = applyFuelEntry(bike: bike, entry: e, history: history);
      // km réels = 190 + 60 = 250 ; litres = 3 + 9,5 = 12,5 → 5 L/100
      expect(out.measuredL100, closeTo(5.0, 1e-9));
    });

    test('plein saisi après coup : le réservoir n’est pas touché', () {
      const bike = Bike(id: 'b', name: 'MT-07', consumptionL100: 5.0, kmSinceFullTank: 120, odometerKm: 10400);
      final history = [fuel('1', d0, 14, odo: 10000), fuel('3', d0.add(const Duration(days: 10)), 13, odo: 10380)];
      // Plein oublié, entre les deux.
      final late = fuel('2', d0.add(const Duration(days: 5)), 10, odo: 10200);
      final out = applyFuelEntry(bike: bike, entry: late, history: history, now: d0.add(const Duration(days: 12)));
      expect(out.bike.kmSinceFullTank, 120);
      expect(out.measuredL100, closeTo(5.0, 1e-9)); // 10 L / 200 km
      // Dernier plein mais saisi 3 jours après : pas de remise à zéro non plus.
      final old = fuel('4', d0.add(const Duration(days: 11)), 2, full: false);
      final out2 = applyFuelEntry(bike: bike, entry: old, history: history, now: d0.add(const Duration(days: 14)));
      expect(out2.bike.kmSinceFullTank, 120);
      // Saisi sur le moment : remise à zéro.
      final fresh = fuel('5', d0.add(const Duration(days: 12)), 6, odo: 10500);
      final out3 = applyFuelEntry(
        bike: bike,
        entry: fresh,
        history: history,
        now: d0.add(const Duration(days: 12, hours: 1)),
      );
      expect(out3.bike.kmSinceFullTank, 0);
    });

    test('conso par plein et litres à prévoir', () {
      final history = [fuel('1', d0, 14, odo: 10000), fuel('2', d0.add(const Duration(days: 5)), 12, odo: 10200)];
      expect(consumptionPerEntry(history), {'2': closeTo(6.0, 1e-9)});
      const bike = Bike(id: 'b', name: 'x', tankLiters: 15, consumptionL100: 5, kmSinceFullTank: 100);
      expect(litersToFill(bike), 5);
      expect(litersToFill(bike, extraKm: 1000), 15);
    });
  });

  group('liens de navigation', () {
    test('Google Maps deux-roues et Waze', () {
      const p = GeoPoint(45.18779, 5.72449);
      expect(
        googleMapsDirectionsUri(p).toString(),
        'https://www.google.com/maps/dir/?api=1&destination=45.187790,5.724490&travelmode=two-wheeler',
      );
      expect(wazeNavigateUri(p).toString(), 'https://waze.com/ul?ll=45.187790,5.724490&navigate=yes');
      expect(navigationUri(NavApp.waze, p), wazeNavigateUri(p));
    });
  });
}
