import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cono_moto/services/feedback/crash_report.dart';
import 'package:cono_moto/services/feedback/discord_feedback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _ctx = FeedbackContext(appLabel: 'v1.0.0 (build 12, abc1234)', deviceLabel: 'Android 15');
const _webhook = 'https://discord.com/api/webhooks/123456789/abc-DEF_ghi';

final _stack = StackTrace.fromString('''
#0      ListBase.first (dart:collection/list.dart:60:5)
#1      RideController.stop (package:cono_moto/features/ride/ride_controller.dart:123:5)
#2      _RideScreenState._onStop.<anonymous closure> (package:cono_moto/features/ride/ride_screen.dart:88:12)
<asynchronous suspension>
#3      State.setState (package:flutter/src/widgets/framework.dart:1219:30)
#4      _RideScreenState.build (package:cono_moto/features/ride/ride_screen.dart:42:7)
#5      StatefulElement.build (package:flutter/src/widgets/framework.dart:5842:27)
#6      ComponentElement.performRebuild (package:flutter/src/widgets/framework.dart:5730:15)
''');

CrashReport _capture(Object error, StackTrace? stack, {String? context, String? screen}) => CrashReport.capture(
      error,
      stack,
      app: _ctx,
      at: DateTime.utc(2026, 10, 6, 12, 34),
      context: context,
      screen: screen,
    );

class _BoomError extends Error {}

Map<String, dynamic> _embed(Map<String, dynamic> payload) => (payload['embeds'] as List).single as Map<String, dynamic>;

/// Taille comptée par Discord pour un embed (limite : 6000 caractères).
int _embedSize(Map<String, dynamic> e) =>
    (e['title'] as String).length +
    (e['description'] as String).length +
    ((e['footer'] as Map)['text'] as String).length +
    (e['fields'] as List).fold<int>(0, (n, f) => n + (f['name'] as String).length + (f['value'] as String).length);

