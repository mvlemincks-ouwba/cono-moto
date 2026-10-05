import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/garage.dart';
import '../fuel/fuel_logic.dart';
import '../fuel/fuel_ui.dart';
import '../history/widgets/chart_kit.dart';
import '../ride/ride_controller.dart';
import '../settings/settings_screen.dart';
import 'autonomy.dart';
import 'bike_form.dart';
import 'costs.dart';
import 'expense_form.dart';
import 'garage_providers.dart';
import 'maintenance.dart';
import 'maintenance_ui.dart';
import 'widgets/fuel_gauge.dart';

/// Onglet Garage : la moto, son autonomie, son entretien, ses pleins et ce qu'elle coûte.
class GarageScreen extends ConsumerWidget {
  const GarageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bikes = ref.watch(bikesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Garage'),
        actions: [
          IconButton(
            tooltip: 'Stations autour de moi',
            onPressed: () => showFuelStationsSheet(context),
            icon: const Icon(Icons.local_gas_station_outlined),
          ),
          IconButton(
            tooltip: 'Réglages',
            onPressed: () => Navigator.of(context).push(SettingsScreen.route()),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: bikes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'Garage inaccessible',
          message: 'Impossible de lire tes motos : $e',
        ),
        data: (list) => list.isEmpty ? const _EmptyGarage() : const _GarageContent(),
      ),
    );
  }
}

class _EmptyGarage extends StatelessWidget {
  const _EmptyGarage();

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.two_wheeler_rounded,
      title: 'Ajoute ta moto',
      message:
          'Renseigne ta bécane pour suivre ton autonomie, tes pleins, ton entretien '
          'et ce qu’elle te coûte vraiment.',
      action: Column(
        children: [
          FilledButton.icon(
            onPressed: () => showBikeForm(context),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Ajouter ma moto'),
          ),
          const SizedBox(height: CmSpacing.sm),
          TextButton.icon(
            onPressed: () => showFuelStationsSheet(context),
            icon: const Icon(Icons.local_gas_station_outlined),
            label: const Text('Voir les prix autour de moi'),
          ),
        ],
      ),
    );
  }
}

class _GarageContent extends ConsumerWidget {
  const _GarageContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bikes = ref.watch(bikesProvider).value ?? const <Bike>[];
    final bike = ref.watch(garageBikeProvider);
    if (bike == null) return const SizedBox.shrink();
    final data = ref.watch(bikeGarageDataProvider(bike.id));
    final alertKm = ref.watch(settingsProvider.select((s) => s.autonomyAlertKm));
    final defaultBike = ref.watch(defaultBikeProvider);
    // Arrondi au km : pas besoin de reconstruire le garage à chaque point GPS.
    final rideKm = ref.watch(
      rideControllerProvider.select((s) => s.isActive ? (s.distanceM / 1000).floorToDouble() : 0.0),
    );
    final autonomy = computeAutonomy(bike: bike, rideKm: bike.id == defaultBike?.id ? rideKm : 0, alertKm: alertKm);
    final now = DateTime.now();
    final d = data.value;

    final states = d == null
        ? const <MaintenanceState>[]
        : evaluateAllMaintenance(d.items, odometerKm: bike.odometerKm + rideKm, now: now);
    final attention = states.where((s) => s.status.needsAttention).length;

    return ListView(
      padding: const EdgeInsets.only(bottom: CmSpacing.xxl),
      children: [
        if (bikes.length > 1) _BikeSwitcher(bikes: bikes, selected: bike),
        Padding(
          padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.sm, CmSpacing.lg, 0),
          child: _BikeHero(
            bike: bike,
            autonomy: autonomy,
            measuredCount: d == null ? 0 : consumptionPerEntry(d.fuel).length,
          ),
        ),
        SectionHeader(
          "Carnet d'entretien",
          action: TextButton.icon(
            onPressed: () => showMaintenanceItemForm(context, bike: bike),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Ajouter'),
          ),
        ),
        if (attention > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, CmSpacing.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Pill(
                label: attention == 1 ? '1 entretien à prévoir' : '$attention entretiens à prévoir',
                icon: Icons.build_rounded,
                color: states.first.status.color,
              ),
            ),
          ),
        if (d == null) const _SectionLoading() else MaintenanceList(bike: bike, states: states, logs: d.logs),
        const SectionHeader('Ce que te coûte ta moto'),
        if (d == null)
          const _SectionLoading()
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
            child: _CostCard(
              summary: computeBikeCosts(
                bike: bike,
                fuel: d.fuel,
                expenses: d.expenses,
                logs: d.logs,
                ridesKm: d.ridesKm,
                now: now,
              ),
            ),
          ),
        SectionHeader(
          'Pleins',
          action: TextButton.icon(
            onPressed: () => showFuelEntryForm(context, bikeId: bike.id),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Plein'),
          ),
        ),
        if (d == null) const _SectionLoading() else _FuelLog(entries: d.fuel),
        SectionHeader(
          'Dépenses',
          action: TextButton.icon(
            onPressed: () => showExpenseForm(context, bikeId: bike.id),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Dépense'),
          ),
        ),
        if (d == null) const _SectionLoading() else _ExpenseLog(expenses: d.expenses),
      ],
    );
  }
}

