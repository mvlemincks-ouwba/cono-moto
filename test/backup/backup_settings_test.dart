import 'dart:io';

import 'package:cono_moto/core/format.dart';
import 'package:cono_moto/core/providers.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/backup.dart';
import 'package:cono_moto/data/database.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/features/backup/backup_providers.dart';
import 'package:cono_moto/features/backup/backup_tiles.dart';
import 'package:cono_moto/features/history/history_providers.dart';
import 'package:cono_moto/features/navigation/recent_destinations.dart';
import 'package:cono_moto/features/ride/dashboard/dashboard_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers.dart';

Ride _ride(String id, {DateTime? at}) {
  final start = at ?? DateTime.utc(2026, 9, 1, 9);
  return Ride(id: id, name: 'Balade $id', startedAt: start, endedAt: start.add(const Duration(hours: 2)));
}

Future<void> _pump(WidgetTester tester, {required List<Ride> rides, Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(p),
        ridesProvider.overrideWith((ref) => Stream.value(rides)),
      ],
      child: MaterialApp(
        theme: CmTheme.dark(),
        home: Scaffold(body: BackupSettingsTiles(now: DateTime.utc(2026, 10, 6, 12))),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  test('rappel : des balades et pas de sauvegarde depuis plus d\'un mois', () {
    final now = DateTime.utc(2026, 10, 6);
    LastBackup at(int daysAgo) => LastBackup(at: now.subtract(Duration(days: daysAgo)), bytes: 1);
    expect(backupReminderDue(rides: 0, last: null, now: now), isFalse);
    expect(backupReminderDue(rides: 3, last: null, now: now), isTrue);
    expect(backupReminderDue(rides: 3, last: at(10), now: now), isFalse);
    expect(backupReminderDue(rides: 3, last: at(30), now: now), isFalse);
    expect(backupReminderDue(rides: 3, last: at(31), now: now), isTrue);
  });

  test('taille de fichier en Ko / Mo', () {
    expect(Fmt.fileSize(0), '0 Ko');
    expect(Fmt.fileSize(850 * 1024), '850 Ko');
    expect(Fmt.fileSize(1258291), '1,2 Mo');
  });

  testWidgets('jamais sauvegardé : nombre de balades et petit rappel', (tester) async {
    await _pump(tester, rides: [_ride('a'), _ride('b')]);
    expect(find.text('Sauvegarder mes données'), findsOneWidget);
    expect(find.text('Restaurer une sauvegarde'), findsOneWidget);
    expect(find.text('2 balades · pas encore de sauvegarde'), findsOneWidget);
    expect(find.textContaining('tout est perdu'), findsOneWidget);
  });

  testWidgets('sauvegarde récente : date et taille, sans rappel', (tester) async {
    await _pump(
      tester,
      rides: [_ride('a')],
      prefs: {
        LastBackupNotifier.atKey: DateTime.utc(2026, 10, 1, 18).millisecondsSinceEpoch,
        LastBackupNotifier.bytesKey: 1258291,
      },
    );
    expect(find.text('1 balade · dernière le 1 oct. 2026 (1,2 Mo)'), findsOneWidget);
    expect(find.textContaining('pense à'), findsNothing);
    expect(find.textContaining('tout est perdu'), findsNothing);
  });

  testWidgets('vieille sauvegarde : rappel', (tester) async {
    await _pump(
      tester,
      rides: [_ride('a')],
      prefs: {LastBackupNotifier.atKey: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch},
    );
    expect(find.textContaining('Plus d\'un mois sans sauvegarde'), findsOneWidget);
  });

  test('après restauration, l\'appli relit balades, réglages et vues du compteur', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('cono_moto_backup_reload');
    addTearDown(() => dir.delete(recursive: true));
    Future<AppDatabase> open(String name) =>
        AppDatabase.open(factory: databaseFactoryFfi, path: '${dir.path}/$name.db');

    // Le téléphone d'avant : deux balades, thème clair, vue « piste ».
    final old = await open('ancien');
    for (final id in ['r1', 'r2']) {
      await old.db.insert('rides', _ride(id).toDb());
    }
    SharedPreferences.setMockInitialValues({
      'settings.themeMode': 'light',
      DashboardController.activeKey: 'piste',
      RecentDestinationsNotifier.prefsKey: '[]',
    });
    final bytes = await AppBackup.export(old, await SharedPreferences.getInstance());
    await old.close();

    // Le nouveau téléphone, déjà lancé avec une balade et le thème sombre.
    final db = await open('nouveau');
    await db.db.insert('rides', _ride('locale').toDb());
    SharedPreferences.setMockInitialValues({'settings.themeMode': 'dark'});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(c.dispose);
    final sub = c.listen(ridesProvider, (_, _) {});
    addTearDown(sub.close);
    expect((await c.read(ridesProvider.future)).map((r) => r.id), ['locale']);
    expect(c.read(settingsProvider).themeMode, ThemeMode.dark);
    expect(c.read(dashboardProvider).activeId, isNot('piste'));

    await AppBackup.restore(db, prefs, AppBackup.decode(bytes));
    reloadAfterRestore(c);

    expect((await c.read(ridesProvider.future)).map((r) => r.id).toSet(), {'r1', 'r2'});
    expect(c.read(settingsProvider).themeMode, ThemeMode.light);
    expect(c.read(dashboardProvider).activeId, 'piste');
    await db.close();
  });
}
