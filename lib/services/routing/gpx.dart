import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import '../../core/geo.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/ride.dart';
import 'route_scoring.dart';

/// Point nommé (wpt) d'un fichier GPX.
class GpxWaypoint {
  const GpxWaypoint(this.point, {this.name, this.elevation});

  final GeoPoint point;
  final String? name;
  final double? elevation;
}

/// Construit un fichier GPX 1.1 (trace enregistrée et/ou itinéraire).
///
/// - [track] : trace GPS avec heure et altitude → `<trk>` ;
/// - [route] : géométrie d'un itinéraire → `<trk>` (si pas de trace, pour les
///   applis qui n'affichent que les traces) + `<rte>` simplifié ;
/// - [waypoints] : points nommés → `<wpt>`.
String buildGpx({
  required String name,
  List<TrackPoint> track = const [],
  List<GeoPoint> route = const [],
  List<GpxWaypoint> waypoints = const [],
  String? description,
  DateTime? time,
}) {
  final sb = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<gpx version="1.1" creator="Cono Moto" '
      'xmlns="http://www.topografix.com/GPX/1/1" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">',
    )
    ..writeln('  <metadata>')
    ..writeln('    <name>${_esc(name)}</name>');
  if (description != null && description.isNotEmpty) {
    sb.writeln('    <desc>${_esc(description)}</desc>');
  }
  final stamp = time ?? (track.isNotEmpty ? track.first.time : null);
  if (stamp != null) sb.writeln('    <time>${_time(stamp)}</time>');
  sb.writeln('  </metadata>');

  for (final w in waypoints) {
    sb.write('  <wpt lat="${_c(w.point.lat)}" lon="${_c(w.point.lng)}">');
    if (w.elevation != null) sb.write('<ele>${w.elevation!.toStringAsFixed(1)}</ele>');
    if (w.name != null) sb.write('<name>${_esc(w.name!)}</name>');
    sb.writeln('</wpt>');
  }

  if (track.isNotEmpty) {
    sb
      ..writeln('  <trk>')
      ..writeln('    <name>${_esc(name)}</name>')
      ..writeln('    <trkseg>');
    for (final p in track) {
      sb.write('      <trkpt lat="${_c(p.lat)}" lon="${_c(p.lng)}">');
      if (p.altitude != null) sb.write('<ele>${p.altitude!.toStringAsFixed(1)}</ele>');
      sb.write('<time>${_time(p.time)}</time>');
      sb.writeln('</trkpt>');
    }
    sb
      ..writeln('    </trkseg>')
      ..writeln('  </trk>');
  } else if (route.length >= 2) {
    sb
      ..writeln('  <trk>')
      ..writeln('    <name>${_esc(name)}</name>')
      ..writeln('    <trkseg>');
    for (final p in route) {
      sb.writeln('      <trkpt lat="${_c(p.lat)}" lon="${_c(p.lng)}"></trkpt>');
    }
    sb
      ..writeln('    </trkseg>')
      ..writeln('  </trk>');
  }

  if (route.length >= 2) {
    final simplified = Geo.simplify(route, 15);
    sb
      ..writeln('  <rte>')
      ..writeln('    <name>${_esc(name)}</name>');
    for (final p in simplified) {
      sb.writeln('    <rtept lat="${_c(p.lat)}" lon="${_c(p.lng)}"></rtept>');
    }
    sb.writeln('  </rte>');
  }
  sb.writeln('</gpx>');
  return sb.toString();
}

/// GPX d'une balade planifiée.
String buildRouteGpx(PlannedRoute route) => buildGpx(
  name: route.name,
  route: route.points,
  description: route.description.isEmpty ? null : route.description,
  time: route.createdAt,
);

/// Nom de fichier propre (« Virolos vers Dourdan » → « virolos-vers-dourdan.gpx »).
String gpxFileName(String name) {
  const accents = {
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'î': 'i',
    'ï': 'i',
    'ô': 'o',
    'ö': 'o',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ç': 'c',
    'œ': 'oe',
    'æ': 'ae',
  };
  final lower = name.toLowerCase().split('').map((c) => accents[c] ?? c).join();
  final slug = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return '${slug.isEmpty ? 'balade' : slug}.gpx';
}

