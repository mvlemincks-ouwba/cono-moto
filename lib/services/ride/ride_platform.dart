import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../core/location.dart';
import '../../core/native.dart';
import '../../core/notifications.dart';

/// Échantillon d'un capteur inertiel (repère du téléphone).
@immutable
class SensorSample {
  const SensorSample(this.time, this.x, this.y, this.z);

  final DateTime time;
  final double x;
  final double y;
  final double z;
}

/// Tout ce que l'enregistreur de balade demande à l'appareil. Remplaçable dans
/// les tests (voir [ridePlatformProvider]).
abstract class RidePlatform {
  DateTime now();

  Future<LocationAccess> ensureLocationPermission();

  /// Flux GPS haute fréquence (service au premier plan).
  Stream<RiderPosition> positions();

  /// Gyroscope ≈ 50 Hz (rad/s). Peut émettre une erreur si absent.
  Stream<SensorSample> gyroscope();

  /// Accéléromètre ≈ 50 Hz (m/s², gravité incluse).
  Stream<SensorSample> accelerometer();

  Future<void> requestNotificationPermission();

  /// Demande la permission d'envoyer des SMS. Retourne true si accordée.
  Future<bool> requestSmsPermission();

  Future<void> keepScreenOn(bool on);

  Future<void> notify({
    required int id,
    required String title,
    required String body,
    CmChannel channel = CmChannel.ride,
  });

  Future<void> cancelNotification(int id);

  /// Annonce vocale en français.
  Future<void> speak(String text);

  Future<void> stopSpeaking();

  Future<void> vibrate();

  Future<bool> sendSms(String phone, String message);
}

/// Implémentation Android réelle.
class DeviceRidePlatform implements RidePlatform {
  DeviceRidePlatform(this._location);

  final LocationService _location;
  FlutterTts? _tts;
  Future<void>? _ttsReady;

  static const _sensorPeriod = SensorInterval.gameInterval; // 20 ms ≈ 50 Hz

  @override
  DateTime now() => DateTime.now();

  @override
  Future<LocationAccess> ensureLocationPermission() => _location.ensurePermission();

  @override
  Stream<RiderPosition> positions() => _location.rideStream().map(RiderPosition.fromGeolocator);

  @override
  Stream<SensorSample> gyroscope() =>
      gyroscopeEventStream(samplingPeriod: _sensorPeriod).map((e) => SensorSample(e.timestamp, e.x, e.y, e.z));

  @override
  Stream<SensorSample> accelerometer() =>
      accelerometerEventStream(samplingPeriod: _sensorPeriod).map((e) => SensorSample(e.timestamp, e.x, e.y, e.z));

  @override
  Future<void> requestNotificationPermission() async {
    try {
      await Notifications.requestPermission();
    } catch (e) {
      debugPrint('Permission notifications : $e');
    }
  }

  @override
  Future<bool> requestSmsPermission() async {
    try {
      final status = await Permission.sms.request();
      return status.isGranted;
    } catch (e) {
      debugPrint('Permission SMS : $e');
      return false;
    }
  }

  @override
  Future<void> keepScreenOn(bool on) => NativeBridge.keepScreenOn(on);

  @override
  Future<void> notify({
    required int id,
    required String title,
    required String body,
    CmChannel channel = CmChannel.ride,
  }) => Notifications.show(id: id, title: title, body: body, channel: channel);

  @override
  Future<void> cancelNotification(int id) => Notifications.cancel(id);

  Future<FlutterTts> _ensureTts() async {
    final tts = _tts ??= FlutterTts();
    await (_ttsReady ??= () async {
      await tts.setLanguage('fr-FR');
      await tts.setSpeechRate(0.5);
      await tts.setVolume(1);
    }());
    return tts;
  }

  @override
  Future<void> speak(String text) async {
    try {
      final tts = await _ensureTts();
      await tts.speak(text);
    } catch (e) {
      debugPrint('Synthèse vocale indisponible : $e');
    }
  }

  @override
  Future<void> stopSpeaking() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  @override
  Future<void> vibrate() async {
    try {
      await HapticFeedback.vibrate();
      await HapticFeedback.heavyImpact();
    } catch (_) {}
  }

  @override
  Future<bool> sendSms(String phone, String message) => NativeBridge.sendSms(phone, message);
}

final ridePlatformProvider = Provider<RidePlatform>((ref) => DeviceRidePlatform(ref.watch(locationServiceProvider)));
