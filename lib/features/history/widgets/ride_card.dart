import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/ui/widgets.dart';
import '../../../data/models/ride.dart';

/// « samedi 4 octobre 2026 » avec majuscule.
String capitalizeFirst(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Carte d'une balade dans l'historique.
class RideCard extends StatelessWidget {
  const RideCard({super.key, required this.ride, required this.onTap});

  final Ride ride;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final s = ride.stats;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final points = ride.previewPoints;
    final lean = s.maxLeanDeg;
    final day = DateFormat('EEE d MMM', 'fr_FR').format(ride.startedAt.toLocal());

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(CmSpacing.radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(CmSpacing.md),
          child: Row(
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: isDark ? CmColors.asphalt900 : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.all(6),
                child: points.length >= 2
                    ? RouteShape(points: points, strokeWidth: 2.4)
                    : Icon(Icons.route_rounded, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: CmSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ride.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      '${capitalizeFirst(day)} · ${Fmt.time(ride.startedAt)}',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(Fmt.km(s.distanceM), style: CmTheme.numbers(size: 26)),
                        const SizedBox(width: 3),
                        Text(
                          'km',
                          style: CmTheme.numbers(size: 14, weight: FontWeight.w600, color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(width: CmSpacing.md),
                        Flexible(
                          child: Text(
                            [
                              Fmt.durationS(s.movingTimeS > 0 ? s.movingTimeS : s.totalTimeS),
                              if (s.avgMovingSpeedKmh > 0) '${Fmt.number(s.avgMovingSpeedKmh)} km/h moy',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
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
                        if (lean > 0)
                          Pill(
                            label: '${lean.round()}° max',
                            icon: Icons.u_turn_right_rounded,
                            color: CmColors.forLean(lean),
                          ),
                        if (s.elevationGainM >= 100)
                          Pill(
                            label: '${Fmt.number(s.elevationGainM)} m D+',
                            icon: Icons.landscape_rounded,
                            color: CmColors.sky,
                          ),
                        if (ride.sharedWithFriends)
                          const Pill(label: 'Partagée', icon: Icons.groups_rounded, color: CmColors.teal),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
