import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// Jauge d'inclinaison : arc gradué de 0 à 60° de chaque côté, silhouette de
/// moto (vue de dos) qui se penche, repères des angles max à gauche et à
/// droite, valeur en grand.
///
/// Convention : [angleDeg] négatif = gauche, positif = droite. Les max sont
/// des valeurs positives.
class LeanGauge extends StatelessWidget {
  const LeanGauge({
    super.key,
    required this.angleDeg,
    this.maxLeftDeg = 0,
    this.maxRightDeg = 0,
    this.size = 280,
    this.showValue = true,
    this.dimmed = false,
  });

  final double angleDeg;
  final double maxLeftDeg;
  final double maxRightDeg;

  /// Largeur de la jauge (la hauteur vaut ~0,86 × la largeur).
  final double size;

  /// Affiche la valeur en grand sous la moto.
  final bool showValue;

  /// Rendu atténué (pause, calibrage…).
  final bool dimmed;

  static const double rangeDeg = 60;

  @override
  Widget build(BuildContext context) {
    final target = angleDeg.isFinite ? angleDeg.clamp(-70.0, 70.0) : 0.0;
    return Semantics(
      label:
          'Angle ${target.abs().round()} degrés ${target < 0
              ? 'à gauche'
              : target > 0
              ? 'à droite'
              : ''}',
      child: SizedBox(
        width: size,
        height: size * (showValue ? 0.86 : 0.6),
        // Pas d'animation entre deux valeurs : en balade l'angle change jusqu'à
        // 10 fois par seconde, et une animation relancée à chaque fois ferait
        // redessiner l'écran 60 fois par seconde en continu (batterie).
        child: Builder(
          builder: (context) {
            final angle = target.toDouble();
            final color = CmColors.forLean(angle.abs());
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: LeanGaugePainter(
                      angleDeg: angle,
                      maxLeftDeg: maxLeftDeg,
                      maxRightDeg: maxRightDeg,
                      dimmed: dimmed,
                      labelColor: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (showValue)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: size * 0.585,
                    child: _Value(angle: angle, color: dimmed ? color.withValues(alpha: 0.5) : color, size: size),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Value extends StatelessWidget {
  const _Value({required this.angle, required this.color, required this.size});

  final double angle;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final abs = angle.abs().round();
    final side = abs == 0 ? '' : (angle < 0 ? 'GAUCHE' : 'DROITE');
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$abs',
              style: CmTheme.numbers(size: size * 0.2, color: color),
            ),
            Padding(
              padding: EdgeInsets.only(top: size * 0.012),
              child: Text(
                '°',
                style: CmTheme.numbers(size: size * 0.11, color: color),
              ),
            ),
          ],
        ),
        SizedBox(height: size * 0.008),
        Text(
          side.isEmpty ? 'DROIT' : side,
          style: TextStyle(
            fontSize: math.max(10, size * 0.042),
            fontWeight: FontWeight.w800,
            letterSpacing: 2.4,
            color: muted,
          ),
        ),
      ],
    );
  }
}

/// Dessin de la jauge (exposé pour réutilisation et tests).
class LeanGaugePainter extends CustomPainter {
  LeanGaugePainter({
    required this.angleDeg,
    this.maxLeftDeg = 0,
    this.maxRightDeg = 0,
    this.dimmed = false,
    this.labelColor = const Color(0xFF9AA3B2),
  });

  final double angleDeg;
  final double maxLeftDeg;
  final double maxRightDeg;
  final bool dimmed;
  final Color labelColor;

  static const double _arcSpanDeg = 66;
  static const List<(double, double)> _bands = [(0, 15), (15, 30), (30, 40), (40, 48), (48, _arcSpanDeg)];

  static double _rad(double deg) => deg * math.pi / 180;

  /// Angle canvas (radians, horaire depuis +x) pour une inclinaison donnée.
  static double _canvasAngle(double leanDeg) => -math.pi / 2 + _rad(leanDeg);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final pivot = Offset(w / 2, w * 0.56);
    final r = w * 0.455;
    final track = w * 0.05;
    final rect = Rect.fromCircle(center: pivot, radius: r);
    final opacity = dimmed ? 0.45 : 1.0;

