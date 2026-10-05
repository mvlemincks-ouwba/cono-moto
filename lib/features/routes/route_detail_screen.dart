// STUB — à implémenter par le module « Balades à faire ».
import 'package:flutter/material.dart';

import '../../data/models/planned_route.dart';

/// Détail d'une balade planifiée : carte, profil, météo, bouton « C'est parti ».
class RouteDetailScreen extends StatelessWidget {
  const RouteDetailScreen({super.key, required this.route});

  final PlannedRoute route;

  static Route<void> pageRoute(PlannedRoute route) =>
      MaterialPageRoute(builder: (_) => RouteDetailScreen(route: route));

  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Text(route.name)));
}
