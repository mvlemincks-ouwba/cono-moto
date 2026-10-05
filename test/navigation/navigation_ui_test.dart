import 'dart:convert';

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/location.dart';
import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/data/models/shared.dart';
import 'package:cono_moto/features/garage/autonomy.dart';
import 'package:cono_moto/features/navigation/destination_preview_screen.dart';
import 'package:cono_moto/features/navigation/navigation_providers.dart';
import 'package:cono_moto/features/navigation/navigation_view.dart';
import 'package:cono_moto/features/navigation/quick_report_sheet.dart';
import 'package:cono_moto/features/navigation/recent_destinations.dart';
import 'package:cono_moto/features/navigation/where_to_screen.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/features/ride/ride_screen.dart';
import 'package:cono_moto/features/ride/widgets/lean_gauge.dart';
import 'package:cono_moto/features/routes/guidance_controller.dart';
import 'package:cono_moto/features/routes/routes_providers.dart';
import 'package:cono_moto/features/traffic/traffic_providers.dart';
import 'package:cono_moto/services/routing/geocoder.dart';
import 'package:cono_moto/services/routing/http_support.dart';
import 'package:cono_moto/services/routing/maneuver_kinds.dart';
import 'package:cono_moto/services/routing/valhalla_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';
import '../routes/fixtures.dart';

class _Ride extends RideController {
  _Ride(this.initial);

  final RideSessionState initial;

  @override
  RideSessionState build() => initial;

  @override
  Future<bool> start({PlannedRoute? route}) async {
    state = RideSessionState(
      status: RideStatus.recording,
      rideId: 'nouvelle',
      startedAt: DateTime.utc(2026, 10, 5, 9),
      route: route,
      gpsAccuracyM: 4,
    );
    return true;
  }

  @override
  void pause() => state = state.copyWith(status: RideStatus.paused);

  @override
  void resume() => state = state.copyWith(status: RideStatus.recording);

  @override
  void dismissLowFuelAlert() => state = state.copyWith(lowFuelAlert: false);
}

class _Route extends ActiveRouteNotifier {
  _Route(this.initial);

  final PlannedRoute? initial;

  @override
  PlannedRoute? build() => initial;
}

class _Hub extends PositionHub {
  _Hub(this.initial);

  final RiderPosition? initial;

  @override
  RiderPosition? build() => initial;
}

class _Traffic extends TrafficNotifier {
  _Traffic(this.initial);

  final TrafficState initial;

  @override
  TrafficState build() => initial;
}

class _Voice extends VoiceGuide {
  final said = <String>[];

  @override
  Future<void> speak(String text) async => said.add(text);
}

const _sizes = <String, Size>{
  'petit téléphone': Size(360, 640),
  'téléphone': Size(393, 852),
  'paysage': Size(852, 393),
};

final _riding = RideSessionState(
  status: RideStatus.recording,
  rideId: 'r',
  startedAt: DateTime.utc(2026, 10, 5, 9),
  distanceM: 48250,
  movingTime: const Duration(minutes: 52),
  elapsed: const Duration(hours: 1, minutes: 4, seconds: 33),
  speedKmh: 87.4,
  avgSpeedKmh: 55.5,
  leanDeg: -38.2,
  maxLeanLeftDeg: 44,
  maxLeanRightDeg: 39,
  gpsAccuracyM: 4,
  leanCalibrated: true,
  leanFromGyro: true,
  lowFuelAlert: true,
  track: const [GeoPoint(45, 5), GeoPoint(45.01, 5.01)],
);

const _start = GeoPoint(45.1, 5.7);
final _line = [for (var d = 0.0; d <= 3000; d += 50) Geo.destination(_start, 0, d)];

Maneuver _m(String type, double along, String instruction, {String? street}) => Maneuver(
  instruction: instruction,
  type: type,
  distanceAlongM: along,
  location: Geo.pointAtDistance(_line, along),
  streetName: street,
);

