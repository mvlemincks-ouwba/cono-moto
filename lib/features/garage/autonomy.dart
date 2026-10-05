// STUB — à implémenter par le module « Garage & essence ». Utilisé par le HUD de balade.
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Estimation d'autonomie de la moto par défaut (tient compte de la balade en cours).
class AutonomyInfo {
  const AutonomyInfo({
    required this.remainingKm,
    required this.remainingLiters,
    required this.fillRatio,
    required this.low,
  });

  final double remainingKm;
  final double remainingLiters;

  /// Niveau du réservoir 0..1.
  final double fillRatio;

  /// Sous le seuil d'alerte des réglages.
  final bool low;
}

final autonomyProvider = Provider<AutonomyInfo?>((ref) => null);
