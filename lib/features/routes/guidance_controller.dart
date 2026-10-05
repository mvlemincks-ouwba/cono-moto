import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../core/location.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/models/planned_route.dart';
import '../../services/routing/guidance_engine.dart';
import '../../services/routing/http_support.dart';
import '../navigation/destination_routing.dart';
import '../navigation/navigation_logic.dart';
import '../ride/ride_controller.dart';
import 'routes_providers.dart';

/// Synthèse vocale française pour les annonces de guidage.
class VoiceGuide {
  FlutterTts? _tts;
  bool _ready = false;

  Future<void> speak(String text) async {
    try {
      final tts = _tts ??= FlutterTts();
      if (!_ready) {
        await tts.setLanguage('fr-FR');
        await tts.setSpeechRate(0.5);
        await tts.setVolume(1);
        await tts.awaitSpeakCompletion(false);
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) await _setupIosAudio(tts);
        _ready = true;
      }
      // focus : baisse la musique le temps de l'annonce (Android).
      await tts.speak(text, focus: true);
    } catch (e) {
      debugPrint('Synthèse vocale indisponible : $e');
    }
  }

  /// iOS : session audio partagée en lecture, qui baisse la musique (appli de
  /// musique, intercom Bluetooth) le temps de l'annonce sans la couper, puis
  /// la rend à la fin (autoStopSharedSession).
  static Future<void> _setupIosAudio(FlutterTts tts) async {
    try {
      await tts.setSharedInstance(true);
      await tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, const [
        IosTextToSpeechAudioCategoryOptions.duckOthers,
        IosTextToSpeechAudioCategoryOptions.mixWithOthers,
      ], IosTextToSpeechAudioMode.voicePrompt);
      await tts.autoStopSharedSession(true);
    } catch (e) {
      debugPrint('Session audio iOS : $e');
    }
  }

  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}

final voiceGuideProvider = Provider<VoiceGuide>((ref) {
  final v = VoiceGuide();
  ref.onDispose(v.stop);
  return v;
});

/// Dernier itinéraire issu d'un recalcul en cours de route (pour ne pas
/// annoncer un nouveau « C'est parti ! »).
class ReroutedRouteNotifier extends Notifier<PlannedRoute?> {
  @override
  PlannedRoute? build() => null;

  void mark(PlannedRoute route) => state = route;
}

final reroutedRouteProvider = NotifierProvider<ReroutedRouteNotifier, PlannedRoute?>(ReroutedRouteNotifier.new);

/// Moteur de guidage de l'itinéraire actif (recréé quand l'itinéraire change).
final guidanceEngineProvider = Provider<GuidanceEngine?>((ref) {
  final route = ref.watch(activeRouteProvider);
  if (route == null || route.points.length < 2) return null;
  return GuidanceEngine(route, rerouted: identical(ref.read(reroutedRouteProvider), route));
});

/// Anti-spam du recalcul automatique, une instance par balade (survit aux
/// recalculs, qui recréent le contrôleur de guidage).
final autoRerouteProvider = Provider<AutoReroutePolicy>((ref) {
  ref.watch(rideControllerProvider.select((s) => s.rideId));
  return AutoReroutePolicy();
});

/// État du guidage affiché par [GuidanceBanner].
@immutable
class GuidanceState {
  const GuidanceState({required this.route, this.snapshot, this.recalculating = false, this.error});

  final PlannedRoute route;

  /// Null tant qu'aucune position GPS n'a été reçue.
  final GuidanceSnapshot? snapshot;
  final bool recalculating;
  final String? error;

