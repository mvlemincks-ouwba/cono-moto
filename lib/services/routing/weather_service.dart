import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/geo.dart';
import 'http_support.dart';

/// Grandes familles de temps (codes WMO d'Open-Meteo).
enum WeatherKind { clear, partly, cloudy, fog, drizzle, rain, showers, snow, storm, unknown }

class WeatherCodes {
  WeatherCodes._();

  static WeatherKind kind(int? code) {
    if (code == null) return WeatherKind.unknown;
    if (code == 0 || code == 1) return WeatherKind.clear;
    if (code == 2) return WeatherKind.partly;
    if (code == 3) return WeatherKind.cloudy;
    if (code == 45 || code == 48) return WeatherKind.fog;
    if (code >= 51 && code <= 57) return WeatherKind.drizzle;
    if ((code >= 61 && code <= 67)) return WeatherKind.rain;
    if ((code >= 71 && code <= 77) || code == 85 || code == 86) return WeatherKind.snow;
    if (code >= 80 && code <= 82) return WeatherKind.showers;
    if (code >= 95) return WeatherKind.storm;
    return WeatherKind.unknown;
  }

  static String label(int? code) => switch (code) {
    0 => 'Grand soleil',
    1 => 'Plutôt dégagé',
    2 => 'Éclaircies',
    3 => 'Couvert',
    45 || 48 => 'Brouillard',
    51 || 53 || 55 => 'Bruine',
    56 || 57 => 'Bruine verglaçante',
    61 => 'Pluie faible',
    63 => 'Pluie',
    65 => 'Forte pluie',
    66 || 67 => 'Pluie verglaçante',
    71 || 73 || 75 || 77 => 'Neige',
    80 || 81 => 'Averses',
    82 => 'Grosses averses',
    85 || 86 => 'Averses de neige',
    95 => 'Orage',
    96 || 99 => 'Orage et grêle',
    _ => '—',
  };

  static bool isWet(int? code) {
    final k = kind(code);
    return k == WeatherKind.drizzle ||
        k == WeatherKind.rain ||
        k == WeatherKind.showers ||
        k == WeatherKind.snow ||
        k == WeatherKind.storm;
  }
}

/// Prévisions horaires d'un point.
class HourlySeries {
  const HourlySeries({
    required this.point,
    required this.times,
    required this.temperature,
    required this.precipitationProbability,
    required this.precipitation,
    required this.weatherCode,
    required this.windSpeed,
    required this.windGusts,
  });

  final GeoPoint point;

  /// Heures (UTC).
  final List<DateTime> times;
  final List<double?> temperature;
  final List<double?> precipitationProbability;
  final List<double?> precipitation;
  final List<int?> weatherCode;
  final List<double?> windSpeed;
  final List<double?> windGusts;

  /// Index de l'heure la plus proche de [t] (-1 si série vide).
  int nearestIndex(DateTime t) {
    if (times.isEmpty) return -1;
    var best = 0;
    var bestDiff = (times[0].difference(t)).abs();
    for (var i = 1; i < times.length; i++) {
      final d = (times[i].difference(t)).abs();
      if (d < bestDiff) {
        best = i;
        bestDiff = d;
      }
    }
    return best;
  }
}

/// Météo prévue à un endroit du parcours, à l'heure de passage estimée.
class RouteWeatherSample {
  const RouteWeatherSample({
    required this.distanceAlongM,
    required this.point,
    required this.eta,
    this.temperatureC,
    this.precipitationProbability,
    this.precipitationMm,
    this.weatherCode,
    this.windKmh,
    this.gustKmh,
  });

  final double distanceAlongM;
  final GeoPoint point;

  /// Heure de passage estimée (UTC).
  final DateTime eta;
  final double? temperatureC;
  final double? precipitationProbability;
  final double? precipitationMm;
  final int? weatherCode;
  final double? windKmh;
  final double? gustKmh;

  double get km => distanceAlongM / 1000;

