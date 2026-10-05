# Cono Moto · Firebase (module « Potes »)

Sans Firebase, Cono Moto marche **en solo** : carte, balades, historique,
garage… tout fonctionne, et l'onglet *Potes* affiche une carte explicative.

Avec Firebase (offre gratuite **Spark**, sans carte bancaire), tu débloques :

- comptes (e-mail + mot de passe), profil, **code ami** à 6 caractères ;
- **positions en direct** des potes pendant les balades, alerte **SOS** ;
- **signalements** entre potes (gravillons, contrôle, travaux…) ;
- **groupes** : point de regroupement, alerte « pote qui décroche », **frais partagés** ;
- **lien de suivi web** pour un proche qui n'a pas l'app ;
- partage d'itinéraires et de balades enregistrées dans le fil des potes.

On n'utilise que **Authentication** et **Realtime Database** (+ **Hosting**
pour la page de suivi). Ni Firestore, ni Cloud Functions : tout tient dans
l'offre gratuite.

Contenu de ce dossier :

| Fichier | Rôle |
| --- | --- |
| `database.rules.json` | Règles de sécurité de la Realtime Database (expliquées plus bas) |
| `firebase.json` | Configuration CLI : règles + hébergement de `web_share/` |
| `deploy.sh` | Déploie règles et page de suivi en une commande |
| `rules.test.mjs` | 88 scénarios de test des règles contre l'émulateur |

---

## 1. Créer le projet Firebase (10 minutes)

1. Va sur <https://console.firebase.google.com> › **Ajouter un projet**
   (Google Analytics inutile). Le projet démarre sur l'offre **Spark** (gratuite).
2. **Authentication** › *Commencer* › *Méthode de connexion* › **Adresse e-mail/Mot de passe** › *Activer*.
   Dans *Modèles*, passe la langue des e-mails en **français** (e-mail « mot de passe oublié »).
3. **Realtime Database** › *Créer une base de données* › emplacement **europe-west1 (Belgique)**
   › démarrer en **mode verrouillé**. Note l'URL affichée, du type
   `https://mon-projet-default-rtdb.europe-west1.firebasedatabase.app`.
4. **Paramètres du projet** › *Général* › *Vos applications* › icône **Android** :
   nom de package `fr.conomoto.cono_moto`. Le fichier `google-services.json`
   n'est **pas** nécessaire (la config est passée à la compilation), mais il
   contient les valeurs dont tu as besoin :

   | Valeur | Où la trouver | `--dart-define` |
   | --- | --- | --- |
   | Clé API | `client[0].api_key[0].current_key` (ou « Clé API Web » dans *Général*) | `FIREBASE_API_KEY` |
   | ID d'application | `client[0].client_info.mobilesdk_app_id` (`1:…:android:…`) | `FIREBASE_APP_ID` |
   | N° d'expéditeur | `project_info.project_number` | `FIREBASE_MESSAGING_SENDER_ID` |
   | ID du projet | `project_info.project_id` | `FIREBASE_PROJECT_ID` |
   | URL de la base | étape 3 | `FIREBASE_DATABASE_URL` |
   | Bucket (facultatif) | `project_info.storage_bucket` | `FIREBASE_STORAGE_BUCKET` |

## 2. Déployer les règles et la page de suivi

```bash
npm install -g firebase-tools
firebase login
cd firebase
firebase use --add          # choisis ton projet (crée .firebaserc)
./deploy.sh                 # règles RTDB + page web_share/live.html
```

`deploy.sh` recopie `../web_share` dans `firebase/web_share` (Hosting ne sert
que des fichiers situés sous le dossier de `firebase.json` ; la copie est
ignorée par git), puis lance `firebase deploy --only database,hosting`.

La page de suivi est alors en ligne sur `https://mon-projet.web.app/live.html` :
c'est la valeur de **`SHARE_VIEWER_URL`**.

