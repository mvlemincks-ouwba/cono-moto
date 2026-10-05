// STUB — à implémenter par le module « Garage & essence / historique ».
import 'package:flutter/material.dart';

/// Détail d'une balade enregistrée : carte, stats, graphes, coût.
class RideDetailScreen extends StatelessWidget {
  const RideDetailScreen({super.key, required this.rideId});

  final String rideId;

  static Route<void> pageRoute(String rideId) =>
      MaterialPageRoute(builder: (_) => RideDetailScreen(rideId: rideId));

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Text('Balade')));
}
