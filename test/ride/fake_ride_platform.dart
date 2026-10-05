import 'dart:async';

import 'package:cono_moto/core/location.dart';
import 'package:cono_moto/core/native.dart';
import 'package:cono_moto/core/notifications.dart';
import 'package:cono_moto/services/ride/ride_platform.dart';

/// Plateforme simulée : horloge manuelle, flux GPS / capteurs pilotés par le test,
/// effets (notifications, voix, SMS) enregistrés.
class FakeRidePlatform implements RidePlatform {
  DateTime clock = DateTime.utc(2026, 6, 7, 9);
  LocationAccess access = LocationAccess.granted;
  bool smsGranted = true;
  bool smsWorks = true;

  /// false = comportement iPhone (pas d'envoi automatique, écran Messages).
  bool smsAutomatic = true;
  SmsComposeResult composeResult = SmsComposeResult.sent;

  final gps = StreamController<RiderPosition>.broadcast();
  final gyro = StreamController<SensorSample>.broadcast();
  final acc = StreamController<SensorSample>.broadcast();

  final notifications = <({int id, String title, String body, CmChannel channel})>[];
  final cancelled = <int>[];
  final spoken = <String>[];
  final sms = <({String phone, String message})>[];
  final composed = <({String phone, String message})>[];
  final screenOn = <bool>[];
  int vibrations = 0;

  void advance(Duration d) => clock = clock.add(d);

  @override
  DateTime now() => clock;

  @override
  Future<LocationAccess> ensureLocationPermission() async => access;

  @override
  Stream<RiderPosition> positions() => gps.stream;

  @override
  Stream<SensorSample> gyroscope() => gyro.stream;

  @override
  Stream<SensorSample> accelerometer() => acc.stream;

  @override
  Future<void> requestNotificationPermission() async {}

  @override
  Future<bool> requestSmsPermission() async => smsGranted;

  @override
  Future<void> keepScreenOn(bool on) async => screenOn.add(on);

  @override
  Future<void> notify({
    required int id,
    required String title,
    required String body,
    CmChannel channel = CmChannel.ride,
  }) async => notifications.add((id: id, title: title, body: body, channel: channel));

  @override
  Future<void> cancelNotification(int id) async => cancelled.add(id);

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stopSpeaking() async {}

  @override
  Future<void> vibrate() async => vibrations++;

  @override
  bool get canSendSmsAutomatically => smsAutomatic;

  @override
  Future<bool> sendSms(String phone, String message) async {
    sms.add((phone: phone, message: message));
    return smsWorks;
  }

  @override
  Future<SmsComposeResult> composeSms(String phone, String message) async {
    composed.add((phone: phone, message: message));
    return composeResult;
  }
}
