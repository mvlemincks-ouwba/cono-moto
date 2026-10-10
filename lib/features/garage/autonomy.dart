import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/models/garage.dart';
import '../ride/ride_controller.dart';

/// Estimation d'autonomie de la moto par défaut (tient compte de la balade en cours).
class AutonomyInfo {
  const AutonomyInfo({
    required this.remainingKm,
    required this.remainingLiters,
    required this.fillRatio,
    required this.low,
    this.tankLiters = 0,
    this.consumptionL100 = 0,
    this.inReserve = false,
    this.bikeId,
    this.bikeName,
  });

  final double remainingKm;
  final double remainingLiters;

  /// Niveau du réservoir 0..1.
  final double fillRatio;

  /// Sous le seuil d'alerte des réglages.
  final bool low;

  /// Capacité du réservoir (L).
  final double tankLiters;

  /// Consommation moyenne utilisée pour l'estimation (L/100 km).
  final double consumptionL100;

  /// Le niveau estimé est passé sous la réserve de la moto.
  final bool inReserve;
  final String? bikeId;
  final String? bikeName;
}

/// Calcul pur de l'autonomie.
///
/// litres restants = réservoir − (km depuis le plein + km de la balade en cours) × conso / 100.
AutonomyInfo computeAutonomy({required Bike bike, double rideKm = 0, int alertKm = 40}) {
  final tank = math.max(bike.tankLiters, 0.1);
  final conso = bike.consumptionL100 > 0 ? bike.consumptionL100 : 5.5;
  final usedKm = math.max(0.0, bike.kmSinceFullTank) + math.max(0.0, rideKm);
  final remainingLiters = (tank - usedKm * conso / 100).clamp(0.0, tank).toDouble();
  final remainingKm = remainingLiters / conso * 100;
  return AutonomyInfo(
    remainingKm: remainingKm,
    remainingLiters: remainingLiters,
    fillRatio: (remainingLiters / tank).clamp(0.0, 1.0).toDouble(),
    low: remainingKm < alertKm,
    tankLiters: tank,
    consumptionL100: conso,
    inReserve: remainingLiters <= bike.reserveLiters,
    bikeId: bike.id,
    bikeName: bike.name,
  );
}

/// Autonomie de la moto par défaut, mise à jour en direct pendant une balade.
final autonomyProvider = Provider<AutonomyInfo?>((ref) {
  final bike = ref.watch(defaultBikeProvider);
  if (bike == null) return null;
  final alertKm = ref.watch(settingsProvider.select((s) => s.autonomyAlertKm));
  // Seuls les km pas encore reportés sur la moto (un plein en route les a
  // déjà comptés).
  final rideKm = ref.watch(rideControllerProvider.select((s) => s.uncountedKm));
  return computeAutonomy(bike: bike, rideKm: rideKm, alertKm: alertKm);
});
