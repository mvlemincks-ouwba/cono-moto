import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/map/cm_map.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../services/routing/http_support.dart';
import '../../services/routing/overpass_client.dart';
import '../../services/routing/route_generator.dart';
import 'generation_loader.dart';
import 'route_actions.dart';
import 'route_detail_screen.dart';
import 'route_ui.dart';
import 'routes_providers.dart';

/// Calcul puis présentation des propositions (carte + cartes à faire défiler).
class GenerationResultsScreen extends ConsumerStatefulWidget {
  const GenerationResultsScreen({super.key, required this.request});

  final RouteRequest request;

  static Route<void> pageRoute(RouteRequest request) =>
      MaterialPageRoute(builder: (_) => GenerationResultsScreen(request: request));

  @override
  ConsumerState<GenerationResultsScreen> createState() => _GenerationResultsScreenState();
}

class _GenerationResultsScreenState extends ConsumerState<GenerationResultsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(generationProvider.notifier).run(widget.request);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(generationProvider);
    final Widget body;
    if (s.result != null && s.result!.candidates.isNotEmpty) {
      body = _ResultsView(key: ValueKey(s.result), result: s.result!, request: s.request ?? widget.request);
    } else if (s.error != null) {
      body = _ErrorView(error: s.error!);
    } else {
      body = GenerationLoader(
        progress: s.progress,
        styleIcon: widget.request.style.icon,
        onCancel: () {
          ref.read(generationProvider.notifier).cancel();
          Navigator.of(context).maybePop();
        },
      );
    }
    return Scaffold(
      backgroundColor: CmColors.asphalt900,
      body: AnimatedSwitcher(duration: const Duration(milliseconds: 400), child: body),
    );
  }
}

class _ErrorView extends ConsumerWidget {
  const _ErrorView({required this.error});

