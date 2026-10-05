import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/native.dart';
import '../../core/notifications.dart';
import '../../core/settings.dart';
import '../../services/ride/crash_messages.dart';
import '../../services/ride/ride_platform.dart';
import '../../services/social/sos.dart';

enum CrashAlertPhase {
  /// Pas d'alerte.
  idle,

  /// Compte à rebours en cours : le motard peut répondre « Je vais bien ».
  countdown,

  /// Envoi des alertes en cours.
  sending,

  /// Alertes envoyées (ou simulées en mode test).
  sent,
}

@immutable
class CrashAlertState {
  const CrashAlertState({
    this.phase = CrashAlertPhase.idle,
    this.secondsLeft = 0,
    this.totalSeconds = 60,
    this.test = false,
    this.position,
    this.accuracyM,
    this.triggeredAt,
    this.contactName = '',
    this.contactPhone = '',
    this.smsAutomatic = true,
    this.smsSent,
    this.smsMessage,
    this.smsCompose,
    this.sosSent,
    this.notificationShown = false,
  });

  final CrashAlertPhase phase;
  final int secondsLeft;
  final int totalSeconds;

  /// Mode essai : rien n'est réellement envoyé.
  final bool test;
  final GeoPoint? position;
  final double? accuracyM;
  final DateTime? triggeredAt;
  final String contactName;
  final String contactPhone;

  /// Le téléphone envoie le SMS tout seul (Android). Sur iPhone (false),
  /// Apple l'interdit : le SMS est préparé et il faut appuyer sur Envoyer.
  final bool smsAutomatic;

  /// null = SMS non envoyé (pas de contact, ou sur iPhone en attente de
  /// l'utilisateur), true = envoyé, false = échec.
  final bool? smsSent;
  final String? smsMessage;

  /// iPhone : issue du dernier écran Messages ouvert (null = pas encore ouvert).
  final SmsComposeResult? smsCompose;

  /// null = pas tenté (pas de position).
  final bool? sosSent;
  final bool notificationShown;

  bool get active => phase != CrashAlertPhase.idle;
  bool get hasContact => contactPhone.trim().isNotEmpty;

  /// Nom affiché du contact (ou son numéro).
  String get contactLabel => contactName.isNotEmpty ? contactName : contactPhone;

  /// iPhone : le SMS de secours est prêt mais il reste à appuyer sur Envoyer.
  bool get smsAwaitingUser => phase == CrashAlertPhase.sent && !test && hasContact && !smsAutomatic && smsSent != true;
}

/// Compte à rebours de l'alerte chute et envoi des secours.
///
/// Indépendant de l'écran : si l'interface n'est pas affichable, l'alerte part
/// quand même à l'expiration.
class CrashAlertController extends Notifier<CrashAlertState> {
  Timer? _timer;
  VoidCallback? _onClosed;

  static const notificationId = 4303;

  @override
  CrashAlertState build() {
    ref.onDispose(() => _timer?.cancel());
    return const CrashAlertState();
  }

  RidePlatform get _platform => ref.read(ridePlatformProvider);

  /// Déclenche l'alerte. [onClosed] est appelé quand elle est levée
  /// (« Je vais bien » ou « Annuler l'alerte »).
  void trigger({GeoPoint? at, double? accuracyM, bool test = false, int seconds = 60, VoidCallback? onClosed}) {
    if (state.active) return;
    final settings = ref.read(settingsProvider);
    _onClosed = onClosed;
    state = CrashAlertState(
      phase: CrashAlertPhase.countdown,
      secondsLeft: seconds,
      totalSeconds: seconds,
      test: test,
      position: at,
      accuracyM: accuracyM,
      triggeredAt: _platform.now(),
      contactName: settings.emergencyName.trim(),
      contactPhone: settings.emergencyPhone.trim(),
      smsAutomatic: _platform.canSendSmsAutomatically,
    );
    _announce(first: true);
    _platform.vibrate();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (state.phase != CrashAlertPhase.countdown) return;
    final left = state.secondsLeft - 1;
    if (left <= 0) {
      _timer?.cancel();
      _timer = null;
      state = _copy(secondsLeft: 0);
      unawaited(_dispatch());
      return;
    }
    state = _copy(secondsLeft: left);
    _platform.vibrate();
    if (left % 15 == 0 || left == 10) _announce();
  }

