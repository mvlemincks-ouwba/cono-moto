import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/database.dart';
import '../../data/models/ride.dart';
import '../../data/repositories.dart';

/// Enregistrement d'une balade qui préserve ses points GPS.
///
/// `RideRepository.upsert` fait un `INSERT OR REPLACE` : en SQLite, REPLACE
/// supprime la ligne existante avant de réinsérer, ce qui déclenche le
/// `ON DELETE CASCADE` de `track_points` et **efface tous les points** de la
/// balade. Ici, une balade déjà en base est mise à jour en place.
class RideStore {
  RideStore(this._db, this._repo);

  final AppDatabase _db;
  final RideRepository _repo;

  /// Identifiant qui n'existe jamais : sert à déclencher la notification de
  /// changement du dépôt sans rien supprimer.
  static const _noRide = '__cono_moto_no_ride__';

  Future<void> save(Ride ride) async {
    final updated = await _db.db.update('rides', ride.toDb(), where: 'id = ?', whereArgs: [ride.id]);
    if (updated == 0) {
      await _repo.upsert(ride);
      return;
    }
    // Rafraîchit les écrans qui écoutent RideRepository.changes (historique…).
    await _repo.delete(_noRide);
  }
}

final rideStoreProvider = Provider<RideStore>(
  (ref) => RideStore(ref.watch(databaseProvider), ref.watch(rideRepositoryProvider)),
);
