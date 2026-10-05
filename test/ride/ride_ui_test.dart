import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/features/garage/autonomy.dart';
import 'package:cono_moto/features/navigation/navigation_providers.dart';
import 'package:cono_moto/features/navigation/navigation_view.dart';
import 'package:cono_moto/features/ride/crash_alert_controller.dart';
import 'package:cono_moto/features/ride/crash_alert_screen.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/features/ride/ride_screen.dart';
import 'package:cono_moto/features/ride/ride_summary_screen.dart';
import 'package:cono_moto/features/ride/widgets/lean_gauge.dart';
import 'package:cono_moto/services/ride/ride_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';
import 'fake_ride_platform.dart';

class _FixedRideController extends RideController {
  _FixedRideController(this.initial);

  final RideSessionState initial;

  @override
  RideSessionState build() => initial;
}

const _sizes = <String, Size>{
  'petit téléphone': Size(360, 640),
  'téléphone': Size(393, 852),
  'paysage': Size(852, 393),
};

final _activeState = RideSessionState(
  status: RideStatus.recording,
  rideId: 'r',
  startedAt: DateTime.utc(2026, 6, 7, 9),
  distanceM: 48250,
  movingTime: const Duration(minutes: 52, seconds: 10),
  elapsed: const Duration(hours: 1, minutes: 4, seconds: 33),
  speedKmh: 87.4,
  maxSpeedKmh: 131,
  avgSpeedKmh: 55.5,
  leanDeg: -38.2,
  maxLeanLeftDeg: 44,
  maxLeanRightDeg: 39,
  hardBrakeCount: 2,
  curveCount: 143,
  gpsAccuracyM: 4,
  leanCalibrated: true,
  leanFromGyro: true,
  lowFuelAlert: true,
  crashDetectionArmed: true,
  track: const [GeoPoint(45, 5), GeoPoint(45.01, 5.01)],
);

Future<void> _pumpApp(
  WidgetTester tester,
  Widget child, {
  required Size size,
  List overrides = const [],
  Map<String, Object> initialPrefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    'settings.emergencyName': 'Julie',
    'settings.emergencyPhone': '0611',
    ...initialPrefs,
  });
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        ridePlatformProvider.overrideWithValue(FakeRidePlatform()),
        defaultBikeProvider.overrideWithValue(null),
        ...overrides.cast(),
      ],
      child: MaterialApp(theme: CmTheme.dark(), home: child),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    debugDisableNavigationMaps = true;
    await initTestLocale();
  });

  for (final entry in _sizes.entries) {
    testWidgets('HUD prêt à rouler · ${entry.key}', (tester) async {
      await _pumpApp(tester, const RideScreen(), size: entry.value);
      expect(find.text('Prêt à rouler ?'), findsOneWidget);
      expect(find.text('C\'EST PARTI'), findsOneWidget);
      await tester.dragUntilVisible(
        find.textContaining('Fixe ton téléphone sur le guidon'),
        find.byType(ListView),
        const Offset(0, -120),
      );
      await tester.dragUntilVisible(find.textContaining('Julie'), find.byType(ListView), const Offset(0, -120));
    });

    testWidgets('HUD navigation par défaut en balade · ${entry.key}', (tester) async {
      await _pumpApp(
        tester,
        const RideScreen(),
        size: entry.value,
        overrides: [
          rideControllerProvider.overrideWith(() => _FixedRideController(_activeState)),
          autonomyProvider.overrideWithValue(
            const AutonomyInfo(remainingKm: 38, remainingLiters: 2, fillRatio: 0.13, low: true),
          ),
        ],
      );
      expect(find.byType(NavigationView), findsOneWidget);
      expect(find.text('87'), findsOneWidget);
      expect(find.text('encore ~38 km'), findsOneWidget);
      expect(find.text('Signaler'), findsOneWidget);
      expect(find.byTooltip('Vue compteur'), findsOneWidget);
    });

    testWidgets('HUD compteur en balade · ${entry.key}', (tester) async {
      await _pumpApp(
        tester,
        const RideScreen(),
        size: entry.value,
        initialPrefs: {'settings.rideMapFirst': false},
        overrides: [
          rideControllerProvider.overrideWith(() => _FixedRideController(_activeState)),
          autonomyProvider.overrideWithValue(
            const AutonomyInfo(remainingKm: 38, remainingLiters: 2, fillRatio: 0.13, low: true),
          ),
        ],
      );
      expect(find.text('87'), findsOneWidget);
      expect(find.text('Réserve en vue !'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      expect(find.byType(LeanGauge), findsOneWidget);
    });

    testWidgets('récapitulatif · ${entry.key}', (tester) async {
      final ride = Ride(
        id: 'r',
        name: 'Balade du dimanche matin',
        startedAt: DateTime.utc(2026, 6, 7, 7),
        endedAt: DateTime.utc(2026, 6, 7, 10, 30),
        stats: const RideStats(
          distanceM: 182400,
          movingTimeS: 9800,
          totalTimeS: 12600,
          maxSpeedKmh: 142,
          maxLeanLeftDeg: 47,
          maxLeanRightDeg: 42,
          avgLeanInCurvesDeg: 26,
          curveCount: 312,
          elevationGainM: 1840,
          hardBrakeCount: 3,
        ),
        previewPolyline: Geo.encodePolyline(const [GeoPoint(45, 5), GeoPoint(45.1, 5.2), GeoPoint(45.05, 5.4)]),
      );
      await _pumpApp(tester, RideSummaryScreen(ride: ride), size: entry.value);
      expect(find.text('Bien roulé !'), findsOneWidget);
      await tester.dragUntilVisible(find.text('47°'), find.byType(ListView), const Offset(0, -150));
      await tester.dragUntilVisible(find.text('Voir le détail'), find.byType(ListView), const Offset(0, -150));
    });

    testWidgets('alerte chute · ${entry.key}', (tester) async {
      late ProviderContainer container;
      await _pumpApp(
        tester,
        Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const CrashAlertScreen();
          },
        ),
        size: entry.value,
      );
      container.read(crashAlertProvider.notifier).trigger(at: const GeoPoint(45, 5), seconds: 60);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('JE VAIS BIEN'), findsOneWidget);
      expect(find.text('Appeler les secours (112)'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('59'), findsOneWidget);
      await tester.tap(find.text('JE VAIS BIEN'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(crashAlertProvider).phase, CrashAlertPhase.idle);
    });
  }

  testWidgets('jauge : valeur, côté et repères max', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CmTheme.dark(),
        home: const Scaffold(body: Center(child: LeanGauge(angleDeg: -32.4, maxLeftDeg: 41, maxRightDeg: 37))),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('32'), findsOneWidget);
    expect(find.text('GAUCHE'), findsOneWidget);
  });
}
