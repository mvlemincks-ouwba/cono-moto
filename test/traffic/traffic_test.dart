import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/data/models/shared.dart';
import 'package:cono_moto/features/traffic/traffic_providers.dart';
import 'package:cono_moto/services/traffic/tomtom_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sample = {
    'incidents': [
      {
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [5.0, 45.0],
            [5.01, 45.0],
          ],
        },
        'properties': {
          'id': 'abc',
          'iconCategory': 8,
          'magnitudeOfDelay': 4,
          'events': [
            {'description': 'Route fermée', 'code': 401, 'iconCategory': 8}
          ],
          'startTime': '2026-10-05T06:00:00Z',
          'endTime': null,
          'from': 'Villard',
          'to': 'Lans',
          'length': 800.5,
          'delay': 0,
          'roadNumbers': ['D531'],
        },
      },
      {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [5.2, 45.1]},
        'properties': {'id': 'p1', 'iconCategory': 1, 'events': []},
      },
      {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': 'bad'},
        'properties': {'id': 'x'},
      },
    ],
  };

  test('parse les incidents TomTom', () {
    final list = TomTomTrafficClient.parseIncidents(sample);
    expect(list.length, 2);
    final closed = list.first;
    expect(closed.kind, IncidentKind.fermeture);
    expect(closed.geometry.length, 2);
    expect(closed.location.lat, 45.0);
    expect(closed.location.lng, 5.0);
    expect(closed.description, 'Route fermée');
    expect(closed.roadName, 'D531');
    expect(closed.magnitude, 4);
    expect(list[1].kind, IncidentKind.accident);
    expect(list[1].geometry, isEmpty);
  });

  test('réponse inattendue → liste vide', () {
    expect(TomTomTrafficClient.parseIncidents(null), isEmpty);
    expect(TomTomTrafficClient.parseIncidents({'incidents': 'non'}), isEmpty);
  });

  test('bbox trop grande réduite sous 10 000 km²', () {
    const big = GeoBounds(south: 44, west: 4, north: 46, east: 7);
    final c = TomTomTrafficClient.clampBounds(big);
    final h = (c.north - c.south) * 111.32;
    final w = (c.east - c.west) * 111.32 * 0.7071;
    expect(h * w, lessThan(10000));
    expect(c.center.lat, closeTo(45, 1e-9));
  });

  test('incidents devant moi sur l\'itinéraire', () {
    final route = [for (var i = 0; i <= 100; i++) GeoPoint(45.0, 5.0 + i * 0.002)];
    final incidents = [
      const TrafficIncident(id: 'devant', kind: IncidentKind.travaux, location: GeoPoint(45.0005, 5.1)),
      const TrafficIncident(id: 'derriere', kind: IncidentKind.accident, location: GeoPoint(45.0, 5.01)),
      const TrafficIncident(id: 'loin', kind: IncidentKind.accident, location: GeoPoint(45.05, 5.1)),
    ];
    final myAlong = Geo.project(const GeoPoint(45.0, 5.05), route)!.distanceAlongM;
    final ahead = incidentsAhead(route: route, myDistanceAlongM: myAlong, incidents: incidents);
    expect(ahead.map((a) => a.incident.id), ['devant']);
    expect(ahead.first.distanceAheadM, closeTo(3935, 60));
  });

  test('petits bouchons masqués', () {
    expect(isRelevantIncident(const TrafficIncident(id: 'a', kind: IncidentKind.bouchon, location: GeoPoint(0, 0), magnitude: 1)), isFalse);
    expect(isRelevantIncident(const TrafficIncident(id: 'b', kind: IncidentKind.bouchon, location: GeoPoint(0, 0), magnitude: 3)), isTrue);
    expect(isRelevantIncident(const TrafficIncident(id: 'c', kind: IncidentKind.travaux, location: GeoPoint(0, 0))), isTrue);
  });
}
