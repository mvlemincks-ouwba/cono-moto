import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../services/routing/elevation_client.dart';

/// Profil d'altitude (fl_chart) avec dégradé orange.
class ElevationChart extends StatelessWidget {
  const ElevationChart({super.key, required this.profile, this.color = CmColors.orange, this.height = 170});

  final ElevationProfile profile;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (profile.elevationsM.length < 2) return SizedBox(height: height);
    final spots = <FlSpot>[
      for (var i = 0; i < profile.elevationsM.length; i++)
        if (profile.elevationsM[i].isFinite) FlSpot(profile.distancesM[i] / 1000, profile.elevationsM[i]),
    ];
    if (spots.length < 2) return SizedBox(height: height);
    final minE = spots.map((s) => s.y).reduce(math.min);
    final maxE = spots.map((s) => s.y).reduce(math.max);
    final span = math.max(60.0, maxE - minE);
    final minY = (minE - span * 0.15).floorToDouble();
    final maxY = (maxE + span * 0.15).ceilToDouble();
    final maxX = spots.last.x;
    final xInterval = _niceInterval(maxX / 4);
    final yInterval = _niceInterval((maxY - minY) / 3);
    final labelStyle = TextStyle(color: scheme.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w600);

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: maxX,
          minY: minY,
          maxY: maxY,
          clipData: const FlClipData.all(),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: yInterval,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: scheme.outlineVariant.withValues(alpha: 0.5), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                interval: yInterval,
                getTitlesWidget: (v, meta) {
                  if (v == meta.min || v == meta.max) return const SizedBox.shrink();
                  return SideTitleWidget(
                    meta: meta,
                    child: Text('${v.round()} m', style: labelStyle),
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
                    child: Text('${v.round()} km', style: labelStyle),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            handleBuiltInTouches: true,
            touchTooltipData: LineTouchTooltipData(
              tooltipBorderRadius: BorderRadius.circular(10),
              getTooltipColor: (_) => CmColors.asphalt600,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    '${s.y.round()} m\n',
                    CmTheme.numbers(size: 18, color: Colors.white),
                    children: [
                      TextSpan(
                        text: 'km ${Fmt.number(s.x, decimals: 1)}',
                        style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
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
              curveSmoothness: 0.18,
              preventCurveOverShooting: true,
              color: color,
              barWidth: 2.6,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [color.withValues(alpha: 0.45), color.withValues(alpha: 0.02)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static double _niceInterval(double raw) {
    if (raw <= 0) return 1;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final n = raw / mag;
    final nice = n < 1.5 ? 1 : (n < 3 ? 2 : (n < 7 ? 5 : 10));
    return nice * mag;
  }
}
