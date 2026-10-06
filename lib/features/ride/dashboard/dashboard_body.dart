// Vue compteur du HUD : les vues de l'utilisateur (Balade, Piste, Trail…),
// une par page, qu'on fait défiler d'un geste ou avec les flèches. Chaque
// vue affiche la vitesse en grand, un ou deux cadrans et des tuiles.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/ui/widgets.dart';
import '../../garage/autonomy.dart';
import '../ride_controller.dart';
import '../widgets/g_force_gauge.dart';
import '../widgets/lean_gauge.dart';
import 'dashboard_model.dart';

class DashboardBody extends ConsumerStatefulWidget {
  const DashboardBody({super.key});

  @override
  ConsumerState<DashboardBody> createState() => _DashboardBodyState();
}

class _DashboardBodyState extends ConsumerState<DashboardBody> {
  late final PageController _pages = PageController(initialPage: ref.read(dashboardProvider).activeIndex);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int index) {
    final count = ref.read(dashboardProvider).views.length;
    if (index < 0 || index >= count) return;
    HapticFeedback.selectionClick();
    _pages.animateToPage(index, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final dash = ref.watch(dashboardProvider);
    final index = dash.activeIndex;
    // Vue changée ailleurs (écran de personnalisation) : on suit.
    ref.listen(dashboardProvider.select((d) => d.activeIndex), (_, next) {
      if (_pages.hasClients && (_pages.page?.round() ?? next) != next) _pages.jumpToPage(next);
    });
    return Column(
      children: [
        if (dash.views.length > 1)
          _ViewSwitcher(
            views: dash.views,
            index: index,
            onPrevious: index > 0 ? () => _go(index - 1) : null,
            onNext: index < dash.views.length - 1 ? () => _go(index + 1) : null,
          ),
        Expanded(
          child: PageView(
            controller: _pages,
            onPageChanged: (i) => ref.read(dashboardProvider.notifier).selectIndex(i),
            children: [for (final v in dash.views) DashPage(key: ValueKey(v.id), view: v)],
          ),
        ),
      ],
    );
  }
}

class _ViewSwitcher extends StatelessWidget {
  const _ViewSwitcher({required this.views, required this.index, this.onPrevious, this.onNext});

  final List<DashView> views;
  final int index;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          IconButton(
            onPressed: onPrevious,
            tooltip: 'Vue précédente',
            icon: const Icon(Icons.chevron_left_rounded, size: 30),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    views[index].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 10),
                for (var i = 0; i < views.length; i++)
                  Container(
                    width: i == index ? 14 : 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: i == index ? CmColors.orange : muted.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: onNext,
            tooltip: 'Vue suivante',
            icon: const Icon(Icons.chevron_right_rounded, size: 30),
          ),
        ],
      ),
    );
  }
}

/// Une vue compteur, mise en page selon la place disponible.
class DashPage extends StatelessWidget {
  const DashPage({super.key, required this.view});

  final DashView view;

  static const _tileRowHeight = 78.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final gauges = view.gauges;
    final tiles = view.tiles;
    final rows = (tiles.length / 3).ceil();
    final tilesHeight = rows == 0 ? 0.0 : rows * _tileRowHeight + (rows - 1) * _gap;

