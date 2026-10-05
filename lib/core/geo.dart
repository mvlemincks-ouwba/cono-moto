import 'dart:math' as math;

/// Point géographique (WGS84). Type neutre utilisé par toute la logique métier,
/// indépendant de la librairie de carte.
class GeoPoint {
  const GeoPoint(this.lat, this.lng);

  final double lat;
  final double lng;

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};

  factory GeoPoint.fromJson(Map<String, dynamic> json) =>
      GeoPoint((json['lat'] as num).toDouble(), (json['lng'] as num).toDouble());

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint(${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)})';
}

/// Rectangle géographique.
class GeoBounds {
  const GeoBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final double south;
  final double west;
  final double north;
  final double east;

  GeoPoint get center => GeoPoint((south + north) / 2, (west + east) / 2);

  bool contains(GeoPoint p) =>
      p.lat >= south && p.lat <= north && p.lng >= west && p.lng <= east;

  /// Rectangle centré sur [center] de demi-côté [radiusM] mètres.
  factory GeoBounds.around(GeoPoint center, double radiusM) {
    final dLat = radiusM / Geo.metersPerDegreeLat;
    final dLng = radiusM /
        (Geo.metersPerDegreeLat * math.cos(center.lat * math.pi / 180).abs().clamp(0.01, 1.0));
    return GeoBounds(
      south: center.lat - dLat,
      west: center.lng - dLng,
      north: center.lat + dLat,
      east: center.lng + dLng,
    );
  }

  static GeoBounds? fromPoints(Iterable<GeoPoint> points) {
    final it = points.iterator;
    if (!it.moveNext()) return null;
    var s = it.current.lat, n = it.current.lat, w = it.current.lng, e = it.current.lng;
    while (it.moveNext()) {
      final p = it.current;
      s = math.min(s, p.lat);
      n = math.max(n, p.lat);
      w = math.min(w, p.lng);
      e = math.max(e, p.lng);
    }
    return GeoBounds(south: s, west: w, north: n, east: e);
  }

  GeoBounds expand(double meters) {
    final dLat = meters / Geo.metersPerDegreeLat;
    final dLng = meters /
        (Geo.metersPerDegreeLat * math.cos(center.lat * math.pi / 180).abs().clamp(0.01, 1.0));
    return GeoBounds(
      south: south - dLat,
      west: west - dLng,
      north: north + dLat,
      east: east + dLng,
    );
  }

  @override
  String toString() => 'GeoBounds($south,$west,$north,$east)';
}

/// Résultat d'une projection d'un point sur une polyligne.
class PolylineProjection {
  const PolylineProjection({
    required this.point,
    required this.segmentIndex,
    required this.distanceFromLineM,
    required this.distanceAlongM,
  });

  /// Point projeté sur la ligne.
  final GeoPoint point;

  /// Index du segment [i, i+1] le plus proche.
  final int segmentIndex;

  /// Distance entre le point d'origine et la ligne.
  final double distanceFromLineM;

  /// Distance parcourue depuis le début de la ligne jusqu'au point projeté.
  final double distanceAlongM;
}

/// Fonctions géographiques pures (testables sans plateforme).
class Geo {
  Geo._();

  static const double earthRadiusM = 6371008.8;
  static const double metersPerDegreeLat = 111320.0;
  static const double g = 9.80665;

  static double _rad(double deg) => deg * math.pi / 180.0;
  static double _deg(double rad) => rad * 180.0 / math.pi;

