// Briques visuelles du plan de navigation : lisibles en roulant (très gros
// chiffres, contraste fort), boutons utilisables avec des gants.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models/planned_route.dart';
import '../../services/routing/guidance_engine.dart';
import '../../services/routing/maneuver_kinds.dart';
import '../garage/autonomy.dart';
import '../ride/ride_controller.dart';
import '../ride/widgets/lean_gauge.dart';
import '../routes/route_ui.dart';
import '../traffic/traffic_providers.dart' show IncidentAhead;
import 'navigation_logic.dart';

/// Fond des panneaux posés sur la carte.
const navPanelColor = Color(0xF5121519);

/// Gris de la partie déjà parcourue.
const navDoneColor = Color(0xFF7C8594);

List<BoxShadow> get _shadow => [
  BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 6)),
];

// =============================================================================
// Bandeau du haut : prochaine manœuvre
// =============================================================================

/// Grosse flèche + distance en très gros chiffres + rue, et « puis … ».
class NavManeuverBanner extends StatelessWidget {
  const NavManeuverBanner({super.key, required this.snapshot, this.compact = false});

  final GuidanceSnapshot snapshot;

  /// Version réduite (téléphone en paysage).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final next = snapshot.next;
    final dist = snapshot.distanceToNextM ?? snapshot.remainingM;
    final soon = next != null && dist < 150;
    final (value, unit) = maneuverDistanceParts(dist);
    final street = next?.streetName;
    final instruction = next?.instruction ?? 'Suis la route';
    final mainText = street ?? instruction;
    final exitNo = next != null && next.type == ManeuverKind.roundabout ? roundaboutExitNumber(next.instruction) : null;
    final then = snapshot.then;
    final arrow = compact ? 76.0 : 96.0;

