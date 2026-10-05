import 'dart:convert';

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/location.dart';
import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/features/navigation/destination_routing.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/features/routes/guidance_controller.dart';
import 'package:cono_moto/features/routes/routes_providers.dart';
import 'package:cono_moto/services/routing/geocoder.dart';
import 'package:cono_moto/services/routing/http_support.dart';
import 'package:cono_moto/services/routing/valhalla_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../routes/fixtures.dart';

class _Ride extends RideController {
  @override
  RideSessionState build() => const RideSessionState(status: RideStatus.recording, rideId: 'ride-1');
}

class _FakeVoice extends VoiceGuide {
  final said = <String>[];

  @override
  Future<void> speak(String text) async => said.add(text);
}

void main() {
  late SharedPreferences prefs;
  late _FakeVoice voice;
  late List<Map<String, dynamic>> requests;
  var fail = false;

  final v = ValhallaClient.parseResponse(fixtureJson('valhalla_route.json') as Map<String, dynamic>);
  final t0 = DateTime.utc(2026, 10, 5, 10);
  DateTime at(num s) => t0.add(Duration(milliseconds: (s * 1000).round()));
  RiderPosition fix(GeoPoint p, num s) => RiderPosition(point: p, time: at(s), speedMs: 12, accuracyM: 5);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    voice = _FakeVoice();
    requests = [];
    fail = false;
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        rideControllerProvider.overrideWith(_Ride.new),
        voiceGuideProvider.overrideWithValue(voice),
        valhallaClientProvider.overrideWithValue(
          ValhallaClient(
            client: MockClient((req) async {
              requests.add(jsonDecode(req.body) as Map<String, dynamic>);
              if (fail) return http.Response('busy', 503);
              return http.Response.bytes(utf8.encode(fixture('valhalla_route.json')), 200);
            }),
            limiter: RateLimiter(Duration.zero),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  PlannedRoute balade() => PlannedRoute(
    id: 'b1',
    name: 'Boucle',
    createdAt: t0,
    points: v.points,
    distanceM: v.distanceM,
    durationS: v.durationS,
    maneuvers: v.maneuvers,
  );

  /// Point à 400 m au nord du tracé (hors itinéraire).
  GeoPoint offPoint(PlannedRoute r, [double east = 0]) =>
      Geo.destination(Geo.destination(Geo.pointAtDistance(r.points, 300), 0, 400), 90, east);

  test('hors itinéraire : recalcul automatique annoncé, après un délai de grâce', () async {
    final c = container();
    final r = balade();
    c.read(activeRouteProvider.notifier).set(r);
    c.listen(guidanceProvider, (_, _) {});
    final hub = c.read(positionHubProvider.notifier);

    hub.publish(fix(r.points.first, 0));
    for (var i = 1; i <= 3; i++) {
      hub.publish(fix(offPoint(r, i * 10.0), i));
    }
    expect(c.read(guidanceProvider)!.snapshot!.offRoute, isTrue);
    expect(requests, isEmpty, reason: 'pas tout de suite : le temps d\'un demi-tour');

    hub.publish(fix(offPoint(r, 40), 8));
    expect(c.read(guidanceProvider)!.recalculating, isTrue);
    expect(voice.said.last, "Recalcul de l'itinéraire.");
    await pumpEventQueue();
    expect(requests, hasLength(1));
    // Depuis ma position, vers la suite de la balade.
    final locs = requests.single['locations'] as List;
    expect((locs.first as Map)['lat'], closeTo(offPoint(r, 40).lat, 1e-5));
    expect(locs.length, greaterThanOrEqualTo(2));
    final g = c.read(guidanceProvider)!;
    expect(g.recalculating, isFalse);
    expect(g.route.id, r.id);
    expect(identical(c.read(activeRouteProvider), r), isFalse);
    expect(voice.said, isNot(contains('Itinéraire recalculé.')));
  });

  test('anti-spam : 20 s entre deux essais, 3 max en 5 min', () async {
    final c = container();
    final r = balade();
    c.read(activeRouteProvider.notifier).set(r);
    c.listen(guidanceProvider, (_, _) {});
    final hub = c.read(positionHubProvider.notifier);
    fail = true; // serveur saturé : on reste hors itinéraire
    hub.publish(fix(r.points.first, 0));
    for (var s = 1; s <= 200; s++) {
      hub.publish(fix(offPoint(r, -s * 2.0), s));
      await pumpEventQueue();
    }
    // Hors itinéraire à 3 s, premier essai à 7 s, puis 27 s et 47 s ; ensuite
    // plus rien avant que le premier essai sorte de la fenêtre de 5 min.
    expect(requests, hasLength(3));
    expect(c.read(guidanceProvider)!.error, contains('surchargé'));
    for (var s = 201; s <= 320; s++) {
      hub.publish(fix(offPoint(r, -s * 2.0), s));
      await pumpEventQueue();
    }
    expect(requests, hasLength(4));
  });

  test('itinéraire « Où on va ? » : recalcul direct vers la destination', () async {
    final c = container();
    const dest = Place(name: 'Dourdan', point: GeoPoint(48.6648, 1.8439));
    final r = buildDestinationRoute(
      v: v,
      start: v.points.first,
      destination: dest,
      option: DestinationOption.smallRoads,
      now: t0,
    );
    c.read(activeRouteProvider.notifier).set(r);
    c.listen(guidanceProvider, (_, _) {});
    final hub = c.read(positionHubProvider.notifier);
    hub.publish(fix(r.points.first, 0));
    for (var i = 1; i <= 6; i++) {
      hub.publish(fix(offPoint(r, i * 10.0), i * 1.5));
    }
    await pumpEventQueue();
    expect(requests, hasLength(1));
    final body = requests.single;
    final locs = body['locations'] as List;
    expect(locs, hasLength(2));
    expect((locs.last as Map)['lat'], closeTo(dest.point.lat, 1e-6));
    final moto = (body['costing_options'] as Map)['motorcycle'] as Map;
    expect(moto['use_highways'], 0.0, reason: 'mêmes préférences que l\'option choisie');
    expect(isDestinationRoute(c.read(activeRouteProvider)!), isTrue);
  });

  test('bouton de secours : recalcul manuel, puis pas d\'automatique dans la foulée', () async {
    final c = container();
    final r = balade();
    c.read(activeRouteProvider.notifier).set(r);
    c.listen(guidanceProvider, (_, _) {});
    final hub = c.read(positionHubProvider.notifier);
    fail = true;
    hub.publish(fix(r.points.first, 0));
    for (var i = 1; i <= 3; i++) {
      hub.publish(fix(offPoint(r, i * 10.0), i));
    }
    await c.read(guidanceProvider.notifier).recalculate();
    expect(requests, hasLength(1));
    expect(voice.said, isNot(contains("Recalcul de l'itinéraire.")));
    for (var s = 4; s <= 20; s++) {
      hub.publish(fix(offPoint(r, -s * 2.0), s));
      await pumpEventQueue();
    }
    expect(requests, hasLength(1), reason: 'moins de 20 s après le recalcul manuel');
  });
}