class _SectionLoading extends StatelessWidget {
  const _SectionLoading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(CmSpacing.lg),
    child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))),
  );
}

/// Sélecteur de moto (si plusieurs).
class _BikeSwitcher extends ConsumerWidget {
  const _BikeSwitcher({required this.bikes, required this.selected});

  final List<Bike> bikes;
  final Bike selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
        children: [
          for (final b in bikes)
            Padding(
              padding: const EdgeInsets.only(right: CmSpacing.sm),
              child: ChoiceChip(
                avatar: CircleAvatar(backgroundColor: b.color, radius: 7),
                label: Text(b.isDefault ? '${b.name} ★' : b.name),
                selected: b.id == selected.id,
                onSelected: (_) => ref.read(selectedBikeIdProvider.notifier).select(b.id),
              ),
            ),
          ActionChip(
            avatar: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Moto'),
            onPressed: () => showBikeForm(context),
          ),
        ],
      ),
    );
  }
}

/// Carte « héros » de la moto.
class _BikeHero extends StatelessWidget {
  const _BikeHero({required this.bike, required this.autonomy, required this.measuredCount});

  final Bike bike;
  final AutonomyInfo autonomy;
  final int measuredCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = bike.color;
    final subtitle = [
      bike.brand,
      bike.model,
      if (bike.year != null) '${bike.year}',
    ].where((s) => s.isNotEmpty).join(' · ');

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(color, scheme.surfaceContainer, 0.45)!, scheme.surfaceContainer],
          stops: const [0, 0.75],
        ),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -36,
            top: -28,
            child: Icon(Icons.two_wheeler_rounded, size: 190, color: Colors.white.withValues(alpha: 0.05)),
          ),
          Padding(
            padding: const EdgeInsets.all(CmSpacing.lg + 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  bike.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.headlineMedium,
                                ),
                              ),
                              if (bike.isDefault) ...[
                                const SizedBox(width: 8),
                                const Pill(label: 'Par défaut', color: CmColors.orange),
                              ],
                            ],
                          ),
                          if (subtitle.isNotEmpty)
                            Text(subtitle, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Modifier la moto',
                      onPressed: () => showBikeForm(context, bike: bike),
                      icon: const Icon(Icons.edit_rounded, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: CmSpacing.lg),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'COMPTEUR',
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
                                Text(Fmt.number(bike.odometerKm), style: CmTheme.numbers(size: 50)),
                                const SizedBox(width: 4),
                                Text(
                                  'km',
                                  style: CmTheme.numbers(
                                    size: 20,
                                    weight: FontWeight.w600,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: CmSpacing.md),
                          _HeroLine(
                            icon: Icons.water_drop_outlined,
                            text: '${Fmt.number(bike.consumptionL100, decimals: 1)} L/100 km',
                            caption: measuredCount > 0 ? 'mesurée' : 'estimée',
                          ),
                          const SizedBox(height: 4),
                          _HeroLine(
                            icon: Icons.local_gas_station_outlined,
                            text:
                                '${Fmt.number(autonomy.remainingLiters, decimals: 1)} / '
                                '${Fmt.number(bike.tankLiters, decimals: bike.tankLiters % 1 == 0 ? 0 : 1)} L',
                            caption: bike.fuelType.label,
                          ),
                        ],
                      ),
                    ),
                    FuelGauge.fromAutonomy(autonomy, size: 136, reserveLiters: bike.reserveLiters),
                  ],
                ),
                if (autonomy.low || autonomy.inReserve) ...[
                  const SizedBox(height: CmSpacing.md),
                  Pill(
                    label: autonomy.inReserve
                        ? 'Sur la réserve : pense au plein !'
                        : 'Autonomie basse : pense au plein',
                    icon: Icons.warning_amber_rounded,
                    color: CmColors.red,
                  ),
                ],
                const SizedBox(height: CmSpacing.lg),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => showFuelEntryForm(context, bikeId: bike.id),
                        icon: const Icon(Icons.local_gas_station_rounded),
                        label: const Text('Faire le plein'),
                      ),
                    ),
                    const SizedBox(width: CmSpacing.sm),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => showFuelStationsSheet(context),
                        icon: const Icon(Icons.euro_rounded),
                        label: const Text('Prix du coin'),
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