> Pas envie d'installer la CLI ? Copie-colle `database.rules.json` dans la
> console (*Realtime Database › Règles › Publier*). Sans page déployée, l'app
> fonctionne, seul le bouton « Lien de suivi » explique qu'il manque la page.

## 3. Compiler l'app avec Firebase

En local :

```bash
flutter build apk --release \
  --dart-define=FIREBASE_API_KEY=AIza... \
  --dart-define=FIREBASE_APP_ID=1:1234567890:android:abc123 \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=1234567890 \
  --dart-define=FIREBASE_PROJECT_ID=mon-projet \
  --dart-define=FIREBASE_DATABASE_URL=https://mon-projet-default-rtdb.europe-west1.firebasedatabase.app \
  --dart-define=SHARE_VIEWER_URL=https://mon-projet.web.app/live.html
```

Sur GitHub Actions (`.github/workflows/android.yml`) : ajoute ces valeurs dans
*Settings › Secrets and variables › Actions*, avec exactement les mêmes noms
(`FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`,
`FIREBASE_PROJECT_ID`, `FIREBASE_DATABASE_URL`, `FIREBASE_STORAGE_BUCKET`,
`SHARE_VIEWER_URL`). Le workflow les transmet via `--dart-define-from-file`.

Les quatre premières + l'URL de la base suffisent à activer le mode potes.

---

## 4. Modèle de données (Realtime Database)

```text
users/{uid}/profile            { name, color, bike, code, createdAt }
friendCodes/{CODE}             uid                       ← code ami → uid
friends/{uid}/{friendUid}      true                      ← liste de potes (lien mutuel)
friendProofs/{uid}/{fromUid}   { code } | { group }      ← preuve d'invitation (voir règles)
live/{uid}                     { lat, lng, speed, heading, lean, ts, riding,
                                 name, color, bike, sos, sosMessage, sosAt }
reports/{uid}/{id}             { type, lat, lng, comment, ts, expiresAt, authorName }
groups/{gid}                   { name, createdBy, createdAt,
                                 members/{uid}: { name, color, joinedAt },
                                 rally: { lat, lng, label, setBy, setByName, setAt },
                                 expenses/{eid}: { label, amount, paidBy, participants/{uid}: true,
                                                   category, ts, createdBy },
                                 settlements/{sid}: { from, to, amount, ts, createdBy } }
userGroups/{uid}/{gid}         true                      ← index « mes groupes »
shares/{token}                 { uid, name, color, lat, lng, speed, heading, riding, ts,
                                 createdAt, expiresAt, active, trail, sos, sosMessage }
userShares/{uid}/{token}       expiresAt                 ← index « mes liens de suivi »
sharedRoutes/{uid}/{routeId}   PlannedRoute.toJson() + sharedAt
sharedRides/{uid}/{rideId}     { name, startedAt, endedAt, distanceM, movingTimeS, maxSpeedKmh,
                                 avgSpeedKmh, maxLeanDeg, elevationGainM, previewPolyline,
                                 authorName, authorColor, sharedAt }
```

Conventions :

- **Unités** : `speed` en km/h, distances en mètres, dates en millisecondes
  epoch (UTC). `ts` est l'horodatage **serveur** (`ServerValue.timestamp`).
- **Montants** en **centimes** (entiers) : pas d'erreur d'arrondi.
- **Codes** : alphabet sans caractères ambigus `ABCDEFGHJKMNPQRSTUVWXYZ23456789`
  (ni 0/O, ni 1/I/L). Code ami : 6 caractères (ex. `K7PM2X`) ; groupe : 8
  caractères, qui sont aussi **l'identifiant du groupe** (affiché `ABCD-EFGH`).
- **Jeton de lien de suivi** : 32 caractères alphanumériques tirés avec
  `Random.secure()` (~190 bits : impossible à deviner).
- Les **index** `userGroups` et `userShares` évitent de lire des nœuds entiers
  (les règles interdisent de lister `groups/` ou `shares/`).

