// STUB — à implémenter par le module « Potes ». Contrat utilisé par la carte et le HUD.
import 'package:flutter/material.dart';

import '../../core/geo.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/ride.dart';

/// Signaler un danger (gravillons, police…) à la position donnée.
Future<void> showReportSheet(BuildContext context, {required GeoPoint at}) async {}

/// Partager sa position en direct (lien web pour quelqu'un sans l'app).
Future<void> showShareLocationSheet(BuildContext context) async {}

/// Définir un point de regroupement pour un de mes groupes.
Future<void> showSetRallyPointSheet(BuildContext context, {required GeoPoint at}) async {}

/// Partager une balade planifiée avec ses potes.
Future<void> shareRouteWithFriends(BuildContext context, PlannedRoute route) async {}

/// Partager une balade enregistrée (tracé + stats) avec ses potes.
Future<void> shareRideWithFriends(BuildContext context, Ride ride) async {}
