import 'dart:math' as math;

import '../../core/geo.dart';
import '../../data/models/planned_route.dart';
import 'maneuver_kinds.dart';

/// Photo instantanée du guidage.
class GuidanceSnapshot {
  const GuidanceSnapshot({
    required this.progressM,
    required this.totalM,
    required this.distanceFromRouteM,
    required this.offRoute,
    required this.arrived,
    this.next,
    this.nextIndex = -1,
    this.distanceToNextM,
    this.following,
    this.then,
    this.snapped,
    this.announcement,
  });

  /// Distance parcourue le long de l'itinéraire.
  final double progressM;
  final double totalM;

  /// Écart entre la position et l'itinéraire.
  final double distanceFromRouteM;
  final bool offRoute;
  final bool arrived;

  /// Prochaine manœuvre (null si plus rien).
  final Maneuver? next;
  final int nextIndex;
  final double? distanceToNextM;

  /// Manœuvre qui suit la prochaine dans la liste (brute).
  final Maneuver? following;

  /// Manœuvre à afficher en « puis … » : rapprochée de la prochaine et utile
  /// (ni sortie de rond-point déjà annoncée, ni simple « continue »). Null sinon.
  final Maneuver? then;

  /// Position projetée sur l'itinéraire.
  final GeoPoint? snapped;

  /// Phrase à annoncer maintenant (null = rien à dire).
  final String? announcement;

  double get remainingM => math.max(0, totalM - progressM);
}

/// Guidage virage par virage, sans plateforme : projection sur l'itinéraire,
/// prochaine manœuvre, hors-itinéraire, arrivée et annonces vocales.
class GuidanceEngine {
  GuidanceEngine(
    this.route, {
    this.offRouteThresholdM = 60,
    this.backOnRouteM = 40,
    this.offRouteFixes = 3,
    this.farAnnounceM = 500,
    this.nearAnnounceM = 100,
    this.arrivalRadiusM = 40,
    this.maxAccuracyM = 50,
    this.rerouted = false,
  }) : _departAnnounced = rerouted,
       _points = route.points,
       _cum = Geo.cumulativeDistances(route.points),
       _maneuvers = [...route.maneuvers]..sort((a, b) => a.distanceAlongM.compareTo(b.distanceAlongM));

  final PlannedRoute route;
  final double offRouteThresholdM;
  final double backOnRouteM;
  final int offRouteFixes;
  final double farAnnounceM;
  final double nearAnnounceM;
  final double arrivalRadiusM;

  /// Les positions moins précises ne comptent pas pour le hors-itinéraire.
  final double maxAccuracyM;

  /// Itinéraire recalculé en cours de route : pas de « C'est parti ! ».
  final bool rerouted;

  final List<GeoPoint> _points;
  final List<double> _cum;
  final List<Maneuver> _maneuvers;

  double? _progress;
  int _offCount = 0;
  bool _offRoute = false;
  bool _arrived = false;
  bool _departAnnounced;
  final Set<String> _announced = {};

  GuidanceSnapshot? _last;

  /// Dernier état calculé (null avant la première position).
  GuidanceSnapshot? get lastSnapshot => _last;

  double get totalM => _cum.isEmpty ? 0 : _cum.last;
  double get progressM => _progress ?? 0;
  bool get isOffRoute => _offRoute;
  bool get hasArrived => _arrived;
  List<Maneuver> get maneuvers => _maneuvers;

