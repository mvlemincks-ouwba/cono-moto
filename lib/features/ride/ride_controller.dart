// STUB — à implémenter par le module « Balade » (enregistrement GPS, capteurs).
// Les champs et méthodes publics ci-dessous sont un contrat utilisé par les
// autres modules : ne pas les renommer ni changer leurs signatures.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/ride.dart';

enum RideStatus { idle, starting, recording, paused, finishing }

/// État de la balade en cours, observé par la carte, le HUD, l'autonomie…
class RideSessionState {
  const RideSessionState({
    this.status = RideStatus.idle,
    this.rideId,
    this.startedAt,
    this.route,
    this.distanceM = 0,
    this.movingTime = Duration.zero,
    this.elapsed = Duration.zero,
    this.speedKmh = 0,
    this.maxSpeedKmh = 0,
    this.avgSpeedKmh = 0,
    this.leanDeg = 0,
    this.maxLeanLeftDeg = 0,
    this.maxLeanRightDeg = 0,
    this.hardBrakeCount = 0,
    this.track = const [],
    this.gpsAccuracyM,
    this.lastError,
  });

  final RideStatus status;
  final String? rideId;
  final DateTime? startedAt;

  /// Itinéraire suivi (null = balade libre).
  final PlannedRoute? route;
  final double distanceM;
  final Duration movingTime;
  final Duration elapsed;
  final double speedKmh;
  final double maxSpeedKmh;
  final double avgSpeedKmh;

  /// Inclinaison instantanée signée (négatif = gauche).
  final double leanDeg;
  final double maxLeanLeftDeg;
  final double maxLeanRightDeg;
  final int hardBrakeCount;

  /// Trace parcourue (simplifiée) pour l'affichage.
  final List<GeoPoint> track;
  final double? gpsAccuracyM;
  final String? lastError;

  bool get isActive =>
      status == RideStatus.recording || status == RideStatus.paused || status == RideStatus.starting;
}

class RideController extends Notifier<RideSessionState> {
  @override
  RideSessionState build() => const RideSessionState();

  /// Démarre l'enregistrement. Retourne false si impossible (permission…).
  Future<bool> start({PlannedRoute? route}) async => false;

  void pause() {}

  void resume() {}

  /// Termine la balade ; retourne la balade enregistrée (null si annulée/vide).
  Future<Ride?> stop({bool save = true}) async => null;
}

final rideControllerProvider = NotifierProvider<RideController, RideSessionState>(RideController.new);
