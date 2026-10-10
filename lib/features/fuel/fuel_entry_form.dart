import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/garage.dart';
import '../../data/models/shared.dart';
import '../ride/ride_controller.dart';
import 'fuel_logic.dart';

/// Ouvre la saisie d'un plein dans une feuille. Retourne le plein enregistré.
Future<FuelEntry?> showFuelEntrySheet(
  BuildContext context, {
  String? rideId,
  FuelStation? station,
  String? bikeId,
  DateTime? date,
}) {
  return showModalBottomSheet<FuelEntry>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: FuelEntryForm(rideId: rideId, station: station, bikeId: bikeId, date: date),
    ),
  );
}

String _fmtInput(double v, int decimals) {
  var s = v.toStringAsFixed(decimals);
  if (decimals > 0) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s.replaceAll('.', ',');
}

/// Formulaire de saisie d'un plein (ou d'un appoint).
class FuelEntryForm extends ConsumerStatefulWidget {
  const FuelEntryForm({super.key, this.rideId, this.station, this.bikeId, this.date});

  final String? rideId;
  final FuelStation? station;
  final String? bikeId;

  /// Date par défaut (ex : plein ajouté après coup à une balade passée).
  final DateTime? date;

  @override
  ConsumerState<FuelEntryForm> createState() => _FuelEntryFormState();
}

class _FuelEntryFormState extends ConsumerState<FuelEntryForm> {
  final _liters = TextEditingController();
  final _price = TextEditingController();
  final _total = TextEditingController();
  final _odometer = TextEditingController();