class _HeroLine extends StatelessWidget {
  const _HeroLine({required this.icon, required this.text, required this.caption});

  final IconData icon;
  final String text;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Flexible(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: text,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(
                  text: '  $caption',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// « Ce que te coûte ta moto ».
class _CostCard extends StatelessWidget {
  const _CostCard({required this.summary});

  final BikeCostSummary summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = summary.total;
    if (t.total <= 0) {
      return Container(
        padding: const EdgeInsets.all(CmSpacing.lg),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(CmSpacing.radius),
        ),
        child: Row(
          children: [
            Icon(Icons.savings_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: CmSpacing.md),
            const Expanded(
              child: Text(
                'Saisis tes pleins, tes dépenses et tes entretiens pour voir ce que te coûte '
                'vraiment ta moto au kilomètre.',
              ),
            ),
          ],
        ),
      );
    }
    final perKm = summary.perKm;
    final months = summary.months;
    return Container(
      padding: const EdgeInsets.all(CmSpacing.lg),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(CmSpacing.radius)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AU KILOMÈTRE',
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
                          Text(
                            perKm == null ? '—' : Fmt.number(perKm, decimals: 2),
                            style: CmTheme.numbers(size: 46, color: CmColors.orange),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '€/km',
                            style: CmTheme.numbers(size: 18, weight: FontWeight.w600, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      perKm == null
                          ? 'Roule encore un peu pour le calculer'
                          : 'tout compris, sur ${Fmt.number(summary.km)} km',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: CmSpacing.sm),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(Fmt.euros(t.total), style: CmTheme.numbers(size: 26)),
                    ),
                    Text('au total', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.lg),
          _CostBreakdownBar(breakdown: t),
          const SizedBox(height: CmSpacing.md),
          Row(
            children: [
              _CostLegendValue(label: 'Essence', value: t.fuel, color: ChartColors.fuel),
              _CostLegendValue(label: 'Dépenses', value: t.expenses, color: ChartColors.expenses),
              _CostLegendValue(label: 'Entretien', value: t.maintenance, color: ChartColors.maintenance),
            ],
          ),
          const SizedBox(height: CmSpacing.lg),
          Text('Par mois', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          Text(
            'Moyenne ${Fmt.euros(summary.monthlyAverage)} les mois où tu as dépensé',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: CmSpacing.md),
          SizedBox(
            height: 170,
            child: StackedBarChart(
              labels: [for (final m in months) monthShortLabel(m.month)],
              tooltipLabels: [for (final m in months) '${monthShortLabel(m.month)} ${m.month.year}'],
              formatValue: (v) => '${Fmt.number(v)} €',
              series: [
                StackSeries('Essence', ChartColors.fuel, [for (final m in months) m.costs.fuel]),
                StackSeries('Dépenses', ChartColors.expenses, [for (final m in months) m.costs.expenses]),
                StackSeries('Entretien', ChartColors.maintenance, [for (final m in months) m.costs.maintenance]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Barre de répartition horizontale (essence / dépenses / entretien).
class _CostBreakdownBar extends StatelessWidget {
  const _CostBreakdownBar({required this.breakdown});

  final CostBreakdown breakdown;

  @override
  Widget build(BuildContext context) {
    final total = breakdown.total;
    final parts = [
      (breakdown.fuel, ChartColors.fuel),
      (breakdown.expenses, ChartColors.expenses),
      (breakdown.maintenance, ChartColors.maintenance),
    ].where((p) => p.$1 > 0).toList();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 12,
        child: Row(
          children: [
            for (var i = 0; i < parts.length; i++) ...[
              if (i > 0) SizedBox(width: 2, child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainer)),
              Expanded(
                flex: (parts[i].$1 / total * 1000).round().clamp(1, 1000),
                child: ColoredBox(color: parts[i].$2),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CostLegendValue extends StatelessWidget {
  const _CostLegendValue({required this.label, required this.value, required this.color});

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(Fmt.euros(value), style: CmTheme.numbers(size: 20)),
          ),
        ],
      ),
    );
  }
}

/// Journal des pleins.
class _FuelLog extends ConsumerStatefulWidget {
  const _FuelLog({required this.entries});

  final List<FuelEntry> entries;

  @override
  ConsumerState<_FuelLog> createState() => _FuelLogState();
}

class _FuelLogState extends ConsumerState<_FuelLog> {
  bool _all = false;

  Future<bool> _confirmDelete(FuelEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce plein ?'),
        content: Text('${Fmt.number(e.liters, decimals: 2)} L le ${Fmt.date(e.date)} (${Fmt.euros(e.total)})'),
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
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = widget.entries;
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
        child: Text(
          "Aucun plein pour l'instant. Note le prochain pour suivre ta conso réelle.",
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final conso = consumptionPerEntry(entries);
    final shown = _all ? entries : entries.take(5).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(CmSpacing.radius),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) const Divider(indent: 64, height: 1),
                  Dismissible(
                    key: ValueKey('fuel-${shown[i].id}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: CmColors.red,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: CmSpacing.xl),
                      child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                    ),
                    confirmDismiss: (_) => _confirmDelete(shown[i]),
                    onDismissed: (_) => ref.read(garageRepositoryProvider).deleteFuel(shown[i].id),
                    child: _FuelRow(entry: shown[i], consumption: conso[shown[i].id]),
                  ),
                ],
              ],
            ),
          ),
          if (entries.length > 5)
            TextButton(
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? 'Réduire' : 'Voir les ${entries.length} pleins'),
            ),
        ],
      ),
    );
  }
}

class _FuelRow extends StatelessWidget {
  const _FuelRow({required this.entry, required this.consumption});