final _route = PlannedRoute(
  id: 'nav',
  name: 'Vers le col',
  createdAt: DateTime.utc(2026, 10, 5),
  points: _line,
  distanceM: 3000,
  durationS: 300,
  maneuvers: [
    _m(ManeuverKind.depart, 0, 'Dirige-toi vers le nord sur Rue Haute', street: 'Rue Haute'),
    _m(ManeuverKind.right, 1000, 'Tourne à droite sur Rue de la Gare', street: 'Rue de la Gare'),
    _m(ManeuverKind.left, 1200, 'Tourne à gauche sur D 12', street: 'D 12'),
    _m(ManeuverKind.arrive, 3000, 'Tu es arrivé'),
  ],
);

RiderPosition _fix(GeoPoint p) => RiderPosition(point: p, time: DateTime.now().toUtc(), speedMs: 20, accuracyM: 5);

late _Voice _voice;

/// Laisse finir les animations (feuilles, transitions) sans pumpAndSettle
/// (les indicateurs de chargement tournent sans fin).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

var _valhallaCalls = 0;

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget home, {
  required Size size,
  RideSessionState? ride,
  PlannedRoute? route,
  RiderPosition? position,
  TrafficState traffic = const TrafficState(),
  Map<String, Object> prefs = const {},
  ValhallaClient? valhalla,
}) async {
  SharedPreferences.setMockInitialValues({...prefs});
  final sp = await SharedPreferences.getInstance();
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  _voice = _Voice();
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sp),
        rideControllerProvider.overrideWith(() => _Ride(ride ?? _riding)),
        activeRouteProvider.overrideWith(() => _Route(route)),
        positionHubProvider.overrideWith(() => _Hub(position)),
        trafficProvider.overrideWith(() => _Traffic(traffic)),
        defaultBikeProvider.overrideWithValue(null),
        autonomyProvider.overrideWithValue(
          const AutonomyInfo(remainingKm: 38, remainingLiters: 2, fillRatio: 0.13, low: true),
        ),
        voiceGuideProvider.overrideWithValue(_voice),
        valhallaClientProvider.overrideWithValue(
          valhalla ??
              ValhallaClient(
                client: MockClient((req) async {
                  _valhallaCalls++;
                  final file = _valhallaCalls.isOdd ? 'valhalla_route.json' : 'valhalla_two_legs.json';
                  return http.Response.bytes(utf8.encode(fixture(file)), 200);
                }),
                limiter: RateLimiter(Duration.zero),
              ),
        ),
        geocoderProvider.overrideWithValue(
          Geocoder(
            client: MockClient((req) async => http.Response.bytes(utf8.encode(fixture('photon_search.json')), 200)),
          ),
        ),
      ],
      child: MaterialApp(
        theme: CmTheme.dark(),
        home: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return home;
          },
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  return container;
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    debugDisableNavigationMaps = true;
    await initTestLocale();
  });

  setUp(() => _valhallaCalls = 0);

  for (final entry in _sizes.entries) {
    testWidgets('balade libre : le plan s\'ouvre par défaut, compteur à un geste · ${entry.key}', (tester) async {
      await _pump(tester, const RideScreen(), size: entry.value);
      expect(find.byType(NavigationView), findsOneWidget);
      expect(find.text('BALADE LIBRE'), findsOneWidget);
      expect(find.text('87'), findsOneWidget, reason: 'bulle de vitesse');
      expect(find.text('Signaler'), findsOneWidget);
      expect(find.text('PARCOURUS'), findsOneWidget);
      expect(find.text('DURÉE'), findsOneWidget);
      expect(find.text('encore ~38 km'), findsOneWidget);
      expect(find.byTooltip('Où on va ?'), findsOneWidget);

      await tester.tap(find.byTooltip('Vue compteur'));
      await _settle(tester);
      expect(find.byType(NavigationView), findsNothing);
      expect(find.byType(LeanGauge), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);

      await tester.tap(find.byTooltip('Vue navigation'));
      await _settle(tester);
      expect(find.byType(NavigationView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('itinéraire : manœuvre, « puis », arrivée prévue, incident · ${entry.key}', (tester) async {
      final traffic = TrafficState(
        incidents: [
          TrafficIncident(
            id: 't1',
            kind: IncidentKind.travaux,
            location: Geo.destination(Geo.pointAtDistance(_line, 2000), 90, 30),
            roadName: 'D 12',
          ),
        ],
      );
      await _pump(
        tester,
        const RideScreen(),
        size: entry.value,
        route: _route,
        position: _fix(Geo.pointAtDistance(_line, 600)),
        traffic: traffic,
      );
      expect(find.text('400'), findsOneWidget);
      expect(find.text('Rue de la Gare'), findsOneWidget);
      expect(find.text('puis'), findsOneWidget);
      expect(find.text('D 12'), findsWidgets);
      expect(find.text('ARRIVÉE'), findsOneWidget);
      expect(find.text('4 min'), findsOneWidget);
      expect(find.text('Travaux dans 1,4 km'), findsOneWidget);
      expect(find.byTooltip('Vue d\'ensemble'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('hors itinéraire : bandeau et bouton de secours', (tester) async {
    final c = await _pump(
      tester,
      const RideScreen(),
      size: const Size(393, 852),
      route: _route,
      position: _fix(Geo.pointAtDistance(_line, 600)),
    );
    for (var i = 0; i < 3; i++) {
      c.read(positionHubProvider.notifier).publish(_fix(Geo.destination(Geo.pointAtDistance(_line, 700), 90, 300)));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Hors itinéraire'), findsOneWidget);
    expect(find.text('Recalculer'), findsOneWidget);
    await tester.tap(find.text('Recalculer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_valhallaCalls, 1);
    expect(_voice.said, contains('Itinéraire recalculé.'));
  });

  testWidgets('arrivée : terminer ou continuer en balade libre', (tester) async {
    final c = await _pump(
      tester,
      const RideScreen(),
      size: const Size(360, 640),
      route: _route,
      position: _fix(Geo.pointAtDistance(_line, 2600)),
    );
    c.read(positionHubProvider.notifier).publish(_fix(_line.last));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Tu es arrivé !'), findsOneWidget);
    expect(find.text('Terminer la balade'), findsOneWidget);
    await tester.tap(find.text('Continuer en balade libre'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(activeRouteProvider), isNull);
    expect(find.text('BALADE LIBRE'), findsOneWidget);
    expect(c.read(rideControllerProvider).isActive, isTrue);
  });

  testWidgets('menu : arrêter la navigation, la balade continue', (tester) async {
    final c = await _pump(
      tester,
      const RideScreen(),
      size: const Size(393, 852),
      route: _route,
      position: _fix(Geo.pointAtDistance(_line, 600)),
    );
    await tester.tap(find.byTooltip('Menu'));
    await _settle(tester);
    expect(find.text('Terminer la balade'), findsOneWidget);
    await tester.tap(find.text('Arrêter la navigation'));
    await _settle(tester);
    expect(c.read(activeRouteProvider), isNull);
    expect(c.read(rideControllerProvider).isActive, isTrue);
    expect(find.text('BALADE LIBRE'), findsOneWidget);
  });

  testWidgets('voix : coupée puis remise d\'un appui', (tester) async {
    final c = await _pump(tester, const RideScreen(), size: const Size(393, 852));
    expect(c.read(settingsProvider).voiceGuidance, isTrue);
    await tester.tap(find.byTooltip('Couper la voix'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.read(settingsProvider).voiceGuidance, isFalse);
    await tester.tap(find.byTooltip('Activer la voix'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.read(settingsProvider).voiceGuidance, isTrue);
  });

  testWidgets('réglage « plan d\'abord » coupé : le compteur s\'ouvre', (tester) async {
    await _pump(tester, const RideScreen(), size: const Size(393, 852), prefs: {'settings.rideMapFirst': false});
    expect(find.byType(NavigationView), findsNothing);
    expect(find.byType(LeanGauge), findsOneWidget);
  });

  testWidgets('signaler sans compte entre potes : on explique quoi faire', (tester) async {
    await _pump(tester, const RideScreen(), size: const Size(393, 852), position: _fix(_start));
    await tester.tap(find.text('Signaler'));
    await _settle(tester);
    expect(find.text('Mode solo'), findsOneWidget);
  });

  testWidgets('grille de signalement rapide : un appui = un type', (tester) async {
    tester.view.physicalSize = const Size(360, 640) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    Object? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: CmTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  picked = await showModalBottomSheet<Object>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const QuickReportGrid(),
                  );
                },
                child: const Text('ouvrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ouvrir'));
    await _settle(tester);
    for (final t in quickReportTypes) {
      expect(find.text(t.label), findsOneWidget);
    }
    await tester.tap(find.text('Gravillons'));
    await _settle(tester);
    expect(picked, ReportType.gravillons);
    await tester.tap(find.text('ouvrir'));
    await _settle(tester);
    await tester.tap(find.text('Plus…'));
    await _settle(tester);
    expect(picked, 'more');
  });

  testWidgets('« Où on va ? » : recherche, aperçu des deux options, c\'est parti', (tester) async {
    final c = await _pump(
      tester,
      const WhereToScreen(),
      size: const Size(393, 852),
      ride: const RideSessionState(),
      position: _fix(const GeoPoint(48.6436, 1.8296)),
    );
    expect(find.text('Mes balades à faire'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Ramb');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Rambouillet'), findsOneWidget);
    expect(find.text('12 Rue Chasles'), findsOneWidget);

    await tester.tap(find.text('Rambouillet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(DestinationPreviewScreen), findsOneWidget);
    expect(c.read(recentDestinationsProvider).first.name, 'Rambouillet');
    await tester.pump(const Duration(milliseconds: 200));
    expect(_valhallaCalls, 2);
    expect(find.text('Le plus rapide'), findsOneWidget);
    expect(find.text('Par les petites routes'), findsOneWidget);
    expect(find.textContaining('arrivée'), findsNWidgets(2));

    await tester.tap(find.text('Par les petites routes'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('C\'EST PARTI'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final active = c.read(activeRouteProvider)!;
    expect(active.name, 'Vers Rambouillet');
    expect(active.description, 'Par les petites routes');
    expect(c.read(rideControllerProvider).isActive, isTrue);
    expect(find.byType(RideScreen), findsOneWidget);
    expect(find.byType(NavigationView), findsOneWidget);
  });

  testWidgets('« Où on va ? » : récents et retrait', (tester) async {
    final c = await _pump(
      tester,
      const WhereToScreen(),
      size: const Size(360, 640),
      ride: const RideSessionState(),
      prefs: {
        RecentDestinationsNotifier.prefsKey: RecentDestinations.encode([
          RecentDestination(name: 'Col du Glandon', point: const GeoPoint(45.24, 6.17), usedAt: DateTime.utc(2026, 9)),
          RecentDestination(name: 'Vercors', point: const GeoPoint(45.05, 5.42), usedAt: DateTime.utc(2026, 8)),
        ]),
      },
    );
    expect(find.text('Récents'), findsOneWidget);
    expect(find.text('Col du Glandon'), findsOneWidget);
    await tester.tap(find.byTooltip('Retirer').first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Col du Glandon'), findsNothing);
    expect(c.read(recentDestinationsProvider).map((d) => d.name), ['Vercors']);
  });

  testWidgets('aperçu : calcul impossible, message clair et réessai', (tester) async {
    await _pump(
      tester,
      const DestinationPreviewScreen(
        destination: Place(name: 'Dourdan', point: GeoPoint(48.53, 2.01)),
      ),
      size: const Size(393, 852),
      ride: const RideSessionState(),
      position: _fix(const GeoPoint(48.6436, 1.8296)),
      valhalla: ValhallaClient(
        client: MockClient((_) async => http.Response('busy', 429)),
        limiter: RateLimiter(Duration.zero),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('saturé'), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
  });
}
