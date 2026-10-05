import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../data/models/shared.dart';
import '../../services/fuel/fuel_price_client.dart';

/// Client des prix carburants (cache mémoire 5 min partagé par toute l'app).
final fuelPriceClientProvider = Provider<FuelPriceClient>((ref) {
  final client = FuelPriceClient();
  ref.onDispose(client.close);
  return client;
});

/// Quelques tentatives seulement en cas d'échec réseau (pas de boucle infinie).
Duration? _fuelRetry(int retryCount, Object error) => retryCount < 2 ? Duration(seconds: 2 * (retryCount + 1)) : null;

/// Stations autour d'un point (rayon ~10 km), triées par distance.
/// Le point doit être arrondi par l'appelant (~1 km) pour limiter les requêtes
/// (voir `roundForStationQuery` dans fuel_logic.dart).
final stationsAroundProvider = FutureProvider.autoDispose.family<List<FuelStation>, GeoPoint>(
  (ref, center) => ref.watch(fuelPriceClientProvider).around(center),
  retry: _fuelRetry,
);

/// Stations à moins de 3 km d'un itinéraire, dans l'ordre du trajet.
/// La clé est la polyligne encodée (précision 5) de l'itinéraire.
final stationsAlongRouteProvider = FutureProvider.autoDispose.family<List<RouteFuelStation>, String>(
  (ref, encodedRoute) => ref.watch(fuelPriceClientProvider).alongRoute(Geo.decodePolyline(encodedRoute)),
  retry: _fuelRetry,
);

/// Clé de [stationsAlongRouteProvider] pour un itinéraire.
String routeStationsKey(List<GeoPoint> route) => Geo.encodePolyline(route.length > 2 ? Geo.simplify(route, 25) : route);
