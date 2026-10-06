import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/geo.dart';
import 'http_support.dart';

/// Lieu trouvé par la recherche d'adresses.
class Place {
  const Place({required this.name, required this.point, this.detail, this.city, this.type, this.postcode});

  final String name;
  final GeoPoint point;

  /// Complément (« 78120 Rambouillet, Île-de-France »).
  final String? detail;

  /// Commune (pour nommer une balade).
  final String? city;

  /// Type Photon : house, street, city, district, locality…
  final String? type;

  /// Code postal, s'il est connu.
  final String? postcode;

  String get label => detail == null || detail!.isEmpty ? name : '$name, $detail';

  @override
  String toString() => 'Place($label)';
}

/// Recherche d'adresses, sans clé : Photon (Komoot, OpenStreetMap) pour les
/// lieux, villes et cols partout en Europe, et, si [banEndpoints] est
/// renseigné, la Base Adresse Nationale pour les adresses françaises avec
/// numéro (souvent absentes d'OpenStreetMap).
class Geocoder {
  Geocoder({
    http.Client? client,
    this.endpoint = Endpoints.geocoder,
    this.banEndpoints = const [],
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String endpoint;

  /// Base Adresse Nationale (essayées dans l'ordre). Vide : Photon seul.
  final List<String> banEndpoints;
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

  static Uri banUri(String endpoint, String query, {GeoPoint? near, int limit = 6}) => Uri.parse(endpoint).replace(
    queryParameters: {
      'q': query,
      'limit': '$limit',
      if (near != null) 'lat': near.lat.toStringAsFixed(4),
      if (near != null) 'lon': near.lng.toStringAsFixed(4),
    },
  );

  /// Adresses correspondant à [query] (biaisées autour de [near]). Photon et
  /// la Base Adresse Nationale sont interrogés en parallèle ; si l'un des deux
  /// échoue, l'autre suffit.
  Future<List<Place>> search(String query, {GeoPoint? near, int limit = 6}) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    final photon = _photonSearch(q, near: near, limit: limit);
    if (banEndpoints.isEmpty) return photon;
    final ban = _banSearch(q, near: near, limit: limit);
    List<Place>? photonPlaces;
    List<Place>? banPlaces;
    RoutingException? photonError;
    try {
      photonPlaces = await photon;
    } on RoutingException catch (e) {
      photonError = e;
    }
    try {
      banPlaces = await ban;
    } catch (_) {
      banPlaces = null;
    }
    if (photonPlaces == null && banPlaces == null) throw photonError!;
    return merge(q, photon: photonPlaces ?? const [], ban: banPlaces ?? const [], limit: limit);
  }

  Future<List<Place>> _photonSearch(String q, {GeoPoint? near, required int limit}) async {
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

  /// Base Adresse Nationale : premier serveur qui répond.
  Future<List<Place>> _banSearch(String q, {GeoPoint? near, required int limit}) async {
    Object? lastError;
    for (final e in banEndpoints) {
      try {
        final r = await guardedSend(
          () => _client.get(
            banUri(e, q, near: near, limit: limit),
            headers: serviceHeaders(),
          ),
          service: service,
          timeout: const Duration(seconds: 6),
        );
        checkStatus(r, service: service);
        return parseBan(decodeJsonBody(r, service: service));
      } catch (err) {
        lastError = err;
      }
    }
    throw lastError ?? const RoutingException(RoutingErrorKind.server, 'Base Adresse Nationale indisponible.');
  }

  /// La recherche ressemble-t-elle à une adresse (numéro, type de voie) ?
  static bool looksLikeAddress(String q) {
    final s = q.toLowerCase();
    return RegExp(r'^\s*\d+\s*(bis|ter|[a-d])?\b').hasMatch(s) ||
        RegExp(
          // Pas de \b : il ignore les lettres accentuées (« allée », « résidence »).
          r"(^|[\s,])(rue|avenue|av|bd|boulevard|chemin|ch|route|rte|allée|allee|impasse|place|pl|quai|cours|"
          r"lotissement|lieu-dit|hameau|voie|sentier|passage|square|résidence|residence)(?=[\s,.]|$)",
        ).hasMatch(s);
  }

  /// Code postal tapé dans la recherche (5 chiffres), s'il y en a un.
  static String? postcodeIn(String q) => RegExp(r'\b\d{5}\b').firstMatch(q)?.group(0);

  /// Fusionne les résultats : adresses officielles d'abord pour une adresse,
  /// lieux OpenStreetMap d'abord sinon ; doublons et résultats d'un autre code
  /// postal que celui tapé écartés.
  static List<Place> merge(String query, {required List<Place> photon, required List<Place> ban, int limit = 6}) {
    final address = looksLikeAddress(query);
    // Hors adresse, la BAN ne garde que ses réponses sûres (communes, lieux-dits).
    final banKept = [
      for (final p in ban)
        if (address || p.type == 'city' || p.type == 'locality') p,
    ];
    final ordered = address ? [...banKept, ...photon] : [...photon, ...banKept];

    final postcode = postcodeIn(query);
    final matchesPostcode = postcode != null && ordered.any((p) => p.postcode == postcode);
    final out = <Place>[];
    for (final p in ordered) {
      if (matchesPostcode && p.postcode != null && p.postcode != postcode) continue;
      final dup = out.any((o) => _sameName(o.name, p.name) && Geo.distance(o.point, p.point) < 250);
      if (!dup) out.add(p);
      if (out.length >= limit) break;
    }
    return out;
  }

  static bool _sameName(String a, String b) => _norm(a) == _norm(b);

  static String _norm(String s) {
    const from = 'àâäéèêëîïôöùûüç';
    const to = 'aaaeeeeiioouuuc';
    var out = s.toLowerCase();
    for (var i = 0; i < from.length; i++) {
      out = out.replaceAll(from[i], to[i]);
    }
    return out.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }

  /// Analyse une réponse de la Base Adresse Nationale (GeoJSON).
  static List<Place> parseBan(dynamic json) {
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
      String? s(String k) {
        final v = props[k];
        return v is String && v.trim().isNotEmpty ? v.trim() : null;
      }

      final score = props['score'];
      if (score is num && score < 0.35) continue;
      final name = s('name') ?? s('label');
      if (name == null) continue;
      final city = s('city');
      final postcode = s('postcode');
      // context : « 33, Gironde, Nouvelle-Aquitaine »
      final context = s('context')?.split(',').map((e) => e.trim()).toList() ?? const <String>[];
      final department = context.length >= 2 ? context[1] : null;
      final type = switch (s('type')) {
        'housenumber' => 'house',
        'street' => 'street',
        'municipality' => 'city',
        'locality' => 'locality',
        final t => t,
      };
      final parts = <String>[
        if (city != null && city != name) postcode != null ? '$postcode $city' : city,
        if (city == null && postcode != null) postcode,
        if (department != null && department != city && department != name) department,
      ];
      out.add(
        Place(
          name: name,
          point: GeoPoint((coords[1] as num).toDouble(), (coords[0] as num).toDouble()),
          detail: parts.isEmpty ? null : parts.join(', '),
          city: city,
          type: type,
          postcode: postcode,
        ),
      );
    }
    return out;
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
          postcode: postcode,
        ),
      );
    }
    return out;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
