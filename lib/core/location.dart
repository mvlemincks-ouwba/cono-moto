import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import 'geo.dart';

/// Position courante du motard, partagée dans toute l'app.
@immutable
class RiderPosition {
  const RiderPosition({
    required this.point,
    required this.time,
    this.speedMs = 0,
    this.heading,
    this.altitude,
    this.accuracyM,
    this.leanDeg = 0,
  });

  final GeoPoint point;
  final DateTime time;
  final double speedMs;
  final double? heading;
  final double? altitude;
  final double? accuracyM;

  /// Inclinaison signée en degrés (négatif = gauche), 0 hors balade.
  final double leanDeg;

  double get speedKmh => speedMs * 3.6;

  factory RiderPosition.fromGeolocator(Position p, {double leanDeg = 0}) => RiderPosition(
        point: GeoPoint(p.latitude, p.longitude),
        time: p.timestamp.toUtc(),
        speedMs: p.speed < 0 ? 0 : p.speed,
        heading: p.hasHeading && p.heading >= 0 ? p.heading : null,
        altitude: p.hasAltitude ? p.altitude : null,
        accuracyM: p.hasAccuracy ? p.accuracy : null,
        leanDeg: leanDeg,
      );

  RiderPosition withLean(double lean) => RiderPosition(
        point: point,
        time: time,
        speedMs: speedMs,
        heading: heading,
        altitude: altitude,
        accuracyM: accuracyM,
        leanDeg: lean,
      );
}

/// Résultat d'une demande d'accès à la localisation.
enum LocationAccess { granted, denied, deniedForever, serviceDisabled }

/// Accès au GPS (permissions, position ponctuelle, flux continu).
///
/// iPhone : la permission « Pendant l'utilisation » suffit. Une balade démarre
/// app ouverte ; avec le mode d'arrière-plan `location` (Info.plist) et
/// `allowBackgroundLocationUpdates`, iOS continue d'envoyer les positions écran
/// verrouillé (pastille bleue en haut de l'écran), comme Waze ou Google Maps.
/// On ne demande donc pas « Toujours » : rien n'est suivi hors balade.
class LocationService {
  const LocationService();

  /// Vérifie et demande si besoin la permission de localisation.
  ///
  /// [precise] : sur iPhone, si l'utilisateur n'a accordé qu'une position
  /// approximative, demande la position précise pour cette session (clé
  /// `balade` de NSLocationTemporaryUsageDescriptionDictionary).
  Future<LocationAccess> ensurePermission({bool precise = false}) async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceDisabled;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    switch (perm) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        if (precise && defaultTargetPlatform == TargetPlatform.iOS) await _ensurePreciseIos();
        return LocationAccess.granted;
      case LocationPermission.deniedForever:
        return LocationAccess.deniedForever;
      default:
        return LocationAccess.denied;
    }
  }

  static Future<void> _ensurePreciseIos() async {
    try {
      if (await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.reduced) {
        await Geolocator.requestTemporaryFullAccuracy(purposeKey: 'balade');
      }
    } catch (e) {
      debugPrint('Position précise non obtenue : $e');
    }
  }

  Future<void> openSettings() => Geolocator.openAppSettings();
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  /// Dernière position connue (rapide) puis position fraîche si besoin.
  Future<RiderPosition?> current({bool allowStale = true}) async {
    try {
      if (await ensurePermission() != LocationAccess.granted) return null;
      if (allowStale) {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null && DateTime.now().difference(last.timestamp).inMinutes < 5) {
          return RiderPosition.fromGeolocator(last);
        }
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      return RiderPosition.fromGeolocator(p);
    } catch (e) {
      debugPrint('Position indisponible : $e');
      return null;
    }
  }

  /// Flux GPS haute fréquence pour une balade, qui continue écran éteint :
  /// service au premier plan (notification permanente) sur Android, mises à
  /// jour en arrière-plan sur iPhone.
  Stream<Position> rideStream() => _gps.stream(ride: true);

  /// Flux GPS économe (carte ouverte, hors balade). Pendant une balade, il
  /// reçoit les positions du flux de balade.
  Stream<Position> idleStream() => _gps.stream(ride: false);

  /// Un seul flux natif partagé : geolocator ne garde qu'un flux à la fois (le
  /// premier ouvert, avec ses réglages). Sans ce multiplexeur, une balade
  /// lancée carte ouverte hériterait des réglages économes, sans suivi écran
  /// éteint.
  static final _gps = GpsMultiplexer(
    (ride) => Geolocator.getPositionStream(
      locationSettings: positionSettings(ride: ride, platform: defaultTargetPlatform),
    ),
  );

  /// Réglages GPS selon la plateforme et le mode (balade ou carte).
  @visibleForTesting
  static LocationSettings positionSettings({required bool ride, required TargetPlatform platform}) {
    switch (platform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return ride
            ? AppleSettings(
                accuracy: LocationAccuracy.bestForNavigation,
                // Moto sur route : calage sur le réseau routier par iOS.
                activityType: ActivityType.automotiveNavigation,
                distanceFilter: 0,
                // Ne jamais couper le GPS à l'arrêt (pause café, feu rouge…).
                pauseLocationUpdatesAutomatically: false,
                allowBackgroundLocationUpdates: true,
                showBackgroundLocationIndicator: true,
              )
            : AppleSettings(
                accuracy: LocationAccuracy.high,
                activityType: ActivityType.other,
                distanceFilter: 15,
                pauseLocationUpdatesAutomatically: true,
                // Hors balade : rien en arrière-plan (batterie, vie privée).
                allowBackgroundLocationUpdates: false,
                showBackgroundLocationIndicator: false,
              );
      case TargetPlatform.android:
        return ride
            ? AndroidSettings(
                accuracy: LocationAccuracy.bestForNavigation,
                distanceFilter: 0,
                intervalDuration: const Duration(seconds: 1),
                foregroundNotificationConfig: const ForegroundNotificationConfig(
                  notificationTitle: 'Cono Moto · balade en cours',
                  notificationText: 'Enregistrement GPS actif. Bonne route !',
                  notificationChannelName: 'Balade en cours',
                  enableWakeLock: true,
                  setOngoing: true,
                ),
              )
            : AndroidSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 15,
                intervalDuration: const Duration(seconds: 5),
              );
      default:
        return LocationSettings(
          accuracy: ride ? LocationAccuracy.bestForNavigation : LocationAccuracy.high,
          distanceFilter: ride ? 0 : 15,
        );
    }
  }
}

