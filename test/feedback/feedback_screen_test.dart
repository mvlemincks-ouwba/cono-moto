import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/features/feedback/feedback_screen.dart';
import 'package:cono_moto/services/feedback/discord_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

Future<void> _pump(WidgetTester tester, DiscordFeedbackClient client) async {
  SharedPreferences.setMockInitialValues({'feedback.author': 'Julien'});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1080, 6000); // formulaire entier visible
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      discordFeedbackClientProvider.overrideWithValue(client),
    ],
    child: MaterialApp(theme: CmTheme.dark(), home: const FeedbackScreen()),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  testWidgets('Discord non branché : seulement « Partager autrement »', (tester) async {
    await _pump(tester, DiscordFeedbackClient(webhookUrl: '', client: MockClient((_) async => http.Response('', 200))));
    expect(find.textContaining('pas encore branché'), findsOneWidget);
    expect(find.text('Envoyer sur Discord'), findsNothing);
    expect(find.text('Partager autrement'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Julien'), findsOneWidget);
  });

  testWidgets('envoi réussi puis écran de remerciement', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      DiscordFeedbackClient(
        webhookUrl: 'https://discord.com/api/webhooks/1/token',
        client: MockClient((_) async {
          calls++;
          return http.Response('{"id":"1"}', 200);
        }),
      ),
    );
    await tester.tap(find.text('🐞 Bug'));
    await tester.enterText(find.widgetWithText(TextField, 'Titre'), 'La carte se fige');
    await tester.enterText(find.widgetWithText(TextField, 'Explique-nous'), 'Quand je verrouille le téléphone en balade.');
    await tester.tap(find.text('Envoyer sur Discord'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Merci, c\'est posté ! 🙌'), findsOneWidget);
  });

  testWidgets('formulaire incomplet : rien n\'est envoyé', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      DiscordFeedbackClient(
        webhookUrl: 'https://discord.com/api/webhooks/1/token',
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      ),
    );
    await tester.tap(find.text('Envoyer sur Discord'));
    await tester.pump();
    expect(calls, 0);
    expect(find.textContaining('Donne un titre'), findsOneWidget);
  });
}
