import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/ride.dart';
import 'history_providers.dart';
import 'history_stats.dart';
import 'ride_detail_screen.dart';
import 'stats_screen.dart';
import 'widgets/ride_card.dart';

/// Onglet Historique : totaux, balades groupées par mois, accès aux stats.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rides = ref.watch(ridesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mes balades'),
        actions: [
          IconButton(
            tooltip: 'Mes stats',
            onPressed: () => Navigator.of(context).push(StatsScreen.route()),
            icon: const Icon(Icons.insights_rounded),
          ),
        ],
      ),
      body: rides.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(icon: Icons.error_outline_rounded, title: 'Historique inaccessible', message: '$e'),
        data: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.route_rounded,
                title: 'Pas encore de balade',
                message:
                    'Lance ta première balade depuis la carte : elle apparaîtra ici avec ta trace, '
                    'tes angles, ta vitesse et tout le reste.',
              )
            : _HistoryList(rides: list),
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.rides});

  final List<Ride> rides;

  @override
  Widget build(BuildContext context) {
    final totals = computeHistoryTotals(rides, now: DateTime.now());
    final groups = groupRidesByMonth(rides);
    final monthFmt = DateFormat('MMMM yyyy', 'fr_FR');

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.sm, CmSpacing.lg, 0),
            child: _TotalsHeader(totals: totals),
          ),
        ),
        for (final g in groups) ...[
          SliverToBoxAdapter(
            child: SectionHeader(
              capitalizeFirst(monthFmt.format(g.month)),
              action: Text(
                '${g.rides.length} balade${g.rides.length > 1 ? 's' : ''} · ${Fmt.km(g.totalKm * 1000, decimals: 0)} km',
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
            sliver: SliverList.separated(
              itemCount: g.rides.length,
              separatorBuilder: (_, _) => const SizedBox(height: CmSpacing.sm),
              itemBuilder: (context, i) => RideCard(
                ride: g.rides[i],
                onTap: () => Navigator.of(context).push(RideDetailScreen.pageRoute(g.rides[i].id)),
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: CmSpacing.xxl)),
      ],
    );
  }
}

class _TotalsHeader extends StatelessWidget {
  const _TotalsHeader({required this.totals});

  final HistoryTotals totals;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final year = DateTime.now().year;
    return Container(
      padding: const EdgeInsets.all(CmSpacing.lg + 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [CmColors.orange.withValues(alpha: 0.28), scheme.surfaceContainer],
          stops: const [0, 0.8],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'EN $year',
            style: text.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w800,
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(Fmt.km(totals.kmThisYear * 1000, decimals: 0), style: CmTheme.numbers(size: 56)),
                const SizedBox(width: 6),
                Text(
                  'km',
                  style: CmTheme.numbers(size: 22, weight: FontWeight.w600, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: CmSpacing.md),
          Row(
            children: [
              _MiniTotal(label: 'Ce mois', value: Fmt.km(totals.kmThisMonth * 1000, decimals: 0), unit: 'km'),
              _MiniTotal(label: 'Balades', value: '${totals.rideCount}'),
              _MiniTotal(
                label: 'En selle',
                value: Fmt.number(totals.hours, decimals: totals.hours < 10 ? 1 : 0),
                unit: 'h',
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(StatsScreen.route()),
              icon: const Icon(Icons.insights_rounded),
              label: const Text('Mes stats et records'),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniTotal extends StatelessWidget {
  const _MiniTotal({required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.8, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, style: CmTheme.numbers(size: 28)),
                if (unit != null) ...[
                  const SizedBox(width: 3),
                  Text(
                    unit!,
                    style: CmTheme.numbers(size: 14, weight: FontWeight.w600, color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
