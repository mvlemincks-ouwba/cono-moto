// STUB — à implémenter par le module « Garage & essence ». Appelé après chaque balade.
import '../../data/models/garage.dart';
import '../../data/repositories.dart';

/// Messages d'entretien arrivant à échéance pour cette moto (ex : « Graissage
/// chaîne à faire (612 km depuis la dernière fois) »).
Future<List<String>> dueMaintenanceMessages(GarageRepository repo, Bike bike) async => const [];
