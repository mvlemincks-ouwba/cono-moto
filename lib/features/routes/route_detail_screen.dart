import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/map/cm_map.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/planned_route.dart';
import '../../services/routing/elevation_client.dart';
import '../../services/routing/http_support.dart';
import '../../services/routing/maneuver_kinds.dart';
import '../../services/routing/route_scoring.dart';
import '../social/social_sheets.dart';
import 'elevation_chart.dart';
import 'route_actions.dart';
import 'route_ui.dart';
import 'route_weather_card.dart';
import 'routes_providers.dart';

/// Détail d'une balade planifiée : carte, profil, météo, bouton « C'est parti ».
class RouteDetailScreen extends ConsumerStatefulWidget {
  const RouteDetailScreen({super.key, required this.route, this.departure});

  final PlannedRoute route;

  /// Heure de départ prévue (météo), sinon la prochaine heure pleine.
  final DateTime? departure;

  static Route<void> pageRoute(PlannedRoute route, {DateTime? departure}) => MaterialPageRoute(
    builder: (_) => RouteDetailScreen(route: route, departure: departure),
  );

  @override
  ConsumerState<RouteDetailScreen> createState() => _RouteDetailScreenState();
}

enum _MenuAction { rename, shareFriends, exportGpx, reroute, save, delete }

class _RouteDetailScreenState extends ConsumerState<RouteDetailScreen> {
  late PlannedRoute _route = widget.route;

  /// Null tant qu'on ne sait pas si la balade est dans « Mes balades ».
  bool? _saved;
  bool _busy = false;
  bool _showAllSteps = false;
  CmMapController? _map;
  PlannedRoute? _mapRoute;
  List<MapLine> _mapLines = const [];
  List<MapMarker> _mapMarkers = const [];

  /// Couches de la carte, recalculées seulement si la géométrie change.
  void _syncMapLayers(PlannedRoute r, Color color, bool sparse) {
    if (_mapRoute != null && identical(_mapRoute!.points, r.points) && _mapRoute!.style == r.style) return;
    _mapRoute = r;
    _mapLines = [MapLine(id: 'route', points: r.points, color: color, width: 5, dashed: sparse)];
    _mapMarkers = [
      if (r.points.isNotEmpty)
        MapMarker(id: 'start', position: r.points.first, icon: Icons.flag, color: CmColors.green, zIndex: 2),
      if (r.points.length > 1 && Geo.distance(r.points.first, r.points.last) > 200)
        MapMarker(id: 'end', position: r.points.last, icon: Icons.sports_score, color: Colors.white),
    ];
  }

  @override
  void initState() {
    super.initState();
    ref.read(routeRepositoryProvider).get(_route.id).then((r) {
      if (!mounted) return;
      setState(() {
        _saved = r != null;
        if (r != null) _route = r;
      });
    });
  }

  Future<void> _persist(PlannedRoute r) async {
    setState(() => _route = r);
    if (_saved == true) await ref.read(routeRepositoryProvider).upsert(r);
  }

