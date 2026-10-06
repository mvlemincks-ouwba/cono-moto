import 'dart:convert';
import 'dart:io';

import 'package:cono_moto/core/config.dart';
import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/services/routing/geocoder.dart';
import 'package:cono_moto/services/routing/http_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

http.Response _json(String body, [int status = 200]) => http.Response.bytes(utf8.encode(body), status);

/// Faux réseau : Photon et les deux serveurs de la Base Adresse Nationale.
class _Net {
  _Net({this.photon = 'photon_lauba.json', this.ban = 'ban_search.json'});

  String? photon;
  String? ban;
  bool geoplateformeDown = false;
  final hosts = <String>[];
  final urls = <Uri>[];

  Geocoder geocoder() => Geocoder(
    banEndpoints: Endpoints.banGeocoders,
    client: MockClient((req) async {
      hosts.add(req.url.host);
      urls.add(req.url);
      if (req.url.host == 'photon.komoot.io') {
        if (photon == null) throw const SocketException('pas de réseau');
        return _json(fixture(photon!));
      }
      if (req.url.host == 'data.geopf.fr' && geoplateformeDown) return _json('oups', 503);
      if (ban == null) return _json('oups', 500);
      return _json(fixture(ban!));
    }),
  );
}

void main() {
  test('Base Adresse Nationale : adresse avec numéro, rue, réponses peu sûres écartées', () {
    final places = Geocoder.parseBan(fixtureJson('ban_search.json'));
    expect(places, hasLength(2));
    expect(places[0].name, '9 Rue Vital Lauba');
    expect(places[0].label, '9 Rue Vital Lauba, 33160 Saint-Médard-en-Jalles, Gironde');
    expect(places[0].type, 'house');
    expect(places[0].postcode, '33160');
    expect(places[0].city, 'Saint-Médard-en-Jalles');
    expect(places[0].point.lat, closeTo(44.896234, 1e-6));
    expect(places[0].point.lng, closeTo(-0.716553, 1e-6));
    expect(places[1].type, 'street');
  });

  test('« 9 rue vital lauba 33160 » : la bonne adresse en premier, le faux résultat écarté (#10)', () async {
    final net = _Net();
    final res = await net.geocoder().search('9 rue vital lauba 33160', near: const GeoPoint(44.84, -0.58));
    expect(res.map((p) => p.label), [
      '9 Rue Vital Lauba, 33160 Saint-Médard-en-Jalles, Gironde',
      'Rue Vital Lauba, 33160 Saint-Médard-en-Jalles, Gironde',
    ]);
    expect(res.first.type, 'house');
    expect(net.hosts, containsAll(['photon.komoot.io', 'data.geopf.fr']));
    final ban = net.urls.firstWhere((u) => u.host == 'data.geopf.fr');
    expect(ban.path, '/geocodage/search');
    expect(ban.queryParameters, {'q': '9 rue vital lauba 33160', 'limit': '6', 'lat': '44.8400', 'lon': '-0.5800'});
  });

  test('Géoplateforme en panne : l\'ancienne adresse de la BAN prend le relais', () async {
    final net = _Net()..geoplateformeDown = true;
    final res = await net.geocoder().search('9 rue vital lauba 33160');
    expect(res.first.name, '9 Rue Vital Lauba');
    expect(net.hosts, contains('api-adresse.data.gouv.fr'));
  });

  test('un service en panne : l\'autre suffit ; les deux : erreur claire', () async {
    final noBan = _Net(ban: null);
    final viaPhoton = await noBan.geocoder().search('9 rue vital lauba 33160');
    expect(viaPhoton.map((p) => p.name), ['Rue Vital Lauba'], reason: 'le faux résultat (48700) reste écarté');

    final noPhoton = _Net(photon: null);
    expect((await noPhoton.geocoder().search('9 rue vital lauba 33160')).first.name, '9 Rue Vital Lauba');

    final none = _Net(photon: null, ban: null);
    await expectLater(
      none.geocoder().search('9 rue vital lauba 33160'),
      throwsA(isA<RoutingException>().having((e) => e.kind, 'kind', RoutingErrorKind.offline)),
    );
  });

  test('pas une adresse (col, ville…) : OpenStreetMap d\'abord, rues de la BAN ignorées', () {
    final photon = Geocoder.parse(fixtureJson('photon_search.json'));
    final ban = Geocoder.parseBan(fixtureJson('ban_search.json'));
    final res = Geocoder.merge('rambouillet', photon: photon, ban: ban, limit: 8);
    expect(res.map((p) => p.name), photon.map((p) => p.name));
  });

  test('reconnaître une adresse et un code postal', () {
    for (final q in [
      '9 rue vital lauba',
      '12 bis avenue de la gare',
      'allée des chênes',
      'chemin du moulin, Dourdan',
    ]) {
      expect(Geocoder.looksLikeAddress(q), isTrue, reason: q);
    }
    for (final q in ['col du galibier', 'rambouillet', 'Champs-Élysées', 'routes des crêtes']) {
      expect(Geocoder.looksLikeAddress(q), isFalse, reason: q);
    }
    expect(Geocoder.postcodeIn('9 rue vital lauba 33160'), '33160');
    expect(Geocoder.postcodeIn('route 66'), isNull);
  });

  test('Photon seul si la BAN n\'est pas configurée (comportement d\'avant)', () async {
    final hosts = <String>[];
    final g = Geocoder(
      client: MockClient((req) async {
        hosts.add(req.url.host);
        return _json(fixture('photon_lauba.json'));
      }),
    );
    expect(await g.search('9 rue vital lauba 33160'), hasLength(2));
    expect(hosts, ['photon.komoot.io']);
  });
}
