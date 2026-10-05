import 'dart:convert';

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/services/fuel/fuel_price_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fuel_fixtures.dart';

void main() {
  group('parseResponse (v2.1)', () {
    final stations = FuelPriceClient.parseResponse(fuelResponseV21);

    test('ignore les enregistrements sans coordonnées', () {
      expect(stations.length, 2);
      expect(stations.map((s) => s.id), ['38000001', '38100002']);
    });

    test('geom {lon, lat} et adresse rendue lisible', () {
      final s = stations.first;
      expect(s.location.lat, closeTo(45.18779, 1e-9));
      expect(s.location.lng, closeTo(5.72449, 1e-9));
      expect(s.address, '12 Avenue de la Gare');
      expect(s.city, 'Grenoble');
      expect(s.postalCode, '38000');
      expect(s.open24h, isTrue);
      expect(s.brand, isNull);
      expect(s.displayName, '12 Avenue de la Gare');
    });

    test('prix et dates par carburant', () {
      final s = stations.first;
      expect(s.prices[FuelType.sp98], 1.849);
      expect(s.prices[FuelType.e10], 1.759);
      expect(s.prices[FuelType.gazole], 1.689);
      expect(s.prices.containsKey(FuelType.sp95), isFalse);
      expect(s.updatedAt[FuelType.sp98], DateTime.utc(2026, 10, 4, 7, 12));
      expect(s.unavailable, {FuelType.sp95, FuelType.e85, FuelType.gplc});
    });

    test('repli latitude/longitude ×100000, prix en chaîne / millièmes / virgule', () {
      final s = stations[1];
      expect(s.location.lat, closeTo(45.17, 1e-9));
      expect(s.location.lng, closeTo(5.71, 1e-9));
      expect(s.prices[FuelType.gazole], 1.699);
      expect(s.prices[FuelType.sp98], 1.889);
      expect(s.prices[FuelType.e10], 1.779);
      expect(s.unavailable, {FuelType.e10, FuelType.gplc});
      expect(s.priceFor(FuelType.e10), isNull, reason: 'E10 en rupture');
      expect(s.open24h, isFalse);
      expect(s.address, 'Route de Lyon - RN 85');
      expect(s.city, "Saint-Martin-d'Hères");
      expect(s.updatedAt[FuelType.sp98], isNotNull);
    });
  });

  test('parseResponse accepte l’ancien format records/fields', () {
    final s = FuelPriceClient.parseResponse(fuelResponseV1).single;
    expect(s.id, '69000009');
    expect(s.location.lat, 45.76);
    expect(s.location.lng, 4.85);
    expect(s.prices[FuelType.sp98], 1.869);
    expect(s.updatedAt[FuelType.sp98], DateTime.utc(2026, 10, 4, 3));
    expect(s.unavailable, {FuelType.gazole});
    expect(s.address, '3 rue Garibaldi', reason: 'casse mixte conservée');
  });

  test('parseResponse rejette un JSON invalide', () {
    expect(() => FuelPriceClient.parseResponse('<html>'), throwsFormatException);
    expect(() => FuelPriceClient.parseResponse('{"foo": 1}'), throwsFormatException);
  });

  group('helpers de parsing', () {
    test('parsePrice', () {
      expect(FuelPriceClient.parsePrice(1.859), 1.859);
      expect(FuelPriceClient.parsePrice('1,859'), 1.859);
      expect(FuelPriceClient.parsePrice('1859'), 1.859);
      expect(FuelPriceClient.parsePrice(18.59), 1.859);
      expect(FuelPriceClient.parsePrice(0), isNull);
      expect(FuelPriceClient.parsePrice('n/a'), isNull);
      expect(FuelPriceClient.parsePrice(null), isNull);
    });

    test('parseFuelList', () {
      expect(FuelPriceClient.parseFuelList('SP95;E85'), {FuelType.sp95, FuelType.e85});
      expect(FuelPriceClient.parseFuelList(['Gazole', 'SP95-E10']), {FuelType.gazole, FuelType.e10});
      expect(FuelPriceClient.parseFuelList('["GPLc","SP98"]'), {FuelType.gplc, FuelType.sp98});
      expect(FuelPriceClient.parseFuelList(''), isEmpty);
      expect(FuelPriceClient.parseFuelList(null), isEmpty);
    });

    test('parseDate', () {
      expect(FuelPriceClient.parseDate('2026-10-04T07:12:00+00:00'), DateTime.utc(2026, 10, 4, 7, 12));
      expect(FuelPriceClient.parseDate('2026-10-04 07:12:00'), isNotNull);
      expect(FuelPriceClient.parseDate(''), isNull);
      expect(FuelPriceClient.parseDate('pas une date'), isNull);
    });

    test('parseLocation : GeoJSON et chaînes', () {
      expect(
        FuelPriceClient.parseLocation({
          'geom': {
            'type': 'Point',
            'coordinates': [2.35, 48.85],
          },
        }),
        const GeoPoint(48.85, 2.35),
      );
      expect(FuelPriceClient.parseLocation({'latitude': '48.85', 'longitude': '2.35'}), const GeoPoint(48.85, 2.35));
      expect(
        FuelPriceClient.parseLocation({'latitude': '4885000', 'longitude': '235000'}),
        const GeoPoint(48.85, 2.35),
      );
      expect(FuelPriceClient.parseLocation({'adresse': 'x'}), isNull);
    });

    test('prettyName', () {
      expect(FuelPriceClient.prettyName('ZI DES GLAIRONS'), 'ZI des Glairons');
      expect(FuelPriceClient.prettyName('RN7 LIEU-DIT LA FORGE'), 'RN7 Lieu-dit la Forge');
      expect(FuelPriceClient.prettyName('Avenue Jean Jaurès'), 'Avenue Jean Jaurès');
    });
  });

  group('around()', () {
    test('requête within_distance / order_by / limit et distances calculées', () async {
      final requests = <Uri>[];
      final mock = MockClient((req) async {
        requests.add(req.url);
        // Pas de charset dans l'en-tête : le client doit quand même décoder en UTF-8.
        return http.Response.bytes(utf8.encode(fuelResponseV21), 200, headers: {'content-type': 'application/json'});
      });
      final client = FuelPriceClient(client: mock);
      const center = GeoPoint(45.188, 5.724);
      final stations = await client.around(center);

      expect(requests, hasLength(1));
      final q = requests.single.queryParameters;
      expect(q['where'], "within_distance(geom, geom'POINT(5.72400 45.18800)', 10km)");
      expect(q['order_by'], "distance(geom, geom'POINT(5.72400 45.18800)')");
      expect(q['limit'], '100');
      expect(requests.single.path, endsWith('/prix-des-carburants-en-france-flux-instantane-v2/records'));

      expect(stations, hasLength(2));
      expect(stations.first.distanceM, lessThan(stations.last.distanceM!));
      expect(stations.first.distanceM, closeTo(Geo.distance(center, stations.first.location), 1e-6));
      expect(stations[1].city, "Saint-Martin-d'Hères", reason: 'UTF-8 décodé même sans charset');
    });

    test('cache mémoire de 5 minutes', () async {
      var calls = 0;
      var now = DateTime.utc(2026, 10, 5, 10);
      final mock = MockClient((req) async {
        calls++;
        return http.Response(fuelResponseWith([(id: 'a', lat: 45, lng: 5, sp98: 1.8)]), 200);
      });
      final client = FuelPriceClient(client: mock, clock: () => now);
      await client.around(const GeoPoint(45, 5));
      await client.around(const GeoPoint(45, 5));
      expect(calls, 1);
      now = now.add(const Duration(minutes: 6));
      await client.around(const GeoPoint(45, 5));
      expect(calls, 2);
      client.clearCache();
      await client.around(const GeoPoint(45, 5));
      expect(calls, 3);
    });

    test('requêtes simultanées mutualisées', () async {
      var calls = 0;
      final mock = MockClient((req) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response(fuelResponseWith([(id: 'a', lat: 45, lng: 5, sp98: 1.8)]), 200);
      });
      final client = FuelPriceClient(client: mock);
      await Future.wait([client.around(const GeoPoint(45, 5)), client.around(const GeoPoint(45, 5))]);
      expect(calls, 1);
    });

    test('erreurs en français', () async {
      Future<String> errorFor(MockClient mock, {Duration? timeout}) async {
        final client = FuelPriceClient(client: mock, timeout: timeout ?? const Duration(seconds: 5));
        try {
          await client.around(const GeoPoint(45, 5));
          return 'ok';
        } on FuelPriceException catch (e) {
          return e.message;
        }
      }

      expect(await errorFor(MockClient((_) async => http.Response('oops', 503))), contains('indisponible'));
      expect(await errorFor(MockClient((_) async => http.Response('{}', 400))), contains('refusé'));
      expect(await errorFor(MockClient((_) async => http.Response('{}', 429))), contains('Trop de demandes'));
      expect(await errorFor(MockClient((_) async => http.Response('<html>', 200))), contains('illisible'));
      expect(await errorFor(MockClient((_) async => throw http.ClientException('down'))), contains('Pas de réseau'));
      expect(
        await errorFor(
          MockClient((_) async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return http.Response('{}', 200);
          }),
          timeout: const Duration(milliseconds: 20),
        ),
        contains('ne répond pas'),
      );
    });

    test("une erreur n'est pas mise en cache", () async {
      var calls = 0;
      final mock = MockClient((req) async {
        calls++;
        return calls == 1
            ? http.Response('boom', 500)
            : http.Response(fuelResponseWith([(id: 'a', lat: 45, lng: 5, sp98: 1.8)]), 200);
      });
      final client = FuelPriceClient(client: mock);
      await expectLater(client.around(const GeoPoint(45, 5)), throwsA(isA<FuelPriceException>()));
      expect(await client.around(const GeoPoint(45, 5)), hasLength(1));
    });
  });

  group('alongRoute()', () {
    // Ligne droite plein est de ~40 km à la latitude 45°.
    final route = [for (var i = 0; i <= 40; i++) GeoPoint(45, 5 + i * 0.0127)];

    test('filtre à 3 km de la ligne, dédoublonne et trie dans l’ordre du trajet', () async {
      final wheres = <String>[];
      final mock = MockClient((req) async {
        wheres.add(req.url.queryParameters['where']!);
        expect(req.url.queryParameters.containsKey('order_by'), isFalse);
        // Toutes les requêtes renvoient les mêmes stations (doublons).
        return http.Response(
          fuelResponseWith([
            (id: 'loin', lat: 45.1, lng: 5.2, sp98: 1.7), // ~11 km au nord
            (id: 'fin', lat: 45.01, lng: 5.45, sp98: 1.9), // ~1,1 km, vers 35 km
            (id: 'debut', lat: 44.99, lng: 5.05, sp98: 1.8), // ~1,1 km, vers 4 km
            (id: 'bord', lat: 45.025, lng: 5.25, sp98: 1.85), // ~2,8 km
          ]),
          200,
        );
      });
      final client = FuelPriceClient(client: mock);
      final res = await client.alongRoute(route);

      expect(res.map((r) => r.station.id), ['debut', 'bord', 'fin']);
      expect(res.first.offRouteM, closeTo(1112, 30));
      expect(res.first.detourM, closeTo(2 * res.first.offRouteM, 1e-9));
      expect(res.first.distanceAlongM, closeTo(3935, 60));
      expect(res.first.station.distanceM, res.first.offRouteM);
      expect(wheres, isNotEmpty);
      expect(wheres.first, contains(' OR '));
      expect(wheres.first, startsWith("within_distance(geom, geom'POINT(5.00000 45.00000)'"));
    });

    test('pagination quand une page est pleine', () async {
      final offsets = <String>[];
      final mock = MockClient((req) async {
        final offset = req.url.queryParameters['offset']!;
        offsets.add(offset);
        final page = int.parse(offset) ~/ 100;
        final count = page == 0 ? 100 : 7;
        return http.Response(
          fuelResponseWith([
            for (var i = 0; i < count; i++) (id: 'p$page-$i', lat: 45.001, lng: 5.01 + i * 0.0001, sp98: 1.8),
          ]),
          200,
        );
      });
      final client = FuelPriceClient(client: mock);
      final res = await client.alongRoute(route.sublist(0, 5));
      expect(offsets, ['0', '100']);
      expect(res, hasLength(107));
    });

    test('requête combinée refusée (400) → un cercle par requête', () async {
      final wheres = <String>[];
      final mock = MockClient((req) async {
        final where = req.url.queryParameters['where']!;
        wheres.add(where);
        if (where.contains(' OR ')) return http.Response('{"error_code": "ODSQLError"}', 400);
        return http.Response(fuelResponseWith([(id: 'debut', lat: 44.99, lng: 5.05, sp98: 1.8)]), 200);
      });
      final client = FuelPriceClient(client: mock);
      final res = await client.alongRoute(route.sublist(0, 10));
      expect(res.map((r) => r.station.id), ['debut']);
      expect(wheres.where((w) => !w.contains(' OR ')).length, greaterThan(1));
    });

    test('échec total → FuelPriceException', () async {
      final client = FuelPriceClient(client: MockClient((_) async => http.Response('x', 502)));
      await expectLater(client.alongRoute(route), throwsA(isA<FuelPriceException>()));
    });

    test('itinéraire vide', () async {
      final client = FuelPriceClient(client: MockClient((_) async => fail('aucune requête attendue')));
      expect(await client.alongRoute(const []), isEmpty);
    });
  });
}
