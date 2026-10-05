import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/notifications.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/features/ride/crash_alert_controller.dart';
import 'package:cono_moto/services/ride/ride_platform.dart';
import 'package:cono_moto/services/social/sos.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_ride_platform.dart';

class FakeSos implements SosBroadcaster {
  final broadcasts = <({GeoPoint at, String message})>[];
  int cancels = 0;

  @override
  Future<void> broadcast(GeoPoint at, String message) async => broadcasts.add((at: at, message: message));

  @override
  Future<void> cancel() async => cancels++;
}

Future<({ProviderContainer c, FakeRidePlatform platform, FakeSos sos})> setup({bool contact = true}) async {
  SharedPreferences.setMockInitialValues({
    if (contact) 'settings.emergencyName': 'Julie',
    if (contact) 'settings.emergencyPhone': '0611223344',
  });
  final prefs = await SharedPreferences.getInstance();
  final platform = FakeRidePlatform();
  final sos = FakeSos();
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      ridePlatformProvider.overrideWithValue(platform),
      sosBroadcasterProvider.overrideWithValue(sos),
    ],
  );
  return (c: c, platform: platform, sos: sos);
}

const here = GeoPoint(45.18765, 5.72543);

Future<void> waitFor(bool Function() cond) async {
  for (var i = 0; i < 60 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('« Je vais bien » : rien n\'est envoyé', () async {
    final s = await setup();
    var closed = 0;
    final ctrl = s.c.read(crashAlertProvider.notifier);
    ctrl.trigger(at: here, seconds: 30, onClosed: () => closed++);
    expect(s.c.read(crashAlertProvider).phase, CrashAlertPhase.countdown);
    expect(s.platform.spoken.single, contains('Julie'));
    ctrl.imOk();
    expect(s.c.read(crashAlertProvider).phase, CrashAlertPhase.idle);
    expect(closed, 1);
    expect(s.platform.sms, isEmpty);
    expect(s.sos.broadcasts, isEmpty);
    s.c.dispose();
  });

  test('expiration : SMS au contact + SOS aux potes + notification, puis annulation', () async {
    final s = await setup();
    var closed = 0;
    final ctrl = s.c.read(crashAlertProvider.notifier);
    ctrl.trigger(at: here, accuracyM: 6, seconds: 1, onClosed: () => closed++);
    await waitFor(() => s.c.read(crashAlertProvider).phase == CrashAlertPhase.sent);
    final st = s.c.read(crashAlertProvider);
    expect(st.phase, CrashAlertPhase.sent);
    expect(st.smsSent, isTrue);
    expect(st.sosSent, isTrue);
    expect(s.platform.sms.single.phone, '0611223344');
    expect(s.platform.sms.single.message, contains('https://maps.google.com/?q=45.18765,5.72543'));
    expect(s.sos.broadcasts.single.at, here);
    expect(s.platform.notifications.single.channel, CmChannel.safety);

    await ctrl.cancelAlert();
    expect(s.sos.cancels, 1);
    expect(s.platform.sms.last.message, contains('fausse alerte'));
    expect(s.c.read(crashAlertProvider).phase, CrashAlertPhase.idle);
    expect(closed, 1);
    s.c.dispose();
  });

  test('sans contact d\'urgence : les potes sont quand même alertés', () async {
    final s = await setup(contact: false);
    s.c.read(crashAlertProvider.notifier).trigger(at: here, seconds: 1);
    await waitFor(() => s.c.read(crashAlertProvider).phase == CrashAlertPhase.sent);
    final st = s.c.read(crashAlertProvider);
    expect(st.smsSent, isNull);
    expect(st.sosSent, isTrue);
    expect(s.platform.sms, isEmpty);
    expect(s.sos.broadcasts, hasLength(1));
    s.c.dispose();
  });

  test('SMS en échec : signalé', () async {
    final s = await setup();
    s.platform.smsWorks = false;
    s.c.read(crashAlertProvider.notifier).trigger(at: here, seconds: 1);
    await waitFor(() => s.c.read(crashAlertProvider).phase == CrashAlertPhase.sent);
    expect(s.c.read(crashAlertProvider).smsSent, isFalse);
    s.c.dispose();
  });

  test('mode test : rien n\'est réellement envoyé', () async {
    final s = await setup();
    final ctrl = s.c.read(crashAlertProvider.notifier);
    ctrl.trigger(at: here, seconds: 1, test: true);
    await waitFor(() => s.c.read(crashAlertProvider).phase == CrashAlertPhase.sent);
    final st = s.c.read(crashAlertProvider);
    expect(st.smsSent, isTrue);
    expect(st.sosSent, isTrue);
    expect(s.platform.sms, isEmpty);
    expect(s.sos.broadcasts, isEmpty);
    expect(s.platform.notifications, isEmpty);
    await ctrl.cancelAlert();
    expect(s.sos.cancels, 0);
    expect(s.c.read(crashAlertProvider).phase, CrashAlertPhase.idle);
    s.c.dispose();
  });
}
