import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/planned_route.dart';
import '../social/social_providers.dart';
import 'generate_route_screen.dart';
import 'route_actions.dart';
import 'route_detail_screen.dart';
import 'route_ui.dart';
import 'routes_providers.dart';

/// Onglet « Balades » : générer, retrouver ses balades, celles des potes, GPX.
class RoutesHomeScreen extends ConsumerWidget {
  const RoutesHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final saved = ref.watch(savedRoutesProvider);
    final friends = ref.watch(friendsRoutesProvider);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.lg, CmSpacing.lg, 0),
              sliver: SliverToBoxAdapter(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Balades', style: text.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
                          Text(
                            'Où on va rouler aujourd\'hui ?',
                            style: text.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Importer un GPX',
                      onPressed: () => importGpxFlow(context, ref),
                      icon: const Icon(Icons.file_upload_outlined),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.lg, CmSpacing.lg, 0),
              sliver: SliverToBoxAdapter(
                child: _GenerateHeroCard(
                  onOpen: (style) => Navigator.of(context).push(GenerateRouteScreen.pageRoute(style: style)),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.md, CmSpacing.lg, 0),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: _QuickAction(
                        icon: Icons.alt_route,
                        title: "D'un point A à B",
                        subtitle: 'Par les jolies routes',
                        color: CmColors.teal,
                        onTap: () => Navigator.of(context).push(GenerateRouteScreen.pageRoute(loop: false)),
                      ),
                    ),
                    const SizedBox(width: CmSpacing.sm),
                    Expanded(
                      child: _QuickAction(
                        icon: Icons.upload_file,
                        title: 'Importer un GPX',
                        subtitle: 'Trace ou itinéraire',
                        color: CmColors.sky,
                        onTap: () => importGpxFlow(context, ref),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SectionHeader(
                'Mes balades à faire',
                action: saved.value == null || saved.value!.isEmpty
                    ? null
                    : Text('${saved.value!.length}', style: CmTheme.numbers(size: 22, color: scheme.onSurfaceVariant)),
              ),
            ),
            ...saved.when(
              loading: () => [
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(CmSpacing.xl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              ],
              error: (e, _) => [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
                    child: Text('Impossible de lire tes balades : $e'),
                  ),
                ),
              ],
              data: (routes) => routes.isEmpty
                  ? [const SliverToBoxAdapter(child: _NoRoutesCard())]
                  : [
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
                        sliver: SliverList.separated(
                          itemCount: routes.length,
                          separatorBuilder: (_, _) => const SizedBox(height: CmSpacing.sm),
                          itemBuilder: (context, i) {
                            final r = routes[i];
                            return RouteListCard(
                              route: r,
                              subtitle: r.author,
                              onTap: () => Navigator.of(context).push(RouteDetailScreen.pageRoute(r)),
                              onFavorite: () =>
                                  ref.read(routeRepositoryProvider).upsert(r.copyWith(favorite: !r.favorite)),
                            );
                          },
                        ),
                      ),
                    ],
            ),
            const SliverToBoxAdapter(child: SectionHeader('Proposées par les potes')),
            SliverToBoxAdapter(
              child: friends.when(
                loading: () => const SizedBox(height: 80, child: Center(child: CircularProgressIndicator())),
                error: (_, _) => const _FriendsEmpty(),
                data: (list) => list.isEmpty
                    ? const _FriendsEmpty()
                    : SizedBox(
                        height: 214,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
                          scrollDirection: Axis.horizontal,
                          itemCount: list.length,
                          separatorBuilder: (_, _) => const SizedBox(width: CmSpacing.sm),
                          itemBuilder: (context, i) => _FriendRouteCard(
                            route: list[i],
                            onTap: () => Navigator.of(context).push(RouteDetailScreen.pageRoute(list[i])),
                          ),
                        ),
                      ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }
}

/// Grande carte orange « Générer une balade » avec raccourcis de style.
class _GenerateHeroCard extends StatelessWidget {
  const _GenerateHeroCard({required this.onOpen});

  final void Function(RouteStyle? style) onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF8A3D), CmColors.orange, CmColors.orangeDeep],
        ),
        boxShadow: [
          BoxShadow(color: CmColors.orange.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 10)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () => onOpen(null),
            child: Stack(
              children: [
                const Positioned.fill(child: CustomPaint(painter: _CurvyLinesPainter())),
                Padding(
                  padding: const EdgeInsets.fromLTRB(CmSpacing.xl, CmSpacing.xl, CmSpacing.lg, CmSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(Icons.auto_awesome, color: Colors.white),
                          ),
                          const Spacer(),
                          Container(
                            width: 44,
                            height: 44,
                            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                            child: const Icon(Icons.arrow_forward, color: CmColors.orangeDeep),
                          ),
                        ],
                      ),
                      const SizedBox(height: CmSpacing.lg),
                      Text(
                        'Générer une balade',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800, height: 1.0),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Virolos, forêts, cols… dis-nous ce qui te fait envie, on trace.',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: CmSpacing.lg),
                      SizedBox(
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final s in RouteStyle.values)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Material(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  shape: const StadiumBorder(),
                                  child: InkWell(
                                    customBorder: const StadiumBorder(),
                                    onTap: () => onOpen(s),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      child: Row(
                                        children: [
                                          Icon(s.icon, size: 16, color: Colors.white),
                                          const SizedBox(width: 6),
                                          Text(
                                            s.label,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
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

/// Lignes sinueuses décoratives (courbes de niveau / routes).
class _CurvyLinesPainter extends CustomPainter {
  const _CurvyLinesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = Colors.white.withValues(alpha: 0.12);
    for (var k = 0; k < 6; k++) {
      final path = Path();
      final y0 = size.height * (0.1 + k * 0.17);
      for (var x = 0.0; x <= size.width; x += 6) {
        final y = y0 + math.sin(x / size.width * math.pi * 2.4 + k * 0.9) * 16 + math.sin(x / 37 + k) * 3;
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(CmSpacing.md),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoRoutesCard extends StatelessWidget {
  const _NoRoutesCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
      child: Container(
        padding: const EdgeInsets.all(CmSpacing.xl),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(CmSpacing.radius),
          border: Border.all(color: scheme.outlineVariant, width: 1.5),
        ),
        child: Column(
          children: [
            const Icon(Icons.route, color: CmColors.orange, size: 40),
            const SizedBox(height: CmSpacing.sm),
            const Text('Aucune balade en stock', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 4),
            Text(
              'Génère une balade ou importe un GPX : elle t\'attendra ici pour le prochain départ.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendsEmpty extends StatelessWidget {
  const _FriendsEmpty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
      child: Row(
        children: [
          Icon(Icons.groups_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Quand tes potes partageront leurs balades, elles apparaîtront ici.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _FriendRouteCard extends StatelessWidget {
  const _FriendRouteCard({required this.route, required this.onTap});

  final PlannedRoute route;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = styleColor(route.style);
    return SizedBox(
      width: 240,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 110,
                width: double.infinity,
                color: scheme.surfaceContainerHigh,
                padding: const EdgeInsets.all(10),
                child: RouteShape(points: previewPoints(route), color: color),
              ),
              Padding(
                padding: const EdgeInsets.all(CmSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      route.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          '${(route.distanceM / 1000).round()} km',
                          style: CmTheme.numbers(size: 20, color: scheme.onSurface),
                        ),
                        const SizedBox(width: 8),
                        if (route.author != null)
                          Expanded(
                            child: Text(
                              'par ${route.author}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
