import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../autonomy.dart';

/// Couleur du niveau d'essence (rouge → ambre → vert).
Color fuelLevelColor(double ratio, {bool low = false}) {
  if (low || ratio < 0.15) return CmColors.red;
  if (ratio < 0.35) return CmColors.amber;
  return CmColors.green;
}

/// Jauge de réservoir élégante, réutilisable (garage, HUD de balade…).
///
/// - par défaut : cadran en arc de 270° avec l'autonomie en grands chiffres ;
/// - [compact] : barre segmentée horizontale + autonomie (pour un HUD ou une liste).
class FuelGauge extends StatelessWidget {
  const FuelGauge({
    super.key,
    required this.ratio,
    this.remainingKm,
    this.low = false,
    this.size = 150,
    this.compact = false,
    this.reserveRatio,
    this.label = 'autonomie',
  });

  /// Jauge à partir d'une estimation d'autonomie.
  factory FuelGauge.fromAutonomy(
    AutonomyInfo info, {
    Key? key,
    double size = 150,
    bool compact = false,
    double? reserveLiters,
  }) => FuelGauge(
    key: key,
    ratio: info.fillRatio,
    remainingKm: info.remainingKm,
    low: info.low,
    size: size,
    compact: compact,
    reserveRatio: reserveLiters != null && info.tankLiters > 0 ? reserveLiters / info.tankLiters : null,
  );

  /// Niveau 0..1.
  final double ratio;

  /// Km restants (affichés au centre).
  final double? remainingKm;

  /// Alerte autonomie (tout passe au rouge).
  final bool low;

  /// Diamètre du cadran, ou hauteur de référence en mode compact.
  final double size;
  final bool compact;

  /// Part du réservoir correspondant à la réserve (zone hachurée en rouge).
  final double? reserveRatio;
  final String label;

  @override
  Widget build(BuildContext context) {
    final r = ratio.isNaN ? 0.0 : ratio.clamp(0.0, 1.0).toDouble();
    final semantics = remainingKm != null
        ? 'Réservoir ${(r * 100).round()} %, environ ${Fmt.number(remainingKm!)} km d\'autonomie'
        : 'Réservoir ${(r * 100).round()} %';
    return Semantics(label: semantics, child: compact ? _buildCompact(context, r) : _buildArc(context, r));
  }

