// HUD plein écran pendant la balade : compteur ou carte, gros boutons
// utilisables avec des gants. Contrat public : RideScreen + RideScreen.route().
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/map/cm_map.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../fuel/fuel_ui.dart';
import '../garage/autonomy.dart';
import '../routes/guidance_banner.dart';
import '../social/social_sheets.dart';
import 'crash_alert_screen.dart';
import 'ride_controller.dart';
import 'ride_summary_screen.dart';
import 'widgets/lean_gauge.dart';

/// Disposition du HUD.
enum HudLayout { gauges, map }

class RideScreen extends ConsumerStatefulWidget {
  const RideScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const RideScreen());

  /// Le HUD est toujours sombre : contraste maximal, pas d'éblouissement.
  static final ThemeData hudTheme = CmTheme.dark();

  @override
  ConsumerState<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends ConsumerState<RideScreen> {
  static const _layoutKey = 'ride.hudLayout';
  HudLayout _layout = HudLayout.gauges;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    try {
      final saved = ref.read(sharedPreferencesProvider).getString(_layoutKey);
      if (saved == HudLayout.map.name) _layout = HudLayout.map;
    } catch (_) {}
  }

  void _toggleLayout() {
    HapticFeedback.selectionClick();
    setState(() => _layout = _layout == HudLayout.gauges ? HudLayout.map : HudLayout.gauges);
    try {
      ref.read(sharedPreferencesProvider).setString(_layoutKey, _layout.name);
    } catch (_) {}
  }

  Future<void> _finish() async {
    if (_finishing) return;
    final ctrl = ref.read(rideControllerProvider.notifier);
    var save = true;
    if (!ctrl.isWorthSaving) {
      final keep = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.straighten_rounded, color: CmColors.orange),
          title: const Text('Balade très courte'),
          content: const Text('Moins de 200 m au compteur. Tu veux quand même la garder dans ton historique ?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ne pas enregistrer')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enregistrer')),
          ],
        ),
      );
      if (keep == null) return;
      save = keep;
    }
    setState(() => _finishing = true);
    HapticFeedback.heavyImpact();
    final ride = await ctrl.stop(save: save);
    if (!mounted) return;
    if (ride != null) {
      Navigator.of(context).pushReplacement(RideSummaryScreen.route(ride));
    } else {
      Navigator.of(context).maybePop();
      if (!save) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(const SnackBar(content: Text('Balade non enregistrée.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(rideControllerProvider.select((s) => s.status));
    final active = status == RideStatus.recording || status == RideStatus.paused;
    final Widget body;
    if (_finishing || status == RideStatus.finishing) {
      body = const _FinishingView();
    } else if (active) {
      body = _HudView(layout: _layout, onToggleLayout: _toggleLayout, onFinish: _finish);
    } else {
      body = const _ReadyView();
    }
    return Theme(
      data: RideScreen.hudTheme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: CmColors.asphalt900,
          body: AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: body),
        ),
      ),
    );
  }
}

// =============================================================================
// Prêt à rouler
// =============================================================================

class _ReadyView extends ConsumerStatefulWidget {
  const _ReadyView();

  @override
  ConsumerState<_ReadyView> createState() => _ReadyViewState();
}