void main() {
  group('pile d\'appels', () {
    test('lignes nettoyées, sans « asynchronous suspension »', () {
      final frames = parseFrames(_stack);
      expect(frames.first, 'ListBase.first (dart:collection/list.dart:60:5)');
      expect(frames, hasLength(7));
      expect(frames.any((f) => f.contains('asynchronous')), isFalse);
      expect(parseFrames(null), isEmpty);
    });

    test('chemins locaux retirés', () {
      final frames = parseFrames(StackTrace.fromString('#0      main (file:///home/marc/cono-moto/lib/main.dart:10:5)'));
      expect(frames.single, 'main (main.dart:10:5)');
    });

    test('lignes utiles : la première puis celles de l\'appli', () {
      final useful = usefulFrames(parseFrames(_stack));
      expect(useful, [
        'ListBase.first (dart:collection/list.dart:60:5)',
        'RideController.stop (package:cono_moto/features/ride/ride_controller.dart:123:5)',
        '_RideScreenState._onStop.<anonymous closure> (package:cono_moto/features/ride/ride_screen.dart:88:12)',
        '…',
        '_RideScreenState.build (package:cono_moto/features/ride/ride_screen.dart:42:7)',
        '…',
      ]);
    });

    test('sans ligne de l\'appli : le haut de la pile', () {
      final frames = [for (var i = 0; i < 30; i++) 'Flutter.f$i (package:flutter/src/x.dart:$i:1)'];
      final useful = usefulFrames(frames);
      expect(useful, hasLength(11));
      expect(useful.first, frames.first);
      expect(useful.last, '…');
    });

    test('pile énorme : longueur plafonnée', () {
      final frames = [for (var i = 0; i < 500; i++) 'Foo.bar$i (package:cono_moto/features/x/${'y' * 150}.dart:$i:1)'];
      final useful = usefulFrames(frames);
      expect(useful.join('\n').length, lessThanOrEqualTo(2400));
      expect(useful.every((f) => f.length <= 200), isTrue);
    });
  });

  group('signature', () {
    test('même erreur, même signature, même après un changement de ligne', () {
      final a = crashSignature('StateError', parseFrames(_stack));
      final moved = StackTrace.fromString(_stack.toString().replaceAll('123:5', '140:9').replaceAll('88:12', '91:3'));
      expect(a, matches(RegExp(r'^[0-9a-f]{8}$')));
      expect(crashSignature('StateError', parseFrames(moved)), a);
    });

    test('autre type ou autre endroit : autre signature', () {
      final frames = parseFrames(_stack);
      final a = crashSignature('StateError', frames);
      expect(crashSignature('RangeError', frames), isNot(a));
      final elsewhere = [for (final f in frames) f.replaceAll('RideController.stop', 'RideController.start')];
      expect(crashSignature('StateError', elsewhere), isNot(a));
    });

    test('les lignes Flutter sous l\'appli ne changent rien', () {
      final frames = parseFrames(_stack);
      final a = crashSignature('StateError', frames);
      expect(crashSignature('StateError', [...frames, 'Other.thing (package:flutter/src/y.dart:1:1)']), a);
    });
  });

  group('données personnelles', () {
    test('liens, e-mails, positions, numéros, identifiants et textes saisis retirés', () {
      final text = scrubPersonalData(
        'Echec $_webhook?wait=true pour julien.dupont@gmail.com à 48.856613, 2.352222, '
        'tel +33 6 12 34 56 78 ou 0612345678, uid aB3dE5fG7hI9jK1lM3nO5pQ7rS9t, '
        'balade 550e8400-e29b-41d4-a716-446655440000, groupe K7PM2XAB, nom "Julien" « Seb »',
      );
      for (final secret in [
        'abc-DEF_ghi',
        '123456789',
        'webhooks',
        'julien.dupont',
        '48.856613',
        '2.352222',
        '12 34 56',
        '0612345678',
        'aB3dE5fG7hI9jK1lM3nO5pQ7rS9t',
        '550e8400',
        'K7PM2XAB',
        'Julien',
        'Seb',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains('‹lien discord.com›'));
    });

    test('messages d\'erreur ordinaires intacts', () {
      expect(scrubPersonalData('Bad state: No element'), 'Bad state: No element');
      const typeError = "type 'Null' is not a subtype of type 'String' in type cast";
      expect(scrubPersonalData(typeError), typeError);
    });

    test('FormatException : pas le texte illisible', () {
      const e = FormatException('Unexpected character', '{"name":"Julien","lat":48.85}', 1);
      final msg = describeError(e);
      expect(msg, 'FormatException: Unexpected character');
    });

    test('message coupé', () {
      expect(describeError(StateError('x' * 5000)).length, lessThanOrEqualTo(600));
    });
  });

  group('rapport', () {
    test('type, titre et contenu', () {
      final r = _capture(StateError('No element'), _stack, context: 'building RideScreen (widgets library)', screen: 'RideScreen');
      expect(r.type, 'StateError');
      expect(r.heading, '💥 Plantage : StateError dans RideController.stop');
      expect(r.details, contains('Bad state: No element'));
      expect(r.details, contains('**Écran :** RideScreen'));
      expect(r.details, contains('**Contexte :** building RideScreen (widgets library)'));
      expect(r.details, contains('**Signature :** `${r.signature}` · le 2026-10-06 à 12:34 UTC'));
      expect(r.details, contains('RideController.stop (package:cono_moto/features/ride/ride_controller.dart:123:5)'));
    });

    test('type interne sans « _ », pas de pile', () {
      final r = _capture(_BoomError(), null);
      expect(r.type, 'BoomError');
      expect(r.heading, '💥 Plantage : BoomError');
      expect(r.frames, isEmpty);
      expect(r.details, isNot(contains('Pile')));
    });

    test('aller-retour JSON (file d\'attente)', () {
      final r = _capture(StateError('No element'), _stack, context: 'ctx', screen: 'GarageScreen');
      final back = CrashReport.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.toJson(), r.toJson());
      expect(back.id, r.id);
    });
  });

  group('message Discord', () {
    test('bug de l\'appli : champ « Type » = Bug, compris par le pont GitHub', () {
      final r = _capture(StateError('No element'), _stack);
      final p = buildCrashPayload(r);
      expect(p['thread_name'], '💥 Plantage : StateError dans RideController.stop');
      expect(p['allowed_mentions'], {'parse': <String>[]});
      final embed = _embed(p);
      expect(embed['title'], '💥 Plantage : StateError dans RideController.stop');
      expect(embed['timestamp'], '2026-10-06T12:34:00.000Z');
      expect((embed['footer'] as Map)['text'], contains('automatiquement'));
      final fields = {for (final f in embed['fields'] as List) f['name']: f['value']};
      expect(fields['Type'], '🐞 Bug');
      expect(fields['Appli'], 'v1.0.0 (build 12, abc1234)');
      expect(fields['Téléphone'], 'Android 15');
      expect(fields.containsKey('De la part de'), isFalse);
    });

    test('erreur énorme : loin des limites de Discord, rien de personnel', () {
      final message = 'Echec @everyone $_webhook "Julien" 48.8566,2.3522 +33612345678 ${'x' * 9000}';
      final stack = StackTrace.fromString([
        for (var i = 0; i < 800; i++) '#$i      Foo.bar$i (package:cono_moto/features/${'z' * 120}.dart:$i:1)',
      ].join('\n'));
      final p = buildCrashPayload(_capture(StateError(message), stack, context: 'c' * 500, screen: 's' * 500));
      final embed = _embed(p);
      expect((embed['description'] as String).length, lessThanOrEqualTo(4096));
      expect(_embedSize(embed), lessThanOrEqualTo(6000));
      expect((p['thread_name'] as String).length, lessThanOrEqualTo(100));
      final json = jsonEncode(p);
      for (final secret in ['abc-DEF_ghi', '123456789', 'Julien', '48.8566', '612345678']) {
        expect(json, isNot(contains(secret)), reason: secret);
      }
      // Blocs de code bien fermés (sinon le ticket GitHub est illisible).
      expect('```'.allMatches(embed['description'] as String).length.isEven, isTrue);
    });
  });

  test('coupures réseau ignorées, vraies erreurs gardées', () {
    expect(isBenignCrash(const SocketException('Failed host lookup')), isTrue);
    expect(isBenignCrash(http.ClientException('Connection closed')), isTrue);
    expect(isBenignCrash(TimeoutException('trop long')), isTrue);
    expect(isBenignCrash(const HttpException('Connection reset')), isTrue);
    expect(isBenignCrash(StateError('No element')), isFalse);
    expect(isBenignCrash(const FormatException('bad')), isFalse);
  });
}
