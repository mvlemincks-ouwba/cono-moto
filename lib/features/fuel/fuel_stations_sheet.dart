import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/map/cm_map.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/garage.dart';
import '../../data/models/shared.dart';
import '../../services/fuel/fuel_price_client.dart';
import 'fuel_entry_form.dart';
import 'fuel_logic.dart';
import 'fuel_providers.dart';
import 'navigation_links.dart';

final _tagPrice = NumberFormat('0.000', 'fr_FR');

/// Contenu de la feuille « stations-service » (autour de moi ou sur le trajet).
class FuelStationsSheet extends ConsumerStatefulWidget {
  const FuelStationsSheet({super.key, this.near, this.alongRoute, this.initialShowMap = true});

  final GeoPoint? near;
  final List<GeoPoint>? alongRoute;

  /// Carte compacte affichée à l'ouverture.
  final bool initialShowMap;

  @override
  ConsumerState<FuelStationsSheet> createState() => _FuelStationsSheetState();
}

class _FuelStationsSheetState extends ConsumerState<FuelStationsSheet> {
  late FuelType _fuel;
  late StationSort _sort;
  late bool _showMap = widget.initialShowMap;
  GeoPoint? _origin;
  bool _locating = false;
  bool _locationFailed = false;
  String? _selectedId;
  final Map<String, GlobalKey> _cardKeys = {};

  /// Position du motard le long de l'itinéraire (si [FuelStationsSheet.near] est fourni).
  double? _riderAlongM;

  /// Clé de cache de l'itinéraire (calculée une fois : simplifier une longue trace coûte).
  String? _routeKey;

  bool get _routeMode => (widget.alongRoute?.length ?? 0) >= 2;

  @override
  void initState() {
    super.initState();
    _fuel = ref.read(settingsProvider).fuelType;
    _sort = StationSort.price;
    if (_routeMode) {
      _routeKey = routeStationsKey(widget.alongRoute!);
      final near = widget.near;
      if (near != null) {
        final proj = Geo.project(near, widget.alongRoute!);
        // Seulement si le motard est bien sur (ou près de) l'itinéraire.
        if (proj != null && proj.distanceFromLineM < 5000) _riderAlongM = proj.distanceAlongM;
      }
    } else {
      _origin = widget.near ?? ref.read(positionHubProvider)?.point;
      if (_origin == null) _resolveOrigin();
    }
  }

  Future<void> _resolveOrigin() async {
    final known = widget.near ?? ref.read(positionHubProvider)?.point;
    if (known != null) {
      setState(() {
        _origin = known;
        _locationFailed = false;
      });
      return;
    }
    setState(() {
      _locating = true;
      _locationFailed = false;
    });
    final pos = await ref.read(locationServiceProvider).current();
    if (!mounted) return;
    setState(() {
      _locating = false;
      _origin = pos?.point;
      _locationFailed = pos == null;
    });
  }

  void _refresh() {
    ref.read(fuelPriceClientProvider).clearCache();
    if (_routeMode) {
      ref.invalidate(stationsAlongRouteProvider(_routeKey!));
    } else if (_origin != null) {
      ref.invalidate(stationsAroundProvider(roundForStationQuery(_origin!)));
    }
  }

  /// Stations chargées, converties en [StationEntry].
  AsyncValue<List<StationEntry>> _entries() {
    if (_routeMode) {
      final rider = _riderAlongM;
      return ref
          .watch(stationsAlongRouteProvider(_routeKey!))
          .whenData(
            (list) => [
              for (final r in list)
                // Devant le motard seulement (on tolère 500 m derrière).
                if (rider == null || r.distanceAlongM >= rider - 500)
                  StationEntry(
                    r.station,
                    distanceAlongM: rider == null ? r.distanceAlongM : r.distanceAlongM - rider,
                    offRouteM: r.offRouteM,
                    alongFromRider: rider != null,
                  ),
            ],
          );
    }
    final origin = _origin;
    if (origin == null) return const AsyncLoading();
    return ref
        .watch(stationsAroundProvider(roundForStationQuery(origin)))
        .whenData(
          (list) => [
            // Distances recalculées depuis la vraie position (la requête est arrondie).
            for (final s in list) StationEntry(s.withDistance(Geo.distance(origin, s.location))),
          ],
        );
  }

