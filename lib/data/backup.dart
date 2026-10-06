import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../core/config.dart';
import 'database.dart';

/// Erreur de sauvegarde ou de restauration, avec un message prêt à afficher.
class BackupException implements Exception {
  const BackupException(this.message);

  static const notABackup = "Ce fichier n'est pas une sauvegarde Cono Moto.";
  static const damaged = 'Cette sauvegarde est abîmée : impossible de la lire.';
  static const tooNew =
      "Cette sauvegarde vient d'une version plus récente de l'appli : mets-la à jour d'abord";

  final String message;

  @override
  String toString() => message;
}

/// Contenu d'une sauvegarde lue et vérifiée, prêt à être restauré.
class BackupData {
  const BackupData({
    required this.schemaVersion,
    required this.createdAt,
    required this.appBuild,
    required this.tables,
    required this.prefs,
  });

  /// Version de la base au moment de la sauvegarde.
  final int schemaVersion;
  final DateTime? createdAt;
  final String appBuild;

  /// Lignes de chaque table (BLOB déjà décodés).
  final Map<String, List<Map<String, Object?>>> tables;

  /// Préférences sauvegardées (bool, int, double, String ou `List<String>`).
  final Map<String, Object> prefs;

  /// Balades terminées contenues dans la sauvegarde.
  int get rideCount => (tables['rides'] ?? const []).where((r) => r['ended_at'] != null).length;
}

/// Sauvegarde complète des données du téléphone dans un seul fichier
/// `cono-moto-AAAA-MM-JJ.cmbackup` : du JSON compressé en gzip, à ranger sur un
/// Drive, dans Fichiers ou par mail, et à restaurer sur n'importe quel
/// téléphone (Android comme iPhone).
///
/// Contenu : `{format, version, schemaVersion, createdAt, appBuild,
/// tables: {nom: [lignes…]}, prefs: {clé: valeur}}`. Les tables sont lues dans
/// `sqlite_master` : une nouvelle table est sauvegardée sans rien changer ici.
///
/// Sauvegarde d'une base plus ancienne : chaque ligne est remise dans les
/// colonnes qui existent encore, les colonnes ajoutées depuis prennent leur
/// valeur par défaut. Une future migration qui transforme des données (et pas
/// seulement des colonnes en plus) devra avoir sa conversion dans [restore].
class AppBackup {
  AppBackup._();

  static const format = 'cono-moto-backup';
  static const version = 1;
  static const extension = 'cmbackup';

  /// Lignes lues ou écrites d'un coup (les points GPS se comptent par
  /// dizaines de milliers).
  static const pageSize = 2000;

  /// Préférences jamais sauvegardées ni restaurées, car propres à ce
  /// téléphone, secrètes ou passagères :
  /// - `update.*` : mises à jour (vérification auto, dernière recherche,
  ///   version reportée), qui dépendent de l'installation (APK sur Android,
  ///   SideStore sur iPhone) ;
  /// - `backup.*` : date et taille de la dernière sauvegarde de ce téléphone ;
  /// - `settings.onboardingDone` : l'accueil demande les autorisations (GPS,
  ///   notifications, SMS), à redonner sur chaque téléphone ;
  /// - `settings.tomtomApiKey` : clé d'API perso, un secret qui n'a rien à
  ///   faire dans un fichier envoyé par mail ou posé sur un Drive ;
  /// - `ride.hudLayout` : affichage de la balade en cours.
  ///
  /// Le compte des potes (Firebase) n'est pas dans les préférences : Firebase
  /// le garde de son côté, on se reconnecte sur le nouveau téléphone.
  static const excludedPrefPrefixes = ['update.', 'backup.'];
  static const excludedPrefKeys = {'settings.onboardingDone', 'settings.tomtomApiKey', 'ride.hudLayout'};

  /// Marqueurs des valeurs que JSON ne sait pas porter telles quelles.
  static const _blobKey = r'$blob';
  static const _doubleKey = r'$double';

  /// Vrai si la préférence [key] fait partie des sauvegardes.
  static bool keepsPref(String key) =>
      !excludedPrefKeys.contains(key) && !excludedPrefPrefixes.any(key.startsWith);

