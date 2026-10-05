import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/models/garage.dart';
import '../data/models/planned_route.dart';
import '../data/repositories.dart';

/// Base locale, ouverte dans main() puis injectée.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider doit être surchargé dans main()'),
);

final rideRepositoryProvider = Provider<RideRepository>((ref) => RideRepository(ref.watch(databaseProvider)));
final routeRepositoryProvider = Provider<RouteRepository>((ref) => RouteRepository(ref.watch(databaseProvider)));
final garageRepositoryProvider = Provider<GarageRepository>((ref) => GarageRepository(ref.watch(databaseProvider)));

/// Motos du garage, rafraîchies à chaque modification.
final bikesProvider = StreamProvider<List<Bike>>((ref) async* {
  final repo = ref.watch(garageRepositoryProvider);
  yield await repo.bikes();
  await for (final _ in repo.changes) {
    yield await repo.bikes();
  }
});

/// Moto par défaut (null si garage vide).
final defaultBikeProvider = Provider<Bike?>((ref) {
  final bikes = ref.watch(bikesProvider).value ?? const [];
  if (bikes.isEmpty) return null;
  return bikes.firstWhere((b) => b.isDefault, orElse: () => bikes.first);
});

/// Itinéraire actuellement sélectionné pour être suivi (affiché sur la carte,
/// utilisé par le guidage pendant la balade). Null = balade libre.
class ActiveRouteNotifier extends Notifier<PlannedRoute?> {
  @override
  PlannedRoute? build() => null;

  void set(PlannedRoute? route) => state = route;
  void clear() => state = null;
}

final activeRouteProvider = NotifierProvider<ActiveRouteNotifier, PlannedRoute?>(ActiveRouteNotifier.new);
