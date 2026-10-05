import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/map/cm_map.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../services/routing/geocoder.dart';
import '../../services/routing/http_support.dart';
import '../ride/ride_controller.dart';
import '../routes/routes_providers.dart';
import 'destination_routing.dart';
import 'navigation_providers.dart';

/// Aperçu avant de partir : « Le plus rapide » et « Par les petites routes »,
/// distance, durée, heure d'arrivée, tracés sur la carte, puis « C'est parti ».
class DestinationPreviewScreen extends ConsumerStatefulWidget {
  const DestinationPreviewScreen({super.key, required this.destination});

  final Place destination;

  /// Lieu sans nom (appui long sur la carte) : on cherche une adresse.
  static const pinType = 'pin';

  static Route<void> route(Place destination) =>
      MaterialPageRoute(builder: (_) => DestinationPreviewScreen(destination: destination));

  @override
  ConsumerState<DestinationPreviewScreen> createState() => _DestinationPreviewScreenState();
}

class _DestinationPreviewScreenState extends ConsumerState<DestinationPreviewScreen> {
  static const _otherColor = Color(0xFF8E97A6);

  GeoPoint? _start;
  String? _startError;
  String? _niceName;
  DestinationOption _selected = DestinationOption.fastest;
  CmMapController? _map;
  Object? _fittedFor;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _locate();
    if (widget.destination.type == DestinationPreviewScreen.pinType) _reverse();
  }

  Future<void> _locate() async {
    final hub = ref.read(positionHubProvider)?.point;
    if (hub != null) {
      _start = hub;
      return;
    }
    final pos = await ref.read(locationServiceProvider).current();
    if (!mounted) return;
    setState(() {
      _start = pos?.point;
      _startError = pos == null ? 'Position inconnue : active la localisation pour calculer l\'itinéraire.' : null;
    });
  }

  Future<void> _reverse() async {
    try {
      final p = await ref.read(geocoderProvider).reverse(widget.destination.point).timeout(const Duration(seconds: 6));
      if (!mounted || p == null) return;
      setState(() => _niceName = p.name);
    } catch (_) {
      // Pas grave : on garde « Point choisi sur la carte ».
    }
  }

  String get _name => _niceName ?? widget.destination.name;

  void _fit(DestinationPlans plans) {
    final map = _map;
    if (map == null || identical(_fittedFor, plans)) return;
    _fittedFor = plans;
    final pts = [for (final p in plans.plans) ...p.route.points];
    if (pts.isNotEmpty) map.fitPoints(pts, padding: const EdgeInsets.fromLTRB(40, 110, 40, 40));
  }

  Future<void> _go(DestinationPlan plan) async {
    if (_starting) return;
    setState(() => _starting = true);
    HapticFeedback.mediumImpact();
    final route = _niceName == null ? plan.route : plan.route.copyWith(name: 'Vers $_niceName');
    try {
      await startNavigationTo(context, ref, route);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final start = _start;
    final query = start == null ? null : DestinationQuery(start: start, destination: widget.destination);
    final plans = query == null ? null : ref.watch(destinationPlansProvider(query));
    final data = plans?.value;
    final available = data?.plans ?? const <DestinationPlan>[];
    final selected = available.where((p) => p.option == _selected).firstOrNull ?? available.firstOrNull;
    if (data != null) WidgetsBinding.instance.addPostFrameCallback((_) => _fit(data));

    final lines = <MapLine>[
      for (final p in available)
        if (p != selected)
          MapLine(id: 'opt-${p.option.name}', points: p.route.points, color: _otherColor, width: 6, opacity: 0.9),
      if (selected != null)
        MapLine(id: 'opt-selected', points: selected.route.points, color: CmColors.orange, width: 8),
    ];
    final markers = <MapMarker>[
      if (start != null)
        MapMarker(id: 'dest-start', position: start, icon: Icons.two_wheeler_rounded, color: CmColors.green, size: 34),
      MapMarker(
        id: 'dest-end',
        position: widget.destination.point,
        icon: Icons.sports_score_rounded,
        color: const Color(0xFF111827),
        size: 36,
        zIndex: 5,
      ),
    ];
    final riding = ref.watch(rideControllerProvider.select((s) => s.isActive));

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: debugDisableNavigationMaps
                      ? ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHigh)
                      : CmMap(
                          lines: lines,
                          markers: markers,
                          initialCenter: start == null
                              ? widget.destination.point
                              : GeoBounds.fromPoints([start, widget.destination.point])!.center,
                          initialZoom: 9,
                          showUserLocation: false,
                          onCreated: (m) {
                            _map = m;
                            if (data != null) _fit(data);
                          },
                        ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: GlassPanel(
                      padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Retour',
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                          const Icon(Icons.sports_score_rounded, color: CmColors.orange),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                                ),
                                if (widget.destination.detail != null)
                                  Text(
                                    widget.destination.detail!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _BottomCard(
            child: switch ((start, plans)) {
              (null, _) when _startError != null => _Message(
                icon: Icons.location_off_rounded,
                text: _startError!,
                action: TextButton(onPressed: _locate, child: const Text('Réessayer')),
              ),
              (null, _) || (_, null) => const _Loading(text: 'On cherche où tu es…'),
              (_, final AsyncValue<DestinationPlans> p) when p.hasError && !p.isLoading => _Message(
                icon: Icons.wifi_off_rounded,
                text: p.error is RoutingException
                    ? (p.error as RoutingException).message
                    : 'Calcul de l\'itinéraire impossible pour le moment.',
                action: TextButton(
                  onPressed: () => ref.invalidate(destinationPlansProvider(query!)),
                  child: const Text('Réessayer'),
                ),
              ),
              (_, final AsyncValue<DestinationPlans> p) when p.value == null => const _Loading(
                text: 'On cherche les meilleures routes…',
              ),
              _ => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in available) ...[
                    _OptionCard(plan: p, selected: p == selected, onTap: () => setState(() => _selected = p.option)),
                    const SizedBox(height: 8),
                  ],
                  for (final n in data!.notes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded, size: 18, color: CmColors.sky),
                          const SizedBox(width: 8),
                          Expanded(child: Text(n, style: Theme.of(context).textTheme.bodySmall)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 68,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: CmColors.orange,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                      ),
                      onPressed: selected == null || _starting ? null : () => _go(selected),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.navigation_rounded, color: Colors.white, size: 30),
                            const SizedBox(width: 10),
                            Text(
                              riding ? 'Y ALLER' : 'C\'EST PARTI',
                              style: CmTheme.numbers(size: 28, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            },
          ),
        ],
      ),
    );
  }
}

