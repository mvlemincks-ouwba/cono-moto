import 'package:cono_moto/core/geo.dart';
import 'package:cono_moto/core/settings.dart';
import 'package:cono_moto/features/navigation/recent_destinations.dart';
import 'package:cono_moto/services/routing/geocoder.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

RecentDestination dest(String name, GeoPoint p, {int day = 1}) =>
    RecentDestination(name: name, point: p, usedAt: DateTime.utc(2026, 10, day));

void main() {
  const chamrousse = GeoPoint(45.1253, 5.8762);
  const vercors = GeoPoint(45.05, 5.42);

  group('liste des récents', () {
    test('ajout en tête, doublon (même endroit) remonté', () {
      var list = <RecentDestination>[];
      list = RecentDestinations.add(list, dest('Chamrousse', chamrousse));
      list = RecentDestinations.add(list, dest('Vercors', vercors, day: 2));
      expect(list.map((d) => d.name), ['Vercors', 'Chamrousse']);
      // À 30 m près, c'est la même destination.
      list = RecentDestinations.add(list, dest('Station de Chamrousse', Geo.destination(chamrousse, 90, 30), day: 3));
      expect(list.map((d) => d.name), ['Station de Chamrousse', 'Vercors']);
    });

    test('même nom proche : même destination ; loin : différente', () {
      final a = dest('Mairie', const GeoPoint(45, 5));
      expect(RecentDestinations.same(a, dest('mairie', Geo.destination(a.point, 0, 900))), isTrue);
      expect(RecentDestinations.same(a, dest('Mairie', Geo.destination(a.point, 0, 50000))), isFalse);
    });

    test('au plus 8, les plus anciens sortent', () {
      var list = <RecentDestination>[];
      for (var i = 0; i < 12; i++) {
        list = RecentDestinations.add(list, dest('Lieu $i', GeoPoint(45 + i * 0.1, 5)));
      }
      expect(list, hasLength(RecentDestinations.maxCount));
      expect(list.first.name, 'Lieu 11');
      expect(list.last.name, 'Lieu 4');
    });

    test('suppression', () {
      final list = [dest('A', chamrousse), dest('B', vercors)];
      expect(RecentDestinations.remove(list, list.first).map((d) => d.name), ['B']);
    });

    test('aller-retour JSON, lecture tolérante', () {
      final list = [
        RecentDestination(
          name: 'Col du Glandon',
          detail: '73130 Saint-Colomban',
          point: chamrousse,
          usedAt: DateTime.utc(2026, 9, 1),
        ),
        dest('Vercors', vercors),
      ];
      final back = RecentDestinations.decode(RecentDestinations.encode(list));
      expect(back, hasLength(2));
      expect(back.first.label, 'Col du Glandon, 73130 Saint-Colomban');
      expect(back.first.point, chamrousse);
      expect(back.first.usedAt, DateTime.utc(2026, 9, 1));
      expect(back.last.detail, isNull);
      expect(RecentDestinations.decode(null), isEmpty);
      expect(RecentDestinations.decode('pas du json'), isEmpty);
      expect(RecentDestinations.decode('{"a":1}'), isEmpty);
      expect(RecentDestinations.decode('[{"name":"X"},{"name":"Ok","lat":45,"lng":5}, 3]').map((d) => d.name), ['Ok']);
    });

    test('lieu ↔ destination récente', () {
      const place = Place(name: 'Grenoble', detail: '38000', point: GeoPoint(45.19, 5.72));
      final r = RecentDestination.fromPlace(place, DateTime.utc(2026));
      expect(r.toPlace().label, place.label);
      expect(r.toPlace().point, place.point);
    });
  });

  test('gardées dans les préférences du téléphone', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer make() {
      final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      return c;
    }

    final c = make();
    expect(c.read(recentDestinationsProvider), isEmpty);
    await c.read(recentDestinationsProvider.notifier).add(const Place(name: 'Chamrousse', point: chamrousse));
    await c.read(recentDestinationsProvider.notifier).add(const Place(name: 'Vercors', point: vercors));
    expect(prefs.getString(RecentDestinationsNotifier.prefsKey), isNotNull);

    final again = make();
    expect(again.read(recentDestinationsProvider).map((d) => d.name), ['Vercors', 'Chamrousse']);
    await again.read(recentDestinationsProvider.notifier).remove(again.read(recentDestinationsProvider).first);
    expect(again.read(recentDestinationsProvider).map((d) => d.name), ['Chamrousse']);
    await again.read(recentDestinationsProvider.notifier).clear();
    expect(make().read(recentDestinationsProvider), isEmpty);
  });
}
