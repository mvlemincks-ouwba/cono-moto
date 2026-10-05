import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/planned_route.dart';
import '../../services/routing/geocoder.dart';
import '../../services/routing/http_support.dart';
import '../../services/routing/route_generator.dart';
import 'generation_results_screen.dart';
import 'route_ui.dart';
import 'route_weather_card.dart';
import 'routes_providers.dart';

/// Formulaire « Générer une balade ».
class GenerateRouteScreen extends ConsumerStatefulWidget {
  const GenerateRouteScreen({super.key, this.initialStyle, this.initialLoop = true});

  final RouteStyle? initialStyle;
  final bool initialLoop;

  static Route<void> pageRoute({RouteStyle? style, bool loop = true}) => MaterialPageRoute(
    builder: (_) => GenerateRouteScreen(initialStyle: style, initialLoop: loop),
  );

  @override
  ConsumerState<GenerateRouteScreen> createState() => _GenerateRouteScreenState();
}

class _GenerateRouteScreenState extends ConsumerState<GenerateRouteScreen> {
  late RouteStyle _style = widget.initialStyle ?? RouteStyle.sinueux;
  late bool _loop = widget.initialLoop;
  double _distanceKm = 120;
  bool _fromMyPosition = true;
  Place? _startPlace;
  Place? _destPlace;
  bool _avoidHighways = true;
  bool _avoidTolls = true;
  DateTime _departure = nextFullHour();
  bool _locating = false;

  /// Vitesse moyenne indicative par style (estimation de durée).
  double get _avgKmh => switch (_style) {
    RouteStyle.sinueux || RouteStyle.cols => 50,
    RouteStyle.foret || RouteStyle.plat || RouteStyle.mixte => 58,
    RouteStyle.rapide => 75,
  };

  Future<void> _submit() async {
    GeoPoint start;
    String? startLabel;
    if (_fromMyPosition) {
      setState(() => _locating = true);
      final hub = ref.read(positionHubProvider);
      final pos = hub ?? await ref.read(locationServiceProvider).current();
      if (!mounted) return;
      setState(() => _locating = false);
      if (pos == null) {
        showCmSnack(context, 'Position introuvable : active le GPS ou choisis une adresse de départ.', error: true);
        return;
      }
      start = pos.point;
    } else {
      if (_startPlace == null) {
        showCmSnack(context, 'Choisis une adresse de départ dans la liste.', error: true);
        return;
      }
      start = _startPlace!.point;
      startLabel = _startPlace!.label;
    }
    if (!_loop && _destPlace == null) {
      showCmSnack(context, "Choisis une arrivée dans la liste.", error: true);
      return;
    }
    final request = RouteRequest(
      start: start,
      startLabel: startLabel,
      destination: _loop ? null : _destPlace!.point,
      destinationLabel: _loop ? null : _destPlace!.label,
      targetDistanceKm: _distanceKm,
      style: _style,
      avoidHighways: _avoidHighways,
      avoidTolls: _avoidTolls,
      seed: DateTime.now().millisecondsSinceEpoch & 0x3fffffff,
      departure: _departure,
    );
    await Navigator.of(context).push(GenerationResultsScreen.pageRoute(request));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle balade')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, 120),
        children: [
          Text('Qu\'est-ce qui te fait envie ?', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: CmSpacing.md),
          _StyleGrid(selected: _style, onSelected: (s) => setState(() => _style = s)),
          const SizedBox(height: CmSpacing.xl),

          _Label('Format'),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, icon: Icon(Icons.loop), label: Text('Boucle')),
              ButtonSegment(value: false, icon: Icon(Icons.alt_route), label: Text('A → B')),
            ],
            selected: {_loop},
            onSelectionChanged: (v) => setState(() => _loop = v.first),
            style: const ButtonStyle(visualDensity: VisualDensity.comfortable),
          ),
          const SizedBox(height: CmSpacing.xl),

          if (_loop) ...[
            _Label('Distance'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.lg, CmSpacing.lg, CmSpacing.sm),
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text('${_distanceKm.round()}', style: CmTheme.numbers(size: 56, color: CmColors.orange)),
                        const SizedBox(width: 6),
                        Text('km', style: CmTheme.numbers(size: 22, color: scheme.onSurfaceVariant)),
                        const SizedBox(width: CmSpacing.md),
                        Expanded(
                          child: Text(
                            '≈ ${Fmt.duration(Duration(minutes: (_distanceKm / _avgKmh * 60).round()))} de roulage',
                            textAlign: TextAlign.right,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _distanceKm,
                      min: 30,
                      max: 400,
                      divisions: 37,
                      label: '${_distanceKm.round()} km',
                      onChanged: (v) => setState(() => _distanceKm = v),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final km in const [50, 100, 150, 250])
                          ChoiceChip(
                            label: Text('$km km'),
                            selected: _distanceKm.round() == km,
                            onSelected: (_) => setState(() => _distanceKm = km.toDouble()),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: CmSpacing.xl),
          ],

          _Label('Départ'),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, icon: Icon(Icons.my_location), label: Text('Ma position')),
              ButtonSegment(value: false, icon: Icon(Icons.place_outlined), label: Text('Une adresse')),
            ],
            selected: {_fromMyPosition},
            onSelectionChanged: (v) => setState(() => _fromMyPosition = v.first),
          ),
          if (!_fromMyPosition) ...[
            const SizedBox(height: CmSpacing.sm),
            PlaceField(
              hint: 'Ville, adresse, lieu-dit…',
              icon: Icons.trip_origin,
              value: _startPlace,
              onSelected: (p) => setState(() => _startPlace = p),
            ),
          ],
          if (!_loop) ...[
            const SizedBox(height: CmSpacing.xl),
            _Label('Arrivée'),
            PlaceField(
              hint: 'Où tu vas ?',
              icon: Icons.sports_score,
              value: _destPlace,
              onSelected: (p) => setState(() => _destPlace = p),
            ),
          ],
          const SizedBox(height: CmSpacing.xl),

          _Label('Options'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: _avoidHighways,
                  onChanged: (v) => setState(() => _avoidHighways = v),
                  secondary: const Icon(Icons.add_road),
                  title: const Text('Éviter les autoroutes'),
                  subtitle: _style == RouteStyle.rapide && !_avoidHighways
                      ? const Text('Le style « Rapide » les utilisera volontiers')
                      : null,
                ),
                const Divider(indent: 16, endIndent: 16),
                SwitchListTile(
                  value: _avoidTolls,
                  onChanged: (v) => setState(() => _avoidTolls = v),
                  secondary: const Icon(Icons.toll),
                  title: const Text('Éviter les péages'),
                ),
                const Divider(indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: const Text('Heure de départ'),
                  subtitle: const Text('Pour la météo sur le parcours'),
                  trailing: Text(
                    departureLabel(_departure),
                    style: const TextStyle(fontWeight: FontWeight.w800, color: CmColors.orange),
                  ),
                  onTap: () async {
                    final d = await pickDeparture(context, _departure);
                    if (d != null && mounted) setState(() => _departure = d);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.sm, CmSpacing.lg, CmSpacing.md),
          child: FilledButton.icon(
            onPressed: _locating ? null : _submit,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(60)),
            icon: _locating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                  )
                : const Icon(Icons.two_wheeler),
            label: Text(_locating ? 'On te localise…' : 'Trouve-moi une balade', style: const TextStyle(fontSize: 18)),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: CmSpacing.sm, left: 2),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w800, letterSpacing: 1),
      ),
    );
  }
}