  void _selectStation(String id) {
    setState(() => _selectedId = id);
    final ctx = _cardKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350), alignment: 0.1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final data = _entries();
    final bike = ref.watch(defaultBikeProvider);
    final all = data.value ?? const <StationEntry>[];
    final withFuel = all.where((e) => e.station.priceFor(_fuel) != null).toList();
    final sorted = sortStations(withFuel, _fuel, _sort);
    final summary = summarizePrices(withFuel, _fuel, now: now);
    final missing = all.length - withFuel.length;

    final title = _routeMode ? 'Essence sur ton trajet' : 'Essence autour de toi';
    final subtitle = data.isLoading && all.isEmpty
        ? 'Recherche des prix du moment…'
        : _routeMode
        ? '${withFuel.length} station${withFuel.length > 1 ? 's' : ''} à moins de 3 km du trajet'
              '${_riderAlongM != null ? ', devant toi' : ''}'
        : '${withFuel.length} station${withFuel.length > 1 ? 's' : ''} dans un rayon de 10 km';

    return Column(
      children: [
        // En-tête.
        Padding(
          padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.sm, CmSpacing.sm),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: CmColors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.local_gas_station_rounded, color: CmColors.orange),
              ),
              const SizedBox(width: CmSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.headlineSmall),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _showMap ? 'Masquer la carte' : 'Afficher la carte',
                onPressed: () => setState(() => _showMap = !_showMap),
                icon: Icon(_showMap ? Icons.map_rounded : Icons.map_outlined),
              ),
              IconButton(tooltip: 'Actualiser', onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
            ],
          ),
        ),
        // Carburants.
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
            children: [
              for (final f in FuelType.values)
                Padding(
                  padding: const EdgeInsets.only(right: CmSpacing.sm),
                  child: ChoiceChip(
                    label: Text(f.label),
                    selected: f == _fuel,
                    onSelected: (_) => setState(() => _fuel = f),
                    avatar: f == bike?.fuelType ? const Icon(Icons.two_wheeler, size: 16) : null,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: CmSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<StationSort>(
              showSelectedIcon: false,
              segments: [
                for (final s in StationSort.values)
                  if (s != StationSort.route || _routeMode)
                    ButtonSegment(
                      value: s,
                      label: Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                      // Trois segments sur un petit écran : pas de place pour les icônes.
                      icon: _routeMode
                          ? null
                          : Icon(switch (s) {
                              StationSort.price => Icons.euro_rounded,
                              StationSort.distance => Icons.near_me_rounded,
                              StationSort.route => Icons.route_rounded,
                            }),
                    ),
              ],
              selected: {_sort},
              onSelectionChanged: (s) => setState(() => _sort = s.first),
            ),
          ),
        ),
        const SizedBox(height: CmSpacing.sm),
        Expanded(child: _buildBody(context, data, sorted, summary, missing, bike)),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    AsyncValue<List<StationEntry>> data,
    List<StationEntry> sorted,
    PriceSummary? summary,
    int missing,
    Bike? bike,
  ) {
    if (!_routeMode && _origin == null) {
      if (_locating) return const _LoadingList(message: 'On cherche où tu es…');
      if (_locationFailed) {
        return EmptyState(
          icon: Icons.location_off_rounded,
          title: 'Impossible de te localiser',
          message: 'Active la localisation pour trouver les stations autour de toi.',
          action: FilledButton.icon(
            onPressed: _resolveOrigin,
            icon: const Icon(Icons.my_location),
            label: const Text('Réessayer'),
          ),
        );
      }
      return const _LoadingList(message: 'On cherche où tu es…');
    }
    if (data.hasError && !data.hasValue) {
      final e = data.error;
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Prix indisponibles',
        message: e is FuelPriceException ? e.message : 'Impossible de récupérer les prix pour le moment.',
        action: FilledButton.icon(
          onPressed: _refresh,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Réessayer'),
        ),
      );
    }
    if (!data.hasValue) return const _LoadingList(message: 'Recherche des prix du moment…');

    final now = DateTime.now();
    final cheapest = summary?.cheapest;
    final tank = bike?.tankLiters ?? 15;

    return CustomScrollView(
      slivers: [
        if (_showMap && sorted.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.xs, CmSpacing.lg, CmSpacing.md),
              child: _StationsMap(
                entries: sorted,
                fuel: _fuel,
                cheapestId: cheapest?.station.id,
                selectedId: _selectedId,
                origin: _origin,
                route: widget.alongRoute,
                averagePrice: summary?.average,
                onSelect: _selectStation,
              ),
            ),
          ),
        if (sorted.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.local_gas_station_outlined,
              title: 'Aucune station avec du ${_fuel.label}',
              message: missing > 0
                  ? '$missing station${missing > 1 ? 's' : ''} dans le coin, mais sans ${_fuel.label} '
                        '(ou en rupture). Essaie un autre carburant.'
                  : _routeMode
                  ? 'Rien trouvé à moins de 3 km de ton trajet.'
                  : 'Rien trouvé dans un rayon de 10 km.',
            ),
          )
        else ...[
          if (cheapest != null && summary != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, CmSpacing.md),
                child: _CheapestCard(
                  entry: cheapest,
                  fuel: _fuel,
                  summary: summary,
                  tankLiters: tank,
                  onFilled: () => _fillHere(cheapest.station),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, CmSpacing.xl),
            sliver: SliverList.separated(
              itemCount: sorted.length + (missing > 0 ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: CmSpacing.sm),
              itemBuilder: (context, i) {
                if (i == sorted.length) {
                  return Padding(
                    padding: const EdgeInsets.all(CmSpacing.md),
                    child: Text(
                      '+ $missing station${missing > 1 ? 's' : ''} sans ${_fuel.label} dans la zone',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  );
                }
                final e = sorted[i];
                final key = _cardKeys.putIfAbsent(e.station.id, GlobalKey.new);
                return _StationCard(
                  key: key,
                  entry: e,
                  fuel: _fuel,
                  average: summary?.average,
                  isCheapest: e.station.id == cheapest?.station.id,
                  selected: e.station.id == _selectedId,
                  now: now,
                  onFilled: () => _fillHere(e.station),
                  onTap: () => setState(() => _selectedId = e.station.id),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _fillHere(FuelStation station) async {
    await showFuelEntrySheet(context, station: station);
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(CmSpacing.lg),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Row(
          children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4)),
            const SizedBox(width: CmSpacing.md),
            Flexible(
              child: Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
          ],
        ),
        const SizedBox(height: CmSpacing.lg),
        for (var i = 0; i < 5; i++)
          Container(
            height: 92,
            margin: const EdgeInsets.only(bottom: CmSpacing.sm),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer.withValues(alpha: 1 - i * 0.15),
              borderRadius: BorderRadius.circular(CmSpacing.radius),
            ),
          ),
      ],
    );
  }
}

