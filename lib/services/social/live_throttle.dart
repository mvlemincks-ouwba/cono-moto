import '../../core/geo.dart';

/// Décide quand republier sa position en direct (économie de bande passante
/// sur l'offre gratuite Firebase).
///
/// Règle : on publie dès que 5 s se sont écoulées OU qu'on a bougé de 50 m,
/// mais jamais plus d'une fois toutes les 2 s (anti-rafale à haute vitesse).
class LiveThrottle {
  LiveThrottle({
    this.maxInterval = const Duration(seconds: 5),
    this.minInterval = const Duration(seconds: 2),
    this.minDistanceM = 50,
  });

  final Duration maxInterval;
  final Duration minInterval;
  final double minDistanceM;

  GeoPoint? _lastPoint;
  DateTime? _lastTime;

  DateTime? get lastPublishedAt => _lastTime;

  bool shouldPublish(GeoPoint point, DateTime time) {
    final lp = _lastPoint;
    final lt = _lastTime;
    if (lp == null || lt == null) return true;
    final dt = time.difference(lt);
    if (dt < Duration.zero) return true; // horloge revenue en arrière
    if (dt < minInterval) return false;
    if (dt >= maxInterval) return true;
    return Geo.distance(lp, point) >= minDistanceM;
  }

  void markPublished(GeoPoint point, DateTime time) {
    _lastPoint = point;
    _lastTime = time;
  }

  /// Applique la règle et mémorise la publication si elle est due.
  bool check(GeoPoint point, DateTime time) {
    if (!shouldPublish(point, time)) return false;
    markPublished(point, time);
    return true;
  }

  void reset() {
    _lastPoint = null;
    _lastTime = null;
  }
}

/// Traînée récente (pour la page de suivi web) : points espacés, bornés en
/// nombre et en âge.
class TrailBuffer {
  TrailBuffer({this.maxPoints = 240, this.minSpacingM = 40, this.maxAge = const Duration(hours: 3)});

  final int maxPoints;
  final double minSpacingM;
  final Duration maxAge;

  final List<(GeoPoint, DateTime)> _points = [];

  List<GeoPoint> get points => [for (final p in _points) p.$1];

  void add(GeoPoint p, DateTime t) {
    if (_points.isNotEmpty && Geo.distance(_points.last.$1, p) < minSpacingM) return;
    _points.add((p, t));
    _points.removeWhere((e) => t.difference(e.$2) > maxAge);
    if (_points.length > maxPoints) _points.removeRange(0, _points.length - maxPoints);
  }

  /// Polyligne encodée (précision 5) pour la page web.
  String encode() => Geo.encodePolyline(Geo.simplify(points, 8));

  void clear() => _points.clear();
}
