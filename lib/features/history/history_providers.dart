import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models/garage.dart';
import '../../data/models/ride.dart';

/// Balades terminées (la plus récente d'abord), rafraîchies à chaque changement.
final ridesProvider = StreamProvider<List<Ride>>((ref) async* {
  final repo = ref.watch(rideRepositoryProvider);
  yield await repo.list();
  await for (final _ in repo.changes) {
    yield await repo.list();
  }
});

/// Une balade (null si supprimée), rafraîchie après renommage / notes.
final rideProvider = StreamProvider.autoDispose.family<Ride?, String>((ref, id) async* {
  final repo = ref.watch(rideRepositoryProvider);
  yield await repo.get(id);
  await for (final _ in repo.changes) {
    yield await repo.get(id);
  }
});

/// Points GPS complets d'une balade.
final rideTrackProvider = FutureProvider.autoDispose.family<List<TrackPoint>, String>(
  (ref, id) => ref.watch(rideRepositoryProvider).points(id),
);

/// Pleins et dépenses liés à une balade.
class RideCostData {
  const RideCostData({required this.fuel, required this.expenses, this.lastPrice});

  final List<FuelEntry> fuel;
  final List<Expense> expenses;

  /// Dernier prix au litre connu (pour estimer l'essence).
  final double? lastPrice;
}

final rideCostDataProvider = StreamProvider.autoDispose.family<RideCostData, String>((ref, rideId) async* {
  final repo = ref.watch(garageRepositoryProvider);
  Future<RideCostData> load() async {
    final fuel = await repo.fuelEntries(rideId: rideId);
    final expenses = await repo.expenses(rideId: rideId);
    final all = await repo.fuelEntries();
    return RideCostData(fuel: fuel, expenses: expenses, lastPrice: all.isEmpty ? null : all.first.pricePerLiter);
  }

  yield await load();
  await for (final _ in repo.changes) {
    yield await load();
  }
});
