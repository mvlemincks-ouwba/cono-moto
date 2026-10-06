import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/data/backup.dart';
import 'package:cono_moto/data/database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Base dans un fichier temporaire : deux bases `:memory:` ouvertes en même
/// temps seraient la même (il faut ici deux « téléphones »).
Future<AppDatabase> _openFileDb() async {
  sqfliteFfiInit();
  final dir = await Directory.systemTemp.createTemp('cono_moto_backup_test');
  addTearDown(() => dir.delete(recursive: true));
  return AppDatabase.open(factory: databaseFactoryFfi, path: '${dir.path}/cono_moto.db');
}

/// Tables « futures » ajoutées aux bases de test : une avec un BLOB, une
/// WITHOUT ROWID. Elles doivent passer dans la sauvegarde sans code dédié.
Future<AppDatabase> _openDb() async {
  final db = await _openFileDb();
  await db.db.execute('CREATE TABLE photos (id INTEGER PRIMARY KEY, ride_id TEXT, data BLOB NOT NULL)');
  await db.db.execute(
    'CREATE TABLE tags (ride_id TEXT NOT NULL, tag TEXT NOT NULL, PRIMARY KEY (ride_id, tag)) WITHOUT ROWID',
  );
  return db;
}

Future<SharedPreferences> _prefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

const _pointCount = AppBackup.pageSize * 2 + 345;

/// Remplit toutes les tables de l'appli.
Future<void> _fill(AppDatabase db) async {
  final d = db.db;
  await d.insert('bikes', {
    'id': 'b1',
    'name': 'La Bleue',
    'brand': 'Yamaha',
    'model': 'Tracer 9 GT',
    'year': 2023,
    'odometer_km': 18432.5,
    'tank_l': 18.0,
    'reserve_l': 3.5,
    'conso_l100': double.infinity,
    'fuel_type': 'sp98',
    'color': 0xFF4EA8FF,
    'is_default': 1,
    'km_since_full': 190.0,
  });
  await d.insert('rides', {
    'id': 'r1',
    'name': "Col de l'Iseran — été 🏍️",
    'started_at': DateTime.utc(2026, 7, 14, 8).millisecondsSinceEpoch,
    'ended_at': DateTime.utc(2026, 7, 14, 13).millisecondsSinceEpoch,
    'bike_id': 'b1',
    'route_id': 'rt1',
    'distance_m': 212345.67,
    'stats': jsonEncode({'distanceM': 212345.67, 'maxLeanLeftDeg': 41}),
    'events': '[]',
    'preview': '45.1,6.9;45.2,7.0',
    'notes': 'Super journée\navec les potes',
    'shared': 1,
  });
  await d.insert('rides', {
    'id': 'r2',
    'name': 'Balade non terminée',
    'started_at': DateTime.utc(2026, 7, 15, 8).millisecondsSinceEpoch,
    'stats': '{}',
  });
  final batch = d.batch();
  final t0 = DateTime.utc(2026, 7, 14, 8).millisecondsSinceEpoch;
  for (var i = 0; i < _pointCount; i++) {
    batch.insert('track_points', {
      'ride_id': 'r1',
      'seq': i,
      't': t0 + i * 1000,
      'lat': 45.1 + i * 1e-5,
      'lng': 6.9 + i * 1e-5,
      'alt': i.isEven ? 1800.5 + i : null,
      'speed': 12.25,
      'heading': 90.0,
      'acc': 4.0,
      'lean': -12.5,
      'accel': 0.1,
    });
  }
  await batch.commit(noResult: true);
  await d.insert('routes', {
    'id': 'rt1',
    'name': 'Boucle du Vercors',
    'created_at': DateTime.utc(2026, 6, 1).millisecondsSinceEpoch,
    'favorite': 1,
    'data': jsonEncode({'points': [[45.0, 5.5], [45.1, 5.6]]}),
  });
  await d.insert('fuel_entries', {
    'id': 'f1',
    'date': DateTime.utc(2026, 7, 14, 10).millisecondsSinceEpoch,
    'liters': 14.2,
    'price_per_l': 1.849,
    'bike_id': 'b1',
    'ride_id': 'r1',
    'odometer_km': 18240.0,
    'full_tank': 1,
    'station_id': '38000001',
    'station_name': '12 Avenue de la Gare, Grenoble',
    'fuel_type': 'sp98',
    'lat': 45.19,
    'lng': 5.72,
  });
  await d.insert('expenses', {
    'id': 'e1',
    'date': DateTime.utc(2026, 7, 14, 12).millisecondsSinceEpoch,
    'amount': 23.5,
    'category': 'food',
    'label': 'Resto du col',
    'ride_id': 'r1',
    'bike_id': 'b1',
  });
  await d.insert('maintenance_items', {
    'id': 'm1',
    'bike_id': 'b1',
    'type': 'chain',
    'label': 'Graissage chaîne',
    'interval_km': 600,
    'interval_months': null,
    'last_done_km': 18000.0,
    'last_done_date': DateTime.utc(2026, 7, 1).millisecondsSinceEpoch,
    'notes': null,
  });
  await d.insert('maintenance_logs', {
    'id': 'l1',
    'item_id': 'm1',
    'bike_id': 'b1',
    'date': DateTime.utc(2026, 7, 1).millisecondsSinceEpoch,
    'odometer_km': 18000.0,
    'cost': 0.0,
    'notes': 'Fait au garage',
  });
  await d.insert('photos', {
    'ride_id': 'r1',
    'data': Uint8List.fromList([0, 1, 2, 254, 255, 0x1f, 0x8b]),
  });
  await d.insert('tags', {'ride_id': 'r1', 'tag': 'cols'});
}

