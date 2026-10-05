// STUB — à implémenter par le module « Garage & essence ». Contrat utilisé par la carte.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../data/models/shared.dart';

/// Stations autour d'un point (rayon ~10 km), triées par distance.
/// Le point doit être arrondi par l'appelant (~1 km) pour limiter les requêtes.
final stationsAroundProvider =
    FutureProvider.autoDispose.family<List<FuelStation>, GeoPoint>((ref, center) async => const []);
