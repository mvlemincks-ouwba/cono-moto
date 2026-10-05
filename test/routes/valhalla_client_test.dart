import 'dart:convert';
import 'dart:io';

import 'package:cono_moto/core/config.dart';
import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/services/routing/http_support.dart';
import 'package:cono_moto/services/routing/maneuver_kinds.dart';
import 'package:cono_moto/services/routing/tutoiement.dart';
import 'package:cono_moto/services/routing/valhalla_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

void main() {
  group('Valhalla : analyse de la réponse', () {
    test('un seul tronçon', () {
      final r = ValhallaClient.parseResponse(fixtureJson('valhalla_route.json') as Map<String, dynamic>);
      expect(r.points, hasLength(11));
      expect(r.points.first.lat, closeTo(48.6436, 1e-6));
      expect(r.distanceM, closeTo(3715, 1));
      expect(r.durationS, 267);
      expect(r.maneuvers.map((m) => m.type).toList(), [
        ManeuverKind.depart,
        ManeuverKind.left,
        ManeuverKind.roundabout,
        ManeuverKind.roundaboutExit,
        ManeuverKind.arrive,
      ]);
      final left = r.maneuvers[1];
      expect(left.instruction, 'Tourne à gauche sur D 906.');
      expect(left.verbalAlert, 'Tourne à gauche sur D 906, puis prends le rond-point.');
      expect(left.streetName, 'D 906');
      expect(left.distanceAlongM, closeTo(1014, 2));
      expect(left.location.lng, closeTo(1.8434, 1e-4));
      expect(r.maneuvers.first.instruction, "Roule vers l'est sur Rue Chasles.");
      expect(r.maneuvers.last.instruction, 'Tu es arrivé à ta destination.');
      expect(r.maneuvers.last.distanceAlongM, closeTo(Geo.length(r.points), 0.5));
    });

    test('deux tronçons recollés', () {
      final r = ValhallaClient.parseResponse(fixtureJson('valhalla_two_legs.json') as Map<String, dynamic>);
      // 11 + 6 points, le point commun n'est pas dupliqué.
      expect(r.points, hasLength(16));
      final kinds = r.maneuvers.map((m) => m.type).toList();
      expect(kinds.where((k) => k == ManeuverKind.depart), hasLength(1));
      expect(kinds.where((k) => k == ManeuverKind.arrive), hasLength(1));
      expect(kinds, contains(ManeuverKind.waypoint));
      final wp = r.maneuvers.firstWhere((m) => m.type == ManeuverKind.waypoint);
      expect(wp.instruction, 'Point de passage n°1');
      expect(wp.distanceAlongM, closeTo(3715, 2));
      final along = r.maneuvers.map((m) => m.distanceAlongM).toList();
      for (var i = 1; i < along.length; i++) {
        expect(along[i], greaterThanOrEqualTo(along[i - 1]));
      }
      expect(r.maneuvers.last.instruction, 'Ta destination est sur la droite.');
      expect(r.maneuvers[r.maneuvers.length - 2].instruction, 'Tourne à droite sur Rue Chasles.');
      expect(r.distanceM, closeTo(6215, 2));
    });

    test('réponse sans trajet', () {
      expect(
        () => ValhallaClient.parseResponse({
          'trip': {'legs': []},
        }),
        throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.noRoute)),
      );
    });

    test('codes d\'erreur Valhalla', () {
      final e = ValhallaClient.parseError(400, fixture('valhalla_error_442.json'));
      expect(e.kind, RoutingErrorKind.noRoute);
      expect(e.message, contains('Pas de route'));
      expect(
        ValhallaClient.parseError(400, '{"error_code":171,"error":"No suitable edges near location"}').kind,
        RoutingErrorKind.noRoute,
      );
      expect(ValhallaClient.parseError(400, '{"error_code":154}').message, contains('trop long'));
      expect(ValhallaClient.parseError(400, 'pas du json').message, contains('erreur 400'));
    });
  });

  group('Valhalla : requête', () {
    test('corps JSON moto', () {
      final body = ValhallaClient.buildRequest(const [
        RouteLocation(GeoPoint(48.6436, 1.8296)),
        RouteLocation(GeoPoint(48.7, 1.9), kind: LocationKind.through),
        RouteLocation(GeoPoint(48.6436, 1.8296)),
      ], costing: MotorcycleCosting.forStyle(RouteStyle.sinueux, avoidHighways: true, avoidTolls: true));
      expect(body['costing'], 'motorcycle');
      final moto = (body['costing_options'] as Map)['motorcycle'] as Map;
      expect(moto['use_highways'], 0);
      expect(moto['use_tolls'], 0);
      expect(moto['use_trails'], 0);
      expect(moto['use_primary'], lessThan(0.3));
      expect(body['directions_options'], {'units': 'kilometers', 'language': 'fr-FR'});
      final locs = body['locations'] as List;
      expect(locs.map((l) => (l as Map)['type']).toList(), ['break', 'through', 'break']);
      expect((locs.first as Map)['lon'], 1.8296);
    });

    test('style rapide : autoroutes et grands axes', () {
      final c = MotorcycleCosting.forStyle(RouteStyle.rapide);
      expect(c.useHighways, greaterThanOrEqualTo(0.5));
      expect(c.usePrimary, 1);
      expect(MotorcycleCosting.forStyle(RouteStyle.rapide, avoidHighways: true).useHighways, 0);
    });

    test('découpage en morceaux de 20 points', () {
      final pts = [for (var i = 0; i < 45; i++) GeoPoint(48 + i * 0.01, 2)];
      final chunks = ValhallaClient.chunkLocations(pts, 20);
      expect(chunks.map((c) => c.length).toList(), [20, 20, 7]);
      expect(chunks[1].first, chunks[0].last);
      expect(chunks[2].first, chunks[1].last);
      expect(chunks.last.last, pts.last);
      expect(ValhallaClient.chunkLocations(pts.sublist(0, 5), 20), hasLength(1));
    });
  });

  group('Valhalla : client HTTP', () {
    ValhallaClient client(MockClientHandler handler) =>
        ValhallaClient(client: MockClient(handler), limiter: RateLimiter(Duration.zero));

    const locs = [RouteLocation(GeoPoint(48.6436, 1.8296)), RouteLocation(GeoPoint(48.6648, 1.8325))];

    test('POST JSON avec User-Agent', () async {
      late http.Request sent;
      final c = client((req) async {
        sent = req;
        return http.Response.bytes(
          utf8.encode(fixture('valhalla_route.json')),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final r = await c.route(locs);
      expect(sent.method, 'POST');
      expect(sent.url.toString(), Endpoints.valhalla);
      expect(sent.headers['User-Agent'], AppConfig.userAgent);
      expect((jsonDecode(sent.body) as Map)['costing'], 'motorcycle');
      expect(r.maneuvers, hasLength(5));
    });

    test('erreurs lisibles', () async {
      Future<RoutingErrorKind> kindFor(MockClientHandler h) async {
        try {
          await client(h).route(locs);
          fail('aurait dû échouer');
        } on RoutingException catch (e) {
          expect(e.message, isNotEmpty);
          return e.kind;
        }
      }

      expect(
        await kindFor((_) async => http.Response(fixture('valhalla_error_442.json'), 400)),
        RoutingErrorKind.noRoute,
      );
      expect(await kindFor((_) async => http.Response('Too Many Requests', 429)), RoutingErrorKind.rateLimited);
      expect(await kindFor((_) async => http.Response('oops', 503)), RoutingErrorKind.server);
      expect(await kindFor((_) async => throw const SocketException('Failed host lookup')), RoutingErrorKind.offline);
      expect(await kindFor((_) async => throw http.ClientException('Connection closed')), RoutingErrorKind.offline);
      expect(await kindFor((_) async => http.Response('<html>', 200)), RoutingErrorKind.badResponse);
    });

    test('itinéraire par morceaux recollés', () async {
      var calls = 0;
      final c = client((req) async {
        calls++;
        return http.Response.bytes(utf8.encode(fixture('valhalla_route.json')), 200);
      });
      final pts = [for (var i = 0; i < 25; i++) GeoPoint(48.6 + i * 0.001, 1.8)];
      final r = await c.routeThrough(pts);
      expect(calls, 2);
      // Le fixture renvoyé deux fois ne se raccorde pas : 11 + 11 points.
      expect(r.points, hasLength(22));
      expect(r.maneuvers.where((m) => m.type == ManeuverKind.depart), hasLength(1));
      expect(r.maneuvers.where((m) => m.type == ManeuverKind.arrive), hasLength(1));
      expect(r.durationS, 534);
    });
  });

  group('Tutoiement', () {
    test('verbes et tournures courants', () {
      expect(tutoyer('Tournez à droite sur D 12.'), 'Tourne à droite sur D 12.');
      expect(tutoyer('Prenez le rond-point et prenez la 2e sortie.'), 'Prends le rond-point et prends la 2e sortie.');
      expect(tutoyer('Vous êtes arrivé à votre destination.'), 'Tu es arrivé à ta destination.');
      expect(tutoyer('Votre destination est sur la gauche.'), 'Ta destination est sur la gauche.');
      expect(tutoyer('Faites demi-tour.'), 'Fais demi-tour.');
      expect(tutoyer('Insérez-vous sur A 10.'), 'Insère-toi sur A 10.');
      expect(tutoyer('Restez à gauche, puis continuez sur N 12.'), 'Reste à gauche, puis continue sur N 12.');
    });

    test('ne touche pas aux mots inconnus', () {
      expect(tutoyer('Passez chez Mémé'), 'Passe chez Mémé');
      expect(tutoyer('Rue des Prenezières'), 'Rue des Prenezières');
      expect(tutoyer(''), '');
    });
  });
}
