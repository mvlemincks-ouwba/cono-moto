import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/features/history/history_providers.dart';
import 'package:cono_moto/features/history/history_screen.dart';
import 'package:cono_moto/features/history/ride_detail_screen.dart';
import 'package:cono_moto/features/history/stats_screen.dart';
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
        bikesProvider.overrideWith((ref) => Stream.value(const <Bike>[])),
        ...overrides.cast(),
      ],
      child: MaterialApp(theme: CmTheme.dark(), home: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1000));
}

List<TrackPoint> _track() {
  final t0 = DateTime.now().toUtc().subtract(const Duration(days: 1));
  return [
    for (var i = 0; i < 600; i++)
      TrackPoint(
        time: t0.add(Duration(seconds: i)),
        lat: 45 + i * 0.00018,
        lng: 5 + 0.002 * (i % 60 < 30 ? i % 30 : 30 - i % 30),
        speedMs: 15 + (i % 40) / 2,
        leanDeg: (i % 60 < 30 ? -1 : 1) * (i % 30) * 1.4,
        altitude: 400 + i * 0.8,
      ),
  ];
}

/// La carte MapLibre n'a pas de vue native en test : son dispose() lève une
/// LateError (bug de maplibre_gl quand la vue n'a jamais été créée). On démonte
/// l'arbre en ignorant uniquement cette erreur-là.
Future<void> _unmountIgnoringMapLibre(WidgetTester tester) async {
  // Laisse finir les animations (rebond du défilement) avant de démonter.
  await tester.pump(const Duration(seconds: 2));
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = '${details.exception}\n${details.stack}';
    if (text.contains('maplibre') || text.contains('MapLibre')) return;
    original?.call(details);
  };
  try {
    await tester.pumpWidget(const SizedBox());
  } finally {
    FlutterError.onError = original;
  }
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  final now = DateTime.now().toUtc();
  final preview = Geo.encodePolyline([for (final p in _track()) p.point].where((_) => true).toList());
  final rides = [
    Ride(
      id: 'r1',
      name: 'Tour du Vercors par les gorges',
      startedAt: now.subtract(const Duration(days: 1)),
      endedAt: now.subtract(const Duration(days: 1)).add(const Duration(hours: 3)),
      bikeId: 'b',
      previewPolyline: preview,
      stats: const RideStats(
        distanceM: 182400,
        movingTimeS: 9800,
        totalTimeS: 11600,
        maxSpeedKmh: 142,
        maxLeanLeftDeg: 44,
        maxLeanRightDeg: 47,
        hardBrakeCount: 3,
        elevationGainM: 1840,
        curveCount: 312,
        leanHistogram: {0: 4000, 10: 2500, 20: 1800, 30: 900, 40: 120},
      ),
      events: [
        RideEvent(type: 'hard_brake', time: now, lat: 45.02, lng: 5.01, value: 0.6),
        RideEvent(type: 'max_lean', time: now, lat: 45.05, lng: 5.03, value: 47),
      ],
      sharedWithFriends: true,
    ),
    Ride(
      id: 'r2',
      name: 'Petite boucle du soir',
      startedAt: now.subtract(const Duration(days: 45)),
      endedAt: now.subtract(const Duration(days: 45)).add(const Duration(hours: 1)),
      stats: const RideStats(
        distanceM: 64000,
        movingTimeS: 3400,
        maxSpeedKmh: 110,
        maxLeanLeftDeg: 32,
        maxLeanRightDeg: 36,
      ),
    ),
  ];

  for (final size in _sizes.entries) {
    testWidgets('historique vide · ${size.key}', (tester) async {
      await _pump(
        tester,
        const HistoryScreen(),
        size: size.value,
        overrides: [ridesProvider.overrideWith((ref) => Stream.value(const <Ride>[]))],
      );
      expect(find.text('Pas encore de balade'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('historique · ${size.key}', (tester) async {
      await _pump(
        tester,
        const HistoryScreen(),
        size: size.value,
        overrides: [ridesProvider.overrideWith((ref) => Stream.value(rides))],
      );
      expect(find.text('Mes balades'), findsOneWidget);
      expect(find.text('Tour du Vercors par les gorges'), findsOneWidget);
      expect(find.text('47° max'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Petite boucle du soir'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('stats · ${size.key}', (tester) async {
      await _pump(
        tester,
        const StatsScreen(),
        size: size.value,
        overrides: [ridesProvider.overrideWith((ref) => Stream.value(rides))],
      );
      expect(find.text('Mes stats'), findsOneWidget);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('LE PLUS PENCHÉ'), 200, scrollable: list);
      await tester.scrollUntilVisible(find.text('Tu penches plus à droite !'), 200, scrollable: list);
      await tester.scrollUntilVisible(find.text('Km par mois'), 200, scrollable: list);
      expect(tester.takeException(), isNull);
    });

    testWidgets('détail d’une balade · ${size.key}', (tester) async {
      await _pump(
        tester,
        const RideDetailScreen(rideId: 'r1'),
        size: size.value,
        overrides: [
          rideProvider.overrideWith((ref, id) => Stream.value(rides.firstWhere((r) => r.id == id))),
          rideTrackProvider.overrideWith((ref, id) async => _track()),
          rideCostDataProvider.overrideWith(
            (ref, id) => Stream.value(
              RideCostData(
                fuel: [FuelEntry(id: 'f', date: now, liters: 12.4, pricePerLiter: 1.849, rideId: 'r1')],
                expenses: [
                  Expense(id: 'e', date: now, amount: 8.6, category: ExpenseCategory.peage, label: 'A41', rideId: 'r1'),
                ],
                lastPrice: 1.849,
              ),
            ),
          ),
        ],
      );
      expect(find.text('Tour du Vercors par les gorges'), findsWidgets);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Vitesse'), 200, scrollable: list);
      await tester.scrollUntilVisible(find.text('Inclinaison'), 200, scrollable: list);
      await tester.scrollUntilVisible(find.text('Répartition des angles'), 200, scrollable: list);
      await tester.scrollUntilVisible(find.text('TOTAL'), 200, scrollable: list);
      expect(find.text('A41'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Refaire cette balade'), 200, scrollable: list);
      await tester.scrollUntilVisible(find.text("Partager l'image"), 200, scrollable: list);
      expect(find.text('GPX'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmountIgnoringMapLibre(tester);
    });
  }

  testWidgets('détail d’une balade : « Partager l’image » dans le menu', (tester) async {
    await _pump(
      tester,
      const RideDetailScreen(rideId: 'r1'),
      size: _sizes.values.first,
      overrides: [
        rideProvider.overrideWith((ref, id) => Stream.value(rides.firstWhere((r) => r.id == id))),
        rideTrackProvider.overrideWith((ref, id) async => _track()),
        rideCostDataProvider.overrideWith((ref, id) => Stream.value(const RideCostData(fuel: [], expenses: []))),
      ],
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.widgetWithText(PopupMenuItem<String>, "Partager l'image"), findsOneWidget);
    expect(find.widgetWithText(PopupMenuItem<String>, 'Exporter en GPX'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Ferme le menu sans rien choisir.
    await tester.tapAt(const Offset(4, 4));
    await tester.pump(const Duration(milliseconds: 400));
    await _unmountIgnoringMapLibre(tester);
  });
}
