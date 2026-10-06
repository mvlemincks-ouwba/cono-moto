import 'dart:convert';
import 'dart:io';

import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/features/update/update_controller.dart';
import 'package:cono_moto/features/update/update_sheet.dart';
import 'package:cono_moto/services/update/app_update.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers.dart';

const base = 'https://github.com/moi/cono-moto/releases/download/derniere-version';
const channel = MethodChannel('test/updater');

/// Faux serveur : android.json / ios.json puis le fichier (6 octets).
class FakeServer {
  int build = 60;
  int status = 200;
  final requests = <String>[];

  http.Client get client => MockClient.streaming((request, _) async {
        final name = request.url.pathSegments.last;
        requests.add(name);
        if (status != 200) return http.StreamedResponse(const Stream.empty(), status);
        if (name.endsWith('.json')) {
          final platform = name.replaceAll('.json', '');
          final body = utf8.encode(jsonEncode({
            'platform': platform,
            'version': '1.0.0',
            'build': build,
            'file': platform == 'android' ? 'cono-moto.apk' : 'cono-moto-unsigned.ipa',
            'size': 6,
            'notes': ['Radars : zones de danger', 'Plus de cols'],
          }));
          return http.StreamedResponse(Stream.value(body), 200);
        }
        return http.StreamedResponse(Stream.fromIterable([
          [1, 2, 3],
          [4, 5, 6],
        ]), 200);
      });
}

