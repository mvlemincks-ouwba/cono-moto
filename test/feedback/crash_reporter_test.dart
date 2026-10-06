import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:cono_moto/core/crash_reporter.dart';
import 'package:cono_moto/services/feedback/discord_feedback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _webhook = 'https://discord.com/api/webhooks/123456789/abc-DEF_ghi';
const _ctx = FeedbackContext(appLabel: 'v1.0.0 (build 12)', deviceLabel: 'Android 15');

/// Faux Discord : compte les messages reçus, ou fait comme s'il n'y avait pas de réseau.
class _FakeDiscord {
  final posts = <Map<String, dynamic>>[];
  bool online = true;

  DiscordFeedbackClient client({String webhook = _webhook}) => DiscordFeedbackClient(
        webhookUrl: webhook,
        client: MockClient((req) async {
          if (!online) throw http.ClientException('Failed host lookup');
          posts.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response('{"id":"1"}', 200);
        }),
      );

  List<String> get titles => [for (final p in posts) ((p['embeds'] as List).single as Map)['title'] as String];
}

/// Pile d'appels différente pour chaque [where] (donc signature différente).
StackTrace _stack(String where) => StackTrace.fromString('''
#0      ListBase.first (dart:collection/list.dart:60:5)
#1      $where (package:cono_moto/features/ride/ride_controller.dart:123:5)
#2      State.setState (package:flutter/src/widgets/framework.dart:1219:30)
''');