### Qui écrit quoi

| Action dans l'app | Écriture (atomique, multi-chemins) |
| --- | --- |
| Création du profil | `users/{moi}/profile` + `friendCodes/{CODE}` |
| Ajout d'un pote par code | `friends/{moi}/{lui}`, `friends/{lui}/{moi}`, `friendProofs/{lui}/{moi} = {code}` |
| Rejoindre un groupe | `groups/{gid}/members/{moi}` + `userGroups/{moi}/{gid}`, puis un lien d'amitié par membre avec `friendProofs/{membre}/{moi} = {group: gid}` |
| Balade en cours | `live/{moi}` (au plus toutes les 5 s ou 50 m, jamais plus d'une fois / 2 s), `onDisconnect` → `riding=false` |
| Lien de suivi | `shares/{token}` + `userShares/{moi}/{token}`, position mise à jour pendant la balade, traînée toutes les 60 s |
| SOS | `live/{moi}.sos = true` (+ message, position) et `shares/{token}.sos` pour les liens actifs |

**Rejoindre un groupe = devenir pote avec ses membres** : c'est ce qui permet
de voir les membres sur la carte et de détecter celui qui décroche (les
positions en direct ne sont lisibles que par les potes).

---

## 5. Règles de sécurité expliquées

Tout est **fermé par défaut** (`.read`/`.write` à `false` à la racine) ; chaque
nœud ouvre le strict nécessaire et **valide** la forme des données (types,
longueurs, bornes, champs inconnus refusés via `$other`).

- **`users/{uid}/profile`** : écrit par son propriétaire uniquement ; lisible
  par lui et par ceux qu'il a dans ses potes
  (`root.child('friends/'+$uid+'/'+auth.uid).exists()`). Le champ `code` doit
  correspondre à un `friendCodes/{CODE}` réservé par ce même uid.
- **`friendCodes/{CODE}`** : lecture d'**un** code par un utilisateur connecté
  (impossible de lister tous les codes) ; réservation seulement si le code est
  libre, libération seulement par son propriétaire. Format vérifié.
- **`friends/{uid}/{friendUid}`** : liste lisible par son propriétaire seul.
  J'écris librement dans **ma** liste ; je ne peux écrire `friends/{lui}/{moi}`
  **que pour moi** et seulement si, dans la même écriture, existe une
  **preuve** `friendProofs/{lui}/{moi}` ; le retrait (valeur nulle) est
  toujours permis. Valeur `true` obligatoire, et le pote doit avoir un profil.
- **`friendProofs/{uid}/{from}`** : écrit par `from` seulement, et valide si
  `code` est le code ami actuel de `uid`, **ou** si `group` désigne un groupe
  dont `uid` et `from` sont tous deux membres. Personne ne peut donc s'inviter
  dans la liste d'un motard sans son code ou sans groupe commun.
- **`live/{uid}`** : écrit par son propriétaire ; lisible par lui et ses potes.
  Coordonnées bornées, `ts` pas dans le futur (± 60 s), message SOS ≤ 500 car.
- **`reports/{uid}/{id}`** : écrits par leur auteur, lisibles par ses potes ;
  durée de vie ≤ 32 jours, commentaire ≤ 200 caractères.
- **`groups/{gid}`** : lisible **par les membres** uniquement. Création si le
  gid est libre, que `createdBy` est moi et que j'en suis membre ; suppression
  par le créateur seul. **Un utilisateur peut s'ajouter (ou se retirer)
  lui-même** des membres d'un groupe existant : connaître le code = être
  invité. Nom, regroupement, dépenses et remboursements sont modifiables par
  tout membre (comme un Tricount) ; `rally.setBy` doit être l'auteur ;
  montants entiers positifs ; pas de remboursement à soi-même.
- **`userGroups/{uid}`, `userShares/{uid}`** : privés (propriétaire seul).
- **`shares/{token}`** : **lecture publique d'un jeton précis** (pour la page
  web, sans compte) mais **impossible de lister** `shares/`. Écrit seulement par
  le propriétaire (`uid`), durée ≤ 14 h, jeton de 20 à 64 caractères
  alphanumériques.
