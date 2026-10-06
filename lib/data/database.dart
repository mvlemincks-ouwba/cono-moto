import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Base locale SQLite de l'app (balades, garage, itinéraires).
///
/// Les tests peuvent injecter une [DatabaseFactory] (sqflite_common_ffi) et un
/// chemin `inMemoryDatabasePath`.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  /// Version du schéma, notée dans les sauvegardes (voir backup.dart) : une
  /// sauvegarde plus récente que l'appli est refusée.
  static const int version = 1;

  static Future<AppDatabase> open({DatabaseFactory? factory, String? path}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'cono_moto.db');
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, v) async => _migrate(db, 0, v),
        onUpgrade: _migrate,
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _migrate(Database db, int from, int to) async {
    final batch = db.batch();
    if (from < 1) {
      batch.execute('''
        CREATE TABLE rides (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          started_at INTEGER NOT NULL,
          ended_at INTEGER,
          bike_id TEXT,
          route_id TEXT,
          distance_m REAL NOT NULL DEFAULT 0,
          stats TEXT NOT NULL,
          events TEXT NOT NULL DEFAULT '[]',
          preview TEXT NOT NULL DEFAULT '',
          notes TEXT NOT NULL DEFAULT '',
          shared INTEGER NOT NULL DEFAULT 0
        )''');
      batch.execute('CREATE INDEX idx_rides_started ON rides(started_at DESC)');
      batch.execute('''
        CREATE TABLE track_points (
          ride_id TEXT NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
          seq INTEGER NOT NULL,
          t INTEGER NOT NULL,
          lat REAL NOT NULL,
          lng REAL NOT NULL,
          alt REAL,
          speed REAL,
          heading REAL,
          acc REAL,
          lean REAL,
          accel REAL,
          PRIMARY KEY (ride_id, seq)
        )''');
      batch.execute('''
        CREATE TABLE routes (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          favorite INTEGER NOT NULL DEFAULT 0,
          data TEXT NOT NULL
        )''');
      batch.execute('''
        CREATE TABLE bikes (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          brand TEXT, model TEXT, year INTEGER,
          odometer_km REAL, tank_l REAL, reserve_l REAL, conso_l100 REAL,
          fuel_type TEXT, color INTEGER, is_default INTEGER NOT NULL DEFAULT 0,
          km_since_full REAL NOT NULL DEFAULT 0
        )''');
      batch.execute('''
        CREATE TABLE fuel_entries (
          id TEXT PRIMARY KEY,
          date INTEGER NOT NULL,
          liters REAL NOT NULL,
          price_per_l REAL NOT NULL,
          bike_id TEXT, ride_id TEXT, odometer_km REAL,
          full_tank INTEGER NOT NULL DEFAULT 1,
          station_id TEXT, station_name TEXT, fuel_type TEXT,
          lat REAL, lng REAL
        )''');
      batch.execute('CREATE INDEX idx_fuel_ride ON fuel_entries(ride_id)');
      batch.execute('''
        CREATE TABLE expenses (
          id TEXT PRIMARY KEY,
          date INTEGER NOT NULL,
          amount REAL NOT NULL,
          category TEXT NOT NULL,
          label TEXT, ride_id TEXT, bike_id TEXT
        )''');
      batch.execute('CREATE INDEX idx_expenses_ride ON expenses(ride_id)');
      batch.execute('''
        CREATE TABLE maintenance_items (
          id TEXT PRIMARY KEY,
          bike_id TEXT NOT NULL,
          type TEXT NOT NULL,
          label TEXT,
          interval_km INTEGER, interval_months INTEGER,
          last_done_km REAL, last_done_date INTEGER,
          notes TEXT
        )''');
      batch.execute('''
        CREATE TABLE maintenance_logs (
          id TEXT PRIMARY KEY,
          item_id TEXT NOT NULL,
          bike_id TEXT NOT NULL,
          date INTEGER NOT NULL,
          odometer_km REAL, cost REAL, notes TEXT
        )''');
    }
    await batch.commit(noResult: true);
  }

  Future<void> close() => db.close();
}
