import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/geo.dart';
import 'http_support.dart';
import 'route_scoring.dart';

/// Profil d'altitude échantillonné le long d'un itinéraire.
class ElevationProfile {
  const ElevationProfile({required this.distancesM, required this.elevationsM, required this.stats});

  /// Distance depuis le départ de chaque échantillon.
  final List<double> distancesM;
  final List<double> elevationsM;
  final ElevationStats stats;

  bool get isEmpty => elevationsM.isEmpty;
}

/// Altitudes Open-Meteo (modèle numérique de terrain 90 m, sans clé).
class ElevationClient {
  ElevationClient({
    http.Client? client,
    this.endpoint = Endpoints.openMeteoElevation,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String endpoint;
  final Duration timeout;

  static const service = "le service d'altitude";

  /// Limite de l'API : 100 coordonnées par requête.
  static const maxPerRequest = 100;

  static Uri buildUri(String endpoint, List<GeoPoint> points) => Uri.parse(endpoint).replace(
    queryParameters: {
      'latitude': points.map((p) => p.lat.toStringAsFixed(5)).join(','),
      'longitude': points.map((p) => p.lng.toStringAsFixed(5)).join(','),
    },
  );

  /// Altitudes des points (requêtes de 100 points max, en séquence).
  Future<List<double>> elevations(List<GeoPoint> points) async {
    final out = <double>[];
    for (var i = 0; i < points.length; i += maxPerRequest) {
      final chunk = points.sublist(i, (i + maxPerRequest).clamp(0, points.length));
      final r = await guardedSend(
        () => _client.get(buildUri(endpoint, chunk), headers: serviceHeaders()),
        service: service,
        timeout: timeout,
      );
      checkStatus(r, service: service);
      final values = parse(decodeJsonBody(r, service: service));
      if (values.length != chunk.length) {
        throw const RoutingException(
          RoutingErrorKind.badResponse,
          "Le service d'altitude a renvoyé des données incomplètes.",
        );
      }
      out.addAll(values);
    }
    return out;
  }

  /// Profil d'altitude d'une ligne : un point tous les ~[stepM] mètres
  /// (au plus [maxPoints], soit 3 requêtes).
  Future<ElevationProfile> profile(List<GeoPoint> line, {double stepM = 1000, int maxPoints = 300}) async {
    if (line.length < 2) {
      return const ElevationProfile(distancesM: [], elevationsM: [], stats: ElevationStats.empty);
    }
    final cum = Geo.cumulativeDistances(line);
    final distances = RouteScoring.sampleDistances(cum.last, stepM: stepM, maxPoints: maxPoints);
    final samples = [for (final d in distances) Geo.pointAtDistance(line, d, cumulative: cum)];
    final elev = await elevations(samples);
    return ElevationProfile(
      distancesM: distances,
      elevationsM: elev,
      stats: RouteScoring.elevationStats(elev, hysteresisM: 2),
    );
  }

  /// `{"elevation":[38.0, 152.0]}` → liste d'altitudes.
  static List<double> parse(dynamic json) {
    if (json is! Map) return const [];
    final list = json['elevation'];
    if (list is! List) return const [];
    return [for (final v in list) v is num ? v.toDouble() : double.nan];
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
