// Module « Potes » : état partagé (Riverpod). Les 5 premiers providers sont le
// contrat utilisé par la carte ; ne pas les renommer.
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/geo.dart';
import '../../core/location.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/ride.dart';
import '../../data/models/shared.dart';
import '../../services/social/social_api.dart';
import '../ride/ride_controller.dart';
import 'expenses.dart';
import 'social_models.dart';

export 'live_sync.dart' show liveSyncProvider, LiveSyncStatus;

// ===========================================================================
// Contrat (utilisé par la carte)
// ===========================================================================

/// Positions en direct des potes (hors moi) : positions de moins de 12 h,
/// SOS d'abord puis ceux qui roulent.
final friendsLiveProvider = StreamProvider<List<FriendLive>>((ref) {
  final friends = ref.watch(friendsProvider);
  return Stream.value(liveFriends(friends));
});

/// Signalements actifs des potes (et les miens), du plus récent au plus ancien.
/// La liste est re-filtrée chaque minute pour faire disparaître les expirés.
final roadReportsProvider = StreamProvider<List<RoadReport>>((ref) {
  final uid = ref.watch(myUidProvider);
  if (uid == null) return Stream.value(const []);
  final ids = [uid, ...ref.watch(friendIdsProvider).value ?? const <String>[]];
  final all = <RoadReport>[
    for (final id in ids) ...?ref.watch(userReportsProvider(id)).value,
  ];
  // Ménage discret de mes signalements expirés.
  final expiredMine = [
    for (final r in all)
      if (r.authorUid == uid && !reportIsActive(r)) r.id,
  ];
  if (expiredMine.isNotEmpty) {
    final api = ref.read(socialApiProvider);
    Future.microtask(() => api?.purgeReports(uid, expiredMine));
  }
  return _ticking(() => activeReports(all), const Duration(minutes: 1));
});

/// Points de regroupement des groupes dont je fais partie (définis il y a
/// moins de [rallyMaxAge]).
final rallyPointsProvider = StreamProvider<List<RallyPoint>>((ref) {
  final groups = ref.watch(myGroupsProvider);
  final now = DateTime.now().toUtc();
  return Stream.value([
    for (final g in groups)
      if (g.rally != null && now.difference(g.rally!.setAt.toUtc()) < rallyMaxAge) g.rally!,
  ]);
});

/// Balades planifiées partagées par les potes (source = friend, author = pseudo du pote).
final friendsRoutesProvider = StreamProvider<List<PlannedRoute>>((ref) {
  final entries = ref.watch(friendsRouteEntriesProvider);
  return Stream.value([for (final e in entries) e.route]);
});

/// Suis-je connecté au service entre potes (Firebase) ?
final socialSignedInProvider = Provider<bool>((ref) => ref.watch(myUidProvider) != null);

// ===========================================================================
// Socle Firebase / authentification
// ===========================================================================

/// Durée pendant laquelle un point de regroupement reste affiché sur la carte.
const rallyMaxAge = Duration(days: 3);

/// API Firebase ; null en mode solo (Firebase non configuré).
final socialApiProvider = Provider<SocialApi?>((ref) => SocialApi.create());

/// Firebase disponible dans ce build ?
final socialAvailableProvider = Provider<bool>((ref) => ref.watch(socialApiProvider) != null);

/// Utilisateur Firebase connecté.
final authUserProvider = StreamProvider<User?>((ref) {
  final api = ref.watch(socialApiProvider);
  if (api == null) return Stream.value(null);
  return api.authChanges();
});

/// Mon uid (null si déconnecté).
final myUidProvider = Provider<String?>((ref) => ref.watch(authUserProvider).value?.uid);

/// Profil public d'un utilisateur.
final userProfileProvider = StreamProvider.autoDispose.family<UserProfile?, String>((ref, uid) {
  final api = ref.watch(socialApiProvider);
  if (api == null) return Stream.value(null);
  return api.profile(uid);
});

/// Mon profil (null tant qu'il n'est pas créé).
final myProfileProvider = StreamProvider<UserProfile?>((ref) {
  final api = ref.watch(socialApiProvider);
  final uid = ref.watch(myUidProvider);
  if (api == null || uid == null) return Stream.value(null);
  return api.profile(uid);
});

// ===========================================================================
// Potes
// ===========================================================================

