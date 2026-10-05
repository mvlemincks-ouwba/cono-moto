// Plan de navigation plein écran pendant une balade (avec ou sans itinéraire),
// façon GPS : cap en haut, carte inclinée, zoom selon la vitesse, motard dans
// le tiers bas, bandeau de manœuvre, panneau d'arrivée, gros boutons.
import 'dart:async';
import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/map/cm_map.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/shared.dart';
import '../fuel/fuel_ui.dart';
import '../garage/autonomy.dart';
import '../map/map_layers.dart';
import '../ride/ride_controller.dart';
import '../ride/ride_screen.dart';
import '../routes/guidance_controller.dart';
import '../social/social_providers.dart';
import '../social/social_sheets.dart';
import '../traffic/traffic_providers.dart';
import 'navigation_logic.dart';
import 'navigation_providers.dart';
import 'navigation_widgets.dart';
import 'quick_report_sheet.dart';
import 'where_to_screen.dart';

/// Valeur mémorisée tant que ses clés ne changent pas (évite de renvoyer
/// lignes et marqueurs à la carte à chaque image).
class _Memo<T> {
  List<Object?>? _keys;
  T? _value;

  T call(List<Object?> keys, T Function() compute) {
    final k = _keys;
    if (k != null && k.length == keys.length) {
      var same = true;
      for (var i = 0; i < k.length; i++) {
        if (k[i] != keys[i]) {
          same = false;
          break;
        }
      }
      if (same) return _value as T;
    }
    _keys = keys;
    return _value = compute();
  }
}

/// Plan de navigation. [onFinish] termine la balade (logique de RideScreen),
/// [onShowGauges] bascule sur le compteur.
class NavigationView extends ConsumerStatefulWidget {
  const NavigationView({super.key, required this.onFinish, required this.onShowGauges});

  final Future<void> Function() onFinish;
  final VoidCallback onShowGauges;

  @override
  ConsumerState<NavigationView> createState() => _NavigationViewState();
}

class _NavigationViewState extends ConsumerState<NavigationView> {
  static const _autoRecenterAfter = Duration(seconds: 15);

  CmMapController? _map;
  bool _following = true;
  bool _overview = false;
  Timer? _recenterTimer;
  ProviderSubscription<RiderPosition?>? _posSub;
  EdgeInsets _insets = EdgeInsets.zero;

  double? _zoom;
  double? _bearing;
  double? _speed;

  final _geometry = _Memo<NavRouteGeometry?>();
  final _split = _Memo<RouteSplit?>();
  final _incidents = _Memo<List<IncidentAhead>>();
  final _lines = _Memo<List<MapLine>>();
  final _markers = _Memo<List<MapMarker>>();

  @override
  void initState() {
    super.initState();
    _posSub = ref.listenManual<RiderPosition?>(positionHubProvider, (_, next) => _follow(next));
  }

  @override
  void dispose() {
    _recenterTimer?.cancel();
    _posSub?.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Caméra
  // ---------------------------------------------------------------------------

  void _follow(RiderPosition? p, {Duration duration = const Duration(milliseconds: 1000)}) {
    final map = _map;
    if (p == null || map == null || !_following || !mounted) return;
    final kmh = p.speedKmh;
    final speed = _speed = NavCamera.smoothSpeed(_speed, kmh);
    final toManeuver = ref.read(guidanceProvider)?.snapshot?.distanceToNextM;
    final zoom = _zoom = NavCamera.smoothZoom(_zoom, NavCamera.zoomForSpeed(speed, distanceToManeuverM: toManeuver));
    final bearing = _bearing = NavCamera.bearingFor(heading: p.heading, speedKmh: kmh, previous: _bearing);
    unawaited(
      map
          .followCamera(target: p.point, zoom: zoom, bearing: bearing ?? 0, tilt: NavCamera.tilt, duration: duration)
          .catchError((Object e) => debugPrint('Caméra navigation : $e')),
    );
  }

  void _onUserGesture() {
    if (_following) setState(() => _following = false);
    _overview = false;
    _armAutoRecenter();
  }

  void _armAutoRecenter() {
    _recenterTimer?.cancel();
    _recenterTimer = Timer(_autoRecenterAfter, () {
      if (mounted && !_following) _recenter();
    });
  }

  Future<void> _recenter() async {
    _recenterTimer?.cancel();
    HapticFeedback.selectionClick();
    setState(() {
      _following = true;
      _overview = false;
    });
    await _map?.setContentInsets(_insets);
    _follow(ref.read(positionHubProvider), duration: const Duration(milliseconds: 700));
  }

  Future<void> _showOverview(List<GeoPoint> points) async {
    if (points.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _following = false;
      _overview = true;
    });
    _armAutoRecenter();
    final here = ref.read(positionHubProvider)?.point;
    final map = _map;
    if (map == null) return;
    await map.setContentInsets(EdgeInsets.zero);
    await map.fitPoints([...points, ?here], padding: const EdgeInsets.fromLTRB(48, 200, 48, 160));
  }

