import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/planned_route.dart';
import '../../services/routing/maneuver_kinds.dart';
import '../../services/routing/route_scoring.dart';
import '../../services/routing/weather_service.dart';

/// Tests de widgets uniquement : remplace les cartes MapLibre (vues natives,
/// absentes des tests) par un simple fond.
bool debugDisableRouteMaps = false;

/// Couleur associée à chaque type de balade.
Color styleColor(RouteStyle s) => switch (s) {
  RouteStyle.sinueux => CmColors.orange,
  RouteStyle.foret => CmColors.green,
  RouteStyle.cols => CmColors.sky,
  RouteStyle.plat => CmColors.teal,
  RouteStyle.rapide => CmColors.red,
  RouteStyle.mixte => CmColors.amber,
};

/// Couleurs des propositions sur la carte.
const candidateColors = [CmColors.orange, CmColors.teal, CmColors.sky, CmColors.amber];

/// Icône Material d'une manœuvre.
IconData maneuverIcon(String kind) => switch (kind) {
  ManeuverKind.depart => Icons.navigation,
  ManeuverKind.arrive => Icons.sports_score,
  ManeuverKind.waypoint => Icons.flag_outlined,
  ManeuverKind.slightRight => Icons.turn_slight_right,
  ManeuverKind.right => Icons.turn_right,
  ManeuverKind.sharpRight => Icons.turn_sharp_right,
  ManeuverKind.uturnRight => Icons.u_turn_right,
  ManeuverKind.uturnLeft => Icons.u_turn_left,
  ManeuverKind.sharpLeft => Icons.turn_sharp_left,
  ManeuverKind.left => Icons.turn_left,
  ManeuverKind.slightLeft => Icons.turn_slight_left,
  ManeuverKind.rampRight || ManeuverKind.exitRight => Icons.ramp_right,
  ManeuverKind.rampLeft || ManeuverKind.exitLeft => Icons.ramp_left,
  ManeuverKind.stayRight => Icons.fork_right,
  ManeuverKind.stayLeft => Icons.fork_left,
  ManeuverKind.merge || ManeuverKind.mergeLeft || ManeuverKind.mergeRight => Icons.merge,
  ManeuverKind.roundabout || ManeuverKind.roundaboutExit => Icons.roundabout_right,
  ManeuverKind.ferry || ManeuverKind.ferryExit => Icons.directions_boat,
  _ => Icons.straight,
};

(IconData, Color) badgeVisual(BadgeKind k) => switch (k) {
  BadgeKind.curvy => (Icons.gesture, CmColors.orange),
  BadgeKind.straight => (Icons.straight, CmColors.sky),
  BadgeKind.climb => (Icons.landscape, CmColors.amber),
  BadgeKind.flat => (Icons.waves, CmColors.teal),
  BadgeKind.fast => (Icons.speed, CmColors.red),
  BadgeKind.calm => (Icons.spa, CmColors.green),
  BadgeKind.forest => (Icons.forest, CmColors.green),
  BadgeKind.pass => (Icons.terrain, CmColors.sky),
  BadgeKind.highway => (Icons.add_road, CmColors.amber),
};

IconData weatherIcon(int? code) => switch (WeatherCodes.kind(code)) {
  WeatherKind.clear => Icons.wb_sunny,
  WeatherKind.partly => Icons.filter_drama,
  WeatherKind.cloudy => Icons.cloud,
  WeatherKind.fog => Icons.foggy,
  WeatherKind.drizzle => Icons.grain,
  WeatherKind.rain || WeatherKind.showers => Icons.water_drop,
  WeatherKind.snow => Icons.ac_unit,
  WeatherKind.storm => Icons.thunderstorm,
  WeatherKind.unknown => Icons.cloud_outlined,
};

Color weatherColor(int? code) => switch (WeatherCodes.kind(code)) {
  WeatherKind.clear => CmColors.amber,
  WeatherKind.partly => const Color(0xFFFFD27A),
  WeatherKind.cloudy || WeatherKind.fog || WeatherKind.unknown => const Color(0xFF9AA4B2),
  WeatherKind.drizzle || WeatherKind.rain || WeatherKind.showers => CmColors.sky,
  WeatherKind.snow => Colors.white,
  WeatherKind.storm => const Color(0xFFA78BFA),
};

