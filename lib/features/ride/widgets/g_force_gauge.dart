import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';

/// Cadran des accélérations (« cercle des G ») : le point monte quand on
/// accélère, descend quand on freine, et part sur le côté en virage. Une
/// traînée montre les dernières secondes ; les max de la balade sont écrits
/// sous le cadran.
///
/// Convention : [longG] positif = accélération, négatif = freinage ;
/// [latG] négatif = virage à gauche. Les max sont des valeurs positives.
class GForceGauge extends StatefulWidget {
  const GForceGauge({
    super.key,
    required this.longG,
    this.latG = 0,
    this.maxAccelG = 0,
    this.maxDecelG = 0,
    this.size = 280,
    this.dimmed = false,
  });

  final double longG;
  final double latG;
  final double maxAccelG;
  final double maxDecelG;

  /// Largeur du cadran (la hauteur vaut ~0,86 × la largeur, comme la jauge d'angle).
  final double size;
  final bool dimmed;

  /// Bord du cadran, en G.
  static const double rangeG = 1.2;

  /// G latéral d'après l'angle d'inclinaison (physique du virage : tan φ).
  static double lateralFromLean(double leanDeg) =>
      math.tan(leanDeg.clamp(-60.0, 60.0) * math.pi / 180).clamp(-rangeG, rangeG);

  @override
  State<GForceGauge> createState() => _GForceGaugeState();
}

class _GForceGaugeState extends State<GForceGauge> {
  static const _trailLength = 14;
  final _trail = <Offset>[];

  Offset get _point => Offset(widget.latG, widget.longG);

  @override
  void initState() {
    super.initState();
    _trail.add(_point);
  }

  @override
  void didUpdateWidget(GForceGauge old) {
    super.didUpdateWidget(old);
    if (old.longG != widget.longG || old.latG != widget.latG) {
      _trail.add(_point);
      if (_trail.length > _trailLength) _trail.removeAt(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final long = widget.longG.isFinite ? widget.longG : 0.0;
    final braking = long < -0.05;
    final accel = long > 0.05;
    final color = braking ? CmColors.red : (accel ? CmColors.green : Colors.white);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final label = braking ? 'FREINAGE' : (accel ? 'ACCÉLÉRATION' : 'STABLE');
    return Semantics(
      label:
          '${_g(long.abs())} G ${braking
              ? 'au freinage'
              : accel
              ? 'en accélération'
              : ''}',
      child: SizedBox(
        width: size,
        height: size * 0.86,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: size,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: size * 0.64,
                  child: TweenAnimationBuilder<Offset>(
                    tween: Tween(end: _point),
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    builder: (context, p, _) => CustomPaint(
                      painter: GForcePainter(
                        point: p,
                        trail: List.of(_trail),
                        maxAccelG: widget.maxAccelG,
                        maxDecelG: widget.maxDecelG,
                        dimmed: widget.dimmed,
                        labelColor: muted,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: size * 0.02),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      _g(long.abs()),
                      style: CmTheme.numbers(
                        size: size * 0.12,
                        color: widget.dimmed ? color.withValues(alpha: 0.5) : color,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'G',
                      style: CmTheme.numbers(size: size * 0.07, color: muted),
                    ),
                  ],
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: math.max(10, size * 0.04),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.2,
                    color: muted,
                  ),
                ),
                SizedBox(height: size * 0.012),
                Text(
                  'Max : accél. ${_g(widget.maxAccelG)} · frein ${_g(widget.maxDecelG)} G',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: math.max(10, size * 0.042), color: muted, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _g(double v) => Fmt.number(v, decimals: 2);
}

/// Dessin du cercle des G (exposé pour les tests).
class GForcePainter extends CustomPainter {
  GForcePainter({
    required this.point,
    this.trail = const [],
    this.maxAccelG = 0,
    this.maxDecelG = 0,
    this.dimmed = false,
    this.labelColor = const Color(0xFF9AA3B2),
  });

  /// x = G latéral, y = G longitudinal.
  final Offset point;
  final List<Offset> trail;
  final double maxAccelG;
  final double maxDecelG;
  final bool dimmed;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 2;
    Offset toCanvas(Offset g) {
      final x = g.dx.clamp(-GForceGauge.rangeG, GForceGauge.rangeG) / GForceGauge.rangeG;
      final y = g.dy.clamp(-GForceGauge.rangeG, GForceGauge.rangeG) / GForceGauge.rangeG;
      // Accélération vers le haut, freinage vers le bas.
      return c + Offset(x * r, -y * r);
    }

    // Fond, anneaux 0,5 G et 1 G, axes.
    canvas.drawCircle(c, r, Paint()..color = Colors.white.withValues(alpha: 0.04));
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.16);
    canvas.drawCircle(c, r, ring);
    canvas.drawCircle(c, r * 0.5 / GForceGauge.rangeG, ring);
    canvas.drawCircle(c, r * 1.0 / GForceGauge.rangeG, ring..color = Colors.white.withValues(alpha: 0.28));
    final axis = Paint()
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.12);
    canvas.drawLine(c - Offset(r, 0), c + Offset(r, 0), axis);
    canvas.drawLine(c - Offset(0, r), c + Offset(0, r), axis);

    final fontSize = math.max(9.0, r * 0.13);
    void label(String text, Offset at, {Color? color}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: CmTheme.numbers(size: fontSize, weight: FontWeight.w700, color: color ?? labelColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    }

    label('ACCÉL.', c - Offset(0, r * 0.82), color: CmColors.green.withValues(alpha: 0.8));
    label('FREIN', c + Offset(0, r * 0.82), color: CmColors.red.withValues(alpha: 0.8));
    label('1 G', c + Offset(r * 0.6, -r * 0.62));

    // Repères des max.
    final mark = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    if (maxAccelG > 0.02) {
      final p = toCanvas(Offset(0, maxAccelG));
      canvas.drawLine(p - const Offset(8, 0), p + const Offset(8, 0), mark..color = CmColors.green);
    }
    if (maxDecelG > 0.02) {
      final p = toCanvas(Offset(0, -maxDecelG));
      canvas.drawLine(p - const Offset(8, 0), p + const Offset(8, 0), mark..color = CmColors.red);
    }

    // Traînée des dernières secondes.
    for (var i = 0; i < trail.length; i++) {
      final alpha = (i + 1) / (trail.length + 1) * 0.35;
      canvas.drawCircle(toCanvas(trail[i]), r * 0.035, Paint()..color = CmColors.orange.withValues(alpha: alpha));
    }

    // Point courant.
    final long = point.dy;
    final color = long < -0.05 ? CmColors.red : (long > 0.05 ? CmColors.green : CmColors.orange);
    final p = toCanvas(point);
    canvas.drawCircle(p, r * 0.11, Paint()..color = color.withValues(alpha: dimmed ? 0.15 : 0.3));
    canvas.drawCircle(p, r * 0.065, Paint()..color = dimmed ? color.withValues(alpha: 0.5) : color);
  }

  @override
  bool shouldRepaint(GForcePainter old) =>
      old.point != point ||
      old.maxAccelG != maxAccelG ||
      old.maxDecelG != maxDecelG ||
      old.dimmed != dimmed ||
      old.trail.length != trail.length ||
      (trail.isNotEmpty && old.trail.lastOrNull != trail.last);
}
