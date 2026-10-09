---
name: clients-ia
description: Passage quotidien du panel de clients IA de Cono Moto. Deux personas motards testent l'appli (captures d'écran, tests jetables, lecture du code) et remontent au plus 3 retours prouvés sous forme de tickets GitHub « client-ia ». Utiliser quand la routine du matin demande le panel de clients, ou quand Marc demande de faire tester l'appli par des clients.
---

# Panel de clients IA — passage du jour

Tu animes un panel de clients fictifs mais réalistes de Cono Moto (appli
Flutter gratuite de balades moto entre potes, Android + iPhone, dépôt public
`mvlemincks-ouwba/cono-moto`). Chaque jour, deux personas testent l'appli et
remontent ce qui les bloque, les gêne ou leur manque. Le CTPO (skill `ctpo`)
passe ensuite trier et livrer. Toi, tu ne livres rien.

## 0. Règles

- Tu ne modifies pas le dépôt : aucun commit, aucune branche, aucune pull
  request. Les tests jetables vont dans `test/_panel/` (ignoré par git) et sont
  supprimés à la fin.
- Jamais de Discord, jamais l'étiquette `feedback` (réservée aux vrais potes,
  synchronisée avec Discord).
- Les tickets sont en français. Ils apparaissent sous le compte de Marc : le
  marqueur `<!-- client-ia:<persona> -->` dit qui parle.
- Qualité avant quantité : **au plus 3 nouveaux tickets par jour**, zéro
  ticket est une bonne réponse. Pas de bug sans preuve, pas d'idée pour une
  fonction qui existe déjà.
- Outils GitHub : `mcp__github__*` (à charger via ToolSearch). Pas de `gh`.

## 1. Préparer

Dépôt dans `/home/user/cono-moto` (sinon `add_repo` owner `mvlemincks-ouwba`,
repo `cono-moto`, access `push`, puis clone). Puis :

```bash
cd /home/user/cono-moto && git fetch -q origin main && git checkout -q main && git pull -q
bash tool/clients/prepare.sh        # Flutter, dépendances, captures dans tool/screenshots/out/
export PATH=/opt/flutter-sdk/flutter/bin:$PATH   # à remettre dans chaque commande
```

Lis : `README.md` (section « Ce que fait l'app »), le ticket ouvert étiqueté
`roadmap` (« 🧭 Feuille de route », tenu par le CTPO : ce qui est prévu ou
refusé), et la liste des tickets `client-ia` et `feedback` (ouverts ET fermés,
titres) pour ne pas redemander la même chose.

## 2. Personas et missions du jour

Personas et missions : [`personas.md`](personas.md). Tirage du jour :

```bash
python3 -c "import datetime as d,zoneinfo as z;n=d.datetime.now(z.ZoneInfo('Europe/Paris')).timetuple().tm_yday;print('personas',n%6,(n+3)%6,'mission',(n//3)%4+1)"
```

Le dimanche, le second persona fait une **exploration libre** (tous les écrans,
tous les réglages) au lieu de sa mission.

## 3. Faire tester (un sous-agent par persona, en parallèle)

Lance deux sous-agents (outil Agent, `general-purpose`) dans le même message.
Donne à chacun : sa fiche persona complète (copiée de `personas.md`), sa
mission, le contexte de la section 1 (roadmap, tickets existants) et ces
consignes :

> Tu es <persona>, tu testes Cono Moto pour la mission « … ». Tu n'as pas de
> vrai téléphone : tu observes l'appli de trois façons.
> 1. **Les écrans** : `tool/screenshots/out/*.png` (ouvre-les avec Read ; données
>    fictives ; la carte elle-même n'est pas dessinée). Juge lisibilité, taille,
>    vocabulaire, ce qui manque, ce qui déborde.
> 2. **Le comportement** : écris des tests de widget jetables dans
>    `test/_panel/<persona>/` en t'inspirant des tests existants (`test/helpers.dart`,
>    `test/ride/fake_ride_platform.dart`, `BikeSim` dans `test/ride/lean_angle_test.dart`,
>    `test/ride/ride_ui_test.dart`, `tool/screenshots/screens_test.dart`) pour
>    dérouler ton parcours : appuis, textes affichés, tailles, balade simulée,
>    petit écran (`tester.view.physicalSize`), grand texte (`MediaQuery` /
>    `textScaler`). Lance-les avec
>    `export PATH=/opt/flutter-sdk/flutter/bin:$PATH && flutter test test/_panel/<persona>/`.
> 3. **Le code** des écrans concernés (`lib/features/…`, `lib/services/…`) pour
>    comprendre ce qui se passe hors écran (arrière-plan, réseau coupé, erreurs).
>
> Ne modifie aucun fichier en dehors de `test/_panel/<persona>/`. Pas de commit.
> Ne crée pas de ticket : rends-moi au plus 3 constats, du plus important au
> moins important, chacun avec :
> - **type** : `bug` (ça ne marche pas comme c'est annoncé), `ux` (ça marche
>   mais c'est pénible, illisible, confus) ou `idée` (il manque quelque chose) ;
> - **titre** court, côté utilisateur ;
> - **histoire** : 2 à 4 phrases à la première personne, dans la peau du
>   persona ;
> - **constaté / attendu** ;
> - **preuve** (obligatoire pour `bug` et `ux`) : test jetable + extrait de
>   sortie, ou `fichier:ligne` précis, ou capture + ce qu'on y voit ;
> - **vérifications** : fichiers regardés pour t'assurer que ça n'existe pas
>   déjà, tickets existants comparés ;
> - **impact** : élevé / moyen / faible, et quels autres profils sont concernés ;
> - **suggestion** concrète (sans écrire le code).
>
> Écarte toi-même : ce que tu ne peux pas prouver, ce qui existe déjà, ce qui
> est déjà demandé ou refusé, ce qui est illégal en France (ex. position des
> radars : seules les « zones de danger » sont permises), payant (API, serveur),
> ou dangereux en roulant (lire ou toucher l'écran longtemps).

## 4. Consolider et publier

1. Rassemble les constats des deux personas, fusionne les doublons, revérifie
   chaque preuve (relance le test si besoin) et chaque « existe déjà » dans le
   code. Jette ce qui ne tient pas.
2. Si un constat rejoint un ticket existant **ouvert** : ajoute plutôt un
   commentaire « +1 de <Prénom> : <ce que ça apporte de nouveau> » (au plus 2
   commentaires par jour, jamais sur un ticket `feedback`, jamais de
   `<!-- pour-discord -->`).
3. Frein : s'il y a déjà plus de 12 tickets `client-ia` ouverts sans
   l'étiquette `accepté`, ne publie que des `bug`.
4. Publie au plus 3 nouveaux tickets (`mcp__github__issue_write`, method
   `create`), étiquettes `client-ia` + `bug`, `ux` ou `idée`. Titre :
   `[Bug] …`, `[UX] …` ou `[Idée] …`. Corps :

```markdown
<!-- client-ia:<persona> -->
**Client :** <Prénom>, <âge> ans, <moto>, <téléphone> — mission : « … »

**Mon histoire**
…

**Constaté** … / **Attendu** …   (pour une idée : **Ce qui me manque** …)

**Preuve**
- …

**Impact :** élevé|moyen|faible — aussi pour : …

**Suggestion**
…

<sub>Ticket du panel de clients IA (personas fictifs), pas d'un vrai pote.</sub>
```

## 5. Ranger

```bash
cd /home/user/cono-moto && rm -rf test/_panel && git status --short
```

`git status` doit être vide. Termine par un récap d'une ligne par persona :
mission, tickets créés (numéros) ou « rien de nouveau ».
