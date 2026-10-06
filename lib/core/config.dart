import 'package:flutter/foundation.dart';

/// Configuration injectée à la compilation via `--dart-define`
/// (voir README, `.github/workflows/android.yml` et `ios.yml`).
class AppConfig {
  AppConfig._();

  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');

  /// App ID Firebase de l'appli Android (`1:…:android:…`).
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');

  /// App ID Firebase de l'appli iOS (`1:…:ios:…`), déclarée dans la console
  /// avec le bundle id [iosBundleId].
  static const firebaseIosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');

  /// Facultatif sur iOS (connexion Google, non utilisée pour l'instant).
  static const firebaseIosClientId = String.fromEnvironment('FIREBASE_IOS_CLIENT_ID');
  static const firebaseMessagingSenderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const firebaseDatabaseUrl = String.fromEnvironment('FIREBASE_DATABASE_URL');
  static const firebaseStorageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');

  /// Clé TomTom par défaut (modifiable dans les réglages de l'app).
  static const tomtomApiKey = String.fromEnvironment('TOMTOM_API_KEY');

  /// URL de la page web de suivi en direct (ex : https://mon-projet.web.app/live.html).
  static const shareViewerUrl = String.fromEnvironment('SHARE_VIEWER_URL');

  /// Webhook Discord où sont postées les idées et bugs envoyés depuis l'appli
  /// (idéalement celui d'un salon « forum » : une demande = un fil).
  static const discordFeedbackWebhook = String.fromEnvironment('DISCORD_FEEDBACK_WEBHOOK');

  /// Lien d'invitation au serveur Discord (facultatif).
  static const discordInviteUrl = String.fromEnvironment('DISCORD_INVITE_URL');

  /// Adresse où sont publiées les versions pour les mises à jour automatiques
  /// (release « derniere-version » du dépôt public des versions), par ex.
  /// https://github.com/moi/cono-moto-releases/releases/download/derniere-version.
  /// Vide : pas de mises à jour automatiques.
  static const updateBaseUrl = String.fromEnvironment('UPDATE_BASE_URL');

  /// Numéro de build et commit (injectés par la CI, « dev » en local).
  static const appVersion = '1.0.0';
  static const appBuild = String.fromEnvironment('APP_BUILD', defaultValue: 'dev');
  static const appCommit = String.fromEnvironment('APP_COMMIT');

  /// Identifiant de l'appli iOS (PRODUCT_BUNDLE_IDENTIFIER du projet Xcode).
  static const iosBundleId = 'fr.conomoto.conoMoto';

  /// App ID Firebase à utiliser sur la plateforme courante (vide si absent).
  static String firebaseAppIdFor(TargetPlatform platform) =>
      platform == TargetPlatform.iOS ? firebaseIosAppId : firebaseAppId;

  /// Firebase est-il configuré dans ce build pour cette plateforme ? Sinon les
  /// fonctions entre potes sont désactivées et l'app fonctionne en solo.
  static bool get firebaseConfigured => firebaseConfiguredFor(defaultTargetPlatform);

  static bool firebaseConfiguredFor(TargetPlatform platform) =>
      firebaseApiKey.isNotEmpty &&
      firebaseAppIdFor(platform).isNotEmpty &&
      firebaseProjectId.isNotEmpty &&
      firebaseDatabaseUrl.isNotEmpty;

  /// Identifiant envoyé aux services publics (politique d'usage OSM/FOSSGIS).
  static const userAgent = 'ConoMoto/1.0 (+https://github.com/mvlemincks-ouwba/cono-moto)';
}

/// Points d'accès des services gratuits utilisés par l'app.
class Endpoints {
  Endpoints._();

  /// Prix des carburants en France (flux instantané officiel, sans clé).
  static const fuelPrices =
      'https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/prix-des-carburants-en-france-flux-instantane-v2/records';

  /// Calcul d'itinéraire moto (Valhalla FOSSGIS, sans clé, usage raisonnable).
  static const valhalla = 'https://valhalla1.openstreetmap.de/route';

  /// Requêtes OpenStreetMap (forêts, cols…).
  static const overpass = 'https://overpass-api.de/api/interpreter';

  /// Serveurs Overpass essayés dans l'ordre : le serveur principal est souvent
  /// saturé (ou limite les adresses IP partagées des réseaux mobiles).
  static const overpassMirrors = [
    overpass,
    'https://overpass.private.coffee/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  /// Météo (sans clé).
  static const openMeteo = 'https://api.open-meteo.com/v1/forecast';

  /// Altitude (sans clé).
  static const openMeteoElevation = 'https://api.open-meteo.com/v1/elevation';

  /// Incidents de circulation (clé TomTom gratuite requise).
  static const tomtomIncidents = 'https://api.tomtom.com/traffic/services/5/incidentDetails';

  /// Recherche d'adresses (Photon / Komoot, sans clé).
  static const geocoder = 'https://photon.komoot.io/api/';
}
