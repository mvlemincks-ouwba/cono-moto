import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/features/history/ride_share_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import '../helpers.dart';

/// Boucle sinueuse de [n] points (~2 km de rayon), angle alterné gauche/droite.
List<TrackPoint> _loop(int n, {double lean = 40, double? accuracy}) {
  final t0 = DateTime.utc(2026, 6, 7, 7);
  return [
    for (var i = 0; i < n; i++)
      TrackPoint(
        time: t0.add(Duration(seconds: i)),
        lat: 45 + 0.02 * math.sin(2 * math.pi * i / n) + 0.001 * math.sin(i / 7),
        lng: 5.5 + 0.03 * math.cos(2 * math.pi * i / n),
        speedMs: 20,
        leanDeg: lean * math.sin(i / 9),
        accuracyM: accuracy,
      ),
  ];
}

const _fullStats = RideStats(
  distanceM: 182400,
  movingTimeS: 9800,
  totalTimeS: 11600,
  maxSpeedKmh: 142,
  maxLeanLeftDeg: 44,
  maxLeanRightDeg: 49,
  elevationGainM: 1840,
  curveCount: 312,
);

Ride _ride({RideStats stats = _fullStats, String preview = '', String name = 'Tour du Vercors'}) => Ride(
  id: 'r',
  name: name,
  startedAt: DateTime.utc(2026, 6, 7, 7),
  endedAt: DateTime.utc(2026, 6, 7, 10, 30),
  stats: stats,
  previewPolyline: preview,
);

