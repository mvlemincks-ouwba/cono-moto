import 'package:cono_moto/data/models/garage.dart';
import 'package:cono_moto/data/repositories.dart';
import 'package:cono_moto/features/garage/maintenance.dart';
import 'package:cono_moto/features/garage/maintenance_reminders.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

final now = DateTime.utc(2026, 10, 5, 12);

MaintenanceItem item({
  MaintenanceType type = MaintenanceType.chaine,
  int? km,
  int? months,
  double? lastKm,
  DateTime? lastDate,
  String label = '',
}) => MaintenanceItem(
  id: type.name,
  bikeId: 'b',
  type: type,
  label: label,
  intervalKm: km,
  intervalMonths: months,
  lastDoneKm: lastKm,
  lastDoneDate: lastDate,
);

void main() {
  setUpAll(initTestLocale);

  group('statut kilométrique', () {
    MaintenanceState eval(double odo) => evaluateMaintenance(
      item(km: 600, lastKm: 10000, lastDate: now),
      odometerKm: odo,
      now: now,
    );

    test('ok / bientôt (<10 %) / à faire / en retard (>10 %)', () {
      expect(eval(10300).status, MaintenanceStatus.ok);
      expect(eval(10300).kmRemaining, 300);
      expect(eval(10300).progress, closeTo(0.5, 1e-9));
      expect(eval(10541).status, MaintenanceStatus.soon);
      expect(eval(10540).status, MaintenanceStatus.ok);
      expect(eval(10600).status, MaintenanceStatus.due);
      expect(eval(10660).status, MaintenanceStatus.due);
      expect(eval(10661).status, MaintenanceStatus.overdue);
      expect(eval(10661).kmRemaining, -61);
    });

    test('résumés lisibles', () {
      expect(eval(10300).summary, 'encore 300 km');
      expect(eval(10700).summary, '100 km de retard');
    });
  });

  group('statut temporel', () {
    test('vidange 12 mois / 6000 km : la durée peut primer', () {
      final s = evaluateMaintenance(
        item(type: MaintenanceType.vidange, km: 6000, months: 12, lastKm: 10000, lastDate: DateTime.utc(2025, 9, 1)),
        odometerKm: 11000,
        now: now,
      );
      expect(s.status, MaintenanceStatus.due);
      expect(s.drivenByKm, isFalse);
      expect(s.dueDate, DateTime.utc(2026, 9, 1));
      expect(s.daysRemaining, lessThan(0));
      expect(s.progress, greaterThan(1));
    });

    test('liquide de frein : bientôt puis en retard', () {
      MaintenanceStatus at(DateTime d) => evaluateMaintenance(
        item(type: MaintenanceType.liquideFrein, months: 24, lastDate: DateTime.utc(2024, 10, 20)),
        odometerKm: 0,
        now: d,
      ).status;
      expect(at(DateTime.utc(2026, 6, 1)), MaintenanceStatus.ok);
      expect(at(DateTime.utc(2026, 10, 5)), MaintenanceStatus.soon);
      expect(at(DateTime.utc(2026, 11, 1)), MaintenanceStatus.due);
      expect(at(DateTime.utc(2027, 3, 1)), MaintenanceStatus.overdue);
    });

    test('ajout de mois borné à la fin du mois', () {
      expect(addMonths(DateTime.utc(2026, 1, 31), 1), DateTime.utc(2026, 2, 28));
      expect(addMonths(DateTime.utc(2026, 11, 15), 3), DateTime.utc(2027, 2, 15));
      expect(addMonths(DateTime.utc(2026, 1, 15), -1), DateTime.utc(2025, 12, 15));
    });
  });

  test('jamais fait / sans échéance', () {
    final never = evaluateMaintenance(item(km: 600), odometerKm: 1000, now: now);
    expect(never.status, MaintenanceStatus.due);
    expect(never.neverDone, isTrue);
    expect(maintenanceMessage(never), 'Graissage chaîne à faire (jamais renseigné)');
    final free = evaluateMaintenance(
      item(type: MaintenanceType.autre, label: 'Lavage', lastKm: 0),
      odometerKm: 10,
      now: now,
    );
    expect(free.status, MaintenanceStatus.none);
    expect(maintenanceMessage(free), isNull);
  });

  test('messages de rappel', () {
    String? msg(double odo) => maintenanceMessage(
      evaluateMaintenance(
        item(km: 600, lastKm: 10000, lastDate: now),
        odometerKm: odo,
        now: now,
      ),
    );
    expect(msg(10200), isNull);
    expect(msg(10560), 'Graissage chaîne bientôt : encore 40 km');
    expect(msg(10612), 'Graissage chaîne à faire (612 km depuis la dernière fois)');
    expect(msg(10800), 'Graissage chaîne en retard (800 km depuis la dernière fois)');
  });

  test('tri : le plus urgent d’abord', () {
    final states = evaluateAllMaintenance(
      [
        item(type: MaintenanceType.pneuAvant, km: 12000, lastKm: 10000, lastDate: now),
        item(type: MaintenanceType.chaine, km: 600, lastKm: 10000, lastDate: now),
        item(type: MaintenanceType.tensionChaine, km: 1500, lastKm: 9000, lastDate: now),
      ],
      odometerKm: 10700,
      now: now,
    );
    expect(states.map((s) => s.item.type), [
      MaintenanceType.chaine, // en retard (117 %)
      MaintenanceType.tensionChaine, // en retard aussi, mais moins avancé (113 %)
      MaintenanceType.pneuAvant,
    ]);
  });

  test('éléments par défaut d’une nouvelle moto', () {
    var n = 0;
    const bike = Bike(id: 'b', name: 'MT-07', odometerKm: 12345);
    final items = defaultMaintenanceItems(bike, now: now, newId: () => 'id${n++}');
    expect(items.length, MaintenanceType.values.length - 1);
    expect(items.any((i) => i.type == MaintenanceType.autre), isFalse);
    final vidange = items.firstWhere((i) => i.type == MaintenanceType.vidange);
    expect(vidange.intervalKm, 6000);
    expect(vidange.intervalMonths, 12);
    expect(vidange.lastDoneKm, 12345);
    expect(vidange.lastDoneDate, now);
    expect(items.map((i) => i.id).toSet().length, items.length);
    final states = evaluateAllMaintenance(items, odometerKm: 12345, now: now);
    expect(states.every((s) => s.status == MaintenanceStatus.ok), isTrue);
  });

  test('« Fait aujourd’hui » et log', () {
    final i = item(km: 600, lastKm: 10000, lastDate: DateTime.utc(2026, 1, 1));
    final done = markMaintenanceDone(i, odometerKm: 10650, date: now);
    expect(done.lastDoneKm, 10650);
    expect(done.lastDoneDate, now);
    expect(evaluateMaintenance(done, odometerKm: 10650, now: now).status, MaintenanceStatus.ok);
    final log = maintenanceLogFor(i, id: 'l1', odometerKm: 10650, date: now, cost: 12.5);
    expect(log.itemId, i.id);
    expect(log.bikeId, 'b');
    expect(log.cost, 12.5);
  });

  test('édition : un intervalle peut être effacé', () {
    final i = item(type: MaintenanceType.vidange, km: 6000, months: 12, lastKm: 1, lastDate: now);
    final e = editMaintenanceItem(
      i,
      label: 'Vidange + filtre',
      intervalKm: 5000,
      intervalMonths: null,
      lastDoneKm: 2,
      lastDoneDate: now,
    );
    expect(e.intervalMonths, isNull);
    expect(e.intervalKm, 5000);
    expect(e.displayName, 'Vidange + filtre');
  });

  test('dueMaintenanceMessages lit la base et utilise le compteur à jour', () async {
    final db = await openTestDatabase();
    final repo = GarageRepository(db);
    const bike = Bike(id: 'b', name: 'MT-07', odometerKm: 10000);
    await repo.upsertBike(bike);
    await repo.upsertMaintenanceItem(item(km: 600, lastKm: 10000, lastDate: now));
    await repo.upsertMaintenanceItem(item(type: MaintenanceType.pneuArriere, km: 9000, lastKm: 10000, lastDate: now));
    expect(await dueMaintenanceMessages(repo, bike, now: now), isEmpty);
    await repo.addDistance('b', 612);
    // [bike] est périmé (10 000 km) : la fonction relit le compteur.
    expect(await dueMaintenanceMessages(repo, bike, now: now), [
      'Graissage chaîne à faire (612 km depuis la dernière fois)',
    ]);
    await db.close();
  });
}
