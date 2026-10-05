import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../services/routing/guidance_engine.dart';
import '../../services/routing/maneuver_kinds.dart';
import 'guidance_controller.dart';
import 'route_ui.dart';

/// Bandeau « prochaine manœuvre » affiché pendant une balade qui suit un
/// itinéraire (activeRouteProvider). Ne rend rien s'il n'y a pas d'itinéraire.
///
/// Le monter suffit à faire tourner le guidage (annonces vocales comprises).
class GuidanceBanner extends ConsumerWidget {
  const GuidanceBanner({super.key, this.margin = EdgeInsets.zero});

  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(guidanceProvider);
    if (g == null) return const SizedBox.shrink();
    final snap = g.snapshot;

    final Widget content;
    final String key;
    if (snap == null) {
      key = 'wait';
      content = _WaitingPanel(name: g.route.name);
    } else if (snap.arrived) {
      key = 'arrived';
      content = _ArrivedPanel(name: g.route.name);
    } else if (snap.offRoute) {
      key = 'off';
      content = _OffRoutePanel(state: g, snapshot: snap);
    } else {
      key = 'next-${snap.nextIndex}';
      content = _NextManeuverPanel(snapshot: snap);
    }

    return Padding(
      padding: margin,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, -0.08), end: Offset.zero).animate(anim),
                child: child,
              ),
            ),
            child: KeyedSubtree(key: ValueKey(key), child: content),
          ),
          if (g.error != null) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: ref.read(guidanceProvider.notifier).dismissError,
              child: GlassPanel(
                color: CmColors.red.withValues(alpha: 0.9),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                radius: 14,
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        g.error!,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const Icon(Icons.close, color: Colors.white70, size: 18),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NextManeuverPanel extends StatelessWidget {
  const _NextManeuverPanel({required this.snapshot});

  final GuidanceSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final next = snapshot.next;
    final dist = snapshot.distanceToNextM ?? 0;
    final soon = dist < 150;
    final following = snapshot.following;
    final showThen =
        following != null &&
        next != null &&
        following.distanceAlongM - next.distanceAlongM < 300 &&
        following.type != ManeuverKind.roundaboutExit;
    final street = next?.streetName;

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
      radius: 24,
      color: CmColors.asphalt800.withValues(alpha: 0.92),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: soon
                        ? const [CmColors.amber, CmColors.orangeDeep]
                        : const [CmColors.orange, CmColors.orangeDeep],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: CmColors.orange.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(next == null ? Icons.straight : maneuverIcon(next.type), color: Colors.white, size: 46),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      next == null ? '—' : guidanceDistance(dist),
                      style: CmTheme.numbers(size: 44, color: Colors.white),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      next?.instruction ?? 'Suis la route',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (street != null && !(next?.instruction.contains(street) ?? false)) ...[
                      const SizedBox(height: 2),
                      Text(
                        street,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (showThen) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'puis',
                        style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 6),
                      Icon(maneuverIcon(following.type), color: Colors.white, size: 18),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              const Icon(Icons.flag_outlined, color: Colors.white54, size: 16),
              const SizedBox(width: 4),
              Text(
                'Reste ${Fmt.distance(snapshot.remainingM)}',
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: snapshot.totalM <= 0 ? 0 : (snapshot.progressM / snapshot.totalM).clamp(0, 1),
              minHeight: 4,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: const AlwaysStoppedAnimation(CmColors.orange),
            ),
          ),
        ],
      ),
    );
  }
}

class _OffRoutePanel extends ConsumerWidget {
  const _OffRoutePanel({required this.state, required this.snapshot});

  final GuidanceState state;
  final GuidanceSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(colors: [CmColors.orange, CmColors.orangeDeep]),
        boxShadow: [
          BoxShadow(color: CmColors.orange.withValues(alpha: 0.4), blurRadius: 18, offset: const Offset(0, 6)),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.wrong_location, color: Colors.white, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Hors itinéraire',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
                ),
                Text(
                  'Tu es à ${guidanceDistance(snapshot.distanceFromRouteM)} du tracé',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: CmColors.orangeDeep,
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            onPressed: state.recalculating ? null : ref.read(guidanceProvider.notifier).recalculate,
            icon: state.recalculating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: CmColors.orangeDeep),
                  )
                : const Icon(Icons.alt_route),
            label: Text(state.recalculating ? 'Calcul…' : 'Recalculer'),
          ),
        ],
      ),
    );
  }
}

class _ArrivedPanel extends StatelessWidget {
  const _ArrivedPanel({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(colors: [Color(0xFF16A34A), CmColors.green]),
      ),
      child: Row(
        children: [
          const Icon(Icons.sports_score, color: Colors.white, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Arrivé, bien roulé !',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
                ),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WaitingPanel extends StatelessWidget {
  const _WaitingPanel({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 20,
      color: CmColors.asphalt800.withValues(alpha: 0.92),
      child: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: CmColors.orange),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Guidage « $name » : en attente du GPS…',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
