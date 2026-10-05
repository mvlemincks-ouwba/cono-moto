// STUB — écran des réglages (implémenté par l'intégration principale).
import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const SettingsScreen());

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Text('Réglages')));
}
