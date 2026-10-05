import 'dart:ui';

import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/planned_route.dart';
import 'package:cono_moto/data/models/shared.dart';
import 'package:cono_moto/features/navigation/navigation_logic.dart';
import 'package:cono_moto/features/traffic/traffic_providers.dart';
import 'package:cono_moto/services/routing/guidance_engine.dart';
import 'package:cono_moto/services/routing/maneuver_kinds.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Ligne droite vers le nord de [lengthM] mètres, un point tous les [stepM].
List<GeoPoint> northLine(double lengthM, {double stepM = 100, GeoPoint start = const GeoPoint(45, 5)}) => [
  for (var d = 0.0; d <= lengthM + 0.1; d += stepM) Geo.destination(start, 0, d),
];

Maneuver man(String type, double along, {String? street}) => Maneuver(
  instruction: 'Consigne $type',
  type: type,
  distanceAlongM: along,
  location: const GeoPoint(45, 5),
  streetName: street,
);

void main() {
  setUpAll(initTestLocale);

  group('caméra', () {
    test('zoom selon la vitesse : proche en ville, plus large à 110 km/h', () {
      expect(NavCamera.zoomForSpeed(0), 17.2);
      expect(NavCamera.zoomForSpeed(20), 17.2);
      expect(NavCamera.zoomForSpeed(50), closeTo(16.4, 1e-9));
      expect(NavCamera.zoomForSpeed(65), closeTo(16.05, 1e-9));
      expect(NavCamera.zoomForSpeed(110), closeTo(15.1, 1e-9));
      expect(NavCamera.zoomForSpeed(180), 14.8);
      expect(NavCamera.zoomForSpeed(double.nan), 17.2);
      // Le zoom ne remonte jamais quand on accélère.
      var last = double.infinity;
      for (var v = 0.0; v <= 200; v += 5) {
        final z = NavCamera.zoomForSpeed(v);
        expect(z, lessThanOrEqualTo(last));
        last = z;
      }
    });

    test('on se rapproche à l\'approche d\'une manœuvre', () {
      expect(NavCamera.zoomForSpeed(110, distanceToManeuverM: 1200), closeTo(15.1, 1e-9));
      expect(NavCamera.zoomForSpeed(110, distanceToManeuverM: 250), NavCamera.maneuverZoom);
      // Déjà plus proche en ville : on garde.
      expect(NavCamera.zoomForSpeed(10, distanceToManeuverM: 50), 17.2);
    });

    test('zoom lissé : pas de pompage, pas de saut', () {
      expect(NavCamera.smoothZoom(null, 16), 16);
      expect(NavCamera.smoothZoom(16, 16.05), 16);
      expect(NavCamera.smoothZoom(16, 15), closeTo(15.7, 1e-9));
      expect(NavCamera.smoothZoom(15, 16), closeTo(15.3, 1e-9));
      expect(NavCamera.smoothZoom(15.9, 16.1), closeTo(16.1, 1e-9));
    });

    test('vitesse lissée et cap', () {
      expect(NavCamera.smoothSpeed(null, 90), 90);
      expect(NavCamera.smoothSpeed(90, 50), closeTo(76, 1e-9));
      expect(NavCamera.smoothSpeed(10, -3), closeTo(6.5, 1e-9));
      expect(NavCamera.bearingFor(heading: 370, speedKmh: 40), 10);
      // À l'arrêt, on garde le dernier cap.
      expect(NavCamera.bearingFor(heading: 200, speedKmh: 3, previous: 90), 90);
      expect(NavCamera.bearingFor(heading: null, speedKmh: 60, previous: 45), 45);
      expect(NavCamera.bearingFor(heading: null, speedKmh: 60), isNull);
    });

    test('motard dans le tiers bas, au-dessus du panneau', () {
      final insets = NavCamera.riderInsets(const Size(400, 800), bottomOverlay: 120);
      // Point focal = (h + haut) / 2.
      final focalY = (800 + insets.top) / 2;
      expect(focalY, closeTo(560, 1e-9));
      expect(focalY, lessThan(800 - 120));
      expect(insets.left, 0);
      // Petit écran : on reste au-dessus du panneau, jamais au-dessus du milieu.
      final small = NavCamera.riderInsets(const Size(360, 300), bottomOverlay: 120);
      expect((300 + small.top) / 2, 150);
      // Paysage : le point focal est décalé à droite du panneau latéral.
      final land = NavCamera.riderInsets(const Size(850, 390), leftOverlay: 400, fraction: 0.62);
      expect(land.left, 400);
      expect((390 + land.top) / 2, closeTo(390 * 0.62, 1e-9));
      expect(NavCamera.riderInsets(Size.zero).top, 0);
    });
  });

  group('parcouru / restant', () {
    final line = northLine(1000);

    test('coupe à la position, les deux morceaux se rejoignent', () {
      final s = splitRoute(line, 250);
      expect(Geo.length(s.done), closeTo(250, 0.5));
      expect(Geo.length(s.remaining), closeTo(750, 0.5));
      expect(s.done.last, s.remaining.first);
      expect(s.done.first, line.first);
      expect(s.remaining.last, line.last);
    });

    test('sur un sommet : pas de point en double', () {
      final cum = Geo.cumulativeDistances(line);
      final s = splitRoute(line, cum[3], cumulative: cum);
      expect(s.done, hasLength(4));
      expect(s.remaining.first, line[3]);
      expect(s.done.length + s.remaining.length, line.length + 1);
    });

    test('bords : départ, arrivée, ligne trop courte', () {
      expect(splitRoute(line, 0).done, isEmpty);
      expect(splitRoute(line, -5).remaining, same(line));
      expect(splitRoute(line, 5000).remaining, isEmpty);
      expect(splitRoute(line, 5000).done, same(line));
      expect(splitRoute(const [GeoPoint(45, 5)], 10).remaining, hasLength(1));
    });

    test('géométrie allégée : même découpage à l\'échelle', () {
      final dense = northLine(20000, stepM: 10);
      final route = PlannedRoute(id: 'r', name: 'R', createdAt: DateTime.utc(2026), points: dense);
      final g = NavRouteGeometry(route);
      expect(g.points.length, lessThan(dense.length));
      final s = g.split(12000);
      expect(Geo.length(s.done), closeTo(12000, 5));
      expect(g.ahead(12000).first, s.remaining.first);
      expect(g.ahead(30000), g.points, reason: 'arrivé : on renvoie tout le tracé');
    });
  });

  group('heure d\'arrivée', () {
    final now = DateTime(2026, 10, 5, 14, 0);

    test('au prorata de la durée prévue', () {
      final eta = NavEta.compute(remainingM: 30000, totalM: 120000, routeDurationS: 7200, now: now);
      expect(eta.remaining, const Duration(minutes: 30));
      expect(eta.arrival, DateTime(2026, 10, 5, 14, 30));
      expect(eta.remainingM, 30000);
    });

    test('sans durée prévue : 55 km/h de moyenne', () {
      final eta = NavEta.compute(remainingM: 55000, totalM: 55000, routeDurationS: 0, now: now);
      expect(eta.remaining, const Duration(hours: 1));
    });

    test('valeurs aberrantes bornées', () {
      expect(NavEta.compute(remainingM: -10, totalM: 1000, routeDurationS: 100, now: now).remaining, Duration.zero);
      expect(
        NavEta.compute(remainingM: 5000, totalM: 1000, routeDurationS: 100, now: now).remaining,
        const Duration(seconds: 100),
      );
    });
  });

  group('affichage', () {
    test('distance de manœuvre en gros chiffres', () {
      expect(maneuverDistanceParts(0), ('0', 'm'));
      expect(maneuverDistanceParts(84), ('80', 'm'));
      expect(maneuverDistanceParts(286), ('290', 'm'));
      expect(maneuverDistanceParts(480), ('500', 'm'));
      expect(maneuverDistanceParts(990), ('1', 'km'));
      expect(maneuverDistanceParts(1240), ('1,2', 'km'));
      expect(maneuverDistanceParts(3210), ('3,2', 'km'));
      expect(maneuverDistanceParts(12600), ('13', 'km'));
      expect(navDistance(3210), '3,2 km');
    });

    test('numéro de sortie de rond-point', () {
      expect(roundaboutExitNumber('Prends le rond-point et prends la 2e sortie sur D 936.'), 2);
      expect(roundaboutExitNumber('Au rond-point, prends la 1re sortie'), 1);
      expect(roundaboutExitNumber('Prends la 3ème sortie'), 3);
      expect(roundaboutExitNumber('Tourne à gauche sur D 906.'), isNull);
    });

    test('bandeau incident', () {
      const works = TrafficIncident(id: 'w', kind: IncidentKind.travaux, location: GeoPoint(45, 5));
      expect(incidentAheadText(const IncidentAhead(works, 3210)), 'Travaux dans 3,2 km');
      expect(incidentAheadText(const IncidentAhead(works, 640)), 'Travaux dans 650 m');
      expect(incidentAheadText(const IncidentAhead(works, 20)), 'Travaux ici');
    });
  });

  group('manœuvre suivante (« puis … »)', () {
    final list = [
      man(ManeuverKind.depart, 0),
      man(ManeuverKind.right, 1000, street: 'Rue de la Gare'),
      man(ManeuverKind.left, 1200, street: 'D 12'),
      man(ManeuverKind.roundabout, 2500),
      man(ManeuverKind.roundaboutExit, 2540),
      man(ManeuverKind.continueOn, 2600),
      man(ManeuverKind.slightRight, 2800),
      man(ManeuverKind.arrive, 5000),
    ];

    test('rapprochée : affichée', () {
      expect(GuidanceEngine.thenManeuver(list, 1)?.streetName, 'D 12');
    });

    test('trop loin : rien', () {
      expect(GuidanceEngine.thenManeuver(list, 2), isNull);
      expect(GuidanceEngine.thenManeuver(list, 2, maxGapM: 2000)?.type, ManeuverKind.roundabout);
    });

    test('rond-point : on saute la sortie et les « continue »', () {
      expect(GuidanceEngine.thenManeuver(list, 3)?.type, ManeuverKind.slightRight);
    });

    test('arrivée ou index hors limites : rien', () {
      expect(GuidanceEngine.thenManeuver(list, 7), isNull);
      expect(GuidanceEngine.thenManeuver(list, -1), isNull);
      expect(GuidanceEngine.thenManeuver(list, 99), isNull);
    });

    test('le moteur la donne dans sa photo', () {
      final pts = northLine(5000);
      final route = PlannedRoute(id: 'r', name: 'R', createdAt: DateTime.utc(2026), points: pts, maneuvers: list);
      final engine = GuidanceEngine(route);
      final snap = engine.update(Geo.pointAtDistance(pts, 600), accuracyM: 5, speedMs: 14);
      expect(snap.next?.streetName, 'Rue de la Gare');
      expect(snap.then?.streetName, 'D 12');
    });

    test('itinéraire recalculé : pas de nouveau « C\'est parti »', () {
      final pts = northLine(5000);
      final route = PlannedRoute(id: 'r', name: 'R', createdAt: DateTime.utc(2026), points: pts, maneuvers: list);
      expect(GuidanceEngine(route).update(pts.first, accuracyM: 5).announcement, startsWith("C'est parti"));
      expect(GuidanceEngine(route, rerouted: true).update(pts.first, accuracyM: 5).announcement, isNull);
    });
  });

  group('incidents sur la route', () {
    final line = northLine(20000);
    final works = TrafficIncident(
      id: 'w',
      kind: IncidentKind.travaux,
      location: Geo.destination(Geo.pointAtDistance(line, 8000), 90, 40),
    );
    final far = TrafficIncident(
      id: 'far',
      kind: IncidentKind.accident,
      location: Geo.destination(Geo.pointAtDistance(line, 5000), 90, 2000),
    );
    final crash = TrafficIncident(id: 'c', kind: IncidentKind.accident, location: Geo.pointAtDistance(line, 15000));

    test('situés une fois le long du tracé, distance live', () {
      final located = RouteIncidents.locate(line, [crash, far, works]);
      expect(located.map((a) => a.incident.id), ['w', 'c']);
      final a = RouteIncidents.next(located, 4800)!;
      expect(a.incident.id, 'w');
      expect(a.distanceAheadM, closeTo(3200, 2));
      // Dépassé (au-delà de 30 m) : on passe au suivant.
      expect(RouteIncidents.next(located, 8100)!.incident.id, 'c');
      // Trop loin devant.
      expect(RouteIncidents.next(located, 0, horizonM: 5000), isNull);
      expect(RouteIncidents.next(located, 16000), isNull);
    });
  });

  group('anti-spam du recalcul', () {
    final t0 = DateTime.utc(2026, 10, 5, 10);

    test('une tentative toutes les 20 s, 3 max par 5 min', () {
      final th = RerouteThrottle();
      expect(th.canAttempt(t0), isTrue);
      th.record(t0);
      expect(th.canAttempt(t0.add(const Duration(seconds: 10))), isFalse);
      expect(th.waitBefore(t0.add(const Duration(seconds: 10))), const Duration(seconds: 10));
      th.record(t0.add(const Duration(seconds: 20)));
      th.record(t0.add(const Duration(seconds: 40)));
      // 3 tentatives dans la fenêtre : on attend que la première sorte.
      final t1 = t0.add(const Duration(minutes: 2));
      expect(th.canAttempt(t1), isFalse);
      expect(th.waitBefore(t1), const Duration(minutes: 3));
      expect(th.canAttempt(t0.add(const Duration(minutes: 5))), isTrue);
      th.reset();
      expect(th.attempts, isEmpty);
    });

    test('recalcul automatique : délai de grâce puis anti-spam', () {
      final p = AutoReroutePolicy();
      DateTime at(int s) => t0.add(Duration(seconds: s));
      expect(p.onSnapshot(offRoute: false, arrived: false, at: at(0)), isFalse);
      expect(p.onSnapshot(offRoute: true, arrived: false, at: at(1)), isFalse);
      expect(p.offRouteSince, at(1));
      expect(p.onSnapshot(offRoute: true, arrived: false, at: at(3)), isFalse, reason: 'le temps d\'un demi-tour');
      expect(p.onSnapshot(offRoute: true, arrived: false, at: at(5), busy: true), isFalse);
      expect(p.onSnapshot(offRoute: true, arrived: false, at: at(5)), isTrue);
      // Toujours hors itinéraire (échec réseau) : pas avant 20 s.
      expect(p.onSnapshot(offRoute: true, arrived: false, at: at(15)), isFalse);
      expect(p.onSnapshot(offRoute: true, arrived: false, at: at(25)), isTrue);
      expect(p.onSnapshot(offRoute: true, arrived: false, at: at(45)), isTrue);
      // 3 en 5 min : stop jusqu'à ce que la première sorte de la fenêtre.
      for (var s = 65; s < 300; s += 20) {
        expect(p.onSnapshot(offRoute: true, arrived: false, at: at(s)), isFalse, reason: 'à $s s');
      }
      expect(p.onSnapshot(offRoute: true, arrived: false, at: at(306)), isTrue);
      // Retour sur l'itinéraire : on repart de zéro pour le délai de grâce.
      expect(p.onSnapshot(offRoute: false, arrived: false, at: at(310)), isFalse);
      expect(p.offRouteSince, isNull);
      // Arrivé : jamais.
      final q = AutoReroutePolicy();
      expect(q.onSnapshot(offRoute: true, arrived: true, at: at(0)), isFalse);
      expect(q.onSnapshot(offRoute: true, arrived: true, at: at(100)), isFalse);
    });

    test('un recalcul manuel compte aussi', () {
      final p = AutoReroutePolicy();
      p.recordManual(t0);
      expect(p.onSnapshot(offRoute: true, arrived: false, at: t0), isFalse);
      expect(p.onSnapshot(offRoute: true, arrived: false, at: t0.add(const Duration(seconds: 10))), isFalse);
      expect(p.onSnapshot(offRoute: true, arrived: false, at: t0.add(const Duration(seconds: 21))), isTrue);
    });
  });
}
