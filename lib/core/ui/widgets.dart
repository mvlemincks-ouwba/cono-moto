import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../geo.dart';
import '../theme.dart';

/// Tuile de statistique : grand chiffre + unité + libellé.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.icon,
    this.color,
    this.compact = false,
  });

  final String label;
  final String value;
  final String? unit;
  final IconData? icon;
  final Color? color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.onSurface;
    return Container(
      padding: EdgeInsets.all(compact ? CmSpacing.md : CmSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(CmSpacing.radiusSm + 4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: color ?? scheme.onSurfaceVariant),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 4 : 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, style: CmTheme.numbers(size: compact ? 26 : 34, color: accent)),
                if (unit != null) ...[
                  const SizedBox(width: 4),
                  Text(
                    unit!,
                    style: CmTheme.numbers(
                      size: compact ? 14 : 16,
                      weight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
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

/// Grille responsive de [StatTile].
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.children, this.columns = 2, this.compact = false});

  final List<Widget> children;
  final int columns;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const gap = CmSpacing.sm;
      final w = (c.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final child in children) SizedBox(width: w, child: child)],
      );
    });
  }
}

/// En-tête de section.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.padding});

  final String title;
  final Widget? action;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.xl, CmSpacing.lg, CmSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// État vide illustré.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(CmSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: CmColors.orange.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 42, color: CmColors.orange),
            ),
            const SizedBox(height: CmSpacing.lg),
            Text(title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            if (message != null) ...[
              const SizedBox(height: CmSpacing.sm),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: CmSpacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Panneau semi-transparent flouté, à poser au-dessus de la carte.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(CmSpacing.md),
    this.radius = CmSpacing.radius,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color ??
                (isDark ? CmColors.asphalt800.withValues(alpha: 0.82) : Colors.white.withValues(alpha: 0.86)),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.05),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Bouton rond flottant pour la carte.
class MapRoundButton extends StatelessWidget {
  const MapRoundButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.active = false,
    this.size = 48,
    this.badge,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool active;
  final double size;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = GlassPanel(
      padding: EdgeInsets.zero,
      radius: size / 2,
      color: active ? CmColors.orange : null,
      child: SizedBox(
        width: size,
        height: size,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, color: active ? Colors.white : scheme.onSurface),
          tooltip: tooltip,
        ),
      ),
    );
    if (badge == null) return button;
    return Badge(label: Text(badge!), child: button);
  }
}

/// Petit badge arrondi coloré (ex : « Sinueux », « 3 potes en ligne »).
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, this.icon, this.color});

  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? CmColors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: c, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// Dessin vectoriel d'un tracé (aperçu léger sans charger de carte).
class RouteShape extends StatelessWidget {
  const RouteShape({
    super.key,
    required this.points,
    this.color = CmColors.orange,
    this.strokeWidth = 3,
    this.showEnds = true,
  });

  final List<GeoPoint> points;
  final Color color;
  final double strokeWidth;
  final bool showEnds;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _RouteShapePainter(points, color, strokeWidth, showEnds,
          Theme.of(context).colorScheme.onSurface),
      size: Size.infinite,
    );
  }
}

class _RouteShapePainter extends CustomPainter {
  _RouteShapePainter(this.points, this.color, this.strokeWidth, this.showEnds, this.endColor);

  final List<GeoPoint> points;
  final Color color;
  final double strokeWidth;
  final bool showEnds;
  final Color endColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final b = GeoBounds.fromPoints(points)!;
    final cosLat = math.cos(b.center.lat * math.pi / 180);
    final w = math.max((b.east - b.west) * cosLat, 1e-9);
    final h = math.max(b.north - b.south, 1e-9);
    final pad = strokeWidth * 3;
    final scale = math.min((size.width - pad * 2) / w, (size.height - pad * 2) / h);
    final ox = (size.width - w * scale) / 2;
    final oy = (size.height - h * scale) / 2;
    Offset map(GeoPoint p) =>
        Offset(ox + (p.lng - b.west) * cosLat * scale, oy + (b.north - p.lat) * scale);

    final path = Path()..moveTo(map(points.first).dx, map(points.first).dy);
    for (final p in points.skip(1)) {
      final o = map(p);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (showEnds) {
      canvas.drawCircle(map(points.first), strokeWidth * 1.6, Paint()..color = CmColors.green);
      canvas.drawCircle(map(points.last), strokeWidth * 1.6, Paint()..color = endColor);
    }
  }

  @override
  bool shouldRepaint(covariant _RouteShapePainter old) =>
      old.points != points || old.color != color || old.strokeWidth != strokeWidth;
}

/// Affiche un message d'erreur court.
void showCmSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? CmColors.red : null,
    ));
}