  /// Nouvelle position GPS → état du guidage.
  GuidanceSnapshot update(GeoPoint position, {double? accuracyM, double speedMs = 0}) {
    if (_points.length < 2) {
      return GuidanceSnapshot(
        progressM: 0,
        totalM: 0,
        distanceFromRouteM: _points.isEmpty ? 0 : Geo.distance(position, _points.first),
        offRoute: false,
        arrived: false,
      );
    }
    final proj = _locate(position, speedMs);
    final reliable = accuracyM == null || accuracyM <= maxAccuracyM;
    String? announcement;

    // Hors itinéraire (3 positions de suite à plus de 60 m).
    if (proj.distanceFromLineM > offRouteThresholdM) {
      if (reliable) _offCount++;
      if (_offCount >= offRouteFixes && !_offRoute && !_arrived) {
        _offRoute = true;
        announcement = "Tu as quitté l'itinéraire.";
      }
    } else if (proj.distanceFromLineM <= backOnRouteM) {
      _offCount = 0;
      if (_offRoute) {
        _offRoute = false;
        announcement = "De retour sur l'itinéraire, nickel.";
      }
    }

    // On n'avance la progression que si l'on est sur l'itinéraire.
    if (proj.distanceFromLineM <= offRouteThresholdM || _progress == null) {
      _progress = proj.distanceAlongM;
    }
    final progress = _progress!;

    // Arrivée.
    if (!_arrived) {
      final nearEnd = Geo.distance(position, _points.last) <= arrivalRadiusM;
      if ((progress >= totalM - arrivalRadiusM && proj.distanceFromLineM <= offRouteThresholdM) ||
          (nearEnd && progress >= totalM * 0.5)) {
        _arrived = true;
        _offRoute = false;
        announcement = 'Tu es arrivé ! Bien roulé.';
      }
    }

    // Prochaine manœuvre.
    var nextIndex = -1;
    for (var i = 0; i < _maneuvers.length; i++) {
      final m = _maneuvers[i];
      if (m.type == ManeuverKind.depart) continue;
      if (m.distanceAlongM > progress + 3) {
        nextIndex = i;
        break;
      }
    }
    final next = nextIndex >= 0 ? _maneuvers[nextIndex] : null;
    final following = nextIndex >= 0 && nextIndex + 1 < _maneuvers.length ? _maneuvers[nextIndex + 1] : null;
    final then = thenManeuver(_maneuvers, nextIndex);
    final distToNext = next == null ? null : next.distanceAlongM - progress;

    // Annonces vocales.
    if (announcement == null && !_arrived && !_offRoute) {
      if (!_departAnnounced) {
        _departAnnounced = true;
        final depart = _maneuvers.where((m) => m.type == ManeuverKind.depart).firstOrNull;
        if (progress < 300 && depart != null) {
          final say = _sentence(depart);
          announcement = say.isEmpty ? "C'est parti !" : "C'est parti ! $say";
        }
      }
      if (announcement == null && next != null && distToNext != null) {
        announcement = _maneuverAnnouncement(nextIndex, next, distToNext, speedMs);
      }
    }

    return _last = GuidanceSnapshot(
      progressM: progress,
      totalM: totalM,
      distanceFromRouteM: proj.distanceFromLineM,
      offRoute: _offRoute,
      arrived: _arrived,
      next: next,
      nextIndex: nextIndex,
      distanceToNextM: distToNext,
      following: following,
      then: then,
      snapped: proj.point,
      announcement: announcement,
    );
  }

  String? _maneuverAnnouncement(int index, Maneuver m, double dist, double speedMs) {
    // À vive allure, l'annonce « proche » est un peu plus tôt (≈ 6 s avant).
    final near = math.min(250.0, math.max(nearAnnounceM, speedMs * 6));
    final prevAlong = index > 0 ? _maneuvers[index - 1].distanceAlongM : 0.0;
    final gap = m.distanceAlongM - prevAlong;
    // La sortie de rond-point est déjà annoncée avec l'entrée (« prends la 2e sortie »).
    if (m.type == ManeuverKind.roundaboutExit) return null;
    final sentence = m.type == ManeuverKind.arrive ? 'tu arrives à destination.' : _sentence(m);
    if (sentence.isEmpty) return null;
    final keyFar = '$index-far';
    final keyNear = '$index-near';

    if (dist <= near + 10 && dist > 15) {
      if (_announced.add(keyNear)) {
        _announced.add(keyFar);
        return 'Dans ${spokenDistance(dist)}, $sentence';
      }
      return null;
    }
    if (dist <= farAnnounceM + 20 && dist > near + 60) {
      if (ManeuverKind.isPassive(m.type)) return null;
      // Manœuvre rapprochée : pas d'annonce lointaine juste après la précédente.
      if (gap < near + 80) return null;
      if (_announced.add(keyFar)) return 'Dans ${spokenDistance(dist)}, $sentence';
    }
    return null;
  }

  /// Manœuvre « puis … » après [maneuvers][nextIndex] (liste triée) : la
  /// première manœuvre utile qui suit, si elle arrive à moins de [maxGapM].
  /// La sortie d'un rond-point (annoncée avec l'entrée) et les simples
  /// « continue » sont sautées.
  static Maneuver? thenManeuver(List<Maneuver> maneuvers, int nextIndex, {double maxGapM = 400}) {
    if (nextIndex < 0 || nextIndex >= maneuvers.length) return null;
    final next = maneuvers[nextIndex];
    if (next.type == ManeuverKind.arrive) return null;
    for (var i = nextIndex + 1; i < maneuvers.length; i++) {
      final m = maneuvers[i];
      if (m.distanceAlongM - next.distanceAlongM > maxGapM) return null;
      if (m.type == ManeuverKind.roundaboutExit || m.type == ManeuverKind.depart) continue;
      if (ManeuverKind.isPassive(m.type)) continue;
      return m;
    }
    return null;
  }