  bool get rainLikely =>
      (precipitationProbability ?? 0) >= 50 ||
      (precipitationMm ?? 0) >= 0.5 ||
      (WeatherCodes.isWet(weatherCode) && (precipitationProbability ?? 100) >= 40);

  bool get showerRisk => (precipitationProbability ?? 0) >= 30;
}

/// Ambiance générale de la balade.
enum WeatherVerdict { top, correct, bof, pourri }

/// Résumé météo d'une balade.
class RouteWeather {
  const RouteWeather({
    required this.samples,
    required this.departure,
    required this.headline,
    required this.verdict,
    this.details = const [],
    this.minTempC,
    this.maxTempC,
    this.maxGustKmh,
    this.firstRain,
  });

  final List<RouteWeatherSample> samples;
  final DateTime departure;

  /// Phrase principale (« Pluie probable vers km 85 (14 h) »).
  final String headline;

  /// Infos secondaires (rafales, chaleur…).
  final List<String> details;
  final WeatherVerdict verdict;
  final double? minTempC;
  final double? maxTempC;
  final double? maxGustKmh;
  final RouteWeatherSample? firstRain;
}

/// Client Open-Meteo « forecast » multi-points.
class WeatherClient {
  WeatherClient({http.Client? client, this.endpoint = Endpoints.openMeteo, this.timeout = const Duration(seconds: 20)})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String endpoint;
  final Duration timeout;

  static const service = 'le service météo';

  static const hourlyVars = [
    'temperature_2m',
    'precipitation_probability',
    'precipitation',
    'weather_code',
    'wind_speed_10m',
    'wind_gusts_10m',
  ];

  static Uri buildUri(String endpoint, List<GeoPoint> points, {int forecastDays = 3}) => Uri.parse(endpoint).replace(
    queryParameters: {
      'latitude': points.map((p) => p.lat.toStringAsFixed(4)).join(','),
      'longitude': points.map((p) => p.lng.toStringAsFixed(4)).join(','),
      'hourly': hourlyVars.join(','),
      'timezone': 'auto',
      'timeformat': 'unixtime',
      'wind_speed_unit': 'kmh',
      'forecast_days': '${forecastDays.clamp(1, 16)}',
    },
  );

  Future<List<HourlySeries>> hourly(List<GeoPoint> points, {int forecastDays = 3}) async {
    if (points.isEmpty) return const [];
    final r = await guardedSend(
      () => _client.get(buildUri(endpoint, points, forecastDays: forecastDays), headers: serviceHeaders()),
      service: service,
      timeout: timeout,
    );
    checkStatus(r, service: service);
    final series = parse(decodeJsonBody(r, service: service), points);
    if (series.length != points.length) {
      throw const RoutingException(RoutingErrorKind.badResponse, 'Le service météo a renvoyé des données incomplètes.');
    }
    return series;
  }

  /// Une réponse par point : liste JSON (plusieurs points) ou objet (un seul).
  static List<HourlySeries> parse(dynamic json, List<GeoPoint> requested) {
    final list = json is List ? json : (json is Map ? [json] : const []);
    final out = <HourlySeries>[];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      if (item is! Map) continue;
      final hourly = item['hourly'];
      if (hourly is! Map) continue;
      final offset = (item['utc_offset_seconds'] as num?)?.toInt() ?? 0;
      final rawTimes = (hourly['time'] as List?) ?? const [];
      final times = <DateTime>[];
      for (final t in rawTimes) {
        if (t is num) {
          times.add(DateTime.fromMillisecondsSinceEpoch(t.toInt() * 1000, isUtc: true));
        } else if (t is String) {
          // Format ISO local (« 2026-10-05T14:00 ») si timeformat=iso8601.
          final local = DateTime.tryParse('${t}Z');
          if (local != null) times.add(local.subtract(Duration(seconds: offset)));
        }
      }
      List<double?> d(String k) => [for (final v in (hourly[k] as List?) ?? const []) v is num ? v.toDouble() : null];
      final lat = (item['latitude'] as num?)?.toDouble();
      final lng = (item['longitude'] as num?)?.toDouble();
      out.add(
        HourlySeries(
          point: i < requested.length ? requested[i] : GeoPoint(lat ?? 0, lng ?? 0),
          times: times,
          temperature: d('temperature_2m'),
          precipitationProbability: d('precipitation_probability'),
          precipitation: d('precipitation'),
          weatherCode: [for (final v in (hourly['weather_code'] as List?) ?? const []) v is num ? v.toInt() : null],
          windSpeed: d('wind_speed_10m'),
          windGusts: d('wind_gusts_10m'),
        ),
      );
    }
    return out;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// Météo le long d'un itinéraire, à l'heure de passage estimée.
class RouteWeatherService {
  RouteWeatherService(this.client);