class _BottomCard extends StatelessWidget {
  const _BottomCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 16)],
      ),
      child: SafeArea(
        top: false,
        child: Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 12), child: child),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        children: [
          const SizedBox.square(dimension: 26, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: CmColors.amber, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({required this.plan, required this.selected, required this.onTap});

  final DestinationPlan plan;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = plan.route;
    final arrival = plan.arrivalFrom(DateTime.now());
    final badges = <(IconData, String)>[
      if (plan.hasHighway) (Icons.add_road_rounded, 'Autoroute'),
      if (plan.hasToll) (Icons.euro_rounded, 'Péage'),
      if (r.curvatureScore >= 35) (Icons.gesture_rounded, 'Sinueux ${r.curvatureScore.round()}/100'),
    ];
    return Semantics(
      selected: selected,
      button: true,
      label: plan.option.label,
      child: Material(
        color: selected ? CmColors.orange.withValues(alpha: 0.12) : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: selected ? CmColors.orange : scheme.outlineVariant, width: selected ? 2.5 : 1),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: selected ? CmColors.orange : scheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(plan.option.icon, color: selected ? Colors.white : scheme.onSurface),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(plan.option.label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                      const SizedBox(height: 2),
                      Text(
                        '${Fmt.distance(r.distanceM)} · arrivée ${Fmt.time(arrival)}',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                      ),
                      if (badges.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final (icon, label) in badges) Pill(icon: icon, label: label, color: CmColors.sky),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  Fmt.durationS(r.durationS),
                  style: CmTheme.numbers(size: 30, color: selected ? CmColors.orange : scheme.onSurface),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
