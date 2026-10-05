import '../../data/models/garage.dart';
import '../../data/repositories.dart';
import 'maintenance.dart';

/// Messages d'entretien arrivant à échéance pour cette moto (ex : « Graissage
/// chaîne à faire (612 km depuis la dernière fois) »), le plus urgent d'abord.
Future<List<String>> dueMaintenanceMessages(GarageRepository repo, Bike bike, {DateTime? now}) async {
  final items = await repo.maintenanceItems(bike.id);
  // Le compteur peut avoir bougé depuis que [bike] a été lu (fin de balade).
  final fresh = await repo.bike(bike.id) ?? bike;
  final states = evaluateAllMaintenance(items, odometerKm: fresh.odometerKm, now: now ?? DateTime.now());
  return [
    for (final s in states)
      if (maintenanceMessage(s) case final String m) m,
  ];
}
