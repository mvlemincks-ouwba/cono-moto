import 'dart:async';

import 'package:sqflite/sqflite.dart';

import 'database.dart';
import 'models/garage.dart';
import 'models/planned_route.dart';
import 'models/ride.dart';

/// Notifie les écouteurs quand une table change (pour rafraîchir l'UI).
class _ChangeNotifier {
  final _controller = StreamController<void>.broadcast();
  Stream<void> get changes => _controller.stream;
  void notify() => _controller.add(null);
}

/// Accès aux balades enregistrées et à leurs points GPS.
class RideRepository {
  RideRepository(this._db);

  final AppDatabase _db;
  final _changes = _ChangeNotifier();

  Database get _d => _db.db;
  Stream<void> get changes => _changes.changes;

  Future<void> upsert(Ride ride) async {
    await _d.insert('rides', ride.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    _changes.notify();
  }

  Future<Ride?> get(String id) async {
    final rows = await _d.query('rides', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Ride.fromDb(rows.first);
  }

  /// Balades terminées, de la plus récente à la plus ancienne.
  Future<List<Ride>> list({int? limit, int? offset}) async {
    final rows = await _d.query('rides',
        where: 'ended_at IS NOT NULL', orderBy: 'started_at DESC', limit: limit, offset: offset);
    return rows.map(Ride.fromDb).toList();
  }

  /// Balade non terminée (ex : appli tuée pendant un enregistrement).
  Future<Ride?> unfinished() async {
    final rows = await _d.query('rides', where: 'ended_at IS NULL', orderBy: 'started_at DESC', limit: 1);
    return rows.isEmpty ? null : Ride.fromDb(rows.first);
  }

  Future<void> delete(String id) async {
    await _d.delete('track_points', where: 'ride_id = ?', whereArgs: [id]);
    await _d.delete('rides', where: 'id = ?', whereArgs: [id]);
    _changes.notify();
  }

  /// Ajoute des points à la suite de ceux déjà enregistrés.
  Future<void> appendPoints(String rideId, int firstSeq, List<TrackPoint> points) async {
    if (points.isEmpty) return;
    final batch = _d.batch();
    for (var i = 0; i < points.length; i++) {
      batch.insert('track_points', points[i].toDb(rideId, firstSeq + i),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<TrackPoint>> points(String rideId) async {
    final rows = await _d.query('track_points',
        where: 'ride_id = ?', whereArgs: [rideId], orderBy: 'seq ASC');
    return rows.map(TrackPoint.fromDb).toList();
  }

  Future<int> pointCount(String rideId) async {
    final r = await _d.rawQuery('SELECT COUNT(*) AS c FROM track_points WHERE ride_id = ?', [rideId]);
    return (r.first['c'] as int?) ?? 0;
  }
}

/// Balades planifiées (générées, importées GPX, partagées par les potes).
class RouteRepository {
  RouteRepository(this._db);

  final AppDatabase _db;
  final _changes = _ChangeNotifier();

  Database get _d => _db.db;
  Stream<void> get changes => _changes.changes;

  Future<void> upsert(PlannedRoute route) async {
    await _d.insert('routes', route.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    _changes.notify();
  }

  Future<PlannedRoute?> get(String id) async {
    final rows = await _d.query('routes', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : PlannedRoute.fromDb(rows.first);
  }

  Future<List<PlannedRoute>> list() async {
    final rows = await _d.query('routes', orderBy: 'favorite DESC, created_at DESC');
    return rows.map(PlannedRoute.fromDb).toList();
  }

  Future<void> delete(String id) async {
    await _d.delete('routes', where: 'id = ?', whereArgs: [id]);
    _changes.notify();
  }
}

/// Garage : motos, pleins, dépenses, entretien.
class GarageRepository {
  GarageRepository(this._db);

  final AppDatabase _db;
  final _changes = _ChangeNotifier();

  Database get _d => _db.db;
  Stream<void> get changes => _changes.changes;

  // ---- Motos ----

  Future<List<Bike>> bikes() async {
    final rows = await _d.query('bikes', orderBy: 'is_default DESC, name ASC');
    return rows.map(Bike.fromDb).toList();
  }

  Future<Bike?> bike(String id) async {
    final rows = await _d.query('bikes', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Bike.fromDb(rows.first);
  }

  /// Moto par défaut (ou la première), null si le garage est vide.
  Future<Bike?> defaultBike() async {
    final all = await bikes();
    if (all.isEmpty) return null;
    return all.firstWhere((b) => b.isDefault, orElse: () => all.first);
  }

  Future<void> upsertBike(Bike bike) async {
    await _d.transaction((txn) async {
      if (bike.isDefault) {
        await txn.update('bikes', {'is_default': 0}, where: 'id != ?', whereArgs: [bike.id]);
      }
      await txn.insert('bikes', bike.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _changes.notify();
  }

  Future<void> deleteBike(String id) async {
    await _d.delete('bikes', where: 'id = ?', whereArgs: [id]);
    await _d.delete('maintenance_items', where: 'bike_id = ?', whereArgs: [id]);
    await _d.delete('maintenance_logs', where: 'bike_id = ?', whereArgs: [id]);
    _changes.notify();
  }

  /// Ajoute des km parcourus au compteur et au compteur « depuis le plein ».
  Future<void> addDistance(String bikeId, double km) async {
    await _d.rawUpdate(
      'UPDATE bikes SET odometer_km = COALESCE(odometer_km,0) + ?, '
      'km_since_full = COALESCE(km_since_full,0) + ? WHERE id = ?',
      [km, km, bikeId],
    );
    _changes.notify();
  }

  // ---- Pleins ----

  Future<void> upsertFuel(FuelEntry entry) async {
    await _d.insert('fuel_entries', entry.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    _changes.notify();
  }

  Future<void> deleteFuel(String id) async {
    await _d.delete('fuel_entries', where: 'id = ?', whereArgs: [id]);
    _changes.notify();
  }

  Future<List<FuelEntry>> fuelEntries({String? bikeId, String? rideId}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (bikeId != null) {
      where.add('bike_id = ?');
      args.add(bikeId);
    }
    if (rideId != null) {
      where.add('ride_id = ?');
      args.add(rideId);
    }
    final rows = await _d.query('fuel_entries',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'date DESC');
    return rows.map(FuelEntry.fromDb).toList();
  }

  // ---- Dépenses ----

  Future<void> upsertExpense(Expense e) async {
    await _d.insert('expenses', e.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    _changes.notify();
  }

  Future<void> deleteExpense(String id) async {
    await _d.delete('expenses', where: 'id = ?', whereArgs: [id]);
    _changes.notify();
  }

  Future<List<Expense>> expenses({String? rideId, String? bikeId}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (rideId != null) {
      where.add('ride_id = ?');
      args.add(rideId);
    }
    if (bikeId != null) {
      where.add('bike_id = ?');
      args.add(bikeId);
    }
    final rows = await _d.query('expenses',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'date DESC');
    return rows.map(Expense.fromDb).toList();
  }

  // ---- Entretien ----

  Future<List<MaintenanceItem>> maintenanceItems(String bikeId) async {
    final rows = await _d.query('maintenance_items', where: 'bike_id = ?', whereArgs: [bikeId]);
    return rows.map(MaintenanceItem.fromDb).toList();
  }

  Future<void> upsertMaintenanceItem(MaintenanceItem item) async {
    await _d.insert('maintenance_items', item.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    _changes.notify();
  }

  Future<void> deleteMaintenanceItem(String id) async {
    await _d.delete('maintenance_items', where: 'id = ?', whereArgs: [id]);
    _changes.notify();
  }

  Future<void> addMaintenanceLog(MaintenanceLog log) async {
    await _d.insert('maintenance_logs', log.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    _changes.notify();
  }

  Future<List<MaintenanceLog>> maintenanceLogs(String bikeId) async {
    final rows = await _d.query('maintenance_logs',
        where: 'bike_id = ?', whereArgs: [bikeId], orderBy: 'date DESC');
    return rows.map(MaintenanceLog.fromDb).toList();
  }
}