  GuidanceState copyWith({GuidanceSnapshot? snapshot, bool? recalculating, String? error, bool clearError = false}) =>
      GuidanceState(
        route: route,
        snapshot: snapshot ?? this.snapshot,
        recalculating: recalculating ?? this.recalculating,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Guidage virage par virage : actif quand une balade est en cours
/// (enregistrement ou pause) sur un itinéraire ([activeRouteProvider]).
class GuidanceController extends Notifier<GuidanceState?> {
  @override
  GuidanceState? build() {
    final engine = ref.watch(guidanceEngineProvider);
    final status = ref.watch(rideControllerProvider.select((s) => s.status));
    final active = status == RideStatus.recording || status == RideStatus.paused;
    if (engine == null || !active) return null;

    ref.listen<RiderPosition?>(positionHubProvider, (previous, next) {
      if (next == null || identical(previous, next)) return;
      if (ref.read(rideControllerProvider).status != RideStatus.recording) return;
      _onPosition(engine, next);
    });

    var snapshot = engine.lastSnapshot;
    if (snapshot == null) {
      final pos = ref.read(positionHubProvider);
      if (pos != null && status == RideStatus.recording) {
        snapshot = engine.update(pos.point, accuracyM: pos.accuracyM, speedMs: pos.speedMs);
        final say = snapshot.announcement;
        if (say != null) Future.microtask(() => _speak(say));
      }
    }
    return GuidanceState(route: engine.route, snapshot: snapshot);
  }

  void _onPosition(GuidanceEngine engine, RiderPosition p) {
    final snap = engine.update(p.point, accuracyM: p.accuracyM, speedMs: p.speedMs);
    final current = state ?? GuidanceState(route: engine.route);
    state = current.copyWith(snapshot: snap);
    final say = snap.announcement;
    if (say != null) _speak(say);
    // Recalcul automatique quand on sort de l'itinéraire (anti-spam inclus).
    final policy = ref.read(autoRerouteProvider);
    if (policy.onSnapshot(offRoute: snap.offRoute, arrived: snap.arrived, at: p.time, busy: current.recalculating)) {
      recalculate(auto: true);
    }
  }

  void _speak(String text) {
    if (!ref.mounted) return;
    if (!ref.read(settingsProvider).voiceGuidance) return;
    ref.read(voiceGuideProvider).speak(text);
  }

  /// Recalcule depuis ma position vers la suite de l'itinéraire (ou vers la
  /// destination pour un itinéraire « Où on va ? »).
  ///
  /// [auto] : lancé tout seul en sortant de l'itinéraire (annonce « Recalcul
  /// de l'itinéraire »). Sinon, bouton de secours.
  Future<void> recalculate({bool auto = false}) async {
    final s = state;
    final engine = ref.read(guidanceEngineProvider);
    if (s == null || engine == null || s.recalculating) return;
    final pos = ref.read(positionHubProvider);
    if (pos == null) {
      if (!auto) state = s.copyWith(error: 'Position GPS inconnue, patiente un instant.');
      return;
    }
    if (!auto) ref.read(autoRerouteProvider).recordManual(pos.time);
    state = s.copyWith(recalculating: true, clearError: true);
    if (auto) _speak("Recalcul de l'itinéraire.");
    try {
      final via = rerouteTargets(s.route, engine);
      final v = await ref.read(valhallaClientProvider).routeThrough([
        pos.point,
        ...via,
      ], costing: rerouteCosting(s.route));
      if (!ref.mounted) return;
      final old = s.route;
      final rerouted = PlannedRoute(
        id: old.id,
        name: old.name,
        createdAt: old.createdAt,
        points: v.points,
        style: old.style,
        source: old.source,
        waypoints: [pos.point, ...via],
        distanceM: v.distanceM,
        durationS: v.durationS,
        curvatureScore: old.curvatureScore,
        elevationGainM: old.elevationGainM,
        maneuvers: v.maneuvers,
        description: old.description,
        author: old.author,
        favorite: old.favorite,
      );
      if (!auto) _speak('Itinéraire recalculé.');
      // Recrée le moteur (et ce contrôleur) sur le nouvel itinéraire.
      ref.read(reroutedRouteProvider.notifier).mark(rerouted);
      ref.read(activeRouteProvider.notifier).set(rerouted);
    } on RoutingException catch (e) {
      if (!ref.mounted) return;
      state = state?.copyWith(recalculating: false, error: e.message);
    } catch (e) {
      if (!ref.mounted) return;
      state = state?.copyWith(recalculating: false, error: 'Recalcul impossible pour le moment.');
    }
  }

  void dismissError() {
    final s = state;
    if (s != null && s.error != null) state = s.copyWith(clearError: true);
  }
}

final guidanceProvider = NotifierProvider<GuidanceController, GuidanceState?>(GuidanceController.new);
