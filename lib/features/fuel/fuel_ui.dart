// STUB — à implémenter par le module « Garage & essence ». Contrat utilisé ailleurs.
import 'package:flutter/material.dart';

import '../../core/geo.dart';
import '../../data/models/garage.dart';
import '../../data/models/shared.dart';

/// Liste des stations proches (ou le long d'un itinéraire) triées par prix/distance.
Future<void> showFuelStationsSheet(
  BuildContext context, {
  GeoPoint? near,
  List<GeoPoint>? alongRoute,
}) async {}

/// Saisie d'un plein (pré-rempli avec la station et son prix du moment).
Future<FuelEntry?> showFuelEntryForm(
  BuildContext context, {
  String? rideId,
  FuelStation? station,
}) async =>
    null;
