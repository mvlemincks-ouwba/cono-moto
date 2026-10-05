import 'dart:convert';

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/location.dart';
import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/features/routes/guidance_controller.dart';
import 'package:cono_moto/features/routes/routes_providers.dart';
import 'package:cono_moto/services/routing/http_support.dart';
import 'package:cono_moto/services/routing/valhalla_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _Ride extends RideController {
  @override
  RideSessionState build() => const RideSessionState(status: RideStatus.recording);

  void setStatus(RideStatus s) => state = RideSessionState(status: s);
}

class _FakeVoice extends VoiceGuide {
  final said = <String>[];

  @override
  Future<void> speak(String text) async => said.add(text);
}

PlannedRoute fixtureRoute() {
  final v = ValhallaClient.parseResponse(fixtureJson('valhalla_route.json') as Map<String, dynamic>);
  return PlannedRoute(
    id: 'g1',
    name: 'Test',
    createdAt: DateTime.utc(2026, 10, 5),
    points: v.points,
    distanceM: v.distanceM,
    durationS: v.durationS,
    maneuvers: v.maneuvers,
  );
}

RiderPosition fix(GeoPoint p) => RiderPosition(point: p, time: DateTime.now().toUtc(), speedMs: 12, accuracyM: 5);

void main() {
  late SharedPreferences prefs;
  late _FakeVoice voice;
  var valhallaCalls = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    voice = _FakeVoice();
    valhallaCalls = 0;
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        rideControllerProvider.overrideWith(_Ride.new),
        voiceGuideProvider.overrideWithValue(voice),
        valhallaClientProvider.overrideWithValue(
          ValhallaClient(
            client: MockClient((_) async {
              valhallaCalls++;
              return http.Response.bytes(utf8.encode(fixture('valhalla_two_legs.json')), 200);
            }),
            limiter: RateLimiter(Duration.zero),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('inactif sans itinéraire ou hors balade', () {
    final c = container();
    c.listen(guidanceProvider, (_, _) {});
    expect(c.read(guidanceProvider), isNull);
    c.read(activeRouteProvider.notifier).set(fixtureRoute());
    expect(c.read(guidanceProvider), isNotNull);
    (c.read(rideControllerProvider.notifier) as _Ride).setStatus(RideStatus.idle);
    expect(c.read(guidanceProvider), isNull);
  });

  test('suit les positions et annonce à voix haute', () async {
    final c = container();
    final r = fixtureRoute();
    c.read(activeRouteProvider.notifier).set(r);
    c.listen(guidanceProvider, (_, _) {});
    final hub = c.read(positionHubProvider.notifier);

    hub.publish(fix(r.points.first));
    expect(c.read(guidanceProvider)!.snapshot, isNotNull);
    hub.publish(fix(Geo.pointAtDistance(r.points, r.maneuvers[1].distanceAlongM - 480)));
    final s = c.read(guidanceProvider)!.snapshot!;
    expect(s.distanceToNextM, closeTo(480, 3));
    await Future<void>.delayed(Duration.zero);
    expect(voice.said, hasLength(2));
    expect(voice.said.first, startsWith("C'est parti"));
    expect(voice.said.last, startsWith('Dans 500 mètres, tourne à gauche'));

    // Pause : l'état reste, pas de mise à jour.
    (c.read(rideControllerProvider.notifier) as _Ride).setStatus(RideStatus.paused);
    hub.publish(fix(Geo.pointAtDistance(r.points, 2000)));
    expect(c.read(guidanceProvider)!.snapshot!.progressM, lessThan(1000));
  });

  test('voix coupée dans les réglages', () async {
    await prefs.setBool('settings.voiceGuidance', false);
    final c = container();
    final r = fixtureRoute();
    c.read(activeRouteProvider.notifier).set(r);
    c.listen(guidanceProvider, (_, _) {});
    c.read(positionHubProvider.notifier).publish(fix(r.points.first));
    await Future<void>.delayed(Duration.zero);
    expect(voice.said, isEmpty);
  });

  test('recalcul depuis ma position', () async {
    final c = container();
    final r = fixtureRoute();
    c.read(activeRouteProvider.notifier).set(r);
    c.listen(guidanceProvider, (_, _) {});
    final hub = c.read(positionHubProvider.notifier);
    hub.publish(fix(r.points.first));
    final off = Geo.destination(Geo.pointAtDistance(r.points, 300), 0, 400);
    for (var i = 0; i < 3; i++) {
      hub.publish(fix(Geo.destination(off, 90, i * 10.0)));
    }
    expect(c.read(guidanceProvider)!.snapshot!.offRoute, isTrue);
    await c.read(guidanceProvider.notifier).recalculate();
    expect(valhallaCalls, 1);
    final active = c.read(activeRouteProvider)!;
    expect(active.id, r.id);
    expect(active.points, hasLength(16));
    expect(active.waypoints.first, Geo.destination(off, 90, 20));
    final g = c.read(guidanceProvider)!;
    expect(g.route.points, hasLength(16));
    expect(g.recalculating, isFalse);
    expect(voice.said, contains('Itinéraire recalculé.'));
  });

  test('recalcul impossible : message clair', () async {
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        rideControllerProvider.overrideWith(_Ride.new),
        voiceGuideProvider.overrideWithValue(voice),
        valhallaClientProvider.overrideWithValue(
          ValhallaClient(
            client: MockClient((_) async => http.Response('busy', 429)),
            limiter: RateLimiter(Duration.zero),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final r = fixtureRoute();
    c.read(activeRouteProvider.notifier).set(r);
    c.listen(guidanceProvider, (_, _) {});
    c.read(positionHubProvider.notifier).publish(fix(r.points.first));
    await c.read(guidanceProvider.notifier).recalculate();
    final g = c.read(guidanceProvider)!;
    expect(g.recalculating, isFalse);
    expect(g.error, contains('saturé'));
    expect(c.read(activeRouteProvider), same(r));
  });
}
