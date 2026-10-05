import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/geo.dart';
import '../../data/models/planned_route.dart';
import 'http_support.dart';
import 'maneuver_kinds.dart';
import 'tutoiement.dart';

/// Type de point passé à Valhalla.
enum LocationKind {
  /// Arrêt (début/fin d'étape, demi-tour autorisé).
  breakPoint('break'),

  /// Point de passage sans arrêt ni demi-tour.
  through('through'),

  /// Point de passage, demi-tour autorisé.
  via('via');

  const LocationKind(this.wire);

  final String wire;
}

/// Point d'un calcul d'itinéraire.
class RouteLocation {
  const RouteLocation(this.point, {this.kind = LocationKind.breakPoint});

  final GeoPoint point;
  final LocationKind kind;

  Map<String, dynamic> toJson() => {
    'lat': double.parse(point.lat.toStringAsFixed(6)),
    'lon': double.parse(point.lng.toStringAsFixed(6)),
    'type': kind.wire,
  };
}

/// Préférences de coût Valhalla pour la moto (0 = éviter, 1 = favoriser).
class MotorcycleCosting {
  const MotorcycleCosting({
    this.useHighways = 0.5,
    this.useTolls = 0.5,
    this.usePrimary = 0.5,
    this.useTrails = 0,
    this.useFerry = 0.3,
    this.useLivingStreets = 0.1,
  });

  final double useHighways;
  final double useTolls;
  final double usePrimary;
  final double useTrails;
  final double useFerry;
  final double useLivingStreets;

  /// Réglages adaptés au type de balade.
  factory MotorcycleCosting.forStyle(RouteStyle style, {bool avoidHighways = false, bool avoidTolls = false}) {
    final (highways, primary, tolls) = switch (style) {
      RouteStyle.sinueux => (0.0, 0.1, 0.0),
      RouteStyle.foret => (0.0, 0.2, 0.0),
      RouteStyle.cols => (0.0, 0.3, 0.1),
      RouteStyle.plat => (0.1, 0.4, 0.2),
      RouteStyle.rapide => (0.5, 1.0, 0.5),
      RouteStyle.mixte => (0.2, 0.5, 0.3),
    };
    return MotorcycleCosting(
      useHighways: avoidHighways ? 0 : highways,
      usePrimary: primary,
      useTolls: avoidTolls ? 0 : tolls,
      useTrails: 0,
      useFerry: 0.2,
      useLivingStreets: 0.1,
    );
  }

  Map<String, dynamic> toJson() => {
    'use_highways': useHighways,
    'use_tolls': useTolls,
    'use_primary': usePrimary,
    'use_trails': useTrails,
    'use_ferry': useFerry,
    'use_living_streets': useLivingStreets,
  };
}

/// Itinéraire calculé.
class ValhallaRoute {
  const ValhallaRoute({
    required this.points,
    required this.distanceM,
    required this.durationS,
    required this.maneuvers,
    this.hasToll = false,
    this.hasHighway = false,
    this.hasFerry = false,
  });

  final List<GeoPoint> points;
  final double distanceM;
  final int durationS;
  final List<Maneuver> maneuvers;
  final bool hasToll;
  final bool hasHighway;
  final bool hasFerry;

  /// Met bout à bout plusieurs itinéraires consécutifs (calcul par morceaux).
  static ValhallaRoute concat(List<ValhallaRoute> parts) {
    if (parts.length == 1) return parts.first;
    final points = <GeoPoint>[];
    final maneuvers = <Maneuver>[];
    var offsetM = 0.0;
    var distance = 0.0;
    var duration = 0;
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      final skipFirst = points.isNotEmpty && p.points.isNotEmpty && Geo.distance(points.last, p.points.first) < 1;
      points.addAll(skipFirst ? p.points.skip(1) : p.points);
      for (final m in p.maneuvers) {
        final isLastPart = i == parts.length - 1;
        if (i > 0 && m.type == ManeuverKind.depart) continue;
        if (!isLastPart && m.type == ManeuverKind.arrive) continue;
        maneuvers.add(
          Maneuver(
            instruction: m.instruction,
            type: m.type,
            distanceAlongM: m.distanceAlongM + offsetM,
            location: m.location,
            verbalAlert: m.verbalAlert,
            streetName: m.streetName,
          ),
        );
      }
      final len = p.points.length >= 2 ? Geo.length(p.points) : 0.0;
      offsetM += len;
      distance += p.distanceM;
      duration += p.durationS;
    }
    return ValhallaRoute(
      points: points,
      distanceM: distance,
      durationS: duration,
      maneuvers: maneuvers,
      hasToll: parts.any((p) => p.hasToll),
      hasHighway: parts.any((p) => p.hasHighway),
      hasFerry: parts.any((p) => p.hasFerry),
    );
  }
}

