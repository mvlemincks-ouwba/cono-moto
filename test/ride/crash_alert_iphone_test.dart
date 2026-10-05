import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/native.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/features/ride/crash_alert_controller.dart';
import 'package:cono_moto/features/ride/crash_alert_screen.dart';
import 'package:cono_moto/services/ride/ride_platform.dart';
import 'package:cono_moto/services/social/sos.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';
import 'crash_alert_controller_test.dart' show FakeSos;
import 'fake_ride_platform.dart';

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  for (final size in const [Size(360, 640), Size(393, 852), Size(852, 393)]) {
    testWidgets('iPhone : SMS préparé, gros bouton « Envoyer le SMS » · ${size.width.round()}×${size.height.round()}',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'settings.emergencyName': 'Julie',
        'settings.emergencyPhone': '0611223344',
      });
      final prefs = await SharedPreferences.getInstance();
      final platform = FakeRidePlatform()
        ..smsAutomatic = false
        ..composeResult = SmsComposeResult.cancelled;
      final sos = FakeSos();
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            ridePlatformProvider.overrideWithValue(platform),
            sosBroadcasterProvider.overrideWithValue(sos),
          ],
          child: MaterialApp(
            theme: CmTheme.dark(),
            home: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return const CrashAlertScreen();
              },
            ),
          ),
        ),
      );
      container.read(crashAlertProvider.notifier).trigger(at: const GeoPoint(45, 5), seconds: 2);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('un SMS pour Julie sera prêt'), findsOneWidget);
      expect(find.text('JE VAIS BIEN'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(crashAlertProvider).phase, CrashAlertPhase.sent);
      expect(platform.sms, isEmpty, reason: 'pas d\'envoi automatique sur iPhone');
      expect(sos.broadcasts, hasLength(1));
      // Messages s'ouvre tout seul une fois, pré-rempli.
      expect(platform.composed, hasLength(1));
      expect(platform.composed.single.phone, '0611223344');

      expect(find.text('ALERTE CHUTE'), findsOneWidget);
      expect(find.textContaining('SMS prêt pour Julie'), findsOneWidget);
      final sendButton = find.text('Envoyer le SMS à Julie');
      expect(sendButton, findsOneWidget);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Appeler les secours (112)'), 150, scrollable: list);
      await tester.scrollUntilVisible(find.text('Appeler Julie'), 150, scrollable: list);
      await tester.drag(list, const Offset(0, 2000));
      await tester.pump(const Duration(milliseconds: 300));

      platform.composeResult = SmsComposeResult.sent;
      await tester.tap(sendButton);
      await tester.pump(const Duration(milliseconds: 300));
      expect(platform.composed, hasLength(2));
      expect(container.read(crashAlertProvider).smsSent, isTrue);
      expect(find.text('Envoyer le SMS à Julie'), findsNothing);
      expect(find.text('ALERTE ENVOYÉE'), findsOneWidget);
      expect(find.textContaining('SMS envoyé à Julie'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Fin de l'alerte (le minuteur est arrêté).
      container.read(crashAlertProvider.notifier).dismissKeepingAlert();
      await tester.pump(const Duration(milliseconds: 300));
    });
  }
}
