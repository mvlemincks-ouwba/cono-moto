/// Configuration injectée à la compilation via `--dart-define`
/// (voir README et `.github/workflows/android.yml`).
class AppConfig {
  AppConfig._();

  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseMessagingSenderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const firebaseDatabaseUrl = String.fromEnvironment('FIREBASE_DATABASE_URL');
  static const firebaseStorageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');

  /// Clé TomTom par défaut (modifiable dans les réglages de l'app).
  static const tomtomApiKey = String.fromEnvironment('TOMTOM_API_KEY');

  /// URL de la page web de suivi en direct (ex : https://mon-projet.web.app/live.html).
  static const shareViewerUrl = String.fromEnvironment('SHARE_VIEWER_URL');

  /// Firebase est-il configuré dans ce build ? Sinon les fonctions entre potes
  /// sont désactivées et l'app fonctionne en solo.
  static bool get firebaseConfigured =>
      firebaseApiKey.isNotEmpty &&
      firebaseAppId.isNotEmpty &&
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

  /// Météo (sans clé).
  static const openMeteo = 'https://api.open-meteo.com/v1/forecast';

  /// Altitude (sans clé).
  static const openMeteoElevation = 'https://api.open-meteo.com/v1/elevation';

  /// Incidents de circulation (clé TomTom gratuite requise).
  static const tomtomIncidents = 'https://api.tomtom.com/traffic/services/5/incidentDetails';

  /// Recherche d'adresses (Photon / Komoot, sans clé).
  static const geocoder = 'https://photon.komoot.io/api/';
}
