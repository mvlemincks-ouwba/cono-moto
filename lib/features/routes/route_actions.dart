import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/providers.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/planned_route.dart';
import '../../services/routing/gpx.dart';
import '../../services/routing/http_support.dart';
import '../../services/routing/route_scoring.dart';
import '../../services/routing/valhalla_client.dart';
import '../ride/ride_controller.dart';
import '../ride/ride_screen.dart';
import 'route_detail_screen.dart';
import 'routes_providers.dart';

/// « C'est parti » : itinéraire actif + démarrage de l'enregistrement + HUD.
Future<void> startRideOnRoute(BuildContext context, WidgetRef ref, PlannedRoute route) async {
  final navigator = Navigator.of(context);
  final ride = ref.read(rideControllerProvider);
  ref.read(activeRouteProvider.notifier).set(route);
  if (ride.isActive) {
    showCmSnack(context, 'Itinéraire chargé dans ta balade en cours. Bonne route !');
    await navigator.push(RideScreen.route());
    return;
  }
  final ok = await ref.read(rideControllerProvider.notifier).start(route: route);
  if (!context.mounted) return;
  if (!ok) {
    showCmSnack(context, "Impossible de démarrer la balade : vérifie que le GPS est activé et autorisé.", error: true);
    return;
  }
  await navigator.push(RideScreen.route());
}

/// Enregistre une balade dans « Mes balades ».
Future<void> saveRoute(BuildContext context, WidgetRef ref, PlannedRoute route, {bool quiet = false}) async {
  await ref.read(routeRepositoryProvider).upsert(route);
  if (!quiet && context.mounted) showCmSnack(context, '« ${route.name} » rangée dans tes balades à faire.');
}

/// Partage le fichier GPX d'une balade (fichier temporaire + feuille de partage).
Future<void> shareRouteGpx(BuildContext context, PlannedRoute route) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  try {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${gpxFileName(route.name)}');
    await file.writeAsString(buildRouteGpx(route), flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/gpx+xml', name: gpxFileName(route.name))],
        subject: route.name,
        text: '${route.name} · ${(route.distanceM / 1000).round()} km — trace GPX pour ton GPS ou ton appli moto.',
        sharePositionOrigin: origin,
      ),
    );
  } catch (e) {
    if (context.mounted) showCmSnack(context, "Export GPX impossible : $e", error: true);
  }
}

/// Recalcule une balade « éparse » (GPX à points de passage) en suivant les routes.
Future<PlannedRoute> rerouteAlongRoads(WidgetRef ref, PlannedRoute route) async {
  final via = route.waypoints.length >= 2 ? route.waypoints : route.points;
  final v = await ref.read(valhallaClientProvider).routeThrough(via, costing: MotorcycleCosting.forStyle(route.style));
  return PlannedRoute(
    id: route.id,
    name: route.name,
    createdAt: route.createdAt,
    points: v.points,
    style: route.style,
    source: route.source,
    waypoints: via,
    distanceM: v.distanceM,
    durationS: v.durationS,
    curvatureScore: RouteScoring.curvatureScore(v.points),
    elevationGainM: route.elevationGainM,
    maneuvers: v.maneuvers,
    description: route.description,
    author: route.author,
    favorite: route.favorite,
  );
}

/// Choix d'un fichier GPX, import, recalcul éventuel, enregistrement puis
/// ouverture du détail.
Future<void> importGpxFlow(BuildContext context, WidgetRef ref) async {
  final navigator = Navigator.of(context);
  PlatformFile? file;
  try {
    file = await FilePicker.pickFile(type: FileType.any, dialogTitle: 'Choisis un fichier GPX');
  } catch (e) {
    if (context.mounted) showCmSnack(context, "Impossible d'ouvrir le sélecteur de fichiers.", error: true);
    return;
  }
  if (file == null || !context.mounted) return;

  final size = file.lengthSync() ?? await file.length();
  if (size != null && size > 30 * 1024 * 1024) {
    if (context.mounted) showCmSnack(context, 'Fichier trop lourd (30 Mo max).', error: true);
    return;
  }

  GpxImport imported;
  try {
    final bytes = await file.readAsBytes();
    final name = file.name;
    final text = utf8.decode(bytes, allowMalformed: true);
    imported = await _parseInBackground(text, name);
  } on GpxFormatException catch (e) {
    if (context.mounted) showCmSnack(context, e.message, error: true);
    return;
  } catch (e) {
    if (context.mounted) showCmSnack(context, "Lecture du fichier impossible.", error: true);
    return;
  }
  if (!context.mounted) return;

  var route = imported.route;
  if (imported.sparse) {
    final reroute = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.alt_route),
        title: const Text('Suivre les routes ?'),
        content: Text(
          'Ce GPX ne contient que ${route.points.length} points de passage, reliés en ligne droite. '
          'On recalcule le trajet en suivant les routes ?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Garder tel quel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Recalculer')),
        ],
      ),
    );
    if (!context.mounted) return;
    if (reroute == true) {
      showCmSnack(context, 'Calcul du trajet en cours…');
      try {
        route = await rerouteAlongRoads(ref, route);
      } on RoutingException catch (e) {
        if (context.mounted) showCmSnack(context, '${e.message} Balade gardée telle quelle.', error: true);
      }
    }
  }
  await ref.read(routeRepositoryProvider).upsert(route);
  if (!context.mounted) return;
  showCmSnack(context, '« ${route.name} » importée (${(route.distanceM / 1000).round()} km).');
  await navigator.push(RouteDetailScreen.pageRoute(route));
}

/// Analyse hors du fil de l'interface (gros fichiers). Fonction de premier
/// niveau : la fermeture n'embarque que le texte et le nom.
Future<GpxImport> _parseInBackground(String text, String name) => Isolate.run(() => importGpx(text, fileName: name));

/// Vrai si la balade vient d'un GPX épars (lignes droites entre points).
bool isSparseRoute(PlannedRoute r) {
  if (r.points.length < 2 || r.maneuvers.isNotEmpty) return false;
  final spacing = r.distanceM / (r.points.length - 1);
  return r.source == RouteSource.gpx && spacing > sparseSpacingM;
}

/// Vrai si « Suivre les routes » a un sens : GPX épars, ou balade refaite
/// restée sans consignes de virage (recalcul impossible hors réseau).
bool canFollowRoads(PlannedRoute r) =>
    isSparseRoute(r) || (r.source == RouteSource.recorded && r.maneuvers.isEmpty && r.points.length >= 2);