  void _lookAt(GeoPoint p) {
    setState(() => _following = false);
    _armAutoRecenter();
    _map?.moveTo(p, zoom: 15);
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  void _toggleVoice() {
    final on = !ref.read(settingsProvider).voiceGuidance;
    HapticFeedback.selectionClick();
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(voiceGuidance: on));
    if (!on) ref.read(voiceGuideProvider).stop();
    showCmSnack(context, on ? 'Voix activée' : 'Voix coupée');
  }

  void _openFuel(NavRouteGeometry? geometry, double progressM) {
    final here = ref.read(positionHubProvider)?.point;
    showFuelStationsSheet(context, alongRoute: geometry?.ahead(progressM), near: here);
  }

  void _openWhereTo() => Navigator.of(context).push(WhereToScreen.route());

  void _stopNavigation() {
    HapticFeedback.mediumImpact();
    ref.read(activeRouteProvider.notifier).clear();
    showCmSnack(context, 'Navigation arrêtée, la balade continue.');
  }

  Future<void> _confirmFinish() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Theme(
        data: RideScreen.hudTheme,
        child: AlertDialog(
          icon: const Icon(Icons.flag_rounded, color: CmColors.orange, size: 36),
          title: const Text('Terminer la balade ?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Continuer à rouler')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: CmColors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Terminer'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await widget.onFinish();
  }

  void _showMenu({required bool hasRoute}) {
    final ctrl = ref.read(rideControllerProvider.notifier);
    final paused = ref.read(rideControllerProvider).isPaused;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        void run(VoidCallback action) {
          Navigator.pop(ctx);
          action();
        }

        return Theme(
          data: RideScreen.hudTheme,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasRoute) ...[
                    _MenuTile(
                      icon: Icons.close_rounded,
                      label: 'Arrêter la navigation',
                      subtitle: 'La balade continue sans itinéraire',
                      onTap: () => run(_stopNavigation),
                    ),
                    _MenuTile(
                      icon: Icons.alt_route_rounded,
                      label: 'Recalculer l\'itinéraire',
                      onTap: () => run(() => ref.read(guidanceProvider.notifier).recalculate()),
                    ),
                  ],
                  _MenuTile(
                    icon: Icons.search_rounded,
                    label: hasRoute ? 'Changer de destination' : 'Où on va ?',
                    onTap: () => run(_openWhereTo),
                  ),
                  _MenuTile(
                    icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    label: paused ? 'Reprendre la balade' : 'Mettre en pause',
                    onTap: () => run(() {
                      HapticFeedback.mediumImpact();
                      paused ? ctrl.resume() : ctrl.pause();
                    }),
                  ),
                  _MenuTile(icon: Icons.speed_rounded, label: 'Vue compteur', onTap: () => run(widget.onShowGauges)),
                  _MenuTile(
                    icon: Icons.local_gas_station_rounded,
                    label: 'Ajouter un plein',
                    onTap: () => run(() => showFuelEntryForm(context, rideId: ref.read(rideControllerProvider).rideId)),
                  ),
                  _MenuTile(
                    icon: Icons.share_location_rounded,
                    label: 'Partager ma position en direct',
                    onTap: () => run(() => showShareLocationSheet(context)),
                  ),
                  _MenuTile(
                    icon: Icons.keyboard_arrow_down_rounded,
                    label: 'Réduire (la balade continue)',
                    onTap: () => run(() => Navigator.of(context).maybePop()),
                  ),
                  const SizedBox(height: 4),
                  _MenuTile(
                    icon: Icons.stop_circle_rounded,
                    label: 'Terminer la balade',
                    color: CmColors.red,
                    onTap: () => run(_confirmFinish),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Construction
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final guidance = ref.watch(guidanceProvider);
    final activeRoute = ref.watch(activeRouteProvider);
    final route = guidance?.route ?? activeRoute;
    final snap = guidance?.snapshot;
    final progress = snap?.progressM ?? 0;
    final settings = ref.watch(settingsProvider);
    final traffic = ref.watch(trafficProvider.select((t) => t.incidents));
    final track = route == null ? ref.watch(rideControllerProvider.select((s) => s.track)) : const <GeoPoint>[];
    final friends = settings.showFriends ? (ref.watch(friendsLiveProvider).value ?? const []) : const <FriendLive>[];
    final reports = settings.showReports ? (ref.watch(roadReportsProvider).value ?? const []) : const <RoadReport>[];
    final rallies = ref.watch(rallyPointsProvider).value ?? const <RallyPoint>[];
    final lowFuel = ref.watch(rideControllerProvider.select((s) => s.lowFuelAlert));
    final gpsLost = ref.watch(rideControllerProvider.select((s) => s.gpsLost));
    final hasFix = ref.watch(rideControllerProvider.select((s) => s.hasFix));

    final geometry = _geometry([
      route,
    ], () => route == null || route.points.length < 2 ? null : NavRouteGeometry(route));
    final split = _split([geometry, (progress / 20).floor()], () => geometry?.split(progress));
    final located = _incidents([geometry, traffic, settings.showTraffic], () {
      if (geometry == null || !settings.showTraffic) return const <IncidentAhead>[];
      return RouteIncidents.locate(geometry.points, traffic);
    });
    final incidentAhead = geometry == null ? null : RouteIncidents.next(located, geometry.displayDistance(progress));
    final lines = _lines([split, track, traffic, settings.showTraffic], () {
      return [
        if (split != null && split.done.length >= 2)
          MapLine(id: 'nav-done', points: split.done, color: navDoneColor, width: 8, opacity: 0.9, casing: false),
        if (split != null && split.remaining.length >= 2)
          MapLine(id: 'nav-route', points: split.remaining, color: CmColors.orange, width: 11),
        if (route == null && track.length >= 2)
          MapLine(id: 'nav-track', points: track, color: CmColors.teal, width: 5, opacity: 0.9),
        if (settings.showTraffic)
          for (final i in traffic) ?MapLayers.incidentLine(i),
      ];
    });
    final markers = _markers([route, traffic, settings.showTraffic, friends, reports, rallies], () {
      return [
        if (route != null)
          for (final m in MapLayers.routeEnds(route))
            if (m.id.startsWith('route-end')) m,
        if (settings.showTraffic)
          for (final i in traffic) MapLayers.incident(i),
        for (final r in reports) MapLayers.report(r),
        for (final rp in rallies) MapLayers.rally(rp),
        for (final f in friends) MapLayers.friend(f),
      ];
    });

    final arrived = snap?.arrived ?? false;
    final eta = route == null || snap == null
        ? null
        : NavEta.compute(
            remainingM: snap.remainingM,
            totalM: snap.totalM,
            routeDurationS: route.durationS,
            now: DateTime.now(),
          );
    final sos = friends.where((f) => f.sos).toList();

    final notices = <Widget>[
      if (incidentAhead != null && !arrived) NavIncidentBanner(ahead: incidentAhead),
      if (lowFuel)
        NavFuelAlert(
          autonomy: ref.watch(autonomyProvider),
          onStations: () => _openFuel(geometry, progress),
          onDismiss: ref.read(rideControllerProvider.notifier).dismissLowFuelAlert,
        ),
      for (final f in sos)
        NavNotice(
          icon: Icons.sos_rounded,
          text: '${f.name} a peut-être chuté ! Toucher pour voir où.',
          color: CmColors.red,
          onTap: () => _lookAt(f.location),
        ),
      if (guidance?.error != null)
        NavNotice(
          icon: Icons.error_outline_rounded,
          text: guidance!.error!,
          color: CmColors.red.withValues(alpha: 0.92),
          onTap: ref.read(guidanceProvider.notifier).dismissError,
        ),
      if (gpsLost || !hasFix)
        NavNotice(
          icon: gpsLost ? Icons.gps_off_rounded : Icons.gps_not_fixed_rounded,
          text: gpsLost ? 'GPS perdu, on cherche…' : 'Recherche du GPS…',
          color: gpsLost ? CmColors.red : CmColors.asphalt600,
        ),
    ];

    final Widget top;
    if (route == null) {
      top = const Align(alignment: Alignment.centerLeft, child: NavFreeRideHeader());
    } else if (snap == null) {
      top = NavWaitingBanner(name: route.name);
    } else if (arrived) {
      top = const SizedBox.shrink();
    } else if (snap.offRoute || (guidance?.recalculating ?? false)) {
      top = NavOffRouteBanner(
        distanceFromRouteM: snap.distanceFromRouteM,
        recalculating: guidance?.recalculating ?? false,
        onRecalculate: () => ref.read(guidanceProvider.notifier).recalculate(),
      );
    } else {
      top = NavManeuverBanner(snapshot: snap);
    }

    final buttons = <Widget>[
      NavRoundButton(
        icon: settings.voiceGuidance ? Icons.volume_up_rounded : Icons.volume_off_rounded,
        tooltip: settings.voiceGuidance ? 'Couper la voix' : 'Activer la voix',
        color: settings.voiceGuidance ? Colors.white : CmColors.amber,
        onPressed: _toggleVoice,
      ),
      NavRoundButton(
        icon: Icons.local_gas_station_rounded,
        tooltip: 'Essence sur la route',
        color: CmColors.amber,
        onPressed: () => _openFuel(geometry, progress),
      ),
      if (geometry != null)
        NavRoundButton(
          icon: Icons.zoom_out_map_rounded,
          tooltip: 'Vue d\'ensemble',
          active: _overview,
          onPressed: () => _showOverview(split?.remaining.isNotEmpty == true ? split!.remaining : geometry.points),
        )
      else
        NavRoundButton(icon: Icons.search_rounded, tooltip: 'Où on va ?', onPressed: _openWhereTo),
      NavRoundButton(icon: Icons.speed_rounded, tooltip: 'Vue compteur', onPressed: widget.onShowGauges),
    ];

    final bottom = arrived && route != null
        ? NavArrivalPanel(
            route: route,
            onFinish: () {
              HapticFeedback.heavyImpact();
              widget.onFinish();
            },
            onContinue: () {
              ref.read(activeRouteProvider.notifier).clear();
              showCmSnack(context, 'C\'est reparti en balade libre !');
            },
          )
        : NavBottomPanel(
            eta: eta,
            onMenu: () => _showMenu(hasRoute: route != null),
            onResume: ref.read(rideControllerProvider.notifier).resume,
          );

    return LayoutBuilder(
      builder: (context, c) {
        final landscape = c.maxWidth > c.maxHeight * 1.1;
        return landscape
            ? _landscape(c, lines, markers, top, notices, buttons, bottom)
            : _portrait(c, lines, markers, top, notices, buttons, bottom);
      },
    );
  }

  Widget _mapLayer(List<MapLine> lines, List<MapMarker> markers, EdgeInsets insets) {
    if (debugDisableNavigationMaps) {
      return const ColoredBox(key: ValueKey('nav-map-placeholder'), color: CmColors.asphalt700);
    }
    return CmMap(
      lines: lines,
      markers: markers,
      initialZoom: 16.5,
      tilt: NavCamera.tilt,
      compassEnabled: false,
      contentInsets: _overview ? EdgeInsets.zero : insets,
      onUserGesture: _onUserGesture,
      onCreated: (m) {
        _map = m;
        _follow(ref.read(positionHubProvider), duration: const Duration(milliseconds: 300));
      },
      onMarkerTap: _onMarkerTap,
      attributionMargin: const Point(8, 8),
    );
  }

  void _onMarkerTap(MapMarker m) {
    final p = m.payload;
    if (p is RoadReport) showReportDetailsSheet(context, p);
  }

  Widget _portrait(
    BoxConstraints c,
    List<MapLine> lines,
    List<MapMarker> markers,
    Widget top,
    List<Widget> notices,
    List<Widget> buttons,
    Widget bottom,
  ) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, mc) {
              _insets = NavCamera.riderInsets(Size(mc.maxWidth, mc.maxHeight), bottomOverlay: 120);
              return Stack(
                children: [
                  Positioned.fill(child: _mapLayer(lines, markers, _insets)),
                  if (!_following)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: mc.maxHeight < 420 ? 112 : 140,
                      child: Center(child: NavRecenterButton(onPressed: _recenter)),
                    ),
                  Positioned.fill(
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            top,
                            const SizedBox(height: 10),
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: _noticeColumn(notices)),
                                  const SizedBox(width: 10),
                                  _buttonColumn(buttons),
                                ],
                              ),
                            ),
                            _bottomRow(compact: mc.maxHeight < 420),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        bottom,
      ],
    );
  }

  Widget _landscape(
    BoxConstraints c,
    List<MapLine> lines,
    List<MapMarker> markers,
    Widget top,
    List<Widget> notices,
    List<Widget> buttons,
    Widget bottom,
  ) {
    final side = (c.maxWidth * 0.48).clamp(320.0, 460.0);
    _insets = NavCamera.riderInsets(Size(c.maxWidth, c.maxHeight), leftOverlay: side, fraction: 0.62);
    return Stack(
      children: [
        Positioned.fill(child: _mapLayer(lines, markers, _insets)),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: side,
          child: SafeArea(
            right: false,
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                  child: top is NavManeuverBanner ? NavManeuverBanner(snapshot: top.snapshot, compact: true) : top,
                ),
                Expanded(
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: _noticeColumn(notices)),
                ),
                bottom,
              ],
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: SafeArea(
            left: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: _buttonColumn(buttons, size: 54)),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const NavSpeedBubble(size: 80),
                      const SizedBox(width: 10),
                      NavReportButton(size: 72, onPressed: () => showQuickReportSheet(context, ref)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!_following)
          Positioned(
            left: side + 12,
            bottom: 16,
            child: SafeArea(child: NavRecenterButton(onPressed: _recenter)),
          ),
      ],
    );
  }

  Widget _noticeColumn(List<Widget> notices) {
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      // Les zones vides laissent passer les gestes vers la carte.
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final n in notices) Padding(padding: const EdgeInsets.only(bottom: 8), child: n)],
      ),
    );
  }

  Widget _buttonColumn(List<Widget> buttons, {double size = 62}) {
    return LayoutBuilder(
      builder: (context, c) {
        // Petits écrans : boutons un peu plus petits plutôt que cachés.
        final fit = c.maxHeight.isFinite ? c.maxHeight / buttons.length - 10 : size;
        final s = fit.clamp(48.0, size).toDouble();
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          // Les zones vides laissent passer les gestes vers la carte.
          hitTestBehavior: HitTestBehavior.deferToChild,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final b in buttons)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: b is NavRoundButton
                      ? NavRoundButton(
                          icon: b.icon,
                          tooltip: b.tooltip,
                          onPressed: b.onPressed,
                          active: b.active,
                          color: b.color,
                          size: s,
                        )
                      : b,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _bottomRow({bool compact = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        NavSpeedBubble(size: compact ? 76 : 96),
        const SizedBox(width: 8),
        if (!compact)
          const Flexible(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: FittedBox(fit: BoxFit.scaleDown, child: NavLeanChip()),
            ),
          )
        else
          const Spacer(),
        const SizedBox(width: 8),
        NavReportButton(size: compact ? 72 : 88, onPressed: () => showQuickReportSheet(context, ref)),
      ],
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.icon, required this.label, required this.onTap, this.subtitle, this.color});

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? CmColors.orange;
    return ListTile(
      minTileHeight: 64,
      leading: Icon(icon, color: c, size: 30),
      title: Text(
        label,
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color),
      ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      onTap: onTap,
    );
  }
}
