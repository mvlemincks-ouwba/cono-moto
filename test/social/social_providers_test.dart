import 'dart:async';

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/location.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/data/models/shared.dart';
import 'package:cono_moto/features/ride/ride_controller.dart';
import 'package:cono_moto/features/social/social_models.dart';
import 'package:cono_moto/features/social/social_providers.dart';
import 'package:cono_moto/features/social/live_sync.dart';
import 'package:cono_moto/services/social/social_api.dart';
import 'package:cono_moto/services/social/sos.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Laisse les flux et les microtâches se propager.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Recording extends RideController {
  @override
  RideSessionState build() => const RideSessionState(status: RideStatus.recording);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.now().toUtc();

  LiveState live(String uid, GeoPoint at, {bool riding = true, Duration age = Duration.zero, bool sos = false}) =>
      LiveState(uid: uid, location: at, updatedAt: now.subtract(age), riding: riding, speedKmh: 80, sos: sos);

  group('Mode solo (Firebase non configuré)', () {
    test('tout est vide et rien ne casse', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(socialAvailableProvider), isFalse);
      expect(c.read(socialSignedInProvider), isFalse);
      // Comme la carte : on écoute les providers du contrat.
      for (final p in [friendsLiveProvider, roadReportsProvider, rallyPointsProvider, friendsRoutesProvider]) {
        c.listen(p, (_, _) {});
      }
      await settle();
      expect(c.read(friendsLiveProvider).value, isEmpty);
      expect(c.read(roadReportsProvider).value, isEmpty);
      expect(c.read(rallyPointsProvider).value, isEmpty);
      expect(c.read(friendsRoutesProvider).value, isEmpty);
      // Le service de position (watché par la carte) démarre sans erreur.
      c.listen(liveSyncProvider, (_, _) {});
      expect(c.read(liveSyncProvider).signedIn, isFalse);
      // SOS : on ne prétend pas avoir prévenu les potes.
      final sos = c.read(sosBroadcasterProvider);
      await expectLater(sos.broadcast(const GeoPoint(45, 3), 'test'), throwsA(isA<SocialException>()));
      await sos.cancel();
    });
  });

  group('Contrat de la carte', () {
    test('friendsLiveProvider : potes avec position récente, profil prioritaire', () async {
      final c = ProviderContainer(overrides: [
        myUidProvider.overrideWithValue('me'),
        friendIdsProvider.overrideWith((ref) => Stream.value(['a', 'b', 'c'])),
        userProfileProvider.overrideWith((ref, uid) => Stream.value(
              UserProfile(uid: uid, name: 'Pote ${uid.toUpperCase()}', colorValue: 0xFF34D399),
            )),
        liveStateProvider.overrideWith((ref, uid) => Stream.value(switch (uid) {
              'a' => live('a', const GeoPoint(45, 3)),
              'b' => live('b', const GeoPoint(45, 3), age: const Duration(hours: 13)),
              _ => null,
            })),
      ]);
      addTearDown(c.dispose);
      c.listen(friendsLiveProvider, (_, _) {});
      await settle();
      final list = c.read(friendsLiveProvider).value!;
      expect(list.map((f) => f.uid), ['a']);
      expect(list.single.name, 'Pote A');
      expect(list.single.colorValue, 0xFF34D399);
      expect(c.read(friendsProvider).length, 3, reason: 'la liste des potes garde tout le monde');
    });

    test('roadReportsProvider : les miens + ceux des potes, non expirés', () async {
      RoadReport r(String id, String author, {Duration? left, Duration ago = Duration.zero}) => RoadReport(
            id: id,
            type: ReportType.gravillons,
            location: const GeoPoint(45, 3),
            createdAt: now.subtract(ago),
            authorUid: author,
            authorName: author,
            expiresAt: left == null ? null : now.add(left),
          );
      final c = ProviderContainer(overrides: [
        myUidProvider.overrideWithValue('me'),
        friendIdsProvider.overrideWith((ref) => Stream.value(['a'])),
        userReportsProvider.overrideWith((ref, uid) => Stream.value(switch (uid) {
              'me' => [r('m1', 'me', left: const Duration(hours: 1), ago: const Duration(minutes: 5))],
              'a' => [
                  r('a1', 'a', left: const Duration(days: 2)),
                  r('a2', 'a', left: const Duration(minutes: -1)),
                ],
              _ => <RoadReport>[],
            })),
      ]);
      addTearDown(c.dispose);
      c.listen(roadReportsProvider, (_, _) {});
      await settle();
      expect(c.read(roadReportsProvider).value!.map((x) => x.id), ['a1', 'm1']);
      expect(c.read(myReportsProvider).map((x) => x.id), ['m1']);
    });

    test('rallyPointsProvider et myGroupsProvider', () async {
      Group g(String id, {DateTime? rallyAt, bool withMe = true}) => Group(
            id: id,
            name: 'Groupe $id',
            createdBy: 'me',
            members: [
              if (withMe) const GroupMember(uid: 'me', name: 'Moi', colorValue: 1),
              const GroupMember(uid: 'a', name: 'A', colorValue: 1),
            ],
            rally: rallyAt == null
                ? null
                : RallyPoint(
                    groupId: id,
                    groupName: 'Groupe $id',
                    location: const GeoPoint(45, 3),
                    label: 'Col',
                    setBy: 'A',
                    setAt: rallyAt,
                  ),
          );
      final c = ProviderContainer(overrides: [
        myUidProvider.overrideWithValue('me'),
        myGroupIdsProvider.overrideWith((ref) => Stream.value(['G1', 'G2', 'G3', 'G4'])),
        groupProvider.overrideWith((ref, gid) => Stream.value(switch (gid) {
              'G1' => g('G1', rallyAt: now.subtract(const Duration(hours: 2))),
              'G2' => g('G2', rallyAt: now.subtract(const Duration(days: 5))),
              'G3' => g('G3', rallyAt: now, withMe: false),
              _ => null,
            })),
      ]);
      addTearDown(c.dispose);
      c.listen(rallyPointsProvider, (_, _) {});
      await settle();
      expect(c.read(myGroupsProvider).map((x) => x.id), ['G1', 'G2']);
      final rallies = c.read(rallyPointsProvider).value!;
      expect(rallies.map((x) => x.groupId), ['G1'], reason: 'G2 trop vieux, G3 sans moi');
    });

    test('friendsRoutesProvider : auteur = pseudo du pote, plus récent d\'abord', () async {
      SharedRouteEntry e(String id, String author, DateTime at) => SharedRouteEntry(
            authorUid: author,
            sharedAt: at,
            route: PlannedRoute(
              id: id,
              name: 'Balade $id',
              createdAt: at,
              points: const [GeoPoint(45, 3), GeoPoint(45.1, 3.1)],
              author: 'ancien nom',
            ),
          );
      final c = ProviderContainer(overrides: [
        myUidProvider.overrideWithValue('me'),
        friendIdsProvider.overrideWith((ref) => Stream.value(['a', 'b'])),
        userProfileProvider.overrideWith((ref, uid) => Stream.value(UserProfile(uid: uid, name: 'Pote $uid', colorValue: 1))),
        userSharedRoutesProvider.overrideWith((ref, uid) => Stream.value(switch (uid) {
              'a' => [e('r1', 'a', now.subtract(const Duration(days: 1)))],
              'b' => [e('r2', 'b', now)],
              _ => <SharedRouteEntry>[],
            })),
      ]);
      addTearDown(c.dispose);
      c.listen(friendsRoutesProvider, (_, _) {});
      await settle();
      final routes = c.read(friendsRoutesProvider).value!;
      expect(routes.map((r) => r.id), ['r2', 'r1']);
      expect(routes.map((r) => r.author), ['Pote b', 'Pote a']);
      expect(routes.every((r) => r.source == RouteSource.friend), isTrue);
      expect(c.read(friendsFeedProvider).length, 2);
    });
  });

  group('Alerte « pote qui décroche »', () {
    test('détecte un membre de groupe trop loin pendant la balade', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final liveCtrl = StreamController<LiveState?>.broadcast();
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        rideControllerProvider.overrideWith(_Recording.new),
        myUidProvider.overrideWithValue('me'),
        friendIdsProvider.overrideWith((ref) => Stream.value(['max'])),
        userProfileProvider.overrideWith((ref, uid) => Stream.value(UserProfile(uid: uid, name: 'Max', colorValue: 1))),
        liveStateProvider.overrideWith((ref, uid) => liveCtrl.stream),
        myGroupIdsProvider.overrideWith((ref) => Stream.value(['G1'])),
        groupProvider.overrideWith((ref, gid) => Stream.value(const Group(
              id: 'G1',
              name: 'Les Virolos',
              createdBy: 'me',
              members: [
                GroupMember(uid: 'me', name: 'Moi', colorValue: 1),
                GroupMember(uid: 'max', name: 'Max', colorValue: 1),
              ],
            ))),
      ]);
      addTearDown(() {
        c.dispose();
        liveCtrl.close();
      });
      c.listen(stragglerWatcherProvider, (_, _) {});
      await settle();
      const me = GeoPoint(45, 3);
      c.read(positionHubProvider.notifier).publish(RiderPosition(point: me, time: now));
      liveCtrl.add(live('max', Geo.destination(me, 180, 1000)));
      await settle();
      expect(c.read(stragglerWatcherProvider).alerted, isEmpty);
      liveCtrl.add(live('max', Geo.destination(me, 180, 4500)));
      await settle();
      expect(c.read(stragglerWatcherProvider).alerted, {'max'});
      liveCtrl.add(live('max', Geo.destination(me, 180, 1000)));
      await settle();
      expect(c.read(stragglerWatcherProvider).alerted, isEmpty, reason: 'revenu dans le groupe : réarmé');
    });
  });

  test('statut du partage : égalité de valeur', () {
    expect(const LiveSyncStatus(signedIn: true), const LiveSyncStatus(signedIn: true));
    expect(const LiveSyncStatus(signedIn: true).copyWith(activeLinks: 2).activeLinks, 2);
  });
}
