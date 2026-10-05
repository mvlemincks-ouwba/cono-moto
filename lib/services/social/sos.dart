// STUB — à implémenter par le module « Potes ». Utilisé par la détection de chute.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';

/// Diffuse une alerte SOS aux potes (marqueur rouge sur leur carte + notification).
abstract class SosBroadcaster {
  Future<void> broadcast(GeoPoint at, String message);
  Future<void> cancel();
}

class _NoopSos implements SosBroadcaster {
  @override
  Future<void> broadcast(GeoPoint at, String message) async {}

  @override
  Future<void> cancel() async {}
}

final sosBroadcasterProvider = Provider<SosBroadcaster>((ref) => _NoopSos());
