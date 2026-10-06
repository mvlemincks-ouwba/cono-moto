import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'discord_feedback.dart';

/// Rapport de plantage, posté sur le Discord de la bande comme un bug signalé
/// depuis l'appli (champ « Type » = Bug) : le pont GitHub en fait un ticket que
/// la routine du matin traite. Rien de personnel : type d'erreur, message
/// nettoyé, pile d'appels, versions de l'appli et du téléphone, écran affiché.
class CrashReport {
  const CrashReport({
    required this.type,
    required this.message,
    required this.frames,
    required this.signature,
    required this.appLabel,
    required this.deviceLabel,
    required this.at,
    this.context,
    this.screen,
  });

  /// Rapport d'une erreur non rattrapée.
  factory CrashReport.capture(
    Object error,
    StackTrace? stack, {
    required FeedbackContext app,
    required DateTime at,
    String? context,
    String? screen,
  }) {
    final type = errorTypeName(error);
    final all = parseFrames(stack);
    return CrashReport(
      type: type,
      message: describeError(error),
      frames: usefulFrames(all),
      signature: crashSignature(type, all),
      appLabel: app.appLabel,
      deviceLabel: app.deviceLabel,
      at: at,
      context: context == null ? null : scrubPersonalData(context, max: 120),
      screen: screen == null ? null : scrubPersonalData(screen, max: 80),
    );
  }

  factory CrashReport.fromJson(Map<String, dynamic> j) => CrashReport(
        type: j['type'] as String,
        message: j['message'] as String,
        frames: [for (final f in j['frames'] as List) f as String],
        signature: j['signature'] as String,
        appLabel: j['app'] as String,
        deviceLabel: j['device'] as String,
        at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
        context: j['context'] as String?,
        screen: j['screen'] as String?,
      );

  /// Type d'erreur (« StateError »).
  final String type;

  /// Message de l'erreur, nettoyé (voir [scrubPersonalData]).
  final String message;

  /// Lignes utiles de la pile d'appels (voir [usefulFrames]).
  final List<String> frames;

  /// Empreinte de l'erreur (voir [crashSignature]).
  final String signature;
  final String appLabel;
  final String deviceLabel;
  final DateTime at;

  /// Ce que faisait Flutter (« building RideScreen (widgets library) »).
  final String? context;

  /// Écran affiché au moment du plantage.
  final String? screen;

  /// Identifiant dans la file d'attente.
  String get id => '${signature}_${at.millisecondsSinceEpoch}';

  /// « 💥 Plantage : StateError dans RideController.stop ».
  String get heading {
    final frame = frames.firstWhere((f) => f.contains(appPackage) && f.contains(' ('), orElse: () => '');
    return '💥 Plantage : $type${frame.isEmpty ? '' : ' dans ${frame.substring(0, frame.indexOf(' ('))}'}';
  }

  /// Texte du message Discord (et donc du ticket GitHub).
  String get details {
    final utc = at.toUtc().toIso8601String();
    final sb = StringBuffer()
      ..writeln('```')
      ..writeln(_unfenced(message))
      ..writeln('```');
    if (screen != null) sb.writeln('**Écran :** $screen');
    if (context != null) sb.writeln('**Contexte :** $context');
    sb.writeln('**Signature :** `$signature` · le ${utc.substring(0, 10)} à ${utc.substring(11, 16)} UTC');
    if (frames.isNotEmpty) {
      sb
        ..writeln()
        ..writeln('**Pile d\'appels**')
        ..writeln('```')
        ..writeln(_unfenced(frames.join('\n')))
        ..write('```');
    }
    return sb.toString().trim();
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'message': message,
        'frames': frames,
        'signature': signature,
        'app': appLabel,
        'device': deviceLabel,
        'at': at.millisecondsSinceEpoch,
        if (context != null) 'context': context,
        if (screen != null) 'screen': screen,
      };
}

/// Préfixe des lignes de la pile qui viennent du code de l'appli.
const appPackage = 'package:cono_moto/';

/// Message Discord du rapport : même forme qu'un bug signalé depuis l'appli
/// (champ « Type » = 🐞 Bug, versions de l'appli et du téléphone), sans pseudo.
Map<String, dynamic> buildCrashPayload(CrashReport r) => buildDiscordPayload(
      FeedbackDraft(kind: FeedbackKind.bug, title: r.type, description: r.details),
      FeedbackContext(appLabel: r.appLabel, deviceLabel: r.deviceLabel),
      now: r.at,
      heading: r.heading,
      footer: 'Rapport de plantage envoyé automatiquement par l\'appli Cono Moto',
    );

/// Bruit connu, pas un plantage : coupures réseau (zone blanche, tunnel, wifi
/// d'hôtel…). Les appels réseau de l'appli les gèrent déjà (« Pas de réseau »)
/// et une requête qui en laisse échapper une n'apprendrait rien de plus : elle
/// viderait juste le quota de rapports du jour à chaque balade hors réseau.
bool isBenignCrash(Object error) =>
    error is SocketException ||
    error is HandshakeException ||
    error is HttpException ||
    error is http.ClientException ||
    error is TimeoutException;

