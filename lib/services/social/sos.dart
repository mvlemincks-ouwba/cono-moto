// Module « Potes » — alerte SOS, utilisée par la détection de chute.
import 'dart:async';

import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:firebase_database/firebase_database.dart' show ServerValue;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../features/social/social_models.dart';
import '../../features/social/social_providers.dart';
import 'social_api.dart';

/// Diffuse une alerte SOS aux potes (marqueur rouge sur leur carte + notification).
///
/// [broadcast] lève une [SocialException] (message en français) si l'alerte
/// n'a pas pu être remise au serveur : mode solo, pas connecté, refus du
/// serveur ou réseau trop lent (l'écriture reste alors en file et partira dès
/// que possible). Mieux vaut sous-estimer que faire croire que les potes sont
/// prévenus.
abstract class SosBroadcaster {
  Future<void> broadcast(GeoPoint at, String message);
  Future<void> cancel();
}

class _NoopSos implements SosBroadcaster {
  const _NoopSos(this.reason);

  final String reason;

  @override
  Future<void> broadcast(GeoPoint at, String message) async => throw SocialException(reason);

  @override
  Future<void> cancel() async {}
}

/// SOS via la Realtime Database : live/{uid}.sos = true (+ message et
/// position). Les potes reçoivent une notification « Sécurité » et voient le
/// marqueur en rouge ; les liens de suivi web actifs affichent aussi l'alerte.
class FirebaseSosBroadcaster implements SosBroadcaster {
  FirebaseSosBroadcaster(this._api, this._uid, {this.profile, this.shareTokens = const []});

  final SocialApi _api;
  final String _uid;
  final UserProfile? profile;

  /// Liens de suivi web actifs (l'alerte y est aussi affichée).
  final List<String> shareTokens;

  static const _timeout = Duration(seconds: 10);

  @override
  Future<void> broadcast(GeoPoint at, String message) async {
    final p = profile;
    var msg = message.trim();
    if (msg.length > 480) msg = '${msg.substring(0, 477)}…';
    try {
      await _guard(() => _api.publishLive(_uid, {
        'sos': true,
        'sosMessage': msg,
        'sosAt': ServerValue.timestamp,
        'lat': at.lat,
        'lng': at.lng,
        'ts': ServerValue.timestamp,
        'speed': 0,
        if (p != null) ...{'name': p.name, 'color': p.colorValue, 'bike': p.bike},
      }));
    } finally {
      // Les liens de suivi web affichent aussi l'alerte (au mieux).
      if (shareTokens.isNotEmpty) {
        unawaited(_api
            .updateShares(shareTokens, {'sos': true, 'sosMessage': msg, 'lat': at.lat, 'lng': at.lng})
            .catchError((Object e) => debugPrint('SOS : liens de suivi non mis à jour : $e')));
      }
    }
  }

  Future<void> _guard(Future<void> Function() op) async {
    try {
      await op().timeout(_timeout);
    } on TimeoutException {
      throw const SocialException(
          'Réseau trop faible : l\'alerte aux potes partira dès que le téléphone capte.');
    } on FirebaseException catch (e) {
      debugPrint('SOS : diffusion aux potes impossible : $e');
      throw const SocialException('Le serveur a refusé l\'alerte aux potes.');
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _api.publishLive(_uid, {'sos': false, 'sosMessage': null, 'sosAt': null}).timeout(_timeout);
    } on TimeoutException {
      debugPrint('SOS : annulation en file d\'attente.');
    } catch (e) {
      debugPrint('SOS : annulation impossible : $e');
    }
    if (shareTokens.isNotEmpty) {
      unawaited(_api
          .updateShares(shareTokens, {'sos': false, 'sosMessage': null})
          .catchError((Object e) => debugPrint('SOS : liens de suivi non mis à jour : $e')));
    }
  }
}

final sosBroadcasterProvider = Provider<SosBroadcaster>((ref) {
  final api = ref.watch(socialApiProvider);
  final uid = ref.watch(myUidProvider);
  if (api == null) return const _NoopSos('Mode solo : les potes ne peuvent pas être prévenus.');
  if (uid == null) return const _NoopSos('Pas connecté au mode potes : ils ne peuvent pas être prévenus.');
  final shares = ref.watch(mySharesProvider).value ?? const [];
  return FirebaseSosBroadcaster(
    api,
    uid,
    profile: ref.watch(myProfileProvider).value,
    shareTokens: [
      for (final s in shares)
        if (s.isActive()) s.token,
    ],
  );
});
