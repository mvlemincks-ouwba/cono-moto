import 'dart:async';

import 'package:firebase_database/firebase_database.dart' show ServerValue;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/location.dart';
import '../../core/notifications.dart';
import '../../core/settings.dart';
import '../../services/social/live_throttle.dart';
import '../../services/social/social_api.dart';
import '../ride/ride_controller.dart';
import 'social_models.dart';
import 'social_providers.dart';
import 'straggler.dart';

/// État du partage de position en direct.
@immutable
class LiveSyncStatus {
  const LiveSyncStatus({
    this.signedIn = false,
    this.sharingWithFriends = false,
    this.activeLinks = 0,
  });

  final bool signedIn;

  /// Je suis visible par mes potes en ce moment (balade + partage activé).
  final bool sharingWithFriends;

  /// Nombre de liens de suivi web actifs.
  final int activeLinks;

  LiveSyncStatus copyWith({bool? sharingWithFriends, int? activeLinks}) => LiveSyncStatus(
        signedIn: signedIn,
        sharingWithFriends: sharingWithFriends ?? this.sharingWithFriends,
        activeLinks: activeLinks ?? this.activeLinks,
      );

  @override
  bool operator ==(Object other) =>
      other is LiveSyncStatus &&
      other.signedIn == signedIn &&
      other.sharingWithFriends == sharingWithFriends &&
      other.activeLinks == activeLinks;

  @override
  int get hashCode => Object.hash(signedIn, sharingWithFriends, activeLinks);
}

/// Service « toujours actif » du module Potes. À watcher depuis la carte :
/// `ref.watch(liveSyncProvider);`
///
/// - publie live/{uid} pendant la balade (si le partage est activé dans les
///   réglages), au plus toutes les 5 s ou tous les 50 m ;
/// - met `riding=false` à la fin de la balade (et automatiquement en cas de
///   perte de connexion via onDisconnect) ;
/// - met à jour les liens de suivi web actifs ;
/// - surveille les potes qui décrochent et les SOS des potes (notifications).
final liveSyncProvider = NotifierProvider<LiveSync, LiveSyncStatus>(LiveSync.new);

class LiveSync extends Notifier<LiveSyncStatus> {
  _LiveEngine? _engine;

  @override
  LiveSyncStatus build() {
    // Les veilleurs vivent tant que le service vit.
    ref.watch(stragglerWatcherProvider);
    ref.watch(friendsSosWatcherProvider);

    final api = ref.watch(socialApiProvider);
    final uid = ref.watch(myUidProvider);
    _engine?.dispose();
    _engine = null;
    if (api == null || uid == null) return const LiveSyncStatus();

    final engine = _LiveEngine(api, uid, onStatus: (s) {
      if (ref.mounted) state = s;
    });
    _engine = engine;
    ref.onDispose(engine.dispose);

    ref.listen(myProfileProvider, (_, next) => engine.profile = next.value, fireImmediately: true);
    ref.listen(mySharesProvider, (_, next) => engine.setShares(next.value ?? const []), fireImmediately: true);
    ref.listen(
      settingsProvider.select((s) => s.shareLiveWithFriends),
      (_, next) => engine.setSharingAllowed(next),
      fireImmediately: true,
    );
    ref.listen(
      rideControllerProvider.select((s) => s.status),
      (_, next) => engine.setRideStatus(next),
      fireImmediately: true,
    );
    ref.listen(positionHubProvider, (_, next) => engine.onPosition(next), fireImmediately: true);

    return const LiveSyncStatus(signedIn: true);
  }
}

class _LiveEngine {
  _LiveEngine(this.api, this.uid, {required this.onStatus});

  final SocialApi api;
  final String uid;
  final void Function(LiveSyncStatus) onStatus;

  UserProfile? profile;
  final _friendsThrottle = LiveThrottle();
  final _sharesThrottle = LiveThrottle();
  final _trail = TrailBuffer();
  DateTime? _lastTrailSent;

