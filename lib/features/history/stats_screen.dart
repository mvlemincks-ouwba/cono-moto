import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/ride.dart';
import 'history_providers.dart';
import 'history_stats.dart';
import 'ride_detail_screen.dart';
import 'widgets/chart_kit.dart';

/// Statistiques globales : totaux, records, angles, km par mois, gauche/droite.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const StatsScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rides = ref.watch(ridesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Mes stats')),
      body: rides.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(icon: Icons.error_outline_rounded, title: 'Stats indisponibles', message: '$e'),
        data: (list) {
          final s = computeGlobalStats(list, now: DateTime.now());
          if (s.isEmpty) {
            return const EmptyState(
              icon: Icons.insights_rounded,
              title: 'Pas encore de stats',
              message: 'Roule un peu : tes records, tes angles et tes km par mois s’afficheront ici.',
            );
          }
          return _StatsBody(stats: s);
        },
      ),
    );
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.stats});

  final GlobalRideStats stats;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final share = s.leanShare;
    final buckets = share.keys.toList()..sort();
    final months = s.kmPerMonth;
    final current = months.isEmpty ? null : months.length - 1;

    return ListView(
      padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.sm, CmSpacing.lg, CmSpacing.xxl),
      children: [
        StatGrid(
          children: [
            StatTile(
              label: 'Kilomètres',
              value: Fmt.km(s.totalKm * 1000, decimals: 0),
              unit: 'km',
              icon: Icons.route_rounded,
              color: CmColors.orange,
            ),
            StatTile(label: 'Balades', value: '${s.rideCount}', icon: Icons.two_wheeler_rounded),
            StatTile(
              label: 'En selle',
              value: Fmt.number(s.movingTime.inSeconds / 3600, decimals: s.movingTime.inHours < 10 ? 1 : 0),
              unit: 'h',
              icon: Icons.timer_outlined,
            ),
            StatTile(
              label: 'Vitesse moyenne',
              value: Fmt.number(s.avgSpeedKmh),
              unit: 'km/h',
              icon: Icons.speed_rounded,
            ),
          ],
        ),
        const SectionHeader('Records', padding: EdgeInsets.fromLTRB(0, CmSpacing.xl, 0, CmSpacing.sm)),
        _RecordTile(
          icon: Icons.straighten_rounded,
          label: 'La plus longue',
          ride: s.longest,
          value: s.longest == null ? '' : Fmt.distance(s.longest!.stats.distanceM),
          color: CmColors.orange,
        ),
        _RecordTile(
          icon: Icons.u_turn_right_rounded,
          label: 'Le plus penché',
          ride: s.mostLeaned,
          value: s.mostLeaned == null ? '' : '${s.mostLeaned!.stats.maxLeanDeg.round()}°',
          color: s.mostLeaned == null ? CmColors.orange : CmColors.forLean(s.mostLeaned!.stats.maxLeanDeg),
        ),
        _RecordTile(
          icon: Icons.speed_rounded,
          label: 'Vitesse max',
          ride: s.fastest,
          value: s.fastest == null ? '' : Fmt.speed(s.fastest!.stats.maxSpeedKmh),
          color: CmColors.sky,
        ),
        _RecordTile(
          icon: Icons.landscape_rounded,
          label: 'Le plus de D+',
          ride: s.mostClimbing,
          value: s.mostClimbing == null ? '' : '${Fmt.number(s.mostClimbing!.stats.elevationGainM)} m',
          color: CmColors.teal,
        ),
        const SectionHeader('Ta conduite', padding: EdgeInsets.fromLTRB(0, CmSpacing.xl, 0, CmSpacing.sm)),
        StatGrid(
          columns: 3,
          compact: true,
          children: [
            StatTile(
              label: 'Freinages / 100 km',
              value: Fmt.number(s.hardBrakesPer100Km, decimals: 1),
              icon: Icons.warning_amber_rounded,
              compact: true,
            ),
            StatTile(
              label: 'Virages',
              value: Fmt.number(s.curveCount.toDouble()),
              icon: Icons.turn_slight_right,
              compact: true,
            ),
            StatTile(
              label: 'D+ total',
              value: Fmt.number(s.elevationGainM),
              unit: 'm',
              icon: Icons.terrain_rounded,
              compact: true,
            ),
          ],
        ),
        const SectionHeader('Gauche ou droite ?', padding: EdgeInsets.fromLTRB(0, CmSpacing.xl, 0, CmSpacing.sm)),
        _LeanCompare(stats: s),
        const SizedBox(height: CmSpacing.lg),
        if (buckets.isNotEmpty) ...[
          ChartCard(
            title: 'Répartition des angles',
            subtitle: 'Part du temps passé à chaque inclinaison',
            child: SimpleBarChart(
              values: [for (final b in buckets) share[b]! * 100],
              labels: [for (final b in buckets) '$b°'],
              tooltipLabels: [for (final b in buckets) '$b–${b + 10}°'],
              colors: [for (final b in buckets) CmColors.forLean(b + 5.0)],
              formatValue: (v) => '${Fmt.number(v, decimals: v < 10 ? 1 : 0)} %',
            ),
          ),
          const SizedBox(height: CmSpacing.lg),
        ],
        ChartCard(
          title: 'Km par mois',
          subtitle: 'Sur les 12 derniers mois',
          child: SimpleBarChart(
            values: [for (final m in months) m.km],
            labels: [for (final m in months) monthShortLabel(m.month)],
            tooltipLabels: [for (final m in months) '${monthShortLabel(m.month)} ${m.month.year}'],
            color: ChartColors.orange,
            highlightIndex: current,
            formatValue: (v) => '${Fmt.number(v)} km',
          ),
        ),
      ],
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.icon,
    required this.label,
    required this.ride,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Ride? ride;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final r = ride;
    if (r == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: CmSpacing.sm),
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(CmSpacing.radiusSm + 4),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(RideDetailScreen.pageRoute(r.id)),
          child: Padding(
            padding: const EdgeInsets.all(CmSpacing.md),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: CmSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label.toUpperCase(),
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.8, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${r.name} · ${Fmt.date(r.startedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: CmSpacing.sm),
                Text(value, style: CmTheme.numbers(size: 28)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Comparaison des angles max à gauche et à droite.
class _LeanCompare extends StatelessWidget {
  const _LeanCompare({required this.stats});

  final GlobalRideStats stats;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final l = stats.avgMaxLeanLeftDeg;
    final r = stats.avgMaxLeanRightDeg;
    final scale = math.max(50.0, math.max(l, r) * 1.1);
    final side = stats.leanSide;

    Widget bar(double v, Color c, {required bool left}) => Expanded(
      child: Align(
        alignment: left ? Alignment.centerRight : Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: (v / scale).clamp(0.0, 1.0)),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          builder: (context, f, _) => FractionallySizedBox(
            widthFactor: f,
            child: Container(
              height: 18,
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.horizontal(
                  left: left ? const Radius.circular(6) : Radius.zero,
                  right: left ? Radius.zero : const Radius.circular(6),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    Widget sideBlock(String label, double avg, double max, Color c, CrossAxisAlignment align) => Column(
      crossAxisAlignment: align,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 6),
            Text(
              label.toUpperCase(),
              style: text.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        Text('${avg.round()}°', style: CmTheme.numbers(size: 40)),
        Text('record ${max.round()}°', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );

    return Container(
      padding: const EdgeInsets.all(CmSpacing.lg),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(CmSpacing.radius)),
      child: Column(
        children: [
          Row(
            children: [
              sideBlock('Gauche', l, stats.maxLeanLeftDeg, ChartColors.leanLeft, CrossAxisAlignment.start),
              const Spacer(),
              sideBlock('Droite', r, stats.maxLeanRightDeg, ChartColors.leanRight, CrossAxisAlignment.end),
            ],
          ),
          const SizedBox(height: CmSpacing.md),
          Row(
            children: [
              bar(l, ChartColors.leanLeft, left: true),
              Container(width: 2, height: 26, color: scheme.outline),
              bar(r, ChartColors.leanRight, left: false),
            ],
          ),
          const SizedBox(height: CmSpacing.md),
          Row(
            children: [
              Icon(switch (side) {
                LeanSide.right => Icons.turn_right_rounded,
                LeanSide.left => Icons.turn_left_rounded,
                LeanSide.balanced => Icons.balance_rounded,
                LeanSide.unknown => Icons.help_outline_rounded,
              }, color: CmColors.orange),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: Text(stats.leanVerdict, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Moyenne des angles max de chaque balade.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