/// Nom du type d'erreur, sans le « _ » des classes internes de Dart
/// (`_TypeError` → `TypeError`).
String errorTypeName(Object error) {
  final name = error.runtimeType.toString();
  return name.startsWith('_') ? name.substring(1) : name;
}

/// Message de l'erreur, nettoyé et raccourci. Une FormatException recopie
/// d'ordinaire le texte qu'elle n'a pas pu lire (réponse JSON avec des noms ou
/// des positions…) : on n'en garde que le message.
String describeError(Object error) {
  String text;
  try {
    text = error is FormatException ? 'FormatException: ${error.message}' : error.toString();
  } catch (_) {
    text = 'Instance of ${errorTypeName(error)}';
  }
  return scrubPersonalData(text, max: 600);
}

final _url = RegExp(r'\b[a-z][a-z0-9+.-]*://([^/\s?#:)\]"]+)[^\s)\]"]*', caseSensitive: false);
final _email = RegExp(r'[\w.+-]+@[\w-]+(?:\.[\w-]+)+');
final _coordinate = RegExp(r'-?\d{1,3}\.\d{4,}');
final _longNumber = RegExp(r'\+?\d(?:[ .-]?\d){7,}');
final _id = RegExp(r'(?<![\w-])(?=[\w-]*\d)(?=[\w-]*[A-Za-z])[\w-]{16,}(?![\w-])');
final _code = RegExp(r'\b(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{6,8}\b');
final _quoted = RegExp(r'"[^"\n]*"|«[^»\n]*»');

/// Retire d'un texte ce qui pourrait être personnel : adresses web (avec leurs
/// paramètres : positions, jetons, URL du webhook…), e-mails, coordonnées GPS,
/// numéros (téléphone…), identifiants (Firebase, balades, codes de groupe) et
/// textes entre guillemets (valeurs saisies : noms…). Coupe à [max] caractères.
String scrubPersonalData(String text, {int max = 600}) {
  final s = text
      .replaceAllMapped(_url, (m) => '‹lien ${m[1]}›')
      .replaceAll(_email, '‹e-mail›')
      .replaceAll(_coordinate, '‹nombre›')
      .replaceAll(_longNumber, '‹nombre›')
      .replaceAll(_id, '‹id›')
      .replaceAll(_code, '‹code›')
      .replaceAll(_quoted, '"…"')
      .trim();
  return s.length <= max ? s : '${s.substring(0, max - 1)}…';
}

/// Lignes de la pile d'appels, sans numéro ni « `<asynchronous suspension>` »,
/// ni chemin de fichier local (versions de développement).
List<String> parseFrames(StackTrace? stack) {
  if (stack == null) return const [];
  return [
    for (final raw in stack.toString().split('\n'))
      if (raw.trim().isNotEmpty && !raw.contains('<asynchronous suspension>'))
        raw
            .trim()
            .replaceFirst(RegExp(r'^#\d+\s+'), '')
            .replaceAll(RegExp(r'file://[^\s)]*/'), '')
            .replaceAll(RegExp(r'\s+'), ' '),
  ];
}

/// Lignes utiles de la pile : la première (là où l'erreur est levée, souvent
/// dans Dart ou Flutter) puis celles de l'appli, les autres résumées par « … ».
/// Sans ligne de l'appli : le haut de la pile. Au plus [maxChars] caractères,
/// pour que le message Discord reste loin de ses limites.
List<String> usefulFrames(List<String> frames, {int maxApp = 12, int maxChars = 2400}) {
  final app = [
    for (var i = 1; i < frames.length; i++)
      if (frames[i].contains(appPackage)) i,
  ];
  final picked = app.isEmpty
      ? [for (var i = 0; i < frames.length && i < 10; i++) i]
      : [if (frames.isNotEmpty) 0, ...app.take(maxApp)];
  final out = <String>[];
  var size = 0;
  var previous = -1;
  for (final i in picked) {
    final line = frames[i].length <= 200 ? frames[i] : '${frames[i].substring(0, 199)}…';
    final gap = previous >= 0 && i > previous + 1;
    size += line.length + (gap ? 2 : 1);
    if (size > maxChars) break;
    if (gap) out.add('…');
    out.add(line);
    previous = i;
  }
  if (previous < frames.length - 1) out.add('…');
  return out;
}

/// Empreinte d'un plantage : type d'erreur + 3 premières lignes de l'appli
/// dans la pile (le haut de la pile s'il n'y en a pas), sans numéros de ligne
/// pour rester la même d'une version à l'autre. Hachée (FNV-1a, 32 bits).
String crashSignature(String type, List<String> frames) {
  final app = frames.where((f) => f.contains(appPackage)).toList();
  final key = [
    type,
    for (final f in (app.isEmpty ? frames : app).take(3)) f.replaceAll(RegExp(r'[:\s]\d+(?::\d+)?(?=[)\s]|$)'), ''),
  ].join('|');
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(key)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// Empêche un texte de fermer le bloc de code Markdown qui l'entoure.
String _unfenced(String s) => s.replaceAll('```', "'''");