/// Mini-carte des stations avec étiquettes de prix.
class _StationsMap extends StatefulWidget {
  const _StationsMap({
    required this.entries,
    required this.fuel,
    required this.cheapestId,
    required this.selectedId,
    required this.origin,
    required this.route,
    required this.averagePrice,
    required this.onSelect,
  });

  final List<StationEntry> entries;
  final FuelType fuel;
  final String? cheapestId;
  final String? selectedId;
  final GeoPoint? origin;
  final List<GeoPoint>? route;
  final double? averagePrice;
  final ValueChanged<String> onSelect;

  @override
  State<_StationsMap> createState() => _StationsMapState();
}

class _StationsMapState extends State<_StationsMap> {
  List<MapMarker> _markers = const [];
  List<MapLine> _lines = const [];
  CmMapController? _controller;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  String _signature = '';

  /// Empreinte du contenu : la carte ne se resynchronise que s'il change
  /// (CmMap compare les listes par identité).
  String _sig() => [
    widget.fuel.name,
    widget.cheapestId,
    widget.selectedId,
    widget.route?.length,
    for (final e in widget.entries) '${e.station.id}:${e.station.priceFor(widget.fuel)}',
  ].join('|');

  @override
  void didUpdateWidget(covariant _StationsMap old) {
    super.didUpdateWidget(old);
    final changedSet = old.fuel != widget.fuel || old.entries.length != widget.entries.length;
    if (_sig() != _signature) _rebuild();
    if (changedSet) {
      _fit();
    } else if (widget.selectedId != null && widget.selectedId != old.selectedId) {
      final e = widget.entries.where((e) => e.station.id == widget.selectedId).firstOrNull;
      if (e != null) _controller?.moveTo(e.station.location, zoom: 14);
    }
  }

