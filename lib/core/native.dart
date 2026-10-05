import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Fonctions natives Android (voir MainActivity.kt).
class NativeBridge {
  NativeBridge._();

  static const _channel = MethodChannel('fr.conomoto/native');

  /// Envoie un SMS directement (permission SEND_SMS requise).
  /// Retourne false en cas d'échec.
  static Future<bool> sendSms(String phone, String message) async {
    try {
      final ok = await _channel.invokeMethod<bool>('sendSms', {'phone': phone, 'message': message});
      return ok ?? false;
    } catch (e) {
      debugPrint('sendSms a échoué : $e');
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
