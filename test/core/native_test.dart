import 'package:cono_moto/core/config.dart';
import 'package:cono_moto/core/native.dart';
import 'package:cono_moto/services/social/firebase_bootstrap.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lien sms: pré-rempli, au format attendu par chaque plateforme', () {
    const msg = 'Chute ? Position : https://maps.google.com/?q=45.1,5.7';
    final ios = smsUri('06 11 22 33 44', msg, ios: true).toString();
    final android = smsUri('+33 6 11 22 33 44', msg, ios: false).toString();
    expect(ios, startsWith('sms:0611223344&body='));
    expect(android, startsWith('sms:+33611223344?body='));
    expect(Uri.decodeComponent(ios.split('body=').last), msg);
  });

  test('SMS automatique sur Android seulement', () {
    expect(NativeBridge.canSendSmsAutomatically, isTrue); // flutter test simule Android
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      expect(NativeBridge.isIOS, isTrue);
      expect(NativeBridge.canSendSmsAutomatically, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('iPhone : sans FIREBASE_IOS_APP_ID, mode solo', () {
    // Aucun --dart-define dans les tests.
    expect(AppConfig.firebaseAppIdFor(TargetPlatform.iOS), AppConfig.firebaseIosAppId);
    expect(AppConfig.firebaseConfiguredFor(TargetPlatform.iOS), isFalse);
    expect(FirebaseBootstrap.optionsFor(TargetPlatform.iOS), isNull);
    expect(FirebaseBootstrap.optionsFor(TargetPlatform.android), isNull);
  });
}
