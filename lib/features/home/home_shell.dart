import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../garage/garage_screen.dart';
import '../history/history_screen.dart';
import '../history/ride_detail_screen.dart';
import '../map/map_screen.dart';
import '../ride/ride_controller.dart';
import '../ride/ride_display.dart';
import '../ride/ride_screen.dart';
import '../routes/routes_home_screen.dart';
import '../social/social_home_screen.dart';
import '../social/social_providers.dart';
import '../update/update_controller.dart';
import '../update/update_sheet.dart';

/// Onglet actif de la barre de navigation (modifiable depuis n'importe où).
class HomeTabNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

final homeTabProvider = NotifierProvider<HomeTabNotifier, int>(HomeTabNotifier.new);

/// Index des onglets.
class HomeTabs {
  HomeTabs._();
  static const map = 0;
  static const routes = 1;
  static const history = 2;
  static const friends = 3;
  static const garage = 4;
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  late final AppLifecycleListener _lifecycle;
  bool _updatePrompted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recoverRide();
      _checkForUpdate();
    });
    _lifecycle = AppLifecycleListener(
      onResume: _onResume,
      // Écran éteint ou appli en arrière-plan : capteurs ralentis en balade.
      onShow: () => ref.read(rideDisplayProvider).foreground = true,
      onHide: () => ref.read(rideDisplayProvider).foreground = false,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _onResume() {
    // Retour du réglage « Installer des applis inconnues » : l'installation reprend.
    ref.read(appUpdateProvider.notifier).onResumed();
    _checkForUpdate();
  }

  /// Nouvelle version ? On la propose, mais jamais pendant une balade ni
  /// par-dessus un autre écran.
  Future<void> _checkForUpdate() async {
    if (_updatePrompted || !ref.read(appUpdateProvider).autoCheck) return;
    if (ref.read(rideControllerProvider).isActive) return;
    final updates = ref.read(appUpdateProvider.notifier);
    final found = await updates.check();
    if (found == null || !mounted) return;
    // En Wi-Fi, elle se télécharge en douce : « Mettre à jour » l'installera tout de suite.
    unawaited(updates.preDownload());
    if (!updates.shouldPrompt(found)) return;
    if (ref.read(rideControllerProvider).isActive || ModalRoute.of(context)?.isCurrent != true) return;
    _updatePrompted = true;
    try {
      await showUpdateSheet(context);
      // Fenêtre fermée sans lancer la mise à jour : on la repropose demain.
      final phase = ref.read(appUpdateProvider).phase;
      if (phase == UpdatePhase.available || phase == UpdatePhase.error) await updates.snooze(found);
    } finally {
      _updatePrompted = false;
    }
  }

  /// Balade interrompue (appli tuée, batterie à plat) : on la finalise.
  Future<void> _recoverRide() async {
    final ride = await ref.read(rideControllerProvider.notifier).recoverUnfinished();
    if (ride == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Balade interrompue récupérée : « ${ride.name} »'),
      action: SnackBarAction(
        label: 'Voir',
        onPressed: () => Navigator.of(context).push(RideDetailScreen.pageRoute(ride.id)),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(homeTabProvider);
    // Envoi de ma position aux potes, liens de suivi, alertes SOS / décrochage.
    ref.watch(liveSyncProvider);
    final rideActive = ref.watch(rideControllerProvider.select((s) => s.isActive));

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: index,
              children: const [
                MapScreen(),
                RoutesHomeScreen(),
                HistoryScreen(),
                SocialHomeScreen(),
                GarageScreen(),
              ],
            ),
          ),
          if (rideActive && index != HomeTabs.map) const _RideInProgressBar(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: ref.read(homeTabProvider.notifier).select,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Carte'),
          NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: 'Balades'),
          NavigationDestination(icon: Icon(Icons.history), selectedIcon: Icon(Icons.history_toggle_off), label: 'Historique'),
          NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Potes'),
          NavigationDestination(icon: Icon(Icons.two_wheeler_outlined), selectedIcon: Icon(Icons.two_wheeler), label: 'Garage'),
        ],
      ),
    );
  }
}

class _RideInProgressBar extends StatelessWidget {
  const _RideInProgressBar();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.primary,
      child: InkWell(
        onTap: () => Navigator.of(context).push(RideScreen.route()),
        child: const SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.fiber_manual_record, color: Colors.white, size: 14),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Balade en cours · toucher pour revenir au compteur',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