  void _rebuild() {
    _signature = _sig();
    final avg = widget.averagePrice;
    // Au plus 60 étiquettes pour rester lisible : les moins chères d'abord.
    final shown = sortStations(widget.entries, widget.fuel, StationSort.price).take(60).toList();
    _markers = [
      for (final e in shown)
        () {
          final price = e.station.priceFor(widget.fuel)!;
          final stale = isPriceStale(e.station.updatedAt[widget.fuel], now: DateTime.now());
          final isCheapest = e.station.id == widget.cheapestId;
          final selected = e.station.id == widget.selectedId;
          final color = stale
              ? const Color(0xFF6B7280)
              : isCheapest
              ? CmColors.green
              : (avg != null && price <= avg ? CmColors.teal : CmColors.orange);
          return MapMarker(
            id: e.station.id,
            position: e.station.location,
            style: MarkerStyle.tag,
            text: _tagPrice.format(price),
            color: color,
            size: isCheapest || selected ? 34 : 28,
            zIndex: isCheapest ? 100 : (selected ? 90 : (avg != null ? ((avg - price) * 100).round() : 0)),
            highlighted: isCheapest || selected,
            payload: e.station.id,
          );
        }(),
    ];
    final route = widget.route;
    _lines = route != null && route.length >= 2
        ? [MapLine(id: 'route', points: route, color: CmColors.sky, width: 4, opacity: 0.9)]
        : const [];
  }

  Future<void> _fit() async {
    final c = _controller;
    if (c == null) return;
    final pts = [for (final e in widget.entries.take(40)) e.station.location, ?widget.origin];
    if (widget.route != null && widget.route!.length >= 2) {
      await c.fitPoints(widget.route!, padding: const EdgeInsets.all(28));
    } else if (pts.isNotEmpty) {
      await c.fitPoints(pts, padding: const EdgeInsets.all(36));
    }
  }