  bool _sharingAllowed = true;
  RideStatus _status = RideStatus.idle;
  bool _live = false;
  List<LiveShare> _shares = const [];
  RiderPosition? _lastPosition;
  bool _disposed = false;
  var _status$ = const LiveSyncStatus(signedIn: true);

  bool get _rideActive => _status == RideStatus.recording || _status == RideStatus.paused;

  List<String> get _activeTokens => [
        for (final s in _shares)
          if (s.isActive()) s.token,
      ];

  void _emit(LiveSyncStatus s) {
    _status$ = s;
    // Jamais pendant le build du provider.
    scheduleMicrotask(() {
      if (!_disposed) onStatus(_status$);
    });
  }

  void setSharingAllowed(bool v) {
    _sharingAllowed = v;
    _refreshLive();
  }

  void setRideStatus(RideStatus s) {
    final wasActive = _rideActive;
    _status = s;
    if (wasActive && !_rideActive) {
      _trail.clear();
    }
    final tokens = _activeTokens;
    if (wasActive != _rideActive && tokens.isNotEmpty) {
      _safe(api.updateShares(tokens, {'riding': _rideActive, 'ts': ServerValue.timestamp}));
    }
    _refreshLive();
  }

  void setShares(List<LiveShare> shares) {
    _shares = shares;
    final expired = [
      for (final s in shares)
        if (!s.isActive()) s.token,
    ];
    if (expired.isNotEmpty) unawaited(api.purgeShares(uid, expired));
    _emit(_status$.copyWith(activeLinks: _activeTokens.length));
  }

  /// Passe en mode « visible par mes potes » ou en sort.
  void _refreshLive() {
    final shouldBeLive = _rideActive && _sharingAllowed;
    if (shouldBeLive == _live) return;
    _live = shouldBeLive;
    _friendsThrottle.reset();
    if (shouldBeLive) {
      _safe(api.armOfflineFlag(uid));
      final p = _lastPosition;
      if (p != null) onPosition(p);
    } else {
      _safe(api.publishLive(uid, {'riding': false, 'speed': 0, 'ts': ServerValue.timestamp}));
      _safe(api.cancelOfflineFlag(uid));
    }
    _emit(_status$.copyWith(sharingWithFriends: shouldBeLive));
  }

  void onPosition(RiderPosition? pos) {
    if (pos == null || _disposed) return;
    if (!pos.point.lat.isFinite || !pos.point.lng.isFinite) return;
    _lastPosition = pos;
    final now = DateTime.now().toUtc();
    // Position trop vieille (GPS figé) : on ne la republie pas.
    if (now.difference(pos.time.toUtc()) > const Duration(minutes: 2)) return;
    final p = profile;

    if (_live && _friendsThrottle.check(pos.point, now)) {
      _safe(api.publishLive(uid, {
        'lat': _round(pos.point.lat, 6),
        'lng': _round(pos.point.lng, 6),
        'speed': _round(pos.speedKmh, 1),
        'heading': ?(pos.heading == null ? null : _round(pos.heading!, 0)),
        'lean': _round(pos.leanDeg, 0),
        'ts': ServerValue.timestamp,
        'riding': true,
        if (p != null) ...{'name': p.name, 'color': p.colorValue, 'bike': p.bike},
      }));
    }

    final tokens = _activeTokens;
    if (tokens.isNotEmpty && _sharesThrottle.check(pos.point, now)) {
      _trail.add(pos.point, now);
      final sendTrail = _lastTrailSent == null || now.difference(_lastTrailSent!) > const Duration(seconds: 60);
      if (sendTrail) _lastTrailSent = now;
      _safe(api.updateShares(tokens, {
        'lat': _round(pos.point.lat, 6),
        'lng': _round(pos.point.lng, 6),
        'speed': _round(pos.speedKmh, 1),
        'heading': pos.heading == null ? null : _round(pos.heading!, 0),
        'riding': _rideActive,
        'ts': ServerValue.timestamp,
        if (sendTrail) 'trail': _trail.encode(),
      }));
    }
  }

