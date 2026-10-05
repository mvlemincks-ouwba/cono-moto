import 'package:cono_moto/data/models/ride.dart';
import 'package:cono_moto/features/history/history_stats.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

Ride ride(
  String id,
  DateTime start, {
  double km = 100,
  int movingS = 7200,
  double maxSpeed = 120,
  double left = 30,
  double right = 30,
  int brakes = 0,
  double gain = 500,
  Map<int, int> hist = const {},
}) => Ride(
  id: id,
  name: 'Balade $id',
  startedAt: start,
  endedAt: start.add(Duration(seconds: movingS + 600)),
  stats: RideStats(
    distanceM: km * 1000,
    movingTimeS: movingS,
    totalTimeS: movingS + 600,
    maxSpeedKmh: maxSpeed,
    maxLeanLeftDeg: left,
    maxLeanRightDeg: right,
    hardBrakeCount: brakes,
    elevationGainM: gain,
    curveCount: 10,
    leanHistogram: hist,
  ),
);

void main() {
  setUpAll(initTestLocale);
  final now = DateTime(2026, 10, 15, 18);

  final rides = [
    ride('a', DateTime(2026, 10, 12, 9), km: 150, left: 38, right: 44, brakes: 3, hist: {0: 3000, 10: 1500, 30: 200}),
    ride('b', DateTime(2026, 10, 2, 14), km: 80, movingS: 3600, maxSpeed: 165, left: 35, right: 40, gain: 1500),
    ride(
      'c',
      DateTime(2026, 8, 20, 10),
      km: 320,
      movingS: 14400,
      left: 41,
      right: 39,
      brakes: 5,
      hist: {0: 2000, 10: 1000},
    ),
    ride('d', DateTime(2025, 12, 30, 10), km: 50, movingS: 1800, left: 0, right: 0, gain: 0),
  ];

  test('totaux : ce mois, cette année, nombre, heures', () {
    final t = computeHistoryTotals(rides, now: now);
    expect(t.kmThisMonth, closeTo(230, 1e-9));
    expect(t.kmThisYear, closeTo(550, 1e-9));
    expect(t.rideCount, 4);
    expect(t.totalKm, closeTo(600, 1e-9));
    expect(t.movingTime, const Duration(seconds: 7200 + 3600 + 14400 + 1800));
    expect(t.hours, closeTo(7.5, 1e-9));
  });

  test('regroupement par mois, le plus récent d’abord', () {
    final shuffled = [rides[2], rides[0], rides[3], rides[1]];
    final g = groupRidesByMonth(shuffled);
    expect(g.map((m) => m.month), [DateTime(2026, 10), DateTime(2026, 8), DateTime(2025, 12)]);
    expect(g.first.rides.map((r) => r.id), ['a', 'b']);
    expect(g.first.totalKm, closeTo(230, 1e-9));
    expect(groupRidesByMonth(const []), isEmpty);
  });

  test('stats globales : records et moyennes', () {
    final s = computeGlobalStats(rides, now: now);
    expect(s.rideCount, 4);
    expect(s.totalKm, closeTo(600, 1e-9));
    expect(s.avgSpeedKmh, closeTo(600 / 7.5, 1e-9));
    expect(s.hardBrakes, 8);
    expect(s.hardBrakesPer100Km, closeTo(8 / 600 * 100, 1e-9));
    expect(s.longest!.id, 'c');
    expect(s.mostLeaned!.id, 'a');
    expect(s.fastest!.id, 'b');
    expect(s.mostClimbing!.id, 'b');
    expect(s.elevationGainM, 2500);
    expect(s.curveCount, 40);
  });

  test('répartition des angles agrégée', () {
    final s = computeGlobalStats(rides, now: now);
    expect(s.leanHistogram, {0: 5000, 10: 2500, 30: 200});
    expect(s.leanHistogram.keys.toList(), [0, 10, 30]);
    expect(s.leanShare[0], closeTo(5000 / 7700, 1e-9));
  });

  test('km par mois sur 12 mois (mois vides inclus)', () {
    final s = computeGlobalStats(rides, now: now);
    expect(s.kmPerMonth, hasLength(12));
    expect(s.kmPerMonth.first.month, DateTime(2025, 11));
    expect(s.kmPerMonth.last.month, DateTime(2026, 10));
    expect(s.kmPerMonth.last.km, closeTo(230, 1e-9));
    expect(s.kmPerMonth[1].km, 50); // décembre 2025
    expect(s.kmPerMonth[9].km, 320); // août 2026
    expect(s.kmPerMonth[10].km, 0);
  });

  test('gauche / droite : verdict', () {
    final s = computeGlobalStats(rides, now: now);
    // moyennes des max par balade (balade d sans angle ignorée) : G 38, D 41
    expect(s.avgMaxLeanLeftDeg, closeTo(38, 1e-9));
    expect(s.avgMaxLeanRightDeg, closeTo(41, 1e-9));
    expect(s.maxLeanLeftDeg, 41);
    expect(s.maxLeanRightDeg, 44);
    expect(s.leanSide, LeanSide.right);
    expect(s.leanVerdict, 'Tu penches plus à droite !');

    final left = computeGlobalStats([ride('x', now, left: 45, right: 30)], now: now);
    expect(left.leanSide, LeanSide.left);
    final balanced = computeGlobalStats([ride('x', now, left: 40, right: 41)], now: now);
    expect(balanced.leanSide, LeanSide.balanced);
    final none = computeGlobalStats([ride('x', now, left: 0, right: 0)], now: now);
    expect(none.leanSide, LeanSide.unknown);
  });

  test('aucune balade', () {
    final s = computeGlobalStats(const [], now: now);
    expect(s.isEmpty, isTrue);
    expect(s.avgSpeedKmh, 0);
    expect(s.hardBrakesPer100Km, 0);
    expect(s.longest, isNull);
    expect(s.leanShare, isEmpty);
  });
}