  @override
  Widget build(BuildContext context) {
    final center =
        widget.origin ??
        (widget.route?.isNotEmpty == true
            ? GeoBounds.fromPoints(widget.route!)!.center
            : widget.entries.first.station.location);
    return ClipRRect(
      borderRadius: BorderRadius.circular(CmSpacing.radius),
      child: SizedBox(
        height: 210,
        child: Stack(
          children: [
            CmMap(
              initialCenter: center,
              initialZoom: widget.route != null ? 9 : 12.5,
              markers: _markers,
              lines: _lines,
              compassEnabled: false,
              onMarkerTap: (m) => widget.onSelect(m.id),
              onCreated: (c) {
                _controller = c;
                Future<void>.delayed(const Duration(milliseconds: 600), _fit);
              },
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: MapRoundButton(icon: Icons.center_focus_strong_rounded, size: 40, onPressed: _fit),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mise en avant de la station la moins chère.
class _CheapestCard extends StatelessWidget {
  const _CheapestCard({
    required this.entry,
    required this.fuel,
    required this.summary,
    required this.tankLiters,
    required this.onFilled,
  });

  final StationEntry entry;
  final FuelType fuel;
  final PriceSummary summary;
  final double tankLiters;
  final VoidCallback onFilled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = entry.station;
    final price = s.priceFor(fuel)!;
    final perLiter = summary.savingPerLiter(price);
    final forTank = summary.savingFor(price, tankLiters);
    final savingText = summary.count < 2 || perLiter < 0.0005
        ? 'Seule station au prix du moment dans le coin.'
        : '−${Fmt.number(perLiter * 100, decimals: 1)} ct/L vs la moyenne (${Fmt.pricePerLiter(summary.average)}) · '
              '≈ ${Fmt.euros(forTank)} gagnés sur un plein de ${Fmt.number(tankLiters)} L';

    return Container(
      padding: const EdgeInsets.all(CmSpacing.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CmSpacing.radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [CmColors.green.withValues(alpha: 0.22), scheme.surfaceContainer],
        ),
        border: Border.all(color: CmColors.green.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Pill(label: 'Le moins cher', icon: Icons.emoji_events_rounded, color: CmColors.green),
          const SizedBox(height: CmSpacing.md),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(Fmt.number(price, decimals: 3), style: CmTheme.numbers(size: 52, color: scheme.onSurface)),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '€/L ${fuel.label}',
                    style: CmTheme.numbers(size: 18, weight: FontWeight.w600, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: CmSpacing.sm),
          Text(
            s.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          Text(
            [s.postalCode, s.city].where((x) => x.isNotEmpty).join(' '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: CmSpacing.sm),
          Row(
            children: [
              const Icon(Icons.savings_rounded, size: 16, color: CmColors.green),
              const SizedBox(width: 6),
              Expanded(child: Text(savingText, style: Theme.of(context).textTheme.bodySmall)),
            ],
          ),
          const SizedBox(height: CmSpacing.sm),
          _StationMeta(entry: entry, fuel: fuel, now: DateTime.now()),
          const SizedBox(height: CmSpacing.md),
          Row(
            children: [
              Expanded(child: GoThereButton(destination: s.location, filled: true)),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onFilled,
                  icon: const Icon(Icons.local_gas_station_rounded, size: 20),
                  label: const Text('Plein fait'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Distance / détour, fraîcheur, 24/24.
class _StationMeta extends StatelessWidget {
  const _StationMeta({required this.entry, required this.fuel, required this.now});

  final StationEntry entry;
  final FuelType fuel;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = entry.station;
    final updated = s.updatedAt[fuel];
    final freshness = priceFreshness(updated, now: now);
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    Widget item(IconData icon, String text, {Color? color}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color ?? scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: color == null ? muted : muted?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );

    return Wrap(
      spacing: CmSpacing.md,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (entry.onRoute) ...[
          item(
            Icons.route_rounded,
            entry.alongFromRider
                ? (entry.distanceAlongM! < 500 ? 'juste là' : 'dans ${Fmt.distance(entry.distanceAlongM!)}')
                : 'au km ${Fmt.km(entry.distanceAlongM!, decimals: 0)}',
          ),
          item(
            Icons.alt_route_rounded,
            entry.detourM! < 400 ? 'sur le trajet' : 'détour ${Fmt.distance(entry.detourM!)}',
          ),
        ] else if (s.distanceM != null)
          item(Icons.near_me_rounded, Fmt.distance(s.distanceM!)),
        switch (freshness) {
          PriceFreshness.stale => item(
            Icons.warning_amber_rounded,
            'prix du ${Fmt.date(updated!)} · à vérifier',
            color: CmColors.amber,
          ),
          PriceFreshness.unknown => item(Icons.help_outline_rounded, 'date du prix inconnue'),
          _ => item(Icons.schedule_rounded, 'maj ${Fmt.ago(updated!, now: now)}'),
        },
        if (s.open24h) item(Icons.credit_card_rounded, '24/24'),
      ],
    );
  }
}

class _StationCard extends StatelessWidget {
  const _StationCard({
    super.key,
    required this.entry,
    required this.fuel,
    required this.average,
    required this.isCheapest,
    required this.selected,
    required this.now,
    required this.onFilled,
    this.onTap,
  });

  final StationEntry entry;
  final FuelType fuel;
  final double? average;
  final bool isCheapest;
  final bool selected;
  final DateTime now;
  final VoidCallback onFilled;

  /// Toucher la carte : la station est mise en avant sur la mini-carte.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = entry.station;
    final price = s.priceFor(fuel)!;
    final delta = average == null ? null : price - average!;
    final stale = isPriceStale(s.updatedAt[fuel], now: now);
    final others = [
      for (final f in FuelType.values)
        if (f != fuel && s.priceFor(f) != null) '${f.label} ${Fmt.number(s.priceFor(f)!, decimals: 3)}',
    ];

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.md, CmSpacing.sm, CmSpacing.xs),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(CmSpacing.radius),
          border: Border.all(
            color: selected
                ? CmColors.orange
                : (isCheapest ? CmColors.green.withValues(alpha: 0.5) : Colors.transparent),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.displayName.isEmpty ? 'Station' : s.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        [s.postalCode, s.city].where((x) => x.isNotEmpty).join(' '),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      _StationMeta(entry: entry, fuel: fuel, now: now),
                    ],
                  ),
                ),
                const SizedBox(width: CmSpacing.sm),
                Padding(
                  padding: const EdgeInsets.only(right: CmSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        Fmt.number(price, decimals: 3),
                        style: CmTheme.numbers(
                          size: 32,
                          color: stale ? scheme.onSurfaceVariant : (isCheapest ? CmColors.green : scheme.onSurface),
                        ),
                      ),
                      Text(
                        '€/L',
                        style: CmTheme.numbers(size: 13, weight: FontWeight.w600, color: scheme.onSurfaceVariant),
                      ),
                      if (delta != null && delta.abs() >= 0.0005) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${delta < 0 ? '−' : '+'}${Fmt.number(delta.abs() * 100, decimals: 1)} ct',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: delta < 0 ? CmColors.green : scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (others.isNotEmpty || s.unavailable.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                [
                  ...others,
                  if (s.unavailable.isNotEmpty) 'indisponible : ${s.unavailable.map((f) => f.label).join(', ')}',
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                GoThereButton(destination: s.location),
                TextButton.icon(
                  onPressed: onFilled,
                  icon: const Icon(Icons.local_gas_station_outlined, size: 20),
                  label: const Text("J'ai fait le plein ici", overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