Future<ProviderContainer> makeContainer(
  FakeServer server, {
  int? installed = 57,
  UpdatePlatform platform = UpdatePlatform.android,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  final dir = Directory.systemTemp.createTempSync('updates');
  addTearDown(() => dir.deleteSync(recursive: true));
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(sp),
    updateClientProvider.overrideWithValue(UpdateClient(baseUrl: base, client: server.client)),
    apkInstallerProvider.overrideWithValue(ApkInstaller(channel: channel)),
    installedBuildProvider.overrideWithValue(installed),
    updatePlatformProvider.overrideWithValue(platform),
    updateDirectoryProvider.overrideWithValue(() async => dir),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('recherche', () {
    test('nouvelle version trouvée, puis pas de nouvel appel avant 6 h', () async {
      final server = FakeServer();
      final c = await makeContainer(server);
      final ctrl = c.read(appUpdateProvider.notifier);
      final now = DateTime(2026, 10, 6, 9);

      final found = await ctrl.check(now: now);
      expect(found?.build, 60);
      expect(c.read(appUpdateProvider).phase, UpdatePhase.available);
      expect(server.requests, ['android.json']);

      expect((await ctrl.check(now: now.add(const Duration(hours: 2))))?.build, 60);
      expect(server.requests, hasLength(1), reason: 'vérification automatique espacée');

      await ctrl.check(manual: true, now: now.add(const Duration(hours: 2)));
      expect(server.requests, hasLength(2), reason: 'la recherche manuelle passe toujours');
    });

    test('déjà à jour', () async {
      final server = FakeServer()..build = 57;
      final c = await makeContainer(server);
      expect(await c.read(appUpdateProvider.notifier).check(), isNull);
      expect(c.read(appUpdateProvider).phase, UpdatePhase.upToDate);
    });

    test('erreur : silencieuse en automatique, expliquée en manuel', () async {
      final server = FakeServer()..status = 404;
      final c = await makeContainer(server);
      final ctrl = c.read(appUpdateProvider.notifier);
      await ctrl.check();
      expect(c.read(appUpdateProvider).phase, UpdatePhase.idle);
      await ctrl.check(manual: true);
      expect(c.read(appUpdateProvider).phase, UpdatePhase.error);
      expect(c.read(appUpdateProvider).message, contains('Aucune version publiée'));
    });

    test('version de développement : jamais de mise à jour', () async {
      final server = FakeServer();
      final c = await makeContainer(server, installed: null);
      expect(await c.read(appUpdateProvider.notifier).check(manual: true), isNull);
      expect(c.read(appUpdateProvider).message, contains('développement'));
      expect(server.requests, isEmpty);
    });

    test('« plus tard » : pas reproposée pendant 24 h, et réglage mémorisé', () async {
      final c = await makeContainer(FakeServer());
      final ctrl = c.read(appUpdateProvider.notifier);
      final m = (await ctrl.check())!;
      final now = DateTime(2026, 10, 6, 9);
      expect(ctrl.shouldPrompt(m, now: now), isTrue);
      await ctrl.snooze(m, now: now);
      expect(ctrl.shouldPrompt(m, now: now.add(const Duration(hours: 23))), isFalse);
      expect(ctrl.shouldPrompt(m, now: now.add(const Duration(hours: 25))), isTrue);

      await ctrl.setAutoCheck(false);
      expect(c.read(sharedPreferencesProvider).getBool(AppUpdateController.autoKey), isFalse);
      expect(c.read(appUpdateProvider).autoCheck, isFalse);
    });
  });

  group('installation (Android)', () {
    test('autorisation demandée une fois, puis reprise au retour dans l\'appli', () async {
      final server = FakeServer();
      final c = await makeContainer(server);
      final ctrl = c.read(appUpdateProvider.notifier);
      final calls = <String>[];
      var canInstall = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'installApk') {
          expect(File(call.arguments['path'] as String).readAsBytesSync(), [1, 2, 3, 4, 5, 6]);
          return canInstall ? 'started' : 'permission';
        }
        return null;
      });

      await ctrl.check();
      await ctrl.downloadAndInstall();
      expect(c.read(appUpdateProvider).phase, UpdatePhase.waitingPermission);
      expect(calls, ['installApk', 'openInstallSettings']);
      expect(server.requests, ['android.json', 'cono-moto.apk']);

      canInstall = true;
      await ctrl.onResumed();
      expect(c.read(appUpdateProvider).phase, UpdatePhase.installing);
      expect(calls.last, 'installApk');
      expect(server.requests, hasLength(2), reason: 'pas de nouveau téléchargement');

      // Échec remonté par Android : message, et on peut réessayer.
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('installStatus', {'status': 'failure', 'code': 3})),
        (_) {},
      );
      await pumpEventQueue();
      final state = c.read(appUpdateProvider);
      expect(state.phase, UpdatePhase.error);
      expect(state.message, 'Installation annulée.');
      expect(state.manifest?.build, 60);
    });

    test('téléchargement échoué : message et version gardée', () async {
      final server = FakeServer();
      final c = await makeContainer(server);
      final ctrl = c.read(appUpdateProvider.notifier);
      await ctrl.check();
      server.status = 500;
      await ctrl.downloadAndInstall();
      final state = c.read(appUpdateProvider);
      expect(state.phase, UpdatePhase.error);
      expect(state.message, contains('(500)'));
      expect(state.manifest?.build, 60);
    });
  });

  group('écrans', () {
    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      await initTestLocale();
    });

    Future<ProviderContainer> pumpSettings(WidgetTester tester, {UpdatePlatform platform = UpdatePlatform.android}) async {
      final c = await makeContainer(FakeServer(), platform: platform);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: CmTheme.dark(),
          home: const Scaffold(body: SingleChildScrollView(child: UpdateSettingsTiles())),
        ),
      ));
      return c;
    }

    testWidgets('réglage : recherche manuelle puis présentation de la version', (tester) async {
      final c = await pumpSettings(tester);
      expect(find.text('Touche pour chercher une nouvelle version'), findsOneWidget);
      await tester.tap(find.textContaining('Version 1.0.0'));
      await tester.pumpAndSettle();
      expect(find.text('Nouvelle version de Cono Moto'), findsOneWidget);
      expect(find.text('Radars : zones de danger'), findsOneWidget);
      expect(find.text('Mettre à jour'), findsOneWidget);

      await tester.tap(find.text('Plus tard'));
      await tester.pumpAndSettle();
      expect(find.text('Nouvelle version de Cono Moto'), findsNothing);
      expect(c.read(sharedPreferencesProvider).getInt(AppUpdateController.snoozedBuildKey), 60);
      expect(find.textContaining('Nouvelle version disponible'), findsOneWidget);
    });

    testWidgets('iPhone : explique SideStore / Sideloadly au lieu d\'installer', (tester) async {
      await pumpSettings(tester, platform: UpdatePlatform.ios);
      await tester.tap(find.textContaining('Version 1.0.0'));
      await tester.pumpAndSettle();
      expect(find.textContaining('SideStore'), findsOneWidget);
      expect(find.text('Comment faire'), findsOneWidget);
      expect(find.text('Mettre à jour'), findsNothing);
    });
  });
}
