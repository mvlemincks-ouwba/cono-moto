import 'dart:async';
import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/map/cm_map.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/shared.dart';
import '../../services/routing/geocoder.dart';
import '../fuel/fuel_providers.dart';
import '../fuel/fuel_ui.dart';
import '../navigation/destination_preview_screen.dart';
import '../navigation/where_to_screen.dart';
import '../offline/offline_maps_screen.dart';
import '../ride/ride_controller.dart';
import '../ride/ride_screen.dart';
import '../social/social_providers.dart';
import '../social/social_sheets.dart';
import '../traffic/traffic_providers.dart';
import 'map_layers.dart';

/// Carte principale : potes en direct, signalements, trafic, stations, balade.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  CmMapController? _map;
  FollowMode _follow = FollowMode.none;
  GeoBounds? _bounds;
  double _zoom = 5;
  GeoPoint? _stationsCenter;
  StreamSubscription<Position>? _idleSub;
  bool _centeredOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateMe(initial: true));
  }

  @override
  void dispose() {
    _idleSub?.cancel();
    super.dispose();
  }

  /// Position hors balade : un flux économe alimente le PositionHub.
  void _startIdleLocation() {
    if (_idleSub != null) return;
    _idleSub = ref.read(locationServiceProvider).idleStream().listen(
      (p) {
        if (ref.read(rideControllerProvider).isActive) return;
        ref.read(positionHubProvider.notifier).publish(RiderPosition.fromGeolocator(p));
      },
      onError: (_) {},
    );
  }

  Future<void> _locateMe({bool initial = false}) async {
    final loc = ref.read(locationServiceProvider);
    final access = await loc.ensurePermission();
    if (!mounted) return;
    if (access != LocationAccess.granted) {
      if (!initial) {
        showCmSnack(
          context,
          access == LocationAccess.serviceDisabled
              ? 'Active la localisation du téléphone.'
              : 'Autorise la localisation pour voir où tu es.',
          error: true,
        );
        if (access == LocationAccess.deniedForever) await loc.openSettings();
      }
      return;
    }
    _startIdleLocation();
    final pos = ref.read(positionHubProvider) ?? await loc.current();
    if (pos == null || !mounted) return;
    if (!ref.read(rideControllerProvider).isActive) {
      ref.read(positionHubProvider.notifier).publish(pos);
    }
    if (initial && _centeredOnce) return;
    _centeredOnce = true;
    await _map?.moveTo(pos.point, zoom: 12.5);
  }

  void _cycleFollow() {
    final next = switch (_follow) {
      FollowMode.none => FollowMode.follow,
      FollowMode.follow => FollowMode.heading,
      FollowMode.heading => FollowMode.none,
    };
    setState(() => _follow = next);
    if (next != FollowMode.none) _locateMe();
  }

  Future<void> _onCameraIdle(GeoBounds b) async {
    _bounds = b;
    _zoom = await _map?.zoom() ?? _zoom;
    unawaited(ref.read(trafficProvider.notifier).onViewport(b, _zoom));
    final c = b.center;
    // Arrondi ~5 km pour ne pas relancer la recherche des stations à chaque geste.
    final rounded = GeoPoint((c.lat * 20).round() / 20, (c.lng * 20).round() / 20);
    if (mounted && rounded != _stationsCenter) setState(() => _stationsCenter = rounded);
    if (mounted) setState(() {});
  }

  Future<void> _startRide() async {
    final ride = ref.read(rideControllerProvider);
    if (!ride.isActive) {
      await ref.read(rideControllerProvider.notifier).start(route: ref.read(activeRouteProvider));
    }
    if (mounted) await Navigator.of(context).push(RideScreen.route());
  }

  GeoPoint? get _myPoint => ref.read(positionHubProvider)?.point;

  void _onMarkerTap(MapMarker m) {
    final p = m.payload;
    switch (p) {
      case FriendLive f:
        _showFriend(f);
      case RoadReport r:
        showReportDetailsSheet(context, r);
      case RallyPoint rp:
        _showInfo(
          icon: Icons.flag_rounded,
          color: CmColors.sky,
          title: 'Regroupement · ${rp.label}',
          lines: ['Groupe ${rp.groupName}', 'Fixé par ${rp.setBy} ${Fmt.ago(rp.setAt)}'],
          at: rp.location,
        );
      case TrafficIncident i:
        _showInfo(
          icon: i.kind.icon,
          color: i.kind.color,
          title: i.kind.label + (i.roadName.isNotEmpty ? ' · ${i.roadName}' : ''),
          lines: [
            if (i.description.isNotEmpty) i.description,
            if (i.from.isNotEmpty || i.to.isNotEmpty) 'De ${i.from} vers ${i.to}',
            if (i.delayS != null && i.delayS! > 60) 'Retard estimé : ${Fmt.durationS(i.delayS!)}',
            if (i.endTime != null) 'Jusqu\'au ${Fmt.dateTime(i.endTime!)}',
          ],
          at: i.location,
        );
      case FuelStation s:
        showFuelStationsSheet(context, near: s.location);
    }
  }

  void _showFriend(FriendLive f) {
    final me = _myPoint;
    final dist = me == null ? null : Geo.distance(me, f.location);
    _showInfo(
      icon: Icons.two_wheeler,
      color: f.color,
      title: f.name,
      lines: [
        if (f.sos) '⚠️ Alerte chute / SOS en cours !',
        f.riding ? 'En balade · ${f.speedKmh.round()} km/h' : 'À l\'arrêt',
        if (f.bikeName != null && f.bikeName!.isNotEmpty) f.bikeName!,
        if (f.leanDeg != null && f.riding && f.leanDeg!.abs() >= 5) 'Penche à ${f.leanDeg!.abs().round()}°',
        if (dist != null) 'À ${Fmt.distance(dist)} de toi',
        'Position ${Fmt.ago(f.updatedAt)}',
      ],
      at: f.location,
    );
  }

  void _showInfo({
    required IconData icon,
    required Color color,
    required String title,
    required List<String> lines,
    required GeoPoint at,
  }) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(backgroundColor: color, child: Icon(icon, color: Colors.white)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(title, style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final l in lines)
                Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(l)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _map?.moveTo(at, zoom: 15);
                      },
                      icon: const Icon(Icons.center_focus_strong),
                      label: const Text('Centrer'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _navigateTo(at),
                      icon: const Icon(Icons.navigation_rounded),
                      label: const Text('Y aller'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _navigateTo(GeoPoint p) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=${p.lat},${p.lng}&travelmode=two-wheeler');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _onLongPress(GeoPoint p) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.campaign_outlined, color: CmColors.amber),
              title: const Text('Signaler quelque chose ici'),
              subtitle: const Text('Gravillons, contrôle, danger…'),
              onTap: () {
                Navigator.pop(ctx);
                showReportSheet(context, at: p);
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined, color: CmColors.sky),
              title: const Text('Point de regroupement ici'),
              onTap: () {
                Navigator.pop(ctx);
                showSetRallyPointSheet(context, at: p);
              },
            ),
            ListTile(
              leading: const Icon(Icons.local_gas_station_outlined, color: CmColors.green),
              title: const Text('Stations autour d\'ici'),
              onTap: () {
                Navigator.pop(ctx);
                showFuelStationsSheet(context, near: p);
              },
            ),
            ListTile(
              leading: const Icon(Icons.navigation_rounded, color: CmColors.orange),
              title: const Text('Y aller avec Cono Moto'),
              subtitle: const Text('Le plus rapide ou par les petites routes'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  DestinationPreviewScreen.route(
                    Place(name: 'Point choisi sur la carte', point: p, type: DestinationPreviewScreen.pinType),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.navigation_outlined),
              title: const Text('Y aller avec Google Maps'),
              onTap: () {
                Navigator.pop(ctx);
                _navigateTo(p);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showLayers() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Consumer(builder: (ctx, ref, _) {
        final s = ref.watch(settingsProvider);
        final n = ref.read(settingsProvider.notifier);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Sur la carte', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.groups_outlined),
                title: const Text('Mes potes en direct'),
                value: s.showFriends,
                onChanged: (v) => n.update((x) => x.copyWith(showFriends: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.campaign_outlined),
                title: const Text('Signalements des potes'),
                value: s.showReports,
                onChanged: (v) => n.update((x) => x.copyWith(showReports: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.traffic_outlined),
                title: const Text('Trafic : accidents, travaux, fermetures'),
                subtitle: s.effectiveTomtomKey.isEmpty ? const Text('Clé TomTom à ajouter dans les réglages') : null,
                value: s.showTraffic,
                onChanged: (v) => n.update((x) => x.copyWith(showTraffic: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.local_gas_station_outlined),
                title: Text('Prix ${s.fuelType.label} des stations'),
                subtitle: const Text('Visible en zoomant'),
                value: s.showStations,
                onChanged: (v) => n.update((x) => x.copyWith(showStations: v)),
              ),
              ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('Télécharger cette zone (hors-ligne)'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(OfflineMapsScreen.route(visibleBounds: _bounds));
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final ride = ref.watch(rideControllerProvider);
    final route = ref.watch(activeRouteProvider);
    final traffic = ref.watch(trafficProvider);
    final friends = settings.showFriends ? (ref.watch(friendsLiveProvider).value ?? const []) : const <FriendLive>[];
    final reports = settings.showReports ? (ref.watch(roadReportsProvider).value ?? const []) : const <RoadReport>[];
    final rallies = ref.watch(rallyPointsProvider).value ?? const <RallyPoint>[];
    final showStations = settings.showStations && _stationsCenter != null && _zoom >= 10.5;
    final stations = showStations
        ? (ref.watch(stationsAroundProvider(_stationsCenter!)).value ?? const <FuelStation>[])
        : const <FuelStation>[];
    final sosFriends = friends.where((f) => f.sos).toList();

    ref.listen(mapFocusProvider, (prev, next) {
      if (next == null) return;
      setState(() => _follow = FollowMode.none);
      _map?.moveTo(next, zoom: 14.5);
      ref.read(mapFocusProvider.notifier).consumed();
    });

    final lines = <MapLine>[
      if (route != null) ...MapLayers.route(route),
      if (ride.isActive && ride.track.length > 1)
        MapLine(id: 'my-track', points: ride.track, color: CmColors.teal, width: 4),
      if (settings.showTraffic)
        for (final i in traffic.incidents) ?MapLayers.incidentLine(i),
    ];
    final markers = <MapMarker>[
      if (route != null) ...MapLayers.routeEnds(route),
      if (settings.showTraffic) for (final i in traffic.incidents) MapLayers.incident(i),
      ...MapLayers.stations(stations, settings.fuelType),
      for (final r in reports) MapLayers.report(r),
      for (final rp in rallies) MapLayers.rally(rp),
      for (final f in friends) MapLayers.friend(f),
    ];
    final ridingFriends = friends.where((f) => f.riding && !f.isStale).length;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: CmMap(
              lines: lines,
              markers: markers,
              followMode: _follow,
              tilt: 45,
              onFollowModeChanged: (m) => setState(() => _follow = m),
              onCreated: (c) {
                _map = c;
                final p = ref.read(positionHubProvider);
                if (p != null && !_centeredOnce) {
                  _centeredOnce = true;
                  c.moveTo(p.point, zoom: 12.5, animate: false);
                }
              },
              onCameraIdle: _onCameraIdle,
              onMarkerTap: _onMarkerTap,
              onMapLongPress: _onLongPress,
              attributionMargin: const Point(8, 110),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(
                    ridingFriends: ridingFriends,
                    onlineFriends: friends.where((f) => !f.isStale).length,
                    trafficCount: settings.showTraffic ? traffic.incidents.length : null,
                    trafficLoading: traffic.loading,
                    trafficError: settings.showTraffic && settings.effectiveTomtomKey.isNotEmpty ? traffic.error : null,
                    onSearch: () => Navigator.of(context).push(WhereToScreen.route()),
                  ),
                  for (final f in sosFriends) ...[
                    const SizedBox(height: 8),
                    _SosBanner(friend: f, onTap: () => _map?.moveTo(f.location, zoom: 15)),
                  ],
                  if (route != null && !ride.isActive) ...[
                    const SizedBox(height: 8),
                    _ActiveRouteCard(
                      name: route.name,
                      distance: Fmt.distance(route.distanceM),
                      onShow: () => _map?.fitPoints(route.points,
                          padding: const EdgeInsets.fromLTRB(40, 160, 40, 200)),
                      onClear: () => ref.read(activeRouteProvider.notifier).clear(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Boutons latéraux.
          Positioned(
            right: 12,
            bottom: 128,
            child: SafeArea(
              child: Column(
                children: [
                  MapRoundButton(icon: Icons.layers_outlined, tooltip: 'Calques', onPressed: _showLayers),
                  const SizedBox(height: 10),
                  MapRoundButton(
                    icon: Icons.local_gas_station_outlined,
                    tooltip: 'Stations essence',
                    onPressed: () => showFuelStationsSheet(context, near: _myPoint ?? _bounds?.center),
                  ),
                  const SizedBox(height: 10),
                  MapRoundButton(
                    icon: Icons.campaign_outlined,
                    tooltip: 'Signaler',
                    onPressed: () {
                      final at = _myPoint;
                      if (at == null) {
                        showCmSnack(context, 'Position inconnue : appuie longuement sur la carte pour signaler.');
                        return;
                      }
                      showReportSheet(context, at: at);
                    },
                  ),
                  const SizedBox(height: 10),
                  MapRoundButton(
                    icon: Icons.share_location_outlined,
                    tooltip: 'Partager ma position',
                    onPressed: () => showShareLocationSheet(context),
                  ),
                  const SizedBox(height: 10),
                  MapRoundButton(
                    icon: switch (_follow) {
                      FollowMode.none => Icons.my_location,
                      FollowMode.follow => Icons.gps_fixed,
                      FollowMode.heading => Icons.explore,
                    },
                    active: _follow != FollowMode.none,
                    tooltip: 'Me suivre',
                    onPressed: _cycleFollow,
                  ),
                ],
              ),
            ),
          ),
          // Gros bouton « Rouler ».
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: _RideButton(
                active: ride.isActive,
                distance: Fmt.distance(ride.distanceM),
                hasRoute: route != null,
                onPressed: _startRide,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Barre du haut : « Où on va ? » (recherche de destination) + état des potes
/// et du trafic.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.ridingFriends,
    required this.onlineFriends,
    required this.trafficCount,
    required this.trafficLoading,
    required this.trafficError,
    required this.onSearch,
  });

  final int ridingFriends;
  final int onlineFriends;
  final int? trafficCount;
  final bool trafficLoading;
  final String? trafficError;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final friends = ridingFriends > 0 ? ridingFriends : onlineFriends;
    return Semantics(
      button: true,
      label: 'Où on va ? Rechercher une destination',
      child: GlassPanel(
        padding: EdgeInsets.zero,
        radius: 22,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onSearch,
          child: SizedBox(
            height: 58,
            child: Row(
              children: [
                const SizedBox(width: 12),
                const _Logo(),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.search_rounded, color: CmColors.orange, size: 24),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Où on va ?',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: scheme.onSurface),
                        ),
                      ),
                    ],
                  ),
                ),
                if (friends > 0) ...[
                  Tooltip(
                    message: ridingFriends > 0
                        ? '$ridingFriends pote${ridingFriends > 1 ? 's' : ''} en balade'
                        : '$onlineFriends pote${onlineFriends > 1 ? 's' : ''}',
                    child: Pill(icon: Icons.two_wheeler, label: '$friends', color: CmColors.teal),
                  ),
                  const SizedBox(width: 6),
                ],
                if (trafficLoading) ...[
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 6),
                ] else if (trafficError != null) ...[
                  Tooltip(
                    message: trafficError!,
                    child: const Icon(Icons.wifi_off_rounded, size: 18, color: CmColors.amber),
                  ),
                  const SizedBox(width: 6),
                ] else if (trafficCount != null && trafficCount! > 0) ...[
                  Pill(icon: Icons.warning_amber_rounded, label: '$trafficCount', color: CmColors.amber),
                  const SizedBox(width: 6),
                ],
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Cône Cono Moto (dans la barre « Où on va ? »).
class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: const BoxDecoration(color: CmColors.orange, shape: BoxShape.circle),
      child: const Icon(Icons.change_history_rounded, size: 20, color: Colors.white),
    );
  }
}

class _SosBanner extends StatelessWidget {
  const _SosBanner({required this.friend, required this.onTap});

  final FriendLive friend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CmColors.red,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.sos_rounded, color: Colors.white, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${friend.name} a peut-être chuté ! Toucher pour voir où.',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActiveRouteCard extends StatelessWidget {
  const _ActiveRouteCard({required this.name, required this.distance, required this.onShow, required this.onClear});

  final String name;
  final String distance;
  final VoidCallback onShow;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      child: Row(
        children: [
          const Icon(Icons.route, color: CmColors.orange),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: onShow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text('Balade prévue · $distance', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
          IconButton(onPressed: onClear, icon: const Icon(Icons.close), tooltip: 'Retirer l\'itinéraire'),
        ],
      ),
    );
  }
}

class _RideButton extends StatelessWidget {
  const _RideButton({required this.active, required this.distance, required this.hasRoute, required this.onPressed});

  final bool active;
  final String distance;
  final bool hasRoute;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(color: CmColors.orange.withValues(alpha: 0.45), blurRadius: 24, offset: const Offset(0, 8)),
        ],
      ),
      child: Material(
        color: active ? CmColors.orangeDeep : CmColors.orange,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onPressed,
          child: SizedBox(
            height: 68,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(active ? Icons.speed_rounded : Icons.two_wheeler_rounded, color: Colors.white, size: 30),
                const SizedBox(width: 12),
                Text(
                  active ? 'BALADE EN COURS · $distance' : (hasRoute ? 'ROULER CETTE BALADE' : 'ROULER'),
                  style: CmTheme.numbers(size: 26, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