  /// Distance orthodromique (haversine) en mètres.
  static double distance(GeoPoint a, GeoPoint b) {
    final dLat = _rad(b.lat - a.lat);
    final dLng = _rad(b.lng - a.lng);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(h)));
  }

  /// Cap initial de [a] vers [b] en degrés (0 = nord, sens horaire), dans [0, 360).
  static double bearing(GeoPoint a, GeoPoint b) {
    final phi1 = _rad(a.lat);
    final phi2 = _rad(b.lat);
    final dLng = _rad(b.lng - a.lng);
    final y = math.sin(dLng) * math.cos(phi2);
    final x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(dLng);
    return (_deg(math.atan2(y, x)) + 360) % 360;
  }

  /// Différence signée entre deux caps, dans [-180, 180). Positif = virage à droite.
  static double headingDelta(double from, double to) {
    var d = (to - from) % 360;
    if (d >= 180) d -= 360;
    if (d < -180) d += 360;
    return d;
  }

  /// Point atteint depuis [start] en suivant [bearingDeg] sur [distanceM].
  static GeoPoint destination(GeoPoint start, double bearingDeg, double distanceM) {
    final delta = distanceM / earthRadiusM;
    final theta = _rad(bearingDeg);
    final phi1 = _rad(start.lat);
    final lambda1 = _rad(start.lng);
    final phi2 = math.asin(
        math.sin(phi1) * math.cos(delta) + math.cos(phi1) * math.sin(delta) * math.cos(theta));
    final lambda2 = lambda1 +
        math.atan2(math.sin(theta) * math.sin(delta) * math.cos(phi1),
            math.cos(delta) - math.sin(phi1) * math.sin(phi2));
    return GeoPoint(_deg(phi2), ((_deg(lambda2) + 540) % 360) - 180);
  }

  /// Longueur totale d'une polyligne en mètres.
  static double length(List<GeoPoint> points) {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += distance(points[i - 1], points[i]);
    }
    return total;
  }

  /// Distances cumulées depuis le début pour chaque sommet.
  static List<double> cumulativeDistances(List<GeoPoint> points) {
    final out = List<double>.filled(points.length, 0);
    for (var i = 1; i < points.length; i++) {
      out[i] = out[i - 1] + distance(points[i - 1], points[i]);
    }
    return out;
  }

  /// Projette [p] sur la polyligne. Approximation plane locale (précise à
  /// quelques cm pour des segments de quelques km).
  static PolylineProjection? project(GeoPoint p, List<GeoPoint> line, {List<double>? cumulative}) {
    if (line.isEmpty) return null;
    if (line.length == 1) {
      return PolylineProjection(
        point: line.first,
        segmentIndex: 0,
        distanceFromLineM: distance(p, line.first),
        distanceAlongM: 0,
      );
    }
    final cum = cumulative ?? cumulativeDistances(line);
    final cosLat = math.cos(_rad(p.lat));
    double bestDist = double.infinity;
    var bestIdx = 0;
    var bestT = 0.0;
    for (var i = 0; i < line.length - 1; i++) {
      final a = line[i];
      final b = line[i + 1];
      final ax = (a.lng - p.lng) * cosLat;
      final ay = a.lat - p.lat;
      final bx = (b.lng - p.lng) * cosLat;
      final by = b.lat - p.lat;
      final dx = bx - ax;
      final dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 == 0 ? 0.0 : -(ax * dx + ay * dy) / len2;
      t = t.clamp(0.0, 1.0);
      final cx = ax + t * dx;
      final cy = ay + t * dy;
      final d2 = cx * cx + cy * cy;
      if (d2 < bestDist) {
        bestDist = d2;
        bestIdx = i;
        bestT = t;
      }
    }
    final a = line[bestIdx];
    final b = line[bestIdx + 1];
    final proj = GeoPoint(a.lat + (b.lat - a.lat) * bestT, a.lng + (b.lng - a.lng) * bestT);
    final segLen = cum[bestIdx + 1] - cum[bestIdx];
    return PolylineProjection(
      point: proj,
      segmentIndex: bestIdx,
      distanceFromLineM: distance(p, proj),
      distanceAlongM: cum[bestIdx] + segLen * bestT,
    );
  }

  /// Point situé à [distanceM] le long de la polyligne.
  static GeoPoint pointAtDistance(List<GeoPoint> line, double distanceM, {List<double>? cumulative}) {
    if (line.isEmpty) throw ArgumentError('ligne vide');
    if (distanceM <= 0) return line.first;
    final cum = cumulative ?? cumulativeDistances(line);
    if (distanceM >= cum.last) return line.last;
    var lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= distanceM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final segLen = cum[hi] - cum[lo];
    final t = segLen == 0 ? 0.0 : (distanceM - cum[lo]) / segLen;
    final a = line[lo], b = line[hi];
    return GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);
  }

  /// Simplification Douglas-Peucker (tolérance en mètres).
  static List<GeoPoint> simplify(List<GeoPoint> points, double toleranceM) {
    if (points.length < 3) return List.of(points);
    final keep = List<bool>.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;
    final stack = <List<int>>[
      [0, points.length - 1]
    ];
    while (stack.isNotEmpty) {
      final range = stack.removeLast();
      final start = range[0], end = range[1];
      if (end <= start + 1) continue;
      var maxD = 0.0;
      var idx = start;
      final seg = [points[start], points[end]];
      for (var i = start + 1; i < end; i++) {
        final d = project(points[i], seg)!.distanceFromLineM;
        if (d > maxD) {
          maxD = d;
          idx = i;
        }
      }
      if (maxD > toleranceM) {
        keep[idx] = true;
        stack.add([start, idx]);
        stack.add([idx, end]);
      }
    }
    return [
      for (var i = 0; i < points.length; i++)
        if (keep[i]) points[i]
    ];
  }

  /// Rééchantillonne une polyligne à pas constant (mètres).
  static List<GeoPoint> resample(List<GeoPoint> line, double stepM) {
    if (line.length < 2) return List.of(line);
    final cum = cumulativeDistances(line);
    final total = cum.last;
    final out = <GeoPoint>[];
    for (var d = 0.0; d < total; d += stepM) {
      out.add(pointAtDistance(line, d, cumulative: cum));
    }
    out.add(line.last);
    return out;
  }

  /// Encode une polyligne au format Google (précision 1e5 par défaut).
  static String encodePolyline(List<GeoPoint> points, {int precision = 5}) {
    final factor = math.pow(10, precision);
    final sb = StringBuffer();
    var lastLat = 0, lastLng = 0;
    for (final p in points) {
      final lat = (p.lat * factor).round();
      final lng = (p.lng * factor).round();
      _encodeValue(lat - lastLat, sb);
      _encodeValue(lng - lastLng, sb);
      lastLat = lat;
      lastLng = lng;
    }
    return sb.toString();
  }

  static void _encodeValue(int v, StringBuffer sb) {
    var value = v < 0 ? ~(v << 1) : (v << 1);
    while (value >= 0x20) {
      sb.writeCharCode((0x20 | (value & 0x1f)) + 63);
      value >>= 5;
    }
    sb.writeCharCode(value + 63);
  }

  /// Décode une polyligne Google (précision 5) ou Valhalla (précision 6).
  static List<GeoPoint> decodePolyline(String encoded, {int precision = 5}) {
    final factor = math.pow(10, precision).toDouble();
    final out = <GeoPoint>[];
    var index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      for (var k = 0; k < 2; k++) {
        var shift = 0, result = 0, b = 0;
        do {
          b = encoded.codeUnitAt(index++) - 63;
          result |= (b & 0x1f) << shift;
          shift += 5;
        } while (b >= 0x20 && index < encoded.length);
        final delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
        if (k == 0) {
          lat += delta;
        } else {
          lng += delta;
        }
      }
      out.add(GeoPoint(lat / factor, lng / factor));
    }
    return out;
  }
}
