import 'dart:convert';

import '../../core/geo.dart';

/// Un point enregistré pendant une balade.
class TrackPoint {
  const TrackPoint({
    required this.time,
    required this.lat,
    required this.lng,
    this.altitude,
    this.speedMs = 0,
    this.heading,
    this.accuracyM,
    this.leanDeg = 0,
    this.longAccelMs2 = 0,
  });

  /// Horodatage (UTC).
  final DateTime time;
  final double lat;
  final double lng;

  /// Altitude GPS en mètres.
  final double? altitude;

  /// Vitesse en m/s.
  final double speedMs;

  /// Cap en degrés (0 = nord).
  final double? heading;
  final double? accuracyM;

  /// Angle d'inclinaison signé en degrés : négatif = gauche, positif = droite.
  final double leanDeg;

  /// Accélération longitudinale (m/s²) : positive = accélération, négative = freinage.
  final double longAccelMs2;

  GeoPoint get point => GeoPoint(lat, lng);
  double get speedKmh => speedMs * 3.6;

  Map<String, Object?> toDb(String rideId, int seq) => {
        'ride_id': rideId,
        'seq': seq,
        't': time.millisecondsSinceEpoch,
        'lat': lat,
        'lng': lng,
        'alt': altitude,
        'speed': speedMs,
        'heading': heading,
        'acc': accuracyM,
        'lean': leanDeg,
        'accel': longAccelMs2,
      };

  factory TrackPoint.fromDb(Map<String, Object?> row) => TrackPoint(
        time: DateTime.fromMillisecondsSinceEpoch(row['t'] as int, isUtc: true),
        lat: (row['lat'] as num).toDouble(),
        lng: (row['lng'] as num).toDouble(),
        altitude: (row['alt'] as num?)?.toDouble(),
        speedMs: (row['speed'] as num?)?.toDouble() ?? 0,
        heading: (row['heading'] as num?)?.toDouble(),
        accuracyM: (row['acc'] as num?)?.toDouble(),
        leanDeg: (row['lean'] as num?)?.toDouble() ?? 0,
        longAccelMs2: (row['accel'] as num?)?.toDouble() ?? 0,
      );
}

/// Évènement notable pendant une balade (freinage fort, accélération, chute…).
class RideEvent {
  const RideEvent({
    required this.type,
    required this.time,
    required this.lat,
    required this.lng,
    this.value = 0,
  });

  /// 'hard_brake' | 'hard_accel' | 'max_lean' | 'crash' | 'fuel' | 'pause'.
  final String type;
  final DateTime time;
  final double lat;
  final double lng;

  /// Valeur associée (ex : décélération en g, angle en degrés).
  final double value;

  Map<String, dynamic> toJson() => {
        'type': type,
        't': time.millisecondsSinceEpoch,
        'lat': lat,
        'lng': lng,
        'v': value,
      };

  factory RideEvent.fromJson(Map<String, dynamic> j) => RideEvent(
        type: j['type'] as String,
        time: DateTime.fromMillisecondsSinceEpoch(j['t'] as int, isUtc: true),
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        value: (j['v'] as num?)?.toDouble() ?? 0,
      );
}

/// Statistiques calculées d'une balade.
class RideStats {
  const RideStats({
    this.distanceM = 0,
    this.movingTimeS = 0,
    this.totalTimeS = 0,
    this.maxSpeedKmh = 0,
    this.maxLeanLeftDeg = 0,
    this.maxLeanRightDeg = 0,
    this.avgLeanInCurvesDeg = 0,
    this.hardBrakeCount = 0,
    this.hardAccelCount = 0,
    this.maxDecelG = 0,
    this.maxAccelG = 0,
    this.elevationGainM = 0,
    this.elevationLossM = 0,
    this.maxAltitudeM,
    this.curveCount = 0,
    this.leanHistogram = const {},
    this.speedHistogram = const {},
  });

  final double distanceM;
  final int movingTimeS;
  final int totalTimeS;
  final double maxSpeedKmh;

  /// Angle max à gauche (valeur positive en degrés).
  final double maxLeanLeftDeg;

  /// Angle max à droite (valeur positive en degrés).
  final double maxLeanRightDeg;
  final double avgLeanInCurvesDeg;
  final int hardBrakeCount;
  final int hardAccelCount;
  final double maxDecelG;
  final double maxAccelG;
  final double elevationGainM;
  final double elevationLossM;
  final double? maxAltitudeM;
  final int curveCount;

  /// Temps passé (secondes) par tranche d'angle : clé = borne basse (0, 10, 20…).
  final Map<int, int> leanHistogram;

  /// Temps passé (secondes) par tranche de vitesse : clé = borne basse (0, 20, 40…).
  final Map<int, int> speedHistogram;

  double get avgMovingSpeedKmh => movingTimeS > 0 ? distanceM / movingTimeS * 3.6 : 0;
  double get maxLeanDeg => maxLeanLeftDeg > maxLeanRightDeg ? maxLeanLeftDeg : maxLeanRightDeg;
  double get distanceKm => distanceM / 1000;

