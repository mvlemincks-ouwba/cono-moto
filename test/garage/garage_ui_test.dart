import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/features/garage/garage_providers.dart';
import 'package:cono_moto/features/garage/garage_screen.dart';
import 'package:cono_moto/features/garage/widgets/fuel_gauge.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

class _IdleRide extends RideController {
  @override
  RideSessionState build() => const RideSessionState();
}

const _sizes = <String, Size>{'petit téléphone': Size(360, 640), 'téléphone': Size(393, 852)};

Future<void> _pump(WidgetTester tester, Widget child, {required Size size, List<Object> overrides = const []}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        rideControllerProvider.overrideWith(_IdleRide.new),
        ...overrides.cast(),
      ],
      child: MaterialApp(theme: CmTheme.dark(), home: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1000));
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  final now = DateTime.now().toUtc();
  const bike = Bike(
    id: 'b',
    name: 'La Bleue',
    brand: 'Yamaha',
    model: 'Tracer 9 GT',
    year: 2023,
    odometerKm: 18432,
    tankLiters: 18,
    reserveLiters: 3.5,
    consumptionL100: 5.6,
    colorValue: 0xFF4EA8FF,
    isDefault: true,
    kmSinceFullTank: 190,
  );
  final data = BikeGarageData(
    fuel: [
      FuelEntry(
        id: 'f2',
        date: now.subtract(const Duration(days: 2)),
        liters: 14.2,
        pricePerLiter: 1.849,
        bikeId: 'b',
        odometerKm: 18240,
        stationName: '12 Avenue de la Gare, Grenoble',
      ),
      FuelEntry(
        id: 'f1',
        date: now.subtract(const Duration(days: 20)),
        liters: 15.1,
        pricePerLiter: 1.899,
        bikeId: 'b',
        odometerKm: 17990,
      ),
    ],
    expenses: [
      Expense(
        id: 'e1',
        date: now.subtract(const Duration(days: 3)),
        amount: 8.6,
        category: ExpenseCategory.peage,
        label: 'A41',
        bikeId: 'b',
        rideId: 'r1',
      ),
      Expense(
        id: 'e2',
        date: now.subtract(const Duration(days: 40)),
        amount: 189,
        category: ExpenseCategory.entretien,
        label: 'Kit chaîne',
        bikeId: 'b',
      ),
    ],
    items: [
      MaintenanceItem(
        id: 'm1',
        bikeId: 'b',
        type: MaintenanceType.chaine,
        intervalKm: 600,
        lastDoneKm: 17800,
        lastDoneDate: now.subtract(const Duration(days: 30)),
      ),
      MaintenanceItem(
        id: 'm2',
        bikeId: 'b',
        type: MaintenanceType.vidange,
        intervalKm: 6000,
        intervalMonths: 12,
        lastDoneKm: 15000,
        lastDoneDate: now.subtract(const Duration(days: 200)),
      ),
      MaintenanceItem(
        id: 'm3',
        bikeId: 'b',
        type: MaintenanceType.pneuArriere,
        intervalKm: 9000,
        lastDoneKm: 10000,
        lastDoneDate: now.subtract(const Duration(days: 300)),
      ),
    ],
    logs: [
      MaintenanceLog(
        id: 'l1',
        itemId: 'm2',
        bikeId: 'b',
        date: now.subtract(const Duration(days: 200)),
        cost: 95,
        odometerKm: 15000,
      ),
    ],
    ridesKm: 2400,
  );

  for (final size in _sizes.entries) {
    testWidgets('garage vide · ${size.key}', (tester) async {
      await _pump(
        tester,
        const GarageScreen(),
        size: size.value,
        overrides: [bikesProvider.overrideWith((ref) => Stream.value(const <Bike>[]))],
      );
      expect(find.text('Ajoute ta moto'), findsOneWidget);
      expect(find.text('Ajouter ma moto'), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('garage avec une moto · ${size.key}', (tester) async {
      await _pump(
        tester,
        const GarageScreen(),
        size: size.value,
        overrides: [
          bikesProvider.overrideWith((ref) => Stream.value(const [bike])),
          bikeGarageDataProvider.overrideWith((ref, id) => Stream.value(data)),
        ],
      );
      expect(find.text('La Bleue'), findsOneWidget);
      expect(find.text('COMPTEUR'), findsOneWidget);
      expect(find.byType(FuelGauge), findsOneWidget);
      // 18 − 190 × 5,6/100 = 7,36 L → 131 km
      expect(find.text('131'), findsOneWidget);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Pneu arrière'), 200, scrollable: list);
      expect(find.text('À faire'), findsWidgets);
      expect(find.text('Bientôt'), findsWidgets);
      expect(find.text('2 entretiens à prévoir'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('AU KILOMÈTRE'), 200, scrollable: list);
      await tester.scrollUntilVisible(find.text('Kit chaîne'), 300, scrollable: list);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('jauge compacte et cadran', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CmTheme.dark(),
        home: const Scaffold(
          body: Column(
            children: [
              FuelGauge(ratio: 0.12, remainingKm: 28, low: true),
              FuelGauge(ratio: 0.7, remainingKm: 210, compact: true, size: 40),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('28'), findsOneWidget);
    expect(find.text('210'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