  String? _bikeId;
  late FuelType _fuel;
  bool _fullTank = true;
  late DateTime _date;
  String? _rideId;
  bool _linkRide = true;
  bool _priceEdited = false;
  bool _odometerEdited = false;
  bool _syncing = false;
  bool _submitted = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final bikes = ref.read(bikesProvider).value ?? const <Bike>[];
    final bike = bikes.where((b) => b.id == widget.bikeId).firstOrNull ?? ref.read(defaultBikeProvider);
    _bikeId = bike?.id;
    _date = widget.date?.toLocal() ?? DateTime.now();
    // Plein saisi après coup : le compteur actuel ne correspond pas.
    _odometerEdited = widget.date != null && !_isToday(_date);
    _fuel = bike?.fuelType ?? ref.read(settingsProvider).fuelType;
    final ride = ref.read(rideControllerProvider);
    _rideId = widget.rideId ?? (ride.isActive ? ride.rideId : null);
    _applyStationPrice();
    _applyOdometer(bike);
    _liters.addListener(_onLitersOrPrice);
    _price.addListener(_onLitersOrPrice);
    _total.addListener(_onTotal);
  }

  @override
  void dispose() {
    _liters.dispose();
    _price.dispose();
    _total.dispose();
    _odometer.dispose();
    super.dispose();
  }

  /// Km de la balade en cours sur [bikeId] pas encore reportés sur la moto.
  double _rideKmFor(String? bikeId) {
    final ride = ref.read(rideControllerProvider);
    return bikeId != null && ride.bikeId == bikeId ? ride.uncountedKm : 0;
  }

  /// Pré-remplit le prix avec celui de la station (sauf saisie manuelle).
  /// Ne fait pas de setState : appelé depuis initState ou un setState.
  void _applyStationPrice() {
    final p = widget.station?.priceFor(_fuel) ?? widget.station?.prices[_fuel];
    if (p != null && !_priceEdited) {
      _syncing = true;
      _price.text = _fmtInput(p, 3);
      _syncing = false;
      _updateTotalText();
    }
  }

  void _updateTotalText() {
    final l = parseUserNumber(_liters.text);
    final p = parseUserNumber(_price.text);
    _syncing = true;
    _total.text = l != null && p != null && l > 0 && p > 0 ? _fmtInput(fuelTotal(l, p), 2) : '';
    _syncing = false;
  }

  void _applyOdometer(Bike? bike) {
    if (bike == null || _odometerEdited) return;
    final km = bike.odometerKm + _rideKmFor(bike.id);
    _odometer.text = km > 0 ? km.round().toString() : '';
  }

  void _onLitersOrPrice() {
    if (_syncing) return;
    _updateTotalText();
    setState(() {});
  }

  void _onTotal() {
    if (_syncing) return;
    final t = parseUserNumber(_total.text);
    final p = parseUserNumber(_price.text);
    if (t == null || p == null || p <= 0) return;
    final l = litersFromTotal(t, p);
    if (l == null) return;
    _syncing = true;
    _liters.text = _fmtInput(l, 2);
    _syncing = false;
    setState(() {});
  }

  String? get _litersError {
    final l = parseUserNumber(_liters.text);
    if (l == null) return 'Combien de litres ?';
    if (l <= 0 || l > 80) return 'Valeur improbable';
    return null;
  }

  String? get _priceError {
    final p = parseUserNumber(_price.text);
    if (p == null) return 'Prix au litre ?';
    if (p < 0.3 || p > 5) return 'Entre 0,30 et 5 €';
    return null;
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: 'Date du plein',
    );
    if (d == null || !mounted) return;
    setState(() => _date = DateTime(d.year, d.month, d.day, _date.hour, _date.minute));
  }

  Future<void> _save() async {
    setState(() => _submitted = true);
    if (_litersError != null || _priceError != null || _saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final repo = ref.read(garageRepositoryProvider);
    final station = widget.station;
    final liters = parseUserNumber(_liters.text)!;
    final price = parseUserNumber(_price.text)!;
    final odo = parseUserNumber(_odometer.text);

    final entry = FuelEntry(
      id: const Uuid().v4(),
      date: _date.toUtc(),
      liters: liters,
      pricePerLiter: price,
      bikeId: _bikeId,
      rideId: _linkRide ? _rideId : null,
      odometerKm: odo != null && odo > 0 ? odo : null,
      fullTank: _fullTank,
      stationId: station?.id,
      stationName: station == null ? '' : [station.displayName, station.city].where((s) => s.isNotEmpty).join(', '),
      fuelType: _fuel,
      lat: station?.location.lat,
      lng: station?.location.lng,
    );

    try {
      String message = 'Plein enregistré : ${Fmt.euros(entry.total)}';
      final bikeId = _bikeId;
      final bike = bikeId == null ? null : await repo.bike(bikeId);
      if (bike != null) {
        final history = await repo.fuelEntries(bikeId: bike.id);
        // Plein en route : les km déjà roulés sont reportés sur la moto
        // maintenant, et ne seront pas recomptés à l'arrêt de la balade.
        final rideKm = _rideKmFor(bike.id);
        final outcome = applyFuelEntry(
          bike: bike,
          entry: entry,
          history: history,
          now: DateTime.now(),
          rideKm: rideKm,
        );
        await repo.upsertFuel(entry);
        await repo.upsertBike(outcome.bike);
        ref.read(rideControllerProvider.notifier).markGarageKmCounted(bike.id, rideKm);
        final m = outcome.measuredL100;
        if (m != null && outcome.consumptionUpdated) {
          message = 'Plein enregistré · conso mesurée ${Fmt.number(m, decimals: 1)} L/100 km';
        } else if (m != null) {
          message = 'Plein enregistré · conso de ${Fmt.number(m, decimals: 1)} L/100 bizarre, ignorée';
        } else if (!_fullTank) {
          message = 'Appoint enregistré : ${Fmt.euros(entry.total)}';
        }
      } else {
        await repo.upsertFuel(entry);
      }
      navigator.pop(entry);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showCmSnack(context, "Impossible d'enregistrer le plein : $e", error: true);
    }
  }

  /// Les motos peuvent arriver après l'ouverture du formulaire.
  void _onBikesLoaded(List<Bike> bikes) {
    if (_bikeId != null || bikes.isEmpty) return;
    final bike =
        bikes.where((b) => b.id == widget.bikeId).firstOrNull ??
        bikes.firstWhere((b) => b.isDefault, orElse: () => bikes.first);
    setState(() {
      _bikeId = bike.id;
      _fuel = bike.fuelType;
      _applyStationPrice();
      _applyOdometer(bike);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    ref.listen<AsyncValue<List<Bike>>>(bikesProvider, (_, next) => _onBikesLoaded(next.value ?? const []));
    final bikes = ref.watch(bikesProvider).value ?? const <Bike>[];
    final bike = bikes.where((b) => b.id == _bikeId).firstOrNull;
    final station = widget.station;
    final total = parseUserNumber(_total.text);
    final estimate = bike == null ? null : litersToFill(bike, extraKm: _rideKmFor(bike.id));

    final numberKeyboard = const TextInputType.numberWithOptions(decimal: true);
    final numberFilter = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, CmSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
                    Text(_fullTank ? 'Nouveau plein' : 'Nouvel appoint', style: text.headlineSmall),
                    Text(
                      station == null
                          ? 'Saisie manuelle'
                          : [station.displayName, station.city].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.lg),

          // Moto.
          if (bikes.isEmpty)
            Container(
              padding: const EdgeInsets.all(CmSpacing.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(CmSpacing.radiusSm),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, color: scheme.onSurfaceVariant),
                  const SizedBox(width: CmSpacing.sm),
                  const Expanded(child: Text('Ajoute ta moto dans le Garage pour suivre ta conso et ton autonomie.')),
                ],
              ),
            )
          else if (bikes.length > 1)
            Wrap(
              spacing: CmSpacing.sm,
              runSpacing: CmSpacing.sm,
              children: [
                for (final b in bikes)
                  ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: b.color, radius: 7),
                    label: Text(b.name),
                    selected: b.id == _bikeId,
                    onSelected: (_) => setState(() {
                      _bikeId = b.id;
                      _fuel = b.fuelType;
                      _applyStationPrice();
                      _applyOdometer(b);
                    }),
                  ),
              ],
            ),
          if (bikes.isNotEmpty) const SizedBox(height: CmSpacing.md),

          // Carburant.
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final f in FuelType.values)
                  Padding(
                    padding: const EdgeInsets.only(right: CmSpacing.sm),
                    child: ChoiceChip(
                      label: Text(
                        station?.priceFor(f) != null
                            ? '${f.label} · ${Fmt.number(station!.priceFor(f)!, decimals: 3)}'
                            : f.label,
                      ),
                      selected: f == _fuel,
                      onSelected: (_) => setState(() {
                        _fuel = f;
                        _applyStationPrice();
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: CmSpacing.md),

          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Plein complet'), icon: Icon(Icons.battery_full_rounded)),
              ButtonSegment(value: false, label: Text('Appoint'), icon: Icon(Icons.battery_3_bar_rounded)),
            ],
            selected: {_fullTank},
            onSelectionChanged: (s) => setState(() => _fullTank = s.first),
          ),
          const SizedBox(height: CmSpacing.md),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _liters,
                  autofocus: station != null,
                  keyboardType: numberKeyboard,
                  inputFormatters: numberFilter,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Litres',
                    suffixText: 'L',
                    hintText: estimate != null && _fullTank && estimate > 0.5 ? '≈ ${_fmtInput(estimate, 1)}' : null,
                    errorText: _submitted ? _litersError : null,
                  ),
                ),
              ),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: TextField(
                  controller: _price,
                  keyboardType: numberKeyboard,
                  inputFormatters: numberFilter,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => _priceEdited = true,
                  decoration: InputDecoration(
                    labelText: 'Prix au litre',
                    suffixText: '€/L',
                    errorText: _submitted ? _priceError : null,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.sm),
          TextField(
            controller: _total,
            keyboardType: numberKeyboard,
            inputFormatters: numberFilter,
            style: CmTheme.numbers(size: 28, color: scheme.onSurface),
            decoration: InputDecoration(
              labelText: 'Total payé',
              suffixText: '€',
              helperText: total == null ? 'Calculé tout seul, ou tape le total pour trouver les litres' : null,
            ),
          ),
          const SizedBox(height: CmSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _odometer,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9\s]'))],
                  onChanged: (_) => _odometerEdited = true,
                  decoration: const InputDecoration(labelText: 'Compteur', suffixText: 'km'),
                ),
              ),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date',
                      suffixIcon: Icon(Icons.calendar_today_rounded, size: 18),
                    ),
                    child: Text(_isToday(_date) ? "Aujourd'hui" : Fmt.date(_date)),
                  ),
                ),
              ),
            ],
          ),
          if (_rideId != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _linkRide,
              onChanged: (v) => setState(() => _linkRide = v),
              secondary: const Icon(Icons.route_rounded),
              title: Text(widget.rideId != null ? 'Compter dans le coût de cette balade' : 'Lier à la balade en cours'),
            ),
          const SizedBox(height: CmSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.tips_and_updates_outlined, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _fullTank
                      ? 'Plein complet : on calcule ta conso réelle depuis le dernier plein complet '
                            'et on remet la jauge à fond.'
                      : "Appoint : la jauge remonte d'autant, sans calcul de conso.",
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.lg),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(_fullTank ? 'Enregistrer le plein' : "Enregistrer l'appoint"),
          ),
        ],
      ),
    );
  }

  static bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }
}
