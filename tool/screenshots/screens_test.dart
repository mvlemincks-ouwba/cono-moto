// ignore_for_file: invalid_use_of_visible_for_testing_member
// Génère des captures d'écran (hors suite de tests) :
//   flutter test tool/screenshots/screens_test.dart --update-goldens
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/data/models/shared.dart';
import 'package:cono_moto/data/repositories.dart';
import 'package:cono_moto/features/fuel/fuel_providers.dart';
import 'package:cono_moto/features/fuel/fuel_ui.dart';
import 'package:cono_moto/features/garage/autonomy.dart';
import 'package:cono_moto/features/garage/garage_screen.dart';
import 'package:cono_moto/features/history/history_screen.dart';
import 'package:cono_moto/features/history/ride_share_card.dart';
import 'package:cono_moto/features/history/stats_screen.dart';
import 'package:cono_moto/features/onboarding/onboarding_screen.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/features/ride/ride_screen.dart';
import 'package:cono_moto/features/routes/routes_home_screen.dart';
import 'package:cono_moto/features/social/social_home_screen.dart';
import 'package:cono_moto/features/social/social_models.dart';
import 'package:cono_moto/features/social/social_providers.dart';
import 'package:cono_moto/services/ride/ride_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test/helpers.dart';
import '../../test/ride/fake_ride_platform.dart';

const _fontsDir = String.fromEnvironment('FONTS_DIR');

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File(f).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter-sdk/flutter';
  final mat = '$sdk/bin/cache/artifacts/material_fonts';
  await _loadFont('MaterialIcons', ['$mat/MaterialIcons-Regular.otf']);
  await _loadFont('Roboto', ['$mat/Roboto-Regular.ttf', '$mat/Roboto-Medium.ttf', '$mat/Roboto-Bold.ttf']);
  final b = _fontsDir;
  const weights = {
    'regular': 'Regular',
    '400': 'Regular',
    '500': 'Medium',
    '600': 'SemiBold',
    '700': 'Bold',
    '800': 'ExtraBold',
    '900': 'ExtraBold',
  };
  for (final e in weights.entries) {
    await _loadFont('Barlow_${e.key}', ['$b/Barlow-${e.value}.ttf']);
  }
  await _loadFont('Barlow', ['$b/Barlow-Regular.ttf', '$b/Barlow-Bold.ttf']);
  for (final w in ['regular', '400', '500', '600']) {
    await _loadFont('BarlowCondensed_$w', ['$b/BarlowCondensed-SemiBold.ttf']);
  }
  for (final w in ['700', '800', '900']) {
    await _loadFont('BarlowCondensed_$w', ['$b/BarlowCondensed-Bold.ttf']);
  }
  await _loadFont('BarlowCondensed', ['$b/BarlowCondensed-Bold.ttf']);
}

class _FixedRide extends RideController {
  _FixedRide(this.initial);
  final RideSessionState initial;
  @override
  RideSessionState build() => initial;
}

List<TrackPoint> _track(DateTime t0) => [
      for (var i = 0; i < 900; i++)
        TrackPoint(
          time: t0.add(Duration(seconds: i * 4)),
          lat: 45.05 + i * 0.00012 + 0.004 * (i % 120 < 60 ? (i % 60) / 60 : 1 - (i % 60) / 60),
          lng: 5.55 + 0.0025 * (i % 80 < 40 ? i % 40 : 40 - i % 40) / 4 + i * 0.00005,
          speedMs: 14 + (i % 50) / 3,
          leanDeg: (i % 60 < 30 ? -1 : 1) * (i % 30) * 1.45,
          altitude: 300 + 600 * (i / 900) + 40 * ((i % 100) / 100),
        ),
    ];