  Future<void> _toggleFavorite() async {
    final r = _route.copyWith(favorite: !_route.favorite);
    setState(() => _route = r);
    await ref.read(routeRepositoryProvider).upsert(r);
    if (!mounted) return;
    setState(() => _saved = true);
    showCmSnack(context, r.favorite ? 'Ajoutée aux favoris.' : 'Retirée des favoris.');
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _route.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renommer la balade'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          maxLength: 60,
          decoration: const InputDecoration(hintText: 'Ex : Tour des lacs du dimanche'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Renommer')),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == _route.name) return;
    await _persist(_route.copyWith(name: trimmed));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const Text('Supprimer la balade ?'),
        content: Text('« ${_route.name} » disparaîtra de tes balades à faire.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Garder')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CmColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(routeRepositoryProvider).delete(_route.id);
    if (!mounted) return;
    showCmSnack(context, 'Balade supprimée.');
    Navigator.of(context).pop();
  }

  Future<void> _save() async {
    await saveRoute(context, ref, _route);
    if (mounted) setState(() => _saved = true);
  }

  Future<void> _reroute() async {
    setState(() => _busy = true);
    try {
      final r = await rerouteAlongRoads(ref, _route);
      if (!mounted) return;
      await _persist(r);
      if (!mounted) return;
      showCmSnack(context, 'Trajet recalculé : ${Fmt.distance(r.distanceM)} en suivant les routes.');
      _map?.fitPoints(r.points);
    } on RoutingException catch (e) {
      if (mounted) showCmSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onMenu(_MenuAction a) async {
    switch (a) {
      case _MenuAction.rename:
        await _rename();
      case _MenuAction.shareFriends:
        await shareRouteWithFriends(context, _route);
      case _MenuAction.exportGpx:
        await shareRouteGpx(context, _route);
      case _MenuAction.reroute:
        await _reroute();
      case _MenuAction.save:
        await _save();
      case _MenuAction.delete:
        await _delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = _route;
    final color = styleColor(r.style);
    final profileAsync = ref.watch(routeProfileProvider(RouteKey(r)));
    final profile = profileAsync.value;

    // D+ calculé après coup : on le mémorise pour la liste.
    ref.listen<AsyncValue<ElevationProfile>>(routeProfileProvider(RouteKey(r)), (_, next) {
      final p = next.value;
      if (p != null && !p.isEmpty && _route.elevationGainM <= 0 && p.stats.gainM > 0) {
        _persist(_route.copyWith(elevationGainM: p.stats.gainM));
      }
    });

    final gain = r.elevationGainM > 0 ? r.elevationGainM : profile?.stats.gainM;
    final metrics = RouteMetrics(
      distanceM: r.distanceM,
      durationS: r.durationS,
      curvature: r.curvatureScore,
      elevationGainM: gain,
    );
    final badges = RouteScoring.badges(metrics, style: r.style, max: 5);
    final sparse = isSparseRoute(r);
    _syncMapLayers(r, color, sparse);
    final steps = r.maneuvers.where((m) => m.type != ManeuverKind.depart || r.maneuvers.length < 3).toList();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            stretch: true,
            backgroundColor: CmColors.asphalt900,
            foregroundColor: Colors.white,
            title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: r.favorite ? 'Retirer des favoris' : 'Mettre en favori',
                onPressed: _toggleFavorite,
                icon: Icon(r.favorite ? Icons.star : Icons.star_border, color: r.favorite ? CmColors.amber : null),
              ),
              PopupMenuButton<_MenuAction>(
                onSelected: _onMenu,
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: _MenuAction.rename,
                    child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Renommer')),
                  ),
                  const PopupMenuItem(
                    value: _MenuAction.shareFriends,
                    child: ListTile(leading: Icon(Icons.groups_outlined), title: Text('Partager aux potes')),
                  ),
                  const PopupMenuItem(
                    value: _MenuAction.exportGpx,
                    child: ListTile(leading: Icon(Icons.ios_share), title: Text('Exporter en GPX')),
                  ),
                  if (canFollowRoads(r))
                    const PopupMenuItem(
                      value: _MenuAction.reroute,
                      child: ListTile(leading: Icon(Icons.alt_route), title: Text('Suivre les routes')),
                    ),
                  if (_saved == false)
                    const PopupMenuItem(
                      value: _MenuAction.save,
                      child: ListTile(leading: Icon(Icons.bookmark_add_outlined), title: Text('Enregistrer')),
                    ),
                  if (_saved == true)
                    const PopupMenuItem(
                      value: _MenuAction.delete,
                      child: ListTile(
                        leading: Icon(Icons.delete_outline, color: CmColors.red),
                        title: Text('Supprimer', style: TextStyle(color: CmColors.red)),
                      ),
                    ),
                ],
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (debugDisableRouteMaps)
                    const ColoredBox(color: CmColors.asphalt700)
                  else
                    CmMap(
                      interactive: false,
                      showUserLocation: false,
                      compassEnabled: false,
                      initialCenter: r.points.isEmpty ? null : r.points.first,
                      initialZoom: 9,
                      lines: _mapLines,
                      markers: _mapMarkers,
                      onCreated: (c) {
                        _map = c;
                        Future.delayed(const Duration(milliseconds: 400), () {
                          if (mounted) {
                            c.fitPoints(previewPoints(r), padding: const EdgeInsets.fromLTRB(36, 100, 36, 36));
                          }
                        });
                      },
                    ),
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.center,
                          colors: [Color(0xCC0B0D10), Color(0x000B0D10)],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.lg, CmSpacing.lg, 120),
            sliver: SliverList.list(
              children: [
                Text(r.name, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, height: 1.05)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    StylePill(r.style),
                    if (r.source == RouteSource.gpx)
                      const Pill(label: 'Import GPX', icon: Icons.upload_file, color: CmColors.sky),
                    if (r.author != null)
                      Pill(label: 'Par ${r.author}', icon: Icons.person_outline, color: CmColors.teal),
                    if (_saved == false)
                      const Pill(label: 'Pas encore enregistrée', icon: Icons.bookmark_border, color: CmColors.amber),
                  ],
                ),
                if (r.description.isNotEmpty) ...[
                  const SizedBox(height: CmSpacing.md),
                  Text(r.description, style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
                ],
                if (sparse) ...[const SizedBox(height: CmSpacing.md), _SparseBanner(busy: _busy, onReroute: _reroute)],
                const SizedBox(height: CmSpacing.lg),
                StatGrid(
                  compact: true,
                  children: [
                    StatTile(
                      label: 'Distance',
                      value: Fmt.km(r.distanceM, decimals: r.distanceM < 100000 ? 1 : 0),
                      unit: 'km',
                      icon: Icons.straighten,
                      color: CmColors.orange,
                    ),
                    StatTile(
                      label: 'Durée',
                      value: r.durationS > 0 ? Fmt.durationS(r.durationS) : '—',
                      icon: Icons.timer_outlined,
                    ),
                    StatTile(
                      label: 'Sinuosité',
                      value: sparse ? '—' : '${r.curvatureScore.round()}',
                      unit: sparse ? null : '/100',
                      icon: Icons.gesture,
                    ),
                    StatTile(
                      label: 'Dénivelé +',
                      value: gain == null ? '…' : Fmt.number(gain),
                      unit: gain == null ? null : 'm',
                      icon: Icons.landscape,
                    ),
                  ],
                ),
                if (badges.isNotEmpty) ...[const SizedBox(height: CmSpacing.md), BadgeWrap(badges)],
                const SectionHeader(
                  'Profil d\'altitude',
                  padding: EdgeInsets.fromLTRB(0, CmSpacing.xl, 0, CmSpacing.sm),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(CmSpacing.sm, CmSpacing.lg, CmSpacing.lg, CmSpacing.sm),
                    child: profileAsync.when(
                      loading: () => const SizedBox(height: 170, child: Center(child: CircularProgressIndicator())),
                      error: (e, _) => SizedBox(
                        height: 120,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '$e',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                              TextButton(
                                onPressed: () => ref.invalidate(routeProfileProvider(RouteKey(r))),
                                child: const Text('Réessayer'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      data: (p) => Column(
                        children: [
                          ElevationChart(profile: p, color: color),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(CmSpacing.md, CmSpacing.sm, 0, CmSpacing.sm),
                            child: Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              spacing: CmSpacing.md,
                              runSpacing: 4,
                              children: [
                                _ProfileFact(icon: Icons.north_east, label: '+${Fmt.number(p.stats.gainM)} m'),
                                _ProfileFact(icon: Icons.south_east, label: '−${Fmt.number(p.stats.lossM)} m'),
                                _ProfileFact(icon: Icons.terrain, label: 'max ${Fmt.number(p.stats.maxM)} m'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SectionHeader('Météo', padding: EdgeInsets.fromLTRB(0, CmSpacing.xl, 0, CmSpacing.sm)),
                RouteWeatherCard(route: r, departure: widget.departure),
                if (steps.isNotEmpty) ...[
                  SectionHeader(
                    'Roadbook',
                    padding: const EdgeInsets.fromLTRB(0, CmSpacing.xl, 0, CmSpacing.sm),
                    action: Text(
                      '${steps.length} étapes',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (final (i, m) in (_showAllSteps ? steps : steps.take(8)).indexed)
                          _RoadbookRow(maneuver: m, first: i == 0),
                        if (steps.length > 8)
                          TextButton.icon(
                            onPressed: () => setState(() => _showAllSteps = !_showAllSteps),
                            icon: Icon(_showAllSteps ? Icons.expand_less : Icons.expand_more),
                            label: Text(_showAllSteps ? 'Replier' : 'Voir les ${steps.length} étapes'),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.sm, CmSpacing.lg, CmSpacing.md),
          child: Row(
            children: [
              if (_saved == false) ...[
                OutlinedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Enregistrer'),
                ),
                const SizedBox(width: CmSpacing.sm),
              ],
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy || r.points.length < 2 ? null : () => startRideOnRoute(context, ref, r),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                  icon: const Icon(Icons.two_wheeler),
                  label: const Text("C'est parti", style: TextStyle(fontSize: 18)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SparseBanner extends StatelessWidget {
  const _SparseBanner({required this.busy, required this.onReroute});

  final bool busy;
  final VoidCallback onReroute;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(CmSpacing.md),
      decoration: BoxDecoration(
        color: CmColors.sky.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CmColors.sky.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.alt_route, color: CmColors.sky),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Ce GPX relie ses points en ligne droite. Recalcule-le pour suivre les routes et avoir le guidage.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: busy ? null : onReroute,
            child: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Text('Recalculer'),
          ),
        ],
      ),
    );
  }
}

class _ProfileFact extends StatelessWidget {
  const _ProfileFact({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(label, style: CmTheme.numbers(size: 18, color: scheme.onSurface)),
      ],
    );
  }
}

class _RoadbookRow extends StatelessWidget {
  const _RoadbookRow({required this.maneuver, required this.first});

  final Maneuver maneuver;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final arrive = maneuver.type == ManeuverKind.arrive;
    return Column(
      children: [
        if (!first) Divider(height: 1, indent: 64, color: scheme.outlineVariant),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CmSpacing.md, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: (arrive ? CmColors.green : CmColors.orange).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(maneuverIcon(maneuver.type), color: arrive ? CmColors.green : CmColors.orange),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(maneuver.instruction, style: const TextStyle(fontWeight: FontWeight.w600, height: 1.25)),
              ),
              const SizedBox(width: 8),
              Text(
                'km ${Fmt.number(maneuver.distanceAlongM / 1000, decimals: 1)}',
                style: CmTheme.numbers(size: 16, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
