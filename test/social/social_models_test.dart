import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/data/models/shared.dart';
import 'package:cono_moto/features/social/expenses.dart';
import 'package:cono_moto/features/social/social_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reproduit ce que renvoie le SDK Realtime Database : `Map<Object?, Object?>`,
/// tableaux pour les clés 0..n, valeurs nulles et collections vides absentes.
Object? rtdb(Object? v) {
  if (v is Map) {
    final out = <Object?, Object?>{};
    v.forEach((k, val) {
      final c = rtdb(val);
      if (c != null) out[k] = c;
    });
    return out.isEmpty ? null : out;
  }
  if (v is List) {
    final out = <Object?>[for (final x in v) rtdb(x)];
    return out.every((e) => e == null) ? null : out;
  }
  return v;
}

void main() {
  final now = DateTime.utc(2026, 6, 1, 12);

  group('Profil', () {
    test('lecture tolérante', () {
      final p = UserProfile.fromMap('u1', rtdb({'name': ' Max ', 'color': 0xFF2EC4B6, 'bike': 'MT-07', 'code': 'K7PM2X', 'createdAt': 1}))!;
      expect(p.name, 'Max');
      expect(p.color.toARGB32(), 0xFF2EC4B6);
      expect(p.code, 'K7PM2X');
      expect(p.initials, 'MA');
      expect(UserProfile.fromMap('u1', {'color': 1}), isNull, reason: 'sans pseudo');
      expect(UserProfile.fromMap('u1', null), isNull);
    });

    test('couleur par défaut stable', () {
      final p = UserProfile.fromMap('abc', {'name': 'Ju'})!;
      expect(p.colorValue, defaultColorFor('abc'));
      expect(defaultColorFor('abc'), defaultColorFor('abc'));
    });

    test('initiales', () {
      expect(initialsOf('Max Verstappen'), 'MV');
      expect(initialsOf('j'), 'J');
      expect(initialsOf('  '), '?');
    });
  });

  group('Position en direct', () {
    Map<Object?, Object?> raw({int? ts, bool riding = true, bool sos = false}) =>
        rtdb({
          'lat': 45, // entier renvoyé par le SDK
          'lng': 3.25,
          'speed': 87,
          'heading': 120,
          'lean': -32,
          'ts': ts ?? now.millisecondsSinceEpoch,
          'riding': riding,
          'name': 'Max',
          'color': 0xFFA78BFA,
          'bike': 'Tracer 9',
          'sos': sos,
        }) as Map<Object?, Object?>;

    test('conversion vers FriendLive', () {
      final f = Friend(uid: 'u1', live: LiveState.fromMap('u1', raw()));
      final l = f.toFriendLive(now: now)!;
      expect(l.name, 'Max');
      expect(l.location, const GeoPoint(45, 3.25));
      expect(l.speedKmh, 87);
      expect(l.leanDeg, -32);
      expect(l.riding, isTrue);
      expect(l.bikeName, 'Tracer 9');
      expect(l.colorValue, 0xFFA78BFA);
    });

    test('le profil prime sur les infos du direct', () {
      final f = Friend(
        uid: 'u1',
        profile: const UserProfile(uid: 'u1', name: 'Maxime', colorValue: 0xFF34D399, bike: 'R1250GS'),
        live: LiveState.fromMap('u1', raw()),
      );
      final l = f.toFriendLive(now: now)!;
      expect(l.name, 'Maxime');
      expect(l.colorValue, 0xFF34D399);
      expect(l.bikeName, 'R1250GS');
    });

    test('positions de plus de 12 h ignorées', () {
      final old = now.subtract(const Duration(hours: 13)).millisecondsSinceEpoch;
      final f = Friend(uid: 'u1', live: LiveState.fromMap('u1', raw(ts: old)));
      expect(f.toFriendLive(now: now), isNull);
      expect(f.isRiding(now: now), isFalse);
    });

    test('« en balade » seulement avec une position de moins de 10 min', () {
      final f = Friend(uid: 'u1', live: LiveState.fromMap('u1', raw(ts: now.subtract(const Duration(minutes: 20)).millisecondsSinceEpoch)));
      expect(f.isRiding(now: now), isFalse);
      expect(f.toFriendLive(now: now), isNotNull);
    });

    test('tri : SOS, puis en balade, puis par nom', () {
      final list = liveFriends([
        Friend(uid: 'c', profile: const UserProfile(uid: 'c', name: 'Zoé', colorValue: 1), live: LiveState.fromMap('c', raw(riding: false))),
        Friend(uid: 'b', profile: const UserProfile(uid: 'b', name: 'Bob', colorValue: 1), live: LiveState.fromMap('b', raw())),
        Friend(uid: 'a', profile: const UserProfile(uid: 'a', name: 'Alice', colorValue: 1), live: LiveState.fromMap('a', raw(riding: false))),
        Friend(uid: 'd', profile: const UserProfile(uid: 'd', name: 'Dan', colorValue: 1), live: LiveState.fromMap('d', raw(sos: true))),
        const Friend(uid: 'e', profile: UserProfile(uid: 'e', name: 'Sans position', colorValue: 1)),
      ], now: now);
      expect(list.map((f) => f.name), ['Dan', 'Bob', 'Alice', 'Zoé']);
      expect(list.first.sos, isTrue);
    });

    test('données invalides ignorées', () {
      expect(LiveState.fromMap('u', {'lat': 45}), isNull);
      expect(LiveState.fromMap('u', {'lat': 145, 'lng': 3, 'ts': 1}), isNull);
      expect(LiveState.fromMap('u', 'x'), isNull);
    });
  });

  group('Signalements', () {
    test('durées de vie par défaut', () {
      expect(defaultReportLifetime(ReportType.police), const Duration(hours: 2));
      expect(defaultReportLifetime(ReportType.accident), const Duration(hours: 3));
      expect(defaultReportLifetime(ReportType.danger), const Duration(hours: 24));
      expect(defaultReportLifetime(ReportType.gravillons), const Duration(days: 7));
      expect(defaultReportLifetime(ReportType.travaux), const Duration(days: 7));
      for (final t in ReportType.values) {
        expect(reportLifetimeChoices, contains(defaultReportLifetime(t)), reason: t.name);
      }
      expect(lifetimeLabel(const Duration(hours: 2)), '2 h');
      expect(lifetimeLabel(const Duration(days: 7)), '7 j');
    });

    test('aller-retour et expiration', () {
      final map = reportToMap(
        type: ReportType.gravillons,
        at: const GeoPoint(45.1, 3.2),
        comment: '  sortie de virage ',
        createdAt: now,
        lifetime: const Duration(days: 7),
        authorName: 'Max',
      );
      expect(map['comment'], 'sortie de virage');
      final reports = reportsFromMap('u1', rtdb({'r1': map, 'r2': {...map, 'type': 'police', 'ts': now.millisecondsSinceEpoch + 1000, 'expiresAt': now.add(const Duration(hours: 2)).millisecondsSinceEpoch}}));
      expect(reports.length, 2);
      final r1 = reports.firstWhere((r) => r.id == 'r1');
      expect(r1.type, ReportType.gravillons);
      expect(r1.authorUid, 'u1');
      expect(r1.authorName, 'Max');
      expect(r1.expiresAt, now.add(const Duration(days: 7)));

      final in3h = now.add(const Duration(hours: 3));
      final active = activeReports(reports, now: in3h);
      expect(active.map((r) => r.id), ['r1'], reason: 'le contrôle (2 h) a expiré');
      expect(activeReports(reports, now: now).map((r) => r.id), ['r2', 'r1'], reason: 'plus récent d\'abord');
    });
  });

  group('Groupes', () {
    final raw = rtdb({
      'name': 'Les Virolos',
      'createdBy': 'a',
      'createdAt': now.millisecondsSinceEpoch,
      'members': {
        'a': {'name': 'Alice', 'color': 0xFF2EC4B6, 'joinedAt': 1},
        'b': {'name': 'Bob', 'color': 0xFF4EA8FF},
        'c': {'name': 'Carol'},
      },
      'rally': {'lat': 45.3, 'lng': 3.4, 'label': 'Parking du col', 'setBy': 'b', 'setByName': 'Bob', 'setAt': now.millisecondsSinceEpoch},
      'expenses': {
        'e1': Expense(id: '', label: 'Plein', amountCents: 6000, paidBy: 'a', participants: const ['a', 'b', 'c'], createdAt: now).toMap(),
        'e2': Expense(id: '', label: 'Resto', amountCents: 3000, paidBy: 'b', participants: const ['b', 'c'], category: ExpenseCategory.resto, createdAt: now.add(const Duration(hours: 1))).toMap(),
        'cassée': {'amount': 'beaucoup'},
      },
      'settlements': {
        's1': Settlement(id: '', from: 'c', to: 'a', amountCents: 1000, createdAt: now).toMap(),
      },
    });

    test('lecture complète', () {
      final g = Group.fromMap('ABCD2345', raw)!;
      expect(g.name, 'Les Virolos');
      expect(g.members.map((m) => m.name), ['Alice', 'Bob', 'Carol']);
      expect(g.member('c')!.colorValue, defaultColorFor('c'));
      expect(g.hasMember('b'), isTrue);
      expect(g.rally!.label, 'Parking du col');
      expect(g.rally!.setBy, 'Bob');
      expect(g.rally!.groupName, 'Les Virolos');
      expect(g.rally!.location, const GeoPoint(45.3, 3.4));
      expect(g.expenses.map((e) => e.label), ['Resto', 'Plein'], reason: 'plus récente d\'abord, la cassée ignorée');
      expect(g.settlements.single.amountCents, 1000);
    });

    test('soldes et virements du groupe', () {
      final g = Group.fromMap('ABCD2345', raw)!;
      // a : +6000 -2000 -1000(reçu) = +3000 ; b : -2000 +3000 -1500 = -500 ;
      // c : -2000 -1500 +1000 = -2500.
      expect(g.balances, {'a': 3000, 'b': -500, 'c': -2500});
      expect(g.transfers, unorderedEquals(const [
        Transfer(from: 'c', to: 'a', amountCents: 2500),
        Transfer(from: 'b', to: 'a', amountCents: 500),
      ]));
    });

    test('ancien membre conservé dans les comptes', () {
      final g = Group.fromMap('G', rtdb({
        'name': 'G',
        'createdBy': 'a',
        'members': {'a': {'name': 'Alice'}},
        'expenses': {'e': Expense(id: '', label: 'x', amountCents: 1000, paidBy: 'a', participants: const ['a', 'parti'], createdAt: now).toMap()},
      }))!;
      expect(g.balances, {'a': 500, 'parti': -500});
      expect(g.nameOf('parti'), 'Ancien membre');
    });

    test('point de regroupement : contenu écrit', () {
      final m = rallyToMap(at: const GeoPoint(1, 2), label: '  ', setByUid: 'u', setByName: 'Max', setAt: now);
      expect(m['label'], 'Regroupement');
      expect(m['setBy'], 'u');
    });
  });

  group('Liens de suivi', () {
    test('liste et expiration', () {
      final shares = sharesFromMap(rtdb({
        'tok1': now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        'tok2': now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
      }));
      expect(shares.map((s) => s.token), ['tok1', 'tok2']);
      expect(shares.first.isActive(now: now), isTrue);
      expect(shares.last.isActive(now: now), isFalse);
      expect(shares.first.remaining(now: now), const Duration(hours: 1));
      expect(shares.last.remaining(now: now), Duration.zero);
    });
  });

  group('Balades partagées', () {
    test('itinéraire : aller-retour via la base', () {
      final route = PlannedRoute(
        id: 'r1',
        name: 'Gorges du Tarn',
        createdAt: now,
        points: const [GeoPoint(44.3, 3.2), GeoPoint(44.35, 3.25), GeoPoint(44.4, 3.3)],
        style: RouteStyle.sinueux,
        waypoints: const [GeoPoint(44.3, 3.2)],
        distanceM: 123456,
        durationS: 7200,
        curvatureScore: 72,
        maneuvers: const [
          Maneuver(instruction: 'Tournez à droite', type: 'right', distanceAlongM: 120, location: GeoPoint(44.31, 3.21)),
        ],
        favorite: true,
      );
      final map = sharedRouteToMap(route, authorName: 'Alice', sharedAt: now);
      expect(map['favorite'], isFalse);
      final entry = sharedRouteFromMap('u1', 'r1', rtdb(map), authorName: 'Alice R')!;
      expect(entry.route.name, 'Gorges du Tarn');
      expect(entry.route.source, RouteSource.friend);
      expect(entry.route.author, 'Alice R');
      expect(entry.route.points.length, 3);
      expect(entry.route.points.last.lat, closeTo(44.4, 1e-6));
      expect(entry.route.maneuvers.single.instruction, 'Tournez à droite');
      expect(entry.route.style, RouteStyle.sinueux);
      expect(entry.sharedAt, now);
      expect(entry.authorUid, 'u1');
    });

    test('itinéraire corrompu ignoré', () {
      expect(sharedRouteFromMap('u', 'x', {'name': 'sans tracé'}), isNull);
    });

    test('balade enregistrée : aller-retour', () {
      final ride = Ride(
        id: 'ride1',
        name: 'Dimanche matin',
        startedAt: now,
        endedAt: now.add(const Duration(hours: 2)),
        stats: const RideStats(distanceM: 88000, movingTimeS: 5000, maxSpeedKmh: 131, maxLeanLeftDeg: 38, maxLeanRightDeg: 41, elevationGainM: 900),
        previewPolyline: Geo.encodePolyline(const [GeoPoint(45, 3), GeoPoint(45.1, 3.1)]),
      );
      final map = sharedRideToMap(ride, authorName: 'Alice', authorColor: 0xFFFACC15, sharedAt: now);
      final back = FriendRide.fromMap('u1', 'ride1', rtdb(map))!;
      expect(back.name, 'Dimanche matin');
      expect(back.distanceM, 88000);
      expect(back.maxLeanDeg, 41);
      expect(back.avgSpeedKmh, closeTo(88000 / 5000 * 3.6, 1e-9));
      expect(back.previewPoints.length, 2);
      expect(back.authorColorValue, 0xFFFACC15);
      expect(back.withAuthor('Alice R', 1).authorName, 'Alice R');
    });

    test('aperçu trop détaillé simplifié', () {
      final pts = [for (var i = 0; i < 3000; i++) GeoPoint(45 + i * 0.0003, 3 + (i.isEven ? 0.0001 : 0))];
      final ride = Ride(id: 'r', name: 'Long', startedAt: now, previewPolyline: Geo.encodePolyline(pts));
      final map = sharedRideToMap(ride, authorName: 'A', authorColor: 1, sharedAt: now);
      expect((map['previewPolyline'] as String).length, lessThanOrEqualTo(6000));
    });
  });

  group('Mises à jour multi-chemins', () {
    test('profil + réservation du code', () {
      const p = UserProfile(uid: 'u1', name: 'Max', colorValue: 1, code: 'K7PM2X');
      final u = SocialUpdates.createProfile(p);
      expect(u['friendCodes/K7PM2X'], 'u1');
      expect((u['users/u1/profile'] as Map)['code'], 'K7PM2X');
    });

    test('lien d\'amitié avec preuve', () {
      expect(SocialUpdates.linkFriends('me', 'him', code: 'K7PM2X'), {
        'friends/me/him': true,
        'friends/him/me': true,
        'friendProofs/him/me': {'code': 'K7PM2X'},
      });
      expect(SocialUpdates.linkFriends('me', 'him', groupId: 'ABCD2345')['friendProofs/him/me'], {'group': 'ABCD2345'});
      expect(SocialUpdates.unlinkFriends('me', 'him'), {'friends/me/him': null, 'friends/him/me': null});
    });

    test('groupes : créer, rejoindre, quitter', () {
      const me = UserProfile(uid: 'u1', name: 'Max', colorValue: 7);
      final c = SocialUpdates.createGroup('G1', ' Les Virolos ', me, now);
      expect((c['groups/G1'] as Map)['name'], 'Les Virolos');
      expect((c['groups/G1'] as Map)['createdBy'], 'u1');
      expect(c['userGroups/u1/G1'], isTrue);
      final j = SocialUpdates.joinGroup('G1', me, now);
      expect((j['groups/G1/members/u1'] as Map)['name'], 'Max');
      expect(SocialUpdates.leaveGroup('G1', 'u1'), {'groups/G1/members/u1': null, 'userGroups/u1/G1': null});
    });
  });

  test('utilitaires de lecture', () {
    expect(trueKeys(rtdb({'b': true, 'a': true, 'c': false})), ['a', 'b']);
    expect(trueKeys(null), isEmpty);
    expect(children(['x', null, 'y']).map((e) => e.key), ['0', '2']);
    expect(deepJson(<Object?, Object?>{'a': <Object?>[<Object?, Object?>{'b': 1}]}), {
      'a': [
        {'b': 1}
      ]
    });
    expect(asDouble(3), 3.0);
    expect(asInt(3.7), 3);
    expect(asTime(0), DateTime.utc(1970));
  });
}
