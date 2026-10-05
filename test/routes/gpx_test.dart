import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/services/routing/gpx.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  group('Export GPX', () {
    test('trace enregistrée : time et ele, aller-retour', () {
      final t0 = DateTime.utc(2026, 9, 20, 8);
      final track = [
        for (var i = 0; i < 20; i++)
          TrackPoint(
            time: t0.add(Duration(seconds: i * 5)),
            lat: 48.6 + i * 0.0005,
            lng: 1.8 + i * 0.0007,
            altitude: 100 + i * 1.5,
          ),
      ];
      final xml = buildGpx(name: 'Sortie <du> dimanche & co', track: track);
      expect(xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(xml, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
      expect(xml, contains('<name>Sortie &lt;du&gt; dimanche &amp; co</name>'));
      expect(xml, isNot(contains('<rte>')));
      final data = parseGpx(xml);
      expect(data.name, 'Sortie <du> dimanche & co');
      expect(data.tracks, hasLength(1));
      final pts = data.tracks.single;
      expect(pts, hasLength(20));
      expect(pts[3].lat, closeTo(track[3].lat, 1e-6));
      expect(pts[3].lng, closeTo(track[3].lng, 1e-6));
      expect(pts[3].elevation, closeTo(104.5, 0.05));
      expect(pts[3].time, track[3].time);
    });

    test('balade planifiée : trk + rte, aller-retour', () {
      final points = [
        for (var i = 0; i <= 200; i++) GeoPoint(48.6 + 0.01 * (i / 200), 1.8 + 0.02 * (i / 200) + 0.002 * (i % 7) / 7),
      ];
      final route = PlannedRoute(
        id: 'r1',
        name: 'Virolos vers Dourdan',
        createdAt: DateTime.utc(2026, 10, 1),
        points: points,
        style: RouteStyle.sinueux,
        description: 'Boucle de 3 km.',
      );
      final xml = buildRouteGpx(route);
      expect(xml, contains('<rte>'));
      expect(xml, contains('<trk>'));
      expect(xml, contains('<desc>Boucle de 3 km.</desc>'));
      final imp = importGpx(xml);
      expect(imp.sparse, isFalse);
      expect(imp.route.name, 'Virolos vers Dourdan');
      expect(imp.route.source, RouteSource.gpx);
      expect(imp.route.points, hasLength(points.length));
      for (var i = 0; i < points.length; i += 17) {
        expect(Geo.distance(imp.route.points[i], points[i]), lessThan(0.2));
      }
      expect(imp.route.distanceM, closeTo(Geo.length(points), 5));
      expect(imp.route.description, 'Boucle de 3 km.');
      expect(imp.data.routes.single.length, lessThan(points.length));
    });

    test('nom de fichier', () {
      expect(gpxFileName('Virolos vers Dourdan !'), 'virolos-vers-dourdan.gpx');
      expect(gpxFileName('Forêts : Rambouillet & Œuf'), 'forets-rambouillet-oeuf.gpx');
      expect(gpxFileName('***'), 'balade.gpx');
    });
  });

  group('Import GPX', () {
    test('trace Garmin multi-segments', () {
      final imp = importGpx(fixture('track_with_time.gpx'), fileName: 'mon_fichier.gpx');
      expect(imp.route.name, 'Tour du Vexin & des Boucles');
      expect(imp.sparse, isFalse);
      expect(imp.route.points, hasLength(8));
      expect(imp.data.waypoints.single.name, 'Pause café');
      expect(imp.data.tracks, hasLength(2));
      expect(imp.data.tracks.first.first.time, DateTime.utc(2026, 9, 20, 8));
      // D+ avec hystérésis 5 m : 100 → 110 → 118 → 126.
      expect(imp.route.elevationGainM, 26);
      expect(imp.route.durationS, greaterThan(0));
      expect(imp.route.waypoints, [imp.route.points.first, imp.route.points.last]);
    });

    test('itinéraire épars (rte seul) → à recalculer', () {
      final imp = importGpx(fixture('route_only.gpx'));
      expect(imp.sparse, isTrue);
      expect(imp.route.name, 'Route des Crêtes');
      expect(imp.route.description, 'Les Vosges par les crêtes');
      expect(imp.route.points, hasLength(4));
      expect(imp.route.waypoints, hasLength(4));
      expect(imp.route.curvatureScore, 0);
      expect(imp.data.routes.single.first.name, 'Col de la Schlucht');
    });

    test('GPX 1.0 sans espace de noms', () {
      final imp = importGpx(fixture('gpx10_no_ns.gpx'));
      expect(imp.route.name, 'Vieille trace');
      expect(imp.route.points, hasLength(3));
      expect(imp.route.elevationGainM, 5);
    });

    test('nom par défaut depuis le fichier', () {
      const xml =
          '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">'
          '<trk><trkseg><trkpt lat="45" lon="5"/><trkpt lat="45.01" lon="5.01"/></trkseg></trk></gpx>';
      expect(importGpx(xml, fileName: 'tour_du_lac.gpx').route.name, 'tour du lac');
      expect(importGpx(xml).route.name, 'Balade importée');
    });

    test('fichiers invalides', () {
      expect(() => importGpx('pas du xml <<<'), throwsA(isA<GpxFormatException>()));
      expect(() => importGpx('<kml></kml>'), throwsA(isA<GpxFormatException>()));
      expect(() => importGpx('<gpx version="1.1"></gpx>'), throwsA(isA<GpxFormatException>()));
      expect(
        () => importGpx('<gpx><trk><trkseg><trkpt lat="abc" lon="5"/></trkseg></trk></gpx>'),
        throwsA(isA<GpxFormatException>()),
      );
    });
  });
}
