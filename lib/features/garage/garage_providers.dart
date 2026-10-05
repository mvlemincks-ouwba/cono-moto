import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/garage.dart';
import '../../data/models/ride.dart';

/// Fusionne plusieurs flux de « changements » en un seul.
Stream<void> mergeChanges(List<Stream<void>> streams) {
  late final StreamController<void> controller;
  final subs = <StreamSubscription<void>>[];
  controller = StreamController<void>(
    onListen: () {
      for (final s in streams) {
        subs.add(s.listen(controller.add));
      }
    },
    onCancel: () async {
      for (final s in subs) {
        await s.cancel();
      }
      subs.clear();
    },
  );
  return controller.stream;
}

/// Moto affichée dans l'écran Garage (null = moto par défaut).
class SelectedBikeNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? bikeId) => state = bikeId;
}

final selectedBikeIdProvider = NotifierProvider<SelectedBikeNotifier, String?>(SelectedBikeNotifier.new);

/// Moto affichée dans le garage.
final garageBikeProvider = Provider<Bike?>((ref) {
  final bikes = ref.watch(bikesProvider).value ?? const <Bike>[];
  if (bikes.isEmpty) return null;
  final selected = ref.watch(selectedBikeIdProvider);
  return bikes.where((b) => b.id == selected).firstOrNull ?? ref.watch(defaultBikeProvider);
});

/// Données du garage pour une moto.
class BikeGarageData {
  const BikeGarageData({
    required this.fuel,
    required this.expenses,
    required this.items,
    required this.logs,
    required this.ridesKm,
  });

  /// Pleins, du plus récent au plus ancien.
  final List<FuelEntry> fuel;

  /// Dépenses, de la plus récente à la plus ancienne.
  final List<Expense> expenses;
  final List<MaintenanceItem> items;

  /// Historique d'entretien, du plus récent au plus ancien.
  final List<MaintenanceLog> logs;

  /// Km des balades enregistrées avec cette moto.
  final double ridesKm;
}

/// Pleins, dépenses et entretien d'une moto, rafraîchis à chaque modification.
final bikeGarageDataProvider = StreamProvider.autoDispose.family<BikeGarageData, String>((ref, bikeId) async* {
  final garage = ref.watch(garageRepositoryProvider);
  final rides = ref.watch(rideRepositoryProvider);

  Future<BikeGarageData> load() async {
    final results = await Future.wait<Object>([
      garage.fuelEntries(bikeId: bikeId),
      garage.expenses(bikeId: bikeId),
      garage.maintenanceItems(bikeId),
      garage.maintenanceLogs(bikeId),
      rides.list(),
    ]);
    final allRides = results[4] as List<Ride>;
    var km = 0.0;
    for (final r in allRides) {
      if (r.bikeId == bikeId) km += r.stats.distanceM / 1000;
    }
    return BikeGarageData(
      fuel: results[0] as List<FuelEntry>,
      expenses: results[1] as List<Expense>,
      items: results[2] as List<MaintenanceItem>,
      logs: results[3] as List<MaintenanceLog>,
      ridesKm: km,
    );
  }

  yield await load();
  await for (final _ in mergeChanges([garage.changes, rides.changes])) {
    yield await load();
  }
});
