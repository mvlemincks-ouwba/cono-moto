// Logique pure du plan de navigation (sans plateforme, testée dans
// test/navigation/) : caméra, découpage parcouru / restant, heure d'arrivée,
// distances affichées, incidents devant moi, anti-spam du recalcul.
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/painting.dart' show EdgeInsets;

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/shared.dart';
import '../traffic/traffic_providers.dart' show IncidentAhead, incidentsAhead;

// =============================================================================
// Caméra
// =============================================================================

/// Réglages de la caméra « façon GPS » : cap en haut, inclinée, zoom qui
/// s'éloigne avec la vitesse, motard dans le tiers bas de l'écran.
class NavCamera {
  NavCamera._();

  /// Inclinaison de la caméra (degrés).
  static const tilt = 55.0;

  /// Zoom selon la vitesse (km/h → niveau de zoom), interpolé linéairement.
  static const _speedZoom = <(double, double)>[(0, 17.2), (20, 17.2), (50, 16.4), (80, 15.7), (110, 15.1), (130, 14.8)];

  /// Zoom minimal à l'approche d'une manœuvre (on voit bien le carrefour).
  static const maneuverZoom = 16.6;

  /// Distance sous laquelle on zoome sur la manœuvre qui arrive.
  static const maneuverZoomM = 300.0;

  /// Zoom adapté à la vitesse : proche en ville, plus large sur voie rapide,
  /// resserré à l'approche d'une manœuvre.
  static double zoomForSpeed(double kmh, {double? distanceToManeuverM}) {
    final v = kmh.isFinite ? kmh.clamp(0.0, 250.0).toDouble() : 0.0;
    var z = _speedZoom.last.$2;
    for (var i = 1; i < _speedZoom.length; i++) {
      final (s1, z1) = _speedZoom[i];
      if (v <= s1) {
        final (s0, z0) = _speedZoom[i - 1];
        final t = s1 == s0 ? 0.0 : (v - s0) / (s1 - s0);
        z = z0 + (z1 - z0) * t;
        break;
      }
    }
    final d = distanceToManeuverM;
    if (d != null && d >= 0 && d < maneuverZoomM) z = math.max(z, maneuverZoom);
    return z;
  }

  /// Rapproche le zoom courant de la cible sans « pomper » : rien sous
  /// [deadband], au plus [maxStep] par mise à jour.
  static double smoothZoom(double? current, double target, {double maxStep = 0.3, double deadband = 0.12}) {
    if (current == null || !current.isFinite) return target;
    final d = target - current;
    if (d.abs() < deadband) return current;
    return current + d.clamp(-maxStep, maxStep);
  }

  /// Moyenne glissante de la vitesse (le GPS saute de quelques km/h).
  static double smoothSpeed(double? previous, double kmh, {double alpha = 0.35}) {
    final v = kmh.isFinite ? math.max(0.0, kmh) : 0.0;
    if (previous == null || !previous.isFinite) return v;
    return previous + (v - previous) * alpha;
  }

  /// Cap de la caméra : celui du GPS dès qu'on roule, sinon le dernier connu
  /// (à l'arrêt, le cap GPS part dans tous les sens).
  static double? bearingFor({double? heading, required double speedKmh, double? previous, double minSpeedKmh = 7}) {
    if (heading != null && heading.isFinite && speedKmh >= minSpeedKmh) return heading % 360;
    return previous;
  }

  /// Marges de contenu pour placer le motard vers le bas de l'écran
  /// ([fraction] de la hauteur), au-dessus du panneau du bas.
  ///
  /// Avec une marge haute `t`, le point focal est à `(h + t) / 2`.
  static EdgeInsets riderInsets(Size size, {double bottomOverlay = 0, double leftOverlay = 0, double fraction = 0.7}) {
    final h = size.height;
    if (!h.isFinite || h <= 0) return EdgeInsets.zero;
    var y = h * fraction;
    final maxY = h - bottomOverlay - 70;
    if (y > maxY) y = maxY;
    if (y < h * 0.5) y = h * 0.5;
    final top = (2 * y - h).clamp(0.0, h * 0.8).toDouble();
    final left = leftOverlay.clamp(0.0, math.max(0.0, size.width * 0.6)).toDouble();
    return EdgeInsets.only(top: top, left: left);
  }
}

// =============================================================================
// Itinéraire parcouru / restant
// =============================================================================

/// Itinéraire coupé à la position du motard.
class RouteSplit {
  const RouteSplit(this.done, this.remaining);

