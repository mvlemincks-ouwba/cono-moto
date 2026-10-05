import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/geo.dart';
import '../../data/models/shared.dart';

/// Erreur d'accès au trafic, avec un message prêt à afficher.
class TrafficException implements Exception {
  TrafficException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Client de l'API TomTom Traffic Incident Details v5 (clé gratuite requise,
/// 2 500 requêtes/jour sur l'offre gratuite).
class TomTomTrafficClient {
  TomTomTrafficClient({required this.apiKey, http.Client? client}) : _client = client ?? http.Client();

  final String apiKey;
  final http.Client _client;

  /// Surface maximale acceptée par l'API pour une bbox (km²).
  static const maxAreaKm2 = 10000.0;

  static const _fields =
      '{incidents{type,geometry{type,coordinates},properties{id,iconCategory,magnitudeOfDelay,'
      'events{description,code,iconCategory},startTime,endTime,from,to,length,delay,roadNumbers}}}';

  /// Réduit une zone pour respecter la limite de surface de l'API (centrée).
  static GeoBounds clampBounds(GeoBounds b) {
    final cosLat = math.cos(b.center.lat * math.pi / 180).abs().clamp(0.01, 1.0);
    final heightKm = (b.north - b.south) * Geo.metersPerDegreeLat / 1000;
    final widthKm = (b.east - b.west) * Geo.metersPerDegreeLat * cosLat / 1000;
    final area = heightKm * widthKm;
    if (area <= maxAreaKm2 * 0.95) return b;
    final factor = math.sqrt(maxAreaKm2 * 0.95 / area);
    final c = b.center;
    final halfLat = (b.north - b.south) / 2 * factor;
    final halfLng = (b.east - b.west) / 2 * factor;
    return GeoBounds(south: c.lat - halfLat, west: c.lng - halfLng, north: c.lat + halfLat, east: c.lng + halfLng);
  }

  Future<List<TrafficIncident>> incidents(GeoBounds bounds) async {
    if (apiKey.isEmpty) throw TrafficException('Clé TomTom manquante (Réglages › Trafic).');
    final b = clampBounds(bounds);
    final uri = Uri.parse(Endpoints.tomtomIncidents).replace(queryParameters: {
      'key': apiKey,
      'bbox': '${b.west.toStringAsFixed(5)},${b.south.toStringAsFixed(5)},'
          '${b.east.toStringAsFixed(5)},${b.north.toStringAsFixed(5)}',
      'fields': _fields,
      'language': 'fr-FR',
      'timeValidityFilter': 'present',
    });
    final http.Response res;
    try {
      res = await _client.get(uri).timeout(const Duration(seconds: 15));
    } catch (_) {
      throw TrafficException('Trafic indisponible (pas de réseau ?).');
    }
    if (res.statusCode == 403 || res.statusCode == 401) {
      throw TrafficException('Clé TomTom refusée : vérifie-la dans les réglages.');
    }
    if (res.statusCode == 429) {
      throw TrafficException('Quota TomTom du jour atteint, réessaie plus tard.');
    }
    if (res.statusCode != 200) {
      throw TrafficException('Trafic indisponible (erreur ${res.statusCode}).');
    }
    return parseIncidents(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  /// Convertit la réponse JSON TomTom en incidents.
  static List<TrafficIncident> parseIncidents(Object? json) {
    if (json is! Map) return const [];
    final list = json['incidents'];
    if (list is! List) return const [];
    final out = <TrafficIncident>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final props = raw['properties'] is Map ? raw['properties'] as Map : const {};
      final geom = raw['geometry'] is Map ? raw['geometry'] as Map : const {};
      final points = _parseGeometry(geom);
      if (points.isEmpty) continue;
      final category = (props['iconCategory'] as num?)?.toInt() ?? 0;
      final events = props['events'] is List ? props['events'] as List : const [];
      final descriptions = [
        for (final e in events)
          if (e is Map && e['description'] is String && (e['description'] as String).isNotEmpty)
            e['description'] as String
      ];
      final roads = props['roadNumbers'] is List
          ? (props['roadNumbers'] as List).whereType<String>().join(', ')
          : '';
      out.add(TrafficIncident(
        id: '${props['id'] ?? '${points.first.lat},${points.first.lng}'}',
        kind: kindFor(category),
        location: points.first,
        geometry: points.length > 1 ? points : const [],
        description: descriptions.join(' · '),
        roadName: roads,
        from: (props['from'] as String?) ?? '',
        to: (props['to'] as String?) ?? '',
        delayS: (props['delay'] as num?)?.toInt(),
        startTime: DateTime.tryParse('${props['startTime'] ?? ''}'),
        endTime: DateTime.tryParse('${props['endTime'] ?? ''}'),
        magnitude: (props['magnitudeOfDelay'] as num?)?.toInt() ?? 0,
      ));
    }
    return out;
  }

  static List<GeoPoint> _parseGeometry(Map geom) {
    final coords = geom['coordinates'];
    GeoPoint? pt(Object? c) {
      if (c is List && c.length >= 2 && c[0] is num && c[1] is num) {
        return GeoPoint((c[1] as num).toDouble(), (c[0] as num).toDouble());
      }
      return null;
    }

    if (geom['type'] == 'Point') {
      final p = pt(coords);
      return p == null ? const [] : [p];
    }
    if (coords is List) {
      return [for (final c in coords) ?pt(c)];
    }
    return const [];
  }

  /// Correspondance des catégories d'icônes TomTom.
  static IncidentKind kindFor(int iconCategory) => switch (iconCategory) {
        1 => IncidentKind.accident,
        2 || 4 || 5 || 10 || 11 => IncidentKind.meteo,
        3 => IncidentKind.danger,
        6 => IncidentKind.bouchon,
        7 => IncidentKind.voieFermee,
        8 => IncidentKind.fermeture,
        9 => IncidentKind.travaux,
        14 => IncidentKind.vehiculeArrete,
        _ => IncidentKind.autre,
      };
}
