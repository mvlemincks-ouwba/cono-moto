import 'dart:math' as math;

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/services/social/codes.dart';
import 'package:cono_moto/services/social/live_throttle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SocialCodes', () {
    test('code ami : 6 caractères sans ambiguïté', () {
      final r = math.Random(42);
      for (var i = 0; i < 500; i++) {
        final c = SocialCodes.newFriendCode(random: r);
        expect(c.length, 6);
        expect(SocialCodes.isValidFriendCode(c), isTrue, reason: c);
        expect(c, isNot(matches(RegExp('[01OIL]'))));
      }
    });

    test('code de groupe : 8 caractères', () {
      final c = SocialCodes.newGroupCode(random: math.Random(1));
      expect(c.length, 8);
      expect(SocialCodes.isValidGroupCode(c), isTrue);
    });

    test('les codes générés sont variés', () {
      final codes = {for (var i = 0; i < 200; i++) SocialCodes.newFriendCode()};
      expect(codes.length, greaterThan(195));
    });

    test('jeton de partage long et alphanumérique', () {
      final t = SocialCodes.newShareToken();
      expect(t.length, 32);
      expect(SocialCodes.isValidShareToken(t), isTrue);
      expect(SocialCodes.isValidShareToken('court'), isFalse);
      expect(SocialCodes.isValidShareToken('a' * 25 + '/'), isFalse);
    });

    test('normalisation de la saisie', () {
      expect(SocialCodes.normalize(' k7p-m2x '), 'K7PM2X');
      expect(SocialCodes.normalize('abcd-efgh'), 'ABCDEFGH');
      expect(SocialCodes.isValidFriendCode(SocialCodes.normalize('k7pm2x')), isTrue);
    });

    test('validation', () {
      expect(SocialCodes.isValidFriendCode('K7PM2X'), isTrue);
      expect(SocialCodes.isValidFriendCode('K7PM2'), isFalse);
      expect(SocialCodes.isValidFriendCode('K7PM2O'), isFalse, reason: 'O ambigu');
      expect(SocialCodes.isValidFriendCode('K7PM21'), isFalse, reason: '1 ambigu');
      expect(SocialCodes.isValidGroupCode('ABCDEFGH'), isTrue);
      expect(SocialCodes.isValidGroupCode('ABCDEFGHJK'), isTrue);
      expect(SocialCodes.isValidGroupCode('ABCDEFG'), isFalse);
      expect(SocialCodes.isValidGroupCode('ABCDEFGHJKM'), isFalse);
    });

    test('affichage par blocs de 4', () {
      expect(SocialCodes.formatGroupCode('ABCDEFGH'), 'ABCD-EFGH');
      expect(SocialCodes.formatGroupCode('ABCDEFGHJK'), 'ABCD-EFGH-JK');
      expect(SocialCodes.formatGroupCode('ABC'), 'ABC');
    });

    test('URL de la page de suivi', () {
      expect(
        SocialCodes.shareUrl(
          viewerUrl: 'https://cono.web.app/live.html',
          databaseUrl: 'https://cono-default-rtdb.europe-west1.firebasedatabase.app',
          token: 'TOKEN123',
        ),
        'https://cono.web.app/live.html?db=https%3A%2F%2Fcono-default-rtdb.europe-west1.firebasedatabase.app&t=TOKEN123',
      );
      expect(SocialCodes.shareUrl(viewerUrl: 'https://x.app/live.html?v=2', databaseUrl: 'https://d', token: 'T'),
          startsWith('https://x.app/live.html?v=2&db='));
      expect(SocialCodes.shareUrl(viewerUrl: '', databaseUrl: 'https://d', token: 'T'), isNull);
    });
  });

  group('LiveThrottle', () {
    final t0 = DateTime.utc(2026, 6, 1, 10);
    const p0 = GeoPoint(45, 3);

    test('publie la première position', () {
      expect(LiveThrottle().shouldPublish(p0, t0), isTrue);
    });

    test('au plus toutes les 5 s ou tous les 50 m', () {
      final th = LiveThrottle()..markPublished(p0, t0);
      // 3 s, quasi immobile : on attend.
      expect(th.shouldPublish(const GeoPoint(45.0001, 3), t0.add(const Duration(seconds: 3))), isFalse);
      // 5 s écoulées : on publie.
      expect(th.shouldPublish(const GeoPoint(45.0001, 3), t0.add(const Duration(seconds: 5))), isTrue);
      // 3 s mais 111 m parcourus : on publie.
      expect(th.shouldPublish(const GeoPoint(45.001, 3), t0.add(const Duration(seconds: 3))), isTrue);
      // Jamais plus d'une fois toutes les 2 s, même à 200 km/h.
      expect(th.shouldPublish(const GeoPoint(45.001, 3), t0.add(const Duration(seconds: 1))), isFalse);
    });

    test('check mémorise la publication', () {
      final th = LiveThrottle();
      expect(th.check(p0, t0), isTrue);
      expect(th.check(p0, t0.add(const Duration(seconds: 1))), isFalse);
      expect(th.lastPublishedAt, t0);
      th.reset();
      expect(th.check(p0, t0.add(const Duration(seconds: 1))), isTrue);
    });

    test('horloge revenue en arrière : on republie', () {
      final th = LiveThrottle()..markPublished(p0, t0);
      expect(th.shouldPublish(p0, t0.subtract(const Duration(minutes: 1))), isTrue);
    });
  });

  group('TrailBuffer', () {
    test('ignore les points trop proches et borne la taille', () {
      final b = TrailBuffer(maxPoints: 10, minSpacingM: 40);
      final t0 = DateTime.utc(2026);
      b.add(const GeoPoint(45, 3), t0);
      b.add(const GeoPoint(45.0001, 3), t0); // 11 m : ignoré
      expect(b.points.length, 1);
      for (var i = 1; i <= 30; i++) {
        b.add(GeoPoint(45 + i * 0.001, 3), t0.add(Duration(seconds: i)));
      }
      expect(b.points.length, 10);
      expect(b.points.last.lat, closeTo(45.03, 1e-9));
      final decoded = Geo.decodePolyline(b.encode());
      expect(decoded.first.lat, closeTo(b.points.first.lat, 1e-5));
      expect(decoded.last.lat, closeTo(45.03, 1e-5));
    });

    test('oublie les points trop anciens', () {
      final b = TrailBuffer(maxAge: const Duration(hours: 1));
      final t0 = DateTime.utc(2026);
      b.add(const GeoPoint(45, 3), t0);
      b.add(const GeoPoint(46, 3), t0.add(const Duration(hours: 2)));
      expect(b.points, [const GeoPoint(46, 3)]);
    });
  });
}
