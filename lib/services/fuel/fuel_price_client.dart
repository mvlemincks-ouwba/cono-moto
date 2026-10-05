import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/geo.dart';
import '../../data/models/garage.dart';
import '../../data/models/shared.dart';

/// Erreur lisible (en français) remontée par le service des prix carburants.
class FuelPriceException implements Exception {
  const FuelPriceException(this.message, {this.statusCode});

  final String message;

  /// Code HTTP renvoyé par le service, s'il y en a un.
  final int? statusCode;

  @override
  String toString() => message;
}

/// Station trouvée le long d'un itinéraire.
class RouteFuelStation {
  const RouteFuelStation({required this.station, required this.distanceAlongM, required this.offRouteM});

  final FuelStation station;

  /// Position de la station le long de l'itinéraire (mètres depuis le départ).
  final double distanceAlongM;

  /// Distance entre la station et l'itinéraire (à vol d'oiseau).
  final double offRouteM;

  /// Détour aller-retour estimé pour aller faire le plein.
  double get detourM => offRouteM * 2;
}

/// Client du flux instantané officiel des prix des carburants
/// (data.economie.gouv.fr, Opendatasoft Explore v2.1, sans clé).
///
/// - [around] : stations dans un rayon autour d'un point, triées par distance ;
/// - [alongRoute] : stations à moins de 3 km d'un itinéraire.
///
/// Les réponses sont gardées 5 minutes en mémoire. Les champs sont lus de façon
/// très tolérante (le format du jeu de données a varié dans le temps).
class FuelPriceClient {
  FuelPriceClient({
    http.Client? client,
    DateTime Function()? clock,
    this.endpoint = Endpoints.fuelPrices,
    this.timeout = const Duration(seconds: 12),
    this.cacheTtl = const Duration(minutes: 5),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;
  final String endpoint;
  final Duration timeout;
  final Duration cacheTtl;

  /// Taille de page maximale autorisée par l'API.
  static const pageSize = 100;

  final Map<String, _CacheEntry> _cache = {};
  final Map<String, Future<List<FuelStation>>> _inFlight = {};

  /// Stations dans un rayon de [radiusKm] autour de [center], de la plus proche
  /// à la plus lointaine ([FuelStation.distanceM] renseignée).
  Future<List<FuelStation>> around(GeoPoint center, {double radiusKm = 10, int limit = pageSize}) async {
    final point = _point(center);
    final uri = _uri({
      'where': 'within_distance(geom, $point, ${_num(radiusKm)}km)',
      'order_by': 'distance(geom, $point)',
      'limit': '${limit.clamp(1, pageSize)}',
    });
    final stations = await _fetch(uri);
    final out = [for (final s in stations) s.withDistance(Geo.distance(center, s.location))]
      ..sort((a, b) => a.distanceM!.compareTo(b.distanceM!));
    return out;
  }

  /// Stations à moins de [maxOffRouteM] de l'itinéraire, dans l'ordre du trajet.
  ///
  /// L'itinéraire est échantillonné tous les [sampleStepM] ; chaque requête
  /// regroupe plusieurs cercles `within_distance` (OU logique) et pagine les
  /// résultats. Les stations sont ensuite projetées sur la ligne et filtrées.
  Future<List<RouteFuelStation>> alongRoute(
    List<GeoPoint> route, {
    double maxOffRouteM = 3000,
    double sampleStepM = 5000,
    int samplesPerRequest = 12,
    int maxPagesPerRequest = 6,
  }) async {
    if (route.isEmpty) return const [];
    final line = route.length > 2 ? Geo.simplify(route, 25) : List.of(route);
    final samples = line.length >= 2 ? Geo.resample(line, sampleStepM) : line;
    // Rayon des cercles : couvre la bande de ±maxOffRoute entre deux échantillons.
    final radiusKm = math.sqrt(math.pow(sampleStepM / 2, 2) + math.pow(maxOffRouteM, 2)) / 1000 + 0.3;

    final batches = <List<GeoPoint>>[
      for (var i = 0; i < samples.length; i += samplesPerRequest)
        samples.sublist(i, math.min(samples.length, i + samplesPerRequest)),
    ];

    final found = <String, FuelStation>{};
    Object? firstError;
    var successes = 0;
    // 3 requêtes en parallèle au maximum pour rester raisonnable avec le service.
    for (var i = 0; i < batches.length; i += 3) {
      final group = batches.sublist(i, math.min(batches.length, i + 3));
      final results = await Future.wait(
        group.map((b) async {
          try {
            return await _fetchCirclesWithFallback(b, radiusKm, maxPagesPerRequest);
          } catch (e) {
            firstError ??= e;
            return null;
          }
        }),
      );
      for (final r in results) {
        if (r == null) continue;
        successes++;
        for (final s in r) {
          found[s.id] = s;
        }
      }
    }
    if (successes == 0 && firstError != null) {
      throw firstError is FuelPriceException
          ? firstError!
          : const FuelPriceException('Impossible de récupérer les prix le long du trajet.');
    }

    final cum = Geo.cumulativeDistances(line);
    final out = <RouteFuelStation>[];
    for (final s in found.values) {
      final proj = Geo.project(s.location, line, cumulative: cum);
      if (proj == null || proj.distanceFromLineM > maxOffRouteM) continue;
      out.add(
        RouteFuelStation(
          station: s.withDistance(proj.distanceFromLineM),
          distanceAlongM: proj.distanceAlongM,
          offRouteM: proj.distanceFromLineM,
        ),
      );
    }
    out.sort((a, b) => a.distanceAlongM.compareTo(b.distanceAlongM));
    return out;
  }

  /// Plusieurs cercles en une requête (OU logique) ; si le service refuse la
  /// requête combinée (400), on repasse à un cercle par requête.
  Future<List<FuelStation>> _fetchCirclesWithFallback(List<GeoPoint> centers, double radiusKm, int maxPages) async {
    try {
      return await _fetchCircles(centers, radiusKm, maxPages);
    } on FuelPriceException catch (e) {
      if (e.statusCode != 400 || centers.length < 2) rethrow;
      final out = <FuelStation>[];
      for (final c in centers) {
        out.addAll(await _fetchCircles([c], radiusKm, maxPages));
      }
      return out;
    }
  }

  Future<List<FuelStation>> _fetchCircles(List<GeoPoint> centers, double radiusKm, int maxPages) async {
    final where = centers.map((c) => 'within_distance(geom, ${_point(c)}, ${_num(radiusKm)}km)').join(' OR ');
    final out = <FuelStation>[];
    for (var page = 0; page < maxPages; page++) {
      final uri = _uri({'where': where, 'limit': '$pageSize', 'offset': '${page * pageSize}'});
      final res = await _fetch(uri);
      out.addAll(res);
      if (res.length < pageSize) break;
    }
    return out;
  }

  /// Vide le cache mémoire (ex : « tirer pour rafraîchir »).
  void clearCache() => _cache.clear();

  void close() {
    if (_ownsClient) _client.close();
  }

  // ---------------------------------------------------------------------------
  // Réseau

  Uri _uri(Map<String, String> params) => Uri.parse(endpoint).replace(queryParameters: params);

  static String _point(GeoPoint p) => "geom'POINT(${p.lng.toStringAsFixed(5)} ${p.lat.toStringAsFixed(5)})'";

  static String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  Future<List<FuelStation>> _fetch(Uri uri) {
    final key = uri.toString();
    final cached = _cache[key];
    if (cached != null && _clock().difference(cached.at) < cacheTtl) {
      return Future.value(cached.stations);
    }
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _download(uri)
        .then((stations) {
          _cache[key] = _CacheEntry(_clock(), stations);
          return stations;
        })
        .whenComplete(() {
          // Bloc (et non flèche) : remove() renverrait ce futur, que whenComplete attendrait.
          _inFlight.remove(key);
        });
    _inFlight[key] = future;
    return future;
  }

  Future<List<FuelStation>> _download(Uri uri) async {
    final http.Response res;
    try {
      res = await _client
          .get(uri, headers: {'Accept': 'application/json', 'User-Agent': AppConfig.userAgent})
          .timeout(timeout);
    } on TimeoutException {
      throw const FuelPriceException('Le service des prix carburants ne répond pas. Réessaie dans un instant.');
    } on http.ClientException {
      throw const FuelPriceException('Pas de réseau : impossible de récupérer les prix des carburants.');
    } catch (_) {
      throw const FuelPriceException('Connexion impossible au service des prix carburants.');
    }
    if (res.statusCode == 429) {
      throw const FuelPriceException(
        'Trop de demandes au service des prix, réessaie dans une minute.',
        statusCode: 429,
      );
    }
    if (res.statusCode >= 500) {
      throw FuelPriceException(
        'Le service des prix carburants est indisponible pour le moment (erreur ${res.statusCode}).',
        statusCode: res.statusCode,
      );
    }
    if (res.statusCode != 200) {
      throw FuelPriceException(
        'Le service des prix carburants a refusé la demande (erreur ${res.statusCode}).',
        statusCode: res.statusCode,
      );
    }
    try {
      return parseResponse(utf8.decode(res.bodyBytes, allowMalformed: true));
    } on FormatException {
      throw const FuelPriceException('Réponse illisible du service des prix carburants.');
    }
  }

  // ---------------------------------------------------------------------------
  // Parsing (public et statique pour les tests)

  /// Lit une réponse complète (v2.1 `results`, v1 `records[].fields` ou liste brute).
  static List<FuelStation> parseResponse(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      throw const FormatException('JSON invalide');
    }
    final List<Object?> rows;
    if (json is List) {
      rows = json;
    } else if (json is Map) {
      final r = json['results'] ?? json['records'];
      if (r is! List) throw const FormatException('Champ results absent');
      rows = r;
    } else {
      throw const FormatException('Réponse inattendue');
    }
    final out = <FuelStation>[];
    final seen = <String>{};
    for (final row in rows) {
      if (row is! Map) continue;
      var map = row;
      // Format v1 : {"recordid": ..., "fields": {...}, "geometry": {...}}
      if (map['fields'] is Map) {
        map = {...(map['fields'] as Map), if (map['geometry'] != null) '_geometry': map['geometry']};
      }
      final s = parseRecord(Map<String, dynamic>.from(map));
      if (s != null && seen.add(s.id)) out.add(s);
    }
    return out;
  }

  /// Convertit un enregistrement en [FuelStation] (null si inutilisable).
  static FuelStation? parseRecord(Map<String, dynamic> r) {
    final location = parseLocation(r);
    if (location == null) return null;
    final rawId = r['id'] ?? r['recordid'] ?? r['identifiant'];
    final id = rawId == null
        ? '${location.lat.toStringAsFixed(5)},${location.lng.toStringAsFixed(5)}'
        : '$rawId'.trim();

    final prices = <FuelType, double>{};
    final updated = <FuelType, DateTime>{};
    for (final f in FuelType.values) {
      final p = parsePrice(r['${f.apiKey}_prix']);
      if (p != null) prices[f] = p;
      final d = parseDate(r['${f.apiKey}_maj']);
      if (d != null) updated[f] = d;
    }

    final unavailable = <FuelType>{
      ...parseFuelList(r['carburants_indisponibles']),
      ...parseFuelList(r['carburants_rupture_temporaire']),
      ...parseFuelList(r['carburants_rupture_definitive']),
    };

    String str(Object? v) => v == null ? '' : '$v'.trim();
    final brandRaw = str(r['enseigne'] ?? r['marque'] ?? r['nom'] ?? r['name']);

    return FuelStation(
      id: id,
      location: location,
      address: prettyName(str(r['adresse'] ?? r['address'])),
      city: prettyName(str(r['ville'] ?? r['commune'] ?? r['city'])),
      postalCode: str(r['cp'] ?? r['code_postal']),
      prices: prices,
      updatedAt: updated,
      unavailable: unavailable,
      open24h: parseYesNo(r['horaires_automate_24_24'] ?? r['automate_24_24']),
      brand: brandRaw.isEmpty ? null : prettyName(brandRaw),
    );
  }

  /// Position : `geom {lon, lat}`, GeoJSON, `geo_point_2d`, sinon
  /// `latitude`/`longitude` (nombres ou chaînes, éventuellement ×100000).
  static GeoPoint? parseLocation(Map<String, dynamic> r) {
    for (final key in ['geom', 'geo_point', 'geo_point_2d', '_geometry', 'geometry']) {
      final g = r[key];
      if (g is Map) {
        final lat = _toDouble(g['lat'] ?? g['latitude']);
        final lng = _toDouble(g['lon'] ?? g['lng'] ?? g['longitude']);
        if (lat != null && lng != null) return _validPoint(lat, lng);
        final coords = g['coordinates'];
        if (coords is List && coords.length >= 2) {
          final x = _toDouble(coords[0]);
          final y = _toDouble(coords[1]);
          if (x != null && y != null) return _validPoint(y, x);
        }
      } else if (g is List && g.length >= 2) {
        // Ancien geo_point_2d : [lat, lng].
        final a = _toDouble(g[0]);
        final b = _toDouble(g[1]);
        if (a != null && b != null) return _validPoint(a, b);
      }
    }
    var lat = _toDouble(r['latitude'] ?? r['lat']);
    var lng = _toDouble(r['longitude'] ?? r['lon'] ?? r['lng']);
    if (lat == null || lng == null) return null;
    // Coordonnées « PTV » du flux officiel : degrés × 100 000.
    if (lat.abs() > 90 || lng.abs() > 180) {
      lat /= 100000;
      lng /= 100000;
    }
    return _validPoint(lat, lng);
  }

  static GeoPoint? _validPoint(double lat, double lng) {
    if (lat.isNaN || lng.isNaN || lat.abs() > 90 || lng.abs() > 180) return null;
    if (lat == 0 && lng == 0) return null;
    return GeoPoint(lat, lng);
  }

  /// Prix en €/L : accepte nombres, chaînes (« 1,859 »), millièmes (1859).
  static double? parsePrice(Object? v) {
    var p = _toDouble(v);
    if (p == null || p <= 0) return null;
    var guard = 0;
    while (p! >= 10 && guard++ < 4) {
      p /= 10;
    }
    if (p < 0.2 || p > 5) return null;
    return (p * 1000).round() / 1000;
  }

  /// Date ISO 8601 (« 2026-10-04T08:12:00+02:00 », « 2026-10-04 08:12:00 »…).
  static DateTime? parseDate(Object? v) {
    if (v == null) return null;
    if (v is num) {
      final ms = v > 1e11 ? v.toInt() : (v * 1000).toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
    final s = '$v'.trim();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s)?.toUtc() ?? DateTime.tryParse(s.replaceFirst(' ', 'T'))?.toUtc();
  }

  /// Liste de carburants (liste JSON ou chaîne séparée par `;` ou `,`).
  static Set<FuelType> parseFuelList(Object? v) {
    if (v == null) return const {};
    final Iterable<Object?> items;
    if (v is List) {
      items = v;
    } else {
      final s = '$v'.trim();
      if (s.isEmpty) return const {};
      if (s.startsWith('[')) {
        try {
          final decoded = jsonDecode(s);
          if (decoded is List) return parseFuelList(decoded);
        } catch (_) {}
      }
      items = s.split(RegExp(r'[;,|]'));
    }
    final out = <FuelType>{};
    for (final item in items) {
      final f = fuelTypeFromLabel('$item');
      if (f != null) out.add(f);
    }
    return out;
  }

  /// « Gazole », « SP95-E10 », « E10 », « GPLc »… → [FuelType].
  static FuelType? fuelTypeFromLabel(String label) {
    final k = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (k.isEmpty) return null;
    if (k.contains('e10')) return FuelType.e10;
    if (k.contains('e85')) return FuelType.e85;
    if (k.contains('gazole') || k.contains('diesel') || k == 'b7') return FuelType.gazole;
    if (k.contains('gpl')) return FuelType.gplc;
    if (k.contains('98')) return FuelType.sp98;
    if (k.contains('95')) return FuelType.sp95;
    return null;
  }

  static bool parseYesNo(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = '${v ?? ''}'.trim().toLowerCase();
    return s == 'oui' || s == 'o' || s == 'yes' || s == 'true' || s == '1';
  }

  static double? _toDouble(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final s = '$v'.trim().replaceAll(' ', '').replaceAll(',', '.');
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }

  static const _smallWords = {
    'de',
    'du',
    'des',
    'la',
    'le',
    'les',
    'et',
    'en',
    'au',
    'aux',
    'sur',
    'sous',
    'lès',
    'lez',
    'à',
    'd',
    'l',
    'dit',
    'dite',
  };

  static const _abbreviations = {'zi', 'za', 'zac', 'zae', 'zal', 'rn', 'rd', 'cd', 'cc', 'sarl', 'sas', 'bp'};

  /// Les adresses officielles sont souvent en MAJUSCULES : on les rend lisibles
  /// (« 12 AVENUE DE LA GARE » → « 12 Avenue de la Gare »).
  static String prettyName(String raw) {
    final s = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return s;
    final upper = RegExp(r'[A-ZÀ-ÖØ-Þ]').allMatches(s).length;
    final lower = RegExp(r'[a-zß-öø-ÿ]').allMatches(s).length;
    // Déjà en casse mixte : on n'y touche pas.
    if (upper <= lower * 2) return s;
    final buf = StringBuffer();
    var wordIndex = 0;
    for (final m in RegExp(r'([A-Za-zÀ-ÖØ-öø-ÿ0-9]+)|([^A-Za-zÀ-ÖØ-öø-ÿ0-9]+)').allMatches(s)) {
      final word = m.group(1);
      if (word == null) {
        buf.write(m.group(2));
        continue;
      }
      final w = word.toLowerCase();
      if (RegExp(r'[0-9]').hasMatch(w) || _abbreviations.contains(w)) {
        buf.write(w.toUpperCase());
      } else if (wordIndex > 0 && _smallWords.contains(w)) {
        buf.write(w);
      } else {
        buf.write(w[0].toUpperCase() + w.substring(1));
      }
      wordIndex++;
    }
    return buf.toString();
  }
}

class _CacheEntry {
  const _CacheEntry(this.at, this.stations);

  final DateTime at;
  final List<FuelStation> stations;
}