final friendIdsProvider = StreamProvider<List<String>>((ref) {
  final api = ref.watch(socialApiProvider);
  final uid = ref.watch(myUidProvider);
  if (api == null || uid == null) return Stream.value(const []);
  return api.friendIds(uid);
});

final liveStateProvider = StreamProvider.autoDispose.family<LiveState?, String>((ref, uid) {
  final api = ref.watch(socialApiProvider);
  if (api == null) return Stream.value(null);
  return api.live(uid);
});

/// Mes potes avec profil et dernière position, triés par pseudo.
final friendsProvider = Provider<List<Friend>>((ref) {
  final ids = ref.watch(friendIdsProvider).value ?? const <String>[];
  final list = [
    for (final id in ids)
      Friend(
        uid: id,
        profile: ref.watch(userProfileProvider(id)).value,
        live: ref.watch(liveStateProvider(id)).value,
      ),
  ];
  list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
});

/// Pseudo et couleur des potes (ne change que si un profil change).
final friendNamesProvider = Provider<Map<String, UserProfile?>>((ref) {
  final ids = ref.watch(friendIdsProvider).value ?? const <String>[];
  return {for (final id in ids) id: ref.watch(userProfileProvider(id)).value};
});

// ===========================================================================
// Signalements
// ===========================================================================

final userReportsProvider = StreamProvider.autoDispose.family<List<RoadReport>, String>((ref, uid) {
  final api = ref.watch(socialApiProvider);
  if (api == null) return Stream.value(const []);
  return api.reports(uid);
});

/// Mes signalements encore actifs.
final myReportsProvider = Provider<List<RoadReport>>((ref) {
  final uid = ref.watch(myUidProvider);
  if (uid == null) return const [];
  return activeReports(ref.watch(userReportsProvider(uid)).value ?? const []);
});

// ===========================================================================
// Groupes
// ===========================================================================

final myGroupIdsProvider = StreamProvider<List<String>>((ref) {
  final api = ref.watch(socialApiProvider);
  final uid = ref.watch(myUidProvider);
  if (api == null || uid == null) return Stream.value(const []);
  return api.groupIds(uid);
});

final groupProvider = StreamProvider.autoDispose.family<Group?, String>((ref, gid) {
  final api = ref.watch(socialApiProvider);
  if (api == null) return Stream.value(null);
  return api.group(gid);
});

final _forgetting = <String>{};

