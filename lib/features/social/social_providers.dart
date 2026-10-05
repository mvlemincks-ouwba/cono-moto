// STUB — à implémenter par le module « Potes ». Contrat utilisé par la carte.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/planned_route.dart';
import '../../data/models/shared.dart';

/// Positions en direct des potes (hors moi).
final friendsLiveProvider = StreamProvider<List<FriendLive>>((ref) => Stream.value(const []));

/// Signalements actifs des potes (et les miens).
final roadReportsProvider = StreamProvider<List<RoadReport>>((ref) => Stream.value(const []));

/// Points de regroupement des groupes dont je fais partie.
final rallyPointsProvider = StreamProvider<List<RallyPoint>>((ref) => Stream.value(const []));

/// Balades partagées par les potes.
final friendsRoutesProvider = StreamProvider<List<PlannedRoute>>((ref) => Stream.value(const []));

/// Suis-je connecté au service entre potes (Firebase) ?
final socialSignedInProvider = Provider<bool>((ref) => false);
