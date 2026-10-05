import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/geo.dart';
import '../../../core/theme.dart';
import '../../../core/ui/widgets.dart';
import '../../routes/route_detail_screen.dart';
import '../social_models.dart';
import '../social_providers.dart';
import 'social_widgets.dart';

/// Carte du fil « Dernières balades des potes ».
class FeedCard extends StatelessWidget {
  const FeedCard({super.key, required this.item});

  final FeedItem item;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      FeedRoute(:final entry) => _RouteCard(entry: entry),
      FeedRide(:final ride) => _RideCard(ride: ride),
    };
  }
}

class _FeedFrame extends StatelessWidget {
  const _FeedFrame({
    required this.authorName,
    required this.authorColor,
    required this.action,
    required this.when,
    required this.points,
    required this.lineColor,
    required this.title,
    required this.stats,
    this.badge,
    this.onTap,
  });

  final String authorName;
  final Color authorColor;
  final String action;
  final DateTime when;
  final List<GeoPoint> points;
  final Color lineColor;
  final String title;
  final List<Widget> stats;
  final Widget? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SocialCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.md, CmSpacing.lg, CmSpacing.sm),
            child: Row(
              children: [
                RiderAvatar(name: authorName, color: authorColor, size: 32),
                const SizedBox(width: CmSpacing.sm),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: authorName, style: const TextStyle(fontWeight: FontWeight.w800)),
                      TextSpan(text: ' $action'),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(Fmt.ago(when), style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          Container(
            height: 132,
            margin: const EdgeInsets.symmetric(horizontal: CmSpacing.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [CmColors.asphalt700, CmColors.asphalt800.withValues(alpha: 0.9)],
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _GridPainter(Colors.white.withValues(alpha: 0.04))),
                ),
                if (points.length >= 2)
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(CmSpacing.sm),
                      child: RouteShape(points: points, color: lineColor, strokeWidth: 3),
                    ),
                  )
                else
                  const Center(child: Icon(Icons.route_rounded, color: Colors.white24, size: 40)),
                if (badge != null) Positioned(left: 10, top: 10, child: badge!),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.md, CmSpacing.lg, CmSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: CmSpacing.sm),
                Wrap(spacing: 6, runSpacing: 6, children: stats),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (var y = 0.0; y < size.height; y += 22) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.color != color;
}

class _RouteCard extends ConsumerWidget {
  const _RouteCard({required this.entry});

  final SharedRouteEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = entry.route;
    final author = ref.watch(friendNamesProvider.select((m) => m[entry.authorUid]));
    return _FeedFrame(
      authorName: r.author ?? 'Un pote',
      authorColor: Color(author?.colorValue ?? defaultColorFor(entry.authorUid)),
      action: 'propose une balade',
      when: entry.sharedAt,
      points: r.points.length > 400 ? _thin(r.points, 400) : r.points,
      lineColor: CmColors.orange,
      title: r.name,
      badge: const SocialPill(label: 'À FAIRE', icon: Icons.explore_rounded, color: CmColors.orange),
      onTap: () => Navigator.of(context).push(RouteDetailScreen.pageRoute(r)),
      stats: [
        SocialPill(label: Fmt.distance(r.distanceM), icon: Icons.straighten_rounded, color: CmColors.sky),
        if (r.durationS > 0) SocialPill(label: Fmt.durationS(r.durationS), icon: Icons.schedule_rounded, color: CmColors.teal),
        SocialPill(label: r.style.label, icon: r.style.icon, color: CmColors.amber),
        if (r.curvatureScore >= 1)
          SocialPill(label: 'Sinuosité ${r.curvatureScore.round()}', icon: Icons.turn_sharp_right, color: CmColors.orange),
      ],
    );
  }
}

class _RideCard extends StatelessWidget {
  const _RideCard({required this.ride});

  final FriendRide ride;

  @override
  Widget build(BuildContext context) {
    final r = ride;
    return _FeedFrame(
      authorName: r.authorName,
      authorColor: r.authorColor,
      action: 'a roulé',
      when: r.sharedAt,
      points: r.previewPoints,
      lineColor: r.authorColor,
      title: r.name,
      badge: SocialPill(label: Fmt.date(r.startedAt).toUpperCase(), icon: Icons.two_wheeler, color: r.authorColor),
      onTap: () => _showRide(context, r),
      stats: [
        SocialPill(label: Fmt.distance(r.distanceM), icon: Icons.straighten_rounded, color: CmColors.sky),
        if (r.movingTimeS > 0) SocialPill(label: Fmt.durationS(r.movingTimeS), icon: Icons.schedule_rounded, color: CmColors.teal),
        if (r.maxSpeedKmh > 0) SocialPill(label: 'Max ${Fmt.speed(r.maxSpeedKmh)}', icon: Icons.speed_rounded, color: CmColors.amber),
        if (r.maxLeanDeg >= 5) SocialPill(label: '${r.maxLeanDeg.round()}° d\'angle', icon: Icons.screen_rotation_alt_rounded, color: CmColors.forLean(r.maxLeanDeg)),
      ],
    );
  }

  static void _showRide(BuildContext context, FriendRide r) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(CmSpacing.xl, 0, CmSpacing.xl, CmSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  RiderAvatar(name: r.authorName, color: r.authorColor, size: 48),
                  const SizedBox(width: CmSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.name, style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                        Text('${r.authorName} · ${Fmt.dateLong(r.startedAt)}',
                            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: CmSpacing.lg),
              Container(
                height: 220,
                decoration: BoxDecoration(color: CmColors.asphalt700, borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.all(CmSpacing.md),
                child: r.previewPoints.length >= 2
                    ? RouteShape(points: r.previewPoints, color: r.authorColor, strokeWidth: 4)
                    : const Center(child: Icon(Icons.route_rounded, color: Colors.white24, size: 48)),
              ),
              const SizedBox(height: CmSpacing.lg),
              StatGrid(
                children: [
                  StatTile(label: 'Distance', value: Fmt.km(r.distanceM), unit: 'km', icon: Icons.straighten_rounded),
                  StatTile(label: 'Durée', value: Fmt.durationS(r.movingTimeS), icon: Icons.schedule_rounded),
                  StatTile(label: 'Moyenne', value: Fmt.number(r.avgSpeedKmh), unit: 'km/h', icon: Icons.av_timer_rounded),
                  StatTile(label: 'Vitesse max', value: Fmt.number(r.maxSpeedKmh), unit: 'km/h', icon: Icons.speed_rounded),
                  StatTile(
                    label: 'Angle max',
                    value: r.maxLeanDeg.round().toString(),
                    unit: '°',
                    icon: Icons.screen_rotation_alt_rounded,
                    color: CmColors.forLean(r.maxLeanDeg),
                  ),
                  StatTile(label: 'Dénivelé +', value: Fmt.number(r.elevationGainM), unit: 'm', icon: Icons.terrain_rounded),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<T> _thin<T>(List<T> pts, int max) {
  if (pts.length <= max) return pts;
  final step = pts.length / max;
  return [for (var i = 0.0; i < pts.length; i += step) pts[i.floor()], pts.last];
}
