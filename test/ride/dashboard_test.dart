import 'dart:convert';

import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/features/garage/autonomy.dart';
import 'package:cono_moto/features/ride/dashboard/dashboard_body.dart';
import 'package:cono_moto/features/ride/dashboard/dashboard_editor.dart';
import 'package:cono_moto/features/ride/dashboard/dashboard_model.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/features/ride/ride_screen.dart';
import 'package:cono_moto/features/ride/widgets/g_force_gauge.dart';
import 'package:cono_moto/features/ride/widgets/lean_gauge.dart';
import 'package:cono_moto/core/ui/widgets.dart';
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

final _riding = RideSessionState(
  status: RideStatus.recording,
  rideId: 'r',
  startedAt: DateTime.utc(2026, 10, 6, 8, 28),
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
  altitudeM: 812,
  elevationGainM: 70,
  curveCount: 27,
  gpsAccuracyM: 4,
  leanCalibrated: true,
  leanFromGyro: true,
);

/// Vue avec tout : vitesse, deux cadrans et neuf tuiles.
const _full = DashView(
  id: 'full',
  name: 'Tout',
  emoji: '⚡',
  items: [
    DashItem.speed,
    DashItem.lean,
    DashItem.gforce,
    DashItem.distance,
    DashItem.movingTime,
    DashItem.elapsed,
    DashItem.avgSpeed,
    DashItem.maxSpeed,
    DashItem.maxLean,
    DashItem.maxG,
    DashItem.liveG,
    DashItem.altitude,
  ],
);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(393, 852),
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({'settings.rideMapFirst': false, ...prefs});
  final sp = await SharedPreferences.getInstance();
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sp),
        ridePlatformProvider.overrideWithValue(FakeRidePlatform()),
        defaultBikeProvider.overrideWithValue(null),
        rideControllerProvider.overrideWith(() => _FixedRideController(_riding)),
        autonomyProvider.overrideWithValue(
          const AutonomyInfo(remainingKm: 142, remainingLiters: 8, fillRatio: 0.6, low: false),
        ),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return MaterialApp(theme: CmTheme.dark(), home: child);
        },
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  return container;
}

