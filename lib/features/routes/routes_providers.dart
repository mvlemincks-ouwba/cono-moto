import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/providers.dart';
import '../../data/models/planned_route.dart';
import '../../services/routing/elevation_client.dart';
import '../../services/routing/geocoder.dart';
import '../../services/routing/http_support.dart';
import '../../services/routing/overpass_client.dart';
import '../../services/routing/route_generator.dart';
import '../../services/routing/valhalla_client.dart';
import '../../services/routing/weather_service.dart';

/// Pas de nouvel essai automatique : les serveurs publics sont partagés.
Duration? _noRetry(int count, Object error) => null;

// ---------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------

final valhallaClientProvider = Provider<ValhallaClient>((ref) {
  final c = ValhallaClient();
  ref.onDispose(c.close);
  return c;
});

final overpassClientProvider = Provider<OverpassClient>((ref) {
  final c = OverpassClient();
  ref.onDispose(c.close);
  return c;
});

final elevationClientProvider = Provider<ElevationClient>((ref) {
  final c = ElevationClient();
  ref.onDispose(c.close);
  return c;
});

final geocoderProvider = Provider<Geocoder>((ref) {
  final c = Geocoder(banEndpoints: Endpoints.banGeocoders);
  ref.onDispose(c.close);
  return c;
});

final weatherClientProvider = Provider<WeatherClient>((ref) {
  final c = WeatherClient();
  ref.onDispose(c.close);
  return c;
});

final routeGeneratorProvider = Provider<RouteGenerator>(
  (ref) => RouteGenerator(
    valhalla: ref.watch(valhallaClientProvider),
    overpass: ref.watch(overpassClientProvider),
    elevation: ref.watch(elevationClientProvider),
    geocoder: ref.watch(geocoderProvider),
  ),
);

// ---------------------------------------------------------------------------
// Données
// ---------------------------------------------------------------------------

/// Mes balades à faire (favoris en tête), rafraîchies à chaque modification.
final savedRoutesProvider = StreamProvider<List<PlannedRoute>>((ref) async* {
  final repo = ref.watch(routeRepositoryProvider);
  yield await repo.list();
  await for (final _ in repo.changes) {
    yield await repo.list();
  }
});

/// Cache mémoire des profils d'altitude (clé : id + géométrie).
final elevationCacheProvider = Provider<Map<String, ElevationProfile>>((ref) => {});

String profileKey(PlannedRoute r) => '${r.id}:${r.points.length}:${r.distanceM.round()}';

/// Clé stable d'une balade pour les providers « family » : un renommage ou
/// un passage en favori ne relance pas les calculs.
@immutable
class RouteKey {
  const RouteKey(this.route);

  final PlannedRoute route;

  @override
  bool operator ==(Object other) => other is RouteKey && profileKey(other.route) == profileKey(route);

  @override
  int get hashCode => profileKey(route).hashCode;
}

/// Profil d'altitude d'une balade (Open-Meteo, ~1 point/km).
final routeProfileProvider = FutureProvider.autoDispose.family<ElevationProfile, RouteKey>((ref, key) async {
  final route = key.route;
  final cache = ref.read(elevationCacheProvider);
  final k = profileKey(route);
  final cached = cache[k];
  if (cached != null) return cached;
  final profile = await ref.read(elevationClientProvider).profile(route.points, stepM: 1000, maxPoints: 300);
  cache[k] = profile;
  return profile;
}, retry: _noRetry);

/// Paramètres d'une demande de météo sur le parcours.
@immutable
class WeatherQuery {
  const WeatherQuery(this.route, this.departure);

  final PlannedRoute route;
  final DateTime departure;

  @override
  bool operator ==(Object other) =>
      other is WeatherQuery &&
      other.route.id == route.id &&
      other.route.points.length == route.points.length &&
      other.departure == departure;

  @override
  int get hashCode => Object.hash(route.id, route.points.length, departure);
}

/// Météo sur le parcours à l'heure de passage estimée.
final routeWeatherProvider = FutureProvider.autoDispose.family<RouteWeather, WeatherQuery>(
  (ref, q) => RouteWeatherService(ref.read(weatherClientProvider)).forRoute(
    q.route.points,
    q.route.durationS > 0 ? q.route.durationS : (q.route.distanceM / 1000 / 55 * 3600).round(),
    q.departure,
  ),
  retry: _noRetry,
);

/// Prochaine heure pleine (heure de départ par défaut).
DateTime nextFullHour([DateTime? now]) {
  final n = now ?? DateTime.now();
  return DateTime(n.year, n.month, n.day, n.hour).add(const Duration(hours: 1));
}

// ---------------------------------------------------------------------------
// Génération
// ---------------------------------------------------------------------------

@immutable
class GenerationState {
  const GenerationState({this.request, this.progress, this.result, this.error, this.running = false});

  final RouteRequest? request;
  final GenerationProgress? progress;
  final GenerationResult? result;
  final RoutingException? error;
  final bool running;

  GenerationState copyWith({GenerationProgress? progress}) => GenerationState(
    request: request,
    progress: progress ?? this.progress,
    result: result,
    error: error,
    running: running,
  );
}

/// Calcul des propositions (plusieurs secondes) : garde l'avancement et le
/// résultat le temps que l'écran de résultats est ouvert.
class GenerationController extends Notifier<GenerationState> {
  int _runId = 0;

  @override
  GenerationState build() {
    ref.onDispose(() => _runId++);
    return const GenerationState();
  }

  Future<void> run(RouteRequest request) async {
    final id = ++_runId;
    bool alive() => ref.mounted && id == _runId;
    state = GenerationState(
      request: request,
      running: true,
      progress: const GenerationProgress('On chauffe les pneus…', 0, 1),
    );
    var req = request;
    try {
      if (req.startLabel == null) {
        try {
          final place = await ref.read(geocoderProvider).reverse(req.start).timeout(const Duration(seconds: 5));
          final label = place?.city ?? place?.name;
          if (label != null) req = req.copyWith(startLabel: label);
        } catch (_) {
          // Pas grave : la balade n'aura juste pas de nom de départ.
        }
        if (!alive()) return;
      }
      final result = await ref
          .read(routeGeneratorProvider)
          .generate(
            req,
            onProgress: (p) {
              if (alive()) state = state.copyWith(progress: p);
            },
            isCancelled: () => !alive(),
          );
      if (!alive()) return;
      final cache = ref.read(elevationCacheProvider);
      for (final c in result.candidates) {
        if (c.profile != null) cache[profileKey(c.route)] = c.profile!;
      }
      state = GenerationState(request: req, result: result);
    } on RoutingException catch (e) {
      if (!alive() || e.kind == RoutingErrorKind.cancelled) return;
      state = GenerationState(request: req, error: e);
    } catch (e, st) {
      debugPrint('Génération de balade : $e\n$st');
      if (!alive()) return;
      state = GenerationState(
        request: req,
        error: const RoutingException(
          RoutingErrorKind.badResponse,
          "Oups, le calcul a calé. Réessaie dans un instant.",
        ),
      );
    }
  }

  /// Relance avec une nouvelle graine (« Autres idées »).
  Future<void> reroll() {
    final req = state.request;
    if (req == null) return Future.value();
    return run(req.withSeed(req.seed + 7919));
  }

  void cancel() => _runId++;
}

final generationProvider = NotifierProvider.autoDispose<GenerationController, GenerationState>(
  GenerationController.new,
);
