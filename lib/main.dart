import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/notifications.dart';
import 'core/providers.dart';
import 'core/settings.dart';
import 'data/database.dart';
import 'services/social/firebase_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'fr_FR';
  await initializeDateFormatting('fr_FR');
  // Les polices sont téléchargées une fois puis mises en cache ; hors-ligne,
  // on retombe sur la police système sans erreur.
  GoogleFonts.config.allowRuntimeFetching = true;

  final prefs = await SharedPreferences.getInstance();
  final db = await AppDatabase.open();
  await Notifications.init();
  await initFirebase();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
      ],
      child: const ConoMotoApp(),
    ),
  );
}
