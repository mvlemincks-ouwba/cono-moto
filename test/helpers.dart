import 'package:cono_moto/data/database.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Base SQLite en mémoire pour les tests.
Future<AppDatabase> openTestDatabase() async {
  sqfliteFfiInit();
  return AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
}

/// Initialise la locale française (formatage des dates/nombres).
Future<void> initTestLocale() async {
  Intl.defaultLocale = 'fr_FR';
  await initializeDateFormatting('fr_FR');
}
