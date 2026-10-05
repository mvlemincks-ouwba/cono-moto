import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/garage.dart';
import '../fuel/fuel_logic.dart';
import 'garage_providers.dart';
import 'maintenance.dart';

/// Couleurs proposées pour une moto.
const bikeColorChoices = <int>[
  0xFFFF6B1A, // orange
  0xFFEF4444, // rouge
  0xFFFACC15, // jaune
  0xFF22C55E, // vert
  0xFF2EC4B6, // turquoise
  0xFF4EA8FF, // bleu
  0xFF6366F1, // indigo
  0xFFA78BFA, // violet
  0xFFF472B6, // rose
  0xFFE5E7EB, // blanc
  0xFF9CA3AF, // gris
  0xFF1F2937, // noir
];

/// Ajout / modification d'une moto. Retourne la moto enregistrée.
Future<Bike?> showBikeForm(BuildContext context, {Bike? bike}) {
  return showModalBottomSheet<Bike>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: FractionallySizedBox(heightFactor: 0.92, child: BikeForm(bike: bike)),
    ),
  );
}

class BikeForm extends ConsumerStatefulWidget {
  const BikeForm({super.key, this.bike});

  final Bike? bike;

  @override
  ConsumerState<BikeForm> createState() => _BikeFormState();
}

