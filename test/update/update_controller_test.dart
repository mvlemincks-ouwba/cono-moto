import 'dart:async';
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

  /// Statut des fichiers seuls (APK), les descriptions restent lisibles.
  int fileStatus = 200;

  /// android.json donne aussi l'APK de chaque architecture (`files`).
  bool perAbi = false;

  /// Contenu du fichier, morceau par morceau.
  Stream<List<int>> Function() body = () => Stream.fromIterable([
        [1, 2, 3],
        [4, 5, 6],
      ]);
  final requests = <String>[];

  int get fileRequests => requests.where((r) => r.endsWith('.apk')).length;

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
            if (perAbi && platform == 'android')
              'files': {
                'arm64-v8a': {'file': 'cono-moto.apk', 'size': 6},
                'armeabi-v7a': {'file': 'cono-moto-armeabi-v7a.apk', 'size': 6},
              },
            'notes': ['Radars : zones de danger', 'Plus de cols'],
          }));
          return http.StreamedResponse(Stream.value(body), 200);
        }
        if (fileStatus != 200) return http.StreamedResponse(const Stream.empty(), fileStatus);
        return http.StreamedResponse(body(), 200);
      });
}

/// Balade en cours (remplace le contrôleur de balade dans les tests).
class FakeRide extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool riding) => state = riding;
}

final fakeRideProvider = NotifierProvider<FakeRide, bool>(FakeRide.new);

/// Dossier des téléchargements du dernier conteneur créé.
late Directory updatesDir;

List<String> updatesFiles() => [for (final f in updatesDir.listSync()) f.path.split('/').last];

