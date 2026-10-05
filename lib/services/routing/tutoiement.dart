/// Passe les consignes de guidage de Valhalla (vouvoiement) au tutoiement
/// pour coller au ton de l'app : « Tournez à droite » → « Tourne à droite ».
///
/// Seuls des verbes et tournures connus sont convertis : un mot inconnu reste
/// tel quel plutôt que d'être mal conjugué.
String tutoyer(String text) {
  if (text.isEmpty) return text;
  var out = text;
  for (final rule in _rules) {
    out = out.replaceAllMapped(rule.$1, (m) => _matchCase(m.group(0)!, rule.$2));
  }
  return out;
}

String _matchCase(String original, String replacement) {
  if (original.isEmpty || replacement.isEmpty) return replacement;
  final first = original[0];
  if (first == first.toUpperCase() && first != first.toLowerCase()) {
    return replacement[0].toUpperCase() + replacement.substring(1);
  }
  return replacement;
}

RegExp _word(String w) =>
    RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape(w)}(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true);

/// Tournures complètes d'abord, puis verbes isolés.
final List<(RegExp, String)> _rules = [
  for (final e in const [
    ('vous êtes arrivés', 'tu es arrivé'),
    ('vous êtes arrivées', 'tu es arrivé'),
    ('vous êtes arrivée', 'tu es arrivé'),
    ('vous êtes arrivé', 'tu es arrivé'),
    ('vous arriverez', 'tu arriveras'),
    ('vous êtes', 'tu es'),
    ('vous allez', 'tu vas'),
    ('votre destination', 'ta destination'),
    ('votre droite', 'ta droite'),
    ('votre gauche', 'ta gauche'),
    ('votre itinéraire', 'ton itinéraire'),
    ('dirigez-vous', 'dirige-toi'),
    ('engagez-vous', 'engage-toi'),
    ('insérez-vous', 'insère-toi'),
    ('rendez-vous', 'rends-toi'),
    ('placez-vous', 'place-toi'),
    ('mettez-vous', 'mets-toi'),
    ('conduisez', 'roule'),
    ('continuez', 'continue'),
    ('tournez', 'tourne'),
    ('prenez', 'prends'),
    ('serrez', 'serre'),
    ('restez', 'reste'),
    ('gardez', 'garde'),
    ('faites', 'fais'),
    ('rejoignez', 'rejoins'),
    ('entrez', 'entre'),
    ('sortez', 'sors'),
    ('quittez', 'quitte'),
    ('empruntez', 'emprunte'),
    ('suivez', 'suis'),
    ('traversez', 'traverse'),
    ('montez', 'monte'),
    ('descendez', 'descends'),
    ('allez', 'va'),
    ('roulez', 'roule'),
    ('partez', 'pars'),
    ('arrivez', 'arrive'),
    ('utilisez', 'utilise'),
    ('passez', 'passe'),
    ('changez', 'change'),
    ('débarquez', 'débarque'),
    ('embarquez', 'embarque'),
    ('effectuez', 'effectue'),
    ('maintenez', 'maintiens'),
    ('contournez', 'contourne'),
    ('bifurquez', 'bifurque'),
    ('obliquez', 'oblique'),
    ('virez', 'vire'),
    ('ralentissez', 'ralentis'),
  ])
    (_word(e.$1), e.$2),
];