void main() {
  late SharedPreferences prefs;
  late _FakeDiscord discord;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    discord = _FakeDiscord();
    now = DateTime(2026, 10, 6, 12);
  });

  CrashReporter reporter({bool? active = true, bool Function()? isEnabled, String webhook = _webhook}) => CrashReporter(
        prefs: prefs,
        client: discord.client(webhook: webhook),
        active: active,
        isEnabled: isEnabled,
        clock: () => now,
        appContext: () => _ctx,
        currentScreen: () => 'RideScreen',
      );

  group('anti-spam', () {
    test('même erreur : une fois par semaine au plus', () async {
      final r = reporter();
      await r.record(StateError('No element'), _stack('RideController.stop'));
      await r.record(StateError('No element'), _stack('RideController.stop'));
      expect(discord.posts, hasLength(1));
      expect(discord.titles.single, '💥 Plantage : StateError dans RideController.stop');

      now = now.add(const Duration(days: 6));
      await r.record(StateError('No element'), _stack('RideController.stop'));
      expect(discord.posts, hasLength(1));

      now = now.add(const Duration(days: 2));
      await r.record(StateError('No element'), _stack('RideController.stop'));
      expect(discord.posts, hasLength(2));
    });

    test('même erreur, même chez un autre rapporteur (appli relancée)', () async {
      await reporter().record(StateError('No element'), _stack('RideController.stop'));
      await reporter().record(StateError('No element'), _stack('RideController.stop'));
      expect(discord.posts, hasLength(1));
    });

    test('une erreur répétée en rafale ne part qu\'une fois', () async {
      final r = reporter();
      await Future.wait([
        for (var i = 0; i < 20; i++) r.record(StateError('No element'), _stack('RideController.stop')),
      ]);
      expect(discord.posts, hasLength(1));
    });

    test('3 rapports par jour au maximum', () async {
      final r = reporter();
      for (final where in ['A.a', 'B.b', 'C.c', 'D.d']) {
        await r.record(StateError('No element'), _stack(where));
      }
      expect(discord.posts, hasLength(3));

      now = now.add(const Duration(hours: 25));
      await r.record(StateError('No element'), _stack('D.d'));
      expect(discord.posts, hasLength(4));
    });

    test('coupures réseau ignorées', () async {
      final r = reporter();
      await r.record(const SocketException('Failed host lookup'), _stack('A.a'));
      await r.record(http.ClientException('Connection closed'), _stack('B.b'));
      expect(discord.posts, isEmpty);
    });
  });

  group('hors réseau', () {
    test('rapport gardé puis renvoyé au démarrage suivant', () async {
      discord.online = false;
      final r = reporter();
      await r.record(StateError('No element'), _stack('A.a'));
      expect(discord.posts, isEmpty);
      expect(r.pendingReports(), hasLength(1));

      // Démarrage suivant, avec du réseau.
      discord.online = true;
      final restarted = reporter();
      await restarted.flushPending();
      expect(discord.posts, hasLength(1));
      expect(discord.titles.single, '💥 Plantage : StateError dans A.a');
      expect(restarted.pendingReports(), isEmpty);
      expect(prefs.getStringList(CrashReporter.pendingKey), isNull);

      // Plus rien à renvoyer ensuite.
      await reporter().flushPending();
      expect(discord.posts, hasLength(1));
    });

    test('3 rapports en attente au maximum, les plus récents', () async {
      discord.online = false;
      final r = reporter();
      for (final where in ['A.a', 'B.b', 'C.c']) {
        await r.record(StateError('No element'), _stack(where));
      }
      now = now.add(const Duration(days: 1, hours: 1));
      await r.record(StateError('No element'), _stack('D.d'));
      expect(r.pendingReports().map((p) => p.heading), [
        '💥 Plantage : StateError dans B.b',
        '💥 Plantage : StateError dans C.c',
        '💥 Plantage : StateError dans D.d',
      ]);

      discord.online = true;
      await reporter().flushPending();
      expect(discord.posts, hasLength(3));
    });

    test('toujours pas de réseau au démarrage : on garde pour la fois d\'après', () async {
      discord.online = false;
      final r = reporter();
      await r.record(StateError('No element'), _stack('A.a'));
      await reporter().flushPending();
      expect(r.pendingReports(), hasLength(1));
    });

    test('rapport trop vieux abandonné', () async {
      discord.online = false;
      await reporter().record(StateError('No element'), _stack('A.a'));
      discord.online = true;
      now = now.add(const Duration(days: 8));
      await reporter().flushPending();
      expect(discord.posts, isEmpty);
    });
  });

  group('rien n\'est envoyé', () {
    test('réglage coupé', () async {
      await prefs.setBool('settings.crashReports', false);
      final r = reporter(); // lit le réglage dans les préférences
      await r.record(StateError('No element'), _stack('A.a'));
      expect(discord.posts, isEmpty);
    });

    test('réglage coupé après un plantage hors réseau : la file est vidée', () async {
      discord.online = false;
      await reporter().record(StateError('No element'), _stack('A.a'));
      discord.online = true;
      final r = reporter(isEnabled: () => false);
      await r.flushPending();
      expect(discord.posts, isEmpty);
      expect(r.pendingReports(), isEmpty);
    });

    test('debug et tests : rapporteur inactif', () async {
      final r = reporter(active: null); // valeur par défaut : kReleaseMode, faux ici
      expect(r.active, isFalse);
      await r.record(StateError('No element'), _stack('A.a'));
      await prefs.setStringList(CrashReporter.pendingKey, [
        jsonEncode({
          'type': 'StateError',
          'message': 'x',
          'frames': <String>[],
          'signature': 'abcd1234',
          'app': 'v1',
          'device': 'Android',
          'at': now.millisecondsSinceEpoch,
        }),
      ]);
      await r.flushPending();
      expect(discord.posts, isEmpty);
    });

    test('webhook absent de ce build', () async {
      final r = reporter(webhook: '');
      expect(r.isConfigured, isFalse);
      await r.record(StateError('No element'), _stack('A.a'));
      expect(discord.posts, isEmpty);
    });
  });

  group('branchement', () {
    late FlutterExceptionHandler? savedFlutter;
    late ErrorCallback? savedPlatform;

    setUp(() {
      savedFlutter = FlutterError.onError;
      savedPlatform = PlatformDispatcher.instance.onError;
    });

    tearDown(() {
      FlutterError.onError = savedFlutter;
      PlatformDispatcher.instance.onError = savedPlatform;
    });

    test('erreurs Flutter : toujours affichées, et signalées', () async {
      final presented = <FlutterErrorDetails>[];
      FlutterError.onError = presented.add;
      reporter().install();
      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('No element'),
        stack: _stack('RideController.stop'),
        library: 'widgets library',
        context: ErrorDescription('building RideScreen(dirty, state: _RideScreenState#a1b2c)'),
      ));
      // Erreur bénigne (image…), que Flutter n'affiche pas en release.
      FlutterError.onError!(FlutterErrorDetails(exception: StateError('silencieuse'), stack: _stack('B.b'), silent: true));
      await pumpEventQueue();
      expect(presented, hasLength(2));
      expect(discord.posts, hasLength(1));
      final description = ((discord.posts.single['embeds'] as List).single as Map)['description'] as String;
      expect(description, contains('**Contexte :** building RideScreen (widgets library)'));
      expect(description, contains('**Écran :** RideScreen'));
    });

    test('erreurs asynchrones : signalées, et laissées au moteur', () async {
      PlatformDispatcher.instance.onError = null;
      reporter().install();
      final handled = PlatformDispatcher.instance.onError!(StateError('No element'), _stack('A.a'));
      await pumpEventQueue();
      expect(handled, isFalse);
      expect(discord.posts, hasLength(1));
      final description = ((discord.posts.single['embeds'] as List).single as Map)['description'] as String;
      expect(description, contains('code asynchrone'));
    });
  });

  test('contexte Flutter sans détail du widget', () {
    expect(
      flutterErrorContext(FlutterErrorDetails(
        exception: StateError('x'),
        library: 'widgets library',
        context: ErrorDescription("building Tile-[<'Julien'>](dirty)"),
      )),
      'building Tile (widgets library)',
    );
    expect(flutterErrorContext(FlutterErrorDetails(exception: StateError('x'), library: null)), isNull);
  });

  group('écran affiché', () {
    testWidgets('onglet affiché, écran poussé, fenêtre par-dessus', (tester) async {
      final observer = CrashScreenObserver();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        home: const _Shell(tab: 1),
      ));
      expect(observer.currentScreen(), 'GarageScreen');

      navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const _DetailScreen()));
      await tester.pumpAndSettle();
      expect(observer.currentScreen(), 'DetailScreen');

      showDialog<void>(context: navigator.currentContext!, builder: (_) => const AlertDialog(title: Text('Sûr ?')));
      await tester.pumpAndSettle();
      expect(observer.currentScreen(), 'DetailScreen');

      navigator.currentState!
        ..pop()
        ..pop();
      await tester.pumpAndSettle();
      expect(observer.currentScreen(), 'GarageScreen');
    });
  });
}

/// Accueil façon HomeShell : onglets dans un IndexedStack.
class _Shell extends StatelessWidget {
  const _Shell({required this.tab});

  final int tab;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: tab, children: const [_MapScreen(), _GarageScreen()]),
      );
}

class _MapScreen extends StatelessWidget {
  const _MapScreen();

  @override
  Widget build(BuildContext context) => const Text('Carte');
}

class _GarageScreen extends StatelessWidget {
  const _GarageScreen();

  @override
  Widget build(BuildContext context) => const Text('Garage');
}

class _DetailScreen extends StatelessWidget {
  const _DetailScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Détail'));
}
