# 🏍️ Cono Moto

L'app Android gratuite pour les balades moto entre potes : trouver de belles routes, suivre sa trace,
voir ses potes en direct, faire le plein au meilleur prix et savoir à quel point on penche.

## Ce que fait l'app

| | |
|---|---|
| 🗺️ **Balades à faire** | Génération de boucles ou d'allers simples selon le type de tracé : **sinueux, forêt, cols & montagne, plat & cool, rapide, mixte**. Score de sinuosité, dénivelé, météo sur le parcours, import/export GPX, balades partagées par les potes. |
| 📍 **Suivi GPS** | Enregistrement de la balade même écran éteint, guidage virage par virage avec annonces vocales, recalcul si tu sors de l'itinéraire. |
| 📐 **Angle d'inclinaison** | Jauge en direct, angle max gauche/droite, répartition des angles (téléphone fixé sur le guidon). |
| 📊 **Stats** | Vitesse moyenne/max, freinages et accélérations forts, D+, nombre de virages, records, km par mois. |
| 🕓 **Historique** | Toutes tes balades avec carte, graphes vitesse/angle, coût de la balade, « refaire cette balade ». |
| ⛽ **Essence** | Stations autour de toi ou le long de l'itinéraire avec le **prix du moment** (données officielles prix-carburants.gouv.fr), la moins chère mise en avant, prix affichés directement sur la carte. |
| 💶 **Coût des balades** | Pleins, péages, restos… coût par balade, coût au km, conso calculée automatiquement. |
| 🛢️ **Autonomie** | Estimation des km restants dans le réservoir, alerte avant la panne sèche avec les stations sur ta route. |
| 🔧 **Carnet d'entretien** | Graissage chaîne, vidange, pneus, plaquettes, révision : rappels au kilométrage. |
| 🚧 **Trafic temps réel** | Accidents, travaux, routes fermées sur la carte, alerte si un incident est sur ton itinéraire. |
| 👥 **Potes en direct** | Positions des potes sur la carte, statut (en balade à 87 km/h, vu il y a 2 h…). |
| 📢 **Signalements** | Gravillons, contrôle, danger, huile… visibles par tes potes. |
| 🏁 **Mode groupe** | Point de regroupement partagé, alerte quand un pote décroche. |
| 🧾 **Partage des frais** | Façon Tricount : qui a payé quoi, qui doit combien à qui. |
| 🔗 **Partage de position** | Lien web de suivi en direct pour quelqu'un qui n'a pas l'app (valable 1 h, 4 h ou 12 h). |
| 🆘 **Détection de chute** | Choc violent puis immobilité → compte à rebours, puis SMS automatique avec ta position à ton contact d'urgence + alerte aux potes. |
| 📴 **Cartes hors-ligne** | Télécharge une zone ou le couloir d'une balade avant de partir en zone blanche. |

Tout est gratuit : cartes OpenFreeMap / OpenStreetMap, itinéraires Valhalla (FOSSGIS), météo Open-Meteo,
prix officiels des carburants, Firebase (offre gratuite) pour les potes, TomTom (offre gratuite) pour le trafic.

---

## 📲 Installer l'app sur ton téléphone

L'APK est compilé automatiquement par GitHub Actions à chaque push.

1. Sur GitHub, onglet **Actions** › dernier run **« APK Android »** réussi › section **Artifacts** › télécharge
   **cono-moto-apk** (un zip qui contient `cono-moto.apk`).
   Sur la branche `main`, l'APK est aussi publié dans la release **« derniere-version »** (onglet *Releases*).
2. Copie `cono-moto.apk` sur le téléphone et ouvre-le. Android te demandera d'autoriser l'installation
   depuis cette source (« sources inconnues ») : accepte.
3. Les mises à jour s'installent par-dessus sans perdre tes données (toutes les versions sont signées avec la même clé).

> L'app fonctionne **immédiatement en mode solo** (balades, GPS, stats, essence, garage, cartes hors-ligne).
> Pour les fonctions entre potes et le trafic, il faut les clés ci-dessous (15 minutes, une seule fois).

---

## ⚙️ Configuration (une seule fois)

Les clés se mettent dans les **secrets du dépôt GitHub** : *Settings › Secrets and variables › Actions ›
New repository secret*. Le prochain build les intègre automatiquement.

### 1. Firebase (potes en direct, groupes, partage) — gratuit

1. Va sur <https://console.firebase.google.com> › **Ajouter un projet** (Google Analytics inutile).
2. **Build › Authentication** › *Get started* › active **E-mail/Mot de passe**.
3. **Build › Realtime Database** › *Créer une base de données* › emplacement **europe-west1** ›
   démarrer en **mode verrouillé**. Puis onglet **Règles** : colle le contenu de
   [`firebase/database.rules.json`](firebase/database.rules.json) et publie.
4. **Paramètres du projet** (roue dentée) › *Vos applications* › icône **Android** › nom du package
   `fr.conomoto.cono_moto` › enregistrer (pas besoin de télécharger `google-services.json`).