/// Largeur et hauteur lues dans l'en-tête IHDR d'un PNG.
(int, int) _pngSize(Uint8List png) {
  final b = ByteData.sublistView(png);
  return (b.getUint32(16), b.getUint32(20));
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await initTestLocale();
  });

  group('allègement de la trace', () {
    test('une trace courte est gardée telle quelle', () {
      final pts = [for (var i = 0; i < 10; i++) i];
      expect(decimateTrace(pts, maxPoints: 10), pts);
      expect(decimateTrace(const <int>[]), isEmpty);
    });

    test('une longue trace est ramenée au maximum, bouts compris, dans l’ordre', () {
      final pts = [for (var i = 0; i < 20000; i++) i];
      final out = decimateTrace(pts);
      expect(out.length, rideCardMaxPoints);
      expect(out.first, 0);
      expect(out.last, 19999);
      for (var i = 1; i < out.length; i++) {
        expect(out[i], greaterThan(out[i - 1]));
      }
      expect(decimateTrace(pts, maxPoints: 2), [0, 19999]);
    });
  });

  group('projection de la trace', () {
    const frame = Rect.fromLTWH(100, 50, 900, 450);

    test('trace vide : pas de projection', () {
      expect(TraceFit.fit(const [], frame), isNull);
    });

    test('un point seul (ou des points confondus) est centré', () {
      final fit = TraceFit.fit(const [GeoPoint(45, 5)], frame)!;
      expect(fit.map(const GeoPoint(45, 5)), frame.center);
      final same = TraceFit.fit(const [GeoPoint(45, 5), GeoPoint(45, 5)], frame)!;
      expect(same.map(const GeoPoint(45, 5)), frame.center);
    });

    test('les proportions sont gardées (correction cos(lat)) et la trace est centrée', () {
      // Carré de 1 km de côté à 45° N : en degrés, 1,41 fois plus large que haut.
      const dLat = 1000 / Geo.metersPerDegreeLat;
      final dLng = dLat / math.cos(45 * math.pi / 180);
      final sw = const GeoPoint(45, 5);
      final ne = GeoPoint(45 + dLat, 5 + dLng);
      final fit = TraceFit.fit([sw, ne], frame)!;
      final a = fit.map(sw);
      final b = fit.map(ne);
      final width = b.dx - a.dx;
      final height = a.dy - b.dy;
      // Le cadre est 2 fois plus large que haut : c'est la hauteur qui limite.
      expect(height, closeTo(frame.height, 0.5));
      expect(width / height, closeTo(1, 0.01));
      expect((a.dx + b.dx) / 2, closeTo(frame.center.dx, 0.5));
      expect((a.dy + b.dy) / 2, closeTo(frame.center.dy, 0.5));
    });

    test('à 60° N, un degré de longitude vaut un demi-degré de latitude', () {
      final fit = TraceFit.fit(const [GeoPoint(59.75, 5), GeoPoint(60.25, 6)], const Rect.fromLTWH(0, 0, 400, 400))!;
      final a = fit.map(const GeoPoint(59.75, 5));
      final b = fit.map(const GeoPoint(60.25, 6));
      expect((b.dx - a.dx) / (a.dy - b.dy), closeTo(1, 0.01));
    });

    test('une ligne plein est-ouest occupe toute la largeur, au milieu', () {
      final fit = TraceFit.fit(const [GeoPoint(45, 5), GeoPoint(45, 5.5)], frame)!;
      final a = fit.map(const GeoPoint(45, 5));
      final b = fit.map(const GeoPoint(45, 5.5));
      expect(a.dx, closeTo(frame.left, 0.5));
      expect(b.dx, closeTo(frame.right, 0.5));
      expect(a.dy, closeTo(frame.center.dy, 0.5));
    });

    test('tous les points tombent dans le cadre', () {
      final pts = [for (final p in _loop(3000)) p.point];
      final fit = TraceFit.fit(pts, frame)!;
      for (final p in pts) {
        final o = fit.map(p);
        expect(frame.inflate(0.01).contains(o), isTrue, reason: '$p → $o');
      }
    });
  });

  group('stats affichées', () {
    test('balade complète : grands chiffres puis bandeau', () {
      final (:hero, :details) = rideCardStats(_fullStats);
      expect([for (final s in hero) s.label], ['Distance', 'En roulant', 'Moyenne']);
      expect([for (final s in hero) s.value], ['182,4', '2 h 43', '67']);
      expect([for (final s in details) s.label], ['Vit. max', 'Angle G', 'Angle D', 'D+', 'Virages']);
      expect(details[1].value, '44°');
      expect(details[2].color, CmColors.forLean(49));
    });

    test('données partielles : seulement ce qui existe', () {
      final (:hero, :details) = rideCardStats(const RideStats(distanceM: 850, totalTimeS: 600));
      // Durée totale à défaut de temps en mouvement ; pas de moyenne sans elle.
      expect([for (final s in hero) s.toString()], ['Distance : 850 m', 'En roulant : 10 min']);
      expect(details, isEmpty);
    });

    test('sans angle (téléphone non calibré) : pas de « 0° »', () {
      final (:hero, :details) = rideCardStats(
        const RideStats(distanceM: 64000, movingTimeS: 3400, maxSpeedKmh: 110, curveCount: 40),
      );
      expect(hero.length, 3);
      expect([for (final s in details) s.label], ['Vit. max', 'Virages']);
    });

    test('balade vide : rien à afficher', () {
      final (:hero, :details) = rideCardStats(const RideStats());
      expect(hero, isEmpty);
      expect(details, isEmpty);
    });
  });

  group('contenu de la carte', () {
    test('trace complète : allégée et colorée par l’angle', () {
      final c = buildRideCardContent(
        _ride(),
        track: _loop(20000),
        bike: const Bike(id: 'b', name: 'La Tracer', colorValue: 0xFF4EA8FF),
      );
      expect(c.hasTrace, isTrue);
      expect(c.trace.length, rideCardMaxPoints);
      expect(c.leanRuns, isNotEmpty);
      final drawn = c.leanRuns.fold<int>(0, (s, r) => s + r.points.length);
      // Chaque morceau répète son point de jonction avec le suivant.
      expect(drawn, lessThanOrEqualTo(rideCardMaxPoints + 1 + c.leanRuns.length));
      expect(c.big, isNull);
      expect(c.hero.first.label, 'Distance');
      expect(c.bikeName, 'La Tracer');
      expect(c.overline, contains('DIMANCHE 7 JUIN 2026'));
      expect(c.title, 'Tour du Vercors');
      expect(c.canShare, isTrue);
    });

    test('trace sans angle : ligne orange simple', () {
      final c = buildRideCardContent(_ride(), track: _loop(800, lean: 0));
      expect(c.hasTrace, isTrue);
      expect(c.leanRuns, isEmpty);
    });

    test('points GPS imprécis écartés : l’aperçu prend le relais', () {
      final preview = Geo.encodePolyline(const [GeoPoint(45, 5), GeoPoint(45.1, 5.2)]);
      final c = buildRideCardContent(_ride(preview: preview), track: _loop(500, accuracy: 120));
      expect(c.trace, const [GeoPoint(45, 5), GeoPoint(45.1, 5.2)]);
      expect(c.leanRuns, isEmpty);
    });

    test('sans trace : la distance en grand à la place', () {
      final c = buildRideCardContent(_ride());
      expect(c.hasTrace, isFalse);
      expect(c.big?.label, 'Distance');
      expect([for (final s in c.hero) s.label], ['En roulant', 'Moyenne']);
      expect(c.canShare, isTrue);
    });

    test('trace minuscule (< 100 m) : pas de dessin', () {
      final preview = Geo.encodePolyline(const [GeoPoint(45, 5), GeoPoint(45.0003, 5.0003)]);
      final c = buildRideCardContent(_ride(preview: preview));
      expect(c.hasTrace, isFalse);
      expect(c.big, isNotNull);
    });

    test('ni trace ni distance : pas d’image', () {
      final c = buildRideCardContent(_ride(stats: const RideStats()));
      expect(c.canShare, isFalse);
    });

    test('texte de partage', () {
      expect(
        rideCardShareText(_ride()),
        "Tour du Vercors · 182 km · 49° d'angle max — balade du 7 juin 2026, enregistrée avec Cono Moto",
      );
      expect(
        rideCardShareText(_ride(stats: const RideStats(distanceM: 12400))),
        'Tour du Vercors · 12,4 km — balade du 7 juin 2026, enregistrée avec Cono Moto',
      );
    });
  });

  group('image PNG', () {
    Future<Uint8List> render(WidgetTester tester, RideCardContent c) async {
      final png = await tester.runAsync(() => renderRideCardPng(c));
      return png!;
    }

    testWidgets('trace colorée : PNG portrait 1080 × 1350', (tester) async {
      final c = buildRideCardContent(
        _ride(name: 'Un nom de balade très très long qui ne tiendra jamais sur deux lignes de la carte'),
        track: _loop(5000),
        bike: const Bike(id: 'b', name: 'MT-07', colorValue: 0xFF111111),
      );
      final png = await render(tester, c);
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(_pngSize(png), (1080, 1350));
    });

    testWidgets('sans trace ni bandeau : PNG quand même', (tester) async {
      final c = buildRideCardContent(_ride(stats: const RideStats(distanceM: 850)));
      expect(c.hero, isEmpty);
      expect(c.details, isEmpty);
      final png = await render(tester, c);
      expect(_pngSize(png), (1080, 1350));
    });

    testWidgets('trace simple depuis l’aperçu', (tester) async {
      final preview = Geo.encodePolyline([for (final p in _loop(400, lean: 0)) p.point]);
      final c = buildRideCardContent(_ride(preview: preview, stats: const RideStats(distanceM: 64000)));
      expect(c.hasTrace, isTrue);
      final png = await render(tester, c);
      expect(_pngSize(png), (1080, 1350));
    });
  });
}
