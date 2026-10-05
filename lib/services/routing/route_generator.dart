import 'dart:async';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../../core/geo.dart';
import '../../data/models/planned_route.dart';
import 'elevation_client.dart';
import 'geocoder.dart';
import 'http_support.dart';
import 'overpass_client.dart';
import 'route_scoring.dart';
import 'valhalla_client.dart';

/// Ce que le motard demande.
class RouteRequest {
  const RouteRequest({
    required this.start,
    this.startLabel,
    this.destination,
    this.destinationLabel,
    this.targetDistanceKm = 100,
    this.style = RouteStyle.mixte,
    this.avoidHighways = true,
    this.avoidTolls = true,
    this.seed = 0,
    this.departure,
  });

  final GeoPoint start;
  final String? startLabel;

  /// Arrivée (A→B). Null = boucle.
  final GeoPoint? destination;
  final String? destinationLabel;

  /// Distance visée pour une boucle (30–400 km).
  final double targetDistanceKm;
  final RouteStyle style;
  final bool avoidHighways;
  final bool avoidTolls;

  /// Graine du hasard (orientation des boucles).
  final int seed;

  /// Heure de départ prévue (météo).
  final DateTime? departure;

  bool get isLoop => destination == null;

  RouteRequest withSeed(int seed) => copyWith(seed: seed);

  RouteRequest copyWith({String? startLabel, int? seed, DateTime? departure}) => RouteRequest(
    start: start,
    startLabel: startLabel ?? this.startLabel,
    destination: destination,
    destinationLabel: destinationLabel,
    targetDistanceKm: targetDistanceKm,
    style: style,
    avoidHighways: avoidHighways,
    avoidTolls: avoidTolls,
    seed: seed ?? this.seed,
    departure: departure ?? this.departure,
  );
}

/// Une proposition de balade, notée.
class RouteCandidate {
  const RouteCandidate({
    required this.route,
    required this.metrics,
    required this.score,
    required this.badges,
    this.pois = const [],
    this.profile,
  });

  final PlannedRoute route;
  final RouteMetrics metrics;

  /// Adéquation au style demandé (0–100).
  final double score;
  final List<RouteBadge> badges;

  /// Forêts / cols traversés.
  final List<RoutePoi> pois;
  final ElevationProfile? profile;
}

/// Avancement du calcul (pour l'animation de chargement).
class GenerationProgress {
  const GenerationProgress(this.message, this.step, this.totalSteps);

  final String message;
  final int step;
  final int totalSteps;

  double get fraction => totalSteps <= 0 ? 0 : (step / totalSteps).clamp(0, 1).toDouble();
}

class GenerationResult {
  const GenerationResult(this.candidates, {this.notes = const []});

  /// Propositions triées de la meilleure à la moins bonne.
  final List<RouteCandidate> candidates;

  /// Remarques à afficher (« pas de col dans le coin »…).
  final List<String> notes;
}

/// Point de passage prévu, éventuellement accroché à une forêt / un col.
class PlannedVia {
  const PlannedVia(this.point, [this.poi]);

  final GeoPoint point;
  final RoutePoi? poi;
}

class _Plan {
  _Plan({required this.vias, this.radiusM = 0, this.bearing = 0, this.clockwise = true, this.jitterSeed = 0});

  List<PlannedVia> vias;
  double radiusM;
  final double bearing;
  final bool clockwise;
  final int jitterSeed;
}

class _Routed {
  _Routed(this.plan, this.route);

  final _Plan plan;
  final ValhallaRoute route;
}

/// Génère des balades moto : boucles ou A→B, selon le type de tracé.
class RouteGenerator {
  RouteGenerator({
    required this.valhalla,
    this.overpass,
    this.elevation,
    this.geocoder,
    this.candidateCount = 3,
    this.rateLimitPause = const Duration(seconds: 3),
  });

  final ValhallaClient valhalla;
  final OverpassClient? overpass;
  final ElevationClient? elevation;
  final Geocoder? geocoder;
  final int candidateCount;

