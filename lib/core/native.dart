import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

/// Issue de l'écran d'envoi de SMS pré-rempli (iPhone).
enum SmsComposeResult {
  /// L'utilisateur a appuyé sur Envoyer.
  sent,

  /// L'utilisateur a fermé l'écran sans envoyer.
  cancelled,

  /// L'envoi a échoué.
  failed,

  /// L'app Messages a été ouverte (résultat inconnu : repli via lien `sms:`).
  opened,

  /// Ce téléphone ne peut pas envoyer de SMS (pas de carte SIM, Messages désactivé…).
  unavailable,
}

/// Fonctions natives (voir MainActivity.kt sur Android, AppDelegate.swift sur iOS).
///
/// Différence majeure : Android sait envoyer un SMS tout seul (permission
/// SEND_SMS), alors qu'Apple l'interdit sur iPhone. Sur iOS, le SMS est
/// préparé dans l'écran Messages et l'utilisateur doit appuyer sur Envoyer.
class NativeBridge {
  NativeBridge._();

  static const _channel = MethodChannel('fr.conomoto/native');

  /// Tourne sur iPhone (ou iPad). Basé sur [defaultTargetPlatform] pour pouvoir
  /// être simulé dans les tests (`debugDefaultTargetPlatformOverride`).
  static bool get isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  /// Le téléphone peut-il envoyer un SMS sans action de l'utilisateur ?
  /// Oui sur Android, jamais sur iPhone.
  static bool get canSendSmsAutomatically => defaultTargetPlatform == TargetPlatform.android;

  /// Demande la permission d'envoyer des SMS (Android). Sur iPhone, il n'y a
  /// pas de permission SMS : retourne false sans rien demander.
  static Future<bool> requestSmsPermission() async {
    if (!canSendSmsAutomatically) return false;
    try {
      final status = await Permission.sms.request();
      return status.isGranted;
    } catch (e) {
      debugPrint('Permission SMS : $e');
      return false;
    }
  }

  /// Envoie un SMS directement (Android, permission SEND_SMS requise).
  /// Retourne false en cas d'échec, et toujours false sur iPhone.
  static Future<bool> sendSms(String phone, String message) async {
    if (!canSendSmsAutomatically) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('sendSms', {'phone': phone, 'message': message});
      return ok ?? false;
    } catch (e) {
      debugPrint('sendSms a échoué : $e');
      return false;
    }
  }

  /// Ouvre l'écran d'envoi de SMS pré-rempli (destinataire + texte) : il reste
  /// à appuyer sur Envoyer. Sur iPhone, utilise le composeur natif
  /// (MFMessageComposeViewController) ; sinon, ou à défaut, l'app Messages via
  /// un lien `sms:`.
  static Future<SmsComposeResult> composeSms(String phone, String message) async {
    if (isIOS) {
      try {
        final r = await _channel.invokeMethod<String>('composeSms', {'phone': phone, 'message': message});
        switch (r) {
          case 'sent':
            return SmsComposeResult.sent;
          case 'cancelled':
            return SmsComposeResult.cancelled;
          case 'failed':
            return SmsComposeResult.failed;
          case 'unavailable':
            return SmsComposeResult.unavailable;
          case 'busy':
            return SmsComposeResult.opened;
        }
      } catch (e) {
        debugPrint('composeSms natif indisponible : $e');
      }
    }
    try {
      final ok = await launchUrl(smsUri(phone, message, ios: isIOS));
      return ok ? SmsComposeResult.opened : SmsComposeResult.unavailable;
    } catch (e) {
      debugPrint('Ouverture de Messages impossible : $e');
      return SmsComposeResult.unavailable;
    }
  }

  /// Lance un appel (écran de confirmation du téléphone).
  static Future<bool> call(String phone) async {
    try {
      return await launchUrl(Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^0-9+*#]'), '')));
    } catch (e) {
      debugPrint('Appel impossible : $e');
      return false;
    }
  }

  /// Garde l'écran allumé (pendant une balade).
  static Future<void> keepScreenOn(bool on) async {
    try {
      await _channel.invokeMethod<void>('keepScreenOn', {'on': on});
    } catch (e) {
      debugPrint('keepScreenOn a échoué : $e');
    }
  }
}

/// Lien `sms:` pré-rempli. iOS attend `sms:NUMERO&body=…`, Android
/// `sms:NUMERO?body=…`.
@visibleForTesting
Uri smsUri(String phone, String message, {required bool ios}) {
  final number = phone.replaceAll(RegExp(r'[^0-9+]'), '');
  final body = Uri.encodeComponent(message);
  return Uri.parse(ios ? 'sms:$number&body=$body' : 'sms:$number?body=$body');
}
