// Tests des règles de sécurité (firebase/database.rules.json) contre
// l'émulateur Realtime Database, via l'API REST. Aucune dépendance npm.
//
// Depuis le dossier firebase/ :
//   firebase emulators:exec --only database "node rules.test.mjs"
// ou avec un émulateur déjà lancé :
//   FIREBASE_DATABASE_EMULATOR_HOST=127.0.0.1:9000 node rules.test.mjs
import { readFileSync } from 'node:fs';

const HOST = process.env.FIREBASE_DATABASE_EMULATOR_HOST || '127.0.0.1:9000';
const BASE = `http://${HOST}`;
const NS = 'cono-moto-rules-test';
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const token = (uid) => {
  const now = Math.floor(Date.now() / 1000);
  return `${b64({ alg: 'none', typ: 'JWT' })}.${b64({
    iss: `https://securetoken.google.com/${NS}`, aud: NS, iat: now, exp: now + 3600, auth_time: now,
    sub: uid, user_id: uid, firebase: { sign_in_provider: 'password', identities: {} },
  })}.`;
};
async function req(method, path, uid, body, query = '') {
  const headers = { 'Content-Type': 'application/json' };
  if (uid === 'owner') headers.Authorization = 'Bearer owner';
  else if (uid) query += `&auth=${token(uid)}`;
  const r = await fetch(`${BASE}/${path}.json?ns=${NS}${query}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  return { ok: r.ok, status: r.status, text };
}
let pass = 0, fail = 0;
async function expect(label, shouldPass, p) {
  const r = await p;
  if (r.ok === shouldPass) { pass++; } else { fail++; console.log(`ÉCHEC: ${label} → ${r.status} ${r.text.slice(0, 200)}`); }
  return r;
}
const TS = { '.sv': 'timestamp' };
const now = Date.now();

// Charge les règles du dépôt puis repart d'une base vide.
const rules = readFileSync(new URL('./database.rules.json', import.meta.url), 'utf8');
const loaded = await fetch(`${BASE}/.settings/rules.json?ns=${NS}`, {
  method: 'PUT', headers: { Authorization: 'Bearer owner' }, body: rules,
});
if (!loaded.ok) {
  console.error('Règles refusées par l\'émulateur :', await loaded.text());
  process.exit(1);
}
await req('PUT', '', 'owner', null);

const profile = (name, code, color = 4281271990) => ({ name, color, bike: 'MT-07', code, createdAt: now });
// --- Profils et codes
await expect('alice crée son profil', true, req('PATCH', '', 'alice', { 'users/alice/profile': profile('Alice', 'K7PM2X'), 'friendCodes/K7PM2X': 'alice' }));
await expect('bob crée son profil', true, req('PATCH', '', 'bob', { 'users/bob/profile': profile('Bob', 'BBBB22'), 'friendCodes/BBBB22': 'bob' }));
await expect('carol crée son profil', true, req('PATCH', '', 'carol', { 'users/carol/profile': profile('Carol', 'CCCC33'), 'friendCodes/CCCC33': 'carol' }));
await expect('eve crée son profil', true, req('PATCH', '', 'eve', { 'users/eve/profile': profile('Eve', 'EEEE44'), 'friendCodes/EEEE44': 'eve' }));
await expect('eve vole le code d\'alice', false, req('PUT', 'friendCodes/K7PM2X', 'eve', 'eve'));
await expect('eve met un code non réservé', false, req('PATCH', 'users/eve/profile', 'eve', { code: 'XXXX55' }));
await expect('code ambigu (O/0) refusé', false, req('PUT', 'friendCodes/O0OO11', 'eve', 'eve'));
await expect('eve écrit le profil d\'alice', false, req('PATCH', 'users/alice/profile', 'eve', { name: 'Pwned' }));
await expect('alice renomme son profil', true, req('PATCH', '', 'alice', { 'users/alice/profile/name': 'Alice R', 'users/alice/profile/color': 1, 'users/alice/profile/bike': 'Tracer' }));
await expect('pseudo trop long refusé', false, req('PATCH', 'users/alice/profile', 'alice', { name: 'x'.repeat(30) }));
await expect('bob lit friendCodes/K7PM2X', true, req('GET', 'friendCodes/K7PM2X', 'bob'));
await expect('bob liste tous les codes', false, req('GET', 'friendCodes', 'bob'));
await expect('anonyme lit un code', false, req('GET', 'friendCodes/K7PM2X', null));
await expect('bob lit le profil d\'alice (pas encore potes)', false, req('GET', 'users/alice/profile', 'bob'));

