import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/geo.dart';
import 'http_support.dart';

/// Nature d'un point d'intérêt de balade.
enum PoiKind { forest, pass }

/// Forêt nommée ou col routier trouvé dans OpenStreetMap.
class RoutePoi {
  const RoutePoi({
    required this.id,
    required this.name,
    required this.point,
    required this.kind,
    this.elevationM,
    this.pieces = 1,
  });

  final String id;
  final String name;
  final GeoPoint point;
  final PoiKind kind;

  /// Altitude (cols), si renseignée.
  final int? elevationM;

  /// Nombre d'objets OSM regroupés sous ce nom (indice de taille d'une forêt).
  final int pieces;

  /// Une vraie forêt (« Forêt de… ») plutôt qu'un petit bois.
  bool get isMajorForest {
    final n = name.toLowerCase();
    return n.startsWith('forêt') || n.contains('forêt domaniale') || n.startsWith('foret');
  }

  /// Libellé court (« Rambouillet » pour « Forêt domaniale de Rambouillet »).
  String get shortName {
    final m = RegExp(
      r"^(?:forêt|foret|bois|col)(?:\s+domaniale)?\s+(?:de\s+la\s+|de\s+l'|du\s+|des\s+|de\s+|d')",
      caseSensitive: false,
    ).firstMatch(name);
    if (m == null) return name;
    final rest = name.substring(m.end).trim();
    return rest.isEmpty ? name : rest;
  }

  @override
  String toString() => 'RoutePoi($name, $point)';
}

/// Client Overpass (OpenStreetMap) : forêts nommées et cols routiers.
class OverpassClient {
  OverpassClient({
    http.Client? client,
    this.endpoint = Endpoints.overpass,
    RateLimiter? limiter,
    this.timeout = const Duration(seconds: 40),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _limiter = limiter ?? RateLimiter.overpass;

  final http.Client _client;
  final bool _ownsClient;
  final RateLimiter _limiter;
  final String endpoint;
  final Duration timeout;

  static const service = 'le serveur OpenStreetMap (Overpass)';

  /// Forêts nommées autour de chaque point de [centers] (rayon [radiusM]).
  Future<List<RoutePoi>> forestsAround(List<GeoPoint> centers, double radiusM) async {
    if (centers.isEmpty) return const [];
    final json = await _run(forestQuery(centers, radiusM));
    return parseForests(json);
  }

  /// Cols (mountain_pass=yes) situés sur une route carrossable dans [bounds].
  Future<List<RoutePoi>> mountainPasses(GeoBounds bounds) async {
    final json = await _run(passQuery(bounds));
    return parsePasses(json);
  }

  Future<dynamic> _run(String query) async {
    await _limiter.acquire();
    final response = await guardedSend(
      () => _client.post(Uri.parse(endpoint), headers: serviceHeaders(formBody: true), body: {'data': query}),
      service: service,
      timeout: timeout,
    );
    checkStatus(response, service: service);
    final json = decodeJsonBody(response, service: service);
    if (json is! Map) {
      throw const RoutingException(RoutingErrorKind.badResponse, 'Réponse inattendue du serveur Overpass.');
    }
    final remark = json['remark'];
    final elements = json['elements'];
    if (remark is String && remark.contains('error') && (elements is! List || elements.isEmpty)) {
      throw const RoutingException(
        RoutingErrorKind.server,
        'Le serveur OpenStreetMap (Overpass) est débordé pour le moment.',
      );
    }
    return json;
  }

  static String _f(double v) => v.toStringAsFixed(5);

  static String forestQuery(List<GeoPoint> centers, double radiusM) {
    final r = radiusM.round();
    final sb = StringBuffer('[out:json][timeout:30];\n(\n');
    for (final c in centers) {
      final at = '(around:$r,${_f(c.lat)},${_f(c.lng)})';
      sb.writeln('  nwr["landuse"="forest"]["name"]$at;');
      sb.writeln('  nwr["natural"="wood"]["name"]$at;');
    }
    sb.writeln(');');
    sb.write('out center tags;');
    return sb.toString();
  }

  static String passQuery(GeoBounds b) {
    final bbox = '${_f(b.south)},${_f(b.west)},${_f(b.north)},${_f(b.east)}';
    return '[out:json][timeout:30];\n'
        'node["mountain_pass"="yes"]["name"]($bbox)->.passes;\n'
        'way(bn.passes)["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential)(_link)?\$"]->.roads;\n'
        'node.passes(w.roads);\n'
        'out body;';
  }

  static GeoPoint? _position(Map e) {
    final center = e['center'];
    if (center is Map && center['lat'] is num && center['lon'] is num) {
      return GeoPoint((center['lat'] as num).toDouble(), (center['lon'] as num).toDouble());
    }
    if (e['lat'] is num && e['lon'] is num) {
      return GeoPoint((e['lat'] as num).toDouble(), (e['lon'] as num).toDouble());
    }
    return null;
  }

  static List<Map> _elements(dynamic json) {
    if (json is! Map) return const [];
    final list = json['elements'];
    if (list is! List) return const [];
    return list.whereType<Map>().toList();
  }

  /// Forêts regroupées par nom (une forêt domaniale est souvent découpée en
  /// plusieurs objets OSM) ; position = barycentre des morceaux.
  static List<RoutePoi> parseForests(dynamic json) {
    final groups = <String, List<(GeoPoint, String)>>{};
    for (final e in _elements(json)) {
      final tags = e['tags'];
      if (tags is! Map) continue;
      final name = (tags['name'] as String?)?.trim();
      if (name == null || name.isEmpty) continue;
      final p = _position(e);
      if (p == null) continue;
      groups.putIfAbsent(name, () => []).add((p, '${e['type']}/${e['id']}'));
    }
    final out = <RoutePoi>[];
    groups.forEach((name, pieces) {
      // Des homonymes très éloignés (« Bois Communal ») : on garde le groupe
      // principal autour du premier morceau.
      final first = pieces.first.$1;
      final near = pieces.where((p) => Geo.distance(p.$1, first) < 15000).toList();
      final lat = near.map((p) => p.$1.lat).reduce((a, b) => a + b) / near.length;
      final lng = near.map((p) => p.$1.lng).reduce((a, b) => a + b) / near.length;
      out.add(
        RoutePoi(id: near.first.$2, name: name, point: GeoPoint(lat, lng), kind: PoiKind.forest, pieces: near.length),
      );
    });
    return out;
  }

  static List<RoutePoi> parsePasses(dynamic json) {
    final out = <RoutePoi>[];
    final seen = <String>{};
    for (final e in _elements(json)) {
      final tags = e['tags'];
      if (tags is! Map) continue;
      final name = (tags['name'] as String?)?.trim();
      final p = _position(e);
      if (name == null || name.isEmpty || p == null) continue;
      if (!seen.add('$name@${p.lat.toStringAsFixed(2)},${p.lng.toStringAsFixed(2)}')) continue;
      final ele = double.tryParse('${tags['ele'] ?? ''}'.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.]'), ''));
      out.add(
        RoutePoi(id: '${e['type']}/${e['id']}', name: name, point: p, kind: PoiKind.pass, elevationM: ele?.round()),
      );
    }
    return out;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
