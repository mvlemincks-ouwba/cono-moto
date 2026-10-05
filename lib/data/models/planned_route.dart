import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/geo.dart';

/// Type de tracé recherché pour une balade.
enum RouteStyle {
  sinueux('Sinueux', 'Virolos et petites routes qui tournent', Icons.turn_sharp_right),
  foret('Forêt', 'Routes à travers bois et forêts', Icons.forest),
  cols('Cols & montagne', 'Passages de cols, ça grimpe', Icons.landscape),
  plat('Plat & cool', 'Balade tranquille, peu de dénivelé', Icons.waves),
  rapide('Rapide', 'Grandes routes fluides, on avale les km', Icons.speed),
  mixte('Mixte', 'Un peu de tout', Icons.shuffle);

  const RouteStyle(this.label, this.description, this.icon);

  final String label;
  final String description;
  final IconData icon;

  static RouteStyle fromName(String? name) =>
      RouteStyle.values.firstWhere((s) => s.name == name, orElse: () => RouteStyle.mixte);
}

/// D'où vient une balade.
enum RouteSource { generated, gpx, friend, recorded, manual }

/// Instruction de guidage (manœuvre) le long d'un itinéraire.
class Maneuver {
  const Maneuver({
    required this.instruction,
    required this.type,
    required this.distanceAlongM,
    required this.location,
    this.verbalAlert,
    this.streetName,
  });

  /// Texte affiché (« Tournez à droite sur D12 »).
  final String instruction;

  /// Type de manœuvre (code Valhalla ou libellé libre : 'left', 'right', 'roundabout', 'arrive'…).
  final String type;

  /// Position de la manœuvre le long de l'itinéraire (mètres depuis le départ).
  final double distanceAlongM;
  final GeoPoint location;

  /// Phrase à lire par la synthèse vocale.
  final String? verbalAlert;
  final String? streetName;

  Map<String, dynamic> toJson() => {
        'instruction': instruction,
        'type': type,
        'along': distanceAlongM,
        'loc': location.toJson(),
        'verbal': verbalAlert,
        'street': streetName,
      };

  factory Maneuver.fromJson(Map<String, dynamic> j) => Maneuver(
        instruction: j['instruction'] as String,
        type: j['type'] as String,
        distanceAlongM: (j['along'] as num).toDouble(),
        location: GeoPoint.fromJson(Map<String, dynamic>.from(j['loc'] as Map)),
        verbalAlert: j['verbal'] as String?,
        streetName: j['street'] as String?,
      );
}

/// Une balade planifiée (générée, importée, partagée par un pote…).
class PlannedRoute {
  const PlannedRoute({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.points,
    this.style = RouteStyle.mixte,
    this.source = RouteSource.generated,
    this.waypoints = const [],
    this.distanceM = 0,
    this.durationS = 0,
    this.curvatureScore = 0,
    this.elevationGainM = 0,
    this.maneuvers = const [],
    this.description = '',
    this.author,
    this.favorite = false,
  });

  final String id;
  final String name;
  final DateTime createdAt;

  /// Géométrie complète de l'itinéraire.
  final List<GeoPoint> points;
  final RouteStyle style;
  final RouteSource source;

  /// Points de passage utilisés pour calculer l'itinéraire (départ inclus).
  final List<GeoPoint> waypoints;
  final double distanceM;
  final int durationS;

  /// Score de sinuosité 0–100.
  final double curvatureScore;
  final double elevationGainM;
  final List<Maneuver> maneuvers;
  final String description;

  /// Nom du pote qui l'a partagée, le cas échéant.
  final String? author;
  final bool favorite;

  double get distanceKm => distanceM / 1000;

  PlannedRoute copyWith({
    String? name,
    bool? favorite,
    String? description,
    List<Maneuver>? maneuvers,
    double? elevationGainM,
    double? curvatureScore,
  }) =>
      PlannedRoute(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        points: points,
        style: style,
        source: source,
        waypoints: waypoints,
        distanceM: distanceM,
        durationS: durationS,
        curvatureScore: curvatureScore ?? this.curvatureScore,
        elevationGainM: elevationGainM ?? this.elevationGainM,
        maneuvers: maneuvers ?? this.maneuvers,
        description: description ?? this.description,
        author: author,
        favorite: favorite ?? this.favorite,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'polyline': Geo.encodePolyline(points, precision: 6),
        'style': style.name,
        'source': source.name,
        'waypoints': waypoints.map((w) => w.toJson()).toList(),
        'distanceM': distanceM,
        'durationS': durationS,
        'curvature': curvatureScore,
        'elevationGainM': elevationGainM,
        'maneuvers': maneuvers.map((m) => m.toJson()).toList(),
        'description': description,
        'author': author,
        'favorite': favorite,
      };

  factory PlannedRoute.fromJson(Map<String, dynamic> j) => PlannedRoute(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch((j['createdAt'] as num).toInt(), isUtc: true),
        points: Geo.decodePolyline(j['polyline'] as String, precision: 6),
        style: RouteStyle.fromName(j['style'] as String?),
        source: RouteSource.values.firstWhere((s) => s.name == j['source'],
            orElse: () => RouteSource.manual),
        waypoints: ((j['waypoints'] as List?) ?? const [])
            .map((w) => GeoPoint.fromJson(Map<String, dynamic>.from(w as Map)))
            .toList(),
        distanceM: (j['distanceM'] as num?)?.toDouble() ?? 0,
        durationS: (j['durationS'] as num?)?.toInt() ?? 0,
        curvatureScore: (j['curvature'] as num?)?.toDouble() ?? 0,
        elevationGainM: (j['elevationGainM'] as num?)?.toDouble() ?? 0,
        maneuvers: ((j['maneuvers'] as List?) ?? const [])
            .map((m) => Maneuver.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
        description: (j['description'] as String?) ?? '',
        author: j['author'] as String?,
        favorite: (j['favorite'] as bool?) ?? false,
      );

  Map<String, Object?> toDb() => {
        'id': id,
        'name': name,
        'created_at': createdAt.millisecondsSinceEpoch,
        'favorite': favorite ? 1 : 0,
        'data': jsonEncode(toJson()),
      };

  factory PlannedRoute.fromDb(Map<String, Object?> row) =>
      PlannedRoute.fromJson(jsonDecode(row['data'] as String) as Map<String, dynamic>);
}