/// Boucle presque fermée avec des lacets côté montagne (pour la carte à partager).
List<TrackPoint> _cardTrack(DateTime t0) {
  const n = 4000;
  return [
    for (var i = 0; i < n; i++)
      () {
        final th = 1.9 * math.pi * i / n;
        final mountain = math.max(0.0, math.sin(th - math.pi / 3));
        final hairpin = math.sin(th * 46);
        final r = 0.16 * (1 + 0.22 * math.sin(2 * th + 0.6) + 0.1 * math.sin(3 * th + 1.4)) + 0.012 * mountain * hairpin;
        return TrackPoint(
          time: t0.add(Duration(seconds: i * 3)),
          lat: 45.0 + r * math.sin(th),
          lng: 5.55 + r * math.cos(th) / math.cos(45 * math.pi / 180),
          speedMs: 22 - 8 * mountain,
          leanDeg: (6 + 44 * mountain) * hairpin,
          altitude: 400 + 900 * mountain,
        );
      }(),
  ];
}

Future<void> _seed(GarageRepository garage, RideRepository rides, RouteRepository routes) async {
  final now = DateTime.now().toUtc();
  await garage.upsertBike(const Bike(
    id: 'b1',
    name: 'La Tracer',
    brand: 'Yamaha',
    model: 'Tracer 9 GT',
    year: 2023,
    odometerKm: 18432,
    tankLiters: 19,
    reserveLiters: 3.5,
    consumptionL100: 5.4,
    isDefault: true,
    kmSinceFullTank: 196,
  ));
  final items = <MaintenanceItem>[
    MaintenanceItem(id: 'm1', bikeId: 'b1', type: MaintenanceType.chaine, intervalKm: 600, lastDoneKm: 17900, lastDoneDate: now.subtract(const Duration(days: 9))),
    MaintenanceItem(id: 'm2', bikeId: 'b1', type: MaintenanceType.vidange, intervalKm: 10000, intervalMonths: 12, lastDoneKm: 10200, lastDoneDate: now.subtract(const Duration(days: 300))),
    MaintenanceItem(id: 'm3', bikeId: 'b1', type: MaintenanceType.pneuArriere, intervalKm: 9000, lastDoneKm: 12000, lastDoneDate: now.subtract(const Duration(days: 200))),
    MaintenanceItem(id: 'm4', bikeId: 'b1', type: MaintenanceType.plaquettes, intervalKm: 15000, lastDoneKm: 9000, lastDoneDate: now.subtract(const Duration(days: 380))),
    MaintenanceItem(id: 'm5', bikeId: 'b1', type: MaintenanceType.liquideFrein, intervalMonths: 24, lastDoneDate: now.subtract(const Duration(days: 400))),
  ];
  for (final m in items) {
    await garage.upsertMaintenanceItem(m);
  }
  final fills = [
    (40, 16.2, 1.879),
    (31, 15.4, 1.859),
    (19, 14.9, 1.899),
    (6, 17.1, 1.845),
  ];
  var odo = 17200.0;
  for (final (days, liters, price) in fills) {
    odo += 290;
    await garage.upsertFuel(FuelEntry(
      id: 'f$days',
      date: now.subtract(Duration(days: days)),
      liters: liters,
      pricePerLiter: price,
      bikeId: 'b1',
      odometerKm: odo,
      stationName: 'Station · Av. Jean Jaurès, Grenoble',
    ));
  }
  await garage.upsertExpense(Expense(id: 'e1', date: now.subtract(const Duration(days: 6)), amount: 14.8, category: ExpenseCategory.peage, label: 'A41', bikeId: 'b1'));
  await garage.upsertExpense(Expense(id: 'e2', date: now.subtract(const Duration(days: 20)), amount: 32, category: ExpenseCategory.resto, label: 'Resto au col', bikeId: 'b1'));

  final names = [
    ('Tour du Vercors par les gorges', 2, 182400.0, 47.0, 44.0, 1840.0),
    ('Chartreuse, col du Granier', 9, 126300.0, 41.0, 43.0, 1320.0),
    ('Petite boucle du soir', 16, 54200.0, 33.0, 36.0, 420.0),
    ('Route Napoléon jusqu\'à Gap', 38, 231900.0, 45.0, 39.0, 2210.0),
    ('Belledonne, balcons', 52, 98700.0, 38.0, 42.0, 1530.0),
  ];
  for (final (i, n) in names.indexed) {
    final (name, days, dist, ll, lr, dplus) = n;
    final start = now.subtract(Duration(days: days, hours: 4));
    final track = _track(start);
    final simplified = Geo.simplify([for (final p in track) p.point], 30);
    await rides.upsert(Ride(
      id: 'r$i',
      name: name,
      startedAt: start,
      endedAt: start.add(Duration(minutes: (dist / 1000 / 58 * 60).round() + 25)),
      bikeId: 'b1',
      previewPolyline: Geo.encodePolyline(simplified),
      stats: RideStats(
        distanceM: dist,
        movingTimeS: (dist / 1000 / 58 * 3600).round(),
        totalTimeS: (dist / 1000 / 58 * 3600).round() + 1500,
        maxSpeedKmh: 128 + i * 3,
        maxLeanLeftDeg: ll,
        maxLeanRightDeg: lr,
        avgLeanInCurvesDeg: 24,
        hardBrakeCount: 2 + i,
        elevationGainM: dplus,
        curveCount: (dist / 600).round(),
        leanHistogram: const {0: 4000, 10: 2500, 20: 1800, 30: 900, 40: 140},
        speedHistogram: const {0: 300, 20: 900, 40: 2600, 60: 3100, 80: 1800, 100: 400},
      ),
    ));
    if (i == 0) await rides.appendPoints('r0', 0, track);
  }

  await routes.upsert(PlannedRoute(
    id: 'p1',
    name: 'Virolos du Diois',
    createdAt: now.subtract(const Duration(days: 1)),
    points: Geo.simplify([for (final p in _track(now)) p.point], 30),
    style: RouteStyle.sinueux,
    distanceM: 164000,
    durationS: 3 * 3600 + 1200,
    curvatureScore: 82,
    elevationGainM: 1950,
    favorite: true,
  ));
  await routes.upsert(PlannedRoute(
    id: 'p2',
    name: 'Forêt de Chambaran',
    createdAt: now.subtract(const Duration(days: 4)),
    points: Geo.simplify([for (final p in _track(now)) GeoPoint(p.lat - 0.2, p.lng + 0.1)], 30),
    style: RouteStyle.foret,
    distanceM: 112000,
    durationS: 2 * 3600 + 300,
    curvatureScore: 55,
    elevationGainM: 640,
  ));
}