- **`sharedRoutes/{uid}`, `sharedRides/{uid}`** : écrits par leur auteur,
  lisibles par ses potes ; index `.indexOn: ["sharedAt"]` pour la requête
  « 25 plus récents » ; tailles bornées.

### Tester les règles

`rules.test.mjs` rejoue 88 scénarios (ce qui doit passer **et** ce qui doit
être refusé : vol de code, ajout sans code, lecture de position par un
inconnu, écrasement de groupe, lien de suivi modifié par un tiers…) via
l'API REST de l'émulateur, sans dépendance npm (Node ≥ 18) :

```bash
cd firebase
firebase emulators:exec --only database "node rules.test.mjs"
# ou, avec un émulateur déjà lancé sur le port 9000 :
FIREBASE_DATABASE_EMULATOR_HOST=127.0.0.1:9000 node rules.test.mjs
```

---

## 6. La page de suivi web (`web_share/live.html`)

Page **statique et autonome** (HTML + JS, aucune compilation), en français,
optimisée mobile, thème sombre et orange de l'app :

- carte **MapLibre GL JS** (chargée depuis unpkg) avec le style
  **OpenFreeMap Liberty** (gratuit, sans clé) ;
- lit `https://<base>/shares/<jeton>.json` **en streaming** grâce à l'API
  REST de la Realtime Database et à `EventSource` (évènements `put`/`patch`) :
  aucune clé, aucun SDK, aucun compte ;
- marqueur à la couleur du motard (flèche de cap), traînée orange, vitesse,
  « mis à jour il y a… », boutons *Recentrer* et *Itinéraire* (Google Maps),
  bandeau rouge en cas de **SOS**, états *signal perdu*, *partage terminé*,
  *lien incomplet* et *partage introuvable*.

URL partagée par l'app :
`SHARE_VIEWER_URL?db=<URL de la base encodée>&t=<jeton>`. La page n'accepte
que des bases `*.firebasedatabase.app` / `*.firebaseio.com`, est servie avec
`noindex` et `Referrer-Policy: no-referrer` (le jeton ne fuit pas vers les
tuiles de carte).

Vie privée : le lien expire tout seul (1 h, 4 h ou 12 h), le motard peut
l'arrêter à tout moment (*Arrêter le partage*), et les liens expirés sont
désactivés au prochain lancement de l'app.

---

## 7. Coût : l'offre gratuite suffit largement

Limites Spark (Realtime Database) : 100 connexions simultanées, 1 Go stocké,
10 Go téléchargés par mois. Une mise à jour de position pèse ~250 octets :
un motard suivi par 5 potes pendant 3 h (une mise à jour toutes les 5 s)
consomme environ 3 Mo. Les signalements, liens et points de regroupement
expirent ou se nettoient tout seuls. Hosting gratuit : 10 Go de transfert/mois
pour une page de quelques ko.

## 8. Dépannage

| Symptôme | Cause probable |
| --- | --- |
| « Le serveur a refusé l'opération » | Règles non déployées (étape 2) ou base créée dans un autre projet |
| « La connexion par e-mail n'est pas activée » | Fournisseur E-mail/Mot de passe non activé (étape 1.2) |
| L'onglet Potes reste en « mode solo » | Une des valeurs `FIREBASE_*` manque à la compilation |
| Le bouton « Lien de suivi » explique qu'il manque la page | `SHARE_VIEWER_URL` vide : déploie la page (étape 2) et recompile |
| La page affiche « Lien incomplet » | Lien tronqué par la messagerie : renvoie-le |
| E-mail « mot de passe oublié » introuvable | Regarde les spams ; règle la langue des modèles sur le français |
