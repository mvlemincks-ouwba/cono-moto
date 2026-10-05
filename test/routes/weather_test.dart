import 'dart:convert';

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/services/routing/http_support.dart';
import 'package:cono_moto/services/routing/weather_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

final base = DateTime.utc(2026, 10, 5);

RouteWeatherSample sample(
  double km,
  int hour, {
  double t = 15,
  double p = 0,
  double mm = 0,
  int code = 1,
  double gust = 20,
}) => RouteWeatherSample(
  distanceAlongM: km * 1000,
  point: const GeoPoint(48, 2),
  eta: base.add(Duration(hours: hour)),
  temperatureC: t,
  precipitationProbability: p,
  precipitationMm: mm,
  weatherCode: code,
  windKmh: 10,
  gustKmh: gust,
);

void main() {
  const pts = [
    GeoPoint(48.6436, 1.8296),
    GeoPoint(48.70, 1.95),
    GeoPoint(48.75, 2.05),
    GeoPoint(48.72, 2.10),
    GeoPoint(48.68, 2.00),
    GeoPoint(48.6436, 1.8296),
  ];

  test('analyse multi-points (liste JSON)', () {
    final series = WeatherClient.parse(fixtureJson('open_meteo_forecast.json'), pts);
    expect(series, hasLength(6));
    final s = series.first;
    expect(s.times, hasLength(24));
    expect(s.times.first, base);
    expect(s.times.first.isUtc, isTrue);
    expect(s.temperature.last, isNull);
    expect(s.weatherCode.first, 1);
    expect(series[3].precipitationProbability[12], 70);
    expect(series[3].weatherCode[12], 63);
    expect(s.nearestIndex(base.add(const Duration(hours: 5, minutes: 20))), 5);
    expect(s.nearestIndex(base.add(const Duration(hours: 5, minutes: 40))), 6);
  });

  test('analyse mono-point (objet JSON)', () {
    final series = WeatherClient.parse(fixtureJson('open_meteo_forecast_single.json'), [pts.first]);
    expect(series, hasLength(1));
    expect(series.first.windGusts.first, 30);
  });

  test('URL multi-points', () {
    final uri = WeatherClient.buildUri('https://api.open-meteo.com/v1/forecast', pts.take(2).toList(), forecastDays: 2);
    expect(uri.queryParameters['latitude'], '48.6436,48.7000');
    expect(uri.queryParameters['longitude'], '1.8296,1.9500');
    expect(
      uri.queryParameters['hourly'],
      'temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m,wind_gusts_10m',
    );
    expect(uri.queryParameters['timezone'], 'auto');
    expect(uri.queryParameters['forecast_days'], '2');
  });

  test('points de passage et heures estimées', () {
    final line = [const GeoPoint(48.0, 2.0), const GeoPoint(48.5, 2.0)];
    final p = RouteWeatherService.samplePassages(line, 3600 * 5, base.add(const Duration(hours: 8)), count: 6);
    expect(p, hasLength(6));
    expect(p.first.$1, 0);
    expect(p.last.$1, closeTo(Geo.length(line), 0.01));
    expect(p.first.$3, base.add(const Duration(hours: 8)));
    expect(p[1].$3, base.add(const Duration(hours: 9)));
    expect(p.last.$3, base.add(const Duration(hours: 13)));
  });

  test('météo sur le parcours via le client', () async {
    late Uri url;
    final client = WeatherClient(
      client: MockClient((req) async {
        url = req.url;
        return http.Response.bytes(utf8.encode(fixture('open_meteo_forecast.json')), 200);
      }),
    );
    final service = RouteWeatherService(client);
    // Boucle de ~40 km en 4 h (départ 8 h UTC) : le dernier point passe à 12 h.
    final w = await service.forRoute(
      pts,
      4 * 3600,
      base.add(const Duration(hours: 8)),
      now: base.add(const Duration(hours: 6)),
    );
    expect(url.queryParameters['latitude']!.split(','), hasLength(6));
    expect(w.samples, hasLength(6));
    expect(w.firstRain, isNotNull);
    expect(w.firstRain, same(w.samples.last));
    final km = (w.samples.last.distanceAlongM / 1000).round();
    expect(
      w.headline,
      'Pluie probable vers km $km (${RouteWeatherService.hourLabel(base.add(const Duration(hours: 12)))})',
    );
    expect(w.verdict, WeatherVerdict.bof);
    expect(w.minTempC, isNotNull);
    expect(w.maxTempC! >= w.minTempC!, isTrue);
    expect(w.maxGustKmh, 50);
    expect(w.details, contains("Rafales jusqu'à 50 km/h"));
  });

  test('trop loin dans le futur', () async {
    final service = RouteWeatherService(WeatherClient(client: MockClient((_) async => http.Response('[]', 200))));
    await expectLater(
      service.forRoute(pts, 3600, base.add(const Duration(days: 20)), now: base),
      throwsA(isA<RoutingException>()),
    );
  });

  group('résumé', () {
    test('grand beau', () {
      final w = RouteWeatherService.summarize([sample(0, 9), sample(40, 10), sample(80, 11)], base);
      expect(w.headline, 'Grand beau sur tout le parcours');
      expect(w.verdict, WeatherVerdict.top);
      expect(w.firstRain, isNull);
    });

    test('pluie dès le départ', () {
      final w = RouteWeatherService.summarize([
        sample(0, 9, p: 80, mm: 2, code: 63),
        sample(40, 10, p: 80, code: 61),
        sample(80, 11),
      ], base);
      expect(w.headline, startsWith('Pluie probable dès le départ'));
      expect(w.verdict, WeatherVerdict.pourri);
    });

    test('pluie en route', () {
      final w = RouteWeatherService.summarize([sample(0, 9), sample(85, 14, p: 60, code: 61), sample(120, 15)], base);
      expect(
        w.headline,
        'Pluie probable vers km 85 (${RouteWeatherService.hourLabel(base.add(const Duration(hours: 14)))})',
      );
      expect(w.verdict, WeatherVerdict.bof);
    });

    test('orages prioritaires', () {
      final w = RouteWeatherService.summarize([sample(0, 9, p: 70, code: 61), sample(50, 12, p: 60, code: 95)], base);
      expect(w.headline, startsWith('Orages possibles vers km 50'));
      expect(w.verdict, WeatherVerdict.pourri);
    });

    test('averses, rafales, froid, chaleur', () {
      expect(
        RouteWeatherService.summarize([sample(0, 9), sample(30, 10, p: 35, code: 2)], base).headline,
        startsWith("Risque d'averses vers km 30"),
      );
      expect(
        RouteWeatherService.summarize([sample(0, 9, gust: 72), sample(30, 10)], base).headline,
        "Rafales jusqu'à 72 km/h, tiens bien ton guidon",
      );
      expect(
        RouteWeatherService.summarize([sample(0, 9, t: 1), sample(30, 10, t: 4)], base).headline,
        'Ça caille (1 °C) : gare au verglas',
      );
      final hot = RouteWeatherService.summarize([sample(0, 9, t: 28), sample(30, 10, t: 34)], base);
      expect(hot.headline, "Grosse chaleur (jusqu'à 34 °C) : pense à boire");
      expect(RouteWeatherService.summarize([sample(0, 9, code: 3)], base).headline, 'Temps sec, ça roule');
      expect(RouteWeatherService.summarize([sample(0, 9, code: 45)], base).headline, 'Temps sec mais gris');
    });

    test('codes WMO', () {
      expect(WeatherCodes.kind(0), WeatherKind.clear);
      expect(WeatherCodes.kind(63), WeatherKind.rain);
      expect(WeatherCodes.kind(81), WeatherKind.showers);
      expect(WeatherCodes.kind(75), WeatherKind.snow);
      expect(WeatherCodes.kind(99), WeatherKind.storm);
      expect(WeatherCodes.label(45), 'Brouillard');
      expect(WeatherCodes.isWet(2), isFalse);
      expect(WeatherCodes.isWet(55), isTrue);
    });
  });
}