void main() {
  late SharedPreferences prefs;
  final now = DateTime.now().toUtc();

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
    await _loadFonts();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'settings.emergencyName': 'Julie',
      'settings.emergencyPhone': '0611223344',
      'settings.onboardingDone': true,
    });
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> shot(WidgetTester tester, String name, Widget home, List overrides,
      {Future<void> Function(WidgetTester t)? act, double height = 852}) async {
    tester.view.physicalSize = Size(393 * 3, height * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs), ...overrides],
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: CmTheme.dark(), home: home),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (act != null) await act(tester);
    await expectLater(find.byKey(key), matchesGoldenFile('out/$name.png'));
    final original = FlutterError.onError;
    FlutterError.onError = (d) {
      final t = '${d.exception}\n${d.stack}';
      if (t.contains('maplibre') || t.contains('MapLibre')) return;
      original?.call(d);
    };
    try {
      await tester.pumpWidget(const SizedBox());
    } finally {
      FlutterError.onError = original;
    }
  }

  Future<List> dbOverrides(WidgetTester tester) async {
    final db = (await tester.runAsync(openTestDatabase))!;
    final garage = GarageRepository(db), rides = RideRepository(db), routes = RouteRepository(db);
    await tester.runAsync(() => _seed(garage, rides, routes));
    return [
      databaseProvider.overrideWithValue(db),
      ridePlatformProvider.overrideWithValue(FakeRidePlatform()),
    ];
  }

  testWidgets('01-compteur', (tester) async {
    await shot(tester, '01-compteur', const RideScreen(initialLayout: HudLayout.gauges), [
      ridePlatformProvider.overrideWithValue(FakeRidePlatform()),
      defaultBikeProvider.overrideWithValue(null),
      rideControllerProvider.overrideWith(() => _FixedRide(RideSessionState(
            status: RideStatus.recording,
            rideId: 'r',
            startedAt: now.subtract(const Duration(hours: 1)),
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
            crashDetectionArmed: true,
            track: const [GeoPoint(45, 5), GeoPoint(45.01, 5.01)],
          ))),
      autonomyProvider.overrideWithValue(
          const AutonomyInfo(remainingKm: 182, remainingLiters: 9.8, fillRatio: 0.52, low: false, tankLiters: 19, consumptionL100: 5.4)),
    ]);
  });

  testWidgets('09-compteur-piste', (tester) async {
    await prefs.setString('dash.active', 'piste');
    await shot(tester, '09-compteur-piste', const RideScreen(initialLayout: HudLayout.gauges), [
      ridePlatformProvider.overrideWithValue(FakeRidePlatform()),
      defaultBikeProvider.overrideWithValue(null),
      rideControllerProvider.overrideWith(() => _FixedRide(RideSessionState(
            status: RideStatus.recording,
            rideId: 'r',
            startedAt: now.subtract(const Duration(minutes: 27)),
            distanceM: 19600,
            movingTime: const Duration(minutes: 25),
            elapsed: const Duration(minutes: 27, seconds: 4),
            speedKmh: 92.6,
            maxSpeedKmh: 107,
            avgSpeedKmh: 47,
            leanDeg: 24,
            maxLeanLeftDeg: 30,
            maxLeanRightDeg: 28,
            hardBrakeCount: 1,
            longG: -0.42,
            maxAccelG: 0.31,
            maxDecelG: 0.68,
            curveCount: 27,
            gpsAccuracyM: 4,
            leanCalibrated: true,
            leanFromGyro: true,
            crashDetectionArmed: true,
          ))),
    ]);
  });

  testWidgets('02-garage', (tester) async {
    final o = await dbOverrides(tester);
    await shot(tester, '02-garage', const GarageScreen(), o, height: 1500);
  });

  testWidgets('03-historique', (tester) async {
    final o = await dbOverrides(tester);
    await shot(tester, '03-historique', const HistoryScreen(), o);
  });

  testWidgets('04-stats', (tester) async {
    final o = await dbOverrides(tester);
    await shot(tester, '04-stats', const StatsScreen(), o, height: 1500);
  });

  testWidgets('05-balades', (tester) async {
    final o = await dbOverrides(tester);
    await shot(tester, '05-balades', const RoutesHomeScreen(), [
      ...o,
      friendsRoutesProvider.overrideWith((ref) => Stream.value(const <PlannedRoute>[])),
    ]);
  });

  testWidgets('06-essence', (tester) async {
    FuelStation st(String id, String adr, String city, double sp98, double e10, double d, {int h = 2}) => FuelStation(
          id: id,
          location: GeoPoint(45.18 + d / 100000, 5.72),
          address: adr,
          city: city,
          prices: {FuelType.sp98: sp98, FuelType.e10: e10, FuelType.gazole: sp98 - 0.12},
          updatedAt: {FuelType.sp98: now.subtract(Duration(hours: h)), FuelType.e10: now.subtract(Duration(hours: h))},
          distanceM: d,
          open24h: id == 'a',
        );
    final stations = [
      st('a', '12 Avenue Jean Jaurès', 'Grenoble', 1.849, 1.759, 1200),
      st('b', 'Route de Lyon', 'Saint-Égrève', 1.879, 1.789, 3400, h: 5),
      st('c', '3 Rue des Alpes', 'Échirolles', 1.799, 1.719, 4800),
      st('d', 'Centre commercial Grand Place', 'Grenoble', 1.829, 1.739, 2600, h: 30),
      st('e', 'Avenue de la République', 'Meylan', 1.919, 1.829, 5200),
    ];
    final o = await dbOverrides(tester);
    await shot(
      tester,
      '06-essence',
      Builder(builder: (context) => Scaffold(body: Center(child: FilledButton(onPressed: () => showFuelStationsSheet(context, near: const GeoPoint(45.18, 5.72)), child: const Text('go'))))),
      [...o, stationsAroundProvider.overrideWith((ref, c) async => stations)],
      act: (t) async {
        await t.tap(find.text('go'));
        for (var i = 0; i < 10; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
          await t.pump(const Duration(milliseconds: 100));
        }
      },
    );
  });

  testWidgets('07-potes', (tester) async {
    const me = UserProfile(uid: 'me', name: 'Marc', colorValue: 0xFFFF6B1A, bike: 'Tracer 9 GT', code: 'K7PM2X');
    final group = Group(
      id: 'ABCD2345',
      name: 'Les Cono',
      createdBy: 'me',
      members: const [
        GroupMember(uid: 'me', name: 'Marc', colorValue: 0xFFFF6B1A),
        GroupMember(uid: 'a', name: 'Julien', colorValue: 0xFF2EC4B6),
      ],
    );
    await shot(tester, '07-potes', const SocialHomeScreen(), [
      socialAvailableProvider.overrideWithValue(true),
      authUserProvider.overrideWith((ref) => Stream.value(null)),
      myUidProvider.overrideWithValue('me'),
      myProfileProvider.overrideWith((ref) => Stream.value(me)),
      myPositionProvider.overrideWithValue(const GeoPoint(45.18, 5.72)),
      friendIdsProvider.overrideWith((ref) => Stream.value(['a', 'b'])),
      userProfileProvider.overrideWith((ref, uid) => Stream.value(uid == 'a'
          ? const UserProfile(uid: 'a', name: 'Julien', colorValue: 0xFF2EC4B6, bike: 'Street Triple')
          : const UserProfile(uid: 'b', name: 'Seb', colorValue: 0xFFA78BFA, bike: 'MT-07'))),
      liveStateProvider.overrideWith((ref, uid) => Stream.value(uid == 'a'
          ? LiveState(uid: 'a', location: const GeoPoint(45.25, 5.8), updatedAt: now, riding: true, speedKmh: 87)
          : LiveState(uid: 'b', location: const GeoPoint(45.1, 5.6), updatedAt: now.subtract(const Duration(hours: 2))))),
      myGroupIdsProvider.overrideWith((ref) => Stream.value(['ABCD2345'])),
      groupProvider.overrideWith((ref, gid) => Stream.value(group)),
      mySharesProvider.overrideWith((ref) => Stream.value(const <LiveShare>[])),
      userReportsProvider.overrideWith((ref, uid) => Stream.value(const <RoadReport>[])),
      userSharedRidesProvider.overrideWith((ref, uid) => Stream.value(const <FriendRide>[])),
    ], height: 1200);
  });

  testWidgets('08-accueil', (tester) async {
    await shot(tester, '08-accueil', const OnboardingScreen(), []);
  });

  // Image de balade à partager, dessinée à mi-taille (540 × 675).
  testWidgets('10-carte-partage', (tester) async {
    final start = now.subtract(const Duration(days: 2, hours: 4));
    final ride = Ride(
      id: 'r0',
      name: 'Tour du Vercors par les gorges',
      startedAt: start,
      endedAt: start.add(const Duration(hours: 3, minutes: 35)),
      stats: const RideStats(
        distanceM: 182400,
        movingTimeS: 11320,
        totalTimeS: 12900,
        maxSpeedKmh: 128,
        maxLeanLeftDeg: 47,
        maxLeanRightDeg: 44,
        elevationGainM: 1840,
        curveCount: 304,
      ),
    );
    final content = buildRideCardContent(
      ride,
      track: _cardTrack(start),
      bike: const Bike(id: 'b1', name: 'La Tracer', colorValue: 0xFF4EA8FF),
    );
    final image = await tester.runAsync(() {
      final recorder = ui.PictureRecorder();
      paintRideCard(Canvas(recorder)..scale(0.5), content);
      return recorder.endRecording().toImage(540, 675);
    });
    await expectLater(image!, matchesGoldenFile('out/10-carte-partage.png'));
  });
}