// --- Amitié par code
await expect('bob ajoute alice avec son code', true, req('PATCH', '', 'bob', {
  'friends/bob/alice': true, 'friends/alice/bob': true, 'friendProofs/alice/bob': { code: 'K7PM2X' } }));
await expect('eve s\'ajoute chez alice sans code', false, req('PATCH', '', 'eve', { 'friends/eve/alice': true, 'friends/alice/eve': true }));
await expect('eve s\'ajoute chez alice avec un faux code', false, req('PATCH', '', 'eve', {
  'friends/eve/alice': true, 'friends/alice/eve': true, 'friendProofs/alice/eve': { code: 'BBBB22' } }));
await expect('eve écrit une preuve au nom de bob', false, req('PUT', 'friendProofs/alice/bob', 'eve', { code: 'K7PM2X' }));
await expect('bob lit le profil d\'alice (potes)', true, req('GET', 'users/alice/profile', 'bob'));
await expect('bob lit la liste d\'amis d\'alice', false, req('GET', 'friends/alice', 'bob'));
await expect('alice lit sa liste d\'amis', true, req('GET', 'friends/alice', 'alice'));
await expect('valeur non booléenne refusée', false, req('PUT', 'friends/bob/carol', 'bob', 'oui'));
await expect('ami sans profil refusé', false, req('PUT', 'friends/bob/ghost', 'bob', true));

// --- Position en direct
const live = { lat: 45.1, lng: 3.2, speed: 87.5, heading: 120, lean: -12, ts: TS, riding: true, name: 'Alice R', color: 1, bike: 'Tracer' };
await expect('alice publie sa position', true, req('PATCH', 'live/alice', 'alice', live));
await expect('bob lit la position d\'alice', true, req('GET', 'live/alice', 'bob'));
await expect('eve lit la position d\'alice', false, req('GET', 'live/alice', 'eve'));
await expect('anonyme lit la position d\'alice', false, req('GET', 'live/alice', null));
await expect('alice lit la position de bob (bob l\'a dans sa liste)', true, req('GET', 'live/bob', 'alice'));
await expect('eve écrit la position d\'alice', false, req('PATCH', 'live/alice', 'eve', { lat: 0 }));
await expect('champ inconnu refusé', false, req('PATCH', 'live/alice', 'alice', { hack: 1 }));
await expect('latitude hors bornes refusée', false, req('PATCH', 'live/alice', 'alice', { lat: 123 }));
await expect('SOS alice', true, req('PATCH', 'live/alice', 'alice', { sos: true, sosMessage: 'Chute détectée', sosAt: TS, lat: 45.2, lng: 3.3, ts: TS, speed: 0 }));
await expect('SOS annulé', true, req('PATCH', 'live/alice', 'alice', { sos: false, sosMessage: null, sosAt: null }));
await expect('fin de balade', true, req('PATCH', 'live/alice', 'alice', { riding: false, speed: 0, ts: TS }));

// --- Signalements
const report = { type: 'gravillons', lat: 45.1, lng: 3.2, comment: 'sortie de virage', ts: now, expiresAt: now + 7 * 86400000, authorName: 'Alice R' };
await expect('alice signale', true, req('POST', 'reports/alice', 'alice', report));
await expect('bob lit les signalements d\'alice', true, req('GET', 'reports/alice', 'bob'));
await expect('eve lit les signalements d\'alice', false, req('GET', 'reports/alice', 'eve'));
await expect('expiration trop lointaine refusée', false, req('POST', 'reports/alice', 'alice', { ...report, expiresAt: now + 90 * 86400000 }));
await expect('signalement incomplet refusé', false, req('POST', 'reports/alice', 'alice', { type: 'police', lat: 1, lng: 1, ts: now }));
await expect('eve signale chez alice', false, req('POST', 'reports/alice', 'eve', report));

// --- Groupes
const gid = 'ABCD2345';
const member = (name) => ({ name, color: 1, joinedAt: now });
await expect('alice crée un groupe', true, req('PATCH', '', 'alice', {
  [`groups/${gid}`]: { name: 'Les Virolos', createdBy: 'alice', createdAt: now, members: { alice: member('Alice R') } },
  [`userGroups/alice/${gid}`]: true }));
await expect('eve écrase le groupe', false, req('PATCH', '', 'eve', {
  [`groups/${gid}`]: { name: 'Pwned', createdBy: 'eve', createdAt: now, members: { eve: member('Eve') } } }));