/// Partage un flux de positions natif entre plusieurs abonnés et l'ouvre
/// avec les réglages « balade » dès qu'un abonné balade est présent, sinon
/// avec les réglages économes. Le flux natif est rouvert à chaque changement
/// de mode et fermé quand plus personne n'écoute.
class GpsMultiplexer {
  GpsMultiplexer(this._open);

  /// Ouvre le flux natif (ride = réglages balade).
  final Stream<Position> Function(bool ride) _open;

  final _listeners = <_GpsListener>[];
  StreamSubscription<Position>? _sub;
  bool? _subRide;
  bool _syncing = false;
  bool _dirty = false;

  /// Mode du flux natif ouvert (null = fermé). Pour les tests.
  @visibleForTesting
  bool? get openMode => _subRide;

  Stream<Position> stream({required bool ride}) {
    late final _GpsListener listener;
    final controller = StreamController<Position>(
      onListen: () {
        _listeners.add(listener);
        _sync();
      },
      onCancel: () {
        _listeners.remove(listener);
        _sync();
      },
    );
    listener = _GpsListener(controller, ride);
    return controller.stream;
  }

  /// null = personne n'écoute, true = au moins une balade, false = carte seule.
  bool? get _wanted => _listeners.isEmpty ? null : _listeners.any((l) => l.ride);

  Future<void> _sync() async {
    if (_syncing) {
      _dirty = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _dirty = false;
        if (_wanted == _subRide) continue;
        final old = _sub;
        _sub = null;
        _subRide = null;
        // On attend la fermeture de l'ancien flux : geolocator ne rouvre un
        // flux avec de nouveaux réglages qu'une fois l'ancien libéré.
        if (old != null) {
          try {
            await old.cancel();
          } catch (e) {
            debugPrint('Fermeture du flux GPS : $e');
          }
        }
        final mode = _wanted;
        if (mode == null) continue;
        _subRide = mode;
        _sub = _open(mode).listen(
          (p) {
            for (final l in List.of(_listeners)) {
              l.controller.add(p);
            }
          },
          onError: (Object e, StackTrace st) {
            for (final l in List.of(_listeners)) {
              l.controller.addError(e, st);
            }
          },
          onDone: () {
            _sub = null;
            _subRide = null;
            for (final l in List.of(_listeners)) {
              l.controller.close();
            }
          },
        );
      } while (_dirty);
    } finally {
      _syncing = false;
    }
  }
}

class _GpsListener {
  _GpsListener(this.controller, this.ride);

  final StreamController<Position> controller;
  final bool ride;
}

final locationServiceProvider = Provider<LocationService>((ref) => const LocationService());

/// Dernière position connue du motard. Alimentée par l'enregistreur de balade
/// pendant une balade, sinon par la carte. Les autres modules (potes en direct,
/// guidage, stations proches) l'écoutent.
class PositionHub extends Notifier<RiderPosition?> {
  @override
  RiderPosition? build() => null;

  void publish(RiderPosition position) => state = position;
}

final positionHubProvider = NotifierProvider<PositionHub, RiderPosition?>(PositionHub.new);
