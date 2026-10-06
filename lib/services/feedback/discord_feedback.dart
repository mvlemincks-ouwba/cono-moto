import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/config.dart';

/// Nature d'un retour utilisateur.
enum FeedbackKind {
  idee('Idée', '💡', 0xFFFF6B1A),
  bug('Bug', '🐞', 0xFFEF4444),
  autre('Autre', '💬', 0xFF6B7280);

  const FeedbackKind(this.label, this.emoji, this.color);

  final String label;
  final String emoji;
  final int color;
}

/// Capture d'écran jointe.
class FeedbackAttachment {
  const FeedbackAttachment({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;

  /// Limite Discord (10 Mo) avec une marge.
  static const maxBytes = 8 * 1024 * 1024;
}

/// Ce que l'utilisateur a saisi.
class FeedbackDraft {
  const FeedbackDraft({
    required this.kind,
    required this.title,
    required this.description,
    this.author = '',
    this.attachment,
    this.includeDeviceInfo = true,
  });

  final FeedbackKind kind;
  final String title;
  final String description;
  final String author;
  final FeedbackAttachment? attachment;
  final bool includeDeviceInfo;

  /// Message d'erreur de validation, ou null si tout est bon.
  String? validate() {
    if (title.trim().length < 3) return 'Donne un titre (3 caractères minimum).';
    if (description.trim().length < 10) return 'Explique un peu plus (10 caractères minimum).';
    if (attachment != null && attachment!.bytes.length > FeedbackAttachment.maxBytes) {
      return 'Capture trop lourde (8 Mo maximum).';
    }
    return null;
  }

  /// Version texte, pour partager autrement (WhatsApp, Messages…).
  String asPlainText(FeedbackContext ctx) {
    final sb = StringBuffer('${kind.emoji} ${kind.label} pour Cono Moto : ${title.trim()}\n\n${description.trim()}');
    if (author.trim().isNotEmpty) sb.write('\n\n— ${author.trim()}');
    if (includeDeviceInfo) sb.write('\n(${ctx.appLabel} · ${ctx.deviceLabel})');
    return sb.toString();
  }
}

/// Infos techniques jointes au retour.
class FeedbackContext {
  const FeedbackContext({required this.appLabel, required this.deviceLabel});

  factory FeedbackContext.current() {
    final build = AppConfig.appBuild;
    final commit = AppConfig.appCommit.length >= 7 ? AppConfig.appCommit.substring(0, 7) : AppConfig.appCommit;
    final app = 'v${AppConfig.appVersion} (build $build${commit.isEmpty ? '' : ', $commit'})';
    String device;
    try {
      final os = Platform.isIOS ? 'iOS' : (Platform.isAndroid ? 'Android' : Platform.operatingSystem);
      device = '$os ${Platform.operatingSystemVersion}';
    } catch (_) {
      device = 'inconnu';
    }
    return FeedbackContext(appLabel: app, deviceLabel: device);
  }

  final String appLabel;
  final String deviceLabel;
}

/// Erreur d'envoi, avec un message prêt à afficher.
class FeedbackException implements Exception {
  const FeedbackException(this.message);
  final String message;
  @override
  String toString() => message;
}

String _cut(String s, int max) => s.length <= max ? s : '${s.substring(0, max - 1)}…';

/// Construit le message Discord (webhook). Les mentions sont désactivées pour
/// qu'un « @everyone » tapé par quelqu'un ne notifie pas tout le serveur.
/// [heading] remplace « 💡 Idée : titre » comme titre et nom du fil (rapports
/// de plantage : « 💥 Plantage : StateError »).
Map<String, dynamic> buildDiscordPayload(
  FeedbackDraft d,
  FeedbackContext ctx, {
  bool forumThread = true,
  DateTime? now,
  String? heading,
  String footer = 'Envoyé depuis l\'appli Cono Moto',
}) {
  final title = d.title.trim().replaceAll(RegExp(r'\s+'), ' ');
  final fields = <Map<String, dynamic>>[
    {'name': 'Type', 'value': '${d.kind.emoji} ${d.kind.label}', 'inline': true},
    if (d.author.trim().isNotEmpty) {'name': 'De la part de', 'value': _cut(d.author.trim(), 100), 'inline': true},
    if (d.includeDeviceInfo) ...[
      {'name': 'Appli', 'value': ctx.appLabel, 'inline': true},
      {'name': 'Téléphone', 'value': _cut(ctx.deviceLabel, 200), 'inline': true},
    ],
  ];
  final attachment = d.attachment;
  return {
    'username': 'Cono Moto',
    if (forumThread) 'thread_name': _cut(heading ?? '${d.kind.emoji} $title', 100),
    'allowed_mentions': {'parse': <String>[]},
    'embeds': [
      {
        'title': _cut(heading ?? '${d.kind.emoji} ${d.kind.label} : $title', 256),
        'description': _cut(d.description.trim(), 4000),
        'color': d.kind.color & 0xFFFFFF,
        'fields': fields,
        'footer': {'text': footer},
        'timestamp': (now ?? DateTime.now()).toUtc().toIso8601String(),
        if (attachment != null) 'image': {'url': 'attachment://${attachment.filename}'},
      },
    ],
    if (attachment != null)
      'attachments': [
        {'id': 0, 'filename': attachment.filename},
      ],
  };
}

/// Envoi des retours sur un salon Discord via webhook.
class DiscordFeedbackClient {
  DiscordFeedbackClient({
    String? webhookUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 25),
  }) : webhookUrl = (webhookUrl ?? AppConfig.discordFeedbackWebhook).trim(),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String webhookUrl;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  /// Le webhook est-il renseigné (et a-t-il la bonne forme) ?
  bool get isConfigured => isValidWebhook(webhookUrl);

  static bool isValidWebhook(String url) =>
      RegExp(r'^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+$').hasMatch(url.trim());

  /// Publie le retour.
  Future<void> send(FeedbackDraft draft, FeedbackContext ctx) async {
    if (!isConfigured) throw const FeedbackException('Le Discord n\'est pas encore branché sur cette version de l\'appli.');
    final error = draft.validate();
    if (error != null) throw FeedbackException(error);
    await sendPayload(buildDiscordPayload(draft, ctx), attachment: draft.attachment);
  }

  /// Publie un message déjà construit (retour ou rapport de plantage). Sur un
  /// salon forum, chaque message ouvre un fil ; sur un salon texte classique,
  /// Discord refuse `thread_name` : on renvoie sans.
  Future<void> sendPayload(Map<String, dynamic> payload, {FeedbackAttachment? attachment}) async {
    if (!isConfigured) throw const FeedbackException('Le Discord n\'est pas encore branché sur cette version de l\'appli.');
    var response = await _post(payload, attachment);
    if (response.statusCode == 400 && payload.containsKey('thread_name')) {
      response = await _post({...payload}..remove('thread_name'), attachment);
    }
    final code = response.statusCode;
    if (code >= 200 && code < 300) return;
    if (code == 404 || code == 401) {
      throw const FeedbackException('Le salon Discord n\'existe plus (webhook supprimé). Préviens l\'admin du serveur.');
    }
    if (code == 429) {
      throw const FeedbackException('Discord reçoit trop de messages en ce moment. Réessaie dans une minute.');
    }
    throw FeedbackException('Discord a refusé le message (erreur $code). Réessaie ou partage autrement.');
  }

  Future<http.Response> _post(Map<String, dynamic> payload, FeedbackAttachment? attachment) async {
    final uri = Uri.parse(webhookUrl).replace(queryParameters: {'wait': 'true'});
    try {
      if (attachment == null) {
        return await _client
            .post(
              uri,
              headers: {'Content-Type': 'application/json', 'User-Agent': AppConfig.userAgent},
              body: jsonEncode(payload),
            )
            .timeout(timeout);
      }
      final request = http.MultipartRequest('POST', uri)
        ..headers['User-Agent'] = AppConfig.userAgent
        ..fields['payload_json'] = jsonEncode(payload)
        ..files.add(http.MultipartFile.fromBytes('files[0]', attachment.bytes, filename: attachment.filename));
      final streamed = await _client.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const FeedbackException('Discord met trop de temps à répondre. Réessaie dans un instant.');
    } on SocketException {
      throw const FeedbackException('Pas de réseau : ton message n\'est pas parti. Réessaie plus tard ou partage autrement.');
    } on http.ClientException {
      throw const FeedbackException('Pas de réseau : ton message n\'est pas parti. Réessaie plus tard ou partage autrement.');
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
