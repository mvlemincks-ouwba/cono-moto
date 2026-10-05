import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../services/routing/route_generator.dart';

/// Écran d'attente animé pendant le calcul des balades : une route qui
/// serpente, une moto qui avance, des messages qui défilent.
class GenerationLoader extends StatefulWidget {
  const GenerationLoader({super.key, this.progress, this.onCancel, this.styleIcon});

  final GenerationProgress? progress;
  final VoidCallback? onCancel;
  final IconData? styleIcon;

  @override
  State<GenerationLoader> createState() => _GenerationLoaderState();
}

class _GenerationLoaderState extends State<GenerationLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))
    ..repeat();
  Timer? _tipTimer;
  int _tip = 0;

  static const _tips = [
    'Les plus belles routes sont rarement les plus directes.',
    "Pense à faire le plein avant de partir, les stations se font rares dans les virolos.",
    "Le serveur d'itinéraires est partagé : on y va mollo, une demande par seconde.",
    'On évite les ronds-points inutiles et les zones commerciales.',
    'Un col se savoure dans le sens de la montée.',
    'Pause café conseillée toutes les deux heures.',
    'Gravillons en sortie de virage ? Signale-les aux potes.',
  ];

  @override
  void initState() {
    super.initState();
    _tip = DateTime.now().second % _tips.length;
    _tipTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) setState(() => _tip = (_tip + 1) % _tips.length);
    });
  }

  @override
  void dispose() {
    _tipTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = widget.progress;
    final fraction = p?.fraction ?? 0;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.35),
          radius: 1.1,
          colors: [Color(0xFF2A1A12), CmColors.asphalt900],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: CmSpacing.xl),
          child: Column(
            children: [
              const Spacer(),
              SizedBox(
                height: 260,
                width: double.infinity,
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (context, _) => CustomPaint(
                    painter: _WindingRoadPainter(_anim.value),
                    child: Center(
                      child: Transform.translate(
                        offset: const Offset(0, -6),
                        child: Icon(
                          widget.styleIcon ?? Icons.two_wheeler,
                          color: Colors.white.withValues(alpha: 0.08),
                          size: 120,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: CmSpacing.xl),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a),
                    child: child,
                  ),
                ),
                child: Text(
                  p?.message ?? 'On chauffe les pneus…',
                  key: ValueKey(p?.message),
                  textAlign: TextAlign.center,
                  style: text.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: CmSpacing.lg),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: math.max(0.04, fraction)),
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: v,
                    minHeight: 8,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    valueColor: const AlwaysStoppedAnimation(CmColors.orange),
                  ),
                ),
              ),
              if (p != null && p.totalSteps > 1) ...[
                const SizedBox(height: 8),
                Text(
                  'Étape ${math.min(p.step + 1, p.totalSteps)} sur ${p.totalSteps}',
                  style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w700),
                ),
              ],
              const Spacer(),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                child: Row(
                  key: ValueKey(_tip),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lightbulb_outline, color: CmColors.amber, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _tips[_tip],
                        style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: CmSpacing.lg),
              if (widget.onCancel != null)
                TextButton.icon(
                  onPressed: widget.onCancel,
                  icon: const Icon(Icons.close, color: Colors.white70),
                  label: const Text('Annuler', style: TextStyle(color: Colors.white70)),
                ),
              const SizedBox(height: CmSpacing.md),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindingRoadPainter extends CustomPainter {
  _WindingRoadPainter(this.t);

  final double t;

  Path _road(Size s) {
    final w = s.width, h = s.height;
    return Path()
      ..moveTo(w * 0.08, h * 0.92)
      ..cubicTo(w * 0.05, h * 0.62, w * 0.42, h * 0.78, w * 0.46, h * 0.56)
      ..cubicTo(w * 0.50, h * 0.34, w * 0.14, h * 0.40, w * 0.22, h * 0.20)
      ..cubicTo(w * 0.30, h * 0.02, w * 0.70, h * 0.22, w * 0.66, h * 0.42)
      ..cubicTo(w * 0.62, h * 0.62, w * 0.94, h * 0.58, w * 0.92, h * 0.10);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _road(size);
    final metric = path.computeMetrics().first;
    final len = metric.length;

    // Lueur sous la route.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 46
        ..strokeCap = StrokeCap.round
        ..color = CmColors.orange.withValues(alpha: 0.06)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    // Accotements puis bitume.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 34
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = CmColors.asphalt500,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 29
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = CmColors.asphalt700,
    );
    // Ligne médiane qui défile.
    const dash = 14.0, gap = 12.0;
    final shift = (t * (dash + gap) * 6) % (dash + gap);
    final center = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.55);
    for (var d = -shift; d < len; d += dash + gap) {
      final a = math.max(0.0, d), b = math.min(len, d + dash);
      if (b > a) canvas.drawPath(metric.extractPath(a, b), center);
    }

    // Trace orange derrière la moto.
    final pos = Curves.easeInOutSine.transform(t) * len;
    final tail = math.max(0.0, pos - len * 0.35);
    final trail = metric.extractPath(tail, pos);
    final tailStart = metric.getTangentForOffset(tail)?.position ?? Offset.zero;
    final tangent = metric.getTangentForOffset(pos);
    if (tangent != null) {
      canvas.drawPath(
        trail,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(tailStart, tangent.position, [
            CmColors.orange.withValues(alpha: 0),
            CmColors.orange,
          ]),
      );
      // Moto : point lumineux + phare.
      final p = tangent.position;
      canvas.drawCircle(
        p,
        18,
        Paint()
          ..color = CmColors.orange.withValues(alpha: 0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
      final dir = tangent.vector;
      final beam = Path()
        ..moveTo(p.dx, p.dy)
        ..lineTo(p.dx + dir.dx * 42 - dir.dy * 14, p.dy + dir.dy * 42 + dir.dx * 14)
        ..lineTo(p.dx + dir.dx * 42 + dir.dy * 14, p.dy + dir.dy * 42 - dir.dx * 14)
        ..close();
      canvas.drawPath(
        beam,
        Paint()
          ..shader = ui.Gradient.linear(p, p + dir * 42, [
            const Color(0xFFFFF3C4).withValues(alpha: 0.55),
            const Color(0xFFFFF3C4).withValues(alpha: 0),
          ]),
      );
      canvas.drawCircle(p, 7, Paint()..color = Colors.white);
      canvas.drawCircle(p, 4.5, Paint()..color = CmColors.orange);
    }

    // Drapeaux départ / arrivée.
    final start = metric.getTangentForOffset(0)!.position;
    final end = metric.getTangentForOffset(len)!.position;
    canvas.drawCircle(start, 6, Paint()..color = CmColors.green);
    canvas.drawCircle(end, 6, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _WindingRoadPainter old) => old.t != t;
}
