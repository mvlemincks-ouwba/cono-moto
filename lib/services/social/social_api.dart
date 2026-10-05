import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../core/location.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/ride.dart';
import '../../data/models/shared.dart';
import '../../features/social/expenses.dart';
import '../../features/social/social_models.dart';
import 'codes.dart';
import 'firebase_bootstrap.dart';

/// Erreur affichable telle quelle à l'utilisateur (en français).
class SocialException implements Exception {
  const SocialException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Accès à Firebase (Auth + Realtime Database) pour le module Potes.
///
/// Toute la structure de la base est décrite dans `firebase/README.md` et
/// protégée par `firebase/database.rules.json`.
class SocialApi {
  SocialApi._(this.auth, this.db);

  final FirebaseAuth auth;
  final FirebaseDatabase db;

  /// Null si Firebase n'est pas configuré / initialisé (mode solo).
  static SocialApi? create() {
    if (!FirebaseBootstrap.ready) return null;
    try {
      final app = Firebase.app();
      return SocialApi._(
        FirebaseAuth.instanceFor(app: app),
        FirebaseDatabase.instanceFor(app: app, databaseURL: AppConfig.firebaseDatabaseUrl),
      );
    } catch (e) {
      debugPrint('SocialApi indisponible : $e');
      return null;
    }
  }

  static const _ackTimeout = Duration(seconds: 12);

  DatabaseReference ref([String? path]) => db.ref(path);

  /// Clé RTDB valide (pas de . # $ [ ] /).
  static String safeKey(String id) => id.replaceAll(RegExp(r'[.#$\[\]/]'), '_');

  // -------------------------------------------------------------------------
  // Utilitaires
  // -------------------------------------------------------------------------

  /// Écoute un nœud et le convertit ; en cas d'erreur (droits retirés…),
  /// émet [fallback] au lieu de faire échouer l'interface.
  Stream<T> watch<T>(Query query, T Function(Object? raw) parse, T fallback) {
    return query.onValue.map((e) => parse(e.snapshot.value)).transform(
          StreamTransformer<T, T>.fromHandlers(
            handleError: (error, stack, sink) {
              debugPrint('Potes : lecture ${query.path} impossible : $error');
              sink.add(fallback);
            },
          ),
        );
  }

  /// Écrit et attend l'accusé de réception du serveur. Retourne false si le
  /// réseau ne répond pas à temps : l'écriture reste en file et partira
  /// dès que possible (le cache local est déjà à jour).
  Future<bool> _write(Future<void> Function() op) async {
    try {
      await op().timeout(_ackTimeout);
      return true;
    } on TimeoutException {
      return false;
    } on FirebaseException catch (e) {
      throw _friendly(e);
    }
  }

  static SocialException _friendly(FirebaseException e) {
    switch (e.code) {
      case 'permission-denied':
        return const SocialException(
            'Le serveur a refusé l\'opération. Vérifie que les règles de sécurité sont bien déployées.');
      case 'network-error':
      case 'disconnected':
      case 'unavailable':
        return const SocialException('Pas de réseau pour l\'instant. Réessaie dans un coin mieux couvert.');
      default:
        return SocialException('Erreur serveur (${e.code}). Réessaie dans un instant.');
    }
  }

  static bool _isDenied(Object e) => e is FirebaseException && e.code == 'permission-denied';

  // -------------------------------------------------------------------------
  // Authentification
  // -------------------------------------------------------------------------

  Stream<User?> authChanges() => auth.authStateChanges();

  User? get currentUser => auth.currentUser;

  Future<void> signIn(String email, String password) async {
    try {
      await auth.signInWithEmailAndPassword(email: email.trim(), password: password);
    } on FirebaseAuthException catch (e) {
      throw SocialException(authMessage(e.code));
    }
  }

  Future<User> signUp(String email, String password) async {
    try {
      final cred = await auth.createUserWithEmailAndPassword(email: email.trim(), password: password);
      return cred.user!;
    } on FirebaseAuthException catch (e) {
      throw SocialException(authMessage(e.code));
    }
  }