String _c(double v) => v.toStringAsFixed(6);

String _time(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

// -----------------------------------------------------------------------------
// Import
// -----------------------------------------------------------------------------

/// Point lu dans un GPX.
class GpxPoint {
  const GpxPoint(this.lat, this.lng, {this.elevation, this.time, this.name});

  final double lat;
  final double lng;
  final double? elevation;
  final DateTime? time;
  final String? name;

  GeoPoint get point => GeoPoint(lat, lng);
}

/// Contenu d'un fichier GPX.
class GpxData {
  const GpxData({
    this.name,
    this.description,
    this.tracks = const [],
    this.routes = const [],
    this.waypoints = const [],
  });

  final String? name;
  final String? description;

  /// Segments de traces (trk/trkseg).
  final List<List<GpxPoint>> tracks;

  /// Itinéraires (rte).
  final List<List<GpxPoint>> routes;
  final List<GpxPoint> waypoints;

  bool get isEmpty => tracks.every((t) => t.isEmpty) && routes.every((r) => r.isEmpty) && waypoints.length < 2;

  int get trackPointCount => tracks.fold(0, (s, t) => s + t.length);
}

class GpxFormatException implements Exception {
  const GpxFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Lit un fichier GPX (1.0 ou 1.1, avec ou sans espace de noms).
GpxData parseGpx(String source) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(source.trimLeft().replaceFirst('﻿', ''));
  } on XmlException {
    throw const GpxFormatException("Ce fichier n'est pas un GPX valide.");
  }
  final root = doc.rootElement;
  if (root.localName != 'gpx') {
    throw const GpxFormatException("Ce fichier n'est pas un GPX (balise <gpx> absente).");
  }

  String? text(XmlElement parent, String name) {
    final e = parent.findElements(name, namespaceUri: '*').firstOrNull;
    final t = e?.innerText.trim();
    return t == null || t.isEmpty ? null : t;
  }

  GpxPoint? point(XmlElement e) {
    final lat = double.tryParse(e.getAttribute('lat') ?? '');
    final lng = double.tryParse(e.getAttribute('lon') ?? '');
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) return null;
    final ele = double.tryParse(text(e, 'ele') ?? '');
    final timeStr = text(e, 'time');
    return GpxPoint(
      lat,
      lng,
      elevation: ele,
      time: timeStr == null ? null : DateTime.tryParse(timeStr)?.toUtc(),
      name: text(e, 'name'),
    );
  }

  final metadata = root.findElements('metadata', namespaceUri: '*').firstOrNull;
  String? name = metadata == null ? null : text(metadata, 'name');
  String? desc = metadata == null ? null : (text(metadata, 'desc') ?? text(metadata, 'description'));
  // GPX 1.0 : name/desc directement sous <gpx>.
  name ??= text(root, 'name');
  desc ??= text(root, 'desc');

  final tracks = <List<GpxPoint>>[];
  for (final trk in root.findElements('trk', namespaceUri: '*')) {
    name ??= text(trk, 'name');
    desc ??= text(trk, 'desc');
    for (final seg in trk.findElements('trkseg', namespaceUri: '*')) {
      final pts = [for (final e in seg.findElements('trkpt', namespaceUri: '*')) ?point(e)];
      if (pts.isNotEmpty) tracks.add(pts);
    }
  }
  final routes = <List<GpxPoint>>[];
  for (final rte in root.findElements('rte', namespaceUri: '*')) {
    name ??= text(rte, 'name');
    desc ??= text(rte, 'desc');
    final pts = [for (final e in rte.findElements('rtept', namespaceUri: '*')) ?point(e)];
    if (pts.isNotEmpty) routes.add(pts);
  }
  final wpts = [for (final e in root.findElements('wpt', namespaceUri: '*')) ?point(e)];

  return GpxData(name: name, description: desc, tracks: tracks, routes: routes, waypoints: wpts);
}

