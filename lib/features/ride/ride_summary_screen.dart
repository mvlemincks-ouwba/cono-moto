import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/ride.dart';
import '../../services/ride/ride_store.dart';
import '../history/ride_detail_screen.dart';
import 'ride_screen.dart';
import 'widgets/lean_gauge.dart';

/// Récapitulatif affiché juste après la fin d'une balade.
class RideSummaryScreen extends ConsumerStatefulWidget {
  const RideSummaryScreen({super.key, required this.ride});

  final Ride ride;

  static Route<void> route(Ride ride) => MaterialPageRoute(builder: (_) => RideSummaryScreen(ride: ride));

  @override
  ConsumerState<RideSummaryScreen> createState() => _RideSummaryScreenState();
}

class _RideSummaryScreenState extends ConsumerState<RideSummaryScreen> {
  late Ride _ride = widget.ride;

  Future<void> _rename() async {
    final controller = TextEditingController(text: _ride.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nom de la balade'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Ex : Tour du Vercors'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Valider')),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == _ride.name) return;
    final updated = _ride.copyWith(name: trimmed);
    await ref.read(rideStoreProvider).save(updated);
    if (mounted) setState(() => _ride = updated);
  }

  @override
  Widget build(BuildContext context) {
    final r = _ride;
    final s = r.stats;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    final ended = r.endedAt;

    return Theme(
      data: RideScreen.hudTheme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: CmColors.asphalt900,
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded),
                      tooltip: 'Fermer',
                    ),
                    const Spacer(),
                    const Pill(label: 'Enregistrée', icon: Icons.check_circle_rounded, color: CmColors.green),
                  ],
                ),
                const SizedBox(height: 4),
                Text('Bien roulé !', style: CmTheme.numbers(size: 48, color: CmColors.orange)),
                const SizedBox(height: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _rename,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(r.name, style: text.headlineSmall?.copyWith(color: Colors.white)),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.edit_rounded, size: 18, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_capitalize(Fmt.dateLong(r.startedAt))} · ${Fmt.time(r.startedAt)}'
                  '${ended != null ? ' – ${Fmt.time(ended)}' : ''}',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                _TraceCard(ride: r),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _HeroStat(
                        value: s.distanceM < 1000 ? Fmt.number(s.distanceM) : Fmt.km(s.distanceM),
                        unit: s.distanceM < 1000 ? 'm' : 'km',
                        label: 'Distance',
                      ),
                    ),
                    Expanded(
                      child: _HeroStat(value: Fmt.durationS(s.movingTimeS), label: 'En mouvement'),
                    ),
                    Expanded(
                      child: _HeroStat(value: Fmt.number(s.avgMovingSpeedKmh), unit: 'km/h', label: 'Moyenne'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(CmSpacing.radius),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'TES ANGLES MAX',
                        style: text.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      LeanGauge(
                        angleDeg: 0,
                        maxLeftDeg: s.maxLeanLeftDeg,
                        maxRightDeg: s.maxLeanRightDeg,
                        size: (width - 64).clamp(160.0, 300.0),
                        showValue: false,
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: _LeanMax(label: 'Gauche', value: s.maxLeanLeftDeg),
                          ),
                          Expanded(
                            child: _LeanMax(label: 'Droite', value: s.maxLeanRightDeg),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                StatGrid(
                  columns: 2,
                  compact: true,
                  children: [
                    StatTile(
                      compact: true,
                      label: 'Vitesse max',
                      value: Fmt.number(s.maxSpeedKmh),
                      unit: 'km/h',
                      icon: Icons.bolt_rounded,
                    ),
                    StatTile(
                      compact: true,
                      label: 'Virages',
                      value: '${s.curveCount}',
                      icon: Icons.turn_slight_right_rounded,
                    ),
                    StatTile(
                      compact: true,
                      label: 'Dénivelé +',
                      value: Fmt.number(s.elevationGainM),
                      unit: 'm',
                      icon: Icons.terrain_rounded,
                    ),
                    StatTile(
                      compact: true,
                      label: 'Freinages forts',
                      value: '${s.hardBrakeCount}',
                      icon: Icons.warning_amber_rounded,
                      color: s.hardBrakeCount > 0 ? CmColors.amber : null,
                    ),
                    StatTile(
                      compact: true,
                      label: 'Angle moyen',
                      value: '${Fmt.number(s.avgLeanInCurvesDeg)}°',
                      icon: Icons.architecture_rounded,
                    ),
                    StatTile(
                      compact: true,
                      label: 'Durée totale',
                      value: Fmt.durationS(s.totalTimeS),
                      icon: Icons.schedule_rounded,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 60,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pushReplacement(RideDetailScreen.pageRoute(r.id)),
                    icon: const Icon(Icons.insights_rounded),
                    label: const Text('Voir le détail', style: TextStyle(fontSize: 17)),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Retour à la carte'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

class _TraceCard extends StatelessWidget {
  const _TraceCard({required this.ride});

  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final points = ride.previewPoints;
    return Container(
      height: 210,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CmSpacing.radius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [CmColors.asphalt600, CmColors.asphalt800],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(CmSpacing.radius),
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _GridPainter())),
            if (points.length >= 2)
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: RouteShape(points: points, strokeWidth: 4),
                ),
              )
            else
              const Center(
                child: Text('Trace trop courte pour un aperçu', style: TextStyle(color: Colors.white54)),
              ),
          ],
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.035)
      ..strokeWidth = 1;
    const step = 28.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.value, required this.label, this.unit});

  final String value;
  final String? unit;
  final String label;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: CmTheme.numbers(size: 40, color: Colors.white)),
              if (unit != null) ...[
                const SizedBox(width: 3),
                Text(
                  unit!,
                  style: CmTheme.numbers(size: 17, color: muted, weight: FontWeight.w600),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label.toUpperCase(),
          style: TextStyle(color: muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8),
        ),
      ],
    );
  }
}

class _LeanMax extends StatelessWidget {
  const _LeanMax({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final color = CmColors.forLean(value);
    return Column(
      children: [
        Text('${value.round()}°', style: CmTheme.numbers(size: 36, color: color)),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}
