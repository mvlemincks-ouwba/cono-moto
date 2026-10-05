import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/geo.dart';
import 'http_support.dart';

/// Lieu trouvé par la recherche d'adresses.
class Place {
  const Place({required this.name, required this.point, this.detail, this.city, this.type});

  final String name;
  final GeoPoint point;

  /// Complément (« 78120 Rambouillet, Île-de-France »).
  final String? detail;

  /// Commune (pour nommer une balade).
  final String? city;

  /// Type Photon : house, street, city, district, locality…
  final String? type;

  String get label => detail == null || detail!.isEmpty ? name : '$name, $detail';

  @override
  String toString() => 'Place($label)';
}

/// Recherche d'adresses Photon (Komoot), sans clé.
class Geocoder {
  Geocoder({http.Client? client, this.endpoint = Endpoints.geocoder, this.timeout = const Duration(seconds: 12)})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String endpoint;
  final Duration timeout;

  static const service = "la recherche d'adresses";

  static Uri searchUri(String endpoint, String query, {GeoPoint? near, int limit = 6}) {
    final base = Uri.parse(endpoint);
    return base.replace(
      queryParameters: {
        'q': query,
        'lang': 'fr',
        'limit': '$limit',
        if (near != null) 'lat': near.lat.toStringAsFixed(4),
        if (near != null) 'lon': near.lng.toStringAsFixed(4),
      },
    );
  }

  static Uri reverseUri(String endpoint, GeoPoint p) {
    final base = Uri.parse(endpoint);
    return base
        .resolve('../reverse')
        .replace(queryParameters: {'lat': p.lat.toStringAsFixed(5), 'lon': p.lng.toStringAsFixed(5), 'lang': 'fr'});
  }

  /// Adresses correspondant à [query] (biaisées autour de [near]).
  Future<List<Place>> search(String query, {GeoPoint? near, int limit = 6}) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    final r = await guardedSend(
      () => _client.get(
        searchUri(endpoint, q, near: near, limit: limit),
        headers: serviceHeaders(),
      ),
      service: service,
      timeout: timeout,
    );
    checkStatus(r, service: service);
    return parse(decodeJsonBody(r, service: service));
  }

  /// Lieu le plus proche de [p] (null si rien).
  Future<Place?> reverse(GeoPoint p) async {
    final r = await guardedSend(
      () => _client.get(reverseUri(endpoint, p), headers: serviceHeaders()),
      service: service,
      timeout: timeout,
    );
    checkStatus(r, service: service);
    final places = parse(decodeJsonBody(r, service: service));
    return places.isEmpty ? null : places.first;
  }

  /// Analyse une FeatureCollection GeoJSON Photon.
  static List<Place> parse(dynamic json) {
    if (json is! Map) return const [];
    final features = json['features'];
    if (features is! List) return const [];
    final out = <Place>[];
    for (final f in features.whereType<Map>()) {
      final geom = f['geometry'];
      final props = f['properties'];
      if (geom is! Map || props is! Map) continue;
      final coords = geom['coordinates'];
      if (coords is! List || coords.length < 2 || coords[0] is! num || coords[1] is! num) continue;
      final point = GeoPoint((coords[1] as num).toDouble(), (coords[0] as num).toDouble());
      String? s(String k) {
        final v = props[k];
        return v is String && v.trim().isNotEmpty ? v.trim() : null;
      }

      final street = s('street');
      final number = s('housenumber');
      final city = s('city') ?? s('town') ?? s('village') ?? (s('type') == 'city' ? s('name') : null);
      String? name = s('name');
      if (number != null && street != null) {
        name = '$number $street';
      } else {
        name ??= street ?? city;
      }
      if (name == null) continue;
      final postcode = s('postcode');
      final parts = <String>[
        if (city != null && city != name) postcode != null ? '$postcode $city' : city,
        if (city == null && postcode != null) postcode,
        if (s('county') != null && s('county') != city && s('county') != name) s('county')!,
        if (s('countrycode') != null && s('countrycode') != 'FR' && s('country') != null) s('country')!,
      ];
      out.add(
        Place(
          name: name,
          point: point,
          detail: parts.isEmpty ? null : parts.join(', '),
          city: city ?? (s('type') == 'city' ? name : null),
          type: s('type'),
        ),
      );
    }
    return out;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