  /// Pause avant de réessayer quand le serveur répond 429.
  final Duration rateLimitPause;

  static const _uuid = Uuid();

  // ---------------------------------------------------------------------------
  // Géométrie pure (testée)
  // ---------------------------------------------------------------------------

  /// Facteur « route réelle / cercle » selon le style.
  static double tortuosity(RouteStyle style) => switch (style) {
    RouteStyle.sinueux => 1.35,
    RouteStyle.cols => 1.4,
    RouteStyle.rapide => 1.2,
    _ => 1.3,
  };

  /// Rayon du cercle de la boucle : distance / (2π·k).
  static double loopRadiusM(double targetKm, RouteStyle style) => targetKm * 1000 / (2 * math.pi * tortuosity(style));

  /// Nombre de points de passage selon la distance.
  static int viaCount(double targetKm) => targetKm < 80 ? 3 : 4;

  /// Centre du cercle : le départ est sur le cercle, le centre à [radiusM]
  /// dans la direction [bearingDeg].
  static GeoPoint circleCenter(GeoPoint start, double radiusM, double bearingDeg) =>
      Geo.destination(start, bearingDeg, radiusM);

  /// Angles (relatifs au départ, vus du centre) des points de passage.
  static List<double> sectorAngles(int count) => [for (var k = 1; k <= count; k++) k * 360 / (count + 1)];

  /// Points de passage géométriques répartis sur le cercle.
  static List<GeoPoint> loopWaypoints(
    GeoPoint start,
    double radiusM,
    double bearingDeg, {
    int count = 3,
    bool clockwise = true,
    math.Random? jitter,
  }) {
    final center = circleCenter(start, radiusM, bearingDeg);
    final startAngle = (bearingDeg + 180) % 360;
    final dir = clockwise ? 1 : -1;
    return [
      for (final a in sectorAngles(count))
        () {
          final da = jitter == null ? 0.0 : (jitter.nextDouble() - 0.5) * 16;
          final dr = jitter == null ? 1.0 : 1 + (jitter.nextDouble() - 0.5) * 0.2;
          return Geo.destination(center, startAngle + dir * (a + da), radiusM * dr);
        }(),
    ];
  }

  /// Faut-il corriger la boucle (écart > 25 % à la cible) ?
  static bool needsAdjustment(double targetM, double actualM) =>
      targetM > 0 && actualM > 0 && (actualM - targetM).abs() / targetM > 0.25;

  /// Nouveau rayon pour viser la cible (bornes pour éviter les extrêmes).
  static double rescaleRadius(double radiusM, double targetM, double actualM) {
    if (actualM <= 0) return radiusM;
    final k = (targetM / actualM).clamp(0.35, 2.5);
    return radiusM * k;
  }

  /// Choisit, secteur par secteur, la meilleure forêt / le meilleur col proche
  /// du cercle ; sinon garde le point géométrique.
  static List<PlannedVia> planLoopVias(
    GeoPoint start,
    double radiusM,
    double bearingDeg, {
    required int count,
    required bool clockwise,
    List<RoutePoi> pool = const [],
    int jitterSeed = 0,
  }) {
    final geometric = loopWaypoints(
      start,
      radiusM,
      bearingDeg,
      count: count,
      clockwise: clockwise,
      jitter: math.Random(jitterSeed),
    );
    if (pool.isEmpty) return [for (final p in geometric) PlannedVia(p)];
    final center = circleCenter(start, radiusM, bearingDeg);
    final startAngle = (bearingDeg + 180) % 360;
    final dir = clockwise ? 1 : -1;
    final angles = sectorAngles(count);
    final half = 360 / (count + 1) / 2;
    final used = <RoutePoi>[];
    final out = <PlannedVia>[];
    for (var i = 0; i < count; i++) {
      RoutePoi? best;
      var bestScore = double.infinity;
      for (final poi in pool) {
        if (used.any((u) => u.id == poi.id || Geo.distance(u.point, poi.point) < 3000)) continue;
        final d = Geo.distance(center, poi.point);
        final radial = (d - radiusM).abs() / radiusM;
        if (radial > 0.45) continue;
        final rel = ((Geo.bearing(center, poi.point) - startAngle) * dir) % 360;
        final off = (rel - angles[i]).abs();
        if (off > half) continue;
        if (Geo.distance(start, poi.point) < radiusM * 0.25) continue;
        var score = radial + off / half * 0.5;
        if (poi.kind == PoiKind.forest) {
          if (poi.isMajorForest) score -= 0.3;
          score -= math.min(poi.pieces, 5) * 0.03;
        } else if (poi.elevationM != null) {
          score -= (poi.elevationM! / 3000).clamp(0, 1) * 0.2;
        }
        if (score < bestScore) {
          bestScore = score;
          best = poi;
        }
      }
      if (best != null) {
        used.add(best);
        out.add(PlannedVia(best.point, best));
      } else {
        out.add(PlannedVia(geometric[i]));
      }
    }
    return out;
  }

