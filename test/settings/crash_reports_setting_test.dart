import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/features/feedback/feedback_screen.dart';
import 'package:cono_moto/features/settings/settings_screen.dart';
import 'package:cono_moto/services/feedback/discord_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

const _label = 'Envoyer les rapports de plantage';

Future<SharedPreferences> _pump(WidgetTester tester, {required String webhook}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1080, 12000); // réglages entiers visibles
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      discordFeedbackClientProvider.overrideWithValue(
        DiscordFeedbackClient(webhookUrl: webhook, client: MockClient((_) async => http.Response('', 200))),
      ),
    ],
    child: MaterialApp(theme: CmTheme.dark(), home: const SettingsScreen()),
  ));
  await tester.pump();
  return prefs;
}

SwitchListTile _tile(WidgetTester tester) => tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, _label));

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  testWidgets('activé par défaut, se coupe d\'un appui', (tester) async {
    final prefs = await _pump(tester, webhook: 'https://discord.com/api/webhooks/1/token');
    expect(find.text('Sans ta position ni ton nom : juste l\'erreur et la version de l\'appli'), findsOneWidget);
    expect(_tile(tester).value, isTrue);

    await tester.tap(find.text(_label));
    await tester.pump();
    expect(_tile(tester).value, isFalse);
    expect(prefs.getBool('settings.crashReports'), isFalse);
    expect(AppSettings.fromPrefs(prefs).crashReports, isFalse);
  });

  testWidgets('Discord pas branché : interrupteur grisé et expliqué', (tester) async {
    await _pump(tester, webhook: '');
    expect(find.textContaining('pas encore branché'), findsOneWidget);
    expect(_tile(tester).onChanged, isNull);
    expect(_tile(tester).value, isFalse);
  });
}
