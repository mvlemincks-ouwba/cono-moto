import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/data/repositories.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

void main() {
  test('balade + points : enregistrement et relecture', () async {
    final db = await openTestDatabase();
    final repo = RideRepository(db);
    final ride = Ride(
      id: 'r1',
      name: 'Tour du Vercors',
      startedAt: DateTime.utc(2026, 6, 1, 9),
      endedAt: DateTime.utc(2026, 6, 1, 12),
      stats: const RideStats(distanceM: 142000, maxLeanLeftDeg: 38, leanHistogram: {0: 100, 10: 50}),
    );
    await repo.upsert(ride);
    await repo.appendPoints('r1', 0, [
      TrackPoint(time: DateTime.utc(2026, 6, 1, 9), lat: 45.0, lng: 5.5, speedMs: 10, leanDeg: -12),
      TrackPoint(time: DateTime.utc(2026, 6, 1, 9, 0, 1), lat: 45.0001, lng: 5.5001, speedMs: 11),
    ]);
    final loaded = await repo.get('r1');
    expect(loaded!.name, 'Tour du Vercors');
    expect(loaded.stats.maxLeanLeftDeg, 38);
    expect(loaded.stats.leanHistogram[10], 50);
    expect(await repo.pointCount('r1'), 2);
    expect((await repo.points('r1')).first.leanDeg, -12);
    expect((await repo.list()).length, 1);
    await repo.delete('r1');
    expect(await repo.get('r1'), isNull);
    await db.close();
  });

  test('garage : moto par défaut et kilométrage', () async {
    final db = await openTestDatabase();
    final repo = GarageRepository(db);
    await repo.upsertBike(const Bike(id: 'a', name: 'MT-07', isDefault: true));
    await repo.upsertBike(const Bike(id: 'b', name: 'Tracer', isDefault: true));
    final def = await repo.defaultBike();
    expect(def!.id, 'b');
    await repo.addDistance('b', 120.5);
    final b = await repo.bike('b');
    expect(b!.odometerKm, 120.5);
    expect(b.kmSinceFullTank, 120.5);
    await db.close();
  });
}