class _StyleGrid extends StatelessWidget {
  const _StyleGrid({required this.selected, required this.onSelected});

  final RouteStyle selected;
  final ValueChanged<RouteStyle> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, c) {
        final w = (c.maxWidth - CmSpacing.sm) / 2;
        return Wrap(
          spacing: CmSpacing.sm,
          runSpacing: CmSpacing.sm,
          children: [
            for (final s in RouteStyle.values)
              SizedBox(
                width: w,
                child: _StyleTile(style: s, selected: s == selected, onTap: () => onSelected(s), scheme: scheme),
              ),
          ],
        );
      },
    );
  }
}

class _StyleTile extends StatelessWidget {
  const _StyleTile({required this.style, required this.selected, required this.onTap, required this.scheme});

  final RouteStyle style;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final color = styleColor(style);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: selected ? color.withValues(alpha: 0.16) : scheme.surfaceContainer,
        border: Border.all(color: selected ? color : Colors.transparent, width: 2),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(CmSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: selected ? 1 : 0.16),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(style.icon, color: selected ? Colors.white : color, size: 22),
                    ),
                    const Spacer(),
                    AnimatedOpacity(
                      opacity: selected ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(Icons.check_circle, color: color, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(style.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 2),
                Text(
                  style.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.25),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Champ d'adresse avec suggestions Photon (anti-rebond 400 ms).
class PlaceField extends ConsumerStatefulWidget {
  const PlaceField({super.key, required this.onSelected, this.value, this.hint = 'Adresse', this.icon = Icons.search});

  final ValueChanged<Place?> onSelected;
  final Place? value;
  final String hint;
  final IconData icon;

  @override
  ConsumerState<PlaceField> createState() => _PlaceFieldState();
}

class _PlaceFieldState extends ConsumerState<PlaceField> {
  late final _controller = TextEditingController(text: widget.value?.label ?? '');
  Timer? _debounce;
  List<Place> _results = const [];
  bool _loading = false;
  String? _error;
  int _query = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    if (widget.value != null) widget.onSelected(null);
    _debounce?.cancel();
    if (q.trim().length < 3) {
      setState(() {
        _results = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(q));
  }

  Future<void> _search(String q) async {
    final id = ++_query;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final near = ref.read(positionHubProvider)?.point;
      final res = await ref.read(geocoderProvider).search(q, near: near);
      if (!mounted || id != _query) return;
      setState(() {
        _results = res;
        _loading = false;
        _error = res.isEmpty ? 'Aucun résultat, essaie avec la ville.' : null;
      });
    } on RoutingException catch (e) {
      if (!mounted || id != _query) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  void _pick(Place p) {
    FocusScope.of(context).unfocus();
    _controller.text = p.label;
    setState(() => _results = const []);
    widget.onSelected(p);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: (q) {
            _debounce?.cancel();
            if (q.trim().length >= 3) _search(q);
          },
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: Icon(widget.icon),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : widget.value != null
                ? const Icon(Icons.check_circle, color: CmColors.green)
                : (_controller.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _controller.clear();
                            _onChanged('');
                          },
                        )
                      : null),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(_error!, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        if (_results.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(top: 6),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final p in _results)
                  ListTile(
                    dense: true,
                    leading: Icon(p.type == 'house' || p.type == 'street' ? Icons.place_outlined : Icons.location_city),
                    title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: p.detail == null ? null : Text(p.detail!),
                    onTap: () => _pick(p),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
