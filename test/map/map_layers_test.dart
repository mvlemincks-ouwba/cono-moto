import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/map/map_models.dart';
import 'package:cono_moto/core/theme.dart';
import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/data/models/shared.dart';
import 'package:cono_moto/features/map/map_layers.dart';
import 'package:cono_moto/features/offline/offline_maps.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

void main() {
  setUpAll(initTestLocale);

  FuelStation station(String id, double price) => FuelStation(
        id: id,
        location: const GeoPoint(45, 5),
        address: '1 rue X',
        city: 'Grenoble',
        prices: {FuelType.sp98: price},
      );

  test('étiquettes de prix colorées du moins cher au plus cher', () {
    final markers = MapLayers.stations(
      [station('a', 1.799), station('b', 1.899), station('c', 1.999), station('d', 1.849), station('e', 1.949)],
      FuelType.sp98,
    );
    expect(markers.length, 5);
    final byId = {for (final m in markers) m.id: m};
    expect(byId['station:a']!.color, CmColors.green);
    expect(byId['station:a']!.highlighted, isTrue);
    expect(byId['station:c']!.color, CmColors.red);
    expect(byId['station:a']!.text, '1,799');
    expect(byId['station:a']!.style, MarkerStyle.tag);
  });

  test('stations sans prix pour ce carburant ignorées', () {
    expect(MapLayers.stations([station('a', 1.8)], FuelType.gazole), isEmpty);
  });

  test('pote en SOS mis en avant', () {
    final m = MapLayers.friend(FriendLive(
      uid: 'u1',
      name: 'Max Verstap',
      location: const GeoPoint(45, 5),
      updatedAt: DateTime.now().toUtc(),
      riding: true,
      speedKmh: 87,
      sos: true,
    ));
    expect(m.highlighted, isTrue);
    expect(m.text, 'MV');
    expect(m.zIndex, greaterThan(50));
  });

  test('estimation des tuiles hors-ligne', () {
    final small = GeoBounds.around(const GeoPoint(45.2, 5.7), 10000);
    final big = GeoBounds.around(const GeoPoint(45.2, 5.7), 50000);
    expect(OfflineTiles.tileCount(small), greaterThan(0));
    expect(OfflineTiles.tileCount(big), greaterThan(OfflineTiles.tileCount(small) * 10));
    // Zone de 20 km de côté en zooms 6-14 : quelques milliers de tuiles au plus.
    expect(OfflineTiles.tileCount(small), lessThan(5000));
  });
}
