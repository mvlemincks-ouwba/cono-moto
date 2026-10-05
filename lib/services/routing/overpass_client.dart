import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/geo.dart';
import 'http_support.dart';
import 'photon_pois.dart';

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
///
/// Le serveur public principal est très sollicité (délais dépassés, 429 pour
/// les adresses IP partagées des réseaux mobiles) : on essaie plusieurs
/// serveurs miroirs, puis en dernier recours la recherche de lieux Photon.
class OverpassClient {
  OverpassClient({
    http.Client? client,
    List<String>? endpoints,
    String? endpoint,
    RateLimiter? limiter,
    this.timeout = const Duration(seconds: 25),
    PhotonPoiClient? fallback,
    bool usePhotonFallback = true,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _limiter = limiter ?? RateLimiter.overpass,
       endpoints = endpoints ?? (endpoint != null ? [endpoint] : Endpoints.overpassMirrors),
       _fallback = usePhotonFallback ? (fallback ?? PhotonPoiClient(client: client)) : null;

  final http.Client _client;
  final bool _ownsClient;
  final RateLimiter _limiter;

  /// Serveurs essayés dans l'ordre.
  final List<String> endpoints;
  final Duration timeout;
  final PhotonPoiClient? _fallback;

  static const service = 'le serveur OpenStreetMap (Overpass)';

  /// Forêts nommées à moins de [radiusM] d'un des points de [centers].
  Future<List<RoutePoi>> forestsAround(List<GeoPoint> centers, double radiusM) async {
    if (centers.isEmpty) return const [];
    final bounds = GeoBounds.fromPoints(centers)!.expand(radiusM);
    List<RoutePoi> pois;
    try {
      pois = parseForests(await _run(forestQuery(centers, radiusM)));
    } on RoutingException catch (e) {
      final fb = _fallback;
      if (fb == null || !_canFallBack(e)) rethrow;
      pois = await _viaFallback(() => fb.forests(bounds), e);
    }
    return [
      for (final p in pois)
        if (centers.any((c) => Geo.distance(c, p.point) <= radiusM)) p,
    ];
  }

  /// Cols (mountain_pass=yes) situés sur une route carrossable dans [bounds].
  Future<List<RoutePoi>> mountainPasses(GeoBounds bounds) async {
    try {
      return parsePasses(await _run(passQuery(bounds)));
    } on RoutingException catch (e) {
      final fb = _fallback;
      if (fb == null || !_canFallBack(e)) rethrow;
      return _viaFallback(() => fb.passes(bounds), e);
    }
  }

  /// Le repli n'a de sens que si Overpass est en cause (pas sans réseau).
  static bool _canFallBack(RoutingException e) =>
      e.kind != RoutingErrorKind.offline && e.kind != RoutingErrorKind.cancelled;

  Future<List<RoutePoi>> _viaFallback(Future<List<RoutePoi>> Function() run, RoutingException overpassError) async {
    try {
      return await run();
    } on RoutingException {
      // On remonte l'erreur Overpass d'origine, plus parlante.
      throw overpassError;
    }
  }

  /// Exécute la requête sur chaque serveur jusqu'à obtenir une réponse.
  Future<dynamic> _run(String query) async {
    RoutingException? last;
    for (final endpoint in endpoints) {
      try {
        return await _runOn(endpoint, query);
      } on RoutingException catch (e) {
        // Sans réseau, inutile d'essayer les autres serveurs.
        if (e.kind == RoutingErrorKind.offline || e.kind == RoutingErrorKind.invalidRequest) rethrow;
        last = e;
      }
    }
    throw last ?? const RoutingException(RoutingErrorKind.server, 'Aucun serveur OpenStreetMap disponible.');
  }

  Future<dynamic> _runOn(String endpoint, String query) async {
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

  /// Forêts et bois nommés dans le rectangle englobant les cercles demandés.
  /// Une seule zone (plutôt qu'un filtre « around » par point, très coûteux en
  /// région boisée comme les Landes), surfaces uniquement, nombre plafonné.
  static String forestQuery(List<GeoPoint> centers, double radiusM, {int limit = 200}) {
    final b = GeoBounds.fromPoints(centers)!.expand(radiusM);
    final bbox = '${_f(b.south)},${_f(b.west)},${_f(b.north)},${_f(b.east)}';
    return '[out:json][timeout:20][bbox:$bbox];\n'
        '(\n'
        '  way["landuse"="forest"]["name"];\n'
        '  relation["landuse"="forest"]["name"];\n'
        '  way["natural"="wood"]["name"];\n'
        '  relation["natural"="wood"]["name"];\n'
        ');\n'
        'out tags center $limit;';
  }

  static String passQuery(GeoBounds b) {
    final bbox = '${_f(b.south)},${_f(b.west)},${_f(b.north)},${_f(b.east)}';
    return '[out:json][timeout:20];\n'
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
    _fallback?.close();
    if (_ownsClient) _client.close();
  }
}