  Future<void> resetPassword(String email) async {
    try {
      await auth.setLanguageCode('fr');
      await auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw SocialException(authMessage(e.code));
    }
  }

  Future<void> signOut({String? uid}) async {
    if (uid != null) {
      // Je disparais proprement de la carte de mes potes.
      try {
        await ref('live/$uid').update({'riding': false, 'speed': 0}).timeout(const Duration(seconds: 4));
        await ref('live/$uid').onDisconnect().cancel().timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    await auth.signOut();
  }

  /// Messages d'erreur Firebase Auth en français.
  static String authMessage(String code) => switch (code) {
        'invalid-email' => 'Cette adresse e-mail ne ressemble à rien de connu.',
        'user-disabled' => 'Ce compte a été désactivé.',
        'user-not-found' || 'wrong-password' || 'invalid-credential' || 'INVALID_LOGIN_CREDENTIALS' =>
          'E-mail ou mot de passe incorrect.',
        'email-already-in-use' => 'Un compte existe déjà avec cet e-mail. Connecte-toi plutôt !',
        'weak-password' => 'Mot de passe trop faible : 6 caractères minimum.',
        'too-many-requests' => 'Trop de tentatives. Fais une pause café et réessaie dans quelques minutes.',
        'network-request-failed' => 'Pas de réseau. Vérifie ta connexion.',
        'operation-not-allowed' =>
          'La connexion par e-mail n\'est pas activée sur le projet Firebase (voir firebase/README.md).',
        'missing-email' => 'Indique ton adresse e-mail.',
        _ => 'Oups, erreur de connexion ($code).',
      };

  // -------------------------------------------------------------------------
  // Profil
  // -------------------------------------------------------------------------

  Stream<UserProfile?> profile(String uid) =>
      watch(ref('users/$uid/profile'), (raw) => UserProfile.fromMap(uid, raw), null);

  Future<UserProfile?> fetchProfile(String uid) async {
    final snap = await ref('users/$uid/profile').get();
    return UserProfile.fromMap(uid, snap.value);
  }

  /// Crée le profil et réserve un code ami unique.
  Future<UserProfile> createProfile({
    required String uid,
    required String name,
    required int colorValue,
    String bike = '',
  }) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final code = SocialCodes.newFriendCode();
      try {
        final existing = await ref('friendCodes/$code').get();
        if (existing.exists) continue;
        final profile = UserProfile(
          uid: uid,
          name: name.trim(),
          colorValue: colorValue,
          bike: bike.trim(),
          code: code,
          createdAt: DateTime.now().toUtc(),
        );
        await ref().update(SocialUpdates.createProfile(profile));
        return profile;
      } on FirebaseException catch (e) {
        if (!_isDenied(e)) throw _friendly(e);
        // Code pris entre-temps, ou jeton d'auth pas encore propagé juste
        // après l'inscription : on patiente un peu et on retente.
        await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
    throw const SocialException(
        'Impossible de créer ton profil. Vérifie que les règles de sécurité sont déployées, puis réessaie.');
  }

  /// Met à jour pseudo / couleur / moto, et recopie le nom et la couleur
  /// dans mes groupes.
  Future<bool> updateProfile(UserProfile p, {Iterable<String> groupIds = const []}) => _write(() async {
        await ref().update({
          'users/${p.uid}/profile/name': p.name.trim(),
          'users/${p.uid}/profile/color': p.colorValue,
          'users/${p.uid}/profile/bike': p.bike.trim(),
        });
        for (final gid in groupIds) {
          try {
            await ref('groups/$gid/members/${p.uid}').update({'name': p.name.trim(), 'color': p.colorValue});
          } catch (_) {}
        }
      });

  // -------------------------------------------------------------------------
  // Potes
  // -------------------------------------------------------------------------

  Stream<List<String>> friendIds(String uid) => watch(ref('friends/$uid'), trueKeys, const <String>[]);

  /// Ajoute un pote grâce à son code. Retourne son uid.
  Future<String> addFriendByCode(UserProfile me, String rawCode) async {
    final code = SocialCodes.normalize(rawCode);
    if (!SocialCodes.isValidFriendCode(code)) {
      throw const SocialException('Un code ami fait 6 caractères, sans 0, O, 1, I ni L (ex : K7PM2X).');
    }
    if (code == me.code) {
      throw const SocialException('C\'est ton propre code ! Demande plutôt celui de ton pote.');
    }
    final String? uid;
    try {
      uid = asString((await ref('friendCodes/$code').get()).value);
    } on FirebaseException catch (e) {
      throw _friendly(e);
    } catch (_) {
      throw const SocialException('Pas de réseau pour vérifier le code. Réessaie dans un instant.');
    }
    if (uid == null) throw const SocialException('Aucun motard avec ce code. Vérifie les caractères.');
    if (uid == me.uid) throw const SocialException('C\'est ton propre code !');
    await _write(() => ref().update(SocialUpdates.linkFriends(me.uid, uid!, code: code)));
    return uid;
  }

  Future<bool> removeFriend(String me, String friend) =>
      _write(() => ref().update(SocialUpdates.unlinkFriends(me, friend)));

  Stream<LiveState?> live(String uid) => watch(ref('live/$uid'), (raw) => LiveState.fromMap(uid, raw), null);

  // -------------------------------------------------------------------------
  // Position en direct
  // -------------------------------------------------------------------------

  Future<void> publishLive(String uid, Map<String, Object?> fields) => ref('live/$uid').update(fields);

  /// Si l'app perd la connexion (tuée, plus de réseau…), le serveur me marque
  /// automatiquement « plus en balade ».
  Future<void> armOfflineFlag(String uid) =>
      ref('live/$uid').onDisconnect().update({'riding': false, 'speed': 0});

  Future<void> cancelOfflineFlag(String uid) => ref('live/$uid').onDisconnect().cancel();

  // -------------------------------------------------------------------------
  // Signalements
  // -------------------------------------------------------------------------

  Stream<List<RoadReport>> reports(String uid) =>
      watch(ref('reports/$uid'), (raw) => reportsFromMap(uid, raw), const <RoadReport>[]);

  Future<bool> addReport(String uid, Map<String, Object?> report) =>
      _write(() => ref('reports/$uid').push().set(report));

  Future<bool> deleteReport(String uid, String id) => _write(() => ref('reports/$uid/$id').remove());

  /// Ménage : supprime mes signalements expirés.
  Future<void> purgeReports(String uid, Iterable<String> ids) async {
    final updates = {for (final id in ids) 'reports/$uid/$id': null};
    if (updates.isEmpty) return;
    try {
      await ref().update(updates);
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // Groupes
  // -------------------------------------------------------------------------

  Stream<List<String>> groupIds(String uid) => watch(ref('userGroups/$uid'), trueKeys, const <String>[]);

  /// Groupe en direct. Les instantanés partiels (juste après avoir rejoint,
  /// le cache local ne contient que mon entrée de membre) sont ignorés ;
  /// null = groupe supprimé ou accès retiré.
  Stream<Group?> group(String gid) => watch(
        ref('groups/$gid'),
        (raw) => raw == null ? const _Missing() : (Group.fromMap(gid, raw) ?? const _Partial()),
        const _Missing(),
      ).where((v) => v is! _Partial).map((v) => v is Group ? v : null);

  Future<String> createGroup(UserProfile me, String name) async {
    for (var attempt = 0; attempt < 6; attempt++) {
      final gid = SocialCodes.newGroupCode();
      try {
        await ref().update(SocialUpdates.createGroup(gid, name, me, DateTime.now().toUtc())).timeout(_ackTimeout);
        return gid;
      } on TimeoutException {
        throw const SocialException('Pas de réseau : impossible de créer le groupe pour l\'instant.');
      } on FirebaseException catch (e) {
        if (_isDenied(e)) continue; // code déjà pris (rarissime)
        throw _friendly(e);
      }
    }
    throw const SocialException('Impossible de créer le groupe. Réessaie dans un instant.');
  }

  /// Rejoint un groupe avec son code, puis devient pote avec ses membres
  /// (pour se voir sur la carte pendant les balades).
  Future<Group> joinGroup(UserProfile me, String rawCode) async {
    final gid = SocialCodes.normalize(rawCode);
    if (!SocialCodes.isValidGroupCode(gid)) {
      throw const SocialException('Un code de groupe fait 8 caractères (ex : ABCD-EFGH).');
    }
    try {
      await ref().update(SocialUpdates.joinGroup(gid, me, DateTime.now().toUtc())).timeout(_ackTimeout);
    } on TimeoutException {
      throw const SocialException('Pas de réseau : impossible de rejoindre le groupe pour l\'instant.');
    } on FirebaseException catch (e) {
      if (_isDenied(e)) throw const SocialException('Aucun groupe avec ce code. Vérifie auprès de tes potes.');
      throw _friendly(e);
    }
    final Group? g;
    try {
      g = Group.fromMap(gid, (await ref('groups/$gid').get()).value);
    } catch (_) {
      throw const SocialException('Groupe rejoint, mais impossible de le charger. Réessaie plus tard.');
    }
    if (g == null) throw const SocialException('Ce groupe n\'existe plus.');
    // Une mise à jour par membre : un profil incomplet chez l'un ne bloque
    // pas les autres liens.
    await Future.wait([
      for (final m in g.members)
        if (m.uid != me.uid)
          ref().update(SocialUpdates.linkFriends(me.uid, m.uid, groupId: gid)).timeout(_ackTimeout).catchError(
                (Object e) => debugPrint('Potes : lien avec ${m.name} impossible : $e'),
              ),
    ]);
    return g;
  }

  Future<bool> leaveGroup(String me, String gid) => _write(() => ref().update(SocialUpdates.leaveGroup(gid, me)));

  /// Supprime le groupe (réservé à son créateur).
  Future<bool> deleteGroup(String me, String gid) => _write(() async {
        await ref('groups/$gid').remove();
        await ref('userGroups/$me/$gid').remove();
      });

  /// Retire de mon index un groupe qui n'existe plus (après vérification
  /// auprès du serveur : hors ligne ou en cas de doute, on ne touche à rien).
  Future<void> forgetGroup(String me, String gid) async {
    try {
      final g = Group.fromMap(gid, (await ref('groups/$gid').get()).value);
      if (g != null && g.hasMember(me)) return;
    } on FirebaseException catch (e) {
      if (!_isDenied(e)) return;
    } catch (_) {
      return;
    }
    try {
      await ref('userGroups/$me/$gid').remove();
    } catch (_) {}
  }

  Future<bool> renameGroup(String gid, String name) => _write(() => ref('groups/$gid/name').set(name.trim()));

  Future<bool> setRally(String gid, Map<String, Object?> rally) => _write(() => ref('groups/$gid/rally').set(rally));

  Future<bool> clearRally(String gid) => _write(() => ref('groups/$gid/rally').remove());

  Future<bool> addExpense(String gid, Expense e) => _write(() => ref('groups/$gid/expenses').push().set(e.toMap()));

  Future<bool> deleteExpense(String gid, String id) => _write(() => ref('groups/$gid/expenses/$id').remove());

  Future<bool> addSettlement(String gid, Settlement s) =>
      _write(() => ref('groups/$gid/settlements').push().set(s.toMap()));

  Future<bool> deleteSettlement(String gid, String id) =>
      _write(() => ref('groups/$gid/settlements/$id').remove());

  // -------------------------------------------------------------------------
  // Lien de suivi web
  // -------------------------------------------------------------------------

  Stream<List<LiveShare>> myShares(String uid) => watch(ref('userShares/$uid'), sharesFromMap, const <LiveShare>[]);

  /// Crée un lien de suivi. Retourne le jeton.
  Future<String> createShare({
    required UserProfile me,
    required Duration duration,
    RiderPosition? position,
    bool riding = false,
  }) async {
    final token = SocialCodes.newShareToken();
    final now = DateTime.now().toUtc();
    final expires = now.add(duration).millisecondsSinceEpoch;
    final share = <String, Object?>{
      'uid': me.uid,
      'name': me.name,
      'color': me.colorValue,
      'createdAt': now.millisecondsSinceEpoch,
      'expiresAt': expires,
      'active': true,
      'riding': riding,
      'ts': ServerValue.timestamp,
      if (position != null) ...{
        'lat': position.point.lat,
        'lng': position.point.lng,
        'speed': double.parse(position.speedKmh.toStringAsFixed(1)),
        'heading': ?position.heading?.roundToDouble(),
      },
    };
    try {
      await ref().update({
        'shares/$token': share,
        'userShares/${me.uid}/$token': expires,
      }).timeout(_ackTimeout);
    } on TimeoutException {
      throw const SocialException('Pas de réseau : le lien ne peut pas être créé pour l\'instant.');
    } on FirebaseException catch (e) {
      throw _friendly(e);
    }
    return token;
  }

  Future<bool> stopShare(String uid, String token) => _write(() => ref().update({
        'shares/$token/active': false,
        'shares/$token/expiresAt': DateTime.now().toUtc().millisecondsSinceEpoch,
        'userShares/$uid/$token': null,
      }));

  /// Met à jour la position de plusieurs liens d'un coup.
  Future<void> updateShares(Iterable<String> tokens, Map<String, Object?> fields) {
    final updates = <String, Object?>{
      for (final t in tokens)
        for (final f in fields.entries) 'shares/$t/${f.key}': f.value,
    };
    if (updates.isEmpty) return Future.value();
    return ref().update(updates);
  }

  /// Ménage des liens expirés (désactivés et retirés de mon index).
  Future<void> purgeShares(String uid, Iterable<String> tokens) async {
    final updates = <String, Object?>{
      for (final t in tokens) ...{'shares/$t/active': false, 'userShares/$uid/$t': null},
    };
    if (updates.isEmpty) return;
    try {
      await ref().update(updates);
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // Balades partagées
  // -------------------------------------------------------------------------

  Future<bool> shareRoute(UserProfile me, PlannedRoute route) => _write(() => ref(
        'sharedRoutes/${me.uid}/${safeKey(route.id)}',
      ).set(sharedRouteToMap(route, authorName: me.name, sharedAt: DateTime.now().toUtc())));

  Future<bool> unshareRoute(String uid, String routeId) =>
      _write(() => ref('sharedRoutes/$uid/${safeKey(routeId)}').remove());

  Stream<List<SharedRouteEntry>> sharedRoutes(String uid) => watch(
        ref('sharedRoutes/$uid').orderByChild('sharedAt').limitToLast(25),
        (raw) => [for (final e in children(raw)) ?sharedRouteFromMap(uid, e.key, e.value)],
        const <SharedRouteEntry>[],
      );

  Future<bool> shareRide(UserProfile me, Ride ride) => _write(() => ref('sharedRides/${me.uid}/${safeKey(ride.id)}')
      .set(sharedRideToMap(ride, authorName: me.name, authorColor: me.colorValue, sharedAt: DateTime.now().toUtc())));

  Future<bool> unshareRide(String uid, String rideId) =>
      _write(() => ref('sharedRides/$uid/${safeKey(rideId)}').remove());

  Stream<List<FriendRide>> sharedRides(String uid) => watch(
        ref('sharedRides/$uid').orderByChild('sharedAt').limitToLast(25),
        (raw) => [for (final e in children(raw)) ?FriendRide.fromMap(uid, e.key, e.value)],
        const <FriendRide>[],
      );
}

/// Marqueurs internes pour [SocialApi.group].
class _Partial {
  const _Partial();
}

class _Missing {
  const _Missing();
}
