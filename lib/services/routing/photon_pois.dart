import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/geo.dart';
import 'http_support.dart';
import 'overpass_client.dart';

/// Repli quand Overpass ne répond pas : la recherche de lieux Photon (Komoot)
/// connaît aussi les forêts nommées et les cols. Moins complète qu'Overpass
/// (recherche par mot : « forêt », « bois », « col »), mais servie par une
/// infrastructure différente.
class PhotonPoiClient {
  PhotonPoiClient({http.Client? client, this.endpoint = Endpoints.geocoder, this.timeout = const Duration(seconds: 12)})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String endpoint;
  final Duration timeout;

  static const service = 'la recherche de lieux (Photon)';

  /// Forêts et bois nommés dans [bounds].
  Future<List<RoutePoi>> forests(GeoBounds bounds) async {
    final results = <RoutePoi>[];
    for (final q in const ['forêt', 'bois']) {
      results.addAll(await _search(q, bounds, const ['landuse:forest', 'natural:wood'], PoiKind.forest));
    }
    return _dedupe(results);
  }

  /// Cols dans [bounds].
  Future<List<RoutePoi>> passes(GeoBounds bounds) async =>
      _dedupe(await _search('col', bounds, const ['mountain_pass'], PoiKind.pass));

  static Uri searchUri(String endpoint, String query, GeoBounds b, List<String> osmTags, {int limit = 50}) {
    final base = Uri.parse(endpoint);
    final params = <String, dynamic>{
      'q': query,
      'lang': 'fr',
      'limit': '$limit',
      'bbox': [b.west, b.south, b.east, b.north].map((v) => v.toStringAsFixed(4)).join(','),
      'osm_tag': osmTags,
    };
    return base.replace(queryParameters: params);
  }

  Future<List<RoutePoi>> _search(String query, GeoBounds b, List<String> tags, PoiKind kind) async {
    final r = await guardedSend(
      () => _client.get(searchUri(endpoint, query, b, tags), headers: serviceHeaders()),
      service: service,
      timeout: timeout,
    );
    checkStatus(r, service: service);
    return parse(decodeJsonBody(r, service: service), kind, bounds: b);
  }

  /// Analyse une FeatureCollection Photon en points d'intérêt.
  static List<RoutePoi> parse(dynamic json, PoiKind kind, {GeoBounds? bounds}) {
    if (json is! Map || json['features'] is! List) return const [];
    final out = <RoutePoi>[];
    for (final f in (json['features'] as List).whereType<Map>()) {
      final geom = f['geometry'];
      final props = f['properties'];
      if (geom is! Map || props is! Map) continue;
      final c = geom['coordinates'];
      if (c is! List || c.length < 2 || c[0] is! num || c[1] is! num) continue;
      final name = props['name'];
      if (name is! String || name.trim().isEmpty) continue;
      final point = GeoPoint((c[1] as num).toDouble(), (c[0] as num).toDouble());
      // Photon traite la bbox comme une préférence forte, pas un filtre strict.
      if (bounds != null && !bounds.contains(point)) continue;
      final ele = double.tryParse('${props['ele'] ?? ''}'.replaceAll(',', '.'));
      out.add(RoutePoi(
        id: 'photon/${props['osm_type'] ?? '?'}/${props['osm_id'] ?? out.length}',
        name: name.trim(),
        point: point,
        kind: kind,
        elevationM: ele?.round(),
      ));
    }
    return out;
  }

  static List<RoutePoi> _dedupe(List<RoutePoi> pois) {
    final seen = <String>{};
    return [
      for (final p in pois)
        if (seen.add('${p.name.toLowerCase()}@${p.point.lat.toStringAsFixed(2)},${p.point.lng.toStringAsFixed(2)}')) p,
    ];
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
