import 'dart:convert';

import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/features/routes/generate_route_screen.dart';
import 'package:cono_moto/features/routes/generation_loader.dart';
import 'package:cono_moto/features/routes/guidance_banner.dart';
import 'package:cono_moto/features/routes/guidance_controller.dart';
import 'package:cono_moto/features/routes/route_weather_card.dart';
import 'package:cono_moto/features/routes/routes_home_screen.dart';
import 'package:cono_moto/features/routes/routes_providers.dart';
import 'package:cono_moto/features/social/social_providers.dart';
import 'package:cono_moto/services/routing/guidance_engine.dart';
import 'package:cono_moto/services/routing/route_generator.dart';
import 'package:cono_moto/services/routing/valhalla_client.dart';
import 'package:cono_moto/services/routing/weather_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';
import 'fixtures.dart';

class _IdleRide extends RideController {
  @override
  RideSessionState build() => const RideSessionState();
}

class _FakeGuidance extends GuidanceController {
  _FakeGuidance(this.initial);

  final GuidanceState? initial;

  @override
  GuidanceState? build() => initial;
}

Future<void> _pump(WidgetTester tester, Widget child, {List<Object> overrides = const [], bool scaffold = true}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(360, 760) * 3;
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
        home: scaffold ? Scaffold(body: child) : child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

PlannedRoute fixtureRoute({String name = 'Virolos vers Dourdan', bool favorite = false, String? author}) {
  final v = ValhallaClient.parseResponse(fixtureJson('valhalla_route.json') as Map<String, dynamic>);
  return PlannedRoute(
    id: name,
    name: name,
    createdAt: DateTime.utc(2026, 10, 1),
    points: v.points,
    style: RouteStyle.sinueux,
    distanceM: 124000,
    durationS: 9000,
    curvatureScore: 68,
    elevationGainM: 850,
    maneuvers: v.maneuvers,
    favorite: favorite,
    author: author,
  );
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  group('GuidanceBanner', () {
    testWidgets('rien sans itinéraire', (tester) async {
      await _pump(
        tester,
        const GuidanceBanner(),
        overrides: [guidanceProvider.overrideWith(() => _FakeGuidance(null))],
      );
      expect(tester.getSize(find.byType(GuidanceBanner)).height, 0);
    });

    testWidgets('prochaine manœuvre', (tester) async {
      final r = fixtureRoute();
      final snap = GuidanceSnapshot(
        progressM: 664,
        totalM: 3715,
        distanceFromRouteM: 4,
        offRoute: false,
        arrived: false,
        next: r.maneuvers[1],
        nextIndex: 1,
        distanceToNextM: 352,
        following: r.maneuvers[2],
      );
      await _pump(
        tester,
        const GuidanceBanner(),
        overrides: [guidanceProvider.overrideWith(() => _FakeGuidance(GuidanceState(route: r, snapshot: snap)))],
      );
      expect(find.text('350 m'), findsOneWidget);
      expect(find.text('Tourne à gauche sur D 906.'), findsOneWidget);
      expect(find.byIcon(Icons.turn_left), findsOneWidget);
      expect(find.textContaining('Reste'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hors itinéraire + recalcul', (tester) async {
      final r = fixtureRoute();
      const snap = GuidanceSnapshot(
        progressM: 664,
        totalM: 3715,
        distanceFromRouteM: 142,
        offRoute: true,
        arrived: false,
      );
      await _pump(
        tester,
        const GuidanceBanner(),
        overrides: [guidanceProvider.overrideWith(() => _FakeGuidance(GuidanceState(route: r, snapshot: snap)))],
      );
      expect(find.text('Hors itinéraire'), findsOneWidget);
      expect(find.text('Recalculer'), findsOneWidget);
      expect(find.textContaining('140 m'), findsOneWidget);
    });

    testWidgets('arrivée', (tester) async {
      final r = fixtureRoute();
      const snap = GuidanceSnapshot(
        progressM: 3715,
        totalM: 3715,
        distanceFromRouteM: 2,
        offRoute: false,
        arrived: true,
      );
      await _pump(
        tester,
        const GuidanceBanner(),
        overrides: [guidanceProvider.overrideWith(() => _FakeGuidance(GuidanceState(route: r, snapshot: snap)))],
      );
      expect(find.text('Arrivé, bien roulé !'), findsOneWidget);
    });
  });

  testWidgets('écran Balades : génération, mes balades, potes', (tester) async {
    final mine = [fixtureRoute(name: 'Virolos vers Dourdan', favorite: true), fixtureRoute(name: 'Tour du lac')];
    final friends = [fixtureRoute(name: 'La boucle à Jojo', author: 'Jojo')];
    await _pump(
      tester,
      const RoutesHomeScreen(),
      scaffold: false,
      overrides: [
        savedRoutesProvider.overrideWith((ref) => Stream.value(mine)),
        friendsRoutesProvider.overrideWith((ref) => Stream.value(friends)),
      ],
    );
    expect(find.text('Balades'), findsOneWidget);
    expect(find.text('Générer une balade'), findsOneWidget);
    expect(find.text('Mes balades à faire'), findsOneWidget);
    expect(find.text('Virolos vers Dourdan'), findsOneWidget);
    expect(find.byIcon(Icons.star), findsOneWidget);
    await tester.scrollUntilVisible(find.text('La boucle à Jojo'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('par Jojo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('écran Balades vide', (tester) async {
    await _pump(
      tester,
      const RoutesHomeScreen(),
      scaffold: false,
      overrides: [
        savedRoutesProvider.overrideWith((ref) => Stream.value(const [])),
        friendsRoutesProvider.overrideWith((ref) => Stream.value(const [])),
      ],
    );
    expect(find.text('Aucune balade en stock'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('formulaire de génération', (tester) async {
    await _pump(tester, const GenerateRouteScreen(), scaffold: false);
    expect(find.text('Trouve-moi une balade'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('120'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('120'), findsOneWidget);
    await tester.tap(find.text('A → B'));
    await tester.pumpAndSettle();
    expect(find.text('ARRIVÉE'), findsOneWidget);
    expect(find.text('120'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chargement animé', (tester) async {
    await _pump(
      tester,
      const GenerationLoader(progress: GenerationProgress('On cherche des virolos…', 1, 4)),
      scaffold: true,
    );
    expect(find.text('On cherche des virolos…'), findsOneWidget);
    expect(find.text('Étape 2 sur 4'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('carte météo sur le parcours', (tester) async {
    final client = WeatherClient(
      client: MockClient((req) async => http.Response.bytes(utf8.encode(fixture('open_meteo_forecast.json')), 200)),
    );
    final r = fixtureRoute();
    await _pump(
      tester,
      SingleChildScrollView(
        child: RouteWeatherCard(route: r, departure: DateTime.now().add(const Duration(hours: 1))),
      ),
      overrides: [weatherClientProvider.overrideWithValue(client)],
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('MÉTÉO SUR LE PARCOURS'), findsOneWidget);
    expect(find.text('départ'), findsOneWidget);
    expect(find.textContaining('Rafales'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
