import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/services/ride/crash_messages.dart';
import 'package:cono_moto/services/ride/ride_naming.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

void main() {
  setUpAll(initTestLocale);

  group('nom automatique', () {
    // 4 octobre 2026 = dimanche, 6 octobre 2026 = mardi (heure locale).
    test('balade du dimanche matin', () {
      expect(autoRideName(DateTime(2026, 10, 4, 9, 15), distanceKm: 85), 'Balade du dimanche matin');
    });

    test('selon la distance et le moment', () {
      expect(autoRideName(DateTime(2026, 10, 6, 12, 30), distanceKm: 12), 'Petit tour du mardi midi');
      expect(autoRideName(DateTime(2026, 10, 4, 15), distanceKm: 210), 'Belle virée du dimanche après-midi');
      expect(autoRideName(DateTime(2026, 10, 6, 19), distanceKm: 60), 'Balade du mardi soir');
      expect(autoRideName(DateTime(2026, 10, 4, 7), distanceKm: 420), 'Road trip du dimanche matin');
      expect(autoRideName(DateTime(2026, 10, 6, 23, 10), distanceKm: 50), 'Balade nocturne du mardi');
    });

    test('itinéraire suivi : son nom est repris', () {
      expect(autoRideName(DateTime(2026, 10, 4, 9), routeName: 'Boucle du Vercors'), 'Boucle du Vercors');
      expect(autoRideName(DateTime(2026, 10, 4, 9), distanceKm: 80, routeName: '  '), 'Balade du dimanche matin');
    });
  });

  group('messages d\'alerte chute', () {
    test('SMS avec lien Google Maps', () {
      final sms = buildCrashSms(at: const GeoPoint(45.123456, 5.654321), accuracyM: 8.4);
      expect(sms, contains('https://maps.google.com/?q=45.12346,5.65432'));
      expect(sms, contains('±8 m'));
      expect(sms, contains('112'));
    });

    test('SMS sans position', () {
      expect(buildCrashSms(), contains('Position GPS indisponible'));
    });
  });
}
