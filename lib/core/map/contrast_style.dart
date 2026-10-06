import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../settings.dart';

/// Carte sombre plus lisible : les rues ressortent sur le fond (gris clairs
/// selon leur importance, plus larges, liseré sombre), les noms de rue sont
/// plus lumineux. Le tracé orange de la balade reste au-dessus et garde la
/// vedette. Le style d'origine (OpenFreeMap) est téléchargé, transformé, puis
/// gardé en cache pour marcher hors-ligne.
class ContrastStyle {
  ContrastStyle._();

  /// À changer quand la transformation change (le cache est alors refait).
  static const version = 1;

  /// Âge maximal du style en cache avant d'en retélécharger l'original.
  static const maxAge = Duration(days: 7);

  /// Styles sombres concernés.
  static bool appliesTo(String styleUrl) => styleUrl == MapStyle.dark.url || styleUrl == MapStyle.fiord.url;

  /// Couleur des rues selon leur classe (schéma OpenMapTiles).
  static const roadColor = [
    'match',
    ['get', 'class'],
    ['motorway'],
    '#C3CAD5',
    ['trunk', 'primary'],
    '#AEB6C3',
    ['secondary', 'tertiary'],
    '#959EAD',
    ['minor', 'service', 'busway', 'raceway'],
    '#7A8392',
    '#606978',
  ];

  static const casingColor = '#05070A';
  static const labelColor = '#E6EBF2';
  static const labelHalo = '#0B0D10';

  /// Élargissement des rues.
  static const widthFactor = 1.5;

  /// Couches de transport à ne pas toucher (rail, bacs, remontées…).
  static final _skip = RegExp(r'rail|transit|ferry|aerialway|pier|cablecar');

