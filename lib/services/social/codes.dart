import 'dart:math' as math;

/// Codes lisibles (code ami, code de groupe) et jetons de partage.
///
/// Logique pure, sans Firebase : testée dans `test/social/codes_test.dart`.
class SocialCodes {
  SocialCodes._();

  /// Alphabet sans caractères ambigus : ni 0/O, ni 1/I/L.
  static const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  /// Longueur d'un code ami (ex : « K7PM2X »).
  static const friendCodeLength = 6;

  /// Longueur d'un code de groupe (= identifiant du groupe dans la base).
  static const groupCodeLength = 8;

  /// Longueur d'un jeton de lien de suivi web (non devinable).
  static const shareTokenLength = 32;

  static const _tokenAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  static final math.Random _secure = _makeRandom();

  static math.Random _makeRandom() {
    try {
      return math.Random.secure();
    } catch (_) {
      return math.Random();
    }
  }

  static String _random(String chars, int length, math.Random? random) {
    final r = random ?? _secure;
    final sb = StringBuffer();
    for (var i = 0; i < length; i++) {
      sb.write(chars[r.nextInt(chars.length)]);
    }
    return sb.toString();
  }

  /// Nouveau code ami aléatoire.
  static String newFriendCode({math.Random? random}) => _random(alphabet, friendCodeLength, random);

  /// Nouveau code de groupe aléatoire.
  static String newGroupCode({math.Random? random}) => _random(alphabet, groupCodeLength, random);

  /// Nouveau jeton de partage de position (32 caractères alphanumériques).
  static String newShareToken({math.Random? random}) => _random(_tokenAlphabet, shareTokenLength, random);

  /// Nettoie une saisie : majuscules, sans espaces ni tirets.
  static String normalize(String input) => input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static bool _allInAlphabet(String code) => code.split('').every(alphabet.contains);

  /// Code ami valide (après [normalize]) ?
  static bool isValidFriendCode(String code) => code.length == friendCodeLength && _allInAlphabet(code);

  /// Code de groupe valide (après [normalize]) ? 8 à 10 caractères.
  static bool isValidGroupCode(String code) => code.length >= 8 && code.length <= 10 && _allInAlphabet(code);

  /// Jeton de partage valide ?
  static bool isValidShareToken(String token) =>
      token.length >= 20 && token.length <= 64 && RegExp(r'^[A-Za-z0-9]+$').hasMatch(token);

  /// Code de groupe affiché par blocs de 4 : « ABCD-EFGH ».
  static String formatGroupCode(String code) {
    if (code.length <= 4) return code;
    final parts = <String>[];
    for (var i = 0; i < code.length; i += 4) {
      parts.add(code.substring(i, math.min(i + 4, code.length)));
    }
    return parts.join('-');
  }

  /// URL de la page de suivi web pour un jeton donné.
  ///
  /// Retourne null si la page n'est pas déployée ([viewerUrl] vide).
  static String? shareUrl({
    required String viewerUrl,
    required String databaseUrl,
    required String token,
  }) {
    final base = viewerUrl.trim();
    if (base.isEmpty) return null;
    final sep = base.contains('?') ? '&' : '?';
    return '$base${sep}db=${Uri.encodeQueryComponent(databaseUrl.trim())}&t=$token';
  }
}