    return Semantics(
      liveRegion: true,
      label: 'Dans $value $unit, $instruction',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(compact ? 10 : 12),
            decoration: BoxDecoration(
              color: navPanelColor,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: (soon ? CmColors.amber : CmColors.orange).withValues(alpha: 0.5), width: 2),
              boxShadow: _shadow,
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: arrow,
                  height: arrow,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: soon
                          ? const [CmColors.amber, CmColors.orange]
                          : const [CmColors.orange, CmColors.orangeDeep],
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        next == null ? Icons.straight_rounded : maneuverIcon(next.type),
                        color: Colors.white,
                        size: arrow * 0.72,
                      ),
                      if (exitNo != null)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                            child: Text(
                              '$exitNo',
                              style: CmTheme.numbers(size: 20, color: CmColors.orangeDeep, weight: FontWeight.w800),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              value,
                              style: CmTheme.numbers(
                                size: compact ? 52 : 68,
                                color: Colors.white,
                                weight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              unit,
                              style: CmTheme.numbers(size: compact ? 24 : 30, color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        mainText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: compact ? 18 : 22,
                          height: 1.15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (then != null)
            Container(
              margin: const EdgeInsets.only(left: 18),
              padding: const EdgeInsets.fromLTRB(14, 6, 16, 8),
              decoration: BoxDecoration(
                color: CmColors.asphalt600.withValues(alpha: 0.97),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'puis',
                    style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  Icon(maneuverIcon(then.type), color: Colors.white, size: 32),
                  if (then.streetName != null) ...[
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 170),
                      child: Text(
                        then.streetName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
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

/// Hors itinéraire : recalcul automatique en cours, bouton de secours.
class NavOffRouteBanner extends StatelessWidget {
  const NavOffRouteBanner({
    super.key,
    required this.distanceFromRouteM,
    required this.recalculating,
    required this.onRecalculate,
  });

  final double distanceFromRouteM;
  final bool recalculating;
  final VoidCallback onRecalculate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(colors: [CmColors.orange, CmColors.orangeDeep]),
        boxShadow: _shadow,
      ),
      child: Row(
        children: [
          recalculating
              ? const SizedBox.square(
                  dimension: 40,
                  child: CircularProgressIndicator(strokeWidth: 4, color: Colors.white),
                )
              : const Icon(Icons.wrong_location_rounded, color: Colors.white, size: 44),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  recalculating ? 'Recalcul de l\'itinéraire…' : 'Hors itinéraire',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, height: 1.1),
                ),
                const SizedBox(height: 2),
                Text(
                  'Tu es à ${navDistance(distanceFromRouteM)} du tracé',
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          if (!recalculating) ...[
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: CmColors.orangeDeep,
                minimumSize: const Size(0, 58),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              onPressed: onRecalculate,
              icon: const Icon(Icons.alt_route_rounded, size: 24),
              label: const Text('Recalculer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
          ],
        ],
      ),
    );
  }
}

/// En attendant le premier fix GPS.
class NavWaitingBanner extends StatelessWidget {
  const NavWaitingBanner({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: navPanelColor, borderRadius: BorderRadius.circular(24), boxShadow: _shadow),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(strokeWidth: 3, color: CmColors.orange),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              '$name · on attend le GPS…',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Alertes sous le bandeau
// =============================================================================

/// « Travaux dans 3,2 km ».
class NavIncidentBanner extends StatelessWidget {
  const NavIncidentBanner({super.key, required this.ahead});

  final IncidentAhead ahead;

  @override
  Widget build(BuildContext context) {
    final i = ahead.incident;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
      decoration: BoxDecoration(
        color: navPanelColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: i.kind.color, width: 2),
        boxShadow: _shadow,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: i.kind.color, shape: BoxShape.circle),
            child: Icon(i.kind.icon, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  incidentAheadText(ahead),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w900),
                ),
                if (i.roadName.isNotEmpty || i.description.isNotEmpty)
                  Text(
                    i.roadName.isNotEmpty ? i.roadName : i.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Autonomie basse : stations sur la route.
class NavFuelAlert extends StatelessWidget {
  const NavFuelAlert({super.key, required this.autonomy, required this.onStations, required this.onDismiss});

  final AutonomyInfo? autonomy;
  final VoidCallback onStations;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(color: CmColors.amber, borderRadius: BorderRadius.circular(20), boxShadow: _shadow),
      child: Row(
        children: [
          const Icon(Icons.local_gas_station_rounded, color: Colors.black, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Réserve !',
                  maxLines: 1,
                  style: TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.w900, height: 1.1),
                ),
                if (autonomy != null)
                  Text(
                    'encore ~${autonomy!.remainingKm.round()} km',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.black87, fontSize: 14, fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: CmColors.amber,
              minimumSize: const Size(0, 50),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: onStations,
            child: const Text('Stations'),
          ),
          IconButton(
            tooltip: 'Masquer',
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, color: Colors.black),
          ),
        ],
      ),
    );
  }
}

/// Petite pastille d'alerte (GPS perdu, erreur de recalcul, pote en SOS…).
class NavNotice extends StatelessWidget {
  const NavNotice({super.key, required this.icon, required this.text, required this.color, this.onTap});

  final IconData icon;
  final String text;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              if (onTap != null) const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Bas de l'écran
// =============================================================================

/// Bulle de vitesse façon GPS.
class NavSpeedBubble extends ConsumerWidget {
  const NavSpeedBubble({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(rideControllerProvider.select((s) => s.speedKmh));
    final hasFix = ref.watch(rideControllerProvider.select((s) => s.hasFix));
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    final text = !hasFix ? '--' : '${speed < 2 ? 0 : speed.round()}';
    return Semantics(
      label: 'Vitesse $text kilomètres heure',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: CmColors.asphalt900.withValues(alpha: 0.95),
          shape: BoxShape.circle,
          border: Border.all(color: paused ? CmColors.amber : Colors.white, width: 3.5),
          boxShadow: _shadow,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                text,
                style: CmTheme.numbers(size: size * 0.46, color: Colors.white, weight: FontWeight.w800),
              ),
            ),
            Text(
              paused ? 'PAUSE' : 'km/h',
              style: TextStyle(
                color: paused ? CmColors.amber : Colors.white70,
                fontSize: size * 0.13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Petit indicateur d'angle d'inclinaison.
class NavLeanChip extends ConsumerWidget {
  const NavLeanChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lean = ref.watch(rideControllerProvider.select((s) => s.leanDeg));
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    final abs = lean.abs().round();
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      decoration: BoxDecoration(color: navPanelColor, borderRadius: BorderRadius.circular(22), boxShadow: _shadow),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LeanGauge(angleDeg: lean, size: 64, showValue: false, dimmed: paused),
          const SizedBox(width: 4),
          Text('$abs°', style: CmTheme.numbers(size: 28, color: CmColors.forLean(abs.toDouble()))),
        ],
      ),
    );
  }
}

/// Bouton rond de la carte, gros et contrasté.
class NavRoundButton extends StatelessWidget {
  const NavRoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
    this.size = 62,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool active;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bg = active ? CmColors.orange : navPanelColor;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: _shadow),
          child: Material(
            color: bg,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: Icon(icon, size: size * 0.48, color: color ?? Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// Gros bouton orange « Signaler ».
class NavReportButton extends StatelessWidget {
  const NavReportButton({super.key, required this.onPressed, this.size = 88});

  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Signaler',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: CmColors.orange.withValues(alpha: 0.5), blurRadius: 20, offset: const Offset(0, 6)),
              ],
            ),
            child: Material(
              shape: const CircleBorder(side: BorderSide(color: Colors.white, width: 3)),
              clipBehavior: Clip.antiAlias,
              color: CmColors.orange,
              child: InkWell(
                onTap: onPressed,
                child: Icon(Icons.campaign_rounded, color: Colors.white, size: size * 0.5),
              ),
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: navPanelColor, borderRadius: BorderRadius.circular(99)),
              child: const Text(
                'Signaler',
                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// « Recentrer » quand l'utilisateur a déplacé la carte.
class NavRecenterButton extends StatelessWidget {
  const NavRecenterButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), boxShadow: _shadow),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: CmColors.asphalt900,
          minimumSize: const Size(0, 60),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: const StadiumBorder(),
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.navigation_rounded, color: CmColors.orange, size: 28),
        label: const Text('Recentrer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      ),
    );
  }
}

/// Une valeur du panneau du bas.
class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label, this.unit, this.color = Colors.white, this.size = 34});

  final String value;
  final String? unit;
  final String label;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: CmTheme.numbers(size: size, color: color, weight: FontWeight.w800),
              ),
              if (unit != null) ...[
                const SizedBox(width: 3),
                Text(
                  unit!,
                  style: CmTheme.numbers(size: size * 0.5, color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8),
        ),
      ],
    );
  }
}