class _BikeFormState extends ConsumerState<BikeForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _brand;
  late final TextEditingController _model;
  late final TextEditingController _year;
  late final TextEditingController _odometer;
  late final TextEditingController _tank;
  late final TextEditingController _reserve;
  late final TextEditingController _conso;
  late FuelType _fuel;
  late int _color;
  late bool _isDefault;
  bool _saving = false;

  bool get _editing => widget.bike != null;

  static String _n(double v) {
    final s = v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return s.replaceAll('.', ',');
  }

  @override
  void initState() {
    super.initState();
    final b = widget.bike;
    final hasBikes = (ref.read(bikesProvider).value ?? const []).isNotEmpty;
    _name = TextEditingController(text: b?.name ?? '');
    _brand = TextEditingController(text: b?.brand ?? '');
    _model = TextEditingController(text: b?.model ?? '');
    _year = TextEditingController(text: b?.year?.toString() ?? '');
    _odometer = TextEditingController(text: b == null ? '' : b.odometerKm.round().toString());
    _tank = TextEditingController(text: _n(b?.tankLiters ?? 15));
    _reserve = TextEditingController(text: _n(b?.reserveLiters ?? 3));
    _conso = TextEditingController(text: _n(b?.consumptionL100 ?? 5.5));
    _fuel = b?.fuelType ?? ref.read(settingsProvider).fuelType;
    _color = b?.colorValue ?? bikeColorChoices.first;
    _isDefault = b?.isDefault ?? !hasBikes;
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in [_name, _brand, _model, _year, _odometer, _tank, _reserve, _conso]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'Donne-lui un petit nom' : null;

  String? Function(String?) _range(double min, double max, String unit, {bool optional = false}) => (v) {
    final x = parseUserNumber(v);
    if (x == null) return optional && (v == null || v.trim().isEmpty) ? null : 'Nombre attendu';
    if (x < min || x > max) return 'Entre ${_n(min)} et ${_n(max)} $unit';
    return null;
  };

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false) || _saving) return;
    setState(() => _saving = true);
    final repo = ref.read(garageRepositoryProvider);
    final navigator = Navigator.of(context);
    final old = widget.bike;
    final bikes = ref.read(bikesProvider).value ?? const <Bike>[];
    final year = int.tryParse(_year.text.trim());
    final bike = Bike(
      id: old?.id ?? const Uuid().v4(),
      name: _name.text.trim(),
      brand: _brand.text.trim(),
      model: _model.text.trim(),
      year: year,
      odometerKm: parseUserNumber(_odometer.text) ?? 0,
      tankLiters: parseUserNumber(_tank.text) ?? 15,
      reserveLiters: parseUserNumber(_reserve.text) ?? 3,
      consumptionL100: parseUserNumber(_conso.text) ?? 5.5,
      fuelType: _fuel,
      colorValue: _color,
      // La première moto est forcément celle par défaut.
      isDefault: _isDefault || bikes.where((b) => b.id != old?.id).isEmpty,
      kmSinceFullTank: old?.kmSinceFullTank ?? 0,
    );
    try {
      await repo.upsertBike(bike);
      if (old == null) {
        final now = DateTime.now();
        for (final item in defaultMaintenanceItems(bike, now: now, newId: const Uuid().v4)) {
          await repo.upsertMaintenanceItem(item);
        }
      }
      if (bike.isDefault && ref.read(settingsProvider).fuelType != bike.fuelType) {
        await ref.read(settingsProvider.notifier).update((s) => s.copyWith(fuelType: bike.fuelType));
      }
      ref.read(selectedBikeIdProvider.notifier).select(bike.id);
      navigator.pop(bike);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showCmSnack(context, "Impossible d'enregistrer la moto : $e", error: true);
    }
  }

  Future<void> _delete() async {
    final bike = widget.bike!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Supprimer ${bike.name} ?'),
        content: const Text("Son carnet d'entretien sera supprimé. Les balades, pleins et dépenses restent."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CmColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final navigator = Navigator.of(context);
    final repo = ref.read(garageRepositoryProvider);
    await repo.deleteBike(bike.id);
    // Une autre moto devient celle par défaut si besoin.
    final rest = await repo.bikes();
    if (bike.isDefault && rest.isNotEmpty && !rest.any((b) => b.isDefault)) {
      await repo.upsertBike(rest.first.copyWith(isDefault: true));
    }
    ref.read(selectedBikeIdProvider.notifier).select(null);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = Color(_color);
    final numKeyboard = const TextInputType.numberWithOptions(decimal: true);
    final numFilter = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))];

    Widget field(
      TextEditingController c,
      String label, {
      String? suffix,
      String? Function(String?)? validator,
      bool number = false,
      String? hint,
    }) => TextFormField(
      controller: c,
      keyboardType: number ? numKeyboard : TextInputType.text,
      inputFormatters: number ? numFilter : null,
      textCapitalization: number ? TextCapitalization.none : TextCapitalization.words,
      validator: validator,
      decoration: InputDecoration(labelText: label, suffixText: suffix, hintText: hint),
    );

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, CmSpacing.xxl),
        children: [
          // Aperçu.
          Container(
            padding: const EdgeInsets.all(CmSpacing.lg),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(CmSpacing.radius),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color.withValues(alpha: 0.45), scheme.surfaceContainer],
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Icon(
                    Icons.two_wheeler_rounded,
                    size: 30,
                    color: color.computeLuminance() > 0.6 ? Colors.black87 : Colors.white,
                  ),
                ),
                const SizedBox(width: CmSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _editing ? 'Ta moto' : 'Nouvelle moto',
                        style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        _name.text.trim().isEmpty ? 'Ta bécane' : _name.text.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.headlineMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SectionHeader('Identité', padding: EdgeInsets.fromLTRB(0, CmSpacing.xl, 0, CmSpacing.sm)),
          field(_name, 'Petit nom', validator: _required, hint: 'La Bleue, MT-07…'),
          const SizedBox(height: CmSpacing.sm),
          Row(
            children: [
              Expanded(child: field(_brand, 'Marque', hint: 'Yamaha')),
              const SizedBox(width: CmSpacing.sm),
              Expanded(child: field(_model, 'Modèle', hint: 'Tracer 9')),
            ],
          ),
          const SizedBox(height: CmSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _year,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final y = int.tryParse(v.trim());
                    if (y == null || y < 1900 || y > DateTime.now().year + 1) return 'Année ?';
                    return null;
                  },
                  decoration: const InputDecoration(labelText: 'Année'),
                ),
              ),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: field(
                  _odometer,
                  'Compteur',
                  suffix: 'km',
                  number: true,
                  validator: _range(0, 2000000, 'km', optional: true),
                ),
              ),
            ],
          ),
          const SectionHeader('Réservoir & conso', padding: EdgeInsets.fromLTRB(0, CmSpacing.xl, 0, CmSpacing.sm)),
          Row(
            children: [
              Expanded(
                child: field(_tank, 'Réservoir', suffix: 'L', number: true, validator: _range(3, 40, 'L')),
              ),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: field(_reserve, 'Réserve', suffix: 'L', number: true, validator: _range(0, 10, 'L')),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.sm),
          field(
            _conso,
            'Conso moyenne',
            suffix: 'L/100 km',
            number: true,
            validator: _range(minPlausibleL100, maxPlausibleL100, 'L/100'),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              'Elle s’affine toute seule à chaque plein complet.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: CmSpacing.md),
          Text('Carburant', style: text.labelLarge),
          const SizedBox(height: CmSpacing.sm),
          Wrap(
            spacing: CmSpacing.sm,
            runSpacing: CmSpacing.sm,
            children: [
              for (final f in FuelType.values)
                ChoiceChip(label: Text(f.label), selected: f == _fuel, onSelected: (_) => setState(() => _fuel = f)),
            ],
          ),
          const SectionHeader('Couleur', padding: EdgeInsets.fromLTRB(0, CmSpacing.xl, 0, CmSpacing.sm)),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in bikeColorChoices)
                Semantics(
                  button: true,
                  selected: c == _color,
                  label: 'Couleur',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _color = c),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == _color ? scheme.onSurface : scheme.outlineVariant,
                          width: c == _color ? 3 : 1,
                        ),
                      ),
                      child: c == _color
                          ? Icon(
                              Icons.check_rounded,
                              size: 20,
                              color: Color(c).computeLuminance() > 0.6 ? Colors.black87 : Colors.white,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: CmSpacing.md),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _isDefault,
            onChanged: (v) => setState(() => _isDefault = v),
            title: const Text('Moto par défaut'),
            subtitle: const Text('Utilisée pour les balades, l’autonomie et les pleins'),
          ),
          const SizedBox(height: CmSpacing.lg),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check_rounded),
            label: Text(_editing ? 'Enregistrer' : 'Ajouter au garage'),
          ),
          if (_editing) ...[
            const SizedBox(height: CmSpacing.sm),
            TextButton.icon(
              onPressed: _delete,
              style: TextButton.styleFrom(foregroundColor: CmColors.red),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Supprimer cette moto'),
            ),
          ],
        ],
      ),
    );
  }
}
