import 'dart:convert';
import 'dart:typed_data';

import 'package:cono_moto/services/feedback/discord_feedback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _webhook = 'https://discord.com/api/webhooks/123456789/abc-DEF_ghi';
const _ctx = FeedbackContext(appLabel: 'v1.0.0 (build 12)', deviceLabel: 'Android 15');

FeedbackDraft _draft({FeedbackKind kind = FeedbackKind.idee, FeedbackAttachment? attachment}) => FeedbackDraft(
      kind: kind,
      title: '  Radars   sur la carte ',
      description: 'Afficher les radars fixes avec une alerte vocale. @everyone',
      author: 'Julien',
      attachment: attachment,
    );

void main() {
  group('message Discord', () {
    test('fil de forum, embed et mentions désactivées', () {
      final p = buildDiscordPayload(_draft(), _ctx, now: DateTime.utc(2026, 10, 5, 12));
      expect(p['thread_name'], '💡 Radars sur la carte');
      expect(p['allowed_mentions'], {'parse': <String>[]});
      final embed = (p['embeds'] as List).single as Map<String, dynamic>;
      expect(embed['title'], '💡 Idée : Radars sur la carte');
      expect(embed['description'], contains('@everyone'));
      expect(embed['color'], 0xFF6B1A);
      expect(embed['timestamp'], '2026-10-05T12:00:00.000Z');
      final fields = {for (final f in embed['fields'] as List) f['name']: f['value']};
      expect(fields['Type'], '💡 Idée');
      expect(fields['De la part de'], 'Julien');
      expect(fields['Appli'], 'v1.0.0 (build 12)');
      expect(fields['Téléphone'], 'Android 15');
      expect(embed.containsKey('image'), isFalse);
    });

    test('sans infos techniques ni fil', () {
      final d = FeedbackDraft(kind: FeedbackKind.bug, title: 'Carte figée', description: 'Elle se fige au verrouillage.', includeDeviceInfo: false);
      final p = buildDiscordPayload(d, _ctx, forumThread: false);
      expect(p.containsKey('thread_name'), isFalse);
      final fields = ((p['embeds'] as List).single as Map)['fields'] as List;
      expect(fields.map((f) => f['name']), ['Type']);
    });

    test('titres trop longs coupés', () {
      final d = FeedbackDraft(kind: FeedbackKind.idee, title: 'x' * 300, description: 'y' * 20);
      final p = buildDiscordPayload(d, _ctx);
      expect((p['thread_name'] as String).length, lessThanOrEqualTo(100));
      expect(((p['embeds'] as List).single['title'] as String).length, lessThanOrEqualTo(256));
    });

    test('titre et pied de page sur mesure (rapports de plantage)', () {
      const d = FeedbackDraft(kind: FeedbackKind.bug, title: 'StateError', description: 'Bad state: No element');
      final p = buildDiscordPayload(d, _ctx, heading: '💥 Plantage : StateError', footer: 'Rapport automatique');
      expect(p['thread_name'], '💥 Plantage : StateError');
      final embed = (p['embeds'] as List).single as Map<String, dynamic>;
      expect(embed['title'], '💥 Plantage : StateError');
      expect(embed['footer'], {'text': 'Rapport automatique'});
      expect((embed['fields'] as List).first, {'name': 'Type', 'value': '🐞 Bug', 'inline': true});
    });

    test('capture : référence attachment://', () {
      final a = FeedbackAttachment(bytes: Uint8List.fromList([1, 2, 3]), filename: 'capture.jpg');
      final p = buildDiscordPayload(_draft(attachment: a), _ctx);
      expect(((p['embeds'] as List).single as Map)['image'], {'url': 'attachment://capture.jpg'});
      expect(p['attachments'], [
        {'id': 0, 'filename': 'capture.jpg'},
      ]);
    });

    test('validation et texte à partager', () {
      expect(const FeedbackDraft(kind: FeedbackKind.idee, title: 'ab', description: 'assez long texte').validate(), isNotNull);
      expect(const FeedbackDraft(kind: FeedbackKind.idee, title: 'Titre', description: 'court').validate(), isNotNull);
      expect(_draft().validate(), isNull);
      final text = _draft().asPlainText(_ctx);
      expect(text, startsWith('💡 Idée pour Cono Moto : Radars   sur la carte'));
      expect(text, contains('— Julien'));
      expect(text, contains('(v1.0.0 (build 12) · Android 15)'));
    });

    test('forme du webhook', () {
      expect(DiscordFeedbackClient.isValidWebhook(_webhook), isTrue);
      expect(DiscordFeedbackClient.isValidWebhook('https://discordapp.com/api/webhooks/1/x'), isTrue);
      expect(DiscordFeedbackClient.isValidWebhook('https://evil.example/api/webhooks/1/x'), isFalse);
      expect(DiscordFeedbackClient.isValidWebhook(''), isFalse);
    });
  });

  group('envoi', () {
    test('JSON avec ?wait=true', () async {
      late http.Request sent;
      final c = DiscordFeedbackClient(
        webhookUrl: _webhook,
        client: MockClient((req) async {
          sent = req;
          return http.Response('{"id":"1"}', 200);
        }),
      );
      await c.send(_draft(), _ctx);
      expect(sent.method, 'POST');
      expect(sent.url.queryParameters['wait'], 'true');
      expect(sent.headers['content-type'], startsWith('application/json'));
      expect((jsonDecode(sent.body) as Map)['thread_name'], '💡 Radars sur la carte');
    });

    test('salon texte (pas un forum) : renvoi sans thread_name', () async {
      final bodies = <Map>[];
      final c = DiscordFeedbackClient(
        webhookUrl: _webhook,
        client: MockClient((req) async {
          final body = jsonDecode(req.body) as Map;
          bodies.add(body);
          return body.containsKey('thread_name')
              ? http.Response('{"code":220003,"message":"Webhooks can only create threads in forum channels"}', 400)
              : http.Response('{"id":"2"}', 200);
        }),
      );
      await c.send(_draft(), _ctx);
      expect(bodies, hasLength(2));
      expect(bodies.last.containsKey('thread_name'), isFalse);
    });

    test('message déjà construit : même renvoi sans thread_name', () async {
      final bodies = <Map>[];
      final c = DiscordFeedbackClient(
        webhookUrl: _webhook,
        client: MockClient((req) async {
          final body = jsonDecode(req.body) as Map;
          bodies.add(body);
          return http.Response('{}', body.containsKey('thread_name') ? 400 : 200);
        }),
      );
      final payload = buildDiscordPayload(_draft(), _ctx);
      await c.sendPayload(payload);
      expect(bodies, hasLength(2));
      expect(bodies.last.containsKey('thread_name'), isFalse);
      expect(payload.containsKey('thread_name'), isTrue); // message d'origine intact
      final rejected = DiscordFeedbackClient(webhookUrl: _webhook, client: MockClient((_) async => http.Response('', 400)));
      await expectLater(rejected.sendPayload(payload), throwsA(isA<FeedbackException>()));
    });

    test('capture envoyée en multipart', () async {
      late http.BaseRequest sent;
      String? payloadJson;
      final c = DiscordFeedbackClient(
        webhookUrl: _webhook,
        client: MockClient.streaming((req, stream) async {
          sent = req;
          final bytes = await stream.toBytes();
          final raw = latin1.decode(bytes);
          payloadJson = raw.contains('payload_json') ? raw : null;
          return http.StreamedResponse(Stream.value(utf8.encode('{"id":"3"}')), 200);
        }),
      );
      final a = FeedbackAttachment(bytes: Uint8List.fromList(List.filled(10, 7)), filename: 'capture.png');
      await c.send(_draft(attachment: a), _ctx);
      expect(sent.headers['content-type'], startsWith('multipart/form-data'));
      expect(payloadJson, contains('name="files[0]"; filename="capture.png"'));
    });

    test('erreurs lisibles', () async {
      Future<void> expectMessage(int status, String fragment) async {
        final c = DiscordFeedbackClient(webhookUrl: _webhook, client: MockClient((_) async => http.Response('', status)));
        await expectLater(
          c.send(_draft(), _ctx),
          throwsA(isA<FeedbackException>().having((e) => e.message, 'message', contains(fragment))),
        );
      }

      await expectMessage(404, 'webhook supprimé');
      await expectMessage(429, 'trop de messages');
      await expectMessage(500, 'erreur 500');
      final offline = DiscordFeedbackClient(
        webhookUrl: _webhook,
        client: MockClient((_) async => throw http.ClientException('no route')),
      );
      await expectLater(offline.send(_draft(), _ctx), throwsA(isA<FeedbackException>()));
      final notConfigured = DiscordFeedbackClient(webhookUrl: '', client: MockClient((_) async => http.Response('', 200)));
      expect(notConfigured.isConfigured, isFalse);
      await expectLater(notConfigured.send(_draft(), _ctx), throwsA(isA<FeedbackException>()));
    });
  });
}