  /// Partie déjà parcourue (grisée).
  final List<GeoPoint> done;

  /// Partie restante (orange), commence à la position projetée.
  final List<GeoPoint> remaining;
}

/// Coupe [points] à [progressM] mètres du départ.
RouteSplit splitRoute(List<GeoPoint> points, double progressM, {List<double>? cumulative}) {
  if (points.length < 2) return RouteSplit(const [], List.unmodifiable(points));
  final cum = cumulative ?? Geo.cumulativeDistances(points);
  final total = cum.last;
  if (!progressM.isFinite || progressM <= 0) return RouteSplit(const [], points);
  if (progressM >= total) return RouteSplit(points, const []);
  var lo = 0, hi = cum.length - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (cum[mid] <= progressM) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final cut = Geo.pointAtDistance(points, progressM, cumulative: cum);
  final onVertex = cum[lo] == progressM;
  return RouteSplit(
    [...points.sublist(0, lo + 1), if (!onVertex) cut],
    [if (!onVertex) cut, ...points.sublist(onVertex ? lo : lo + 1)],
  );
}

/// Géométrie d'affichage d'un itinéraire : allégée (moins de points envoyés à
/// la carte à chaque seconde), avec ses distances cumulées.
class NavRouteGeometry {
  NavRouteGeometry(this.route, {double toleranceM = 3})
    : points = route.points.length > 400 ? Geo.simplify(route.points, toleranceM) : route.points {
    cumulative = Geo.cumulativeDistances(points);
    final original = route.points.length > 400 ? Geo.length(route.points) : cumulative.last;
    _ratio = original <= 0 ? 1 : cumulative.last / original;
  }

  final PlannedRoute route;
  final List<GeoPoint> points;
  late final List<double> cumulative;
  late final double _ratio;

  /// Distance sur la géométrie allégée correspondant à [progressM], mesuré
  /// sur la géométrie d'origine (moteur de guidage).
  double displayDistance(double progressM) => progressM * _ratio;

  RouteSplit split(double progressM) => splitRoute(points, displayDistance(progressM), cumulative: cumulative);

  /// Partie restante (ex : stations essence sur la route devant moi).
  List<GeoPoint> ahead(double progressM) {
    final s = split(progressM);
    return s.remaining.length >= 2 ? s.remaining : points;
  }
}

// =============================================================================
// Heure d'arrivée
// =============================================================================

/// Ce qu'il reste à rouler.
class NavEta {
  const NavEta({required this.remainingM, required this.remaining, required this.arrival});

  final double remainingM;
  final Duration remaining;
  final DateTime arrival;

  /// Temps restant au prorata de la durée prévue par le calcul d'itinéraire,
  /// à défaut à [fallbackSpeedKmh] de moyenne.
  static NavEta compute({
    required double remainingM,
    required double totalM,
    required int routeDurationS,
    required DateTime now,
    double fallbackSpeedKmh = 55,
  }) {
    final r = remainingM.isFinite ? math.max(0.0, remainingM) : 0.0;
    final secs = routeDurationS > 0 && totalM > 0
        ? routeDurationS * (math.min(r, totalM) / totalM)
        : r / (fallbackSpeedKmh / 3.6);
    final d = Duration(seconds: secs.round());
    return NavEta(remainingM: r, remaining: d, arrival: now.add(d));
  }
}

// =============================================================================
// Affichage
// =============================================================================

/// Distance d'une manœuvre en (valeur, unité) pour les très gros chiffres :
/// « 80 m », « 350 m », « 1,2 km », « 12 km ».
(String, String) maneuverDistanceParts(double meters) {
  final m = meters.isFinite ? math.max(0.0, meters) : 0.0;
  if (m < 995) {
    final step = m < 300 ? 10 : 50;
    final r = (m / step).round() * step;
    if (r < 1000) return ('$r', 'm');
  }
  if (m < 9950) {
    var v = Fmt.number(m / 1000, decimals: 1);
    if (v.endsWith(',0')) v = v.substring(0, v.length - 2);
    return (v, 'km');
  }
  return (Fmt.number(m / 1000), 'km');
}

/// « 350 m », « 1,2 km » (même arrondi que le bandeau).
String navDistance(double meters) {
  final (v, u) = maneuverDistanceParts(meters);
  return '$v $u';
}