await expect('groupe au nom de quelqu\'un d\'autre refusé', false, req('PATCH', '', 'eve', {
  'groups/EEEE2345': { name: 'X', createdBy: 'alice', members: { eve: member('Eve') } } }));
await expect('bob lit le groupe avant de rejoindre', false, req('GET', `groups/${gid}`, 'bob'));
await expect('bob rejoint avec un mauvais code', false, req('PATCH', '', 'bob', {
  'groups/ZZZZ9999/members/bob': member('Bob'), 'userGroups/bob/ZZZZ9999': true }));
await expect('bob rejoint le groupe', true, req('PATCH', '', 'bob', {
  [`groups/${gid}/members/bob`]: member('Bob'), [`userGroups/bob/${gid}`]: true }));
await expect('bob lit le groupe', true, req('GET', `groups/${gid}`, 'bob'));
await expect('carol rejoint le groupe', true, req('PATCH', '', 'carol', {
  [`groups/${gid}/members/carol`]: member('Carol'), [`userGroups/carol/${gid}`]: true }));
await expect('carol devient pote d\'alice via le groupe', true, req('PATCH', '', 'carol', {
  'friends/carol/alice': true, 'friends/alice/carol': true, 'friendProofs/alice/carol': { group: gid } }));
await expect('carol devient pote de bob via le groupe', true, req('PATCH', '', 'carol', {
  'friends/carol/bob': true, 'friends/bob/carol': true, 'friendProofs/bob/carol': { group: gid } }));
await expect('carol lit la position d\'alice', true, req('GET', 'live/alice', 'carol'));
await expect('eve se lie via un groupe dont elle n\'est pas membre', false, req('PATCH', '', 'eve', {
  'friends/eve/alice': true, 'friends/alice/eve': true, 'friendProofs/alice/eve': { group: gid } }));
await expect('eve ajoute bob au groupe', false, req('PATCH', '', 'eve', { [`groups/${gid}/members/eve`]: null, [`groups/${gid}/members/dave`]: member('Dave') }));
await expect('bob change de pseudo dans le groupe', true, req('PATCH', `groups/${gid}/members/bob`, 'bob', { name: 'Bobby', color: 2 }));
await expect('bob renomme le groupe', true, req('PUT', `groups/${gid}/name`, 'bob', 'Les Virolos du dimanche'));
await expect('eve renomme le groupe', false, req('PUT', `groups/${gid}/name`, 'eve', 'Pwned'));
const rally = (by) => ({ lat: 45.3, lng: 3.4, label: 'Parking du col', setBy: by, setByName: 'Bobby', setAt: now });
await expect('bob fixe le regroupement', true, req('PUT', `groups/${gid}/rally`, 'bob', rally('bob')));
await expect('regroupement au nom d\'un autre refusé', false, req('PUT', `groups/${gid}/rally`, 'bob', rally('alice')));
await expect('eve fixe le regroupement', false, req('PUT', `groups/${gid}/rally`, 'eve', rally('eve')));
const expense = { label: 'Plein', amount: 2350, paidBy: 'alice', participants: { alice: true, bob: true, carol: true }, category: 'essence', ts: now, createdBy: 'bob' };
await expect('bob ajoute une dépense', true, req('POST', `groups/${gid}/expenses`, 'bob', expense));
await expect('montant négatif refusé', false, req('POST', `groups/${gid}/expenses`, 'bob', { ...expense, amount: -5 }));
await expect('eve ajoute une dépense', false, req('POST', `groups/${gid}/expenses`, 'eve', expense));
await expect('remboursement', true, req('POST', `groups/${gid}/settlements`, 'carol', { from: 'carol', to: 'alice', amount: 783, ts: now, createdBy: 'carol' }));
await expect('remboursement à soi-même refusé', false, req('POST', `groups/${gid}/settlements`, 'carol', { from: 'carol', to: 'carol', amount: 783, ts: now }));
await expect('bob supprime le groupe (pas créateur)', false, req('DELETE', `groups/${gid}`, 'bob'));
await expect('bob retire alice du groupe', false, req('DELETE', `groups/${gid}/members/alice`, 'bob'));
await expect('bob quitte le groupe', true, req('PATCH', '', 'bob', { [`groups/${gid}/members/bob`]: null, [`userGroups/bob/${gid}`]: null }));
await expect('bob ne lit plus le groupe', false, req('GET', `groups/${gid}`, 'bob'));
await expect('alice supprime le groupe', true, req('DELETE', `groups/${gid}`, 'alice'));