class _ReadyViewState extends ConsumerState<_ReadyView> with SingleTickerProviderStateMixin {
  late final AnimationController _sway = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _sway.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    HapticFeedback.mediumImpact();
    final ok = await ref.read(rideControllerProvider.notifier).start(route: ref.read(activeRouteProvider));
    if (!ok && mounted) HapticFeedback.vibrate();
  }

  @override
  Widget build(BuildContext context) {
    final ride = ref.watch(rideControllerProvider);
    final starting = ride.status == RideStatus.starting;
    final route = ref.watch(activeRouteProvider);
    final bike = ref.watch(defaultBikeProvider);
    final settings = ref.watch(settingsProvider);
    final scheme = Theme.of(context).colorScheme;
    final canPop = Navigator.of(context).canPop();

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                if (canPop)
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Fermer',
                  ),
                const Spacer(),
                if (settings.crashDetection)
                  Flexible(
                    child: TextButton.icon(
                      onPressed: () => CrashAlertScreen.startTest(context, ref),
                      icon: const Icon(Icons.health_and_safety_outlined, size: 18),
                      label: const Text('Tester l\'alerte chute', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                Center(
                  child: AnimatedBuilder(
                    animation: _sway,
                    builder: (_, _) => LeanGauge(
                      angleDeg: math.sin((_sway.value - 0.5) * math.pi) * 24,
                      size: math.min(MediaQuery.sizeOf(context).width - 80, 280),
                      showValue: false,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Prêt à rouler ?',
                  textAlign: TextAlign.center,
                  style: CmTheme.numbers(size: 46, color: scheme.onSurface),
                ),
                const SizedBox(height: 6),
                Text(
                  bike != null
                      ? 'En selle sur ta ${bike.name}'
                      : 'Ajoute ta moto dans le garage pour suivre son kilométrage.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                const _InfoCard(
                  icon: Icons.phone_android_rounded,
                  color: CmColors.orange,
                  title: 'Fixe ton téléphone sur le guidon pour mesurer l\'angle',
                  message: 'Laisse-le immobile quelques secondes au départ : on calibre l\'inclinaison.',
                ),
                if (route != null) ...[
                  const SizedBox(height: 10),
                  _InfoCard(
                    icon: Icons.alt_route_rounded,
                    color: CmColors.sky,
                    title: route.name,
                    message:
                        'Itinéraire suivi · ${Fmt.distance(route.distanceM > 0 ? route.distanceM : Geo.length(route.points))}',
                    trailing: IconButton(
                      tooltip: 'Rouler sans itinéraire',
                      onPressed: () => ref.read(activeRouteProvider.notifier).clear(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                _SafetyCard(settings: settings),
                if (ride.lastError != null) ...[
                  const SizedBox(height: 10),
                  _ErrorCard(message: ride.lastError!, access: ride.locationAccess),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: SizedBox(
              width: double.infinity,
              height: 76,
              child: FilledButton(
                onPressed: starting ? null : _start,
                style: FilledButton.styleFrom(
                  backgroundColor: CmColors.orange,
                  disabledBackgroundColor: CmColors.orange.withValues(alpha: 0.6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: starting
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                            ),
                            SizedBox(width: 14),
                            Text('Recherche du GPS…', style: TextStyle(fontSize: 18, color: Colors.white)),
                          ],
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.play_arrow_rounded, size: 36, color: Colors.white),
                            const SizedBox(width: 8),
                            Text('C\'EST PARTI', style: CmTheme.numbers(size: 30, color: Colors.white)),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.color, required this.title, this.message, this.trailing});

  final IconData icon;
  final Color color;
  final String title;
  final String? message;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(CmSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(CmSpacing.radius),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: CmSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                if (message != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    message!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _SafetyCard extends StatelessWidget {
  const _SafetyCard({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    if (!settings.crashDetection) {
      return const _InfoCard(
        icon: Icons.shield_outlined,
        color: Color(0xFF9AA3B2),
        title: 'Détection de chute désactivée',
        message: 'Tu peux l\'activer dans les réglages.',
      );
    }
    if (!settings.hasEmergencyContact) {
      return const _InfoCard(
        icon: Icons.health_and_safety_rounded,
        color: CmColors.amber,
        title: 'Détection de chute active',
        message: 'Pas de contact d\'urgence : seuls tes potes seront prévenus. Ajoutes-en un dans les réglages.',
      );
    }
    final name = settings.emergencyName.trim().isNotEmpty ? settings.emergencyName.trim() : settings.emergencyPhone;
    return _InfoCard(
      icon: Icons.health_and_safety_rounded,
      color: CmColors.green,
      title: 'Détection de chute active',
      message: 'En cas de chute sans réponse, $name reçoit un SMS avec ta position.',
    );
  }
}

class _ErrorCard extends ConsumerWidget {
  const _ErrorCard({required this.message, this.access});

  final String message;
  final LocationAccess? access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.read(locationServiceProvider);
    final action = switch (access) {
      LocationAccess.deniedForever => ('Ouvrir les réglages', location.openSettings),
      LocationAccess.serviceDisabled => ('Activer la localisation', location.openLocationSettings),
      _ => null,
    };
    return _InfoCard(
      icon: Icons.location_off_rounded,
      color: CmColors.red,
      title: message,
      trailing: action == null ? null : TextButton(onPressed: () => action.$2(), child: Text(action.$1)),
    );
  }
}

class _FinishingView extends StatelessWidget {
  const _FinishingView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(dimension: 56, child: CircularProgressIndicator(strokeWidth: 5)),
          const SizedBox(height: 20),
          Text('On range la balade au garage…', style: CmTheme.numbers(size: 28, color: Colors.white)),
        ],
      ),
    );
  }
}

// =============================================================================
// HUD
// =============================================================================

class _HudView extends ConsumerWidget {
  const _HudView({required this.layout, required this.onToggleLayout, required this.onFinish});

  final HudLayout layout;
  final VoidCallback onToggleLayout;
  final Future<void> Function() onFinish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasRoute =
        ref.watch(rideControllerProvider.select((s) => s.route != null)) || ref.watch(activeRouteProvider) != null;
    return LayoutBuilder(
      builder: (context, c) {
        // Téléphone en paysage sur le guidon : boutons en colonne à droite.
        final landscape = c.maxWidth > c.maxHeight * 1.1;
        final main = Column(
          children: [
            SafeArea(
              bottom: false,
              right: !landscape,
              child: _TopBar(layout: layout, onToggleLayout: onToggleLayout),
            ),
            if (hasRoute) const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 8), child: GuidanceBanner()),
            const _FuelBanner(),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: layout == HudLayout.gauges ? const _GaugesBody() : const _MapBody(),
              ),
            ),
          ],
        );
        if (landscape) {
          return Row(
            children: [
              Expanded(child: SafeArea(top: false, right: false, child: main)),
              SafeArea(left: false, child: _ActionBar(onFinish: onFinish, vertical: true)),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: main),
            SafeArea(top: false, child: _ActionBar(onFinish: onFinish)),
          ],
        );
      },
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.layout, required this.onToggleLayout});

  final HudLayout layout;
  final VoidCallback onToggleLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    final elapsed = ref.watch(rideControllerProvider.select((s) => s.elapsed));
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 8, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            iconSize: 30,
            tooltip: 'Réduire (la balade continue)',
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _RecPill(paused: paused, elapsed: elapsed),
              ),
            ),
          ),
          const SizedBox(width: 6),
          const _GpsBadge(),
          const SizedBox(width: 6),
          MapRoundButton(
            icon: layout == HudLayout.gauges ? Icons.map_rounded : Icons.speed_rounded,
            tooltip: layout == HudLayout.gauges ? 'Vue carte' : 'Vue compteur',
            onPressed: onToggleLayout,
          ),
          const SizedBox(width: 6),
          MapRoundButton(icon: Icons.more_horiz_rounded, tooltip: 'Plus', onPressed: () => _showMore(context, ref)),
        ],
      ),
    );
  }

  void _showMore(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Theme(
        data: RideScreen.hudTheme,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SheetAction(
                  icon: Icons.local_gas_station_rounded,
                  label: 'Ajouter un plein',
                  onTap: () {
                    Navigator.pop(ctx);
                    showFuelEntryForm(context, rideId: ref.read(rideControllerProvider).rideId);
                  },
                ),
                _SheetAction(
                  icon: Icons.share_location_rounded,
                  label: 'Partager ma position en direct',
                  onTap: () {
                    Navigator.pop(ctx);
                    showShareLocationSheet(context);
                  },
                ),
                _SheetAction(
                  icon: layout == HudLayout.gauges ? Icons.map_rounded : Icons.speed_rounded,
                  label: layout == HudLayout.gauges ? 'Passer en vue carte' : 'Passer en vue compteur',
                  onTap: () {
                    Navigator.pop(ctx);
                    onToggleLayout();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 64,
      leading: Icon(icon, color: CmColors.orange, size: 28),
      title: Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      onTap: onTap,
    );
  }
}

class _RecPill extends StatefulWidget {
  const _RecPill({required this.paused, required this.elapsed});

  final bool paused;
  final Duration elapsed;

  @override
  State<_RecPill> createState() => _RecPillState();
}

class _RecPillState extends State<_RecPill> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.paused ? CmColors.amber : CmColors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.paused)
            Icon(Icons.pause_rounded, size: 16, color: color)
          else
            FadeTransition(
              opacity: Tween(begin: 0.25, end: 1.0).animate(_blink),
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
          const SizedBox(width: 8),
          Text(
            widget.paused ? 'PAUSE' : 'REC',
            style: TextStyle(color: color, fontWeight: FontWeight.w900, letterSpacing: 1.2, fontSize: 13),
          ),
          const SizedBox(width: 8),
          Text(Fmt.chrono(widget.elapsed), style: CmTheme.numbers(size: 20, color: Colors.white)),
        ],
      ),
    );
  }
}