Future<ProviderContainer> makeContainer(
  FakeServer server, {
  int? installed = 57,
  UpdatePlatform platform = UpdatePlatform.android,
  Map<String, Object> prefs = const {},
  Directory? dir,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  if (dir == null) {
    final temp = dir = Directory.systemTemp.createTempSync('updates');
    addTearDown(() => temp.deleteSync(recursive: true));
  }
  updatesDir = dir;
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(sp),
    updateClientProvider.overrideWithValue(UpdateClient(baseUrl: base, client: server.client)),
    apkInstallerProvider.overrideWithValue(ApkInstaller(channel: channel)),
    installedBuildProvider.overrideWithValue(installed),
    updatePlatformProvider.overrideWithValue(platform),
    updateDirectoryProvider.overrideWithValue(() async => dir!),
    updateRideActiveProvider.overrideWith((ref) => ref.watch(fakeRideProvider)),
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

  /// Faux Android : architectures, type de connexion et installation. Retourne
  /// les appels reçus.
  List<MethodCall> mockNative({
    bool unmetered = true,
    List<String> abis = const ['arm64-v8a', 'armeabi-v7a', 'armeabi'],
  }) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'supportedAbis' => abis,
        'isNetworkUnmetered' => unmetered,
        'installApk' => 'started',
        _ => null,
      };
    });
    return calls;
  }

  group('APK par architecture (Android)', () {
    test('le téléphone reçoit l\'APK de son architecture', () async {
      final server = FakeServer()..perAbi = true;
      final c = await makeContainer(server);
      final calls = mockNative(abis: ['armeabi-v7a', 'armeabi']);
      final ctrl = c.read(appUpdateProvider.notifier);

      expect((await ctrl.check())?.file, 'cono-moto-armeabi-v7a.apk');
      expect(c.read(appUpdateProvider).manifest?.file, 'cono-moto-armeabi-v7a.apk');
      await ctrl.downloadAndInstall();
      expect(server.requests, ['android.json', 'cono-moto-armeabi-v7a.apk']);
      expect(c.read(appUpdateProvider).phase, UpdatePhase.installing);
      expect(calls.last.arguments['path'] as String, endsWith('/60-cono-moto-armeabi-v7a.apk'));
    });

    test('architecture non publiée ou inconnue : file (APK arm64)', () async {
      final server = FakeServer()..perAbi = true;
      var c = await makeContainer(server);
      mockNative(abis: ['x86_64']);
      expect((await c.read(appUpdateProvider.notifier).check())?.file, 'cono-moto.apk');

      c = await makeContainer(server);
      messenger.setMockMethodCallHandler(channel, null);
      expect((await c.read(appUpdateProvider.notifier).check())?.file, 'cono-moto.apk');
    });

    test('description d\'avant (sans files) : Android n\'est pas interrogé', () async {
      final c = await makeContainer(FakeServer());
      final calls = mockNative();
      expect((await c.read(appUpdateProvider.notifier).check())?.file, 'cono-moto.apk');
      expect(calls, isEmpty);
    });
  });

  group('téléchargement en Wi-Fi (Android)', () {
    final now = DateTime(2026, 10, 6, 9);

    /// Conteneur dont la vérification automatique vient de trouver la build 60.
    Future<(ProviderContainer, AppUpdateController)> found(
      FakeServer server, {
      UpdatePlatform platform = UpdatePlatform.android,
    }) async {
      final c = await makeContainer(server, platform: platform);
      final ctrl = c.read(appUpdateProvider.notifier);
      expect((await ctrl.check(now: now))?.build, 60);
      return (c, ctrl);
    }

    test('en Wi-Fi : téléchargée en douce, puis installée sans retéléchargement', () async {
      final server = FakeServer();
      final calls = mockNative();
      final (c, ctrl) = await found(server);
      expect(c.read(appUpdateProvider).downloaded, isFalse);

      expect(await ctrl.preDownload(now: now), isTrue);
      final state = c.read(appUpdateProvider);
      expect(state.downloaded, isTrue);
      expect((state.phase, state.progress), (UpdatePhase.available, 0), reason: 'rien à l\'écran');
      expect(updatesFiles(), ['60-cono-moto.apk']);
      expect(server.requests, ['android.json', 'cono-moto.apk']);

      await ctrl.downloadAndInstall();
      expect(c.read(appUpdateProvider).phase, UpdatePhase.installing);
      expect(server.fileRequests, 1, reason: 'fichier complet réutilisé');
      expect(calls.map((m) => m.method), ['isNetworkUnmetered', 'installApk']);
    });

    test('jamais sur les données mobiles ni pendant une balade', () async {
      final server = FakeServer();
      final calls = mockNative(unmetered: false);
      final (c, ctrl) = await found(server);
      expect(await ctrl.preDownload(now: now), isFalse);

      // Android ne répond pas : comme les données mobiles.
      messenger.setMockMethodCallHandler(channel, null);
      expect(await ctrl.preDownload(now: now), isFalse);

      mockNative();
      c.read(fakeRideProvider.notifier).set(true);
      expect(await ctrl.preDownload(now: now), isFalse);
      expect(server.fileRequests, 0);
      expect(calls.map((m) => m.method), ['isNetworkUnmetered']);

      // Ces refus ne comptent pas comme un essai : balade finie, ça part.
      c.read(fakeRideProvider.notifier).set(false);
      expect(await ctrl.preDownload(now: now), isTrue);
      expect(server.fileRequests, 1);
    });

    test('réglage coupé (ou vérification automatique coupée) : rien', () async {
      final server = FakeServer();
      mockNative();
      final (c, ctrl) = await found(server);
      await ctrl.setWifiDownload(false);
      expect(c.read(sharedPreferencesProvider).getBool(AppUpdateController.wifiKey), isFalse);
      expect(await ctrl.preDownload(now: now), isFalse);

      await ctrl.setWifiDownload(true);
      await ctrl.setAutoCheck(false);
      expect(await ctrl.preDownload(now: now), isFalse);
      expect(server.fileRequests, 0);
      expect(updatesFiles(), isEmpty);
    });

    test('iPhone : rien', () async {
      final server = FakeServer();
      final calls = mockNative();
      final (_, ctrl) = await found(server, platform: UpdatePlatform.ios);
      expect(await ctrl.preDownload(now: now), isFalse);
      expect(server.requests, ['ios.json']);
      expect(calls, isEmpty);
    });

    test('au plus un essai par version et par jour', () async {
      final server = FakeServer()..fileStatus = 500;
      mockNative();
      final (c, ctrl) = await found(server);
      expect(await ctrl.preDownload(now: now), isFalse);
      expect(server.fileRequests, 1);
      expect(updatesFiles(), isEmpty);
      expect(c.read(appUpdateProvider).phase, UpdatePhase.available, reason: 'échec silencieux');

      server.fileStatus = 200;
      expect(await ctrl.preDownload(now: now.add(const Duration(hours: 6))), isFalse);
      expect(server.fileRequests, 1, reason: 'déjà essayé aujourd\'hui');

      // Nouvelle version publiée entre-temps : elle a droit à son essai.
      server.build = 61;
      await ctrl.check(manual: true, now: now.add(const Duration(hours: 6)));
      expect(await ctrl.preDownload(now: now.add(const Duration(hours: 6))), isTrue);
      expect(updatesFiles(), ['61-cono-moto.apk']);
      expect(server.fileRequests, 2);

      // Déjà prête : plus rien à télécharger.
      expect(await ctrl.preDownload(now: now.add(const Duration(days: 2))), isTrue);
      expect(server.fileRequests, 2);
    });

    test('le lendemain, nouvel essai', () async {
      final server = FakeServer()..fileStatus = 500;
      mockNative();
      final (_, ctrl) = await found(server);
      expect(await ctrl.preDownload(now: now), isFalse);
      server.fileStatus = 200;
      expect(await ctrl.preDownload(now: now.add(const Duration(hours: 25))), isTrue);
      expect(server.fileRequests, 2);
    });

    test('balade ou coupure en route : arrêt et fichier partiel supprimé', () async {
      final server = FakeServer();
      var chunks = StreamController<List<int>>();
      server.body = () => chunks.stream;
      mockNative();
      final (c, ctrl) = await found(server);

      var done = ctrl.preDownload(now: now);
      await pumpEventQueue();
      chunks.add([1, 2, 3]);
      await pumpEventQueue();
      expect(updatesFiles(), ['60-cono-moto.apk.part']);
      c.read(fakeRideProvider.notifier).set(true);
      chunks.add([4, 5, 6]);
      expect(await done, isFalse);
      expect(updatesFiles(), isEmpty);
      expect(c.read(appUpdateProvider).downloaded, isFalse);

      c.read(fakeRideProvider.notifier).set(false);
      chunks = StreamController<List<int>>();
      done = ctrl.preDownload(now: now.add(const Duration(days: 1)));
      await pumpEventQueue();
      chunks.add([1, 2, 3]);
      await pumpEventQueue();
      chunks.addError(const SocketException('Wi-Fi perdu'));
      expect(await done, isFalse);
      expect(updatesFiles(), isEmpty);
      expect(c.read(appUpdateProvider).phase, UpdatePhase.available);
    });

    test('« Mettre à jour » pendant le téléchargement en Wi-Fi : il continue au premier plan', () async {
      final server = FakeServer();
      final chunks = StreamController<List<int>>();
      server.body = () => chunks.stream;
      mockNative();
      final (c, ctrl) = await found(server);

      final background = ctrl.preDownload(now: now);
      await pumpEventQueue();
      chunks.add([1, 2, 3]);
      await pumpEventQueue();
      expect(c.read(appUpdateProvider).progress, 0, reason: 'rien à l\'écran en arrière-plan');

      final foreground = ctrl.downloadAndInstall();
      await pumpEventQueue();
      expect(c.read(appUpdateProvider).phase, UpdatePhase.downloading);
      chunks.add([4, 5, 6]);
      await chunks.close();
      await foreground;
      expect(await background, isTrue);
      expect(c.read(appUpdateProvider).phase, UpdatePhase.installing);
      expect(server.fileRequests, 1);
    });

    test('déjà téléchargée avant (appli relancée) : vu dès la recherche', () async {
      final dir = Directory.systemTemp.createTempSync('updates');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/60-cono-moto.apk').writeAsBytesSync([1, 2, 3, 4, 5, 6]);
      final server = FakeServer();
      final c = await makeContainer(server, dir: dir);
      final calls = mockNative();
      final ctrl = c.read(appUpdateProvider.notifier);
      await ctrl.check(now: now);
      expect(c.read(appUpdateProvider).downloaded, isTrue);
      expect(await ctrl.preDownload(now: now), isTrue);
      await ctrl.downloadAndInstall();
      expect(c.read(appUpdateProvider).phase, UpdatePhase.installing);
      expect(server.fileRequests, 0);
      expect(calls.map((m) => m.method), ['installApk']);
    });
  });

  group('écrans', () {
    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      await initTestLocale();
    });

    Future<ProviderContainer> pumpSettings(
      WidgetTester tester, {
      UpdatePlatform platform = UpdatePlatform.android,
      Directory? dir,
    }) async {
      final c = await makeContainer(FakeServer(), platform: platform, dir: dir);
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
      expect(find.text('Télécharger les mises à jour en Wi-Fi'), findsNothing);
      await tester.tap(find.textContaining('Version 1.0.0'));
      await tester.pumpAndSettle();
      expect(find.textContaining('SideStore'), findsOneWidget);
      expect(find.text('Comment faire'), findsOneWidget);
      expect(find.text('Mettre à jour'), findsNothing);
    });

    testWidgets('réglage « en Wi-Fi » : activé par défaut, mémorisé, suit la vérification automatique',
        (tester) async {
      final c = await pumpSettings(tester);
      final wifi = find.widgetWithText(SwitchListTile, 'Télécharger les mises à jour en Wi-Fi');
      expect(tester.widget<SwitchListTile>(wifi).value, isTrue);
      await tester.tap(wifi);
      await tester.pumpAndSettle();
      expect(c.read(appUpdateProvider).wifiDownload, isFalse);
      expect(c.read(sharedPreferencesProvider).getBool(AppUpdateController.wifiKey), isFalse);

      await tester.tap(find.text('Vérifier automatiquement'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(wifi).onChanged, isNull);
    });

    testWidgets('déjà téléchargée : la fenêtre le dit', (tester) async {
      final dir = Directory.systemTemp.createTempSync('updates');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/60-cono-moto.apk').writeAsBytesSync([1, 2, 3, 4, 5, 6]);
      await pumpSettings(tester, dir: dir);
      await tester.tap(find.textContaining('Version 1.0.0'));
      await tester.pumpAndSettle();
      expect(find.text('Déjà téléchargée, l\'installation prend quelques secondes'), findsOneWidget);
      expect(find.text('Mettre à jour'), findsOneWidget);
    });
  });
}