5. Dans les paramètres du projet, récupère et ajoute ces secrets GitHub :

| Secret GitHub | Où le trouver |
|---|---|
| `FIREBASE_API_KEY` | Paramètres du projet › Général › *Clé API Web* |
| `FIREBASE_APP_ID` | Paramètres › Vos applications › appli Android › *ID d'application* (`1:…:android:…`) |
| `FIREBASE_MESSAGING_SENDER_ID` | Paramètres › Cloud Messaging › *ID de l'expéditeur* (le nombre au milieu de l'App ID) |
| `FIREBASE_PROJECT_ID` | Paramètres › Général › *ID du projet* |
| `FIREBASE_DATABASE_URL` | Realtime Database › l'URL en haut (`https://<projet>-default-rtdb.europe-west1.firebasedatabase.app`) |
| `FIREBASE_STORAGE_BUCKET` | (facultatif) Paramètres › Général › *Bucket de stockage* |

L'offre gratuite (Spark) suffit largement pour une bande de potes.

### 2. Page de suivi en direct (lien pour quelqu'un sans l'app) — gratuit

La page [`web_share/live.html`](web_share/live.html) s'héberge gratuitement sur Firebase Hosting :

```bash
npm install -g firebase-tools
firebase login
cd firebase
firebase use --add            # choisis ton projet
firebase deploy --only hosting,database
```

Puis ajoute le secret `SHARE_VIEWER_URL` = `https://<projet>.web.app/live.html`.
Détails dans [`firebase/README.md`](firebase/README.md).

### 3. Trafic temps réel (accidents, travaux, fermetures) — gratuit

1. Crée un compte sur <https://developer.tomtom.com> et copie ta clé API (offre gratuite : 2 500 requêtes/jour).
2. Soit tu ajoutes le secret GitHub `TOMTOM_API_KEY` (clé intégrée pour tous), soit chacun colle la clé dans
   l'app : **Garage › ⚙ Réglages › Trafic en temps réel › Clé TomTom**.

### 4. (Facultatif) Ta propre clé de signature

Par défaut, l'APK est signé avec la clé partagée `android/app/cono-shared.keystore` versionnée dans ce dépôt
privé (pratique pour installer les mises à jour par-dessus). Pour utiliser ta propre clé, ajoute les secrets
`KEYSTORE_BASE64` (keystore encodé en base64), `KEYSTORE_PASSWORD`, `KEY_ALIAS` et `KEY_PASSWORD`.
⚠️ Changer de clé oblige à désinstaller l'ancienne version (les données locales sont perdues).

---

## 🧑‍💻 Développement

- Flutter **3.47** / Dart 3.13, Android uniquement pour l'instant (le code Flutter est prêt pour iOS plus tard).
- Architecture : Riverpod 3 (sans génération de code), SQLite (`sqflite`) pour les données locales,
  Firebase Realtime Database pour les potes, MapLibre pour la carte.

```bash
flutter pub get
flutter analyze
flutter test
flutter run --dart-define-from-file=build-config.json   # facultatif : clés en local
```

`build-config.json` (non versionné) a le même format que celui généré par la CI :

```json
{
  "FIREBASE_API_KEY": "...", "FIREBASE_APP_ID": "...", "FIREBASE_MESSAGING_SENDER_ID": "...",
  "FIREBASE_PROJECT_ID": "...", "FIREBASE_DATABASE_URL": "...", "FIREBASE_STORAGE_BUCKET": "",
  "TOMTOM_API_KEY": "...", "SHARE_VIEWER_URL": "..."
}
```

### Organisation du code

```
lib/
  core/          socle : géo, carte (CmMap), thème, réglages, localisation, notifications
  data/          modèles, base SQLite, dépôts
  features/
    map/         carte principale (potes, signalements, trafic, stations, bouton Rouler)
    ride/        balade en cours : GPS, capteurs, angle, chute, HUD, récap
    routes/      balades à faire : génération, guidage, météo, GPX
    social/      potes, groupes, frais partagés, partage de position, SOS
    fuel/        stations et pleins
    garage/      motos, autonomie, entretien, coûts
    history/     historique, détail d'une balade, stats
    traffic/     incidents TomTom
    offline/     cartes hors-ligne
    settings/    réglages
  services/      clients des API (carburants, itinéraires, trafic, Firebase…)
web_share/       page web de suivi en direct
firebase/        règles de sécurité et hébergement
```

### Sources de données

© contributeurs [OpenStreetMap](https://www.openstreetmap.org/copyright), [OpenFreeMap](https://openfreemap.org),
[prix-carburants.gouv.fr](https://www.prix-carburants.gouv.fr) (licence ouverte),
[Valhalla / FOSSGIS](https://valhalla1.openstreetmap.de), [Open-Meteo](https://open-meteo.com),
[TomTom](https://developer.tomtom.com), [Photon / Komoot](https://photon.komoot.io).
