import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/notifications.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/models/shared.dart';
import '../../services/traffic/tomtom_client.dart';
import '../ride/ride_controller.dart';

/// Incident situé devant moi sur l'itinéraire suivi.
class IncidentAhead {
  const IncidentAhead(this.incident, this.distanceAheadM);
  final TrafficIncident incident;
  final double distanceAheadM;
}

/// Incidents qui touchent la partie restante de l'itinéraire (à moins de
/// [corridorM] de la ligne), triés du plus proche au plus lointain.
List<IncidentAhead> incidentsAhead({
  required List<GeoPoint> route,
  required double myDistanceAlongM,
  required List<TrafficIncident> incidents,
  double corridorM = 150,
  double horizonM = 40000,
}) {
  if (route.length < 2) return const [];
  final cum = Geo.cumulativeDistances(route);
  final out = <IncidentAhead>[];
  for (final inc in incidents) {
    final probes = inc.geometry.isEmpty ? [inc.location] : [inc.geometry.first, inc.geometry.last];
    double? best;
    for (final p in probes) {
      final proj = Geo.project(p, route, cumulative: cum);
      if (proj == null || proj.distanceFromLineM > corridorM) continue;
      final ahead = proj.distanceAlongM - myDistanceAlongM;
      if (ahead < -50 || ahead > horizonM) continue;
      best = best == null ? ahead : (ahead < best ? ahead : best);
    }
    if (best != null) out.add(IncidentAhead(inc, best < 0 ? 0 : best));
  }
  out.sort((a, b) => a.distanceAheadM.compareTo(b.distanceAheadM));
  return out;
}

/// Incidents importants pour un motard (on masque les petits ralentissements).
bool isRelevantIncident(TrafficIncident i) =>
    i.kind != IncidentKind.bouchon || i.magnitude >= 3;

@immutable
class TrafficState {
  const TrafficState({
    this.incidents = const [],
    this.loading = false,
    this.error,
    this.updatedAt,
    this.ahead = const [],
  });

  final List<TrafficIncident> incidents;
  final bool loading;
  final String? error;
  final DateTime? updatedAt;

  /// Incidents sur l'itinéraire suivi (pendant une balade).
  final List<IncidentAhead> ahead;

  TrafficState copyWith({
    List<TrafficIncident>? incidents,
    bool? loading,
    String? error,
    bool clearError = false,
    DateTime? updatedAt,
    List<IncidentAhead>? ahead,
  }) =>
      TrafficState(
        incidents: incidents ?? this.incidents,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        updatedAt: updatedAt ?? this.updatedAt,
        ahead: ahead ?? this.ahead,
      );
}

/// Incidents de circulation en temps réel (TomTom) autour de la zone affichée
/// ou, pendant une balade, autour de moi et sur mon itinéraire.
class TrafficNotifier extends Notifier<TrafficState> {
  GeoBounds? _lastBounds;
  DateTime? _lastFetch;
  Timer? _rideTimer;
  final Set<String> _notified = {};

  @override
  TrafficState build() {
    ref.onDispose(() => _rideTimer?.cancel());
    ref.listen(rideControllerProvider.select((s) => s.status), (prev, next) {
      final riding = next == RideStatus.recording || next == RideStatus.paused;
      if (riding && _rideTimer == null) {
        _rideTimer = Timer.periodic(const Duration(minutes: 3), (_) => _refreshAroundMe());
        Future.microtask(_refreshAroundMe);
      } else if (!riding) {
        _rideTimer?.cancel();
        _rideTimer = null;
        _notified.clear();
      }
    });
    return const TrafficState();
  }

  String get _key => ref.read(settingsProvider).effectiveTomtomKey;
  bool get enabled => ref.read(settingsProvider).showTraffic && _key.isNotEmpty;

  /// À appeler quand la carte s'arrête de bouger.
  Future<void> onViewport(GeoBounds bounds, double zoom) async {
    if (!enabled || zoom < 8.5) return;
    final now = DateTime.now();
    final last = _lastBounds;
    final recent = _lastFetch != null && now.difference(_lastFetch!) < const Duration(minutes: 2);
    if (recent && last != null && last.contains(bounds.center) && _similar(last, bounds)) return;
    await _fetch(bounds.expand(2000));
  }

  bool _similar(GeoBounds a, GeoBounds b) {
    final da = (a.north - a.south) * (a.east - a.west);
    final db = (b.north - b.south) * (b.east - b.west);
    return db <= da * 1.3;
  }

  Future<void> refresh() async {
    final b = _lastBounds;
    _lastFetch = null;
    if (b != null) await _fetch(b);
  }

  Future<void> _refreshAroundMe() async {
    if (!enabled) return;
    final me = ref.read(positionHubProvider);
    if (me == null) return;
    await _fetch(GeoBounds.around(me.point, 25000));
    _checkAhead(me);
  }

  Future<void> _fetch(GeoBounds bounds) async {
    final key = _key;
    if (key.isEmpty) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final list = await TomTomTrafficClient(apiKey: key).incidents(bounds);
      _lastBounds = bounds;
      _lastFetch = DateTime.now();
      state = state.copyWith(
        incidents: list.where(isRelevantIncident).toList(),
        loading: false,
        updatedAt: DateTime.now(),
      );
    } on TrafficException catch (e) {
      state = state.copyWith(loading: false, error: e.message);
    } catch (e) {
      state = state.copyWith(loading: false, error: 'Trafic indisponible.');
    }
  }

  void _checkAhead(RiderPosition me) {
    final route = ref.read(activeRouteProvider);
    if (route == null || route.points.length < 2) {
      state = state.copyWith(ahead: const []);
      return;
    }
    final proj = Geo.project(me.point, route.points);
    if (proj == null) return;
    final ahead = incidentsAhead(
      route: route.points,
      myDistanceAlongM: proj.distanceAlongM,
      incidents: state.incidents,
    );
    state = state.copyWith(ahead: ahead);
    for (final a in ahead) {
      final i = a.incident;
      if (_notified.contains(i.id)) continue;
      if (i.kind == IncidentKind.bouchon) continue;
      _notified.add(i.id);
      final where = i.roadName.isNotEmpty ? ' (${i.roadName})' : '';
      final km = (a.distanceAheadM / 1000).toStringAsFixed(a.distanceAheadM < 10000 ? 1 : 0);
      Notifications.show(
        id: 4000 + _notified.length,
        title: '⚠️ ${i.kind.label} sur ta route dans $km km$where',
        body: i.description.isNotEmpty ? i.description : 'Prudence en approchant.',
        channel: CmChannel.ride,
      );
    }
  }
}

final trafficProvider = NotifierProvider<TrafficNotifier, TrafficState>(TrafficNotifier.new);