  void _announce({bool first = false}) {
    final s = state;
    final who = s.hasContact ? (s.contactName.isNotEmpty ? s.contactName : 'ton contact d\'urgence') : 'tes potes';
    if (first) {
      _platform.speak(
        s.hasContact && !s.smsAutomatic
            ? 'Chute détectée ! Si tout va bien, appuie sur « Je vais bien ». '
                  'Sinon, tes potes seront alertés et un SMS pour $who sera prêt dans ${s.secondsLeft} secondes.'
            : 'Chute détectée ! Si tout va bien, appuie sur « Je vais bien ». '
                  'Sinon, $who sera prévenu dans ${s.secondsLeft} secondes.',
      );
    } else {
      _platform.speak('Alerte dans ${s.secondsLeft} secondes. Appuie sur « Je vais bien » si tout va bien.');
    }
  }

  /// Le motard va bien : on arrête tout, rien n'est envoyé.
  void imOk() {
    if (state.phase != CrashAlertPhase.countdown) return;
    _close();
  }

  /// Envoie l'alerte tout de suite (bouton « Envoyer maintenant »).
  void sendNow() {
    if (state.phase != CrashAlertPhase.countdown) return;
    _timer?.cancel();
    _timer = null;
    state = _copy(secondsLeft: 0);
    unawaited(_dispatch());
  }

  Future<void> _dispatch() async {
    state = _copy(phase: CrashAlertPhase.sending);
    final s = state;
    GeoPoint? at = s.position;
    double? accuracy = s.accuracyM;
    try {
      final hub = ref.read(positionHubProvider);
      at ??= hub?.point;
      accuracy ??= hub?.accuracyM;
    } catch (_) {}
    final sms = buildCrashSms(at: at, accuracyM: accuracy, time: s.triggeredAt);

    bool? smsSent;
    bool? sosSent;
    if (s.test) {
      smsSent = s.hasContact && s.smsAutomatic ? true : null;
      sosSent = at != null ? true : null;
    } else {
      // iPhone : pas d'envoi automatique possible, le SMS sera préparé dans
      // Messages (voir [composeSms]).
      if (s.hasContact && s.smsAutomatic) {
        try {
          smsSent = await _platform.sendSms(s.contactPhone, sms);
        } catch (e) {
          debugPrint('SMS de secours : $e');
          smsSent = false;
        }
      }
      if (at != null) {
        try {
          await ref.read(sosBroadcasterProvider).broadcast(at, buildCrashSosMessage());
          sosSent = true;
        } catch (e) {
          debugPrint('SOS potes : $e');
          sosSent = false;
        }
      }
      final who = [if (smsSent == true) s.contactLabel, if (sosSent == true) 'tes potes'];
      final awaitingSms = s.hasContact && !s.smsAutomatic;
      await _safe(
        () => _platform.notify(
          id: notificationId,
          title: awaitingSms ? 'Chute : envoie le SMS à ${s.contactLabel}' : 'Alerte chute envoyée',
          body: awaitingSms
              ? '${sosSent == true ? 'Tes potes sont alertés. ' : ''}'
                    'Ouvre Cono Moto et appuie sur Envoyer pour prévenir ${s.contactLabel}.'
              : who.isEmpty
              ? 'Impossible de prévenir quelqu\'un automatiquement : appelle le 112 si besoin.'
              : 'Prévenus : ${who.join(' et ')}. Ouvre Cono Moto pour annuler si tout va bien.',
          channel: CmChannel.safety,
        ),
      );
    }
    if (!ref.mounted || state.phase != CrashAlertPhase.sending) return;
    state = _copy(
      phase: CrashAlertPhase.sent,
      position: at,
      accuracyM: accuracy,
      smsSent: smsSent,
      smsMessage: sms,
      sosSent: sosSent,
      notificationShown: !s.test,
    );
    if (s.test) {
      _platform.speak('Test terminé. En vrai, l\'alerte serait partie maintenant.');
    } else if (s.hasContact && !s.smsAutomatic) {
      _platform.speak(
        '${sosSent == true ? 'Tes potes sont alertés. ' : ''}'
        'Le SMS pour ${s.contactLabel} est prêt : appuie sur Envoyer.',
      );
    } else if (smsSent == true || sosSent == true) {
      _platform.speak('Alerte envoyée. Tes proches sont prévenus.');
    } else {
      _platform.speak('Personne n\'a pu être prévenu automatiquement. Appelle le 112 si besoin.');
    }
  }

