// Réponses réalistes du jeu Opendatasoft « prix-des-carburants-en-france-flux-instantane-v2 ».

/// Format actuel (Explore v2.1) : geom {lon, lat}, prix numériques, listes JSON.
const fuelResponseV21 = r'''
{
  "total_count": 3,
  "results": [
    {
      "id": 38000001,
      "latitude": "4518779",
      "longitude": "572449",
      "cp": "38000",
      "pop": "R",
      "adresse": "12 AVENUE DE LA GARE",
      "ville": "GRENOBLE",
      "horaires": "{\"@automate-24-24\": \"1\"}",
      "geom": {"lon": 5.72449, "lat": 45.18779},
      "gazole_maj": "2026-10-04T07:12:00+00:00",
      "gazole_prix": 1.689,
      "sp95_maj": null,
      "sp95_prix": null,
      "e85_maj": null,
      "e85_prix": null,
      "gplc_maj": null,
      "gplc_prix": null,
      "e10_maj": "2026-10-04T07:12:00+00:00",
      "e10_prix": 1.759,
      "sp98_maj": "2026-10-04T07:12:00+00:00",
      "sp98_prix": 1.849,
      "carburants_disponibles": ["Gazole", "E10", "SP98"],
      "carburants_indisponibles": ["SP95", "E85", "GPLc"],
      "horaires_automate_24_24": "Oui",
      "services_service": ["Station de gonflage", "Boutique alimentaire"],
      "departement": "Isère",
      "code_departement": "38",
      "region": "Auvergne-Rhône-Alpes",
      "code_region": "84"
    },
    {
      "id": "38100002",
      "latitude": 4517000.0,
      "longitude": 571000.0,
      "cp": "38100",
      "adresse": "ROUTE DE LYON - RN 85",
      "ville": "SAINT-MARTIN-D'HÈRES",
      "geom": null,
      "gazole_prix": "1.699",
      "gazole_maj": "2026-10-03 18:00:00",
      "sp98_prix": "1889",
      "sp98_maj": "2026-09-25 10:00:00",
      "e10_prix": "1,779",
      "e10_maj": "2026-10-04 06:30:00",
      "carburants_indisponibles": "E10;GPLc",
      "horaires_automate_24_24": "Non"
    },
    {
      "id": 38200003,
      "cp": "38200",
      "adresse": "Sans coordonnées",
      "ville": "Vienne",
      "sp98_prix": 1.9
    }
  ]
}
''';

/// Ancien format (v1) : records[].fields + geometry GeoJSON.
const fuelResponseV1 = r'''
{
  "nhits": 1,
  "records": [
    {
      "recordid": "abc",
      "fields": {
        "id": 69000009,
        "adresse": "3 rue Garibaldi",
        "ville": "Lyon",
        "cp": "69003",
        "sp98_prix": 1.869,
        "sp98_maj": "2026-10-04T05:00:00+02:00",
        "carburants_indisponibles": "Gazole"
      },
      "geometry": {"type": "Point", "coordinates": [4.85, 45.76]}
    }
  ]
}
''';

/// Construit une réponse v2.1 à partir de stations (lat, lng, prix SP98).
String fuelResponseWith(List<({String id, double lat, double lng, double sp98})> stations) {
  final rows = stations
      .map(
        (s) =>
            '{"id": "${s.id}", "geom": {"lon": ${s.lng}, "lat": ${s.lat}}, '
            '"adresse": "Station ${s.id}", "ville": "Ville", "cp": "00000", '
            '"sp98_prix": ${s.sp98}, "sp98_maj": "2026-10-04T07:00:00+00:00"}',
      )
      .join(',');
  return '{"total_count": ${stations.length}, "results": [$rows]}';
}