  Widget _buildArc(BuildContext context, double r) {
    final scheme = Theme.of(context).colorScheme;
    final color = fuelLevelColor(r, low: low);
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: r),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => CustomPaint(
          painter: _ArcGaugePainter(
            ratio: value,
            reserveRatio: reserveRatio,
            track: scheme.surfaceContainerHighest,
            tick: scheme.onSurfaceVariant.withValues(alpha: 0.45),
            low: low,
          ),
          foregroundPainter: _ArcLabelsPainter(
            color: scheme.onSurfaceVariant,
            emptyColor: color == CmColors.red ? CmColors.red : scheme.onSurfaceVariant,
            fontSize: math.max(9, size * 0.075),
          ),
          child: Padding(
            padding: EdgeInsets.all(size * 0.16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  low ? Icons.local_gas_station : Icons.local_gas_station_outlined,
                  size: size * 0.12,
                  color: low ? CmColors.red : scheme.onSurfaceVariant,
                ),
                SizedBox(height: size * 0.02),
                FittedBox(
                  child: Text(
                    remainingKm != null ? Fmt.number(remainingKm!) : '${(r * 100).round()}',
                    style: CmTheme.numbers(size: size * 0.26, color: low ? CmColors.red : scheme.onSurface),
                  ),
                ),
                Text(
                  remainingKm != null ? 'km · $label' : '%',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant, fontSize: math.max(10, size * 0.072)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context, double r) {
    final scheme = Theme.of(context).colorScheme;
    final color = fuelLevelColor(r, low: low);
    const segments = 10;
    final filled = r <= 0 ? 0 : (r * segments).ceil().clamp(1, segments);
    final h = size.clamp(18.0, 60.0) * 0.36;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.local_gas_station, size: h * 1.4, color: low ? CmColors.red : scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        for (var i = 0; i < segments; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: h * 0.62,
            height: h,
            margin: const EdgeInsets.symmetric(horizontal: 1.2),
            decoration: BoxDecoration(
              color: i < filled ? color : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        if (remainingKm != null) ...[
          const SizedBox(width: 8),
          Text(
            Fmt.number(remainingKm!),
            style: CmTheme.numbers(size: h * 1.5, color: low ? CmColors.red : scheme.onSurface),
          ),
          const SizedBox(width: 3),
          Text(
            'km',
            style: CmTheme.numbers(size: h * 0.9, weight: FontWeight.w600, color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

const _startAngle = 135 * math.pi / 180;
const _sweepAngle = 270 * math.pi / 180;

class _ArcGaugePainter extends CustomPainter {
  _ArcGaugePainter({
    required this.ratio,
    required this.reserveRatio,
    required this.track,
    required this.tick,
    required this.low,
  });

  final double ratio;
  final double? reserveRatio;
  final Color track;
  final Color tick;
  final bool low;

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final stroke = s * 0.085;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = s / 2 - stroke / 2 - 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Piste.
    canvas.drawArc(
      rect,
      _startAngle,
      _sweepAngle,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );

    // Zone de réserve (fin trait à l'extérieur).
    final rr = reserveRatio;
    if (rr != null && rr > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius + stroke * 0.5 + 3),
        _startAngle,
        _sweepAngle * rr.clamp(0.0, 1.0),
        false,
        Paint()
          ..color = CmColors.red.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }

    // Graduations.
    for (var i = 0; i <= 8; i++) {
      final a = _startAngle + _sweepAngle * i / 8;
      final major = i % 4 == 0;
      final inner = radius - stroke / 2 - (major ? s * 0.07 : s * 0.045);
      final outer = radius - stroke / 2 - s * 0.02;
      canvas.drawLine(
        center + Offset(math.cos(a), math.sin(a)) * inner,
        center + Offset(math.cos(a), math.sin(a)) * outer,
        Paint()
          ..color = tick
          ..strokeWidth = major ? 2 : 1.2
          ..strokeCap = StrokeCap.round,
      );
    }

    if (ratio <= 0.001) return;

    // Niveau : dégradé rouge → ambre → vert le long de l'arc. La fin du
    // dégradé reboucle vers le rouge pour que le bout arrondi du début reste rouge.
    final f = _sweepAngle / (2 * math.pi);
    final gradient = SweepGradient(
      colors: low
          ? const [CmColors.red, CmColors.red]
          : const [CmColors.red, CmColors.amber, CmColors.green, CmColors.green, CmColors.red],
      stops: low ? const [0, 1] : [0, 0.25 * f, 0.7 * f, f, 1],
      transform: const GradientRotation(_startAngle),
    );
    final sweep = _sweepAngle * ratio;
    final level = fuelLevelColor(ratio, low: low);
    // Halo.
    canvas.drawArc(
      rect,
      _startAngle,
      sweep,
      false,
      Paint()
        ..color = level.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 1.9
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.6),
    );
    canvas.drawArc(
      rect,
      _startAngle,
      sweep,
      false,
      Paint()
        ..shader = gradient.createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
    // Curseur au bout du niveau.
    final end = _startAngle + sweep;
    final tip = center + Offset(math.cos(end), math.sin(end)) * radius;
    canvas.drawCircle(tip, stroke * 0.36, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _ArcGaugePainter old) =>
      old.ratio != ratio ||
      old.reserveRatio != reserveRatio ||
      old.track != track ||
      old.tick != tick ||
      old.low != low;
}

/// Lettres E / F aux extrémités du cadran.
class _ArcLabelsPainter extends CustomPainter {
  _ArcLabelsPainter({required this.color, required this.emptyColor, required this.fontSize});

  final Color color;
  final Color emptyColor;
  final double fontSize;

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = s / 2 - s * 0.085 / 2 - 2;
    void label(String text, double angle, Color c) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: c, fontSize: fontSize, fontWeight: FontWeight.w800),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final p = center + Offset(math.cos(angle), math.sin(angle)) * (radius * 0.98);
      tp.paint(canvas, p + Offset(-tp.width / 2, s * 0.06));
    }

    label('E', _startAngle, emptyColor);
    label('F', _startAngle + _sweepAngle, color);
  }

  @override
  bool shouldRepaint(covariant _ArcLabelsPainter old) =>
      old.color != color || old.emptyColor != emptyColor || old.fontSize != fontSize;
}
