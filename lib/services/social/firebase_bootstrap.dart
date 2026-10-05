import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';

/// État de l'initialisation Firebase (lu par les providers du module Potes).
class FirebaseBootstrap {
  FirebaseBootstrap._();

  static bool _ready = false;
  static Object? _error;

  /// Firebase est initialisé et utilisable.
  static bool get ready => _ready;

  /// Erreur d'initialisation éventuelle (config invalide…).
  static Object? get error => _error;

  /// Options construites depuis les `--dart-define` (null si incomplètes).
  static FirebaseOptions? get options => optionsFor(defaultTargetPlatform);

  /// Options pour une plateforme : l'App ID diffère entre Android et iOS, et
  /// iOS exige en plus le bundle id.
  @visibleForTesting
  static FirebaseOptions? optionsFor(TargetPlatform platform) {
    if (!AppConfig.firebaseConfiguredFor(platform)) return null;
    final ios = platform == TargetPlatform.iOS;
    return FirebaseOptions(
      apiKey: AppConfig.firebaseApiKey,
      appId: AppConfig.firebaseAppIdFor(platform),
      messagingSenderId: AppConfig.firebaseMessagingSenderId,
      projectId: AppConfig.firebaseProjectId,
      databaseURL: AppConfig.firebaseDatabaseUrl,
      storageBucket: AppConfig.firebaseStorageBucket.isEmpty ? null : AppConfig.firebaseStorageBucket,
      authDomain: '${AppConfig.firebaseProjectId}.firebaseapp.com',
      iosBundleId: ios ? AppConfig.iosBundleId : null,
      iosClientId: ios && AppConfig.firebaseIosClientId.isNotEmpty ? AppConfig.firebaseIosClientId : null,
    );
  }
}

/// Initialise Firebase à partir de AppConfig (dart-define). Retourne false si
/// Firebase n'est pas configuré : l'app fonctionne alors en solo.
Future<bool> initFirebase() async {
  if (FirebaseBootstrap._ready) return true;
  final options = FirebaseBootstrap.options;
  if (options == null) {
    debugPrint('Firebase non configuré : mode solo.');
    return false;
  }
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: options);
    }
    FirebaseBootstrap._ready = true;
    FirebaseBootstrap._error = null;
    return true;
  } catch (e) {
    debugPrint('Initialisation Firebase impossible : $e');
    FirebaseBootstrap._error = e;
    FirebaseBootstrap._ready = false;
    return false;
  }
}
