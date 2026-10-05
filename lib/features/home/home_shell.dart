import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../garage/garage_screen.dart';
import '../history/history_screen.dart';
import '../history/ride_detail_screen.dart';
import '../map/map_screen.dart';
import '../ride/ride_controller.dart';
import '../ride/ride_screen.dart';
import '../routes/routes_home_screen.dart';
import '../social/social_home_screen.dart';

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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _recoverRide());
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