  static Future<void> _safe(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('Alerte chute : $e');
    }
  }

  bool _composing = false;

  /// iPhone : ouvre Messages avec le SMS de secours pré-rempli (il reste à
  /// appuyer sur Envoyer). Sans effet en mode test ou sans contact.
  Future<SmsComposeResult?> composeSms() async {
    final s = state;
    if (s.phase != CrashAlertPhase.sent || s.test || !s.hasContact || _composing) return null;
    _composing = true;
    SmsComposeResult result;
    try {
      result = await _platform.composeSms(
        s.contactPhone,
        s.smsMessage ?? buildCrashSms(at: s.position, accuracyM: s.accuracyM, time: s.triggeredAt),
      );
    } catch (e) {
      debugPrint('SMS de secours (Messages) : $e');
      result = SmsComposeResult.unavailable;
    } finally {
      _composing = false;
    }
    if (!ref.mounted || state.phase != CrashAlertPhase.sent) return result;
    state = _copy(
      smsCompose: result,
      smsSent: switch (result) {
        SmsComposeResult.sent => true,
        SmsComposeResult.failed => false,
        _ => null, // annulé : on garde l'état précédent
      },
    );
    if (result == SmsComposeResult.sent) {
      await _safe(() => _platform.cancelNotification(notificationId));
    }
    return result;
  }

  /// Fausse alerte après envoi : on lève le SOS et on rassure le contact.
  Future<void> cancelAlert() async {
    final s = state;
    if (s.phase == CrashAlertPhase.idle) return;
    if (!s.test && s.phase != CrashAlertPhase.countdown) {
      try {
        await ref.read(sosBroadcasterProvider).cancel();
      } catch (e) {
        debugPrint('Annulation SOS : $e');
      }
      if (s.smsSent == true && s.hasContact) {
        if (s.smsAutomatic) {
          await _safe(() => _platform.sendSms(s.contactPhone, buildFalseAlarmSms()));
        } else {
          // iPhone : Messages s'ouvre pré-rempli, il reste à appuyer sur Envoyer.
          unawaited(_safe(() => _platform.composeSms(s.contactPhone, buildFalseAlarmSms())));
        }
      }
      await _safe(() => _platform.cancelNotification(notificationId));
    }
    _close();
  }

  /// Ferme l'écran sans lever l'alerte (les secours restent prévenus).
  void dismissKeepingAlert() {
    if (state.phase != CrashAlertPhase.sent) return;
    _close();
  }

  void _close() {
    _timer?.cancel();
    _timer = null;
    _platform.stopSpeaking();
    final cb = _onClosed;
    _onClosed = null;
    state = const CrashAlertState();
    cb?.call();
  }

  CrashAlertState _copy({
    CrashAlertPhase? phase,
    int? secondsLeft,
    GeoPoint? position,
    double? accuracyM,
    bool? smsSent,
    String? smsMessage,
    SmsComposeResult? smsCompose,
    bool? sosSent,
    bool? notificationShown,
  }) {
    final s = state;
    return CrashAlertState(
      phase: phase ?? s.phase,
      secondsLeft: secondsLeft ?? s.secondsLeft,
      totalSeconds: s.totalSeconds,
      test: s.test,
      position: position ?? s.position,
      accuracyM: accuracyM ?? s.accuracyM,
      triggeredAt: s.triggeredAt,
      contactName: s.contactName,
      contactPhone: s.contactPhone,
      smsAutomatic: s.smsAutomatic,
      smsSent: smsSent ?? s.smsSent,
      smsMessage: smsMessage ?? s.smsMessage,
      smsCompose: smsCompose ?? s.smsCompose,
      sosSent: sosSent ?? s.sosSent,
      notificationShown: notificationShown ?? s.notificationShown,
    );
  }
}

final crashAlertProvider = NotifierProvider<CrashAlertController, CrashAlertState>(CrashAlertController.new);