/// Distance pour le guidage : arrondie à 10 m, puis en km.
String guidanceDistance(double m) {
  if (m < 1000) return '${(m / 10).round() * 10} m';
  return Fmt.distance(m);
}

/// Points allégés pour les aperçus (mis en cache par balade).
final _previewCache = <String, List<GeoPoint>>{};

List<GeoPoint> previewPoints(PlannedRoute r) {
  final key = '${r.id}:${r.points.length}';
  final hit = _previewCache[key];
  if (hit != null) return hit;
  final tol = math.max(15.0, r.distanceM / 2000);
  final pts = r.points.length > 400 ? Geo.simplify(r.points, tol) : r.points;
  if (_previewCache.length > 200) _previewCache.clear();
  return _previewCache[key] = pts;
}

/// Pastille du type de balade.
class StylePill extends StatelessWidget {
  const StylePill(this.style, {super.key});

  final RouteStyle style;

  @override
  Widget build(BuildContext context) => Pill(label: style.label, icon: style.icon, color: styleColor(style));
}

/// Badges d'une balade.
class BadgeWrap extends StatelessWidget {
  const BadgeWrap(this.badges, {super.key});

  final List<RouteBadge> badges;

  @override
  Widget build(BuildContext context) {
    if (badges.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final b in badges)
          () {
            final (icon, color) = badgeVisual(b.kind);
            return Pill(label: b.label, icon: icon, color: color);
          }(),
      ],
    );
  }
}

/// Note ronde 0–100.
class ScoreRing extends StatelessWidget {
  const ScoreRing({super.key, required this.score, this.color = CmColors.orange, this.size = 58, this.label = 'MATCH'});

  final double score;
  final Color color;
  final double size;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: score.clamp(0, 100) / 100),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => CustomPaint(
          painter: _RingPainter(v, color, scheme.surfaceContainerHighest),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${(v * 100).round()}',
                  style: CmTheme.numbers(size: size * 0.36, color: scheme.onSurface),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: size * 0.12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track);

  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.09;
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    canvas.drawArc(
      r,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    canvas.drawArc(
      r,
      -math.pi / 2,
      math.pi * 2 * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: -math.pi / 2,
          endAngle: math.pi * 1.5,
          colors: [color.withValues(alpha: 0.6), color],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.value != value || old.color != color;
}

/// Carte d'une balade dans les listes (aperçu du tracé + chiffres clés).
class RouteListCard extends StatelessWidget {
  const RouteListCard({super.key, required this.route, this.onTap, this.onFavorite, this.subtitle});

  final PlannedRoute route;
  final VoidCallback? onTap;
  final VoidCallback? onFavorite;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = styleColor(route.style);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(CmSpacing.md),
          child: Row(
            children: [
              Container(
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [scheme.surfaceContainerHighest, scheme.surfaceContainerHigh],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: RouteShape(points: previewPoints(route), color: color, strokeWidth: 2.4),
                ),
              ),
              const SizedBox(width: CmSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      route.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          Fmt.km(route.distanceM, decimals: 0),
                          style: CmTheme.numbers(size: 26, color: scheme.onSurface),
                        ),
                        const SizedBox(width: 2),
                        Text('km', style: CmTheme.numbers(size: 14, color: scheme.onSurfaceVariant)),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            [
                              if (route.durationS > 0) Fmt.durationS(route.durationS),
                              if (route.elevationGainM > 0) '+${RouteScoring.formatMeters(route.elevationGainM)} m',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        StylePill(route.style),
                        if (route.source == RouteSource.gpx)
                          const Pill(label: 'GPX', icon: Icons.upload_file, color: CmColors.sky),
                        if (subtitle != null) Pill(label: subtitle!, icon: Icons.person_outline, color: CmColors.teal),
                      ],
                    ),
                  ],
                ),
              ),
              if (onFavorite != null)
                IconButton(
                  onPressed: onFavorite,
                  tooltip: route.favorite ? 'Retirer des favoris' : 'Mettre en favori',
                  icon: Icon(
                    route.favorite ? Icons.star : Icons.star_border,
                    color: route.favorite ? CmColors.amber : scheme.onSurfaceVariant,
                  ),
                )
              else
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
