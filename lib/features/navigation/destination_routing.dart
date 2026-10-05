// « Où on va ? » : options d'itinéraire vers une destination et règles de
// recalcul (logique pure, sans plateforme).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/geo.dart';
import '../../data/models/planned_route.dart';
import '../../services/routing/geocoder.dart';
import '../../services/routing/guidance_engine.dart';
import '../../services/routing/route_scoring.dart';
import '../../services/routing/valhalla_client.dart';

/// Préfixe des identifiants d'itinéraires « vers une destination ».
const destinationRoutePrefix = 'dest-';

/// Itinéraire créé depuis « Où on va ? » (et non une balade à faire).
bool isDestinationRoute(PlannedRoute r) => r.id.startsWith(destinationRoutePrefix);

/// Les deux façons d'aller à une destination.
enum DestinationOption {
  fastest('Le plus rapide', 'Autoroutes et nationales si ça va plus vite', Icons.bolt_rounded, RouteStyle.rapide),
  smallRoads(
    'Par les petites routes',
    'On évite autoroutes et nationales',
    Icons.turn_sharp_right_rounded,
    RouteStyle.sinueux,
  );

  const DestinationOption(this.label, this.description, this.icon, this.style);

  final String label;
  final String description;
  final IconData icon;

  /// Style mémorisé dans l'itinéraire (pour recalculer avec les mêmes préférences).
  final RouteStyle style;

  /// Préférences Valhalla (0 = éviter, 1 = favoriser).
  MotorcycleCosting get costing => switch (this) {
    DestinationOption.fastest => const MotorcycleCosting(
      useHighways: 1.0,
      useTolls: 0.5,
      usePrimary: 1.0,
      useTrails: 0,
      useFerry: 0.4,
      useLivingStreets: 0.1,
    ),
    DestinationOption.smallRoads => const MotorcycleCosting(
      useHighways: 0.0,
      useTolls: 0.0,
      usePrimary: 0.1,
      useTrails: 0,
      useFerry: 0.2,
      useLivingStreets: 0.1,
    ),
  };

  static DestinationOption fromStyle(RouteStyle s) =>
      s == RouteStyle.rapide ? DestinationOption.fastest : DestinationOption.smallRoads;
}

/// Une option calculée.
@immutable
class DestinationPlan {
  const DestinationPlan({required this.option, required this.route, this.hasHighway = false, this.hasToll = false});

  final DestinationOption option;
  final PlannedRoute route;
  final bool hasHighway;
  final bool hasToll;

  DateTime arrivalFrom(DateTime now) => now.add(Duration(seconds: route.durationS));
}

/// Résultat du calcul des options (au moins une).
@immutable
class DestinationPlans {
  const DestinationPlans(this.plans, {this.notes = const []});

  final List<DestinationPlan> plans;

  /// Remarques à afficher (option identique, option impossible…).
  final List<String> notes;
}

/// Construit l'itinéraire suivi à partir du calcul Valhalla.
PlannedRoute buildDestinationRoute({
  required ValhallaRoute v,
  required GeoPoint start,
  required Place destination,
  required DestinationOption option,
  required DateTime now,
}) => PlannedRoute(
  id: '$destinationRoutePrefix${now.microsecondsSinceEpoch}-${option.name}',
  name: 'Vers ${destination.name}',
  createdAt: now.toUtc(),
  points: v.points,
  style: option.style,
  source: RouteSource.manual,
  waypoints: [start, destination.point],
  distanceM: v.distanceM,
  durationS: v.durationS,
  curvatureScore: v.points.length >= 2 ? RouteScoring.curvatureScore(v.points) : 0,
  maneuvers: v.maneuvers,
  description: option.label,
);

/// Deux calculs qui donnent en pratique le même trajet.
bool sameItinerary(ValhallaRoute a, ValhallaRoute b) =>
    (a.distanceM - b.distanceM).abs() <= math.max(150, a.distanceM * 0.015) &&
    (a.durationS - b.durationS).abs() <= math.max(30, a.durationS * 0.02);

/// Assemble les options calculées (l'option « petites routes » identique à
/// la plus rapide est retirée avec une remarque).
DestinationPlans assemblePlans({
  required GeoPoint start,
  required Place destination,
  required DateTime now,
  ValhallaRoute? fastest,
  ValhallaRoute? smallRoads,
  String? fastestError,
  String? smallRoadsError,
}) {
  final plans = <DestinationPlan>[];
  final notes = <String>[];
  DestinationPlan plan(DestinationOption o, ValhallaRoute v) => DestinationPlan(
    option: o,
    route: buildDestinationRoute(v: v, start: start, destination: destination, option: o, now: now),
    hasHighway: v.hasHighway,
    hasToll: v.hasToll,
  );
  if (fastest != null) plans.add(plan(DestinationOption.fastest, fastest));
  if (smallRoads != null) {
    if (fastest != null && sameItinerary(fastest, smallRoads)) {
      notes.add('Par les petites routes, c\'est le même trajet : il n\'y a qu\'un itinéraire sensé ici.');
    } else {
      plans.add(plan(DestinationOption.smallRoads, smallRoads));
    }
  }
  if (fastest == null && fastestError != null && smallRoads != null) notes.add('Le plus rapide : $fastestError');
  if (smallRoads == null && smallRoadsError != null && fastest != null) {
    notes.add('Par les petites routes : $smallRoadsError');
  }
  return DestinationPlans(plans, notes: notes);
}

/// Points vers lesquels recalculer depuis ma position : la destination pour un
/// itinéraire « Où on va ? », la suite du tracé pour une balade (on garde son
/// caractère sinueux).
List<GeoPoint> rerouteTargets(PlannedRoute route, GuidanceEngine engine) {
  if (isDestinationRoute(route)) {
    final dest = route.waypoints.length >= 2 ? route.waypoints.last : route.points.last;
    return [dest];
  }
  return engine.remainingViaPoints();
}

/// Préférences de calcul pour recalculer [route].
MotorcycleCosting rerouteCosting(PlannedRoute route) => isDestinationRoute(route)
    ? DestinationOption.fromStyle(route.style).costing
    : MotorcycleCosting.forStyle(route.style);
