import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cono_moto/services/update/app_update.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const base = 'https://github.com/moi/cono-moto/releases/download/derniere-version';

Map<String, dynamic> manifestJson({int build = 57, int size = 6, String platform = 'android'}) => {
      'platform': platform,
      'version': '1.0.0',
      'build': build,
      'commit': 'abc1234',
      'date': '2026-10-06T08:00:00Z',
      'file': platform == 'android' ? 'cono-moto.apk' : 'cono-moto-unsigned.ipa',
      'size': size,
      'notes': ['Mises à jour automatiques', '  ', 'Boîte à idées'],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateManifest', () {
    test('lecture et comparaison', () {
      final m = UpdateManifest.fromJson(manifestJson(size: 52 * 1024 * 1024));
      expect(m.platform, UpdatePlatform.android);
      expect(m.build, 57);
      expect(m.notes, ['Mises à jour automatiques', 'Boîte à idées']);
      expect(m.label, 'v1.0.0 (build 57)');
      expect(m.sizeLabel, '52 Mo');
      expect(m.isNewerThan(56), isTrue);
      expect(m.isNewerThan(57), isFalse);
      expect(m.isNewerThan(null), isFalse, reason: 'version de développement');
    });

    test('fichier invalide refusé', () {
      expect(() => UpdateManifest.fromJson({...manifestJson(), 'build': '57'}), throwsFormatException);
      expect(() => UpdateManifest.fromJson({...manifestJson(), 'file': '../x.apk'}), throwsFormatException);
      expect(() => UpdateManifest.fromJson({...manifestJson(), 'platform': 'windows'}), throwsFormatException);
    });

    test('APK par architecture (files), absents des descriptions d\'avant', () {
      expect(UpdateManifest.fromJson(manifestJson()).files, isEmpty);
      final m = UpdateManifest.fromJson({
        ...manifestJson(size: 40),
        'files': {
          'arm64-v8a': {'file': 'cono-moto.apk', 'size': 40},
          'armeabi-v7a': {'file': 'cono-moto-armeabi-v7a.apk', 'size': 35},
        },
      });
      expect(m.files.keys, ['arm64-v8a', 'armeabi-v7a']);
      expect((m.files['armeabi-v7a']!.name, m.files['armeabi-v7a']!.size), ('cono-moto-armeabi-v7a.apk', 35));

      for (final files in [
        {'armeabi-v7a': {'file': '../x.apk', 'size': 1}},
        {'armeabi-v7a': {'file': '', 'size': 1}},
        {'armeabi-v7a': {'size': 1}},
        {'armeabi-v7a': 'cono-moto-armeabi-v7a.apk'},
        ['cono-moto.apk'],
      ]) {
        expect(() => UpdateManifest.fromJson({...manifestJson(), 'files': files}), throwsFormatException,
            reason: '$files');
      }
    });

    test('choix de l\'APK selon les architectures du téléphone', () {
      final m = UpdateManifest.fromJson({
        ...manifestJson(size: 40),
        'files': {
          'arm64-v8a': {'file': 'cono-moto.apk', 'size': 40},
          'armeabi-v7a': {'file': 'cono-moto-armeabi-v7a.apk', 'size': 35},
        },
      });
      String pick(List<String> abis) {
        final p = m.forAbis(abis);
        expect((p.build, p.notes, p.files), (m.build, m.notes, m.files), reason: 'même version');
        return '${p.file} ${p.size}';
      }

      expect(pick(['arm64-v8a', 'armeabi-v7a', 'armeabi']), 'cono-moto.apk 40');
      expect(pick(['armeabi-v7a', 'armeabi']), 'cono-moto-armeabi-v7a.apk 35', reason: 'vieux téléphone 32 bits');
      expect(pick(['x86_64', 'arm64-v8a']), 'cono-moto.apk 40', reason: 'architecture non publiée sautée');
      expect(pick(['x86_64']), 'cono-moto.apk 40', reason: 'rien ne correspond : file');
      expect(pick([]), 'cono-moto.apk 40', reason: 'architectures inconnues : file');

      final old = UpdateManifest.fromJson(manifestJson());
      expect(identical(old.forAbis(['armeabi-v7a']), old), isTrue, reason: 'description d\'avant : file');
    });
  });

  group('UpdateClient', () {
    test('lit android.json à côté des fichiers publiés', () async {
      Uri? asked;
      final client = UpdateClient(
        baseUrl: '$base/',
        client: MockClient((r) async {
          asked = r.url;
          return http.Response.bytes(utf8.encode(jsonEncode(manifestJson())), 200);
        }),
      );
      final m = await client.latest(UpdatePlatform.android);
      expect(asked.toString(), '$base/android.json');
      expect(m.build, 57);
      expect(client.pageUri.toString(), 'https://github.com/moi/cono-moto/releases/tag/derniere-version');
      expect(UpdateClient(baseUrl: 'https://exemple.fr/maj').pageUri, isNull);
    });

    test('erreurs en français', () async {
      Future<String> error(http.Response response) async {
        final c = UpdateClient(baseUrl: base, client: MockClient((_) async => response));
        try {
          await c.latest(UpdatePlatform.ios);
          return 'aucune';
        } on UpdateException catch (e) {
          return e.message;
        }
      }

      expect(await error(http.Response('', 404)), contains('Aucune version publiée'));
      expect(await error(http.Response('', 503)), contains('(503)'));
      expect(await error(http.Response('<html>', 200)), contains('illisible'));
      expect(
        () => UpdateClient(baseUrl: '').latest(UpdatePlatform.android),
        throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('pas configurées'))),
      );
    });

    test('pas de connexion', () async {
      final c = UpdateClient(baseUrl: base, client: MockClient((_) async => throw const SocketException('down')));
      expect(
        () => c.latest(UpdatePlatform.android),
        throwsA(isA<UpdateException>().having((e) => e.message, 'message', 'Pas de connexion internet.')),
      );
    });

    group('téléchargement', () {
      late Directory dir;
      setUp(() => dir = Directory.systemTemp.createTempSync('updates'));
      tearDown(() => dir.deleteSync(recursive: true));

      MockClient streaming(List<List<int>> chunks, {List<Uri>? asked}) => MockClient.streaming((r, _) async {
            asked?.add(r.url);
            return http.StreamedResponse(Stream.fromIterable(chunks), 200);
          });

      test('progression, fichier complet et nettoyage des anciennes versions', () async {
        File('${dir.path}/50-cono-moto.apk').writeAsStringSync('ancienne');
        final asked = <Uri>[];
        final client = UpdateClient(baseUrl: base, client: streaming([[1, 2, 3], [4, 5, 6]], asked: asked));
        final progress = <double>[];
        final file = await client.download(UpdateManifest.fromJson(manifestJson()), dir, onProgress: progress.add);
        expect(asked.single.toString(), '$base/cono-moto.apk');
        expect(file.path, endsWith('57-cono-moto.apk'));
        expect(file.readAsBytesSync(), [1, 2, 3, 4, 5, 6]);
        expect(progress, [0.5, 1.0]);
        expect(dir.listSync().map((f) => f.path.split('/').last), ['57-cono-moto.apk']);

        // Déjà téléchargée : rien n'est retéléchargé.
        final again = await client.download(UpdateManifest.fromJson(manifestJson()), dir);
        expect(again.path, file.path);
        expect(asked, hasLength(1));
      });

      test('fichier complet déjà là : réutilisé (taille vérifiée)', () async {
        final m = UpdateManifest.fromJson(manifestJson());
        final asked = <Uri>[];
        final client = UpdateClient(baseUrl: base, client: streaming([[1, 2, 3, 4, 5, 6]], asked: asked));
        expect(client.downloaded(m, dir), isNull);
        File('${dir.path}/57-cono-moto.apk').writeAsBytesSync([1, 2, 3]);
        expect(client.downloaded(m, dir), isNull, reason: 'taille différente');

        File('${dir.path}/57-cono-moto.apk').writeAsBytesSync([9, 9, 9, 9, 9, 9]);
        expect(client.downloaded(m, dir)?.path, endsWith('57-cono-moto.apk'));
        final file = await client.download(m, dir);
        expect(file.readAsBytesSync(), [9, 9, 9, 9, 9, 9]);
        expect(asked, isEmpty);
      });

      test('arrêté en route (keepGoing) : erreur et rien ne reste', () async {
        final chunks = StreamController<List<int>>();
        final client = UpdateClient(
          baseUrl: base,
          client: MockClient.streaming((_, _) async => http.StreamedResponse(chunks.stream, 200)),
        );
        var go = true;
        final done = client.download(UpdateManifest.fromJson(manifestJson()), dir, keepGoing: () => go);
        await pumpEventQueue();
        chunks.add([1, 2, 3]);
        await pumpEventQueue();
        expect(dir.listSync().map((f) => f.path.split('/').last), ['57-cono-moto.apk.part']);
        go = false;
        chunks.add([4, 5, 6]);
        await expectLater(done, throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('arrêté'))));
        expect(dir.listSync(), isEmpty);
        await chunks.close();
      });

      test('connexion coupée en route : fichier partiel supprimé', () async {
        final chunks = StreamController<List<int>>();
        final client = UpdateClient(
          baseUrl: base,
          client: MockClient.streaming((_, _) async => http.StreamedResponse(chunks.stream, 200)),
        );
        final done = client.download(UpdateManifest.fromJson(manifestJson()), dir);
        await pumpEventQueue();
        chunks.add([1, 2, 3]);
        await pumpEventQueue();
        chunks.addError(const SocketException('coupé'));
        await expectLater(done, throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('interrompu'))));
        expect(dir.listSync(), isEmpty);
        await chunks.close();
      });

      test('fichier incomplet : erreur et rien ne reste', () async {
        final client = UpdateClient(baseUrl: base, client: streaming([[1, 2, 3]]));
        await expectLater(
          client.download(UpdateManifest.fromJson(manifestJson()), dir),
          throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('incomplet'))),
        );
        expect(dir.listSync(), isEmpty);
      });

      test('erreur du serveur', () async {
        final client = UpdateClient(
          baseUrl: base,
          client: MockClient.streaming((_, _) async => http.StreamedResponse(const Stream.empty(), 404)),
        );
        await expectLater(
          client.download(UpdateManifest.fromJson(manifestJson()), dir),
          throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('(404)'))),
        );
      });
    });
  });

  group('ApkInstaller', () {
    const channel = MethodChannel('test/updater');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('lancement, autorisation manquante, non disponible', () async {
      final installer = ApkInstaller(channel: channel);
      final calls = <MethodCall>[];
      var answer = 'started';
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return answer;
      });
      expect(await installer.install('/tmp/a.apk'), InstallStart.started);
      expect(calls.single.arguments, {'path': '/tmp/a.apk'});
      answer = 'permission';
      expect(await installer.install('/tmp/a.apk'), InstallStart.needsPermission);

      messenger.setMockMethodCallHandler(channel, null);
      expect(await installer.install('/tmp/a.apk'), InstallStart.unsupported);
      installer.dispose();
    });

    test('Android remonte le résultat de l\'installation', () async {
      final installer = ApkInstaller(channel: channel);
      messenger.setMockMethodCallHandler(channel, (_) async => 'started');
      await installer.install('/tmp/a.apk');
      final events = <InstallEvent>[];
      final sub = installer.events.listen(events.add);

      Future<void> send(Map<String, Object?> args) => messenger.handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(MethodCall('installStatus', args)),
            (_) {},
          );
      await send({'status': 'pending'});
      await send({'status': 'failure', 'code': 6, 'message': 'INSTALL_FAILED_INSUFFICIENT_STORAGE'});
      await pumpEventQueue();
      expect(events.map((e) => e.outcome), [InstallOutcome.pending, InstallOutcome.failure]);
      expect(events.last.message, 'Pas assez de place sur le téléphone.');
      await sub.cancel();
      installer.dispose();
    });

    test('architectures et type de connexion, prudents si Android ne répond pas', () async {
      final installer = ApkInstaller(channel: channel);
      final calls = <String>[];
      Object? unmetered = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'supportedAbis' => ['arm64-v8a', 'armeabi-v7a', 'armeabi'],
          'isNetworkUnmetered' => unmetered,
          _ => null,
        };
      });
      expect(await installer.supportedAbis(), ['arm64-v8a', 'armeabi-v7a', 'armeabi']);
      expect(await installer.supportedAbis(), hasLength(3));
      expect(calls.where((m) => m == 'supportedAbis'), hasLength(1), reason: 'gardées en mémoire');
      expect(await installer.isNetworkUnmetered(), isTrue);
      unmetered = false;
      expect(await installer.isNetworkUnmetered(), isFalse);
      unmetered = null;
      expect(await installer.isNetworkUnmetered(), isFalse, reason: 'inconnu : comme les données mobiles');

      messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'X'));
      expect(await installer.isNetworkUnmetered(), isFalse);
      expect(await ApkInstaller(channel: channel).supportedAbis(), isEmpty);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await installer.isNetworkUnmetered(), isFalse);
      expect(await ApkInstaller(channel: channel).supportedAbis(), isEmpty);
    });

    test('messages d\'échec', () {
      expect(installFailureMessage(3), 'Installation annulée.');
      expect(installFailureMessage(5), contains('signature différente'));
      expect(installFailureMessage(null), contains('a échoué'));
    });
  });
}