    // Fond de piste.
    canvas.drawArc(
      rect,
      _canvasAngle(-_arcSpanDeg),
      _rad(_arcSpanDeg * 2),
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.06)
        ..style = PaintingStyle.stroke
        ..strokeWidth = track
        ..strokeCap = StrokeCap.round,
    );

    // Zones colorées atténuées (vert → rouge), symétriques.
    for (final (from, to) in _bands) {
      final c = CmColors.forLean((from + to) / 2);
      final paint = Paint()
        ..color = c.withValues(alpha: 0.16 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = track
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(rect, _canvasAngle(from), _rad(to - from), false, paint);
      canvas.drawArc(rect, _canvasAngle(-to), _rad(to - from), false, paint);
    }

    // Arc actif, avec halo.
    final a = angleDeg.clamp(-_arcSpanDeg, _arcSpanDeg).toDouble();
    final color = CmColors.forLean(a.abs()).withValues(alpha: opacity);
    if (a.abs() > 0.5) {
      final start = a > 0 ? _canvasAngle(0) : _canvasAngle(a);
      final sweep = _rad(a.abs());
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..color = color.withValues(alpha: 0.55 * opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = track * 1.9
          ..strokeCap = StrokeCap.round
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, track * 0.6),
      );
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = track
          ..strokeCap = StrokeCap.round,
      );
    }

    // Graduations.
    final tickPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var d = -60; d <= 60; d += 5) {
      final major = d % 10 == 0;
      final ang = _canvasAngle(d.toDouble());
      final outer = r - track * 0.9;
      final inner = outer - (major ? w * 0.045 : w * 0.022);
      final dir = Offset(math.cos(ang), math.sin(ang));
      final reached = d != 0 && d.sign == a.sign && d.abs() <= a.abs();
      tickPaint
        ..strokeWidth = major ? w * 0.009 : w * 0.005
        ..color = reached ? color : Colors.white.withValues(alpha: (major ? 0.55 : 0.25) * opacity);
      canvas.drawLine(pivot + dir * inner, pivot + dir * outer, tickPaint);
      if (major && d != 0 && d.abs() % 20 == 0) {
        _text(
          canvas,
          '${d.abs()}',
          pivot + dir * (inner - w * 0.05),
          w * 0.048,
          labelColor.withValues(alpha: 0.9 * opacity),
          FontWeight.w700,
        );
      }
    }

    // Repère 0°.
    final top = pivot + Offset(0, -(r + track * 0.85));
    final zero = Path()
      ..moveTo(top.dx, top.dy + w * 0.028)
      ..lineTo(top.dx - w * 0.02, top.dy - w * 0.004)
      ..lineTo(top.dx + w * 0.02, top.dy - w * 0.004)
      ..close();
    canvas.drawPath(zero, Paint()..color = Colors.white.withValues(alpha: 0.7 * opacity));

    // Côtés G / D.
    final endL = _canvasAngle(-_arcSpanDeg - 6);
    final endR = _canvasAngle(_arcSpanDeg + 6);
    _text(canvas, 'G', pivot + Offset(math.cos(endL), math.sin(endL)) * r, w * 0.05, labelColor, FontWeight.w800);
    _text(canvas, 'D', pivot + Offset(math.cos(endR), math.sin(endR)) * r, w * 0.05, labelColor, FontWeight.w800);

    // Repères des max.
    if (maxLeftDeg >= 1) _maxMarker(canvas, pivot, r, track, w, -maxLeftDeg.clamp(0.0, _arcSpanDeg));
    if (maxRightDeg >= 1) _maxMarker(canvas, pivot, r, track, w, maxRightDeg.clamp(0.0, _arcSpanDeg));

    // Route.
    final roadPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0.35 * opacity),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(pivot.dx - r * 0.75, pivot.dy - 2, r * 1.5, 4))
      ..strokeWidth = w * 0.008
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(pivot + Offset(-r * 0.75, 0), pivot + Offset(r * 0.75, 0), roadPaint);

    // Moto qui se penche.
    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(_rad(a));
    _drawBike(canvas, r * 0.56, color, opacity);
    canvas.restore();
  }

  void _maxMarker(Canvas canvas, Offset pivot, double r, double track, double w, double deg) {
    final ang = _canvasAngle(deg);
    final dir = Offset(math.cos(ang), math.sin(ang));
    final tip = pivot + dir * (r + track * 0.6);
    final base = pivot + dir * (r + track * 0.6 + w * 0.04);
    final normal = Offset(-dir.dy, dir.dx) * (w * 0.02);
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base.dx + normal.dx, base.dy + normal.dy)
      ..lineTo(base.dx - normal.dx, base.dy - normal.dy)
      ..close();
    final c = CmColors.forLean(deg.abs());
    canvas.drawPath(path, Paint()..color = c);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    _text(canvas, '${deg.abs().round()}°', pivot + dir * (r + track * 0.6 + w * 0.07), w * 0.042, c, FontWeight.w800);
  }

  /// Silhouette de moto vue de dos, origine = point de contact du pneu.
  void _drawBike(Canvas canvas, double h, Color accent, double opacity) {
    final body = Colors.white.withValues(alpha: 0.92 * opacity);
    final dark = const Color(0xFF1B1F26).withValues(alpha: opacity);
    final mid = const Color(0xFF3A414D).withValues(alpha: opacity);

    // Ombre portée au sol.
    canvas.drawOval(
      Rect.fromCenter(center: Offset(0, h * 0.01), width: h * 0.42, height: h * 0.05),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35 * opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, h * 0.02),
    );

    // Pneu arrière.
    final tire = RRect.fromRectAndRadius(Rect.fromLTRB(-h * 0.07, -h * 0.42, h * 0.07, 0), Radius.circular(h * 0.07));
    canvas.drawRRect(tire, Paint()..color = dark);
    canvas.drawRRect(
      tire,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.012,
    );

    // Garde-boue / feu arrière.
    final tail = Path()
      ..moveTo(-h * 0.13, -h * 0.40)
      ..lineTo(h * 0.13, -h * 0.40)
      ..lineTo(h * 0.20, -h * 0.58)
      ..lineTo(-h * 0.20, -h * 0.58)
      ..close();
    canvas.drawPath(tail, Paint()..color = mid);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(0, -h * 0.45), width: h * 0.16, height: h * 0.04),
        Radius.circular(h * 0.02),
      ),
      Paint()..color = CmColors.red.withValues(alpha: 0.9 * opacity),
    );

    // Guidon (dépasse de chaque côté).
    final bar = Paint()
      ..color = body
      ..strokeWidth = h * 0.045
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(-h * 0.36, -h * 0.70), Offset(h * 0.36, -h * 0.70), bar);
    canvas.drawCircle(Offset(-h * 0.38, -h * 0.66), h * 0.035, Paint()..color = mid);
    canvas.drawCircle(Offset(h * 0.38, -h * 0.66), h * 0.035, Paint()..color = mid);

    // Pilote : buste.
    final torso = Path()
      ..moveTo(-h * 0.12, -h * 0.56)
      ..lineTo(h * 0.12, -h * 0.56)
      ..quadraticBezierTo(h * 0.25, -h * 0.74, h * 0.20, -h * 0.86)
      ..lineTo(-h * 0.20, -h * 0.86)
      ..quadraticBezierTo(-h * 0.25, -h * 0.74, -h * 0.12, -h * 0.56)
      ..close();
    canvas.drawPath(torso, Paint()..color = body);
    // Bande de couleur sur le blouson.
    canvas.drawLine(
      Offset(-h * 0.17, -h * 0.75),
      Offset(h * 0.17, -h * 0.75),
      Paint()
        ..color = accent
        ..strokeWidth = h * 0.035
        ..strokeCap = StrokeCap.round,
    );

    // Casque.
    final helmetCenter = Offset(0, -h * 0.98);
    canvas.drawCircle(helmetCenter, h * 0.13, Paint()..color = accent);
    canvas.drawCircle(
      helmetCenter,
      h * 0.13,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.012,
    );
    // Reflet.
    canvas.drawArc(
      Rect.fromCircle(center: helmetCenter, radius: h * 0.09),
      -math.pi * 0.9,
      math.pi * 0.45,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.018
        ..strokeCap = StrokeCap.round,
    );
  }

  /// Police des chiffres du thème, créée une seule fois (paint est appelé à
  /// chaque image de l'animation).
  static final TextStyle _labelStyle = CmTheme.numbers(size: 12, weight: FontWeight.w700);

  void _text(Canvas canvas, String text, Offset center, double fontSize, Color color, FontWeight weight) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: _labelStyle.copyWith(fontSize: fontSize * 1.12, color: color, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant LeanGaugePainter old) =>
      old.angleDeg != angleDeg ||
      old.maxLeftDeg != maxLeftDeg ||
      old.maxRightDeg != maxRightDeg ||
      old.dimmed != dimmed ||
      old.labelColor != labelColor;
}
