import 'dart:async';

import 'package:cono_moto/core/location.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

Position _pos(double lat) => Position(
      latitude: lat,
      longitude: 5,
      timestamp: DateTime.utc(2026, 6, 7, 9),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// Source native simulée : un contrôleur par ouverture, fermetures comptées.
class _FakeNative {
  final opened = <bool>[];
  final controllers = <StreamController<Position>>[];
  int cancels = 0;

  Stream<Position> open(bool ride) {
    opened.add(ride);
    final c = StreamController<Position>(onCancel: () => cancels++);
    controllers.add(c);
    return c.stream;
  }

  StreamController<Position> get last => controllers.last;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('GpsMultiplexer', () {
    test('carte seule : un flux économe, fermé quand plus personne n\'écoute', () async {
      final native = _FakeNative();
      final mux = GpsMultiplexer(native.open);
      final got = <double>[];
      final sub = mux.stream(ride: false).listen((p) => got.add(p.latitude));
      await _settle();
      expect(native.opened, [false]);
      expect(mux.openMode, isFalse);
      native.last.add(_pos(45));
      await _settle();
      expect(got, [45]);
      await sub.cancel();
      await _settle();
      expect(native.cancels, 1);
      expect(mux.openMode, isNull);
    });

    test('balade lancée carte ouverte : le flux natif est rouvert en mode balade', () async {
      final native = _FakeNative();
      final mux = GpsMultiplexer(native.open);
      final idle = <double>[];
      final ride = <double>[];
      final idleSub = mux.stream(ride: false).listen((p) => idle.add(p.latitude));
      await _settle();
      final rideSub = mux.stream(ride: true).listen((p) => ride.add(p.latitude));
      await _settle();
      expect(native.opened, [false, true], reason: 'sinon la balade hériterait des réglages économes');
      expect(native.cancels, 1);
      expect(mux.openMode, isTrue);

      native.last.add(_pos(46));
      await _settle();
      expect(ride, [46]);
      expect(idle, [46], reason: 'la carte reçoit aussi les positions de la balade');

      await rideSub.cancel();
      await _settle();
      expect(native.opened, [false, true, false], reason: 'fin de balade : retour au flux économe');
      expect(mux.openMode, isFalse);

      await idleSub.cancel();
      await _settle();
      expect(mux.openMode, isNull);
      expect(native.cancels, 3);
    });

    test('les erreurs GPS sont transmises aux abonnés', () async {
      final native = _FakeNative();
      final mux = GpsMultiplexer(native.open);
      final errors = <Object>[];
      final sub = mux.stream(ride: true).listen((_) {}, onError: errors.add);
      await _settle();
      native.last.addError(const LocationServiceDisabledException());
      await _settle();
      expect(errors.single, isA<LocationServiceDisabledException>());
      await sub.cancel();
    });
  });

  group('Réglages GPS par plateforme', () {
    test('iPhone, balade : navigation, arrière-plan autorisé, jamais en pause', () {
      final s = LocationService.positionSettings(ride: true, platform: TargetPlatform.iOS);
      expect(s, isA<AppleSettings>());
      final a = s as AppleSettings;
      expect(a.accuracy, LocationAccuracy.bestForNavigation);
      expect(a.activityType, ActivityType.automotiveNavigation);
      expect(a.distanceFilter, 0);
      expect(a.allowBackgroundLocationUpdates, isTrue);
      expect(a.pauseLocationUpdatesAutomatically, isFalse);
      expect(a.showBackgroundLocationIndicator, isTrue);
    });

    test('iPhone, carte : économe et rien en arrière-plan', () {
      final a = LocationService.positionSettings(ride: false, platform: TargetPlatform.iOS) as AppleSettings;
      expect(a.allowBackgroundLocationUpdates, isFalse);
      expect(a.distanceFilter, 15);
    });

    test('Android, balade : service au premier plan', () {
      final s = LocationService.positionSettings(ride: true, platform: TargetPlatform.android);
      expect(s, isA<AndroidSettings>());
      final a = s as AndroidSettings;
      expect(a.foregroundNotificationConfig, isNotNull);
      expect(a.intervalDuration, const Duration(seconds: 1));
      final idle = LocationService.positionSettings(ride: false, platform: TargetPlatform.android) as AndroidSettings;
      expect(idle.foregroundNotificationConfig, isNull);
    });
  });
}
