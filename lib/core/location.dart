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
class LocationService {
  const LocationService();

  /// Vérifie et demande si besoin la permission de localisation.
  Future<LocationAccess> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceDisabled;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    switch (perm) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return LocationAccess.granted;
      case LocationPermission.deniedForever:
        return LocationAccess.deniedForever;
      default:
        return LocationAccess.denied;
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

  /// Flux GPS haute fréquence pour une balade : service au premier plan
  /// (notification permanente) pour continuer écran éteint.
  Stream<Position> rideStream() => Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
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
        ),
      );

  /// Flux GPS économe (carte ouverte, hors balade).
  Stream<Position> idleStream() => Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 15,
          intervalDuration: const Duration(seconds: 5),
        ),
      );
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