// --- Lien de suivi
const tok = 'aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE';
await expect('alice crée un lien', true, req('PATCH', '', 'alice', {
  [`shares/${tok}`]: { uid: 'alice', name: 'Alice R', color: 1, createdAt: now, expiresAt: now + 4 * 3600000, active: true, ts: TS, lat: 45, lng: 3, speed: 50.5, heading: 90 },
  [`userShares/alice/${tok}`]: now + 4 * 3600000 }));
await expect('anonyme lit le lien', true, req('GET', `shares/${tok}`, null));
await expect('anonyme liste les liens', false, req('GET', 'shares', null));
await expect('eve modifie le lien d\'alice', false, req('PATCH', `shares/${tok}`, 'eve', { lat: 1 }));
await expect('eve crée un lien au nom d\'alice', false, req('PUT', 'shares/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz', 'eve', { uid: 'alice', expiresAt: now }));
await expect('lien de 48 h refusé', false, req('PUT', 'shares/yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy', 'alice', { uid: 'alice', expiresAt: now + 48 * 3600000 }));
await expect('jeton trop court refusé', false, req('PUT', 'shares/abc', 'alice', { uid: 'alice', expiresAt: now }));
await expect('mise à jour de position du lien', true, req('PATCH', '', 'alice', {
  [`shares/${tok}/lat`]: 45.01, [`shares/${tok}/lng`]: 3.01, [`shares/${tok}/speed`]: 80, [`shares/${tok}/heading`]: null,
  [`shares/${tok}/riding`]: true, [`shares/${tok}/ts`]: TS, [`shares/${tok}/trail`]: '_p~iF~ps|U_ulLnnqC' }));
await expect('SOS sur le lien', true, req('PATCH', '', 'alice', { [`shares/${tok}/sos`]: true, [`shares/${tok}/sosMessage`]: 'Chute' }));
await expect('arrêt du partage', true, req('PATCH', '', 'alice', {
  [`shares/${tok}/active`]: false, [`shares/${tok}/expiresAt`]: now, [`userShares/alice/${tok}`]: null }));
await expect('bob lit les liens d\'alice', false, req('GET', 'userShares/alice', 'bob'));

// --- Balades partagées
const route = { id: 'r1', name: 'Gorges du Tarn', createdAt: now, polyline: '_p~iF~ps|U_ulLnnqC', style: 'sinueux', source: 'generated',
  waypoints: [{ lat: 45, lng: 3 }], distanceM: 123456.7, durationS: 7200, curvature: 72.5, elevationGainM: 1500,
  maneuvers: [{ instruction: 'Tournez à droite', type: 'right', along: 120, loc: { lat: 45, lng: 3 } }], description: '', author: 'Alice R', favorite: false, sharedAt: now };
await expect('alice partage un itinéraire', true, req('PUT', 'sharedRoutes/alice/r1', 'alice', route));
await expect('bob lit les itinéraires (requête triée)', true, req('GET', 'sharedRoutes/alice', 'bob', undefined, '&orderBy=%22sharedAt%22&limitToLast=25'));
await expect('eve lit les itinéraires', false, req('GET', 'sharedRoutes/alice', 'eve'));
const ride = { name: 'Balade du dimanche', startedAt: now, endedAt: now + 3600000, distanceM: 88000, movingTimeS: 5000, maxSpeedKmh: 131,
  avgSpeedKmh: 63.4, maxLeanDeg: 41, elevationGainM: 900, previewPolyline: '_p~iF~ps|U_ulLnnqC', authorName: 'Alice R', authorColor: 1, sharedAt: now };
await expect('alice partage une balade', true, req('PUT', 'sharedRides/alice/ride1', 'alice', ride));
await expect('bob lit les balades (requête triée)', true, req('GET', 'sharedRides/alice', 'bob', undefined, '&orderBy=%22sharedAt%22&limitToLast=25'));
await expect('champ inconnu sur une balade refusé', false, req('PUT', 'sharedRides/alice/ride2', 'alice', { ...ride, hack: true }));

// --- Retrait d'un pote
await expect('bob retire alice (des deux côtés)', true, req('PATCH', '', 'bob', { 'friends/bob/alice': null, 'friends/alice/bob': null }));
await expect('bob ne lit plus la position d\'alice', false, req('GET', 'live/alice', 'bob'));

console.log(`\n${pass} réussis, ${fail} échecs`);
process.exit(fail ? 1 : 0);