  final FuelEntry entry;
  final double? consumption;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg, vertical: CmSpacing.md),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: ChartColors.fuel.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Icon(
              entry.fullTank ? Icons.local_gas_station_rounded : Icons.water_drop_outlined,
              size: 18,
              color: ChartColors.fuel,
            ),
          ),
          const SizedBox(width: CmSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${Fmt.number(entry.liters, decimals: 2)} L · ${Fmt.pricePerLiter(entry.pricePerLiter)}',
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  [
                    Fmt.date(entry.date),
                    entry.fullTank ? 'plein' : 'appoint',
                    if (entry.stationName.isNotEmpty) entry.stationName,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: CmSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(Fmt.euros(entry.total), style: CmTheme.numbers(size: 20)),
              if (consumption != null)
                Text(
                  '${Fmt.number(consumption!, decimals: 1)} L/100',
                  style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Journal des dépenses.
class _ExpenseLog extends ConsumerStatefulWidget {
  const _ExpenseLog({required this.expenses});

  final List<Expense> expenses;

  @override
  ConsumerState<_ExpenseLog> createState() => _ExpenseLogState();
}

class _ExpenseLogState extends ConsumerState<_ExpenseLog> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final list = widget.expenses;
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
        child: Text(
          'Péages, équipement, pièces… note-les pour avoir le vrai coût de ta passion.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final shown = _all ? list : list.take(5).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(CmSpacing.radius),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) const Divider(indent: 64, height: 1),
                  Dismissible(
                    key: ValueKey('expense-${shown[i].id}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: CmColors.red,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: CmSpacing.xl),
                      child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                    ),
                    onDismissed: (_) {
                      final e = shown[i];
                      final repo = ref.read(garageRepositoryProvider);
                      repo.deleteExpense(e.id);
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          SnackBar(
                            content: Text('${e.category.label} supprimé'),
                            action: SnackBarAction(label: 'Annuler', onPressed: () => repo.upsertExpense(e)),
                          ),
                        );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg, vertical: CmSpacing.md),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: _expenseColor(shown[i].category).withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(shown[i].category.icon, size: 18, color: _expenseColor(shown[i].category)),
                          ),
                          const SizedBox(width: CmSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  shown[i].label.isNotEmpty ? shown[i].label : shown[i].category.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                Text(
                                  [
                                    Fmt.date(shown[i].date),
                                    if (shown[i].label.isNotEmpty) shown[i].category.label,
                                    if (shown[i].rideId != null) 'balade',
                                  ].join(' · '),
                                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          Text(Fmt.euros(shown[i].amount), style: CmTheme.numbers(size: 20)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (list.length > 5)
            TextButton(
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? 'Réduire' : 'Voir les ${list.length} dépenses'),
            ),
        ],
      ),
    );
  }

  static Color _expenseColor(ExpenseCategory c) =>
      c == ExpenseCategory.entretien ? ChartColors.maintenance : ChartColors.expenses;
}