    return LayoutBuilder(
      builder: (context, c) {
        final landscape = c.maxWidth > c.maxHeight * 1.1;
        if (landscape) return _landscape(c, gauges, tiles);

        // Portrait : vitesse en haut, cadrans au milieu, tuiles en bas. Si tout
        // ne tient pas, la page entière est réduite plutôt que de déborder.
        final speedSize = gauges.isEmpty
            ? (c.maxHeight * 0.3).clamp(72.0, 200.0)
            : (c.maxHeight * 0.2).clamp(72.0, 156.0);
        final speedBlock = view.showsSpeed ? speedSize * 1.05 : 0.0;
        final minGauges = gauges.isEmpty ? 0.0 : 130.0;
        final height = math.max(c.maxHeight, speedBlock + minGauges + tilesHeight + 16);
        final middle = height - speedBlock - tilesHeight - 16;
        final perGaugeWidth = gauges.length == 2 ? (c.maxWidth - 32 - 12) / 2 : c.maxWidth - 40;
        final gaugeSize = math.max(110.0, math.min(perGaugeWidth, middle / 0.86));

        final page = SizedBox(
          width: c.maxWidth,
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                if (view.showsSpeed && gauges.isNotEmpty) DashSpeed(size: speedSize),
                Expanded(
                  child: gauges.isNotEmpty
                      ? Center(
                          child: _GaugesRow(items: gauges, size: gaugeSize),
                        )
                      : Center(child: view.showsSpeed ? DashSpeed(size: speedSize) : const SizedBox.shrink()),
                ),
                if (tiles.isNotEmpty) DashTiles(items: tiles),
                const SizedBox(height: _gap),
              ],
            ),
          ),
        );
        if (height <= c.maxHeight) return page;
        return FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.topCenter, child: page);
      },
    );
  }

  Widget _landscape(BoxConstraints c, List<DashItem> gauges, List<DashItem> tiles) {
    final gaugeArea = gauges.isEmpty ? 0.0 : c.maxWidth * (gauges.length == 2 ? 0.55 : 0.45);
    final gaugeSize = gauges.isEmpty
        ? 0.0
        : math.min(c.maxHeight / 0.9, (gaugeArea - 12 * (gauges.length - 1)) / gauges.length);
    final leftWidth = math.max(300.0, c.maxWidth - gaugeArea - 44);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: leftWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (view.showsSpeed) DashSpeed(size: math.min(c.maxHeight * (tiles.isEmpty ? 0.6 : 0.42), 150)),
                      if (view.showsSpeed && tiles.isNotEmpty) const SizedBox(height: 12),
                      if (tiles.isNotEmpty) DashTiles(items: tiles),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (gauges.isNotEmpty) ...[
            const SizedBox(width: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: _GaugesRow(items: gauges, size: gaugeSize),
            ),
          ],
        ],
      ),
    );
  }
}

class _GaugesRow extends StatelessWidget {
  const _GaugesRow({required this.items, required this.size});

  final List<DashItem> items;
  final double size;

  @override
  Widget build(BuildContext context) {
    final children = [
      for (final i in items)
        FittedBox(
          fit: BoxFit.scaleDown,
          child: i == DashItem.gforce ? DashGForce(size: size) : DashLean(size: size),
        ),
    ];
    if (children.length == 1) return children.single;
    return Row(mainAxisSize: MainAxisSize.min, children: [children[0], const SizedBox(width: 12), children[1]]);
  }
}