/// Le HUD a des animations en boucle (pastille REC) : pas de pumpAndSettle.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _viewsJson(List<DashView> views) => jsonEncode([for (final v in views) v.toJson()]);

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  group('modèle', () {
    test('aller-retour JSON, éléments inconnus ignorés, limites respectées', () {
      final v = DashView.fromJson({
        'id': 'x',
        'name': '  ',
        'items': ['speed', 'speed', 'lean', 'gforce', 'radar', ...DashItem.values.map((i) => i.name)],
      });
      expect(v.name, 'Ma vue');
      expect(v.items.first, DashItem.speed);
      expect(v.items.where((i) => i == DashItem.speed), hasLength(1));
      expect(v.gauges, [DashItem.lean, DashItem.gforce]);
      expect(v.tiles, hasLength(DashView.maxTiles));
      expect(DashView.fromJson(v.toJson()), v);
    });

    test('vues de départ : Balade, Piste, Trail, Tranquille', () {
      expect(defaultDashViews.map((v) => v.name), ['Balade', 'Piste', 'Trail', 'Tranquille']);
      expect(defaultDashViews[1].gauges, contains(DashItem.gforce));
      for (final v in defaultDashViews) {
        expect(DashView.sanitizeItems(v.items), v.items, reason: v.name);
      }
    });
  });

  group('enregistrement', () {
    Future<ProviderContainer> container(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues(prefs);
      final sp = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(sp)]);
      addTearDown(c.dispose);
      return c;
    }

    test('vues de départ, puis création, choix, ordre et suppression mémorisés', () async {
      final c = await container({});
      final ctrl = c.read(dashboardProvider.notifier);
      expect(c.read(dashboardProvider).active.id, 'balade');

      await ctrl.save(_full.copyWith(id: ctrl.newId()));
      expect(c.read(dashboardProvider).views, hasLength(5));
      expect(c.read(dashboardProvider).activeId, 'vue5');

      ctrl.select('piste');
      await ctrl.move(1, 0);
      expect(c.read(dashboardProvider).views.first.id, 'piste');

      final sp = c.read(sharedPreferencesProvider);
      expect(sp.getString(DashboardController.activeKey), 'piste');
      final saved = jsonDecode(sp.getString(DashboardController.viewsKey)!) as List;
      expect(saved.map((j) => j['id']), ['piste', 'balade', 'trail', 'tranquille', 'vue5']);

      await ctrl.delete('piste');
      expect(c.read(dashboardProvider).activeId, 'balade', reason: 'la vue affichée a été supprimée');
      await ctrl.resetToDefaults();
      expect(c.read(dashboardProvider).views, defaultDashViews);
    });

    test('jamais sans vue, et données illisibles ignorées', () async {
      final c = await container({
        DashboardController.viewsKey: _viewsJson([_full]),
      });
      await c.read(dashboardProvider.notifier).delete('full');
      expect(c.read(dashboardProvider).views.single.id, 'full');

      final broken = await container({DashboardController.viewsKey: '{pas du json'});
      expect(broken.read(dashboardProvider).views, defaultDashViews);
    });
  });

  group('tuiles', () {
    test('valeurs affichées', () {
      String valueOf(DashItem i, {AutonomyInfo? autonomy}) {
        final t = dashTile(i, _riding, autonomy, now: DateTime(2026, 10, 6, 9, 5)) as StatTile;
        return '${t.label}|${t.value}|${t.unit ?? ''}';
      }

      expect(valueOf(DashItem.distance), 'Distance|19,6|km');
      expect(valueOf(DashItem.maxLean), 'Angles G · D|30° · 28°|');
      expect(valueOf(DashItem.maxG), 'G acc · frein|0,31 · 0,68|');
      expect(valueOf(DashItem.liveG), 'Freinage|0,42|G');
      expect(valueOf(DashItem.altitude), 'Altitude|812|m');
      expect(valueOf(DashItem.autonomy), 'Autonomie|--|km');
      expect(valueOf(DashItem.clock), 'Heure|09:05|');
      expect(valueOf(DashItem.elapsed), 'Chrono|27:04|');
    });

    test('G latéral d\'après l\'angle', () {
      expect(GForceGauge.lateralFromLean(45), closeTo(1, 0.001));
      expect(GForceGauge.lateralFromLean(-30), closeTo(-0.577, 0.001));
      expect(GForceGauge.lateralFromLean(80), GForceGauge.rangeG);
    });
  });

  group('compteur en balade', () {
    const sizes = {'petit téléphone': Size(360, 640), 'téléphone': Size(393, 852), 'paysage': Size(852, 393)};
    for (final size in sizes.entries) {
      for (final view in [...defaultDashViews, _full]) {
        testWidgets('${view.name} · ${size.key}', (tester) async {
          await _pump(
            tester,
            const RideScreen(),
            size: size.value,
            prefs: {
              DashboardController.viewsKey: _viewsJson([...defaultDashViews, _full]),
              DashboardController.activeKey: view.id,
            },
          );
          expect(find.text(view.title), findsOneWidget);
          expect(find.text('93'), view.showsSpeed ? findsOneWidget : findsNothing);
          expect(find.byType(LeanGauge), view.items.contains(DashItem.lean) ? findsOneWidget : findsNothing);
          expect(find.byType(GForceGauge), view.items.contains(DashItem.gforce) ? findsOneWidget : findsNothing);
          expect(find.byType(StatTile), findsNWidgets(view.tiles.length));
        });
      }
    }

    testWidgets('flèches et geste : on change de vue, et elle est mémorisée', (tester) async {
      final c = await _pump(tester, const RideScreen());
      expect(find.text('🛣️ Balade'), findsOneWidget);
      await tester.tap(find.byTooltip('Vue suivante'));
      await _settle(tester);
      expect(find.text('🏁 Piste'), findsOneWidget);
      expect(find.byType(GForceGauge), findsOneWidget);
      expect(find.text('FREINAGE'), findsOneWidget);
      expect(c.read(sharedPreferencesProvider).getString(DashboardController.activeKey), 'piste');

      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
      await _settle(tester);
      expect(find.text('🏔️ Trail'), findsOneWidget);
      expect(c.read(dashboardProvider).activeId, 'trail');
    });

    testWidgets('une seule vue : pas de sélecteur', (tester) async {
      await _pump(
        tester,
        const RideScreen(),
        prefs: {
          DashboardController.viewsKey: _viewsJson([defaultDashViews.first]),
        },
      );
      expect(find.byTooltip('Vue suivante'), findsNothing);
      expect(find.byType(DashboardBody), findsOneWidget);
    });
  });

  group('personnalisation', () {
    testWidgets('modifier la vue Piste : retirer et ajouter des tuiles', (tester) async {
      tester.view.physicalSize = const Size(393, 2400) * 3;
      final c = await _pump(tester, const DashboardViewsScreen(), size: const Size(393, 2400));
      expect(find.text('Balade'), findsOneWidget);
      expect(find.text('Affichée'), findsOneWidget);

      await tester.tap(find.text('Piste'));
      await tester.pumpAndSettle();
      expect(find.text('Modifier la vue'), findsOneWidget);
      expect(find.byType(GForceGauge), findsOneWidget, reason: 'aperçu');

      await tester.tap(find.byTooltip('Retirer').first); // Angles max
      await tester.pump();
      await tester.tap(find.widgetWithText(ActionChip, 'Altitude'));
      await tester.pump();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      final piste = c.read(dashboardProvider).views.firstWhere((v) => v.id == 'piste');
      expect(piste.tiles, isNot(contains(DashItem.maxLean)));
      expect(piste.tiles.last, DashItem.altitude);
      expect(c.read(dashboardProvider).activeId, 'piste');
    });

    testWidgets('nouvelle vue nommée, sans cadran', (tester) async {
      final c = await _pump(tester, const DashboardViewsScreen(), size: const Size(393, 2400));
      await tester.tap(find.text('Nouvelle vue'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Rando pluie');
      await tester.tap(find.text('🌧️'));
      await tester.tap(find.text('Angle d\'inclinaison'));
      await tester.pump();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      final dash = c.read(dashboardProvider);
      expect(dash.active.name, 'Rando pluie');
      expect(dash.active.emoji, '🌧️');
      expect(dash.active.gauges, isEmpty);
      expect(find.text('Rando pluie'), findsOneWidget);
    });
  });
}
