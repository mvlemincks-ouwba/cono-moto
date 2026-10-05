// STUB — à implémenter par le module « Balade » (HUD plein écran pendant la balade).
import 'package:flutter/material.dart';

class RideScreen extends StatelessWidget {
  const RideScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const RideScreen());

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Text('Balade')));
}
