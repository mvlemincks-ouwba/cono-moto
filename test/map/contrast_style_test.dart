import 'dart:convert';
import 'dart:io';

import 'package:cono_moto/core/map/contrast_style.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Extrait d'un style sombre façon OpenMapTiles (Dark Matter).
final _style = {
  'version': 8,
  'sprite': 'sprites/dark',
  'glyphs': 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
  'sources': {
    'openmaptiles': {'type': 'vector', 'url': 'https://tiles.openfreemap.org/planet'},
    'relatif': {
      'type': 'vector',
      'tiles': ['tiles/{z}/{x}/{y}.pbf'],
    },
  },
  'layers': [
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': '#0e0e0e'},
    },
    {
      'id': 'highway_minor',
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': 'transportation',
      'paint': {
        'line-color': '#181818',
        'line-width': {
          'base': 1.55,
          'stops': [
            [4, 0.25],
            [20, 30],
          ],
        },
        'line-opacity': 0.9,
      },
    },
    {
      'id': 'highway_major_casing',
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': 'transportation',
      'paint': {'line-color': '#3c3c3c', 'line-width': 3},
    },
    {
      'id': 'highway_motorway_inner',
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': 'transportation',
      'paint': {
        'line-color': '#282828',
        'line-width': [
          'interpolate',
          ['exponential', 1.4],
          ['zoom'],
          6,
          0.5,
          18,
          20,
        ],
      },
    },
    {
      'id': 'railway',
      'type': 'line',
      'source': 'openmaptiles',
      'source-layer': 'transportation',
      'paint': {'line-color': '#232323', 'line-width': 1},
    },
    {
      'id': 'highway_name_other',
      'type': 'symbol',
      'source': 'openmaptiles',
      'source-layer': 'transportation_name',
      'paint': {'text-color': '#565656'},
    },
    {
      'id': 'building',
      'type': 'fill',
      'source': 'openmaptiles',
      'source-layer': 'building',
      'paint': {'fill-color': '#0a0a0a'},
    },
  ],
};

const _url = 'https://tiles.openfreemap.org/styles/dark';

Map<String, dynamic> _layer(Map<String, dynamic> style, String id) =>
    (style['layers'] as List).cast<Map<String, dynamic>>().firstWhere((l) => l['id'] == id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('transformation', () {
    final out = jsonDecode(ContrastStyle.transform(jsonEncode(_style), styleUrl: _url)) as Map<String, dynamic>;

    test('rues claires selon leur classe, plus larges, opaques', () {
      final minor = _layer(out, 'highway_minor')['paint'] as Map;
      expect(minor['line-color'], ContrastStyle.roadColor);
      expect(minor['line-opacity'], 1);
      expect(minor['line-width'], {
        'base': 1.55,
        'stops': [
          [4, 0.38],
          [20, 45],
        ],
      });
      final motorway = _layer(out, 'highway_motorway_inner')['paint'] as Map;
      expect(motorway['line-width'], [
        'interpolate',
        ['exponential', 1.4],
        ['zoom'],
        6,
        0.75,
        18,
        30,
      ]);
    });

    test('liseré sombre pour les bords de route', () {
      final casing = _layer(out, 'highway_major_casing')['paint'] as Map;
      expect(casing['line-color'], ContrastStyle.casingColor);
      expect(casing['line-width'], 4.5);
      expect(casing.containsKey('line-opacity'), isFalse);
    });

    test('noms de rue lisibles, le reste intact', () {
      final names = _layer(out, 'highway_name_other')['paint'] as Map;
      expect(names['text-color'], ContrastStyle.labelColor);
      expect(names['text-halo-width'], 1.6);
      expect(_layer(out, 'railway')['paint'], {'line-color': '#232323', 'line-width': 1});
      expect(_layer(out, 'building')['paint'], {'fill-color': '#0a0a0a'});
      expect(_layer(out, 'background')['paint'], {'background-color': '#0e0e0e'});
    });

    test('adresses relatives rendues absolues (style chargé depuis un fichier)', () {
      expect(out['sprite'], 'https://tiles.openfreemap.org/styles/sprites/dark');
      expect(out['glyphs'], _style['glyphs']);
      final sources = out['sources'] as Map;
      expect(sources['openmaptiles']['url'], 'https://tiles.openfreemap.org/planet');
      expect(sources['relatif']['tiles'], ['https://tiles.openfreemap.org/styles/tiles/{z}/{x}/{y}.pbf']);
    });

    test('largeurs : nombre, step, expression quelconque', () {
      expect(ContrastStyle.scaleWidth(2, 1.5), 3);
      expect(
        ContrastStyle.scaleWidth([
          'step',
          ['zoom'],
          1,
          12,
          2,
        ], 2),
        [
          'step',
          ['zoom'],
          2,
          12,
          4,
        ],
      );
      expect(ContrastStyle.scaleWidth(['get', 'w'], 2), [
        '*',
        2.0,
        ['get', 'w'],
      ]);
      expect(ContrastStyle.scaleWidth(null, 2), isNull);
    });
  });

  group('préparation et cache', () {
    late Directory dir;
    late int requests;
    late int status;
    late http.Client client;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('styles');
      requests = 0;
      status = 200;
      client = MockClient((r) async {
        requests++;
        expect(r.url.toString(), _url);
        return http.Response.bytes(utf8.encode(jsonEncode(_style)), status);
      });
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<String> prepare({DateTime? now}) =>
        ContrastStyle.prepare(_url, client: client, directory: () async => dir, now: now);

    test('téléchargé une fois, puis servi depuis le cache', () async {
      final path = await prepare();
      expect(path, startsWith(dir.path));
      final saved = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      expect((_layer(saved, 'highway_minor')['paint'] as Map)['line-color'], ContrastStyle.roadColor);

      expect(await prepare(), path);
      expect(requests, 1);
    });

    test('cache ancien : servi tout de suite, rafraîchi en arrière-plan', () async {
      final path = await prepare();
      expect(await prepare(now: DateTime.now().add(const Duration(days: 8))), path);
      await pumpEventQueue();
      expect(requests, 2);
    });

    test('hors-ligne la première fois : style d\'origine', () async {
      status = 503;
      expect(await prepare(), _url);
      client = MockClient((_) async => throw const SocketException('pas de réseau'));
      expect(await prepare(), _url);
      expect(dir.listSync(), isEmpty);
    });

    test('styles clairs : jamais touchés', () async {
      expect(
        await ContrastStyle.prepare(MapStyle.liberty.url, client: client, directory: () async => dir),
        MapStyle.liberty.url,
      );
      expect(requests, 0);
    });
  });

  test('option désactivée : le style d\'origine', () async {
    SharedPreferences.setMockInitialValues({'settings.mapHighContrast': false});
    final c = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance())],
    );
    addTearDown(c.dispose);
    expect(c.read(settingsProvider).mapHighContrast, isFalse);
    expect(await c.read(mapStyleSourceProvider(_url).future), _url);
  });
}