/// Toutes les lignes de toutes les tables, dans un ordre stable.
Future<Map<String, List<Map<String, Object?>>>> _dump(AppDatabase db) async => {
      for (final t in await AppBackup.tables(db.db))
        t: await db.db.query(t, orderBy: t == 'tags' ? 'ride_id, tag' : 'rowid'),
    };

/// Fichier de sauvegarde fabriqué à la main (gzip + JSON).
List<int> _file(Map<String, Object?> content) => gzip.encode(utf8.encode(jsonEncode(content)));

Map<String, Object?> _content({
  int version = AppBackup.version,
  int schemaVersion = AppDatabase.version,
  Map<String, Object?> tables = const {},
  Map<String, Object?> prefs = const {},
}) =>
    {
      'format': AppBackup.format,
      'version': version,
      'schemaVersion': schemaVersion,
      'createdAt': '2026-10-01T18:42:00.000Z',
      'appBuild': '42',
      'tables': tables,
      'prefs': prefs,
    };

Map<String, Object?> _ride(String id, {String? name = 'Balade', Map<String, Object?> extra = const {}}) => {
      'id': id,
      'name': ?name,
      'started_at': DateTime.utc(2026, 5, 1).millisecondsSinceEpoch,
      'ended_at': DateTime.utc(2026, 5, 1, 2).millisecondsSinceEpoch,
      'distance_m': 1000.0,
      'stats': '{}',
      ...extra,
    };

Matcher _backupError(String message) =>
    isA<BackupException>().having((e) => e.message, 'message', message);

