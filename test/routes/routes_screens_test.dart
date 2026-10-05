import 'dart:convert';

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/services/routing/elevation_client.dart';
import 'package:cono_moto/services/routing/weather_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/features/routes/generation_results_screen.dart';
import 'package:cono_moto/features/routes/route_detail_screen.dart';
import 'package:cono_moto/features/routes/route_ui.dart';
import 'package:cono_moto/features/routes/routes_providers.dart';
import 'package:cono_moto/services/routing/route_generator.dart';
import 'package:cono_moto/services/routing/route_scoring.dart';
import 'package:cono_moto/services/routing/valhalla_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';
import 'fixtures.dart';

class _IdleRide extends RideController {
  @override
  RideSessionState build() => const RideSessionState();
}

class _FakeGen extends GenerationController {
  _FakeGen(this.initial);
  final GenerationState initial;
  @override
  GenerationState build() => initial;
  @override
  Future<void> run(RouteRequest request) async {}
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    debugDisableRouteMaps = true;
    await initTestLocale();
  });

  testWidgets('écran de résultats : 3 propositions', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(360, 760) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final v = ValhallaClient.parseResponse(fixtureJson('valhalla_route.json') as Map<String, dynamic>);
    const start = GeoPoint(48.6436, 1.8296);
    final cands = [
      for (var i = 0; i < 3; i++)
        RouteCandidate(
          route: PlannedRoute(
            id: 'c$i',
            name: 'Virolos vers Dourdan par la vallée $i',
            createdAt: DateTime.utc(2026),
            points: v.points,
            distanceM: 124000,
            durationS: 9000,
            curvatureScore: 70,
            maneuvers: v.maneuvers,
            description: 'Boucle de 124 km au départ de Rambouillet, par la Forêt de Rambouillet.',
          ),
          metrics: const RouteMetrics(distanceM: 124000, durationS: 9000, curvature: 70, elevationGainM: 1250),
          score: 80 - i * 10.0,
          badges: const [
            RouteBadge('Très sinueux', BadgeKind.curvy),
            RouteBadge('+1 250 m D+', BadgeKind.climb),
            RouteBadge('Tranquille', BadgeKind.calm),
          ],
        ),
    ];
    const req = RouteRequest(start: start);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          rideControllerProvider.overrideWith(_IdleRide.new),
          generationProvider.overrideWith(
            () => _FakeGen(
              GenerationState(
                request: req,
                result: GenerationResult(
                  cands,
                  notes: const ['Pas de col routier à portée : on t\'a trouvé des routes qui tournent à la place.'],
                ),
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: CmTheme.dark(),
          home: const GenerationResultsScreen(request: req),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text("C'est parti"), findsWidgets);
    expect(find.text('Meilleur match'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('détail d\'une balade : stats, profil, météo, roadbook', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = await tester.runAsync(openTestDatabase);
    tester.view.physicalSize = const Size(360, 760) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final v = ValhallaClient.parseResponse(fixtureJson('valhalla_route.json') as Map<String, dynamic>);
    final route = PlannedRoute(
      id: 'd1',
      name: 'Virolos vers Dourdan',
      createdAt: DateTime.utc(2026),
      points: v.points,
      distanceM: 124000,
      durationS: 9000,
      curvatureScore: 70,
      maneuvers: v.maneuvers,
      style: RouteStyle.sinueux,
      description: 'Boucle de 124 km au départ de Rambouillet.',
    );
    final elevation = ElevationClient(
      client: MockClient((req) async {
        final n = req.url.queryParameters['latitude']!.split(',').length;
        return http.Response(
          jsonEncode({
            'elevation': [for (var i = 0; i < n; i++) 100.0 + i * 7],
          }),
          200,
        );
      }),
    );
    final weather = WeatherClient(
      client: MockClient((req) async => http.Response.bytes(utf8.encode(fixture('open_meteo_forecast.json')), 200)),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db!),
          rideControllerProvider.overrideWith(_IdleRide.new),
          elevationClientProvider.overrideWithValue(elevation),
          weatherClientProvider.overrideWithValue(weather),
        ],
        child: MaterialApp(
          theme: CmTheme.dark(),
          home: RouteDetailScreen(route: route),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text("C'est parti"), findsOneWidget);
    expect(find.text('Enregistrer'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Roadbook'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Tourne à gauche sur D 906.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
