// Écran carte principal — intégré après les modules (stub temporaire).
import 'package:flutter/material.dart';

import '../../core/map/cm_map.dart';

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(body: CmMap());
}