  /// Transforme le JSON du style [source] (téléchargé depuis [styleUrl]).
  static String transform(String source, {required String styleUrl}) {
    final style = jsonDecode(source) as Map<String, dynamic>;
    _absolutize(style, Uri.parse(styleUrl));
    for (final layer in (style['layers'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final id = '${layer['id']}';
      final sourceLayer = layer['source-layer'];
      if (_skip.hasMatch(id)) continue;
      if (sourceLayer == 'transportation' && layer['type'] == 'line') {
        final paint = (layer['paint'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
        final casing = id.contains('casing') || id.contains('outline');
        paint['line-color'] = casing ? casingColor : roadColor;
        if (paint.containsKey('line-width')) paint['line-width'] = scaleWidth(paint['line-width'], widthFactor);
        if (!casing) paint['line-opacity'] = 1;
        layer['paint'] = paint;
      } else if (sourceLayer == 'transportation_name' && layer['type'] == 'symbol') {
        final paint = (layer['paint'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
        paint['text-color'] = labelColor;
        paint['text-halo-color'] = labelHalo;
        paint['text-halo-width'] = 1.6;
        layer['paint'] = paint;
      }
    }
    return jsonEncode(style);
  }

  /// Multiplie une largeur MapLibre par [k] : nombre, ancienne fonction
  /// `{stops: …}`, ou expression (`interpolate` / `step` sur le zoom, dont
  /// seules les valeurs de sortie peuvent être modifiées).
  @visibleForTesting
  static Object? scaleWidth(Object? value, double k) {
    Object? scale(Object? v) => v is num ? _round(v * k) : ['*', k, v];
    if (value is num) return _round(value * k);
    if (value is Map) {
      final stops = value['stops'];
      if (stops is! List) return value;
      return {
        ...value.cast<String, dynamic>(),
        'stops': [
          for (final s in stops)
            if (s is List && s.length == 2 && s[1] is num) [s[0], _round((s[1] as num) * k)] else s,
        ],
      };
    }
    if (value is List && value.isNotEmpty) {
      final op = value.first;
      if (op == 'interpolate' && value.length >= 5) {
        // ['interpolate', type, input, z1, v1, z2, v2, …]
        return [for (var i = 0; i < value.length; i++) i >= 4 && i.isEven ? scale(value[i]) : value[i]];
      }
      if (op == 'step' && value.length >= 3) {
        // ['step', input, v0, z1, v1, …]
        return [for (var i = 0; i < value.length; i++) i >= 2 && i.isEven ? scale(value[i]) : value[i]];
      }
      return ['*', k, value];
    }
    return value;
  }

  static num _round(num v) => (v * 100).round() / 100;

  /// Le style est chargé depuis un fichier : les adresses relatives (sprite,
  /// polices, sources) doivent devenir absolues.
  static void _absolutize(Map<String, dynamic> style, Uri base) {
    // Uri.resolve encode les accolades des gabarits ({z}, {fontstack}…) :
    // on les remet, MapLibre en a besoin.
    String abs(String u) => u.startsWith(RegExp(r'[a-z]+://'))
        ? u
        : base.resolve(u).toString().replaceAll('%7B', '{').replaceAll('%7D', '}');
    final sprite = style['sprite'];
    if (sprite is String) {
      style['sprite'] = abs(sprite);
    } else if (sprite is List) {
      for (final s in sprite) {
        if (s is Map && s['url'] is String) s['url'] = abs(s['url'] as String);
      }
    }
    if (style['glyphs'] is String) style['glyphs'] = abs(style['glyphs'] as String);
    final sources = style['sources'];
    if (sources is Map) {
      for (final src in sources.values) {
        if (src is! Map) continue;
        if (src['url'] is String) src['url'] = abs(src['url'] as String);
        if (src['tiles'] is List) src['tiles'] = [for (final t in src['tiles'] as List) t is String ? abs(t) : t];
      }
    }
  }

  /// Chemin du style transformé. S'il est déjà en cache, il sert tout de
  /// suite (et il est rafraîchi en arrière-plan après [maxAge]) ; sinon
  /// l'original est téléchargé et transformé. En cas d'échec (hors-ligne la
  /// première fois…), l'adresse d'origine.
  static Future<String> prepare(
    String styleUrl, {
    http.Client? client,
    Future<Directory> Function()? directory,
    DateTime? now,
  }) async {
    if (!appliesTo(styleUrl)) return styleUrl;
    try {
      final dir = await (directory ?? _defaultDirectory)();
      final name = styleUrl.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      final file = File('${dir.path}/contrast-v$version-$name.json');
      if (await file.exists()) {
        if ((now ?? DateTime.now()).difference(await file.lastModified()) >= maxAge) {
          unawaited(_download(styleUrl, file, client));
        }
        return file.path;
      }
      if (await _download(styleUrl, file, client)) return file.path;
    } catch (e) {
      debugPrint('Carte contrastée indisponible ($styleUrl) : $e');
    }
    return styleUrl;
  }

  /// Télécharge et transforme le style dans [file]. Faux en cas d'échec.
  static Future<bool> _download(String styleUrl, File file, http.Client? client) async {
    final c = client ?? http.Client();
    try {
      final r = await c
          .get(Uri.parse(styleUrl), headers: {'User-Agent': AppConfig.userAgent})
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return false;
      final out = transform(utf8.decode(r.bodyBytes), styleUrl: styleUrl);
      await file.parent.create(recursive: true);
      // Écriture atomique : la carte ne lit jamais un fichier à moitié écrit.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(out);
      await tmp.rename(file.path);
      return true;
    } catch (e) {
      debugPrint('Téléchargement du style $styleUrl : $e');
      return false;
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/map-styles');
}

/// Style à donner à la carte pour l'adresse [styleUrl] : le fichier du style
/// contrasté si la carte est sombre et l'option active, sinon l'adresse.
final mapStyleSourceProvider = FutureProvider.family<String, String>((ref, styleUrl) async {
  final contrast = ref.watch(settingsProvider.select((s) => s.mapHighContrast));
  if (!contrast || !ContrastStyle.appliesTo(styleUrl)) return styleUrl;
  return ContrastStyle.prepare(styleUrl);
});