/// Client du serveur Valhalla public (FOSSGIS) : itinéraires moto.
class ValhallaClient {
  ValhallaClient({
    http.Client? client,
    this.endpoint = Endpoints.valhalla,
    RateLimiter? limiter,
    this.timeout = const Duration(seconds: 45),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _limiter = limiter ?? RateLimiter.valhalla;

  final http.Client _client;
  final bool _ownsClient;
  final RateLimiter _limiter;
  final String endpoint;
  final Duration timeout;

  static const service = "le serveur d'itinéraires";

  /// Nombre max de points par requête sur le serveur public.
  static const maxLocations = 20;

  /// Calcule un itinéraire passant par [locations] (au moins 2).
  Future<ValhallaRoute> route(
    List<RouteLocation> locations, {
    MotorcycleCosting costing = const MotorcycleCosting(),
  }) async {
    if (locations.length < 2) {
      throw const RoutingException(RoutingErrorKind.invalidRequest, 'Il faut au moins un départ et une arrivée.');
    }
    final body = jsonEncode(buildRequest(locations, costing: costing));
    await _limiter.acquire();
    final response = await guardedSend(
      () => _client.post(Uri.parse(endpoint), headers: serviceHeaders(jsonBody: true), body: body),
      service: service,
      timeout: timeout,
    );
    if (response.statusCode >= 400 && response.statusCode < 500 && response.statusCode != 429) {
      throw parseError(response.statusCode, utf8.decode(response.bodyBytes, allowMalformed: true));
    }
    checkStatus(response, service: service);
    final json = decodeJsonBody(response, service: service);
    if (json is! Map<String, dynamic>) {
      throw const RoutingException(RoutingErrorKind.badResponse, "Réponse inattendue du serveur d'itinéraires.");
    }
    return parseResponse(json);
  }

  /// Itinéraire passant par une longue liste de points : découpé en morceaux
  /// de [maxLocations] points puis recollé. Les points intermédiaires sont
  /// des passages (« through »).
  Future<ValhallaRoute> routeThrough(
    List<GeoPoint> points, {
    MotorcycleCosting costing = const MotorcycleCosting(),
  }) async {
    if (points.length < 2) {
      throw const RoutingException(RoutingErrorKind.invalidRequest, 'Il faut au moins un départ et une arrivée.');
    }
    final parts = <ValhallaRoute>[];
    for (final chunk in chunkLocations(points, maxLocations)) {
      parts.add(
        await route([
          for (var i = 0; i < chunk.length; i++)
            RouteLocation(
              chunk[i],
              kind: i == 0 || i == chunk.length - 1 ? LocationKind.breakPoint : LocationKind.through,
            ),
        ], costing: costing),
      );
    }
    return ValhallaRoute.concat(parts);
  }

  /// Découpe en morceaux qui se chevauchent d'un point (fin = début suivant).
  static List<List<GeoPoint>> chunkLocations(List<GeoPoint> points, int max) {
    if (points.length <= max) return [points];
    final out = <List<GeoPoint>>[];
    var start = 0;
    while (start < points.length - 1) {
      final end = (start + max - 1).clamp(0, points.length - 1);
      out.add(points.sublist(start, end + 1));
      start = end;
    }
    return out;
  }

  static Map<String, dynamic> buildRequest(
    List<RouteLocation> locations, {
    MotorcycleCosting costing = const MotorcycleCosting(),
  }) => {
    'locations': [for (final l in locations) l.toJson()],
    'costing': 'motorcycle',
    'costing_options': {'motorcycle': costing.toJson()},
    'directions_options': {'units': 'kilometers', 'language': 'fr-FR'},
    'id': 'cono-moto',
  };

  /// Analyse une réponse Valhalla (`trip.summary`, `trip.legs[]`).
  static ValhallaRoute parseResponse(Map<String, dynamic> json) {
    final trip = json['trip'];
    if (trip is! Map) {
      throw const RoutingException(RoutingErrorKind.badResponse, "Réponse du serveur d'itinéraires incomplète.");
    }
    final legs = (trip['legs'] as List?) ?? const [];
    if (legs.isEmpty) {
      throw const RoutingException(RoutingErrorKind.noRoute, 'Aucune route trouvée entre ces points.');
    }

    final points = <GeoPoint>[];
    // (index dans la géométrie globale, manœuvre brute, index de l'étape)
    final raw = <(int, Map, int)>[];
    for (var li = 0; li < legs.length; li++) {
      final leg = legs[li] as Map;
      final shape = Geo.decodePolyline((leg['shape'] as String?) ?? '', precision: 6);
      final int offset;
      if (points.isNotEmpty && shape.isNotEmpty && Geo.distance(points.last, shape.first) < 1) {
        offset = points.length - 1;
        points.addAll(shape.skip(1));
      } else {
        offset = points.length;
        points.addAll(shape);
      }
      for (final m in (leg['maneuvers'] as List?) ?? const []) {
        final map = m as Map;
        final begin = (map['begin_shape_index'] as num?)?.toInt() ?? 0;
        raw.add((offset + begin, map, li));
      }
    }
    if (points.length < 2) {
      throw const RoutingException(RoutingErrorKind.noRoute, 'Aucune route trouvée entre ces points.');
    }

    final cum = Geo.cumulativeDistances(points);
    final maneuvers = <Maneuver>[];
    var waypointNo = 0;
    for (final (index, m, legIndex) in raw) {
      final code = (m['type'] as num?)?.toInt() ?? 0;
      var kind = ManeuverKind.fromValhalla(code);
      final lastLeg = legIndex == legs.length - 1;
      // Étapes intermédiaires : un seul repère « point de passage ».
      if (legIndex > 0 && kind == ManeuverKind.depart) continue;
      final idx = index.clamp(0, points.length - 1);
      String instruction = tutoyer((m['instruction'] as String?)?.trim() ?? '');
      String? verbal = _verbal(m);
      if (!lastLeg && kind == ManeuverKind.arrive) {
        kind = ManeuverKind.waypoint;
        waypointNo++;
        instruction = 'Point de passage n°$waypointNo';
        verbal = 'Point de passage.';
      }
      final streets =
          (m['street_names'] as List?)?.whereType<String>().toList() ??
          (m['begin_street_names'] as List?)?.whereType<String>().toList();
      maneuvers.add(
        Maneuver(
          instruction: instruction.isEmpty ? _fallbackInstruction(kind) : instruction,
          type: kind,
          distanceAlongM: cum[idx],
          location: points[idx],
          verbalAlert: verbal,
          streetName: (streets == null || streets.isEmpty) ? null : streets.first,
        ),
      );
    }

    final summary = (trip['summary'] as Map?) ?? const {};
    final lengthKm = (summary['length'] as num?)?.toDouble();
    final timeS = (summary['time'] as num?)?.toDouble() ?? 0;
    return ValhallaRoute(
      points: points,
      distanceM: lengthKm != null ? lengthKm * 1000 : cum.last,
      durationS: timeS.round(),
      maneuvers: maneuvers,
      hasToll: summary['has_toll'] == true,
      hasHighway: summary['has_highway'] == true,
      hasFerry: summary['has_ferry'] == true,
    );
  }

  static String? _verbal(Map m) {
    final v =
        (m['verbal_pre_transition_instruction'] as String?) ??
        (m['verbal_transition_alert_instruction'] as String?) ??
        (m['instruction'] as String?);
    if (v == null || v.trim().isEmpty) return null;
    return tutoyer(v.trim());
  }

  static String _fallbackInstruction(String kind) => switch (kind) {
    ManeuverKind.arrive => "Tu es arrivé !",
    ManeuverKind.depart => "C'est parti !",
    ManeuverKind.left => 'Tourne à gauche',
    ManeuverKind.right => 'Tourne à droite',
    ManeuverKind.roundabout => 'Prends le rond-point',
    _ => 'Continue',
  };

  /// Traduit une erreur 4xx Valhalla (`error_code`) en message clair.
  static RoutingException parseError(int status, String body) {
    int? code;
    String? message;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        code = (j['error_code'] as num?)?.toInt();
        message = j['error'] as String?;
      }
    } catch (_) {}
    switch (code) {
      case 442:
      case 443:
        return const RoutingException(
          RoutingErrorKind.noRoute,
          "Pas de route praticable entre ces points. Essaie un autre départ ou une autre distance.",
        );
      case 170:
      case 171:
        return const RoutingException(
          RoutingErrorKind.noRoute,
          "Un des points est trop loin d'une route praticable à moto.",
        );
      case 154:
      case 155:
      case 156:
      case 157:
      case 158:
        return const RoutingException(
          RoutingErrorKind.invalidRequest,
          "Trajet trop long pour le serveur d'itinéraires. Réduis la distance ou découpe-le en étapes.",
        );
      case 150:
        return const RoutingException(
          RoutingErrorKind.invalidRequest,
          "Trop de points de passage pour le serveur d'itinéraires.",
        );
    }
    return RoutingException(
      status == 404 ? RoutingErrorKind.server : RoutingErrorKind.invalidRequest,
      message == null
          ? "Le serveur d'itinéraires a refusé la demande (erreur $status)."
          : "Itinéraire impossible : $message.",
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
