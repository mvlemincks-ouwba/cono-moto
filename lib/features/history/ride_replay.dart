import '../../data/models/planned_route.dart';
import '../../data/models/ride.dart';
import '../../data/repositories.dart';
import '../../services/routing/http_support.dart';
import 'ride_analysis.dart';

/// Résultat de « Refaire cette balade ».
class ReplayPlan {
  const ReplayPlan(this.route, {this.offlineError});

  /// Itinéraire à ouvrir.
  final PlannedRoute route;

  /// Recalcul impossible (réseau, serveur) : la trace est gardée sans
  /// consignes de virage.
  final RoutingException? offlineError;
}

/// Prépare l'itinéraire pour refaire [ride], avec flèches, voix et roadbook :
/// 1. la balade suivait un itinéraire encore enregistré → on le reprend ;
/// 2. sinon la trace devient une balade « enregistrée » (une seule par balade,
///    `replay-<id>`), recalculée le long des routes par [reroute] ;
/// 3. sans réseau, la trace est gardée telle quelle (« Suivre les routes »
///    reste proposé dans le menu).
/// Renvoie `null` s'il n'y a pas de trace exploitable.
Future<ReplayPlan?> prepareReplay({
  required Ride ride,
  required RouteRepository routes,
  required Future<List<TrackPoint>> Function() track,
  required Future<PlannedRoute> Function(PlannedRoute route) reroute,
  required DateTime now,
  void Function()? onRerouting,
}) async {
  final followed = ride.routeId == null ? null : await routes.get(ride.routeId!);
  if (followed != null && followed.maneuvers.isNotEmpty) return ReplayPlan(followed);

  final id = 'replay-${ride.id}';
  final saved = await routes.get(id);
  if (saved != null && saved.maneuvers.isNotEmpty) return ReplayPlan(saved);

  var route = plannedRouteFromRide(ride, await track(), id: id, now: now);
  if (route.points.length < 2) return null;
  // Ancienne version sans consignes : on garde son nom et son étoile.
  if (saved != null) route = route.copyWith(name: saved.name, favorite: saved.favorite);
  RoutingException? error;
  onRerouting?.call();
  try {
    route = await reroute(route);
  } on RoutingException catch (e) {
    error = e;
  }
  await routes.upsert(route);
  return ReplayPlan(route, offlineError: error);
}