  /// Cols à viser (un par proposition) : à portée de la boucle, les plus
  /// hauts d'abord, dans des directions bien différentes.
  static List<RoutePoi> pickPassTargets(GeoPoint start, double radiusM, List<RoutePoi> pool, int count) {
    final inReach = pool.where((p) {
      final d = Geo.distance(start, p.point);
      return d >= radiusM * 0.3 && d <= radiusM * 1.9;
    }).toList()..sort((a, b) => (b.elevationM ?? 0).compareTo(a.elevationM ?? 0));
    final out = <RoutePoi>[];
    for (final p in inReach) {
      if (out.length >= count) break;
      final b = Geo.bearing(start, p.point);
      if (out.every((o) => Geo.headingDelta(Geo.bearing(start, o.point), b).abs() > 50)) out.add(p);
    }
    return out;
  }

  /// Orientation du cercle (départ → centre) pour que la boucle de rayon
  /// [radiusM] passe par [target].
  static double bearingThrough(GeoPoint start, GeoPoint target, double radiusM, {bool clockwise = true}) {
    final d = Geo.distance(start, target);
    final ratio = (d / (2 * radiusM)).clamp(0.0, 1.0);
    final offset = math.acos(ratio) * 180 / math.pi;
    return (Geo.bearing(start, target) + (clockwise ? -offset : offset) + 360) % 360;
  }

  /// Point de passage décalé sur le côté pour varier un trajet A→B.
  static GeoPoint sideOffset(GeoPoint a, GeoPoint b, {required bool left, double ratio = 0.18}) {
    final d = Geo.distance(a, b);
    final mid = Geo.pointAtDistance([a, b], d / 2);
    final offset = (d * ratio).clamp(3000.0, 40000.0);
    final bearing = Geo.bearing(a, b) + (left ? -90 : 90);
    return Geo.destination(mid, bearing, offset);
  }

  /// Meilleurs POI pour un détour A→B raisonnable, côté gauche puis droit.
  static (RoutePoi?, RoutePoi?) pickAbPois(GeoPoint a, GeoPoint b, List<RoutePoi> pool) {
    final d = Geo.distance(a, b);
    if (d <= 0 || pool.isEmpty) return (null, null);
    RoutePoi? left, right;
    var bestL = double.infinity, bestR = double.infinity;
    final ab = Geo.bearing(a, b);
    for (final p in pool) {
      final detour = (Geo.distance(a, p.point) + Geo.distance(p.point, b)) / d;
      if (detour > 1.4) continue;
      final da = Geo.distance(a, p.point) / d;
      if (da < 0.1 || da > 0.9) continue;
      var score = detour;
      if (p.kind == PoiKind.forest && p.isMajorForest) score -= 0.1;
      final side = Geo.headingDelta(ab, Geo.bearing(a, p.point));
      if (side < 0) {
        if (score < bestL) {
          bestL = score;
          left = p;
        }
      } else if (score < bestR) {
        bestR = score;
        right = p;
      }
    }
    return (left, right);
  }

