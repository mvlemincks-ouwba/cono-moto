import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../ride_analysis.dart';

/// Couleurs des graphes : trio catégoriel validé (contraste, daltonisme) en
/// clair comme en sombre, cohérent avec la palette asphalte + orange.
class ChartColors {
  ChartColors._();

  static const orange = Color(0xFFE8641E);
  static const teal = Color(0xFF22A99C);
  static const blue = Color(0xFF5B8FE8);

  static const fuel = orange;
  static const expenses = teal;
  static const maintenance = blue;

  /// Angle : gauche / droite (paire divergente autour de 0).
  static const leanLeft = teal;
  static const leanRight = orange;

  static Color tooltip(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? CmColors.asphalt500 : const Color(0xFF2B2F36);
}

const _monthShort = ['Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin', 'Juil', 'Août', 'Sep', 'Oct', 'Nov', 'Déc'];

/// « Oct », « Juil »…
String monthShortLabel(DateTime m) => _monthShort[m.month - 1];

/// Intervalle « rond » pour ~[ticks] graduations.
double niceInterval(double maxValue, {int ticks = 4}) {
  if (maxValue <= 0 || maxValue.isNaN) return 1;
  final raw = maxValue / ticks;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final nice = norm <= 1 ? 1 : (norm <= 2 ? 2 : (norm <= 2.5 ? 2.5 : (norm <= 5 ? 5 : 10)));
  return nice * mag;
}

TextStyle _axisStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelSmall!
        .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 10.5);

FlGridData _grid(BuildContext context, double interval) => FlGridData(
  show: true,
  drawVerticalLine: false,
  horizontalInterval: interval,
  getDrawingHorizontalLine: (_) => FlLine(
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
    strokeWidth: 1,
    dashArray: const [3, 4],
  ),
);

/// Carte contenant un graphe avec titre, sous-titre et légende.
class ChartCard extends StatelessWidget {
  const ChartCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.legend,
    this.height = 180,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? legend;
  final Widget? trailing;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.lg, CmSpacing.lg, CmSpacing.md),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(CmSpacing.radius)),
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
                    Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          if (legend != null) ...[const SizedBox(height: CmSpacing.sm), legend!],
          const SizedBox(height: CmSpacing.md),
          SizedBox(height: height, child: child),
        ],
      ),
    );
  }
}

/// Légende : pastille de couleur + libellé (texte en encre neutre).
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.items});

  final List<(String label, Color color)> items;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600);
    return Wrap(
      spacing: CmSpacing.md,
      runSpacing: 4,
      children: [
        for (final (label, color) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 6),
              Text(label, style: style),
            ],
          ),
      ],
    );
  }
}

/// Courbe d'une valeur en fonction de la distance (vitesse, angle, altitude).
///
/// Si [negativeColor] est fourni, la courbe est bicolore autour de 0
/// (ex : angle à gauche / à droite).
class DistanceLineChart extends StatelessWidget {
  const DistanceLineChart({
    super.key,
    required this.points,
    required this.color,
    required this.formatValue,
    this.negativeColor,
    this.minY,
    this.maxY,
    this.symmetric = false,
    this.fill = true,
  });

  final List<SeriesPoint> points;
  final Color color;
  final Color? negativeColor;
  final String Function(double v) formatValue;
  final double? minY;
  final double? maxY;