void main() {
  test('nom du fichier : cono-moto-AAAA-MM-JJ.cmbackup', () {
    expect(AppBackup.fileName(DateTime(2026, 3, 7, 23, 59)), 'cono-moto-2026-03-07.cmbackup');
  });

  test('aller-retour : toutes les tables et les réglages reviennent à l\'identique', () async {
    final source = await _openDb();
    await _fill(source);
    final expected = await _dump(source);
    // Garde-fou : chaque table de l'appli (même ajoutée plus tard) est remplie ici.
    for (final e in expected.entries) {
      expect(e.value, isNotEmpty, reason: 'table ${e.key} vide dans le test de sauvegarde');
    }
    expect(expected['track_points'], hasLength(_pointCount));

    final srcPrefs = await _prefs({
      'settings.themeMode': 'light',
      'settings.stragglerAlertKm': 4.5,
      'settings.hardBrakeThresholdG': 1.0,
      'settings.autonomyAlertKm': 30,
      'settings.voiceGuidance': false,
      'dash.views': '[{"id":"vue1"}]',
      'misc.list': ['a', 'b'],
    });
    final progress = <double>[];
    final bytes = await AppBackup.export(
      source,
      srcPrefs,
      now: DateTime.utc(2026, 10, 6, 9, 30),
      appBuild: '123',
      onProgress: progress.add,
    );
    expect(progress.last, 1.0);
    expect(bytes.take(2), [0x1f, 0x8b], reason: 'fichier compressé en gzip');

    final data = await AppBackup.read(bytes);
    expect(data.schemaVersion, AppDatabase.version);
    expect(data.createdAt, DateTime.utc(2026, 10, 6, 9, 30));
    expect(data.appBuild, '123');
    expect(data.rideCount, 1, reason: 'seules les balades terminées comptent');

    // Autre téléphone, avec déjà des données qui doivent disparaître.
    final target = await _openDb();
    await target.db.insert('rides', _ride('vieille'));
    await target.db.insert('track_points', {'ride_id': 'vieille', 'seq': 0, 't': 0, 'lat': 1.0, 'lng': 2.0});
    await target.db.insert('bikes', {'id': 'autre', 'name': 'Autre moto'});
    final dstPrefs = await _prefs({'settings.themeMode': 'system'});
    final restoreProgress = <double>[];
    await AppBackup.restore(target, dstPrefs, data, onProgress: restoreProgress.add);
    expect(restoreProgress.last, 1.0);

    expect(await _dump(target), expected);
    final blob = (await target.db.query('photos')).single['data'];
    expect(blob, isA<Uint8List>());
    expect((await target.db.query('bikes')).single['conso_l100'], double.infinity);

    final s = AppSettings.fromPrefs(dstPrefs);
    expect(s.themeMode, ThemeMode.light);
    expect(s.stragglerAlertKm, 4.5);
    expect(s.hardBrakeThresholdG, 1.0);
    expect(s.autonomyAlertKm, 30);
    expect(s.voiceGuidance, isFalse);
    expect(dstPrefs.getString('dash.views'), '[{"id":"vue1"}]');
    expect(dstPrefs.getStringList('misc.list'), ['a', 'b']);
    await source.close();
    await target.close();
  });

  test('réglages : ce qui est propre au téléphone n\'est ni sauvegardé ni écrasé', () async {
    final db = await _openDb();
    final srcPrefs = await _prefs({
      'settings.themeMode': 'light',
      'settings.emergencyPhone': '0612345678',
      'dash.active': 'piste',
      'nav.recentDestinations': '[]',
      'feedback.author': 'Marc',
      'settings.tomtomApiKey': 'cle-secrete',
      'settings.onboardingDone': true,
      'update.auto': false,
      'update.lastCheck': 123,
      'update.snoozedBuild': 7,
      'update.snoozedUntil': 456,
      'ride.hudLayout': 'r1|map',
      'backup.lastAt': 1,
    });
    final data = AppBackup.decode(await AppBackup.export(db, srcPrefs));
    expect(data.prefs.keys.toSet(), {
      'settings.themeMode',
      'settings.emergencyPhone',
      'dash.active',
      'nav.recentDestinations',
      'feedback.author',
    });

    final dstPrefs = await _prefs({
      'settings.themeMode': 'dark',
      'dash.views': '[{"id":"perso"}]',
      'settings.tomtomApiKey': 'ma-cle',
      'settings.onboardingDone': true,
      'update.lastCheck': 999,
      'backup.lastAt': 42,
    });
    await AppBackup.restore(db, dstPrefs, data);
    expect(dstPrefs.getString('settings.themeMode'), 'light');
    expect(dstPrefs.getString('dash.active'), 'piste');
    expect(dstPrefs.getString('feedback.author'), 'Marc');
    // Absent de la sauvegarde : remplacé (supprimé), comme le reste des données.
    expect(dstPrefs.getString('dash.views'), isNull);
    // Propre à ce téléphone : intact.
    expect(dstPrefs.getString('settings.tomtomApiKey'), 'ma-cle');
    expect(dstPrefs.getBool('settings.onboardingDone'), isTrue);
    expect(dstPrefs.getInt('update.lastCheck'), 999);
    expect(dstPrefs.getInt('backup.lastAt'), 42);
    expect(dstPrefs.getBool('update.auto'), isNull);
    await db.close();
  });

  test('sauvegarde d\'une version plus récente de l\'appli : refusée', () {
    expect(
      () => AppBackup.decode(_file(_content(schemaVersion: AppDatabase.version + 1))),
      throwsA(_backupError(BackupException.tooNew)),
    );
    expect(
      () => AppBackup.decode(_file(_content(version: AppBackup.version + 1))),
      throwsA(_backupError(BackupException.tooNew)),
    );
    expect(
      BackupException.tooNew,
      "Cette sauvegarde vient d'une version plus récente de l'appli : mets-la à jour d'abord",
    );
  });

  test('fichier abîmé ou étranger : refusé avec un message clair', () async {
    final db = await _openDb();
    await _fill(db);
    final good = await AppBackup.export(db, await _prefs({}));
    await db.close();

    for (final bytes in <List<int>>[
      const [],
      utf8.encode('Bonjour'),
      List.generate(500, (i) => (i * 37) % 256),
      good.sublist(0, good.length ~/ 2),
      gzip.encode(utf8.encode('{"format": "cono-moto-backup", "version": 1')),
      _file({'format': 'autre-appli', 'version': 1}),
      _file({'tables': {}}),
    ]) {
      expect(() => AppBackup.decode(bytes), throwsA(_backupError(BackupException.notABackup)));
    }
    // Même message quand la lecture se fait hors du fil de l'interface.
    await expectLater(
      AppBackup.read(Uint8List.fromList(good.sublist(0, 100))),
      throwsA(_backupError(BackupException.notABackup)),
    );

    for (final content in <Map<String, Object?>>[
      {..._content(), 'version': 'un'},
      {..._content(), 'schemaVersion': null},
      {..._content(), 'tables': []},
      _content(tables: {'rides': 'pas une liste'}),
      _content(tables: {
        'rides': [
          [1, 2, 3],
        ],
      }),
      _content(tables: {
        'rides': [
          {
            'id': 'r1',
            'name': ['liste'],
          },
        ],
      }),
      _content(tables: {
        'photos': [
          {
            'data': {r'$blob': 'pas du base64 !'},
          },
        ],
      }),
    ]) {
      expect(() => AppBackup.decode(_file(content)), throwsA(_backupError(BackupException.damaged)));
    }
  });

  test('JSON déjà décompressé : accepté', () {
    final data = AppBackup.decode(utf8.encode(jsonEncode(_content(tables: {'rides': [_ride('r1')]}))));
    expect(data.rideCount, 1);
  });

  test('échec en cours de restauration : rien n\'a bougé (base et réglages)', () async {
    final db = await _openDb();
    await _fill(db);
    final before = await _dump(db);
    final prefs = await _prefs({'settings.themeMode': 'dark', 'dash.active': 'balade'});

    // Une balade sans nom (NOT NULL) après d'autres lignes valides.
    final data = AppBackup.decode(_file(_content(
      tables: {
        'bikes': [
          {'id': 'nouvelle', 'name': 'Nouvelle moto'},
        ],
        'rides': [_ride('ok'), _ride('sans-nom', name: null)],
      },
      prefs: {'settings.themeMode': 'light'},
    )));
    await expectLater(AppBackup.restore(db, prefs, data), throwsA(isA<Exception>()));

    expect(await _dump(db), before);
    expect(prefs.getString('settings.themeMode'), 'dark');
    expect(prefs.getString('dash.active'), 'balade');
    await db.close();
  });

  test('points GPS orphelins : refusé, annulé, et la base reste utilisable', () async {
    final db = await _openDb();
    await _fill(db);
    final before = await _dump(db);
    final prefs = await _prefs({});

    final data = AppBackup.decode(_file(_content(tables: {
      'rides': [_ride('r1')],
      'track_points': [
        {'ride_id': 'fantome', 'seq': 0, 't': 0, 'lat': 45.0, 'lng': 5.0},
      ],
    })));
    await expectLater(AppBackup.restore(db, prefs, data), throwsA(_backupError(BackupException.damaged)));
    expect(await _dump(db), before);

    // La transaction a bien été refermée : une nouvelle restauration passe.
    final ok = AppBackup.decode(_file(_content(tables: {'rides': [_ride('r9')]})));
    await AppBackup.restore(db, prefs, ok);
    expect((await db.db.query('rides')).map((r) => r['id']), ['r9']);
    await db.close();
  });

  test('tables et colonnes inconnues ignorées, colonnes manquantes à leur valeur par défaut', () async {
    final db = await _openFileDb();
    final prefs = await _prefs({});
    final data = AppBackup.decode(_file(_content(tables: {
      'rides': [
        _ride('r1', extra: {'colonne_du_futur': 'ignorée', 'meteo': 3.5}),
      ],
      'table_du_futur': [
        {'id': 1},
      ],
    })));
    await AppBackup.restore(db, prefs, data);

    final row = (await db.db.query('rides')).single;
    expect(row['id'], 'r1');
    expect(row.containsKey('colonne_du_futur'), isFalse);
    // Colonnes absentes de la sauvegarde (base plus ancienne) : valeurs par défaut.
    expect(row['events'], '[]');
    expect(row['notes'], '');
    expect(row['shared'], 0);
    expect(await AppBackup.tables(db.db), isNot(contains('table_du_futur')));
    await db.close();
  });

  test('tables système jamais exportées', () async {
    final db = await _openFileDb();
    await db.db.execute('CREATE TABLE android_metadata (locale TEXT)');
    await db.db.execute('CREATE TABLE compteurs (id INTEGER PRIMARY KEY AUTOINCREMENT, n INTEGER)');
    await db.db.insert('compteurs', {'n': 1});
    final tables = await AppBackup.tables(db.db);
    expect(tables, contains('compteurs'));
    expect(tables, isNot(contains('android_metadata')));
    expect(tables.where((t) => t.startsWith('sqlite_')), isEmpty);
    await db.close();
  });
}