  // ---------------------------------------------------------------------------
  // Génération
  // ---------------------------------------------------------------------------

  Future<GenerationResult> generate(
    RouteRequest req, {
    void Function(GenerationProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final notes = <String>[];
    final rnd = math.Random(req.seed);
    final costing = MotorcycleCosting.forStyle(req.style, avoidHighways: req.avoidHighways, avoidTolls: req.avoidTolls);
    final wantsPois = (req.style == RouteStyle.foret || req.style == RouteStyle.cols) && overpass != null;
    final totalSteps = (wantsPois ? 1 : 0) + candidateCount + 1;
    var step = 0;
    void progress(String msg) => onProgress?.call(GenerationProgress(msg, step, totalSteps));
    void checkCancel() {
      if (isCancelled?.call() ?? false) throw RoutingException.cancelled;
    }

    // 1. Plans (points de passage) -------------------------------------------
    final plans = <_Plan>[];
    var pool = <RoutePoi>[];
    final targetM = req.targetDistanceKm * 1000;

    if (req.isLoop) {
      final radius = loopRadiusM(req.targetDistanceKm, req.style);
      final n = viaCount(req.targetDistanceKm);
      final baseBearing = rnd.nextDouble() * 360;
      final cw = rnd.nextBool();
      for (var k = 0; k < candidateCount; k++) {
        final bearing = (baseBearing + k * 360 / candidateCount + (rnd.nextDouble() - 0.5) * 30) % 360;
        plans.add(
          _Plan(
            vias: const [],
            radiusM: radius,
            bearing: bearing,
            clockwise: k.isEven ? cw : !cw,
            jitterSeed: rnd.nextInt(1 << 30),
          ),
        );
      }
      if (wantsPois) {
        checkCancel();
        progress(
          req.style == RouteStyle.foret
              ? 'On repère les plus belles forêts du coin…'
              : 'On cherche les cols à portée de roue…',
        );
        pool = await _fetchLoopPois(req, plans, radius, n, notes);
        step++;
      }
      if (req.style == RouteStyle.cols && pool.isNotEmpty) {
        // Les cols sont rares : on oriente chaque boucle pour passer par l'un d'eux.
        final targets = pickPassTargets(req.start, radius, pool, plans.length);
        for (var k = 0; k < targets.length; k++) {
          final p = plans[k];
          plans[k] = _Plan(
            vias: const [],
            radiusM: radius,
            bearing: bearingThrough(req.start, targets[k].point, radius, clockwise: p.clockwise),
            clockwise: p.clockwise,
            jitterSeed: p.jitterSeed,
          );
        }
      }
      for (final p in plans) {
        p.vias = planLoopVias(
          req.start,
          p.radiusM,
          p.bearing,
          count: n,
          clockwise: p.clockwise,
          pool: pool,
          jitterSeed: p.jitterSeed,
        );
      }
      if (wantsPois && pool.isNotEmpty && plans.every((p) => p.vias.every((v) => v.poi == null))) {
        notes.add(
          req.style == RouteStyle.foret
              ? "Pas de forêt nommée bien placée : on t'a quand même trouvé de jolies routes."
              : "Pas de col bien placé pour cette distance : on a visé les routes qui tournent.",
        );
      }
    } else {
      final a = req.start, b = req.destination!;
      if (wantsPois) {
        checkCancel();
        progress(
          req.style == RouteStyle.foret ? 'On repère les forêts sur le chemin…' : 'On cherche des cols sur le chemin…',
        );
        pool = await _fetchAbPois(req, notes);
        step++;
      }
      final (poiL, poiR) = pickAbPois(a, b, pool);
      plans.add(_Plan(vias: const []));
      if (candidateCount > 1) {
        plans.add(
          _Plan(vias: [poiL != null ? PlannedVia(poiL.point, poiL) : PlannedVia(sideOffset(a, b, left: true))]),
        );
      }
      if (candidateCount > 2) {
        plans.add(
          _Plan(vias: [poiR != null ? PlannedVia(poiR.point, poiR) : PlannedVia(sideOffset(a, b, left: false))]),
        );
      }
    }

    // 2. Calculs d'itinéraires (séquentiels : ~1 req/s sur le serveur public) --
    final routed = <_Routed>[];
    final errors = <RoutingException>[];
    const messages = [
      'On trace un premier parcours…',
      "On cherche des virolos dans l'autre sens…",
      'Dernière proposition, on peaufine…',
      'Encore une idée…',
    ];
    for (var i = 0; i < plans.length; i++) {
      checkCancel();
      progress(messages[i.clamp(0, messages.length - 1)]);
      final plan = plans[i];
      try {
        var route = await _routePlan(req, plan, costing);
        if (req.isLoop && needsAdjustment(targetM, route.distanceM)) {
          checkCancel();
          progress(
            route.distanceM > targetM
                ? 'Un poil trop long, on resserre la boucle…'
                : 'Un peu court, on élargit la boucle…',
          );
          final newRadius = rescaleRadius(plan.radiusM, targetM, route.distanceM);
          final retryPlan = _Plan(
            vias: planLoopVias(
              req.start,
              newRadius,
              plan.bearing,
              count: plan.vias.length,
              clockwise: plan.clockwise,
              pool: pool,
              jitterSeed: plan.jitterSeed,
            ),
            radiusM: newRadius,
            bearing: plan.bearing,
            clockwise: plan.clockwise,
            jitterSeed: plan.jitterSeed,
          );
          try {
            final retry = await _routePlan(req, retryPlan, costing);
            if ((retry.distanceM - targetM).abs() < (route.distanceM - targetM).abs()) {
              route = retry;
              plan.vias = retryPlan.vias;
              plan.radiusM = newRadius;
            }
          } on RoutingException catch (e) {
            if (e.kind == RoutingErrorKind.offline || e.kind == RoutingErrorKind.cancelled) rethrow;
          }
        }
        routed.add(_Routed(plan, route));
      } on RoutingException catch (e) {
        if (e.kind == RoutingErrorKind.offline || e.kind == RoutingErrorKind.cancelled) rethrow;
        errors.add(e);
      }
      step++;
    }
    if (routed.isEmpty) {
      throw errors.isNotEmpty
          ? errors.first
          : const RoutingException(
              RoutingErrorKind.noRoute,
              "Aucune balade trouvée. Essaie un autre départ ou une autre distance.",
            );
    }
    if (errors.isNotEmpty) {
      notes.add(
        routed.length == 1
            ? 'Une seule proposition a pu être calculée.'
            : '${routed.length} propositions seulement : le serveur a calé sur les autres.',
      );
    }

    // 3. Altitude, noms, scores -------------------------------------------------
    checkCancel();
    progress('On mesure le dénivelé et on compare…');
    // Open-Meteo encaisse sans souci quelques requêtes en parallèle.
    var elevationFailed = false;
    final profiles = await Future.wait([
      for (final r in routed)
        () async {
          if (elevation == null) return null;
          try {
            return await elevation!.profile(r.route.points, stepM: 1000, maxPoints: 200);
          } on RoutingException {
            elevationFailed = true;
            return null;
          }
        }(),
    ]);
    if (elevationFailed) notes.add("Dénivelé indisponible pour l'instant.");

    final places = await _placeNames(req, routed);
    checkCancel();

    final candidates = <RouteCandidate>[];
    for (var i = 0; i < routed.length; i++) {
      final r = routed[i];
      final profile = profiles[i];
      final pois = [for (final v in r.plan.vias) ?v.poi];
      final metrics = RouteMetrics(
        distanceM: r.route.distanceM,
        durationS: r.route.durationS,
        curvature: RouteScoring.curvatureScore(r.route.points),
        elevationGainM: profile?.stats.gainM,
        poiCount: pois.length,
        hasHighway: r.route.hasHighway,
      );
      final score = RouteScoring.styleFit(req.style, metrics, targetDistanceM: req.isLoop ? targetM : null);
      final waypoints = <GeoPoint>[req.start, for (final v in r.plan.vias) v.point, req.destination ?? req.start];
      candidates.add(
        RouteCandidate(
          route: PlannedRoute(
            id: _uuid.v4(),
            name: routeName(req, metrics, pois, places[i], variant: i),
            createdAt: DateTime.now().toUtc(),
            points: r.route.points,
            style: req.style,
            source: RouteSource.generated,
            waypoints: waypoints,
            distanceM: r.route.distanceM,
            durationS: r.route.durationS,
            curvatureScore: metrics.curvature,
            elevationGainM: profile?.stats.gainM ?? 0,
            maneuvers: r.route.maneuvers,
            description: routeDescription(req, metrics, pois),
          ),
          metrics: metrics,
          score: score,
          badges: RouteScoring.badges(metrics, style: req.style),
          pois: pois,
          profile: profile,
        ),
      );
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    step = totalSteps;
    progress("C'est prêt !");
    return GenerationResult(candidates, notes: notes);
  }

  Future<ValhallaRoute> _routePlan(RouteRequest req, _Plan plan, MotorcycleCosting costing) async {
    final end = req.destination ?? req.start;
    final locations = [
      RouteLocation(req.start),
      for (final v in plan.vias) RouteLocation(v.point, kind: LocationKind.through),
      RouteLocation(end),
    ];
    try {
      return await valhalla.route(locations, costing: costing);
    } on RoutingException catch (e) {
      if (e.kind != RoutingErrorKind.rateLimited) rethrow;
      // Serveur saturé : on souffle un peu et on retente une fois.
      await Future<void>.delayed(rateLimitPause);
      return valhalla.route(locations, costing: costing);
    }
  }

  Future<List<RoutePoi>> _fetchLoopPois(
    RouteRequest req,
    List<_Plan> plans,
    double radius,
    int n,
    List<String> notes,
  ) async {
    final client = overpass!;
    try {
      if (req.style == RouteStyle.foret) {
        final centers = <GeoPoint>[
          for (final p in plans) ...loopWaypoints(req.start, radius, p.bearing, count: n, clockwise: p.clockwise),
        ];
        final r = (radius * 0.4).clamp(3000.0, 15000.0);
        final pool = await client.forestsAround(centers, r);
        if (pool.isEmpty) notes.add("Pas de forêt nommée dans le coin : on a visé les petites routes.");
        return pool;
      } else {
        final pool = await client.mountainPasses(GeoBounds.around(req.start, radius * 2.3));
        if (pool.isEmpty) {
          notes.add("Pas de col routier à portée : on t'a trouvé des routes qui tournent à la place.");
        }
        return pool;
      }
    } on RoutingException catch (e) {
      if (e.kind == RoutingErrorKind.offline) rethrow;
      notes.add(
        "OpenStreetMap ne répond pas : balade générée sans viser de ${req.style == RouteStyle.foret ? 'forêt' : 'col'}.",
      );
      return const [];
    }
  }

  Future<List<RoutePoi>> _fetchAbPois(RouteRequest req, List<String> notes) async {
    final client = overpass!;
    final a = req.start, b = req.destination!;
    final d = Geo.distance(a, b);
    try {
      if (req.style == RouteStyle.foret) {
        final centers = [
          Geo.pointAtDistance([a, b], d / 3),
          Geo.pointAtDistance([a, b], d * 2 / 3),
        ];
        return await client.forestsAround(centers, (d * 0.35).clamp(3000.0, 15000.0));
      }
      final bounds = GeoBounds.fromPoints([a, b])!.expand((d * 0.25).clamp(5000.0, 30000.0));
      return await client.mountainPasses(bounds);
    } on RoutingException catch (e) {
      if (e.kind == RoutingErrorKind.offline) rethrow;
      notes.add('OpenStreetMap ne répond pas : variantes calculées sans points remarquables.');
      return const [];
    }
  }

  /// Nom de commune pour chaque proposition (point le plus éloigné du départ,
  /// ou point de passage A→B). Best effort : null si le service ne répond pas.
  Future<List<String?>> _placeNames(RouteRequest req, List<_Routed> routed) async {
    final g = geocoder;
    if (g == null) return List.filled(routed.length, null);
    Future<String?> one(_Routed r) async {
      GeoPoint target;
      if (req.isLoop) {
        target = r.route.points.reduce(
          (best, p) => Geo.distance(req.start, p) > Geo.distance(req.start, best) ? p : best,
        );
      } else if (r.plan.vias.isNotEmpty) {
        target = r.plan.vias.first.point;
      } else {
        return null;
      }
      try {
        final place = await g.reverse(target);
        return place?.city ?? place?.name;
      } catch (_) {
        return null;
      }
    }

    try {
      return await Future.wait(routed.map(one)).timeout(const Duration(seconds: 8));
    } catch (_) {
      return List.filled(routed.length, null);
    }
  }

  // ---------------------------------------------------------------------------
  // Textes
  // ---------------------------------------------------------------------------

  static String _short(String? label) {
    if (label == null || label.isEmpty) return '';
    return label.split(',').first.trim();
  }

  static String routeName(RouteRequest req, RouteMetrics m, List<RoutePoi> pois, String? place, {int variant = 0}) {
    final km = m.distanceKm.round();
    if (!req.isLoop) {
      final to = _short(req.destinationLabel);
      final base = to.isEmpty ? 'Balade A→B' : 'Vers $to';
      if (pois.isNotEmpty) return '$base par ${pois.first.name}';
      if (variant > 0 && place != null) return '$base par $place';
      return base;
    }
    switch (req.style) {
      case RouteStyle.foret:
        if (pois.length >= 2) return 'Forêts : ${pois[0].shortName} & ${pois[1].shortName}';
        if (pois.length == 1) return 'Par la ${pois[0].name}'.replaceAll('Par la Bois', 'Par le Bois');
        return place != null ? 'Sous-bois vers $place' : 'Sous-bois · $km km';
      case RouteStyle.cols:
        if (pois.isNotEmpty) return 'Par le ${pois.first.name}'.replaceAll('le Col', 'le col');
        return place != null ? 'Grimpette vers $place' : 'Grimpette · $km km';
      case RouteStyle.sinueux:
        return place != null ? 'Virolos vers $place' : 'Virolos · $km km';
      case RouteStyle.plat:
        return place != null ? 'Balade cool vers $place' : 'Balade cool · $km km';
      case RouteStyle.rapide:
        return place != null ? 'Ça roule vers $place' : 'Ça roule · $km km';
      case RouteStyle.mixte:
        return place != null ? 'Boucle vers $place' : 'Boucle · $km km';
    }
  }

  static String routeDescription(RouteRequest req, RouteMetrics m, List<RoutePoi> pois) {
    final km = m.distanceKm.round();
    final from = _short(req.startLabel);
    final sb = StringBuffer(req.isLoop ? 'Boucle de $km km' : 'Trajet de $km km');
    if (from.isNotEmpty) sb.write(req.isLoop ? ' au départ de $from' : ' depuis $from');
    if (!req.isLoop) {
      final to = _short(req.destinationLabel);
      if (to.isNotEmpty) sb.write(' jusqu\'à $to');
    }
    if (pois.isNotEmpty) {
      final names = pois.map((p) => p.name).toList();
      final joined = names.length == 1
          ? names.first
          : '${names.sublist(0, names.length - 1).join(', ')} et ${names.last}';
      sb.write(', par $joined');
    }
    sb.write('.');
    return sb.toString();
  }
}
