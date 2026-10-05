import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/config.dart';

/// Nature d'une erreur des services de balade (itinéraire, météo, altitude…).
enum RoutingErrorKind { offline, timeout, rateLimited, server, noRoute, invalidRequest, badResponse, cancelled }

/// Erreur lisible par l'utilisateur (message en français, tutoiement).
class RoutingException implements Exception {
  const RoutingException(this.kind, this.message, {this.cause});

  final RoutingErrorKind kind;
  final String message;
  final Object? cause;

  /// Vrai si réessayer plus tard a une chance de marcher.
  bool get isTransient =>
      kind == RoutingErrorKind.offline ||
      kind == RoutingErrorKind.timeout ||
      kind == RoutingErrorKind.rateLimited ||
      kind == RoutingErrorKind.server;

  static RoutingException offline(String service, [Object? cause]) => RoutingException(
    RoutingErrorKind.offline,
    "Pas de réseau : impossible de joindre $service. Vérifie ta connexion et réessaie.",
    cause: cause,
  );

  static const cancelled = RoutingException(RoutingErrorKind.cancelled, 'Recherche annulée.');

  @override
  String toString() => message;
}

/// En-têtes communs (User-Agent obligatoire pour les services OSM/FOSSGIS).
Map<String, String> serviceHeaders({bool jsonBody = false, bool formBody = false}) => {
  'User-Agent': AppConfig.userAgent,
  'Accept': 'application/json',
  if (jsonBody) 'Content-Type': 'application/json; charset=utf-8',
  if (formBody) 'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
};

/// Exécute une requête en traduisant les erreurs réseau en [RoutingException].
Future<http.Response> guardedSend(
  Future<http.Response> Function() send, {
  required String service,
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    return await send().timeout(timeout);
  } on TimeoutException catch (e) {
    throw RoutingException(
      RoutingErrorKind.timeout,
      '${_cap(service)} met trop de temps à répondre. Réessaie dans un instant.',
      cause: e,
    );
  } on SocketException catch (e) {
    throw RoutingException.offline(service, e);
  } on HandshakeException catch (e) {
    throw RoutingException.offline(service, e);
  } on http.ClientException catch (e) {
    throw RoutingException.offline(service, e);
  }
}

/// Vérifie le code HTTP (429, 5xx, 4xx) et lève une erreur claire.
void checkStatus(http.Response r, {required String service}) {
  final code = r.statusCode;
  if (code >= 200 && code < 300) return;
  if (code == 429) {
    throw RoutingException(
      RoutingErrorKind.rateLimited,
      '${_cap(service)} est saturé (trop de demandes). Patiente quelques secondes et réessaie.',
    );
  }
  if (code == 502 || code == 503 || code == 504) {
    throw RoutingException(
      RoutingErrorKind.server,
      '${_cap(service)} est surchargé pour le moment (erreur $code). Réessaie un peu plus tard.',
    );
  }
  if (code >= 500) {
    throw RoutingException(
      RoutingErrorKind.server,
      '${_cap(service)} est en panne (erreur $code). Réessaie plus tard.',
    );
  }
  throw RoutingException(RoutingErrorKind.invalidRequest, '${_cap(service)} a refusé la demande (erreur $code).');
}

/// Décode un corps JSON en UTF-8 (indépendamment du charset annoncé).
dynamic decodeJsonBody(http.Response r, {required String service}) {
  try {
    return jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
  } on FormatException catch (e) {
    throw RoutingException(RoutingErrorKind.badResponse, '${_cap(service)} a renvoyé une réponse illisible.', cause: e);
  }
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Espace les requêtes vers un même serveur (ex : Valhalla FOSSGIS ≈ 1 req/s).
class RateLimiter {
  RateLimiter(this.minInterval);

  final Duration minInterval;
  DateTime? _last;
  Future<void> _chain = Future.value();

  /// Limiteur partagé pour le serveur Valhalla public.
  static final valhalla = RateLimiter(const Duration(milliseconds: 1100));

  /// Limiteur partagé pour Overpass (serveur public très sollicité).
  static final overpass = RateLimiter(const Duration(milliseconds: 1500));

  /// Attend son tour (les appels sont sérialisés).
  Future<void> acquire() {
    final next = _chain.then((_) async {
      final last = _last;
      if (last != null && minInterval > Duration.zero) {
        final wait = minInterval - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _last = DateTime.now();
    });
    _chain = next.catchError((_) {});
    return next;
  }
}
