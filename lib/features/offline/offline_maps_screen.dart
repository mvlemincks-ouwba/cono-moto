import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/planned_route.dart';
import 'offline_maps.dart';

/// Gestion des cartes hors-ligne (zones téléchargées pour rouler sans réseau).
class OfflineMapsScreen extends ConsumerStatefulWidget {
  const OfflineMapsScreen({super.key, this.visibleBounds});

  /// Zone actuellement affichée sur la carte (proposée au téléchargement).
  final GeoBounds? visibleBounds;

  static Route<void> route({GeoBounds? visibleBounds}) =>
      MaterialPageRoute(builder: (_) => OfflineMapsScreen(visibleBounds: visibleBounds));

  @override
  ConsumerState<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _RegionRow {
  _RegionRow(this.region, this.status);
  final ml.OfflineRegion region;
  ml.OfflineRegionStatus? status;
}

class _OfflineMapsScreenState extends ConsumerState<OfflineMapsScreen> {
  List<_RegionRow> _regions = [];
  bool _loading = true;
  final Map<String, double> _downloads = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      await ml.setOfflineTileCountLimit(200000);
      final regions = await ml.getListOfRegions();
      final rows = <_RegionRow>[];
      for (final r in regions) {
        ml.OfflineRegionStatus? st;
        try {
          st = await ml.getOfflineRegionStatus(r.id);
        } catch (_) {}
        rows.add(_RegionRow(r, st));
      }
      if (mounted) setState(() => _regions = rows);
    } catch (e) {
      if (mounted) showCmSnack(context, 'Impossible de lire les cartes hors-ligne : $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download(String name, GeoBounds b) async {
    final mb = OfflineTiles.estimatedMb(b);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Télécharger « $name » ?'),
        content: Text(
          'Environ ${mb.toStringAsFixed(0)} Mo (${OfflineTiles.tileCount(b)} tuiles, zooms 6 à 14).\n'
          'Idéalement en Wi-Fi.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Télécharger')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final styleUrl = ref.read(settingsProvider).mapStyle.resolve(Theme.of(context).brightness);
    setState(() => _downloads[name] = 0);
    try {
      await ml.downloadOfflineRegion(
        ml.OfflineRegionDefinition(
          bounds: ml.LatLngBounds(
            southwest: ml.LatLng(b.south, b.west),
            northeast: ml.LatLng(b.north, b.east),
          ),
          mapStyleUrl: styleUrl,
          minZoom: OfflineTiles.minZoom,
          maxZoom: OfflineTiles.maxZoom,
        ),
        metadata: {'name': name, 'createdAt': DateTime.now().toIso8601String()},
        onEvent: (event) {
          if (!mounted) return;
          if (event is ml.InProgress) {
            setState(() => _downloads[name] = event.progress / 100);
          } else if (event is ml.Success) {
            setState(() => _downloads.remove(name));
            showCmSnack(context, '« $name » est dispo hors-ligne 👌');
            _reload();
          } else if (event is ml.Error) {
            setState(() => _downloads.remove(name));
            showCmSnack(context, 'Téléchargement interrompu : ${event.cause.message}', error: true);
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() => _downloads.remove(name));
        showCmSnack(context, 'Téléchargement impossible : $e', error: true);
      }
    }
  }

  Future<void> _delete(_RegionRow row) async {
    await ml.deleteOfflineRegion(row.region.id);
    await _reload();
  }

  Future<void> _aroundMe(double radiusKm) async {
    final me = ref.read(positionHubProvider)?.point ?? (await ref.read(locationServiceProvider).current())?.point;
    if (me == null) {
      if (mounted) showCmSnack(context, 'Position introuvable : active la localisation.', error: true);
      return;
    }
    await _download('Autour de moi (${radiusKm.round()} km)', GeoBounds.around(me, radiusKm * 1000));
  }

  Future<void> _forRoute() async {
    final routes = await ref.read(routeRepositoryProvider).list();
    if (!mounted) return;
    if (routes.isEmpty) {
      showCmSnack(context, 'Aucune balade enregistrée pour le moment.');
      return;
    }
    final picked = await showModalBottomSheet<PlannedRoute>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Quelle balade ?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            for (final r in routes)
              ListTile(
                leading: Icon(r.style.icon, color: CmColors.orange),
                title: Text(r.name),
                subtitle: Text(Fmt.distance(r.distanceM)),
                onTap: () => Navigator.pop(ctx, r),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final b = OfflineTiles.forRoute(picked.points);
    if (b != null) await _download(picked.name, b);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Cartes hors-ligne')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Les petites routes passent souvent en zone blanche. Télécharge la carte à l\'avance '
              'pour garder le fond de carte, ta trace et ton itinéraire même sans réseau.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          const SectionHeader('Télécharger'),
          if (widget.visibleBounds != null)
            _ActionTile(
              icon: Icons.crop_free,
              title: 'La zone affichée sur la carte',
              subtitle: '≈ ${OfflineTiles.estimatedMb(widget.visibleBounds!).toStringAsFixed(0)} Mo',
              onTap: () => _download('Zone du ${Fmt.date(DateTime.now())}', widget.visibleBounds!),
            ),
          _ActionTile(
            icon: Icons.my_location,
            title: 'Autour de moi · 30 km',
            subtitle: 'Pour une sortie dans le coin',
            onTap: () => _aroundMe(30),
          ),
          _ActionTile(
            icon: Icons.travel_explore,
            title: 'Autour de moi · 80 km',
            subtitle: 'Pour la journée',
            onTap: () => _aroundMe(80),
          ),
          _ActionTile(
            icon: Icons.route,
            title: 'Le long d\'une balade planifiée',
            subtitle: 'Couloir de 5 km autour du tracé',
            onTap: _forRoute,
          ),
          for (final e in _downloads.entries)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Téléchargement : ${e.key}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(value: e.value <= 0 ? null : e.value.clamp(0, 1)),
                      const SizedBox(height: 6),
                      Text('${(e.value * 100).clamp(0, 100).toStringAsFixed(0)} %'),
                    ],
                  ),
                ),
              ),
            ),
          const SectionHeader('Zones téléchargées'),
          if (_loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_regions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Aucune zone pour l\'instant.', style: TextStyle(color: scheme.onSurfaceVariant)),
            )
          else
            for (final row in _regions)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.offline_pin, color: CmColors.green),
                    title: Text('${row.region.metadata['name'] ?? 'Zone ${row.region.id}'}'),
                    subtitle: Text(_statusText(row.status)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Supprimer',
                      onPressed: () => _delete(row),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  String _statusText(ml.OfflineRegionStatus? s) {
    if (s == null) return 'État inconnu';
    final mb = s.completedResourceSize / (1024 * 1024);
    if (s.isComplete) return 'Complète · ${mb.toStringAsFixed(0)} Mo';
    return 'Incomplète (${(s.downloadProgress).toStringAsFixed(0)} %) · ${mb.toStringAsFixed(0)} Mo';
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        child: ListTile(
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: CmColors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: CmColors.orange),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.download_rounded),
          onTap: onTap,
        ),
      ),
    );
  }
}