/// Numéro de sortie d'un rond-point lu dans la consigne (« … prends la 2e
/// sortie … » → 2), null sinon.
int? roundaboutExitNumber(String instruction) {
  final m = RegExp(r'(\d+)\s*(?:e|è|ème|eme|re|ère|er)\s+sortie', caseSensitive: false).firstMatch(instruction);
  if (m == null) return null;
  final n = int.tryParse(m.group(1)!);
  return n == null || n <= 0 || n > 12 ? null : n;
}

/// Texte du bandeau incident : « Travaux dans 3,2 km ».
String incidentAheadText(IncidentAhead a) {
  if (a.distanceAheadM < 60) return '${a.incident.kind.label} ici';
  return '${a.incident.kind.label} dans ${navDistance(a.distanceAheadM)}';
}

/// Incidents de circulation sur l'itinéraire, situés une fois pour toutes le
/// long du tracé, puis distance live depuis ma progression.
class RouteIncidents {
  RouteIncidents._();

  /// Incidents à moins de [corridorM] du tracé, avec leur position le long
  /// de l'itinéraire (`distanceAheadM` = distance depuis le départ), triés.
  static List<IncidentAhead> locate(List<GeoPoint> route, List<TrafficIncident> incidents, {double corridorM = 150}) =>
      incidentsAhead(
        route: route,
        myDistanceAlongM: 0,
        incidents: incidents,
        corridorM: corridorM,
        horizonM: double.infinity,
      );

  /// Prochain incident devant moi (à moins de [horizonM]).
  static IncidentAhead? next(
    List<IncidentAhead> located,
    double progressM, {
    double horizonM = 30000,
    double behindM = 30,
  }) {
    for (final a in located) {
      final d = a.distanceAheadM - progressM;
      if (d < -behindM) continue;
      if (d > horizonM) return null;
      return IncidentAhead(a.incident, math.max(0, d));
    }
    return null;
  }
}

// =============================================================================
// Recalcul automatique : anti-spam
// =============================================================================

/// Limite les recalculs (le serveur Valhalla public est partagé, ~1 req/s) :
/// au plus une tentative toutes les [minInterval], et [maxInWindow] par
/// [window].
class RerouteThrottle {
  RerouteThrottle({
    this.minInterval = const Duration(seconds: 20),
    this.window = const Duration(minutes: 5),
    this.maxInWindow = 3,
  });

  final Duration minInterval;
  final Duration window;
  final int maxInWindow;
  final List<DateTime> _attempts = [];

  List<DateTime> get attempts => List.unmodifiable(_attempts);

  /// Délai avant la prochaine tentative autorisée (zéro = maintenant).
  Duration waitBefore(DateTime now) {
    _attempts.removeWhere((t) => now.difference(t) >= window);
    var wait = Duration.zero;
    if (_attempts.isNotEmpty) {
      final sinceLast = now.difference(_attempts.last);
      if (sinceLast < minInterval) wait = minInterval - sinceLast;
    }
    if (_attempts.length >= maxInWindow) {
      final freeAt = _attempts[_attempts.length - maxInWindow].add(window);
      final w = freeAt.difference(now);
      if (w > wait) wait = w;
    }
    return wait.isNegative ? Duration.zero : wait;
  }

  bool canAttempt(DateTime now) => waitBefore(now) == Duration.zero;

  void record(DateTime now) => _attempts.add(now);

  void reset() => _attempts.clear();
}

/// Décide quand relancer le calcul d'itinéraire tout seul : hors itinéraire
/// depuis au moins [grace] (le temps d'un demi-tour), pas d'arrivée, pas de
/// calcul en cours, et l'anti-spam d'accord.
class AutoReroutePolicy {
  AutoReroutePolicy({this.grace = const Duration(seconds: 4), RerouteThrottle? throttle})
    : throttle = throttle ?? RerouteThrottle();

  final Duration grace;
  final RerouteThrottle throttle;
  DateTime? _offSince;

  DateTime? get offRouteSince => _offSince;

  /// À appeler à chaque position ; true = lancer un recalcul maintenant (la
  /// tentative est alors comptée).
  bool onSnapshot({required bool offRoute, required bool arrived, required DateTime at, bool busy = false}) {
    if (!offRoute || arrived) {
      _offSince = null;
      return false;
    }
    final since = _offSince ??= at;
    if (busy) return false;
    if (at.difference(since) < grace) return false;
    if (!throttle.canAttempt(at)) return false;
    throttle.record(at);
    return true;
  }

  /// Recalcul lancé à la main : compte dans l'anti-spam.
  void recordManual(DateTime at) => throttle.record(at);

  void reset() {
    _offSince = null;
    throttle.reset();
  }
}
