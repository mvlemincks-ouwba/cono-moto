import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
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

  /// Flux GPS haute fréquence (service au premier plan sur Android, suivi en
  /// arrière-plan autorisé sur iPhone).
  Stream<RiderPosition> positions();

  /// Gyroscope (rad/s) : ≈ 50 Hz si [fast], ≈ 15 Hz sinon (moins de réveils du
  /// processeur, assez pour suivre l'angle). Peut émettre une erreur si absent.
  Stream<SensorSample> gyroscope({bool fast = true});

  /// Accéléromètre (m/s², gravité incluse) : ≈ 50 Hz si [fast], ≈ 15 Hz sinon.
  Stream<SensorSample> accelerometer({bool fast = true});

  Future<void> requestNotificationPermission();

  /// Demande la permission d'envoyer des SMS. Retourne true si accordée
  /// (toujours false sur iPhone : pas d'envoi automatique possible).
  Future<bool> requestSmsPermission();

  /// Le téléphone envoie-t-il un SMS tout seul ? Oui sur Android ; sur iPhone,
  /// Apple l'interdit : le SMS est préparé ([composeSms]) et il faut appuyer
  /// sur Envoyer.
  bool get canSendSmsAutomatically;

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

  /// Envoi automatique (Android). Retourne false en cas d'échec.
  Future<bool> sendSms(String phone, String message);

  /// Ouvre l'écran Messages pré-rempli (iPhone) : l'utilisateur doit appuyer
  /// sur Envoyer.
  Future<SmsComposeResult> composeSms(String phone, String message);
}

/// Implémentation réelle (Android et iPhone).
class DeviceRidePlatform implements RidePlatform {
  DeviceRidePlatform(this._location);

  final LocationService _location;
  FlutterTts? _tts;
  Future<void>? _ttsReady;

  // 20 ms ≈ 50 Hz, ou 66 ms ≈ 15 Hz.
  static Duration _sensorPeriod(bool fast) => fast ? SensorInterval.gameInterval : SensorInterval.uiInterval;

  @override
  DateTime now() => DateTime.now();

  @override
  Future<LocationAccess> ensureLocationPermission() => _location.ensurePermission(precise: true);

  @override
  Stream<RiderPosition> positions() => _location.rideStream().map(RiderPosition.fromGeolocator);

  @override
  Stream<SensorSample> gyroscope({bool fast = true}) => gyroscopeEventStream(
    samplingPeriod: _sensorPeriod(fast),
  ).map((e) => SensorSample(e.timestamp, e.x, e.y, e.z));

  @override
  Stream<SensorSample> accelerometer({bool fast = true}) => accelerometerEventStream(
    samplingPeriod: _sensorPeriod(fast),
  ).map((e) => SensorSample(e.timestamp, e.x, e.y, e.z));

  @override
  Future<void> requestNotificationPermission() async {
    try {
      await Notifications.requestPermission();
    } catch (e) {
      debugPrint('Permission notifications : $e');
    }
  }

  @override
  Future<bool> requestSmsPermission() => NativeBridge.requestSmsPermission();

  @override
  bool get canSendSmsAutomatically => NativeBridge.canSendSmsAutomatically;

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
      // Sur iPhone, la session audio (lecture, baisse de la musique, écran
      // verrouillé) est configurée une fois pour toutes dans AppDelegate.swift.
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

  @override
  Future<SmsComposeResult> composeSms(String phone, String message) => NativeBridge.composeSms(phone, message);
}

final ridePlatformProvider = Provider<RidePlatform>((ref) => DeviceRidePlatform(ref.watch(locationServiceProvider)));