  /// Nom du fichier de sauvegarde du jour : `cono-moto-2026-10-06.cmbackup`.
  static String fileName(DateTime day) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'cono-moto-${day.year}-${two(day.month)}-${two(day.day)}.$extension';
  }

  /// Tables de l'appli, hors tables internes de SQLite et d'Android.
  static Future<List<String>> tables(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name != 'android_metadata' ORDER BY name",
    );
    return [for (final r in rows) r['name'] as String];
  }

  /// Préférences à sauvegarder, telles qu'enregistrées sur ce téléphone.
  static Map<String, Object> prefsToSave(SharedPreferences prefs) {
    final out = <String, Object>{};
    for (final k in prefs.getKeys()) {
      final v = prefs.get(k);
      if (v == null || !keepsPref(k)) continue;
      // Listes parfois relues en List<dynamic> : remises en List<String>.
      out[k] = v is List ? [for (final s in v) '$s'] : v;
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------

  /// Fichier de sauvegarde complet (octets gzip). Les lignes sont lues et
  /// compressées page par page : la mémoire reste raisonnable et l'interface
  /// respire entre deux pages. [onProgress] reçoit l'avancement (0 à 1).
  static Future<Uint8List> export(
    AppDatabase database,
    SharedPreferences prefs, {
    DateTime? now,
    String appBuild = AppConfig.appBuild,
    void Function(double done)? onProgress,
  }) async {
    late List<int> compressed;
    final gz = gzip.encoder.startChunkedConversion(ByteConversionSink.withCallback((b) => compressed = b));
    final out = utf8.encoder.startChunkedConversion(gz);

    out.add('{');
    final header = {
      'format': format,
      'version': version,
      'schemaVersion': AppDatabase.version,
      'createdAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'appBuild': appBuild,
    };
    for (final e in header.entries) {
      out.add('${jsonEncode(e.key)}:${jsonEncode(e.value)},');
    }
    out.add('"tables":{');

    // Une transaction pour une photo cohérente (pas de point ajouté entre deux pages).
    await database.db.transaction((txn) async {
      final names = await tables(txn);
      var total = 0;
      for (final t in names) {
        total += Sqflite.firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM "$t"')) ?? 0;
      }
      var done = 0;
      for (var i = 0; i < names.length; i++) {
        final t = names[i];
        out.add('${i == 0 ? '' : ','}${jsonEncode(t)}:[');
        final order = await _hasRowid(txn, t) ? 'rowid' : null;
        var first = true;
        for (var offset = 0;; offset += pageSize) {
          final rows = await txn.query(t, orderBy: order, limit: pageSize, offset: offset);
          final page = StringBuffer();
          for (final r in rows) {
            if (!first) page.write(',');
            page.write(jsonEncode({for (final e in r.entries) e.key: _encodeValue(e.value)}));
            first = false;
          }
          out.add(page.toString());
          done += rows.length;
          if (total > 0) onProgress?.call(done / total);
          if (rows.length < pageSize) break;
        }
        out.add(']');
      }
    });

    out.add('},"prefs":${jsonEncode(prefsToSave(prefs))}}');
    out.close();
    final bytes = compressed;
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  }

  /// Écrit la sauvegarde dans [dir] (vidé au passage des anciennes sauvegardes).
  static Future<File> writeFile(
    AppDatabase database,
    SharedPreferences prefs,
    Directory dir, {
    DateTime? now,
    void Function(double done)? onProgress,
  }) async {
    final at = now ?? DateTime.now();
    final bytes = await export(database, prefs, now: at, onProgress: onProgress);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File('${dir.path}/${fileName(at)}');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<bool> _hasRowid(DatabaseExecutor db, String table) async {
    final rows = await db.rawQuery("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table]);
    final sql = rows.isEmpty ? '' : (rows.first['sql'] as String? ?? '');
    return !sql.toUpperCase().contains('WITHOUT ROWID');
  }

  static Object? _encodeValue(Object? v) {
    if (v is List<int>) return {_blobKey: base64Encode(v)};
    if (v is double && !v.isFinite) return {_doubleKey: '$v'};
    return v;
  }

  // ---------------------------------------------------------------------------
  // Lecture
  // ---------------------------------------------------------------------------

  /// Lit et vérifie une sauvegarde hors du fil de l'interface (gros fichiers).
  static Future<BackupData> read(Uint8List bytes) => Isolate.run(() => decode(bytes));

  /// Lit et vérifie une sauvegarde. Lève [BackupException] si le fichier n'en
  /// est pas une, s'il est abîmé ou s'il vient d'une version plus récente.
  static BackupData decode(List<int> bytes) {
    final Object? root;
    try {
      // Gzip reconnu à sa signature ; un JSON déjà décompressé passe aussi.
      final raw = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b ? gzip.decode(bytes) : bytes;
      root = utf8.decoder.fuse(json.decoder).convert(raw);
    } catch (_) {
      throw const BackupException(BackupException.notABackup);
    }
    if (root is! Map || root['format'] != format) throw const BackupException(BackupException.notABackup);
    final v = root['version'];
    final schema = root['schemaVersion'];
    if (v is! int || schema is! int || v < 1 || schema < 1) throw const BackupException(BackupException.damaged);
    if (v > version || schema > AppDatabase.version) throw const BackupException(BackupException.tooNew);

    final rawTables = root['tables'];
    final rawPrefs = root['prefs'] ?? const <String, Object?>{};
    if (rawTables is! Map || rawPrefs is! Map) throw const BackupException(BackupException.damaged);
    final tables = <String, List<Map<String, Object?>>>{};
    try {
      for (final e in rawTables.entries) {
        final rows = e.value as List;
        for (final row in rows) {
          // Décodage sur place : pas de deuxième copie des points GPS en mémoire.
          (row as Map<String, Object?>).updateAll((_, value) => _decodeValue(value));
        }
        tables[e.key as String] = rows.cast<Map<String, Object?>>();
      }
    } catch (_) {
      throw const BackupException(BackupException.damaged);
    }

    final prefs = <String, Object>{};
    for (final e in rawPrefs.entries) {
      // Valeurs d'un type inconnu des préférences : ignorées.
      final value = e.value;
      if (value is bool || value is int || value is double || value is String) {
        prefs['${e.key}'] = value as Object;
      } else if (value is List && value.every((s) => s is String)) {
        prefs['${e.key}'] = value.cast<String>().toList();
      }
    }

    return BackupData(
      schemaVersion: schema,
      createdAt: DateTime.tryParse('${root['createdAt']}'),
      appBuild: '${root['appBuild'] ?? ''}',
      tables: tables,
      prefs: prefs,
    );
  }

  static Object? _decodeValue(Object? v) {
    if (v == null || v is num || v is String) return v;
    if (v is Map && v.length == 1) {
      final blob = v[_blobKey];
      if (blob is String) return base64Decode(blob);
      final d = v[_doubleKey];
      if (d is String) return double.parse(d);
    }
    throw const FormatException('Valeur inattendue');
  }

  // ---------------------------------------------------------------------------
  // Restauration
  // ---------------------------------------------------------------------------

  /// Remplace toutes les données (tables et préférences sauvegardables) par
  /// celles de [data]. Tout ou rien : en cas d'erreur, la base revient en
  /// arrière (transaction) et les préférences d'avant sont remises.
  ///
  /// Seules les tables et colonnes qui existent dans cette version de l'appli
  /// sont reprises ; le reste est ignoré.
  static Future<void> restore(
    AppDatabase database,
    SharedPreferences prefs,
    BackupData data, {
    void Function(double done)? onProgress,
  }) async {
    final before = prefsToSave(prefs);
    try {
      await _replacePrefs(prefs, data.prefs);
      await database.db.transaction((txn) async {
        // Clés étrangères (points → balade) vérifiées une fois tout inséré :
        // l'ordre des tables n'a pas d'importance.
        await txn.execute('PRAGMA defer_foreign_keys = ON');
        final names = await tables(txn);
        for (final t in names) {
          await txn.delete(t);
        }
        final total = names.fold(0, (n, t) => n + (data.tables[t]?.length ?? 0));
        var done = 0;
        for (final t in names) {
          final rows = data.tables[t];
          if (rows == null || rows.isEmpty) continue;
          final columns = {for (final c in await txn.rawQuery('PRAGMA table_info("$t")')) c['name'] as String};
          var batch = txn.batch();
          var pending = 0;
          for (final row in rows) {
            final values = {
              for (final e in row.entries)
                if (columns.contains(e.key)) e.key: e.value,
            };
            if (values.isNotEmpty) batch.insert(t, values);
            if (++pending == pageSize) {
              await batch.commit(noResult: true);
              batch = txn.batch();
              done += pending;
              pending = 0;
              onProgress?.call(done / total);
            }
          }
          await batch.commit(noResult: true);
          done += pending;
          onProgress?.call(done / total);
        }
        // Vérifié ici plutôt qu'au COMMIT : un COMMIT refusé laisserait la
        // transaction ouverte.
        if ((await txn.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
          throw const BackupException(BackupException.damaged);
        }
      });
    } catch (_) {
      await _replacePrefs(prefs, before);
      rethrow;
    }
  }

  /// Remplace les préférences sauvegardables par [values] (les autres ne
  /// bougent pas).
  static Future<void> _replacePrefs(SharedPreferences prefs, Map<String, Object> values) async {
    for (final k in prefs.getKeys().toList()) {
      if (keepsPref(k) && !values.containsKey(k)) await prefs.remove(k);
    }
    for (final e in values.entries) {
      if (!keepsPref(e.key)) continue;
      switch (e.value) {
        case final bool v:
          await prefs.setBool(e.key, v);
        case final int v:
          await prefs.setInt(e.key, v);
        case final double v:
          await prefs.setDouble(e.key, v);
        case final String v:
          await prefs.setString(e.key, v);
        case final List<Object?> v:
          await prefs.setStringList(e.key, [for (final s in v) '$s']);
      }
    }
  }
}
