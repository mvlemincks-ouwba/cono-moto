import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Ce que le motard voit pendant une balade, pour régler la fréquence des
/// capteurs : l'angle n'a besoin de 50 mesures par seconde que s'il est à
/// l'écran (ou pour la détection de chute, qui écoute l'accéléromètre).
///
/// L'écran de balade (compteur ou navigation) se signale avec [hudShown] /
/// [hudHidden] ; l'accueil indique si l'appli est au premier plan
/// ([foreground] : faux écran éteint ou appli en arrière-plan).
class RideDisplay extends ChangeNotifier {
  int _huds = 0;
  bool _foreground = true;

  /// L'écran de balade est affiché et l'appli est au premier plan.
  bool get leanVisible => _huds > 0 && _foreground;

  void hudShown() => _update(() => _huds++);

  void hudHidden() => _update(() => _huds = _huds > 0 ? _huds - 1 : 0);

  bool get foreground => _foreground;
  set foreground(bool value) => _update(() => _foreground = value);

  void _update(void Function() change) {
    final before = leanVisible;
    change();
    if (leanVisible != before) notifyListeners();
  }
}

final rideDisplayProvider = Provider<RideDisplay>((ref) {
  final display = RideDisplay();
  ref.onDispose(display.dispose);
  return display;
});