  /// Axe Y symétrique autour de 0.
  final bool symmetric;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return Center(
        child: Text('Pas assez de données', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }
    final values = points.map((p) => p.value);
    var lo = minY ?? values.reduce(math.min);
    var hi = maxY ?? values.reduce(math.max);
    if (symmetric) {
      final m = math.max(10.0, math.max(lo.abs(), hi.abs()));
      final step = niceInterval(m, ticks: 2);
      hi = (m / step).ceil() * step;
      lo = -hi;
    } else {
      final span = math.max(1.0, hi - lo);
      if (minY == null) lo = math.max(0, lo - span * 0.08);
      if (maxY == null) hi = hi + span * 0.08;
    }
    final interval = niceInterval(hi - lo, ticks: symmetric ? 4 : 3);
    if (!symmetric) {
      lo = (lo / interval).floor() * interval;
      hi = (hi / interval).ceil() * interval;
    }
    final totalKm = points.last.km;
    final xInterval = niceInterval(totalKm, ticks: 4);
    final spots = [for (final p in points) FlSpot(p.km, p.value)];
    final neg = negativeColor;
    final zero = hi == lo ? 0.5 : ((0 - lo) / (hi - lo)).clamp(0.0, 1.0);

    final gradient = neg == null
        ? null
        : LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [neg, neg, color, color],
            stops: [0, zero, zero, 1],
          );

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: totalKm,
        minY: lo,
        maxY: hi,
        clipData: const FlClipData.all(),
        gridData: _grid(context, interval),
        borderData: FlBorderData(show: false),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            if (lo < 0 && hi > 0) HorizontalLine(y: 0, color: Theme.of(context).colorScheme.outline, strokeWidth: 1),
          ],
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: interval,
              getTitlesWidget: (v, meta) {
                if (v == meta.max && !symmetric) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: Text(formatValue(v), style: _axisStyle(context)),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: xInterval,
              getTitlesWidget: (v, meta) {
                if (v == meta.max && v % xInterval != 0) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: Text('${Fmt.number(v)} km', style: _axisStyle(context)),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => ChartColors.tooltip(context),
            tooltipBorderRadius: BorderRadius.circular(10),
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItems: (spots) => [
              for (final s in spots)
                LineTooltipItem(
                  formatValue(s.y),
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
                  children: [
                    TextSpan(
                      text: '\nkm ${Fmt.number(s.x, decimals: 1)}',
                      style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w500, fontSize: 11),
                    ),
                  ],
                ),
            ],
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            preventCurveOverShooting: true,
            color: neg == null ? color : null,
            gradient: gradient,
            gradientArea: LineChartGradientArea.wholeChart,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: fill && neg == null,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [color.withValues(alpha: 0.32), color.withValues(alpha: 0.0)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Barres simples (km par mois, répartition des angles…).
class SimpleBarChart extends StatelessWidget {
  const SimpleBarChart({
    super.key,
    required this.values,
    required this.labels,
    required this.formatValue,
    this.color = ChartColors.orange,
    this.colors,
    this.tooltipLabels,
    this.highlightIndex,
  });

  final List<double> values;
  final List<String> labels;
  final String Function(double v) formatValue;
  final Color color;

  /// Couleur par barre (prioritaire sur [color]).
  final List<Color>? colors;

  /// Libellé complet affiché dans l'infobulle (sinon [labels]).
  final List<String>? tooltipLabels;

  /// Barre mise en avant (les autres sont légèrement atténuées).
  final int? highlightIndex;

  @override
  Widget build(BuildContext context) {
    final maxV = values.isEmpty ? 0.0 : values.reduce(math.max);
    final interval = niceInterval(maxV <= 0 ? 1 : maxV, ticks: 3);
    final top = maxV <= 0 ? interval * 3 : (maxV / interval).ceil() * interval;
    final width = values.isEmpty ? 10.0 : (240 / values.length).clamp(6.0, 26.0);
    return BarChart(
      BarChartData(
        maxY: top,
        minY: 0,
        alignment: BarChartAlignment.spaceAround,
        gridData: _grid(context, interval),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: interval,
              getTitlesWidget: (v, meta) => v == meta.max
                  ? const SizedBox.shrink()
                  : SideTitleWidget(
                      meta: meta,
                      child: Text(formatValue(v), style: _axisStyle(context)),
                    ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= labels.length) return const SizedBox.shrink();
                // Une étiquette sur deux si beaucoup de barres.
                if (labels.length > 8 && (labels.length - 1 - i).isOdd) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: Text(labels[i], style: _axisStyle(context)),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => ChartColors.tooltip(context),
            tooltipBorderRadius: BorderRadius.circular(10),
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
              formatValue(rod.toY),
              const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
              children: [
                TextSpan(
                  text: '\n${(tooltipLabels ?? labels)[group.x]}',
                  style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w500, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < values.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: values[i],
                  width: width,
                  color: (colors != null ? colors![i] : color).withValues(
                    alpha: highlightIndex == null || highlightIndex == i ? 1 : 0.55,
                  ),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  backDrawRodData: BackgroundBarChartRodData(
                    show: true,
                    toY: top,
                    color: Theme.of(context).colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Série d'un graphe empilé.
class StackSeries {
  const StackSeries(this.label, this.color, this.values);

  final String label;
  final Color color;
  final List<double> values;
}

/// Barres empilées (coûts mensuels par catégorie).
class StackedBarChart extends StatelessWidget {
  const StackedBarChart({
    super.key,
    required this.labels,
    required this.series,
    required this.formatValue,
    this.tooltipLabels,
  });

  final List<String> labels;
  final List<StackSeries> series;
  final String Function(double v) formatValue;
  final List<String>? tooltipLabels;

  @override
  Widget build(BuildContext context) {
    final n = labels.length;
    final totals = [for (var i = 0; i < n; i++) series.fold<double>(0, (s, ser) => s + ser.values[i])];
    final maxV = totals.isEmpty ? 0.0 : totals.reduce(math.max);
    final interval = niceInterval(maxV <= 0 ? 10 : maxV, ticks: 3);
    final top = maxV <= 0 ? interval * 3 : (maxV / interval).ceil() * interval;
    final surface = Theme.of(context).colorScheme.surfaceContainer;
    final width = n == 0 ? 10.0 : (240 / n).clamp(6.0, 22.0);

    return BarChart(
      BarChartData(
        maxY: top,
        minY: 0,
        alignment: BarChartAlignment.spaceAround,
        gridData: _grid(context, interval),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              interval: interval,
              getTitlesWidget: (v, meta) => v == meta.max
                  ? const SizedBox.shrink()
                  : SideTitleWidget(
                      meta: meta,
                      child: Text(formatValue(v), style: _axisStyle(context)),
                    ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= n) return const SizedBox.shrink();
                if (n > 8 && (n - 1 - i).isOdd) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: Text(labels[i], style: _axisStyle(context)),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => ChartColors.tooltip(context),
            tooltipBorderRadius: BorderRadius.circular(10),
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            maxContentWidth: 180,
            getTooltipItem: (group, gi, rod, ri) {
              final i = group.x;
              return BarTooltipItem(
                '${(tooltipLabels ?? labels)[i]} · ${formatValue(totals[i])}',
                const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12),
                textAlign: TextAlign.left,
                children: [
                  for (final s in series)
                    if (s.values[i] > 0)
                      TextSpan(
                        text: '\n${s.label} : ${formatValue(s.values[i])}',
                        style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w500, fontSize: 11),
                      ),
                ],
              );
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < n; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: totals[i],
                  width: width,
                  color: Colors.transparent,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  rodStackItems: _stack(i, surface),
                ),
              ],
            ),
        ],
      ),
    );
  }

  List<BarChartRodStackItem> _stack(int i, Color surface) {
    final items = <BarChartRodStackItem>[];
    var from = 0.0;
    for (final s in series) {
      final v = s.values[i];
      if (v <= 0) continue;
      items.add(BarChartRodStackItem(from, from + v, s.color, borderSide: BorderSide(color: surface, width: 1)));
      from += v;
    }
    return items;
  }
}
