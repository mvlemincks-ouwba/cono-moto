import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/features/social/straggler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 6, 1, 10);
  const me = GeoPoint(45.0, 3.0);

  /// Pote à [km] au nord de moi.
  StragglerCandidate pote(String uid, double km, {bool riding = true, Duration age = Duration.zero}) =>
      StragglerCandidate(
        uid: uid,
        name: uid.toUpperCase(),
        location: Geo.destination(me, 0, km * 1000),
        riding: riding,
        updatedAt: now.subtract(age),
      );

  List<StragglerAlert> step(StragglerDetector d, List<StragglerCandidate> members, {bool riding = true, double threshold = 3}) =>
      d.update(me: me, iAmRiding: riding, thresholdKm: threshold, members: members, myUid: 'moi', now: now);

  test('alerte une seule fois quand un pote dépasse le seuil', () {
    final d = StragglerDetector();
    expect(step(d, [pote('max', 1)]), isEmpty);
    final alerts = step(d, [pote('max', 3.5)]);
    expect(alerts.single.uid, 'max');
    expect(alerts.single.name, 'MAX');
    expect(alerts.single.distanceM, closeTo(3500, 5));
    // Toujours loin : pas de nouvelle notification.
    expect(step(d, [pote('max', 4)]), isEmpty);
    expect(step(d, [pote('max', 6)]), isEmpty);
    expect(d.alerted, {'max'});
  });

  test('hystérésis : réarmement seulement sous 60 % du seuil', () {
    final d = StragglerDetector();
    step(d, [pote('max', 3.2)]);
    // Revient à 2,5 km (> 1,8 km) puis repart : pas de nouvelle alerte.
    expect(step(d, [pote('max', 2.5)]), isEmpty);
    expect(step(d, [pote('max', 3.3)]), isEmpty);
    // Revient vraiment dans le groupe (1,5 km < 1,8 km) : réarmé.
    expect(step(d, [pote('max', 1.5)]), isEmpty);
    expect(d.alerted, isEmpty);
    expect(step(d, [pote('max', 3.4)]).single.uid, 'max');
  });

  test('ignore les potes à l\'arrêt ou sans position fraîche', () {
    final d = StragglerDetector();
    expect(step(d, [pote('max', 10, riding: false)]), isEmpty);
    expect(step(d, [pote('julie', 10, age: const Duration(minutes: 5))]), isEmpty);
    expect(d.alerted, isEmpty);
  });

  test('rien si je ne roule pas, et oubli à la fin de ma balade', () {
    final d = StragglerDetector();
    expect(step(d, [pote('max', 10)], riding: false), isEmpty);
    expect(step(d, [pote('max', 10)]).length, 1);
    step(d, [pote('max', 10)], riding: false);
    expect(d.alerted, isEmpty);
    // Nouvelle balade : de nouveau une alerte.
    expect(step(d, [pote('max', 10)]).length, 1);
  });

  test('plusieurs potes, doublons et moi-même ignorés', () {
    final d = StragglerDetector();
    final alerts = step(d, [
      pote('max', 5),
      pote('max', 5),
      pote('julie', 1),
      pote('lolo', 8),
      StragglerCandidate(uid: 'moi', name: 'Moi', location: Geo.destination(me, 90, 9000), riding: true, updatedAt: now),
    ]);
    expect(alerts.map((a) => a.uid), unorderedEquals(['max', 'lolo']));
  });

  test('seuil nul = alerte désactivée ; position inconnue = pas de conclusion', () {
    final d = StragglerDetector();
    expect(step(d, [pote('max', 50)], threshold: 0), isEmpty);
    expect(
      d.update(me: null, iAmRiding: true, thresholdKm: 3, members: [pote('max', 50)], now: now),
      isEmpty,
    );
  });

  test('seuil réglable', () {
    final d = StragglerDetector();
    expect(step(d, [pote('max', 4)], threshold: 5), isEmpty);
    expect(step(d, [pote('max', 5.5)], threshold: 5).length, 1);
  });
}