/// Résultat d'un import GPX.
class GpxImport {
  const GpxImport({required this.route, required this.sparse, required this.data});

  final PlannedRoute route;

  /// Vrai si le fichier ne contient que des points épars (rte / wpt) : il
  /// vaut mieux recalculer l'itinéraire en suivant les routes.
  final bool sparse;
  final GpxData data;
}

/// Espacement moyen au-delà duquel une géométrie est considérée « éparse ».
const sparseSpacingM = 300.0;

/// Convertit un GPX en balade planifiée (source gpx).
GpxImport gpxToPlannedRoute(GpxData data, {String? fallbackName, String? id, DateTime? now}) {
  final fromTrack = data.trackPointCount >= 2;
  final List<GpxPoint> pts;
  if (fromTrack) {
    pts = [for (final seg in data.tracks) ...seg];
  } else if (data.routes.any((r) => r.length >= 2)) {
    pts = [for (final r in data.routes) ...r];
  } else if (data.waypoints.length >= 2) {
    pts = data.waypoints;
  } else {
    throw const GpxFormatException('Ce GPX ne contient ni trace ni itinéraire exploitable.');
  }
  // Supprime les doublons consécutifs.
  final points = <GeoPoint>[];
  final elevations = <double>[];
  for (final p in pts) {
    final g = p.point;
    if (points.isNotEmpty && Geo.distance(points.last, g) < 0.5) continue;
    points.add(g);
    if (p.elevation != null) elevations.add(p.elevation!);
  }
  if (points.length < 2) {
    throw const GpxFormatException('Ce GPX ne contient pas assez de points.');
  }
  final distance = Geo.length(points);
  final spacing = distance / (points.length - 1);
  final sparse = !fromTrack && spacing > sparseSpacingM;

  // Durée : horodatage de la trace si plausible, sinon ~55 km/h de moyenne.
  var durationS = (distance / 1000 / 55 * 3600).round();
  if (fromTrack) {
    final times = pts.map((p) => p.time).whereType<DateTime>().toList();
    if (times.length >= 2) {
      final s = times.last.difference(times.first).inSeconds;
      if (s > 60 && s < 48 * 3600) {
        final avg = distance / s * 3.6;
        if (avg > 10 && avg < 160) durationS = s;
      }
    }
  }

  final gain = elevations.length >= points.length * 0.6
      ? RouteScoring.elevationStats(elevations, hysteresisM: fromTrack ? 5 : 2).gainM
      : 0.0;

  final waypoints = data.routes.any((r) => r.length >= 2)
      ? [
          for (final r in data.routes)
            for (final p in r) p.point,
        ]
      : (data.waypoints.length >= 2 && !fromTrack
            ? [for (final w in data.waypoints) w.point]
            : [points.first, points.last]);

  final name = (data.name?.trim().isNotEmpty ?? false)
      ? data.name!.trim()
      : (fallbackName?.trim().isNotEmpty ?? false)
      ? fallbackName!.trim()
      : 'Balade importée';

  final route = PlannedRoute(
    id: id ?? const Uuid().v4(),
    name: name,
    createdAt: (now ?? DateTime.now()).toUtc(),
    points: points,
    style: RouteStyle.mixte,
    source: RouteSource.gpx,
    waypoints: waypoints,
    distanceM: distance,
    durationS: durationS,
    curvatureScore: sparse ? 0 : RouteScoring.curvatureScore(points),
    elevationGainM: gain,
    description: data.description ?? '',
  );
  return GpxImport(route: route, sparse: sparse, data: data);
}

/// Lit un fichier GPX et le convertit (raccourci de [parseGpx] + [gpxToPlannedRoute]).
GpxImport importGpx(String source, {String? fileName}) {
  final data = parseGpx(source);
  final base = fileName?.replaceAll(RegExp(r'\.gpx$', caseSensitive: false), '').replaceAll(RegExp(r'[_-]+'), ' ');
  return gpxToPlannedRoute(data, fallbackName: base);
}