  final WeatherClient client;

  /// Horizon max des prévisions Open-Meteo.
  static const maxDays = 16;

  Future<RouteWeather> forRoute(
    List<GeoPoint> line,
    int durationS,
    DateTime departure, {
    int samples = 6,
    DateTime? now,
  }) async {
    if (line.length < 2) {
      throw const RoutingException(RoutingErrorKind.invalidRequest, 'Itinéraire vide : pas de météo possible.');
    }
    final n = (now ?? DateTime.now()).toUtc();
    final end = departure.toUtc().add(Duration(seconds: durationS));
    final days = end.difference(n).inHours / 24;
    if (days > maxDays - 0.5) {
      throw const RoutingException(
        RoutingErrorKind.invalidRequest,
        "Trop loin dans le futur : la météo n'est prévue que sur 15 jours.",
      );
    }
    final passages = samplePassages(line, durationS, departure, count: samples);
    final series = await client.hourly([
      for (final p in passages) p.$2,
    ], forecastDays: (days.ceil() + 1).clamp(1, maxDays));
    return summarize(buildSamples(passages, series), departure);
  }

  /// Points régulièrement espacés (départ et arrivée inclus) avec l'heure de
  /// passage estimée (vitesse supposée constante).
  static List<(double, GeoPoint, DateTime)> samplePassages(
    List<GeoPoint> line,
    int durationS,
    DateTime departure, {
    int count = 6,
  }) {
    final cum = Geo.cumulativeDistances(line);
    final total = cum.last;
    final n = math.max(2, count);
    return [
      for (var i = 0; i < n; i++)
        () {
          final d = total * i / (n - 1);
          final frac = total <= 0 ? 0.0 : d / total;
          return (
            d,
            Geo.pointAtDistance(line, d, cumulative: cum),
            departure.toUtc().add(Duration(seconds: (durationS * frac).round())),
          );
        }(),
    ];
  }

  static List<RouteWeatherSample> buildSamples(List<(double, GeoPoint, DateTime)> passages, List<HourlySeries> series) {
    final out = <RouteWeatherSample>[];
    for (var i = 0; i < passages.length && i < series.length; i++) {
      final (d, p, eta) = passages[i];
      final s = series[i];
      final idx = s.nearestIndex(eta);
      T? at<T>(List<T?> l) => idx >= 0 && idx < l.length ? l[idx] : null;
      out.add(
        RouteWeatherSample(
          distanceAlongM: d,
          point: p,
          eta: eta,
          temperatureC: at(s.temperature),
          precipitationProbability: at(s.precipitationProbability),
          precipitationMm: at(s.precipitation),
          weatherCode: at(s.weatherCode),
          windKmh: at(s.windSpeed),
          gustKmh: at(s.windGusts),
        ),
      );
    }
    return out;
  }

  /// « 14 h » (heure locale de l'appareil, arrondie).
  static String hourLabel(DateTime t) {
    final local = t.toLocal().add(const Duration(minutes: 30));
    return '${local.hour} h';
  }

  static String _where(RouteWeatherSample s, {required bool first}) {
    if (first || s.distanceAlongM < 2000) return 'dès le départ (${hourLabel(s.eta)})';
    return 'vers km ${s.km.round()} (${hourLabel(s.eta)})';
  }

