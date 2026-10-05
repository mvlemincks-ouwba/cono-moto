import 'package:flutter/material.dart';

import '../../core/geo.dart';
import '../../data/models/garage.dart';
import '../../data/models/shared.dart';
import 'fuel_entry_form.dart';
import 'fuel_stations_sheet.dart';

export 'fuel_entry_form.dart' show FuelEntryForm;
export 'fuel_stations_sheet.dart' show FuelStationsSheet;

/// Liste des stations proches (ou le long d'un itinéraire) triées par prix/distance.
///
/// - [near] : point de recherche (sinon la position du motard) ;
/// - [alongRoute] : itinéraire (stations à moins de 3 km, détour affiché).
Future<void> showFuelStationsSheet(BuildContext context, {GeoPoint? near, List<GeoPoint>? alongRoute}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.94,
      child: FuelStationsSheet(near: near, alongRoute: alongRoute),
    ),
  );
}

/// Saisie d'un plein (pré-rempli avec la station et son prix du moment).
/// Retourne le plein enregistré, ou null si annulé.
Future<FuelEntry?> showFuelEntryForm(
  BuildContext context, {
  String? rideId,
  FuelStation? station,
  String? bikeId,
  DateTime? date,
}) => showFuelEntrySheet(context, rideId: rideId, station: station, bikeId: bikeId, date: date);