  /// Arrondi (moins d'octets envoyés) ; une valeur non finie (NaN d'un
  /// capteur) ferait échouer toute l'écriture : elle devient 0.
  static double _round(double v, int decimals) => v.isFinite ? double.parse(v.toStringAsFixed(decimals)) : 0;

  void _safe(Future<void> f) {
    unawaited(f.catchError((Object e) {
      debugPrint('Potes : synchro de position impossible : $e');
    }));
  }

  void dispose() {
    _disposed = true;
  }
}

// ===========================================================================
// Alerte « pote qui décroche »
// ===========================================================================

final stragglerWatcherProvider = Provider<StragglerDetector>((ref) {
  final detector = StragglerDetector();

  void evaluate() {
    final ride = ref.read(rideControllerProvider);
    final iAmRiding = ride.status == RideStatus.recording || ride.status == RideStatus.paused;
    final me = ref.read(positionHubProvider);
    final myUid = ref.read(myUidProvider);
    final groups = ref.read(myGroupsProvider);
    final memberIds = {
      for (final g in groups)
        for (final m in g.members) m.uid,
    }..remove(myUid);
    final friends = ref.read(friendsProvider);
    final candidates = <StragglerCandidate>[
      for (final f in friends)
        if (memberIds.contains(f.uid) && f.live != null)
          StragglerCandidate(
            uid: f.uid,
            name: f.name,
            location: f.live!.location,
            riding: f.live!.riding,
            updatedAt: f.live!.updatedAt,
          ),
    ];
    final alerts = detector.update(
      me: me?.point,
      iAmRiding: iAmRiding,
      thresholdKm: ref.read(settingsProvider).stragglerAlertKm,
      members: candidates,
      myUid: myUid,
    );
    for (final a in alerts) {
      unawaited(Notifications.show(
        id: 41000 + (a.uid.hashCode & 0x3ff),
        title: '${a.name} a décroché',
        body: '${a.name} est à ${Fmt.distance(a.distanceM)} de toi. '
            'Lève le pied ou fais une pause au prochain carrefour.',
        channel: CmChannel.ride,
      ));
    }
  }

  ref.listen(friendsProvider, (_, _) => evaluate());
  ref.listen(myGroupsProvider, (_, _) => evaluate());
  ref.listen(rideControllerProvider.select((s) => s.status), (_, _) => evaluate());
  ref.listen(positionHubProvider, (_, _) => evaluate());
  return detector;
});

// ===========================================================================
// SOS des potes
// ===========================================================================

final friendsSosWatcherProvider = Provider<Set<String>>((ref) {
  final notified = <String>{};

  void check(List<Friend> friends) {
    final now = DateTime.now().toUtc();
    final inSos = <String>{};
    for (final f in friends) {
      final l = f.recentLive(now: now);
      if (l == null || !l.sos) continue;
      inSos.add(f.uid);
      if (notified.contains(f.uid)) continue;
      // On ne ressort pas une vieille alerte au redémarrage de l'app.
      final since = l.sosAt ?? l.updatedAt;
      if (now.difference(since.toUtc()) > const Duration(hours: 3)) {
        notified.add(f.uid);
        continue;
      }
      notified.add(f.uid);
      final msg = l.sosMessage?.trim();
      unawaited(Notifications.show(
        id: 42000 + (f.uid.hashCode & 0x3ff),
        title: 'SOS · ${f.name} a besoin d\'aide',
        body: (msg != null && msg.isNotEmpty)
            ? msg
            : '${f.name} a peut-être chuté. Ouvre Cono Moto pour voir sa position sur la carte.',
        channel: CmChannel.safety,
      ));
    }
    // SOS levé : on pourra re-alerter s'il se reproduit.
    notified.removeWhere((uid) => !inSos.contains(uid));
  }

  ref.listen(friendsProvider, (_, next) => check(next), fireImmediately: true);
  return notified;
});