  Map<String, dynamic> toJson() => {
        'distanceM': distanceM,
        'movingTimeS': movingTimeS,
        'totalTimeS': totalTimeS,
        'maxSpeedKmh': maxSpeedKmh,
        'maxLeanLeftDeg': maxLeanLeftDeg,
        'maxLeanRightDeg': maxLeanRightDeg,
        'avgLeanInCurvesDeg': avgLeanInCurvesDeg,
        'hardBrakeCount': hardBrakeCount,
        'hardAccelCount': hardAccelCount,
        'maxDecelG': maxDecelG,
        'maxAccelG': maxAccelG,
        'elevationGainM': elevationGainM,
        'elevationLossM': elevationLossM,
        'maxAltitudeM': maxAltitudeM,
        'curveCount': curveCount,
        'leanHistogram': leanHistogram.map((k, v) => MapEntry('$k', v)),
        'speedHistogram': speedHistogram.map((k, v) => MapEntry('$k', v)),
      };

  factory RideStats.fromJson(Map<String, dynamic> j) {
    Map<int, int> hist(Object? raw) => raw is Map
        ? raw.map((k, v) => MapEntry(int.parse('$k'), (v as num).toInt()))
        : const {};
    double d(String k) => (j[k] as num?)?.toDouble() ?? 0;
    int i(String k) => (j[k] as num?)?.toInt() ?? 0;
    return RideStats(
      distanceM: d('distanceM'),
      movingTimeS: i('movingTimeS'),
      totalTimeS: i('totalTimeS'),
      maxSpeedKmh: d('maxSpeedKmh'),
      maxLeanLeftDeg: d('maxLeanLeftDeg'),
      maxLeanRightDeg: d('maxLeanRightDeg'),
      avgLeanInCurvesDeg: d('avgLeanInCurvesDeg'),
      hardBrakeCount: i('hardBrakeCount'),
      hardAccelCount: i('hardAccelCount'),
      maxDecelG: d('maxDecelG'),
      maxAccelG: d('maxAccelG'),
      elevationGainM: d('elevationGainM'),
      elevationLossM: d('elevationLossM'),
      maxAltitudeM: (j['maxAltitudeM'] as num?)?.toDouble(),
      curveCount: i('curveCount'),
      leanHistogram: hist(j['leanHistogram']),
      speedHistogram: hist(j['speedHistogram']),
    );
  }
}

/// Une balade enregistrée (historique).
class Ride {
  const Ride({
    required this.id,
    required this.name,
    required this.startedAt,
    this.endedAt,
    this.bikeId,
    this.routeId,
    this.stats = const RideStats(),
    this.events = const [],
    this.previewPolyline = '',
    this.notes = '',
    this.sharedWithFriends = false,
  });

  final String id;
  final String name;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? bikeId;

  /// Balade planifiée suivie, si applicable.
  final String? routeId;
  final RideStats stats;
  final List<RideEvent> events;

  /// Tracé simplifié encodé (polyline précision 5) pour les aperçus.
  final String previewPolyline;
  final String notes;
  final bool sharedWithFriends;

  List<GeoPoint> get previewPoints =>
      previewPolyline.isEmpty ? const [] : Geo.decodePolyline(previewPolyline);

  Ride copyWith({
    String? name,
    DateTime? endedAt,
    String? bikeId,
    String? routeId,
    RideStats? stats,
    List<RideEvent>? events,
    String? previewPolyline,
    String? notes,
    bool? sharedWithFriends,
  }) =>
      Ride(
        id: id,
        name: name ?? this.name,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        bikeId: bikeId ?? this.bikeId,
        routeId: routeId ?? this.routeId,
        stats: stats ?? this.stats,
        events: events ?? this.events,
        previewPolyline: previewPolyline ?? this.previewPolyline,
        notes: notes ?? this.notes,
        sharedWithFriends: sharedWithFriends ?? this.sharedWithFriends,
      );

  Map<String, Object?> toDb() => {
        'id': id,
        'name': name,
        'started_at': startedAt.millisecondsSinceEpoch,
        'ended_at': endedAt?.millisecondsSinceEpoch,
        'bike_id': bikeId,
        'route_id': routeId,
        'distance_m': stats.distanceM,
        'stats': jsonEncode(stats.toJson()),
        'events': jsonEncode(events.map((e) => e.toJson()).toList()),
        'preview': previewPolyline,
        'notes': notes,
        'shared': sharedWithFriends ? 1 : 0,
      };

  factory Ride.fromDb(Map<String, Object?> row) => Ride(
        id: row['id'] as String,
        name: row['name'] as String,
        startedAt: DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int, isUtc: true),
        endedAt: row['ended_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['ended_at'] as int, isUtc: true),
        bikeId: row['bike_id'] as String?,
        routeId: row['route_id'] as String?,
        stats: RideStats.fromJson(jsonDecode(row['stats'] as String) as Map<String, dynamic>),
        events: (jsonDecode((row['events'] as String?) ?? '[]') as List)
            .map((e) => RideEvent.fromJson(e as Map<String, dynamic>))
            .toList(),
        previewPolyline: (row['preview'] as String?) ?? '',
        notes: (row['notes'] as String?) ?? '',
        sharedWithFriends: (row['shared'] as int? ?? 0) == 1,
      );
}
