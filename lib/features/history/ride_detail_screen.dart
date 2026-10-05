import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/map/cm_map.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/garage.dart';
import '../../data/models/ride.dart';
import '../../services/routing/gpx.dart';
import '../fuel/fuel_ui.dart';
import '../garage/expense_form.dart';
import '../routes/route_detail_screen.dart';
import '../social/social_sheets.dart';
import 'history_providers.dart';
import 'ride_analysis.dart';
import 'widgets/chart_kit.dart';
import 'widgets/ride_card.dart' show capitalizeFirst;

/// Coloration de la trace sur la carte.
enum TraceColoring {
  plain('Trace', Icons.timeline_rounded),
  lean('Angle', Icons.u_turn_right_rounded),
  speed('Vitesse', Icons.speed_rounded);

  const TraceColoring(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Couleurs des tranches d'angle (alignées sur CmColors.forLean).
final _leanColors = [
  CmColors.forLean(7),
  CmColors.forLean(20),
  CmColors.forLean(35),
  CmColors.forLean(44),
  CmColors.forLean(52),
];
const _leanLegend = ['< 15°', '15–30°', '30–40°', '40–48°', '48°+'];

/// Couleurs des tranches de vitesse (rampe froide → chaude, distincte de l'angle).
const _speedColors = [Color(0xFF2EC4B6), Color(0xFF4EA8FF), Color(0xFF6366F1), Color(0xFFA855F7), Color(0xFFEC4899)];
const _speedLegend = ['< 50', '50–80', '80–110', '110–130', '130+ km/h'];

/// Détail d'une balade enregistrée : carte, stats, graphes, coût.
class RideDetailScreen extends ConsumerStatefulWidget {
  const RideDetailScreen({super.key, required this.rideId});

  final String rideId;

  static Route<void> pageRoute(String rideId) => MaterialPageRoute(builder: (_) => RideDetailScreen(rideId: rideId));

  @override
  ConsumerState<RideDetailScreen> createState() => _RideDetailScreenState();
}

class _RideDetailScreenState extends ConsumerState<RideDetailScreen> {
  TraceColoring _coloring = TraceColoring.lean;
  int _riders = 1;
  bool _busy = false;

  List<TrackPoint>? _seriesSource;
  RideSeries _series = RideSeries.empty;

  RideSeries _seriesFor(List<TrackPoint> track) {
    if (!identical(track, _seriesSource)) {
      _seriesSource = track;
      _series = buildRideSeries(track);
    }
    return _series;
  }

  // ---------------------------------------------------------------------------
  // Actions

  Future<void> _rename(Ride ride) async {
    final name = await _textDialog(
      title: 'Renommer la balade',
      initial: ride.name,
      hint: 'Tour du Vercors',
      maxLines: 1,
    );
    if (name == null || name.trim().isEmpty || name.trim() == ride.name) return;
    await ref.read(rideRepositoryProvider).upsert(ride.copyWith(name: name.trim()));
  }

  Future<void> _editNotes(Ride ride) async {
    final notes = await _textDialog(
      title: 'Notes',
      initial: ride.notes,
      hint: 'Le resto au col, les gravillons après le virage du lac…',
      maxLines: 6,
    );
    if (notes == null || notes == ride.notes) return;
    await ref.read(rideRepositoryProvider).upsert(ride.copyWith(notes: notes.trim()));
  }

  Future<String?> _textDialog({
    required String title,
    required String initial,
    required String hint,
    required int maxLines,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: maxLines,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: maxLines == 1 ? (v) => Navigator.pop(ctx, v) : null,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('OK')),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _delete(Ride ride) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cette balade ?'),
        content: Text('« ${ride.name} » et sa trace GPS seront effacées. Pas de retour en arrière possible.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CmColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final repo = ref.read(rideRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    await repo.delete(ride.id);
    messenger.showSnackBar(SnackBar(content: Text('« ${ride.name} » supprimée')));
  }

  Future<void> _exportGpx(Ride ride) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final track = await ref.read(rideRepositoryProvider).points(ride.id);
      final gpx = buildGpx(name: ride.name, track: track, route: track.isEmpty ? ride.previewPoints : const []);
      if (gpx.trim().isEmpty) {
        if (mounted) showCmSnack(context, "L'export GPX n'est pas encore disponible.", error: true);
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${safeFileName(ride.name)}.gpx');
      await file.writeAsString(gpx, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/gpx+xml', name: '${safeFileName(ride.name)}.gpx')],
          subject: 'Balade « ${ride.name} »',
          text:
              '${ride.name} · ${Fmt.distance(ride.stats.distanceM)} · ${Fmt.date(ride.startedAt)} (trace GPX Cono Moto)',
        ),
      );
    } catch (e) {
      if (mounted) showCmSnack(context, "Export GPX impossible : $e", error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _replay(Ride ride) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final routes = ref.read(routeRepositoryProvider);
      // Une seule balade planifiée par balade enregistrée (pas de doublons).
      final id = 'replay-${ride.id}';
      var route = await routes.get(id);
      if (route == null) {
        final track = await ref.read(rideRepositoryProvider).points(ride.id);
        route = plannedRouteFromRide(ride, track, id: id, now: DateTime.now());
        if (route.points.length < 2) {
          if (mounted) showCmSnack(context, 'Pas de trace exploitable pour refaire cette balade.', error: true);
          return;
        }
        await routes.upsert(route);
      }
      if (!mounted) return;
      await Navigator.of(context).push(RouteDetailScreen.pageRoute(route));
    } catch (e) {
      if (mounted) showCmSnack(context, 'Impossible de préparer la balade : $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final rideAsync = ref.watch(rideProvider(widget.rideId));
    final ride = rideAsync.value;
    if (ride == null) {
      return Scaffold(
        appBar: AppBar(),
        body: rideAsync.isLoading
            ? const Center(child: CircularProgressIndicator())
            : const EmptyState(
                icon: Icons.search_off_rounded,
                title: 'Balade introuvable',
                message: 'Elle a peut-être été supprimée.',
              ),
      );
    }
    final track = ref.watch(rideTrackProvider(widget.rideId)).value ?? const <TrackPoint>[];
    final bikes = ref.watch(bikesProvider).value ?? const <Bike>[];
    final bike = bikes.where((b) => b.id == ride.bikeId).firstOrNull;
    final series = _seriesFor(track);

    return Scaffold(
      appBar: AppBar(
        title: Text(ride.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Partager aux potes',
            onPressed: () => shareRideWithFriends(context, ride),
            icon: const Icon(Icons.group_add_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'rename' => _rename(ride),
              'notes' => _editNotes(ride),
              'gpx' => _exportGpx(ride),
              'replay' => _replay(ride),
              'delete' => _delete(ride),
              _ => null,
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'rename',
                child: ListTile(leading: Icon(Icons.edit_rounded), title: Text('Renommer')),
              ),
              PopupMenuItem(
                value: 'notes',
                child: ListTile(leading: Icon(Icons.notes_rounded), title: Text('Notes')),
              ),
              PopupMenuItem(
                value: 'gpx',
                child: ListTile(leading: Icon(Icons.file_download_outlined), title: Text('Exporter en GPX')),
              ),
              PopupMenuItem(
                value: 'replay',
                child: ListTile(leading: Icon(Icons.replay_rounded), title: Text('Refaire cette balade')),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline_rounded, color: CmColors.red),
                  title: Text('Supprimer', style: TextStyle(color: CmColors.red)),
                ),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: CmSpacing.xxl),
        children: [
          // Gardée en vie : sinon la carte se recharge à chaque défilement.
          _KeepAlive(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
              child: _RideMapCard(
                ride: ride,
                track: track,
                coloring: _coloring,
                onColoring: (c) => setState(() => _coloring = c),
              ),
            ),
          ),
          _Header(ride: ride, bike: bike, onRename: () => _rename(ride)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
            child: _StatsGrid(ride: ride),
          ),
          if (series.speed.length >= 2) ...[
            const SectionHeader('En graphes'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
              child: _RideCharts(ride: ride, track: track, series: series),
            ),
          ],
          const SectionHeader('Coût de la balade'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
            child: _RideCostSection(ride: ride, riders: _riders, onRiders: (n) => setState(() => _riders = n)),
          ),
          SectionHeader(
            'Notes',
            action: IconButton(
              tooltip: 'Modifier les notes',
              onPressed: () => _editNotes(ride),
              icon: const Icon(Icons.edit_note_rounded),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
            child: _NotesCard(notes: ride.notes, onTap: () => _editNotes(ride)),
          ),
          const SizedBox(height: CmSpacing.xl),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : () => _replay(ride),
                  icon: const Icon(Icons.replay_rounded),
                  label: const Text('Refaire cette balade'),
                ),
                const SizedBox(height: CmSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => shareRideWithFriends(context, ride),
                        icon: const Icon(Icons.group_add_outlined),
                        label: const Text('Aux potes'),
                      ),
                    ),
                    const SizedBox(width: CmSpacing.sm),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _exportGpx(ride),
                        icon: const Icon(Icons.ios_share_rounded),
                        label: const Text('GPX'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// -----------------------------------------------------------------------------
// En-tête et stats

class _Header extends StatelessWidget {
  const _Header({required this.ride, required this.bike, required this.onRename});

  final Ride ride;
  final Bike? bike;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final end = ride.endedAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.lg, CmSpacing.lg, CmSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onRename,
            borderRadius: BorderRadius.circular(8),
            child: Text(ride.name, style: text.headlineMedium),
          ),
          const SizedBox(height: 2),
          Text(
            '${capitalizeFirst(Fmt.dateLong(ride.startedAt))} · ${Fmt.time(ride.startedAt)}'
            '${end != null ? ' → ${Fmt.time(end)}' : ''}',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (bike != null || ride.sharedWithFriends) ...[
            const SizedBox(height: CmSpacing.sm),
            Wrap(
              spacing: 6,
              children: [
                if (bike != null) Pill(label: bike!.name, icon: Icons.two_wheeler_rounded, color: bike!.color),
                if (ride.sharedWithFriends)
                  const Pill(label: 'Partagée', icon: Icons.groups_rounded, color: CmColors.teal),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.ride});

  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final s = ride.stats;
    final moving = s.movingTimeS > 0 ? s.movingTimeS : s.totalTimeS;
    return StatGrid(
      columns: 3,
      compact: true,
      children: [
        StatTile(
          label: 'Distance',
          value: Fmt.km(s.distanceM),
          unit: 'km',
          icon: Icons.route_rounded,
          color: CmColors.orange,
          compact: true,
        ),
        StatTile(label: 'En roulant', value: Fmt.durationS(moving), icon: Icons.timer_outlined, compact: true),
        StatTile(
          label: 'Vit. moy',
          value: Fmt.number(s.avgMovingSpeedKmh),
          unit: 'km/h',
          icon: Icons.speed_rounded,
          compact: true,
        ),
        StatTile(
          label: 'Vit. max',
          value: Fmt.number(s.maxSpeedKmh),
          unit: 'km/h',
          icon: Icons.bolt_rounded,
          compact: true,
        ),
        StatTile(
          label: 'Angle G',
          value: '${s.maxLeanLeftDeg.round()}°',
          icon: Icons.turn_left_rounded,
          color: s.maxLeanLeftDeg > 0 ? CmColors.forLean(s.maxLeanLeftDeg) : null,
          compact: true,
        ),
        StatTile(
          label: 'Angle D',
          value: '${s.maxLeanRightDeg.round()}°',
          icon: Icons.turn_right_rounded,
          color: s.maxLeanRightDeg > 0 ? CmColors.forLean(s.maxLeanRightDeg) : null,
          compact: true,
        ),
        StatTile(label: 'Freinages', value: '${s.hardBrakeCount}', icon: Icons.warning_amber_rounded, compact: true),
        StatTile(
          label: 'D+',
          value: Fmt.number(s.elevationGainM),
          unit: 'm',
          icon: Icons.landscape_rounded,
          compact: true,
        ),
        StatTile(label: 'Virages', value: '${s.curveCount}', icon: Icons.turn_slight_right_rounded, compact: true),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Carte

class _RideMapCard extends StatelessWidget {
  const _RideMapCard({required this.ride, required this.track, required this.coloring, required this.onColoring});

  final Ride ride;
  final List<TrackPoint> track;
  final TraceColoring coloring;
  final ValueChanged<TraceColoring> onColoring;

  @override
  Widget build(BuildContext context) {
    final hasDetail = track.length >= 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(CmSpacing.radius),
          child: SizedBox(
            height: 300,
            child: Stack(
              children: [
                _RideMap(ride: ride, track: track, coloring: hasDetail ? coloring : TraceColoring.plain),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: MapRoundButton(
                    icon: Icons.open_in_full_rounded,
                    size: 42,
                    tooltip: 'Plein écran',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _RideMapPage(ride: ride, track: track, coloring: coloring),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasDetail) ...[
          const SizedBox(height: CmSpacing.sm),
          _ColoringSelector(coloring: coloring, onChanged: onColoring),
        ],
      ],
    );
  }
}

class _ColoringSelector extends StatelessWidget {
  const _ColoringSelector({required this.coloring, required this.onChanged});

  final TraceColoring coloring;
  final ValueChanged<TraceColoring> onChanged;

  @override
  Widget build(BuildContext context) {
    final legend = switch (coloring) {
      TraceColoring.plain => null,
      TraceColoring.lean => [for (var i = 0; i < 5; i++) (_leanLegend[i], _leanColors[i])],
      TraceColoring.speed => [for (var i = 0; i < 5; i++) (_speedLegend[i], _speedColors[i])],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<TraceColoring>(
          showSelectedIcon: false,
          segments: [
            for (final c in TraceColoring.values) ButtonSegment(value: c, label: Text(c.label), icon: Icon(c.icon)),
          ],
          selected: {coloring},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        if (legend != null) ...[const SizedBox(height: CmSpacing.sm), Center(child: ChartLegend(items: legend))],
      ],
    );
  }
}

class _RideMapPage extends StatefulWidget {
  const _RideMapPage({required this.ride, required this.track, required this.coloring});

  final Ride ride;
  final List<TrackPoint> track;
  final TraceColoring coloring;

  @override
  State<_RideMapPage> createState() => _RideMapPageState();
}

class _RideMapPageState extends State<_RideMapPage> {
  late TraceColoring _coloring = widget.coloring;

  @override
  Widget build(BuildContext context) {
    final hasDetail = widget.track.length >= 2;
    return Scaffold(
      appBar: AppBar(title: Text(widget.ride.name)),
      body: Stack(
        children: [
          Positioned.fill(
            child: _RideMap(
              ride: widget.ride,
              track: widget.track,
              coloring: hasDetail ? _coloring : TraceColoring.plain,
              padding: const EdgeInsets.fromLTRB(48, 48, 48, 180),
            ),
          ),
          if (hasDetail)
            Positioned(
              left: CmSpacing.lg,
              right: CmSpacing.lg,
              bottom: CmSpacing.lg,
              child: SafeArea(
                child: GlassPanel(
                  child: _ColoringSelector(coloring: _coloring, onChanged: (c) => setState(() => _coloring = c)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Carte de la trace : départ / arrivée, freinages forts, angle max.
class _RideMap extends StatefulWidget {
  const _RideMap({
    required this.ride,
    required this.track,
    required this.coloring,
    this.padding = const EdgeInsets.all(40),
  });

  final Ride ride;
  final List<TrackPoint> track;
  final TraceColoring coloring;
  final EdgeInsets padding;

  @override
  State<_RideMap> createState() => _RideMapState();
}

class _RideMapState extends State<_RideMap> {
  List<MapLine> _lines = const [];
  List<MapMarker> _markers = const [];
  List<GeoPoint> _points = const [];
  String _key = '';
  CmMapController? _controller;

  @override
  void initState() {
    super.initState();
    _compute();
  }

  @override
  void didUpdateWidget(covariant _RideMap old) {
    super.didUpdateWidget(old);
    final hadPoints = _points.length;
    _compute();
    if (hadPoints != _points.length) _fit();
  }

  void _compute() {
    final key = '${widget.ride.id}|${widget.track.length}|${widget.coloring.name}|${widget.ride.events.length}';
    if (key == _key) return;
    _key = key;
    final track = widget.track;
    final geo = track.length >= 2 ? [for (final p in track) p.point] : widget.ride.previewPoints;
    _points = geo;

    // Lignes.
    if (geo.length < 2) {
      _lines = const [];
    } else if (widget.coloring == TraceColoring.plain || track.length < 2) {
      _lines = [
        MapLine(id: 'trace', points: geo.length > 3000 ? Geo.simplify(geo, 4) : geo, color: CmColors.orange, width: 5),
      ];
    } else {
      final lean = widget.coloring == TraceColoring.lean;
      final runs = colorRuns(
        track,
        lean ? (p) => p.leanDeg.abs() : (p) => p.speedKmh,
        lean ? leanBucketThresholds : speedBucketThresholds,
      );
      final colors = lean ? _leanColors : _speedColors;
      _lines = [
        for (var i = 0; i < runs.length; i++)
          MapLine(id: 'run-$i', points: runs[i].points, color: colors[runs[i].bucket], width: 5),
      ];
    }

    // Marqueurs.
    final markers = <MapMarker>[];
    if (geo.isNotEmpty) {
      markers.add(
        MapMarker(
          id: 'start',
          position: geo.first,
          icon: Icons.play_arrow_rounded,
          color: CmColors.green,
          size: 32,
          zIndex: 20,
          label: 'Départ',
        ),
      );
      if (geo.length > 1 && Geo.distance(geo.first, geo.last) > 80) {
        markers.add(
          MapMarker(
            id: 'end',
            position: geo.last,
            icon: Icons.sports_score_rounded,
            color: const Color(0xFF1F2937),
            size: 32,
            zIndex: 20,
            label: 'Arrivée',
          ),
        );
      }
    }
    var brakeIndex = 0;
    RideEvent? leanEvent;
    for (final e in widget.ride.events) {
      if (e.type == 'hard_brake') {
        markers.add(
          MapMarker(
            id: 'brake-${brakeIndex++}',
            position: GeoPoint(e.lat, e.lng),
            icon: Icons.priority_high_rounded,
            color: CmColors.red,
            size: 24,
            zIndex: 5,
          ),
        );
      } else if (e.type == 'max_lean' && (leanEvent == null || e.value.abs() > leanEvent.value.abs())) {
        leanEvent = e;
      }
    }
    GeoPoint? leanAt;
    var leanValue = 0.0;
    if (leanEvent != null) {
      leanAt = GeoPoint(leanEvent.lat, leanEvent.lng);
      leanValue = leanEvent.value.abs();
    } else if (track.isNotEmpty) {
      final p = track.reduce((a, b) => a.leanDeg.abs() >= b.leanDeg.abs() ? a : b);
      if (p.leanDeg.abs() >= 5) {
        leanAt = p.point;
        leanValue = p.leanDeg.abs();
      }
    }
    if (leanAt != null) {
      markers.add(
        MapMarker(
          id: 'lean',
          position: leanAt,
          text: '${leanValue.round()}°',
          color: CmColors.forLean(leanValue),
          size: 36,
          zIndex: 30,
          highlighted: true,
          label: 'Angle max',
        ),
      );
    }
    _markers = markers;
  }

  Future<void> _fit() async {
    final c = _controller;
    if (c == null || _points.length < 2) return;
    await c.fitPoints(_points, padding: widget.padding);
  }

  static double _zoomFor(GeoBounds b) {
    final cosLat = math.cos(b.center.lat * math.pi / 180).abs().clamp(0.2, 1.0);
    final span = math.max(math.max(b.north - b.south, (b.east - b.west) * cosLat), 0.002);
    return (math.log(300 / span) / math.ln2).clamp(3.0, 16.0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final bounds = GeoBounds.fromPoints(_points);
    return CmMap(
      lines: _lines,
      markers: _markers,
      initialCenter: bounds?.center,
      initialZoom: bounds == null ? 12 : _zoomFor(bounds),
      showUserLocation: false,
      compassEnabled: false,
      onCreated: (c) {
        _controller = c;
        Future<void>.delayed(const Duration(milliseconds: 700), _fit);
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Graphes

class _RideCharts extends StatelessWidget {
  const _RideCharts({required this.ride, required this.track, required this.series});

  final Ride ride;
  final List<TrackPoint> track;
  final RideSeries series;

  @override
  Widget build(BuildContext context) {
    final hist = ride.stats.leanHistogram.isNotEmpty ? ride.stats.leanHistogram : leanHistogramFromPoints(track);
    final buckets = hist.keys.toList()..sort();
    final totalS = hist.values.fold<int>(0, (s, v) => s + v);
    final avgSpeed = ride.stats.avgMovingSpeedKmh;

    return Column(
      children: [
        ChartCard(
          title: 'Vitesse',
          subtitle: avgSpeed > 0 ? 'Moyenne ${Fmt.speed(avgSpeed)} · max ${Fmt.speed(ride.stats.maxSpeedKmh)}' : null,
          child: DistanceLineChart(
            points: series.speed,
            color: ChartColors.orange,
            minY: 0,
            formatValue: (v) => '${v.round()} km/h',
          ),
        ),
        if (series.hasLean) ...[
          const SizedBox(height: CmSpacing.md),
          ChartCard(
            title: 'Inclinaison',
            subtitle: 'Angle le plus fort de chaque tronçon',
            legend: const ChartLegend(items: [('Gauche', ChartColors.leanLeft), ('Droite', ChartColors.leanRight)]),
            child: DistanceLineChart(
              points: series.lean,
              color: ChartColors.leanRight,
              negativeColor: ChartColors.leanLeft,
              symmetric: true,
              formatValue: (v) => v == 0 ? '0°' : '${v.abs().round()}° ${v < 0 ? 'G' : 'D'}',
            ),
          ),
        ],
        if (series.hasAltitude) ...[
          const SizedBox(height: CmSpacing.md),
          ChartCard(
            title: 'Altitude',
            subtitle: ride.stats.elevationGainM > 0 ? '${Fmt.number(ride.stats.elevationGainM)} m de D+' : null,
            child: DistanceLineChart(
              points: series.altitude,
              color: ChartColors.blue,
              formatValue: (v) => '${Fmt.number(v)} m',
            ),
          ),
        ],
        if (totalS > 0) ...[
          const SizedBox(height: CmSpacing.md),
          ChartCard(
            title: 'Répartition des angles',
            subtitle: 'Part du temps passé à chaque inclinaison',
            child: SimpleBarChart(
              values: [for (final b in buckets) hist[b]! / totalS * 100],
              labels: [for (final b in buckets) '$b°'],
              tooltipLabels: [for (final b in buckets) '$b–${b + 10}° · ${Fmt.durationS(hist[b]!)}'],
              colors: [for (final b in buckets) CmColors.forLean(b + 5.0)],
              formatValue: (v) => '${Fmt.number(v, decimals: v < 10 ? 1 : 0)} %',
            ),
          ),
        ],
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Coût

class _RideCostSection extends ConsumerWidget {
  const _RideCostSection({required this.ride, required this.riders, required this.onRiders});

  final Ride ride;
  final int riders;
  final ValueChanged<int> onRiders;

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, String what, Future<void> Function() delete) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Retirer $what ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CmColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (ok == true) await delete();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final data = ref.watch(rideCostDataProvider(ride.id)).value;
    final bikes = ref.watch(bikesProvider).value ?? const <Bike>[];
    final bike = bikes.where((b) => b.id == ride.bikeId).firstOrNull ?? ref.watch(defaultBikeProvider);

    if (data == null) {
      return const Padding(
        padding: EdgeInsets.all(CmSpacing.lg),
        child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))),
      );
    }
    final cost = computeRideCost(
      fuel: data.fuel,
      expenses: data.expenses,
      distanceKm: ride.stats.distanceKm,
      consumptionL100: bike?.consumptionL100,
      pricePerLiter: data.lastPrice,
    );
    final approx = cost.fuelIsEstimated ? '≈ ' : '';

    Widget row({
      required IconData icon,
      required Color color,
      required String title,
      String? subtitle,
      required String amount,
      VoidCallback? onLongPress,
    }) => InkWell(
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: CmSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            Text(amount, style: CmTheme.numbers(size: 20)),
          ],
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.all(CmSpacing.lg),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(CmSpacing.radius)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TOTAL',
                      style: text.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '$approx${Fmt.euros(cost.total)}',
                        style: CmTheme.numbers(size: 40, color: CmColors.orange),
                      ),
                    ),
                  ],
                ),
              ),
              if (cost.perKm != null)
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '$approx${Fmt.number(cost.perKm!, decimals: 2)} €/km',
                          style: CmTheme.numbers(size: 22),
                        ),
                      ),
                      Text(
                        'sur ${Fmt.distance(ride.stats.distanceM)}',
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: CmSpacing.md),
          if (cost.isEmpty)
            Text(
              'Rien de noté pour cette balade. Ajoute ton plein, le péage ou le resto pour connaître son vrai coût.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          for (final f in cost.fuel)
            row(
              icon: Icons.local_gas_station_rounded,
              color: ChartColors.fuel,
              title: '${f.fullTank ? 'Plein' : 'Appoint'} · ${Fmt.number(f.liters, decimals: 2)} L',
              subtitle: [Fmt.pricePerLiter(f.pricePerLiter), if (f.stationName.isNotEmpty) f.stationName].join(' · '),
              amount: Fmt.euros(f.total),
              onLongPress: () =>
                  _confirmDelete(context, ref, 'ce plein', () => ref.read(garageRepositoryProvider).deleteFuel(f.id)),
            ),
          if (cost.fuelIsEstimated)
            row(
              icon: Icons.local_gas_station_outlined,
              color: ChartColors.fuel,
              title: 'Essence estimée',
              subtitle:
                  '${Fmt.number(bike?.consumptionL100 ?? 0, decimals: 1)} L/100 · '
                  '${Fmt.pricePerLiter(data.lastPrice ?? 0)} (dernier plein)',
              amount: '≈ ${Fmt.euros(cost.estimatedFuel!)}',
            ),
          for (final e in cost.expenses)
            row(
              icon: e.category.icon,
              color: ChartColors.expenses,
              title: e.label.isNotEmpty ? e.label : e.category.label,
              subtitle: e.label.isNotEmpty ? e.category.label : null,
              amount: Fmt.euros(e.amount),
              onLongPress: () => _confirmDelete(
                context,
                ref,
                'cette dépense',
                () => ref.read(garageRepositoryProvider).deleteExpense(e.id),
              ),
            ),
          if (!cost.isEmpty) ...[
            const Divider(height: CmSpacing.xl),
            Row(
              children: [
                const Icon(Icons.groups_rounded, size: 20),
                const SizedBox(width: CmSpacing.sm),
                Expanded(
                  child: Text('Par personne', style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                ),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text('$approx${Fmt.euros(cost.perPerson(riders))}', style: CmTheme.numbers(size: 26)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: CmSpacing.xs),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Un motard de moins',
                  onPressed: riders > 1 ? () => onRiders(riders - 1) : null,
                  icon: const Icon(Icons.remove_rounded, size: 18),
                ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: CmSpacing.md),
                    child: Text(
                      riders == 1 ? 'Seul en selle' : '$riders motards',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Un motard de plus',
                  onPressed: riders < 30 ? () => onRiders(riders + 1) : null,
                  icon: const Icon(Icons.add_rounded, size: 18),
                ),
              ],
            ),
          ],
          const SizedBox(height: CmSpacing.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => showExpenseForm(context, rideId: ride.id, bikeId: ride.bikeId, date: ride.startedAt),
                  icon: const Icon(Icons.receipt_long_rounded, size: 20),
                  label: const Text('Dépense'),
                ),
              ),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      showFuelEntryForm(context, rideId: ride.id, bikeId: ride.bikeId, date: ride.startedAt),
                  icon: const Icon(Icons.local_gas_station_outlined, size: 20),
                  label: const Text('Plein'),
                ),
              ),
            ],
          ),
          if (!cost.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: CmSpacing.sm),
              child: Text(
                'Appui long sur une ligne pour la retirer.',
                textAlign: TextAlign.center,
                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _NotesCard extends StatelessWidget {
  const _NotesCard({required this.notes, required this.onTap});

  final String notes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(CmSpacing.radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CmSpacing.radius),
        child: Padding(
          padding: const EdgeInsets.all(CmSpacing.lg),
          child: notes.trim().isEmpty
              ? Row(
                  children: [
                    Icon(Icons.edit_note_rounded, color: scheme.onSurfaceVariant),
                    const SizedBox(width: CmSpacing.sm),
                    Expanded(
                      child: Text(
                        'Un souvenir, une anecdote, le resto à retenir…',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                )
              : Text(notes, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ),
    );
  }
}