  final RoutingException error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = error.kind == RoutingErrorKind.offline;
    return SafeArea(
      child: EmptyState(
        icon: offline ? Icons.cloud_off : Icons.wrong_location,
        title: offline ? 'Pas de réseau' : 'Pas de balade cette fois',
        message: error.message,
        action: Wrap(
          spacing: CmSpacing.md,
          children: [
            OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Modifier')),
            FilledButton.icon(
              onPressed: () {
                final req = ref.read(generationProvider).request;
                if (req != null) ref.read(generationProvider.notifier).run(req);
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsView extends ConsumerStatefulWidget {
  const _ResultsView({super.key, required this.result, required this.request});

  final GenerationResult result;
  final RouteRequest request;

  @override
  ConsumerState<_ResultsView> createState() => _ResultsViewState();
}

class _ResultsViewState extends ConsumerState<_ResultsView> {
  final _pages = PageController(viewportFraction: 0.92);
  CmMapController? _map;
  int _selected = 0;
  final Set<String> _saved = {};
  late List<MapLine> _lines = _buildLines();
  late List<MapMarker> _markers = _buildMarkers();

  List<RouteCandidate> get _candidates => widget.result.candidates;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  List<MapLine> _buildLines() {
    final lines = <MapLine>[];
    for (var i = 0; i < _candidates.length; i++) {
      if (i == _selected) continue;
      lines.add(
        MapLine(
          id: 'cand-$i',
          points: previewPoints(_candidates[i].route),
          color: candidateColors[i % candidateColors.length],
          width: 3.5,
          opacity: 0.45,
          casing: false,
        ),
      );
    }
    lines.add(
      MapLine(
        id: 'cand-$_selected',
        points: _candidates[_selected].route.points,
        color: candidateColors[_selected % candidateColors.length],
        width: 6,
      ),
    );
    return lines;
  }

  List<MapMarker> _buildMarkers() {
    final c = _candidates[_selected];
    final color = candidateColors[_selected % candidateColors.length];
    return [
      MapMarker(
        id: 'start',
        position: widget.request.start,
        icon: Icons.flag,
        color: CmColors.green,
        label: 'Départ',
        zIndex: 10,
      ),
      if (widget.request.destination != null)
        MapMarker(
          id: 'end',
          position: widget.request.destination!,
          icon: Icons.sports_score,
          color: Colors.white,
          label: 'Arrivée',
          zIndex: 9,
        ),
      for (final p in c.pois)
        MapMarker(
          id: 'poi-${p.id}',
          position: p.point,
          icon: p.kind == PoiKind.forest ? Icons.forest : Icons.terrain,
          color: color,
          label: p.shortName,
          size: 32,
        ),
    ];
  }

  void _select(int i) {
    if (i == _selected) return;
    setState(() {
      _selected = i;
      _lines = _buildLines();
      _markers = _buildMarkers();
    });
    _fit();
  }

  Future<void> _fit({bool all = false}) async {
    final pts = all
        ? [for (final c in _candidates) ...previewPoints(c.route)]
        : previewPoints(_candidates[_selected].route);
    await _map?.fitPoints(pts, padding: const EdgeInsets.fromLTRB(48, 120, 48, 40));
  }

  Future<void> _openDetail(RouteCandidate c) async {
    await Navigator.of(context).push(RouteDetailScreen.pageRoute(c.route, departure: widget.request.departure));
    // Enregistrée (ou supprimée) depuis le détail ?
    final stored = await ref.read(routeRepositoryProvider).get(c.route.id);
    if (!mounted) return;
    setState(() => stored == null ? _saved.remove(c.route.id) : _saved.add(c.route.id));
  }

  Future<void> _save(RouteCandidate c) async {
    await saveRoute(context, ref, c.route);
    if (mounted) setState(() => _saved.add(c.route.id));
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.result.notes;
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: debugDisableRouteMaps
                    ? const ColoredBox(color: CmColors.asphalt700)
                    : CmMap(
                        lines: _lines,
                        markers: _markers,
                        initialCenter: widget.request.start,
                        initialZoom: 9,
                        onCreated: (c) {
                          _map = c;
                          Future.delayed(const Duration(milliseconds: 400), () {
                            if (mounted) _fit(all: true);
                          });
                        },
                      ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(CmSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          MapRoundButton(
                            icon: Icons.arrow_back,
                            tooltip: 'Retour',
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const SizedBox(width: CmSpacing.sm),
                          Expanded(
                            child: GlassPanel(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              radius: 24,
                              child: Row(
                                children: [
                                  Icon(widget.request.style.icon, size: 18, color: styleColor(widget.request.style)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${_candidates.length} idée${_candidates.length > 1 ? 's' : ''} · ${widget.request.style.label}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: CmSpacing.sm),
                          MapRoundButton(
                            icon: Icons.casino_outlined,
                            tooltip: 'Autres idées',
                            onPressed: () => ref.read(generationProvider.notifier).reroll(),
                          ),
                        ],
                      ),
                      for (final n in notes) ...[
                        const SizedBox(height: CmSpacing.sm),
                        GlassPanel(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          radius: 16,
                          child: Row(
                            children: [
                              const Icon(Icons.info_outline, size: 18, color: CmColors.amber),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(n, style: const TextStyle(fontWeight: FontWeight.w600)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: CmSpacing.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _candidates.length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: i == _selected ? 26 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: i == _selected
                              ? candidateColors[i % candidateColors.length]
                              : Theme.of(context).colorScheme.outline,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: CmSpacing.sm),
                SizedBox(
                  height: 318,
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: _candidates.length,
                    onPageChanged: _select,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: _CandidateCard(
                        candidate: _candidates[i],
                        rank: i,
                        color: candidateColors[i % candidateColors.length],
                        saved: _saved.contains(_candidates[i].route.id),
                        onSave: () => _save(_candidates[i]),
                        onGo: () => startRideOnRoute(context, ref, _candidates[i].route),
                        onOpen: () => _openDetail(_candidates[i]),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: CmSpacing.md),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.candidate,
    required this.rank,
    required this.color,
    required this.saved,
    required this.onSave,
    required this.onGo,
    required this.onOpen,
  });

  final RouteCandidate candidate;
  final int rank;
  final Color color;
  final bool saved;
  final VoidCallback onSave;
  final VoidCallback onGo;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = candidate.route;
    final m = candidate.metrics;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(height: 4, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.md, CmSpacing.lg, CmSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (rank == 0)
                                        const Padding(
                                          padding: EdgeInsets.only(bottom: 4),
                                          child: Pill(
                                            label: 'Meilleur match',
                                            icon: Icons.emoji_events_outlined,
                                            color: CmColors.amber,
                                          ),
                                        ),
                                      Text(
                                        r.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.1),
                                      ),
                                      if (r.description.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          r.description,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: CmSpacing.sm),
                                ScoreRing(score: candidate.score, color: color),
                              ],
                            ),
                            const SizedBox(height: CmSpacing.md),
                            Row(
                              children: [
                                _Stat(value: Fmt.km(r.distanceM, decimals: 0), unit: 'km', label: 'Distance'),
                                _Stat(value: Fmt.durationS(r.durationS), label: 'Durée'),
                                _Stat(value: '${m.curvature.round()}', unit: '/100', label: 'Virages'),
                                _Stat(
                                  value: m.elevationGainM == null ? '—' : Fmt.number(m.elevationGainM!),
                                  unit: m.elevationGainM == null ? null : 'm',
                                  label: 'D+',
                                ),
                              ],
                            ),
                            const SizedBox(height: CmSpacing.md),
                            BadgeWrap(candidate.badges.take(3).toList()),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: CmSpacing.md),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: saved ? null : onSave,
                          icon: Icon(saved ? Icons.bookmark_added : Icons.bookmark_add_outlined),
                          label: Text(saved ? 'Enregistrée' : 'Enregistrer'),
                        ),
                        const SizedBox(width: CmSpacing.sm),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: onGo,
                            icon: const Icon(Icons.two_wheeler),
                            label: const Text("C'est parti"),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.unit});

  final String value;
  final String? unit;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, style: CmTheme.numbers(size: 26, color: scheme.onSurface)),
                if (unit != null) ...[
                  const SizedBox(width: 2),
                  Text(unit!, style: CmTheme.numbers(size: 13, color: scheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}