/// Vitesse en très grand.
class DashSpeed extends ConsumerWidget {
  const DashSpeed({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(rideControllerProvider.select((s) => s.speedKmh));
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    final hasFix = ref.watch(rideControllerProvider.select((s) => s.hasFix));
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final text = !hasFix ? '--' : '${speed < 2 ? 0 : speed.round()}';
    return Semantics(
      label: 'Vitesse $text kilomètres heure',
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              text,
              style: CmTheme.numbers(size: size, color: paused ? muted : Colors.white, weight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            Text(
              'km/h',
              style: CmTheme.numbers(size: math.max(18, size * 0.2), color: muted, weight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// Jauge d'inclinaison, avec les conseils de calibrage.
class DashLean extends ConsumerWidget {
  const DashLean({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lean = ref.watch(rideControllerProvider.select((s) => s.leanDeg));
    final maxL = ref.watch(rideControllerProvider.select((s) => s.maxLeanLeftDeg));
    final maxR = ref.watch(rideControllerProvider.select((s) => s.maxLeanRightDeg));
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    final calibrated = ref.watch(rideControllerProvider.select((s) => s.leanCalibrated));
    final fromGyro = ref.watch(rideControllerProvider.select((s) => s.leanFromGyro));
    final speed = ref.watch(rideControllerProvider.select((s) => s.speedKmh));

    String? hint;
    if (paused) {
      hint = null;
    } else if (!calibrated && speed < 5) {
      hint = 'Calibrage de l\'angle… garde le téléphone immobile';
    } else if (!fromGyro && speed >= 12) {
      hint = 'Angle estimé via le GPS (moins précis)';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LeanGauge(angleDeg: lean, maxLeftDeg: maxL, maxRightDeg: maxR, size: size, dimmed: paused),
        if (hint != null) Pill(label: hint, icon: Icons.info_outline_rounded, color: CmColors.sky),
      ],
    );
  }
}

/// Cercle des G : accélération / freinage (d'après la vitesse GPS) et G en
/// virage (d'après l'angle).
class DashGForce extends ConsumerWidget {
  const DashGForce({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final longG = ref.watch(rideControllerProvider.select((s) => s.longG));
    final lean = ref.watch(rideControllerProvider.select((s) => s.leanDeg));
    final maxAccel = ref.watch(rideControllerProvider.select((s) => s.maxAccelG));
    final maxDecel = ref.watch(rideControllerProvider.select((s) => s.maxDecelG));
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    return GForceGauge(
      longG: paused ? 0 : longG,
      latG: paused ? 0 : GForceGauge.lateralFromLean(lean),
      maxAccelG: maxAccel,
      maxDecelG: maxDecel,
      size: size,
      dimmed: paused,
    );
  }
}

/// Tuiles chiffrées, trois par ligne.
class DashTiles extends ConsumerWidget {
  const DashTiles({super.key, required this.items});

  final List<DashItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(rideControllerProvider);
    final autonomy = items.contains(DashItem.autonomy) ? ref.watch(autonomyProvider) : null;
    final tiles = [for (final i in items) dashTile(i, s, autonomy)];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < tiles.length; r += 3) ...[
          if (r > 0) const SizedBox(height: 8),
          Row(
            children: [
              for (var i = r; i < r + 3; i++) ...[
                if (i > r) const SizedBox(width: 8),
                Expanded(child: i < tiles.length ? tiles[i] : const SizedBox.shrink()),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// Tuile d'un élément du compteur.
Widget dashTile(DashItem item, RideSessionState s, AutonomyInfo? autonomy, {DateTime? now}) {
  StatTile tile(String label, String value, {String? unit, Color? color}) =>
      StatTile(compact: true, label: label, value: value, unit: unit, color: color);
  String g(double v) => Fmt.number(v, decimals: 2);

  switch (item) {
    case DashItem.distance:
      final d = s.distanceM;
      return tile('Distance', d < 1000 ? Fmt.number(d) : Fmt.km(d), unit: d < 1000 ? 'm' : 'km');
    case DashItem.movingTime:
      return tile('En route', Fmt.chrono(s.movingTime));
    case DashItem.elapsed:
      return tile('Chrono', Fmt.chrono(s.elapsed));
    case DashItem.avgSpeed:
      return tile('Moyenne', Fmt.number(s.avgSpeedKmh), unit: 'km/h');
    case DashItem.maxSpeed:
      return tile('Max', Fmt.number(s.maxSpeedKmh), unit: 'km/h');
    case DashItem.maxLean:
      return tile('Angles G · D', '${s.maxLeanLeftDeg.round()}° · ${s.maxLeanRightDeg.round()}°');
    case DashItem.maxG:
      return tile('G acc · frein', '${g(s.maxAccelG)} · ${g(s.maxDecelG)}');
    case DashItem.liveG:
      final braking = s.longG < -0.05;
      final accel = s.longG > 0.05;
      return tile(
        braking ? 'Freinage' : (accel ? 'Accélération' : 'G'),
        g(s.longG.abs()),
        unit: 'G',
        color: braking ? CmColors.red : (accel ? CmColors.green : null),
      );
    case DashItem.curves:
      return tile('Virages', '${s.curveCount}');
    case DashItem.hardBrakes:
      return tile('Freinages', '${s.hardBrakeCount}', color: s.hardBrakeCount > 0 ? CmColors.amber : null);
    case DashItem.elevationGain:
      return tile('D+', Fmt.number(s.elevationGainM), unit: 'm');
    case DashItem.altitude:
      final alt = s.altitudeM;
      return tile('Altitude', alt == null ? '--' : Fmt.number(alt), unit: 'm');
    case DashItem.autonomy:
      if (autonomy == null) return tile('Autonomie', '--', unit: 'km');
      return tile(
        'Autonomie',
        Fmt.number(autonomy.remainingKm),
        unit: 'km',
        color: autonomy.low ? CmColors.amber : null,
      );
    case DashItem.clock:
      return tile('Heure', Fmt.time(now ?? DateTime.now()));
    case DashItem.speed:
    case DashItem.lean:
    case DashItem.gforce:
      return const SizedBox.shrink();
  }
}
