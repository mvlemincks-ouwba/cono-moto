import 'package:flutter/material.dart';

import '../../core/geo.dart';
import 'garage.dart';

/// Station-service avec ses prix du moment (données prix-carburants.gouv.fr).
class FuelStation {
  const FuelStation({
    required this.id,
    required this.location,
    required this.address,
    required this.city,
    this.postalCode = '',
    this.prices = const {},
    this.updatedAt = const {},
    this.unavailable = const {},
    this.open24h = false,
    this.distanceM,
    this.brand,
  });

  final String id;
  final GeoPoint location;
  final String address;
  final String city;
  final String postalCode;

  /// Prix en €/L par carburant.
  final Map<FuelType, double> prices;

  /// Date de mise à jour de chaque prix.
  final Map<FuelType, DateTime> updatedAt;

  /// Carburants signalés en rupture.
  final Set<FuelType> unavailable;
  final bool open24h;

  /// Distance depuis la position de recherche.
  final double? distanceM;

  /// Enseigne si connue (les données officielles ne la fournissent pas toujours).
  final String? brand;

  String get displayName => brand?.isNotEmpty == true ? brand! : address;

  double? priceFor(FuelType type) => unavailable.contains(type) ? null : prices[type];

  FuelStation withDistance(double d) => FuelStation(
        id: id,
        location: location,
        address: address,
        city: city,
        postalCode: postalCode,
        prices: prices,
        updatedAt: updatedAt,
        unavailable: unavailable,
        open24h: open24h,
        distanceM: d,
        brand: brand,
      );
}

/// Position en direct d'un pote.
class FriendLive {
  const FriendLive({
    required this.uid,
    required this.name,
    required this.location,
    required this.updatedAt,
    this.colorValue = 0xFF2EC4B6,
    this.speedKmh = 0,
    this.heading,
    this.leanDeg,
    this.riding = false,
    this.bikeName,
    this.sos = false,
  });

  final String uid;
  final String name;
  final GeoPoint location;
  final DateTime updatedAt;
  final int colorValue;
  final double speedKmh;
  final double? heading;
  final double? leanDeg;

  /// En balade (enregistrement en cours).
  final bool riding;
  final String? bikeName;

  /// Alerte chute / SOS en cours.
  final bool sos;

  Color get color => Color(colorValue);

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, parts.first.length >= 2 ? 2 : 1).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  /// Position considérée comme périmée au-delà de 10 minutes.
  bool get isStale => DateTime.now().toUtc().difference(updatedAt.toUtc()).inMinutes >= 10;
}

/// Types de signalements entre potes.
enum ReportType {
  gravillons('Gravillons', Icons.grain, Color(0xFFE0A030)),
  police('Contrôle', Icons.local_police, Color(0xFF3B82F6)),
  danger('Danger', Icons.warning_amber_rounded, Color(0xFFEF4444)),
  accident('Accident', Icons.car_crash, Color(0xFFDC2626)),
  routeDegradee('Route dégradée', Icons.add_road, Color(0xFF9CA3AF)),
  huile('Huile / glissant', Icons.opacity, Color(0xFF8B5CF6)),
  animal('Animal', Icons.pets, Color(0xFF16A34A)),
  travaux('Travaux', Icons.construction, Color(0xFFF97316)),
  superSpot('Super spot', Icons.photo_camera, Color(0xFF14B8A6));

  const ReportType(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;

  static ReportType fromName(String? n) =>
      ReportType.values.firstWhere((t) => t.name == n, orElse: () => ReportType.danger);
}

/// Signalement posé par un pote sur la carte.
class RoadReport {
  const RoadReport({
    required this.id,
    required this.type,
    required this.location,
    required this.createdAt,
    required this.authorUid,
    required this.authorName,
    this.comment = '',
    this.expiresAt,
  });

  final String id;
  final ReportType type;
  final GeoPoint location;
  final DateTime createdAt;
  final String authorUid;
  final String authorName;
  final String comment;
  final DateTime? expiresAt;

  bool get isExpired => expiresAt != null && DateTime.now().toUtc().isAfter(expiresAt!.toUtc());
}

/// Point de regroupement défini dans un groupe.
class RallyPoint {
  const RallyPoint({
    required this.groupId,
    required this.groupName,
    required this.location,
    required this.label,
    required this.setBy,
    required this.setAt,
  });

  final String groupId;
  final String groupName;
  final GeoPoint location;
  final String label;
  final String setBy;
  final DateTime setAt;
}

/// Catégories d'incidents de circulation (TomTom iconCategory).
enum IncidentKind {
  accident('Accident', Icons.car_crash, Color(0xFFDC2626)),
  travaux('Travaux', Icons.construction, Color(0xFFF97316)),
  fermeture('Route fermée', Icons.block, Color(0xFFB91C1C)),
  voieFermee('Voie fermée', Icons.remove_road, Color(0xFFEA580C)),
  bouchon('Bouchon', Icons.traffic, Color(0xFFEF4444)),
  danger('Danger', Icons.warning_amber_rounded, Color(0xFFF59E0B)),
  meteo('Météo', Icons.cloud, Color(0xFF60A5FA)),
  vehiculeArrete('Véhicule arrêté', Icons.car_repair, Color(0xFFF59E0B)),
  autre('Incident', Icons.info_outline, Color(0xFF9CA3AF));

  const IncidentKind(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

/// Incident de circulation en temps réel.
class TrafficIncident {
  const TrafficIncident({
    required this.id,
    required this.kind,
    required this.location,
    this.geometry = const [],
    this.description = '',
    this.roadName = '',
    this.from = '',
    this.to = '',
    this.delayS,
    this.startTime,
    this.endTime,
    this.magnitude = 0,
  });

  final String id;
  final IncidentKind kind;

  /// Point représentatif (début de l'incident).
  final GeoPoint location;

  /// Tronçon concerné (peut être vide pour un incident ponctuel).
  final List<GeoPoint> geometry;
  final String description;
  final String roadName;
  final String from;
  final String to;
  final int? delayS;
  final DateTime? startTime;
  final DateTime? endTime;

  /// Gravité 0 (inconnue) à 4 (route fermée).
  final int magnitude;
}
