import '../../core/geo.dart';

/// Détection du « pote qui décroche » — logique pure, testée dans
/// `test/social/straggler_test.dart`.
///
/// Pendant que je roule, si un membre d'un de mes groupes qui roule aussi
/// s'éloigne de plus de `thresholdKm`, on alerte UNE fois. L'alerte est
/// réarmée quand il revient sous 60 % du seuil (hystérésis : pas de
/// notifications en rafale autour du seuil).
class StragglerCandidate {
  const StragglerCandidate({
    required this.uid,
    required this.name,
    required this.location,
    required this.riding,
    required this.updatedAt,
  });

  final String uid;
  final String name;
  final GeoPoint location;
  final bool riding;
  final DateTime updatedAt;
}

class StragglerAlert {
  const StragglerAlert({required this.uid, required this.name, required this.distanceM});

  final String uid;
  final String name;
  final double distanceM;

  @override
  String toString() => 'StragglerAlert($name, ${distanceM.round()} m)';
}

class StragglerDetector {
  StragglerDetector({
    this.rearmRatio = 0.6,
    this.maxPositionAge = const Duration(minutes: 3),
  });

  /// Fraction du seuil sous laquelle l'alerte est réarmée.
  final double rearmRatio;

  /// Une position plus vieille n'est pas prise en compte (pote hors réseau).
  final Duration maxPositionAge;

  final Set<String> _alerted = {};

  /// Potes actuellement considérés comme décrochés.
  Set<String> get alerted => Set.unmodifiable(_alerted);

  /// Oublie tout (fin de balade).
  void reset() => _alerted.clear();

  /// Évalue la situation et retourne les NOUVELLES alertes à notifier.
  List<StragglerAlert> update({
    required GeoPoint? me,
    required bool iAmRiding,
    required double thresholdKm,
    required Iterable<StragglerCandidate> members,
    String? myUid,
    DateTime? now,
  }) {
    if (!iAmRiding || thresholdKm <= 0) {
      reset();
      return const [];
    }
    if (me == null) return const [];
    final t = (now ?? DateTime.now()).toUtc();
    final thresholdM = thresholdKm * 1000;
    final out = <StragglerAlert>[];
    final seen = <String>{};
    for (final m in members) {
      if (m.uid == myUid || !seen.add(m.uid)) continue;
      // Pote à l'arrêt ou sans position fraîche : on ne conclut rien.
      if (!m.riding || t.difference(m.updatedAt.toUtc()) > maxPositionAge) continue;
      final d = Geo.distance(me, m.location);
      if (_alerted.contains(m.uid)) {
        if (d < thresholdM * rearmRatio) _alerted.remove(m.uid);
      } else if (d > thresholdM) {
        _alerted.add(m.uid);
        out.add(StragglerAlert(uid: m.uid, name: m.name, distanceM: d));
      }
    }
    return out;
  }
}
