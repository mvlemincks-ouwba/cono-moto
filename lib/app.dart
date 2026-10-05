import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/settings.dart';
import 'core/theme.dart';
import 'features/home/home_shell.dart';
import 'features/onboarding/onboarding_screen.dart';

/// Navigateur racine (utilisé pour afficher l'alerte de chute depuis n'importe où).
final rootNavigatorKey = GlobalKey<NavigatorState>();

class ConoMotoApp extends ConsumerWidget {
  const ConoMotoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final onboarded = ref.watch(settingsProvider.select((s) => s.onboardingDone));
    return MaterialApp(
      title: 'Cono Moto',
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      theme: CmTheme.light(),
      darkTheme: CmTheme.dark(),
      themeMode: themeMode,
      locale: const Locale('fr', 'FR'),
      supportedLocales: const [Locale('fr', 'FR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: onboarded ? const HomeShell() : const OnboardingScreen(),
    );
  }
}
