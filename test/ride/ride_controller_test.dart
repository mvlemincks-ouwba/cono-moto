import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/location.dart';
import 'package:cono_moto/core/notifications.dart';
import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/data/database.dart';
import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/features/fuel/fuel_logic.dart';
import 'package:cono_moto/features/garage/autonomy.dart';
import 'package:cono_moto/features/ride/crash_alert_controller.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/features/ride/ride_display.dart';
import 'package:cono_moto/services/ride/ride_platform.dart';
import 'package:cono_moto/services/ride/ride_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';
import 'fake_ride_platform.dart';

class Harness {
  Harness._(this.db, this.platform, this.container, this.ownsDb);

  final AppDatabase db;
  final bool ownsDb;
  final FakeRidePlatform platform;
  final ProviderContainer container;
  GeoPoint pos = const GeoPoint(45.2, 5.7);
  double heading = 90;

  static Future<Harness> create({
    Map<String, Object> prefs = const {},
    AppDatabase? db,
    List overrides = const [],
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    final database = db ?? await openTestDatabase();
    final platform = FakeRidePlatform();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(p),
        databaseProvider.overrideWithValue(database),
        ridePlatformProvider.overrideWithValue(platform),
        ...overrides.cast(),
      ],
    );
    return Harness._(database, platform, container, db == null);
  }

  RideController get ctrl => container.read(rideControllerProvider.notifier);
  RideSessionState get state => container.read(rideControllerProvider);

  /// Roule [seconds] secondes à [kmh] (un fix par seconde).
  Future<void> ride(double kmh, int seconds, {double accuracy = 5}) async {
    for (var i = 0; i < seconds; i++) {
      platform.advance(const Duration(seconds: 1));
      pos = Geo.destination(pos, heading, kmh / 3.6);
      platform.gps.add(
        RiderPosition(
          point: pos,
          time: platform.clock,
          speedMs: kmh / 3.6,
          heading: heading,
          altitude: 300,
          accuracyM: accuracy,
        ),
      );
      await pump();
    }
  }

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  Future<void> dispose() async {
    container.dispose();
    // sqflite ffi partage la base « :memory: » tant qu'elle est ouverte.
    if (ownsDb) await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('balade complète : start → points → stop', () async {
    final h = await Harness.create();
    final garage = h.container.read(garageRepositoryProvider);
    await garage.upsertBike(const Bike(id: 'mt07', name: 'MT-07', isDefault: true, odometerKm: 1000));

    expect(await h.ctrl.start(), isTrue);
    expect(h.state.status, RideStatus.recording);
    expect(h.state.bikeName, 'MT-07');
    expect(h.platform.screenOn, [true]);
    final rideId = h.state.rideId!;
    final repo = h.container.read(rideRepositoryProvider);
    expect((await repo.unfinished())?.id, rideId);

    await h.ride(60, 121);
    expect(h.state.distanceM, closeTo(2000, 20));
    expect(h.state.speedKmh, closeTo(60, 0.01));
    expect(h.state.maxSpeedKmh, closeTo(60, 0.01));
    expect(h.state.track.length, greaterThan(10));
    expect(h.container.read(positionHubProvider)?.point, h.pos);

    final ride = await h.ctrl.stop();
    expect(ride, isNotNull);
    expect(ride!.endedAt, isNotNull);
    expect(ride.name, 'Petit tour du dimanche matin');
    expect(ride.stats.distanceM, closeTo(2000, 20));
    expect(ride.stats.movingTimeS, 120);
    expect(ride.previewPoints.length, greaterThanOrEqualTo(2));
    expect(h.state.status, RideStatus.idle);
    expect(h.state.lastRideId, rideId);
    expect(h.platform.screenOn.last, isFalse);

    // Les points sont toujours là (pas d'effacement par REPLACE + CASCADE).
    expect(await repo.pointCount(rideId), 121);
    expect((await repo.get(rideId))!.endedAt, isNotNull);
    expect(await repo.unfinished(), isNull);
    expect((await repo.list()).single.id, rideId);

    final bike = await garage.bike('mt07');
    expect(bike!.odometerKm, closeTo(1002, 0.05));
    await h.dispose();
  });

  test('plein fait en route : autonomie d’un réservoir plein, km comptés une seule fois', () async {
    final h = await Harness.create();
    final garage = h.container.read(garageRepositoryProvider);
    // 20 L à 5 L/100 : 10 L restants au départ (200 km depuis le plein).
    const gs = Bike(
      id: 'gs',
      name: 'R 1250 GS',
      isDefault: true,
      tankLiters: 20,
      consumptionL100: 5,
      kmSinceFullTank: 200,
      odometerKm: 30000,
    );
    await garage.upsertBike(gs);
    final sub = h.container.listen(autonomyProvider, (_, _) {});
    await h.ctrl.start();
    await h.ride(60, 121); // ≈ 2 km
    final before = h.state.uncountedKm;
    expect(before, closeTo(2, 0.05));

    // Plein complet saisi pendant la balade (comme FuelEntryForm._save).
    final bike = (await garage.bike('gs'))!;
    final entry = FuelEntry(
      id: 'f1',
      date: h.platform.clock,
      liters: 10.1,
      pricePerLiter: 1.9,
      bikeId: 'gs',
      odometerKm: 30002,
    );
    final out = applyFuelEntry(bike: bike, entry: entry, history: const [], rideKm: before);
    await garage.upsertFuel(entry);
    await garage.upsertBike(out.bike);
    h.ctrl.markGarageKmCounted('gs', before);
    expect(h.state.uncountedKm, closeTo(0, 0.01));
    for (var i = 0; i < 5; i++) {
      await h.pump();
    }
    expect(sub.read()!.remainingKm, closeTo(400, 1), reason: 'réservoir plein juste après le plein');

    await h.ride(60, 120); // ≈ 2 km de plus
    expect(sub.read()!.remainingKm, closeTo(398, 1));
    await h.ctrl.stop();
    final after = (await garage.bike('gs'))!;
    expect(after.odometerKm, closeTo(30004, 0.1), reason: 'pas de km comptés deux fois');
    expect(after.kmSinceFullTank, closeTo(2, 0.1));
    sub.close();
    await h.dispose();
  });

  test('plein pour une autre moto pendant la balade : rien n’est marqué comme compté', () async {
    final h = await Harness.create();
    await h.container.read(garageRepositoryProvider).upsertBike(const Bike(id: 'mt07', name: 'MT-07', isDefault: true));
    await h.ctrl.start();
    await h.ride(60, 61);
    h.ctrl.markGarageKmCounted('autre', 1);
    expect(h.state.garageKmCounted, 0);
    await h.ctrl.stop(save: false);
    expect(h.state.uncountedKm, 0, reason: 'plus de balade en cours');
    await h.dispose();
  });

  test('balade vide : stop(save: false) la supprime', () async {
    final h = await Harness.create();
    await h.ctrl.start();
    final id = h.state.rideId!;
    await h.ride(10, 20);
    expect(h.ctrl.isWorthSaving, isFalse);
    expect(await h.ctrl.stop(save: false), isNull);
    expect(await h.container.read(rideRepositoryProvider).get(id), isNull);
    expect(h.state.status, RideStatus.idle);
    await h.dispose();
  });

  test('pause / reprise : ni distance ni chrono pendant la pause', () async {
    final h = await Harness.create();
    await h.ctrl.start();
    await h.ride(72, 50); // 1 km
    h.ctrl.pause();
    expect(h.state.status, RideStatus.paused);
    // Pendant la pause, la moto bouge (on pousse la moto, on change de parking…).
    h.platform.advance(const Duration(minutes: 10));
    h.pos = Geo.destination(h.pos, 0, 3000);
    await h.ride(5, 3);
    h.ctrl.resume();
    expect(h.state.status, RideStatus.recording);
    await h.ride(72, 50); // 1 km
    // 2 segments de 50 fixes = 2 × 49 intervalles de 20 m.
    expect(h.state.distanceM, closeTo(1960, 5));
    expect(h.state.elapsed.inSeconds, closeTo(100, 2));

    final ride = await h.ctrl.stop();
    expect(ride!.stats.distanceM, closeTo(1960, 5));
    final pause = ride.events.singleWhere((e) => e.type == 'pause');
    expect(pause.value, closeTo(603, 1));
    await h.dispose();
  });

  test('permission refusée : pas de démarrage, message clair', () async {
    final h = await Harness.create();
    h.platform.access = LocationAccess.deniedForever;
    expect(await h.ctrl.start(), isFalse);
    expect(h.state.status, RideStatus.idle);
    expect(h.state.lastError, contains('réglages'));
    expect(h.state.locationAccess, LocationAccess.deniedForever);
    await h.dispose();
  });

  test('appli tuée : recoverUnfinished finalise la balade orpheline', () async {
    final db = await openTestDatabase();
    final first = await Harness.create(db: db);
    await first.container.read(garageRepositoryProvider).upsertBike(const Bike(id: 'b', name: 'Tracer'));
    await first.ctrl.start();
    final id = first.state.rideId!;
    await first.ride(90, 80); // 2 km
    first.ctrl.pause();
    first.platform.advance(const Duration(minutes: 5));
    first.ctrl.resume();
    await first.ride(90, 40); // 1 km
    await first.ctrl.debugFlush();
    // L'appli est tuée : pas de stop().
    first.container.dispose();

    final second = await Harness.create(db: db);
    final recovered = await second.ctrl.recoverUnfinished();
    expect(recovered, isNotNull);
    expect(recovered!.id, id);
    expect(recovered.endedAt, isNotNull);
    // 79 + 39 intervalles de 25 m.
    expect(recovered.stats.distanceM, closeTo(2950, 5));
    expect(recovered.name, isNot('Balade en cours'));
    expect(recovered.events.where((e) => e.type == 'pause'), hasLength(1));
    final repo = second.container.read(rideRepositoryProvider);
    expect(await repo.unfinished(), isNull);
    expect(await repo.pointCount(id), 120);
    expect((await second.container.read(garageRepositoryProvider).bike('b'))!.odometerKm, closeTo(2.95, 0.02));
    // Rien de plus à récupérer.
    expect(await second.ctrl.recoverUnfinished(), isNull);
    await second.dispose();
    await db.close();
  });

  test('orpheline trop courte : supprimée sans bruit', () async {
    final db = await openTestDatabase();
    final first = await Harness.create(db: db);
    await first.ctrl.start();
    final id = first.state.rideId!;
    await first.ride(20, 10);
    await first.ctrl.debugFlush();
    first.container.dispose();

    final second = await Harness.create(db: db);
    expect(await second.ctrl.recoverUnfinished(), isNull);
    expect(await second.container.read(rideRepositoryProvider).get(id), isNull);
    await second.dispose();
    await db.close();
  });

  test('itinéraire suivi : activé pendant la balade, nom repris, puis libéré', () async {
    final h = await Harness.create();
    final route = PlannedRoute(
      id: 'r1',
      name: 'Gorges de la Bourne',
      createdAt: DateTime.utc(2026),
      points: const [GeoPoint(45.2, 5.7), GeoPoint(45.3, 5.8)],
    );
    await h.ctrl.start(route: route);
    expect(h.container.read(activeRouteProvider)?.id, 'r1');
    expect(h.state.route?.name, 'Gorges de la Bourne');
    await h.ride(50, 30);
    final ride = await h.ctrl.stop();
    expect(ride!.routeId, 'r1');
    expect(ride.name, 'Gorges de la Bourne');
    expect(h.container.read(activeRouteProvider), isNull);
    await h.dispose();
  });

  test('autonomie basse : notification, voix et bandeau une seule fois', () async {
    const low = AutonomyInfo(remainingKm: 34.6, remainingLiters: 1.9, fillRatio: 0.12, low: true);
    final h = await Harness.create(overrides: [autonomyProvider.overrideWithValue(low)]);
    await h.ctrl.start();
    await h.pump();
    await h.pump();
    expect(h.state.lowFuelAlert, isTrue);
    final fuel = h.platform.notifications.where((n) => n.title.contains('plein')).toList();
    expect(fuel, hasLength(1));
    expect(fuel.single.body, contains('35 km'));
    expect(h.platform.spoken.single, contains('35 kilomètres'));
    h.ctrl.dismissLowFuelAlert();
    expect(h.state.lowFuelAlert, isFalse);
    await h.ride(60, 5);
    expect(h.platform.notifications.where((n) => n.title.contains('plein')), hasLength(1));
    await h.ctrl.stop(save: false);
    await h.dispose();
  });

  test('chute détectée : alerte déclenchée, « Je vais bien » réarme la détection', () async {
    final h = await Harness.create(prefs: {'settings.emergencyName': 'Maman', 'settings.emergencyPhone': '0600000000'});
    await h.ctrl.start();
    expect(h.state.crashDetectionArmed, isTrue);
    expect(h.state.smsAllowed, isTrue);
    await h.ride(50, 10);

    // Choc de 6 g (deux échantillons rapprochés).
    for (var i = 0; i < 2; i++) {
      h.platform.advance(const Duration(milliseconds: 20));
      h.platform.acc.add(SensorSample(h.platform.clock, 40, 45, 0));
      await h.pump();
    }
    // Puis immobile.
    await h.ride(0, 20);
    final alert = h.container.read(crashAlertProvider);
    expect(alert.phase, CrashAlertPhase.countdown);
    expect(alert.contactName, 'Maman');
    expect(h.platform.notifications.any((n) => n.channel == CmChannel.safety), isTrue);

    h.container.read(crashAlertProvider.notifier).imOk();
    expect(h.container.read(crashAlertProvider).phase, CrashAlertPhase.idle);
    expect(h.platform.sms, isEmpty);

    final ride = await h.ctrl.stop();
    expect(ride!.events.where((e) => e.type == 'crash'), hasLength(1));
    await h.dispose();
  });

  test('batterie : capteurs à 50 Hz seulement si l\'angle est à l\'écran', () async {
    final h = await Harness.create();
    final display = h.container.read(rideDisplayProvider);
    display.hudShown();
    expect(await h.ctrl.start(), isTrue);
    expect(h.platform.gyroRates, [true]);
    expect(h.platform.accRates, [true]);

    // Écran éteint : gyroscope ralenti, accéléromètre gardé pour la détection de chute.
    display.foreground = false;
    expect(h.platform.gyroRates, [true, false]);
    expect(h.platform.accRates, [true]);
    // Les mesures ralenties alimentent toujours l'angle.
    h.platform.gyro.add(SensorSample(h.platform.clock, 0, 0, 0));
    await h.pump();

    // Détection de chute coupée : l'accéléromètre ralentit aussi (au tic suivant).
    await h.container.read(settingsProvider.notifier).update((s) => s.copyWith(crashDetection: false));
    await h.ride(30, 2);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(h.platform.accRates.last, isFalse);

    // Retour à l'écran de balade : pleine fréquence.
    display.foreground = true;
    expect(h.platform.gyroRates.last, isTrue);
    expect(h.platform.accRates.last, isTrue);

    // Écran de balade réduit (la balade continue) : ralenti ; une seule
    // souscription par changement.
    display.hudHidden();
    expect(h.platform.gyroRates.last, isFalse);
    final calls = h.platform.gyroRates.length;
    display.foreground = false;
    expect(h.platform.gyroRates.length, calls);

    await h.ctrl.stop(save: false);
    display.hudShown();
    expect(h.platform.gyroRates.length, calls, reason: 'plus de balade : plus d\'abonnement');
    await h.dispose();
  });

  test('RideStore.save ne perd pas les points et notifie l\'historique', () async {
    final h = await Harness.create();
    final repo = h.container.read(rideRepositoryProvider);
    final store = h.container.read(rideStoreProvider);
    final ride = Ride(id: 'x', name: 'Test', startedAt: DateTime.utc(2026));
    await store.save(ride);
    await repo.appendPoints('x', 0, [TrackPoint(time: DateTime.utc(2026), lat: 45, lng: 5)]);
    var notified = 0;
    final sub = repo.changes.listen((_) => notified++);
    await store.save(ride.copyWith(name: 'Renommée'));
    await h.pump();
    expect(await repo.pointCount('x'), 1);
    expect((await repo.get('x'))!.name, 'Renommée');
    expect(notified, 1);
    await sub.cancel();
    await h.dispose();
  });

  test('settings : seuil de freinage repris des réglages', () async {
    final h = await Harness.create();
    await h.container.read(settingsProvider.notifier).update((s) => s.copyWith(hardBrakeThresholdG: 0.3));
    await h.ctrl.start();
    await h.ride(90, 10);
    // Freinage à ≈ 0,36 g.
    for (final kmh in [77.4, 64.8, 52.2, 39.6]) {
      await h.ride(kmh, 1);
    }
    await h.ride(39.6, 10);
    final ride = await h.ctrl.stop();
    expect(ride!.stats.hardBrakeCount, 1);
    await h.dispose();
  });

  test('G en direct : freinage négatif, accélération positive, max et altitude', () async {
    final h = await Harness.create();
    await h.ctrl.start();
    await h.ride(60, 15);
    expect(h.state.longG, closeTo(0, 0.02));
    expect(h.state.altitudeM, 300);

    // Freinage : -8 km/h par seconde (≈ 0,23 G).
    for (var v = 52.0; v >= 20; v -= 8) {
      await h.ride(v, 1);
    }
    expect(h.state.longG, lessThan(-0.1));
    expect(h.state.maxDecelG, greaterThan(0.15));

    // Accélération : +7 km/h par seconde.
    for (var v = 27.0; v <= 70; v += 7) {
      await h.ride(v, 1);
    }
    expect(h.state.longG, greaterThan(0.1));
    expect(h.state.maxAccelG, greaterThan(0.1));

    // À l'arrêt, plus de G affiché.
    await h.ride(5, 3);
    expect(h.state.longG, 0);
    await h.ctrl.stop(save: false);
    await h.dispose();
  });
}
