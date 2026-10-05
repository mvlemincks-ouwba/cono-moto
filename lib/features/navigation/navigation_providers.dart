import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../core/providers.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/planned_route.dart';
import '../../services/routing/geocoder.dart';
import '../../services/routing/http_support.dart';
import '../../services/routing/valhalla_client.dart';
import '../ride/ride_controller.dart';
import '../ride/ride_screen.dart';
import '../routes/routes_providers.dart';
import 'destination_routing.dart';

/// Tests de widgets uniquement : remplace les cartes MapLibre du plan de
/// navigation et de « Où on va ? » (vues natives absentes des tests).
bool debugDisableNavigationMaps = false;

/// Demande de calcul des options vers une destination.
@immutable
class DestinationQuery {
  const DestinationQuery({required this.start, required this.destination});

  final GeoPoint start;
  final Place destination;

  // Départ arrondi (~10 m) : un fix GPS qui bouge un peu ne relance rien.
  int get _startKey => Object.hash((start.lat * 1e4).round(), (start.lng * 1e4).round());

  @override
  bool operator ==(Object other) =>
      other is DestinationQuery &&
      other._startKey == _startKey &&
      other.destination.point == destination.point &&
      other.destination.name == destination.name;

  @override
  int get hashCode => Object.hash(_startKey, destination.point, destination.name);
}

Duration? _noRetry(int count, Object error) => null;

/// « Le plus rapide » et « Par les petites routes » vers une destination
/// (deux calculs Valhalla successifs, espacés par le limiteur du client).
final destinationPlansProvider = FutureProvider.autoDispose.family<DestinationPlans, DestinationQuery>((ref, q) async {
  final client = ref.read(valhallaClientProvider);
  final locations = [RouteLocation(q.start), RouteLocation(q.destination.point)];
  ValhallaRoute? fastest, smallRoads;
  RoutingException? fastestError, smallRoadsError;
  try {
    fastest = await client.route(locations, costing: DestinationOption.fastest.costing);
  } on RoutingException catch (e) {
    fastestError = e;
  }
  // Pas de réseau : inutile d'insister.
  if (fastestError == null || !(fastestError.kind == RoutingErrorKind.offline)) {
    try {
      smallRoads = await client.route(locations, costing: DestinationOption.smallRoads.costing);
    } on RoutingException catch (e) {
      smallRoadsError = e;
    }
  }
  if (fastest == null && smallRoads == null) throw fastestError ?? smallRoadsError!;
  return assemblePlans(
    start: q.start,
    destination: q.destination,
    now: DateTime.now(),
    fastest: fastest,
    smallRoads: smallRoads,
    fastestError: fastestError?.message,
    smallRoadsError: smallRoadsError?.message,
  );
}, retry: _noRetry);

/// « C'est parti » vers une destination : itinéraire actif, démarrage de la
/// balade si besoin, puis plan de navigation (en revenant sur l'écran de
/// balade s'il est déjà ouvert).
Future<void> startNavigationTo(BuildContext context, WidgetRef ref, PlannedRoute route) async {
  final navigator = Navigator.of(context);
  ref.read(activeRouteProvider.notifier).set(route);
  final ride = ref.read(rideControllerProvider);
  if (!ride.isActive) {
    final ok = await ref.read(rideControllerProvider.notifier).start(route: route);
    if (!ok && context.mounted) {
      showCmSnack(context, 'Impossible de démarrer : vérifie que le GPS est activé et autorisé.', error: true);
    }
  } else if (context.mounted) {
    showCmSnack(context, 'Itinéraire chargé dans ta balade en cours. Bonne route !');
  }
  var onRideScreen = false;
  navigator.popUntil((r) {
    if (r.settings.name == RideScreen.routeName) {
      onRideScreen = true;
      return true;
    }
    return r.isFirst;
  });
  if (!onRideScreen) await navigator.push(RideScreen.route(initialLayout: HudLayout.map));
}