/// Mes groupes (ceux qui existent encore et dont je suis membre).
final myGroupsProvider = Provider<List<Group>>((ref) {
  final uid = ref.watch(myUidProvider);
  final ids = ref.watch(myGroupIdsProvider).value ?? const <String>[];
  final out = <Group>[];
  final gone = <String>[];
  for (final id in ids) {
    final v = ref.watch(groupProvider(id));
    final g = v.value;
    if (g != null && uid != null && g.hasMember(uid)) {
      out.add(g);
    } else if (v is AsyncData<Group?> && g == null) {
      gone.add(id);
    }
  }
  final toForget = gone.where(_forgetting.add).toList();
  if (toForget.isNotEmpty && uid != null) {
    final api = ref.read(socialApiProvider);
    Future.microtask(() async {
      for (final gid in toForget) {
        try {
          await api?.forgetGroup(uid, gid);
        } finally {
          _forgetting.remove(gid);
        }
      }
    });
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
});

// ===========================================================================
// Lien de suivi web
// ===========================================================================

/// Mes liens de suivi (actifs ou non expirés).
final mySharesProvider = StreamProvider<List<LiveShare>>((ref) {
  final api = ref.watch(socialApiProvider);
  final uid = ref.watch(myUidProvider);
  if (api == null || uid == null) return Stream.value(const []);
  return api.myShares(uid);
});

// ===========================================================================
// Balades partagées
// ===========================================================================

final userSharedRoutesProvider = StreamProvider.autoDispose.family<List<SharedRouteEntry>, String>((ref, uid) {
  final api = ref.watch(socialApiProvider);
  if (api == null) return Stream.value(const []);
  return api.sharedRoutes(uid);
});

final userSharedRidesProvider = StreamProvider.autoDispose.family<List<FriendRide>, String>((ref, uid) {
  final api = ref.watch(socialApiProvider);
  if (api == null) return Stream.value(const []);
  return api.sharedRides(uid);
});

/// Balades planifiées des potes, de la plus récemment partagée à la plus ancienne.
final friendsRouteEntriesProvider = Provider<List<SharedRouteEntry>>((ref) {
  final names = ref.watch(friendNamesProvider);
  final out = <SharedRouteEntry>[
    for (final e in names.entries)
      for (final s in ref.watch(userSharedRoutesProvider(e.key)).value ?? const <SharedRouteEntry>[])
        SharedRouteEntry(
          authorUid: e.key,
          route: asFriendRoute(s.route, author: e.value?.name ?? s.route.author ?? 'Un pote'),
          sharedAt: s.sharedAt,
        ),
  ];
  out.sort((a, b) => b.sharedAt.compareTo(a.sharedAt));
  return out;
});

/// Balades enregistrées partagées par les potes.
final friendsRidesProvider = Provider<List<FriendRide>>((ref) {
  final names = ref.watch(friendNamesProvider);
  final out = <FriendRide>[
    for (final e in names.entries)
      for (final r in ref.watch(userSharedRidesProvider(e.key)).value ?? const <FriendRide>[])
        e.value == null ? r : r.withAuthor(e.value!.name, e.value!.colorValue),
  ];
  out.sort((a, b) => b.sharedAt.compareTo(a.sharedAt));
  return out;
});

/// Élément du fil « Dernières balades des potes ».
sealed class FeedItem {
  const FeedItem();
  DateTime get at;
}

class FeedRoute extends FeedItem {
  const FeedRoute(this.entry);
  final SharedRouteEntry entry;
  @override
  DateTime get at => entry.sharedAt;
}

class FeedRide extends FeedItem {
  const FeedRide(this.ride);
  final FriendRide ride;
  @override
  DateTime get at => ride.sharedAt;
}

final friendsFeedProvider = Provider<List<FeedItem>>((ref) {
  final items = <FeedItem>[
    for (final e in ref.watch(friendsRouteEntriesProvider)) FeedRoute(e),
    for (final r in ref.watch(friendsRidesProvider)) FeedRide(r),
  ]..sort((a, b) => b.at.compareTo(a.at));
  return items.take(30).toList();
});

// ===========================================================================
// Ma position (pour les distances affichées)
// ===========================================================================

/// Position ponctuelle SANS demander la permission (l'onglet Potes est
/// construit au démarrage : on ne veut pas doubler la demande de la carte).
final _oneShotPositionProvider = FutureProvider<GeoPoint?>((ref) async {
  try {
    final perm = await Geolocator.checkPermission();
    if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) return null;
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) return GeoPoint(last.latitude, last.longitude);
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 15)),
    );
    return GeoPoint(p.latitude, p.longitude);
  } catch (_) {
    return null;
  }
});

/// Ma position approximative (arrondie à ~100 m pour limiter les rafraîchissements).
final myPositionProvider = Provider<GeoPoint?>((ref) {
  final hub = ref.watch(positionHubProvider.select((p) => p == null
      ? null
      : GeoPoint((p.point.lat * 1000).roundToDouble() / 1000, (p.point.lng * 1000).roundToDouble() / 1000)));
  if (hub != null) return hub;
  return ref.watch(_oneShotPositionProvider).value;
});

// ===========================================================================
// Actions
// ===========================================================================

/// Actions utilisateur du module Potes (lèvent [SocialException] avec un
/// message en français en cas de problème).
class SocialActions {
  SocialActions(this._ref);

  final Ref _ref;

  SocialApi get api =>
      _ref.read(socialApiProvider) ??
      (throw const SocialException('Mode solo : les fonctions entre potes ne sont pas configurées.'));

  String get uid =>
      _ref.read(myUidProvider) ?? (throw const SocialException('Connecte-toi d\'abord dans l\'onglet Potes.'));

  UserProfile get me =>
      _ref.read(myProfileProvider).value ??
      (throw const SocialException('Termine ton profil dans l\'onglet Potes avant de continuer.'));

  Future<void> signIn(String email, String password) => api.signIn(email, password);

  Future<void> signUp({required String email, required String password, required String name, String bike = ''}) async {
    final user = await api.signUp(email, password);
    final palette = defaultColorFor(user.uid);
    await api.createProfile(uid: user.uid, name: name, colorValue: palette, bike: bike);
  }