/// Panneau du bas : arrivée, temps et km restants (avec itinéraire), ou
/// distance et durée de la balade (balade libre) ; bouton menu.
class NavBottomPanel extends ConsumerWidget {
  const NavBottomPanel({super.key, required this.eta, required this.onMenu, this.onResume});

  /// Null en balade libre.
  final NavEta? eta;
  final VoidCallback onMenu;

  /// Affiché pendant une pause.
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    final List<Widget> metrics;
    final e = eta;
    if (e != null) {
      final (km, unit) = maneuverDistanceParts(e.remainingM);
      metrics = [
        _Metric(value: Fmt.time(e.arrival), label: 'Arrivée', color: CmColors.orange, size: 38),
        _Metric(value: Fmt.duration(e.remaining), label: 'Restant'),
        _Metric(value: km, unit: unit, label: 'Reste'),
      ];
    } else {
      final distance = ref.watch(rideControllerProvider.select((s) => s.distanceM));
      final elapsed = ref.watch(rideControllerProvider.select((s) => s.elapsed));
      final avg = ref.watch(rideControllerProvider.select((s) => s.avgSpeedKmh));
      final (d, u) = distance < 1000 ? (Fmt.number(distance), 'm') : (Fmt.km(distance), 'km');
      metrics = [
        _Metric(value: d, unit: u, label: 'Parcourus', color: CmColors.orange, size: 38),
        _Metric(value: Fmt.chrono(elapsed), label: 'Durée'),
        _Metric(value: Fmt.number(avg), unit: 'km/h', label: 'Moyenne'),
      ];
    }
    return Container(
      decoration: BoxDecoration(
        color: CmColors.asphalt800,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
        boxShadow: _shadow,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 10, 10),
          child: Row(
            children: [
              if (paused && onResume != null) ...[
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: CmColors.green,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(0, 60),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: onResume,
                  icon: const Icon(Icons.play_arrow_rounded, size: 30),
                  label: const Text('Reprendre', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                ),
                const SizedBox(width: 8),
              ],
              for (final m in metrics)
                Expanded(
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: m),
                ),
              const SizedBox(width: 6),
              NavRoundButton(icon: Icons.menu_rounded, tooltip: 'Menu', onPressed: onMenu, size: 60),
            ],
          ),
        ),
      ),
    );
  }
}

/// Arrivée : terminer la balade ou continuer en balade libre.
class NavArrivalPanel extends StatelessWidget {
  const NavArrivalPanel({super.key, required this.route, required this.onFinish, required this.onContinue});

  final PlannedRoute route;
  final VoidCallback onFinish;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CmColors.asphalt800,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: _shadow,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: const BoxDecoration(color: CmColors.green, shape: BoxShape.circle),
                    child: const Icon(Icons.sports_score_rounded, color: Colors.white, size: 34),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Tu es arrivé !', style: CmTheme.numbers(size: 34, color: Colors.white)),
                        Text(
                          route.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 64,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: CmColors.orange, foregroundColor: Colors.white),
                  onPressed: onFinish,
                  icon: const Icon(Icons.flag_rounded, size: 28),
                  label: const Text('Terminer la balade', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38, width: 2),
                  ),
                  onPressed: onContinue,
                  icon: const Icon(Icons.two_wheeler_rounded),
                  label: const Text('Continuer en balade libre', style: TextStyle(fontSize: 17)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Haut de l'écran en balade libre : enregistrement + chrono.
class NavFreeRideHeader extends ConsumerWidget {
  const NavFreeRideHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    final elapsed = ref.watch(rideControllerProvider.select((s) => s.elapsed));
    final color = paused ? CmColors.amber : CmColors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: navPanelColor, borderRadius: BorderRadius.circular(99), boxShadow: _shadow),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            paused
                ? Icon(Icons.pause_rounded, size: 18, color: color)
                : Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
            const SizedBox(width: 8),
            Text(
              paused ? 'PAUSE' : 'BALADE LIBRE',
              style: TextStyle(color: color, fontWeight: FontWeight.w900, letterSpacing: 1.1, fontSize: 13),
            ),
            const SizedBox(width: 10),
            Text(Fmt.chrono(elapsed), style: CmTheme.numbers(size: 22, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