class _GpsBadge extends ConsumerWidget {
  const _GpsBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acc = ref.watch(rideControllerProvider.select((s) => s.gpsAccuracyM));
    final lost = ref.watch(rideControllerProvider.select((s) => s.gpsLost));
    final (IconData icon, Color color, String label) = switch ((acc, lost)) {
      (_, true) => (Icons.gps_off_rounded, CmColors.red, 'GPS perdu'),
      (null, _) => (Icons.gps_not_fixed_rounded, CmColors.amber, 'Recherche GPS'),
      (final a?, _) when a <= 12 => (Icons.gps_fixed_rounded, CmColors.green, 'GPS ±${a.round()} m'),
      (final a?, _) => (Icons.gps_fixed_rounded, CmColors.amber, 'GPS ±${a.round()} m'),
    };
    return Tooltip(
      message: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            if (lost || acc == null) ...[
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FuelBanner extends ConsumerWidget {
  const _FuelBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(rideControllerProvider.select((s) => s.lowFuelAlert));
    final autonomy = ref.watch(autonomyProvider);
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      child: !show
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: GlassPanel(
                color: CmColors.amber.withValues(alpha: 0.18),
                padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                child: Row(
                  children: [
                    const Icon(Icons.local_gas_station_rounded, color: CmColors.amber, size: 30),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Réserve en vue !',
                            style: TextStyle(color: CmColors.amber, fontWeight: FontWeight.w900, fontSize: 16),
                          ),
                          if (autonomy != null)
                            Text(
                              'Encore ~${autonomy.remainingKm.round()} km d\'autonomie',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                            ),
                        ],
                      ),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: CmColors.amber,
                        foregroundColor: Colors.black,
                        minimumSize: const Size(0, 52),
                      ),
                      onPressed: () => _openStations(context, ref),
                      child: const Text('Stations'),
                    ),
                    IconButton(
                      tooltip: 'Masquer',
                      onPressed: ref.read(rideControllerProvider.notifier).dismissLowFuelAlert,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

void _openStations(BuildContext context, WidgetRef ref) {
  final route = ref.read(activeRouteProvider) ?? ref.read(rideControllerProvider).route;
  final here = ref.read(positionHubProvider)?.point;
  showFuelStationsSheet(context, alongRoute: route?.points, near: here);
}

// -----------------------------------------------------------------------------
// Vue compteur
// -----------------------------------------------------------------------------

class _GaugesBody extends StatelessWidget {
  const _GaugesBody();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final landscape = c.maxWidth > c.maxHeight * 1.1;
        if (landscape) {
          final gauge = math.min(c.maxHeight / 0.9, c.maxWidth * 0.45);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(
                        width: math.max(300, c.maxWidth - gauge - 44),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _SpeedReadout(size: math.min(c.maxHeight * 0.42, 150)),
                            const SizedBox(height: 12),
                            const _StatTiles(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _GaugeBlock(size: gauge),
                ),
              ],
            ),
          );
        }
        const tilesHeight = 160.0;
        final speedSize = (c.maxHeight * 0.2).clamp(72.0, 156.0);
        final speedBlock = speedSize * 1.05;
        final gauge = math.max(150.0, math.min(c.maxWidth - 8, (c.maxHeight - tilesHeight - speedBlock - 12) / 0.86));
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              _SpeedReadout(size: speedSize),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _GaugeBlock(size: gauge),
                  ),
                ),
              ),
              const _StatTiles(),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _SpeedReadout extends ConsumerWidget {
  const _SpeedReadout({required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(rideControllerProvider.select((s) => s.speedKmh));
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    final hasFix = ref.watch(rideControllerProvider.select((s) => s.hasFix));
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final text = !hasFix ? '--' : '${speed < 2 ? 0 : speed.round()}';
    return Semantics(
      label: 'Vitesse $text kilomètres heure',
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              text,
              style: CmTheme.numbers(size: size, color: paused ? muted : Colors.white, weight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            Text(
              'km/h',
              style: CmTheme.numbers(size: math.max(18, size * 0.2), color: muted, weight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugeBlock extends ConsumerWidget {
  const _GaugeBlock({required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lean = ref.watch(rideControllerProvider.select((s) => s.leanDeg));
    final maxL = ref.watch(rideControllerProvider.select((s) => s.maxLeanLeftDeg));
    final maxR = ref.watch(rideControllerProvider.select((s) => s.maxLeanRightDeg));
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    final calibrated = ref.watch(rideControllerProvider.select((s) => s.leanCalibrated));
    final fromGyro = ref.watch(rideControllerProvider.select((s) => s.leanFromGyro));
    final speed = ref.watch(rideControllerProvider.select((s) => s.speedKmh));

    String? hint;
    if (paused) {
      hint = null;
    } else if (!calibrated && speed < 5) {
      hint = 'Calibrage de l\'angle… garde le téléphone immobile';
    } else if (!fromGyro && speed >= 12) {
      hint = 'Angle estimé via le GPS (moins précis)';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LeanGauge(angleDeg: lean, maxLeftDeg: maxL, maxRightDeg: maxR, size: size, dimmed: paused),
        if (hint != null) Pill(label: hint, icon: Icons.info_outline_rounded, color: CmColors.sky),
      ],
    );
  }
}

class _StatTiles extends ConsumerWidget {
  const _StatTiles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final distance = ref.watch(rideControllerProvider.select((s) => s.distanceM));
    final moving = ref.watch(rideControllerProvider.select((s) => s.movingTime));
    final avg = ref.watch(rideControllerProvider.select((s) => s.avgSpeedKmh));
    final vmax = ref.watch(rideControllerProvider.select((s) => s.maxSpeedKmh));
    final curves = ref.watch(rideControllerProvider.select((s) => s.curveCount));
    final brakes = ref.watch(rideControllerProvider.select((s) => s.hardBrakeCount));
    final autonomy = ref.watch(autonomyProvider);

    Widget row(List<Widget> children) => Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: children[i]),
        ],
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row([
          StatTile(
            compact: true,
            label: 'Distance',
            value: distance < 1000 ? Fmt.number(distance) : Fmt.km(distance),
            unit: distance < 1000 ? 'm' : 'km',
          ),
          StatTile(compact: true, label: 'En route', value: Fmt.chrono(moving)),
          StatTile(compact: true, label: 'Moyenne', value: Fmt.number(avg), unit: 'km/h'),
        ]),
        const SizedBox(height: 8),
        row([
          if (autonomy != null)
            StatTile(
              compact: true,
              label: 'Autonomie',
              value: Fmt.number(autonomy.remainingKm),
              unit: 'km',
              color: autonomy.low ? CmColors.amber : null,
            )
          else
            StatTile(compact: true, label: 'Freinages', value: '$brakes', color: brakes > 0 ? CmColors.amber : null),
          StatTile(compact: true, label: 'Max', value: Fmt.number(vmax), unit: 'km/h'),
          StatTile(compact: true, label: 'Virages', value: '$curves'),
        ]),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Vue carte
// -----------------------------------------------------------------------------

class _MapBody extends ConsumerStatefulWidget {
  const _MapBody();

  @override
  ConsumerState<_MapBody> createState() => _MapBodyState();
}

class _MapBodyState extends ConsumerState<_MapBody> {
  FollowMode _follow = FollowMode.heading;
  List<MapLine> _lines = const [];
  Object? _linesTrack;
  String? _linesRouteId;

  List<MapLine> _buildLines(List<GeoPoint> track, List<GeoPoint>? route, String? routeId) {
    if (identical(track, _linesTrack) && routeId == _linesRouteId) return _lines;
    _linesTrack = track;
    _linesRouteId = routeId;
    final here = ref.read(positionHubProvider)?.point;
    _lines = [
      if (route != null && route.length >= 2)
        MapLine(id: 'ride-route', points: route, color: CmColors.sky, width: 7, opacity: 0.75),
      if (track.length >= 2 || (track.isNotEmpty && here != null))
        MapLine(id: 'ride-track', points: [...track, ?here], color: CmColors.orange, width: 6),
    ];
    return _lines;
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(rideControllerProvider.select((s) => s.track));
    final route = ref.watch(activeRouteProvider) ?? ref.watch(rideControllerProvider.select((s) => s.route));
    final lines = _buildLines(track, route?.points, route?.id);
    return Stack(
      children: [
        Positioned.fill(
          child: CmMap(
            lines: lines,
            followMode: _follow,
            onFollowModeChanged: (m) => setState(() => _follow = m),
            tilt: 55,
            initialZoom: 16,
            compassEnabled: false,
          ),
        ),
        if (_follow != FollowMode.heading)
          Positioned(
            right: 12,
            top: 12,
            child: MapRoundButton(
              icon: Icons.navigation_rounded,
              tooltip: 'Recentrer',
              size: 56,
              active: true,
              onPressed: () => setState(() => _follow = FollowMode.heading),
            ),
          ),
        const Positioned(left: 12, right: 12, bottom: 12, child: _MiniCounter()),
      ],
    );
  }
}

class _MiniCounter extends ConsumerWidget {
  const _MiniCounter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(rideControllerProvider);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final leanColor = CmColors.forLean(s.leanDeg.abs());
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.hasFix ? '${s.speedKmh < 2 ? 0 : s.speedKmh.round()}' : '--',
                style: CmTheme.numbers(size: 58, color: Colors.white, weight: FontWeight.w800),
              ),
              Text('km/h', style: CmTheme.numbers(size: 16, color: muted)),
            ],
          ),
          const SizedBox(width: 6),
          LeanGauge(
            angleDeg: s.leanDeg,
            maxLeftDeg: s.maxLeanLeftDeg,
            maxRightDeg: s.maxLeanRightDeg,
            size: 104,
            showValue: false,
            dimmed: s.isPaused,
          ),
          Text('${s.leanDeg.abs().round()}°', style: CmTheme.numbers(size: 30, color: leanColor)),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(Fmt.distance(s.distanceM), style: CmTheme.numbers(size: 24, color: Colors.white)),
              const SizedBox(height: 4),
              Text('moy. ${Fmt.number(s.avgSpeedKmh)} km/h', style: TextStyle(color: muted, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Boutons
// -----------------------------------------------------------------------------

class _ActionBar extends ConsumerWidget {
  const _ActionBar({required this.onFinish, this.vertical = false});

  final Future<void> Function() onFinish;

  /// Colonne à droite de l'écran (téléphone en paysage).
  final bool vertical;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paused = ref.watch(rideControllerProvider.select((s) => s.isPaused));
    final ctrl = ref.read(rideControllerProvider.notifier);

    void report() {
      final here = ref.read(positionHubProvider)?.point;
      if (here == null) {
        showCmSnack(context, 'Position GPS pas encore dispo, réessaie dans un instant.');
        return;
      }
      showReportSheet(context, at: here);
    }

    final buttons = <Widget>[
      _HudButton(
        icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
        label: paused ? 'Reprendre' : 'Pause',
        color: paused ? CmColors.green : Colors.white,
        filled: paused,
        onPressed: () {
          HapticFeedback.mediumImpact();
          paused ? ctrl.resume() : ctrl.pause();
        },
      ),
      _HudButton(
        icon: Icons.local_gas_station_rounded,
        label: 'Essence',
        color: CmColors.amber,
        onPressed: () => _openStations(context, ref),
      ),
      _HudButton(icon: Icons.campaign_rounded, label: 'Signaler', color: CmColors.orange, onPressed: report),
      _HudButton(
        icon: Icons.share_location_rounded,
        label: 'Position',
        color: CmColors.teal,
        onPressed: () => showShareLocationSheet(context),
      ),
      _StopButton(onStop: onFinish),
    ];

    final border = BorderSide(color: Colors.white.withValues(alpha: 0.06));
    if (vertical) {
      return Container(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: CmColors.asphalt800,
          border: Border(left: border),
        ),
        child: Column(
          children: [
            for (final b in buttons)
              Expanded(
                child: Center(
                  child: FittedBox(fit: BoxFit.scaleDown, child: b),
                ),
              ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: CmColors.asphalt800,
        border: Border(top: border),
      ),
      child: Row(children: [for (final b in buttons) Expanded(child: b)]),
    );
  }
}

class _HudButton extends StatelessWidget {
  const _HudButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 60,
            child: Material(
              color: filled ? color : color.withValues(alpha: 0.13),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onPressed,
                child: Icon(icon, size: 30, color: filled ? Colors.black : color),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

/// Bouton stop : appui long (anneau qui se remplit) ou appui court + confirmation.
class _StopButton extends StatefulWidget {
  const _StopButton({required this.onStop});

  final Future<void> Function() onStop;

  @override
  State<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends State<_StopButton> with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _trigger();
    });
  bool _fired = false;

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _trigger() {
    if (_fired) return;
    _fired = true;
    HapticFeedback.heavyImpact();
    widget.onStop().whenComplete(() {
      if (mounted) {
        _fired = false;
        _hold.value = 0;
      }
    });
  }

  void _down(TapDownDetails _) {
    HapticFeedback.selectionClick();
    _hold.forward(from: 0);
  }

  Future<void> _up() async {
    if (_fired) return;
    final quickTap = _hold.value < 0.3;
    _hold.reverse();
    if (!quickTap) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.flag_rounded, color: CmColors.orange, size: 36),
        title: const Text('Terminer la balade ?'),
        content: const Text('Astuce : un appui long sur Stop termine directement.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Continuer à rouler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CmColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Terminer'),
          ),
        ],
      ),
    );
    if (ok == true) _trigger();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Terminer la balade (appui long)',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTapDown: _down,
            onTapUp: (_) => _up(),
            onTapCancel: () => _hold.reverse(),
            child: SizedBox.square(
              dimension: 60,
              child: AnimatedBuilder(
                animation: _hold,
                builder: (_, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color.lerp(CmColors.red.withValues(alpha: 0.18), CmColors.red, _hold.value),
                        shape: BoxShape.circle,
                      ),
                    ),
                    CircularProgressIndicator(
                      value: _hold.value,
                      strokeWidth: 4,
                      color: Colors.white,
                      backgroundColor: Colors.transparent,
                    ),
                    Icon(Icons.stop_rounded, size: 32, color: _hold.value > 0.5 ? Colors.white : CmColors.red),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Stop',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
