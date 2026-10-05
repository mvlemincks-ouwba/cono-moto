import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/theme.dart';
import '../../services/routing/geocoder.dart';
import '../../services/routing/http_support.dart';
import '../home/home_shell.dart';
import '../routes/routes_providers.dart';
import 'destination_preview_screen.dart';
import 'recent_destinations.dart';

/// « Où on va ? » : recherche d'une adresse ou d'un lieu (Photon, biaisée
/// autour de ma position), destinations récentes, raccourci vers les balades.
class WhereToScreen extends ConsumerStatefulWidget {
  const WhereToScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const WhereToScreen());

  @override
  ConsumerState<WhereToScreen> createState() => _WhereToScreenState();
}

class _WhereToScreenState extends ConsumerState<WhereToScreen> {
  static const _debounce = Duration(milliseconds: 350);

  final _text = TextEditingController();
  Timer? _timer;
  int _searchId = 0;
  String _query = '';
  bool _loading = false;
  String? _error;
  List<Place> _results = const [];

  @override
  void dispose() {
    _timer?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _timer?.cancel();
    final q = value.trim();
    setState(() {
      _query = q;
      if (q.length < 3) {
        _searchId++;
        _results = const [];
        _error = null;
        _loading = false;
      }
    });
    if (q.length >= 3) _timer = Timer(_debounce, () => _search(q));
  }

  Future<void> _search(String q) async {
    _timer?.cancel();
    if (q.trim().length < 3) return;
    final id = ++_searchId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final near = ref.read(positionHubProvider)?.point;
      final results = await ref.read(geocoderProvider).search(q, near: near, limit: 8);
      if (!mounted || id != _searchId) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } on RoutingException catch (e) {
      if (!mounted || id != _searchId) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || id != _searchId) return;
      setState(() {
        _error = 'Recherche impossible pour le moment.';
        _loading = false;
      });
    }
  }

  void _choose(Place p) {
    FocusScope.of(context).unfocus();
    ref.read(recentDestinationsProvider.notifier).add(p);
    Navigator.of(context).push(DestinationPreviewScreen.route(p));
  }

  void _openSavedRoutes() {
    final tabs = ref.read(homeTabProvider.notifier);
    Navigator.of(context).popUntil((r) => r.isFirst);
    tabs.select(HomeTabs.routes);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final me = ref.watch(positionHubProvider.select((p) => p?.point));
    final recents = ref.watch(recentDestinationsProvider);
    final searching = _query.length >= 3;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        toolbarHeight: 72,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            controller: _text,
            autofocus: true,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              hintText: 'Adresse, ville, lieu…',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Effacer',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _text.clear();
                        _onChanged('');
                      },
                    ),
            ),
            onChanged: _onChanged,
            onSubmitted: _search,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 3),
          if (!searching) ...[
            _ShortcutTile(
              icon: Icons.explore_rounded,
              color: CmColors.orange,
              title: 'Mes balades à faire',
              subtitle: 'Boucles et itinéraires enregistrés',
              onTap: _openSavedRoutes,
            ),
            const SizedBox(height: 12),
            if (recents.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Tape une adresse, une ville ou un lieu (col, resto, station…).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 0, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Récents',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    TextButton(
                      onPressed: () => ref.read(recentDestinationsProvider.notifier).clear(),
                      child: const Text('Tout effacer'),
                    ),
                  ],
                ),
              ),
              for (final r in recents)
                _PlaceTile(
                  icon: Icons.history_rounded,
                  title: r.name,
                  subtitle: _subtitle(r.detail, me, r.point),
                  onTap: () => _choose(r.toPlace()),
                  onRemove: () => ref.read(recentDestinationsProvider.notifier).remove(r),
                ),
            ],
          ] else ...[
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.wifi_off_rounded, color: CmColors.amber),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_error!)),
                    TextButton(onPressed: () => _search(_query), child: const Text('Réessayer')),
                  ],
                ),
              ),
            for (final p in _results)
              _PlaceTile(
                icon: _iconFor(p.type),
                title: p.name,
                subtitle: _subtitle(p.detail, me, p.point),
                onTap: () => _choose(p),
              ),
            if (!_loading && _error == null && _results.isEmpty && _searchId > 0)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Rien trouvé pour « $_query ». Essaie avec la ville.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String? _subtitle(String? detail, GeoPoint? me, GeoPoint at) {
    final dist = me == null ? null : Fmt.distance(Geo.distance(me, at));
    final parts = [?detail, if (dist != null) 'à $dist'];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static IconData _iconFor(String? type) => switch (type) {
    'city' || 'town' || 'village' || 'district' || 'locality' => Icons.location_city_rounded,
    'street' => Icons.add_road_rounded,
    'house' => Icons.home_rounded,
    _ => Icons.place_rounded,
  };
}

class _ShortcutTile extends StatelessWidget {
  const _ShortcutTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(CmSpacing.radius),
      child: ListTile(
        minTileHeight: 72,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CmSpacing.radius)),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: color.withValues(alpha: 0.16),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({required this.icon, required this.title, required this.onTap, this.subtitle, this.onRemove});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 64,
      leading: Icon(icon, color: CmColors.orange, size: 28),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: subtitle == null ? null : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: onRemove == null
          ? null
          : IconButton(tooltip: 'Retirer', icon: const Icon(Icons.close_rounded, size: 20), onPressed: onRemove),
      onTap: onTap,
    );
  }
}