  /// Résumé lisible : phrase principale, verdict, min/max, rafales.
  static RouteWeather summarize(List<RouteWeatherSample> samples, DateTime departure) {
    if (samples.isEmpty) {
      return RouteWeather(
        samples: samples,
        departure: departure,
        headline: 'Pas de prévision disponible',
        verdict: WeatherVerdict.correct,
      );
    }
    final temps = samples.map((s) => s.temperatureC).whereType<double>().toList();
    final gusts = samples.map((s) => s.gustKmh).whereType<double>().toList();
    final minT = temps.isEmpty ? null : temps.reduce(math.min);
    final maxT = temps.isEmpty ? null : temps.reduce(math.max);
    final maxGust = gusts.isEmpty ? null : gusts.reduce(math.max);

    RouteWeatherSample? firstWhere(bool Function(RouteWeatherSample) test) {
      for (final s in samples) {
        if (test(s)) return s;
      }
      return null;
    }

    final storm = firstWhere((s) => WeatherCodes.kind(s.weatherCode) == WeatherKind.storm);
    final snow = firstWhere((s) => WeatherCodes.kind(s.weatherCode) == WeatherKind.snow);
    final rain = firstWhere((s) => s.rainLikely);
    final shower = firstWhere((s) => s.showerRisk);
    final rainyCount = samples.where((s) => s.rainLikely).length;

    String headline;
    WeatherVerdict verdict;
    final details = <String>[];

    if (storm != null) {
      headline = 'Orages possibles ${_where(storm, first: identical(storm, samples.first))}';
      verdict = WeatherVerdict.pourri;
    } else if (snow != null) {
      headline = 'Neige possible ${_where(snow, first: identical(snow, samples.first))}';
      verdict = WeatherVerdict.pourri;
    } else if (rain != null) {
      headline = 'Pluie probable ${_where(rain, first: identical(rain, samples.first))}';
      verdict = rainyCount * 2 >= samples.length ? WeatherVerdict.pourri : WeatherVerdict.bof;
    } else if (shower != null) {
      headline = "Risque d'averses ${_where(shower, first: identical(shower, samples.first))}";
      verdict = WeatherVerdict.bof;
    } else if (maxGust != null && maxGust >= 65) {
      headline = "Rafales jusqu'à ${maxGust.round()} km/h, tiens bien ton guidon";
      verdict = WeatherVerdict.bof;
    } else if (minT != null && minT <= 3) {
      headline = 'Ça caille (${minT.round()} °C) : gare au verglas';
      verdict = WeatherVerdict.bof;
    } else if (maxT != null && maxT >= 32) {
      headline = "Grosse chaleur (jusqu'à ${maxT.round()} °C) : pense à boire";
      verdict = WeatherVerdict.correct;
    } else if (samples.every((s) => (s.weatherCode ?? 0) <= 1)) {
      headline = 'Grand beau sur tout le parcours';
      verdict = WeatherVerdict.top;
    } else if (samples.every((s) => (s.weatherCode ?? 0) <= 3)) {
      headline = 'Temps sec, ça roule';
      verdict = WeatherVerdict.top;
    } else {
      headline = 'Temps sec mais gris';
      verdict = WeatherVerdict.correct;
    }

    if (maxGust != null && maxGust >= 50 && !headline.startsWith('Rafales')) {
      details.add('Rafales jusqu\'à ${maxGust.round()} km/h');
    }
    if (minT != null && minT <= 6 && !headline.startsWith('Ça caille')) {
      details.add('Frais au plus bas (${minT.round()} °C) : sors les gants chauds');
    }
    if (maxT != null && maxT >= 30 && !headline.startsWith('Grosse chaleur')) {
      details.add('Jusqu\'à ${maxT.round()} °C : hydrate-toi');
    }

    return RouteWeather(
      samples: samples,
      departure: departure,
      headline: headline,
      details: details,
      verdict: verdict,
      minTempC: minT,
      maxTempC: maxT,
      maxGustKmh: maxGust,
      firstRain: rain ?? storm ?? snow,
    );
  }
}
