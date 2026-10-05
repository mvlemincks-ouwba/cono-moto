import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/data/models/shared.dart';
import 'package:cono_moto/features/fuel/fuel_providers.dart';
import 'package:cono_moto/features/fuel/fuel_ui.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/services/fuel/fuel_price_client.dart';
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

Future<void> _pump(WidgetTester tester, Widget child, {List<Object> overrides = const []}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(360, 720) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        rideControllerProvider.overrideWith(_IdleRide.new),
        ...overrides.cast(),
      ],
      child: MaterialApp(
        theme: CmTheme.dark(),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  final now = DateTime.now().toUtc();
  const here = GeoPoint(45.188, 5.724);
  FuelStation station(String id, double sp98, double dist, {DateTime? maj, bool h24 = false}) => FuelStation(
    id: id,
    location: Geo.destination(here, 45, dist),
    address: 'Station $id, Avenue Alsace-Lorraine',
    city: 'Grenoble',
    postalCode: '38000',
    prices: {FuelType.sp98: sp98, FuelType.gazole: sp98 - 0.15},
    updatedAt: {FuelType.sp98: maj ?? now.subtract(const Duration(hours: 3))},
    open24h: h24,
    unavailable: id == 'c' ? const {FuelType.e10} : const {},
  );
  final stations = [
    station('a', 1.899, 800, h24: true),
    station('b', 1.829, 2600),
    station('c', 1.869, 4100, maj: now.subtract(const Duration(days: 6))),
  ];
  const bike = Bike(
    id: 'b',
    name: 'La Bleue',
    isDefault: true,
    tankLiters: 18,
    consumptionL100: 5.5,
    kmSinceFullTank: 220,
    odometerKm: 18432,
  );

  testWidgets('feuille des stations : moins cher, économie, fraîcheur', (tester) async {
    await _pump(
      tester,
      const FuelStationsSheet(near: here, initialShowMap: false),
      overrides: [
        bikesProvider.overrideWith((ref) => Stream.value(const [bike])),
        stationsAroundProvider.overrideWith((ref, center) async => stations),
      ],
    );
    expect(find.text('Essence autour de toi'), findsOneWidget);
    expect(find.text('Le moins cher'), findsOneWidget);
    expect(find.textContaining('vs la moyenne'), findsOneWidget);
    final list = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(find.textContaining('à vérifier'), 200, scrollable: list);
    // Tri par distance.
    await tester.tap(find.text('Plus proche'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('feuille des stations : erreur réseau en français', (tester) async {
    await _pump(
      tester,
      const FuelStationsSheet(near: here, initialShowMap: false),
      overrides: [
        bikesProvider.overrideWith((ref) => Stream.value(const <Bike>[])),
        stationsAroundProvider.overrideWith(
          (ref, center) async => throw const FuelPriceException('Pas de réseau : impossible de récupérer les prix.'),
        ),
      ],
    );
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Prix indisponibles'), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
  });

  testWidgets('feuille des stations sur le trajet : seulement devant le motard', (tester) async {
    final route = [for (var i = 0; i <= 50; i++) GeoPoint(45, 5 + i * 0.0127)]; // ~50 km vers l'est
    RouteFuelStation onRoute(String id, double alongKm, double price) => RouteFuelStation(
      station: FuelStation(
        id: id,
        location: GeoPoint(45.005, 5 + alongKm / 78.7),
        address: 'Relais $id',
        city: 'Quelque part',
        prices: {FuelType.sp98: price},
        updatedAt: {FuelType.sp98: now},
      ),
      distanceAlongM: alongKm * 1000,
      offRouteM: 550,
    );
    await _pump(
      tester,
      FuelStationsSheet(alongRoute: route, near: route[20], initialShowMap: false),
      overrides: [
        bikesProvider.overrideWith((ref) => Stream.value(const [bike])),
        stationsAlongRouteProvider.overrideWith(
          (ref, key) async => [onRoute('derriere', 5, 1.70), onRoute('devant', 35, 1.85), onRoute('loin', 48, 1.80)],
        ),
      ],
    );
    expect(find.text('Essence sur ton trajet'), findsOneWidget);
    expect(find.text('Relais derriere'), findsNothing);
    expect(find.text('Relais loin'), findsWidgets); // le moins cher devant
    expect(find.textContaining('dans 28'), findsWidgets); // compté depuis le motard (48 − 20 km)
    expect(find.textContaining('détour'), findsWidgets);
    await tester.tap(find.text('Sur le trajet'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('formulaire de plein : prix pré-rempli et total calculé', (tester) async {
    await _pump(
      tester,
      FuelEntryForm(station: stations[1]),
      overrides: [
        bikesProvider.overrideWith((ref) => Stream.value(const [bike])),
      ],
    );
    expect(find.text('Nouveau plein'), findsOneWidget);
    expect(find.text('1,829'), findsOneWidget);
    expect(find.text('18432'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Litres'), '10');
    await tester.pump();
    expect(find.text('18,29'), findsOneWidget);
    // Saisie du total → litres recalculés.
    await tester.enterText(find.widgetWithText(TextField, 'Total payé'), '36,58');
    await tester.pump();
    expect(find.text('20'), findsOneWidget);
    await tester.tap(find.text('Appoint'));
    await tester.pump();
    expect(find.text('Nouvel appoint'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