  /// Distance prononcée, arrondie (« 500 mètres », « 1,5 kilomètre »).
  static String spokenDistance(double m) {
    if (m >= 950) {
      final km = (m / 500).round() / 2;
      final s = km == km.roundToDouble() ? km.toInt().toString() : km.toString().replaceAll('.', ',');
      return km < 2 ? '$s kilomètre' : '$s kilomètres';
    }
    final step = m > 200 ? 100 : 50;
    final r = math.max(step, (m / step).round() * step);
    return '$r mètres';
  }

  static String _sentence(Maneuver m) {
    final raw = (m.verbalAlert ?? m.instruction).trim();
    if (raw.isEmpty) return '';
    final s = raw[0].toLowerCase() + raw.substring(1);
    return s.endsWith('.') || s.endsWith('!') ? s : '$s.';
  }

  /// Projection avec fenêtre glissante (évite de « sauter » sur le retour
  /// d'une boucle qui repasse au même endroit).
  PolylineProjection _locate(GeoPoint p, double speedMs) {
    final last = _progress;
    if (last == null) {
      final global = Geo.project(p, _points, cumulative: _cum)!;
      if (global.distanceAlongM > totalM * 0.5) {
        final firstHalf = _projectRange(p, 0, totalM * 0.5);
        if (firstHalf != null && firstHalf.distanceFromLineM <= global.distanceFromLineM + 25) {
          return firstHalf;
        }
      }
      return global;
    }
    final ahead = math.max(1500.0, speedMs * 90);
    final window = _projectRange(p, last - 150, last + ahead) ?? Geo.project(p, _points, cumulative: _cum)!;
    if (window.distanceFromLineM <= offRouteThresholdM) return window;
    // Peut-être un raccourci : on cherche plus loin sur l'itinéraire.
    final forward = _projectRange(p, last - 150, totalM);
    if (forward != null && forward.distanceFromLineM <= backOnRouteM) return forward;
    return window;
  }

  PolylineProjection? _projectRange(GeoPoint p, double fromM, double toM) {
    final n = _points.length;
    var i0 = _indexAtOrBefore(math.max(0, fromM));
    var i1 = _indexAtOrBefore(math.min(totalM, toM)) + 1;
    i0 = i0.clamp(0, n - 2);
    i1 = i1.clamp(i0 + 1, n - 1);
    final sub = _points.sublist(i0, i1 + 1);
    final subCum = _cum.sublist(i0, i1 + 1);
    final proj = Geo.project(p, sub, cumulative: subCum);
    if (proj == null) return null;
    return PolylineProjection(
      point: proj.point,
      segmentIndex: proj.segmentIndex + i0,
      distanceFromLineM: proj.distanceFromLineM,
      distanceAlongM: proj.distanceAlongM,
    );
  }

  int _indexAtOrBefore(double d) {
    var lo = 0, hi = _cum.length - 1;
    if (d <= 0) return 0;
    if (d >= _cum[hi]) return hi;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_cum[mid] <= d) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Points à suivre pour recalculer depuis [progressM] : échantillons de la
  /// géométrie restante (≈ tous les 10 km, au plus [maxPoints]), arrivée
  /// incluse, en commençant à [rejoinAheadM] devant.
  List<GeoPoint> remainingViaPoints({double? fromM, int maxPoints = 18, double rejoinAheadM = 1500}) {
    final start = (fromM ?? progressM) + rejoinAheadM;
    final total = totalM;
    if (start >= total - 200) return [_points.last];
    final remaining = total - start;
    var step = 10000.0;
    if (remaining / step + 1 > maxPoints) step = remaining / (maxPoints - 1);
    final out = <GeoPoint>[Geo.pointAtDistance(_points, start, cumulative: _cum)];
    for (var d = start + step; d < total - step * 0.3; d += step) {
      out.add(Geo.pointAtDistance(_points, d, cumulative: _cum));
    }
    out.add(_points.last);
    return out;
  }
}
