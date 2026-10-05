import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/map/map_models.dart';
import '../../core/theme.dart';
import '../../data/models/garage.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/shared.dart';

/// Construction des couches de la carte principale (logique pure, testable).
class MapLayers {
  MapLayers._();

  static MapMarker friend(FriendLive f) {
    final speed = f.riding && f.speedKmh >= 5 ? ' · ${f.speedKmh.round()} km/h' : '';
    return MapMarker(
      id: 'friend:${f.uid}',
      position: f.location,
      style: MarkerStyle.avatar,
      text: f.initials,
      color: f.isStale ? const Color(0xFF6B7280) : f.color,
      label: f.sos ? '⚠ ${f.name} SOS' : '${f.name}$speed',
      size: 40,
      zIndex: f.sos ? 100 : 50,
      highlighted: f.sos,
      payload: f,
    );
  }

  static MapMarker report(RoadReport r) => MapMarker(
        id: 'report:${r.id}',
        position: r.location,
        icon: r.type.icon,
        color: r.type.color,
        size: 30,
        zIndex: 20,
        payload: r,
      );

  static MapMarker rally(RallyPoint p) => MapMarker(
        id: 'rally:${p.groupId}',
        position: p.location,
        icon: Icons.flag_rounded,
        color: CmColors.sky,
        label: p.label,
        size: 38,
        zIndex: 40,
        payload: p,
      );

  static MapMarker incident(TrafficIncident i) => MapMarker(
        id: 'incident:${i.id}',
        position: i.location,
        icon: i.kind.icon,
        color: i.kind.color,
        size: 28,
        zIndex: 10,
        payload: i,
      );

  static MapLine? incidentLine(TrafficIncident i) {
    if (i.geometry.length < 2) return null;
    final closed = i.kind == IncidentKind.fermeture;
    return MapLine(
      id: 'incident-line:${i.id}',
      points: i.geometry,
      color: i.kind.color,
      width: closed ? 5 : 4,
      opacity: 0.9,
      dashed: closed || i.kind == IncidentKind.travaux,
      casing: false,
    );
  }

  /// Étiquettes de prix : vert = moins cher (tiers bas), orange, rouge = cher.
  static List<MapMarker> stations(List<FuelStation> stations, FuelType fuel) {
    final priced = [
      for (final s in stations)
        if (s.priceFor(fuel) != null) s
    ];
    if (priced.isEmpty) return const [];
    final prices = priced.map((s) => s.priceFor(fuel)!).toList()..sort();
    final low = prices[(prices.length / 3).floor().clamp(0, prices.length - 1)];
    final high = prices[(prices.length * 2 / 3).floor().clamp(0, prices.length - 1)];
    final min = prices.first;
    return [
      for (final s in priced)
        () {
          final p = s.priceFor(fuel)!;
          final color = p <= low
              ? CmColors.green
              : p >= high
                  ? CmColors.red
                  : CmColors.orange;
          return MapMarker(
            id: 'station:${s.id}',
            position: s.location,
            style: MarkerStyle.tag,
            icon: Icons.local_gas_station,
            text: Fmt.number(p, decimals: 3).replaceAll(' ', ''),
            color: color,
            size: 30,
            zIndex: p == min ? 9 : 5,
            highlighted: p == min,
            payload: s,
          );
        }(),
    ];
  }

  static List<MapLine> route(PlannedRoute r) => [
        MapLine(id: 'route:${r.id}', points: r.points, color: CmColors.orange, width: 6),
      ];

  static List<MapMarker> routeEnds(PlannedRoute r) {
    if (r.points.length < 2) return const [];
    final loop = r.points.first.lat == r.points.last.lat && r.points.first.lng == r.points.last.lng;
    return [
      MapMarker(
        id: 'route-start:${r.id}',
        position: r.points.first,
        icon: Icons.play_arrow_rounded,
        color: CmColors.green,
        size: 30,
        zIndex: 15,
      ),
      if (!loop)
        MapMarker(
          id: 'route-end:${r.id}',
          position: r.points.last,
          icon: Icons.sports_score,
          color: const Color(0xFF111827),
          size: 30,
          zIndex: 15,
        ),
    ];
  }
}