  Future<void> resetPassword(String email) => api.resetPassword(email);

  Future<void> signOut() => api.signOut(uid: _ref.read(myUidProvider));

  Future<UserProfile> createProfile({required String name, required int colorValue, String bike = ''}) =>
      api.createProfile(uid: uid, name: name, colorValue: colorValue, bike: bike);

  Future<bool> updateProfile(UserProfile p) =>
      api.updateProfile(p, groupIds: _ref.read(myGroupIdsProvider).value ?? const []);

  Future<String> addFriend(String code) => api.addFriendByCode(me, code);

  Future<bool> removeFriend(String friendUid) => api.removeFriend(uid, friendUid);

  Future<bool> addReport({
    required ReportType type,
    required GeoPoint at,
    String comment = '',
    Duration? lifetime,
  }) {
    final profile = me;
    return api.addReport(
      profile.uid,
      reportToMap(
        type: type,
        at: at,
        comment: comment,
        createdAt: DateTime.now().toUtc(),
        lifetime: lifetime ?? defaultReportLifetime(type),
        authorName: profile.name,
      ),
    );
  }

  Future<bool> deleteReport(String id) => api.deleteReport(uid, id);

  Future<String> createGroup(String name) => api.createGroup(me, name);

  Future<Group> joinGroup(String code) => api.joinGroup(me, code);

  Future<bool> leaveGroup(String gid) => api.leaveGroup(uid, gid);

  Future<bool> deleteGroup(String gid) => api.deleteGroup(uid, gid);

  Future<bool> renameGroup(String gid, String name) => api.renameGroup(gid, name);

  Future<bool> setRally(String gid, GeoPoint at, String label) {
    final profile = me;
    return api.setRally(
      gid,
      rallyToMap(
        at: at,
        label: label,
        setByUid: profile.uid,
        setByName: profile.name,
        setAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<bool> clearRally(String gid) => api.clearRally(gid);

  Future<bool> addExpense(
    String gid, {
    required String label,
    required int amountCents,
    required String paidBy,
    required List<String> participants,
    required ExpenseCategory category,
  }) =>
      api.addExpense(
        gid,
        Expense(
          id: '',
          label: label.trim().isEmpty ? category.label : label.trim(),
          amountCents: amountCents,
          paidBy: paidBy,
          participants: participants,
          category: category,
          createdAt: DateTime.now().toUtc(),
          createdBy: uid,
        ),
      );

  Future<bool> deleteExpense(String gid, String id) => api.deleteExpense(gid, id);

  Future<bool> settle(String gid, Transfer t) => api.addSettlement(
        gid,
        Settlement(
          id: '',
          from: t.from,
          to: t.to,
          amountCents: t.amountCents,
          createdAt: DateTime.now().toUtc(),
          createdBy: uid,
        ),
      );

  Future<bool> deleteSettlement(String gid, String id) => api.deleteSettlement(gid, id);

  Future<String> createShare(Duration duration) async {
    var pos = _ref.read(positionHubProvider);
    if (pos == null || DateTime.now().toUtc().difference(pos.time.toUtc()) > const Duration(minutes: 5)) {
      pos = await _ref.read(locationServiceProvider).current() ?? pos;
    }
    final status = _ref.read(rideControllerProvider).status;
    return api.createShare(
      me: me,
      duration: duration,
      position: pos,
      riding: status == RideStatus.recording || status == RideStatus.paused,
    );
  }

  Future<bool> stopShare(String token) => api.stopShare(uid, token);

  Future<bool> shareRoute(PlannedRoute route) => api.shareRoute(me, route);

  Future<bool> unshareRoute(String routeId) => api.unshareRoute(uid, routeId);

  Future<bool> shareRide(Ride ride) => api.shareRide(me, ride);

  Future<bool> unshareRide(String rideId) => api.unshareRide(uid, rideId);
}

final socialActionsProvider = Provider<SocialActions>((ref) => SocialActions(ref));

// ===========================================================================
// Utilitaires
// ===========================================================================

/// Émet [compute()] tout de suite puis à intervalle régulier.
Stream<T> _ticking<T>(T Function() compute, Duration every) async* {
  while (true) {
    yield compute();
    await Future<void>.delayed(every);
  }
}
