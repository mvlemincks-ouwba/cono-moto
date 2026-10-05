import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/garage.dart';
import '../fuel/fuel_logic.dart';
import 'maintenance.dart';

/// Carnet d'entretien : barres de progression colorées par statut.
class MaintenanceList extends StatelessWidget {
  const MaintenanceList({super.key, required this.bike, required this.states, required this.logs});

  final Bike bike;
  final List<MaintenanceState> states;
  final List<MaintenanceLog> logs;

  @override
  Widget build(BuildContext context) {
    if (states.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
        child: Text(
          'Aucun élément suivi. Ajoute la vidange, la chaîne, les pneus…',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(CmSpacing.radius),
        ),
        child: Column(
          children: [
            for (var i = 0; i < states.length; i++) ...[
              if (i > 0) const Divider(indent: 72, height: 1),
              _MaintenanceTile(
                bike: bike,
                state: states[i],
                logs: logs.where((l) => l.itemId == states[i].item.id).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MaintenanceTile extends StatelessWidget {
  const _MaintenanceTile({required this.bike, required this.state, required this.logs});

  final Bike bike;
  final MaintenanceState state;
  final List<MaintenanceLog> logs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = state.status;
    final color = status.color;
    return InkWell(
      borderRadius: BorderRadius.circular(CmSpacing.radius),
      onTap: () => showMaintenanceActions(context, bike: bike, state: state, logs: logs),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.md, CmSpacing.lg, CmSpacing.md),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
              child: Icon(state.item.type.icon, size: 20, color: color),
            ),
            const SizedBox(width: CmSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (status != MaintenanceStatus.ok) Pill(label: status.label, icon: status.icon, color: color),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: status == MaintenanceStatus.none ? 0 : state.progress.clamp(0.02, 1.0),
                      minHeight: 6,
                      color: color,
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    state.summary,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Actions sur un élément : fait aujourd'hui, modifier, historique, supprimer.
Future<void> showMaintenanceActions(
  BuildContext context, {
  required Bike bike,
  required MaintenanceState state,
  required List<MaintenanceLog> logs,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final item = state.item;
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, CmSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(item.type.icon, color: state.status.color),
                  const SizedBox(width: CmSpacing.sm),
                  Expanded(child: Text(state.name, style: Theme.of(ctx).textTheme.headlineSmall)),
                  Pill(label: state.status.label, icon: state.status.icon, color: state.status.color),
                ],
              ),
              const SizedBox(height: CmSpacing.sm),
              Text(_intervalText(item), style: TextStyle(color: scheme.onSurfaceVariant)),
              Text(_lastDoneText(item), style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: CmSpacing.lg),
              FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await showMaintenanceDoneSheet(context, bike: bike, item: item);
                },
                icon: const Icon(Icons.task_alt_rounded),
                label: const Text("Fait aujourd'hui"),
              ),
              const SizedBox(height: CmSpacing.sm),
              OutlinedButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await showMaintenanceItemForm(context, bike: bike, item: item);
                },
                icon: const Icon(Icons.tune_rounded),
                label: const Text("Modifier l'échéance"),
              ),
              if (logs.isNotEmpty) ...[
                const SectionHeader('Historique', padding: EdgeInsets.fromLTRB(0, CmSpacing.xl, 0, CmSpacing.sm)),
                for (final l in logs.take(10))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.check_circle_outline_rounded),
                    title: Text(Fmt.date(l.date)),
                    subtitle: Text(
                      [
                        if (l.odometerKm != null) '${Fmt.number(l.odometerKm!)} km',
                        if (l.notes.isNotEmpty) l.notes,
                      ].join(' · '),
                    ),
                    trailing: l.cost != null && l.cost! > 0
                        ? Text(Fmt.euros(l.cost!), style: const TextStyle(fontWeight: FontWeight.w700))
                        : null,
                  ),
              ],
              const SizedBox(height: CmSpacing.md),
              Consumer(
                builder: (context, ref, _) => TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: CmColors.red),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await ref.read(garageRepositoryProvider).deleteMaintenanceItem(item.id);
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Ne plus suivre cet élément'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

String _intervalText(MaintenanceItem item) {
  final parts = [
    if ((item.intervalKm ?? 0) > 0) 'tous les ${Fmt.number(item.intervalKm!.toDouble())} km',
    if ((item.intervalMonths ?? 0) > 0) 'tous les ${item.intervalMonths} mois',
  ];
  return parts.isEmpty ? "Pas d'échéance définie" : 'À faire ${parts.join(' ou ')}';
}

String _lastDoneText(MaintenanceItem item) {
  if (item.lastDoneKm == null && item.lastDoneDate == null) return 'Jamais renseigné';
  return 'Dernière fois : ${[if (item.lastDoneDate != null) Fmt.date(item.lastDoneDate!), if (item.lastDoneKm != null) 'à ${Fmt.number(item.lastDoneKm!)} km'].join(' ')}';
}

/// « Fait aujourd'hui » : compteur, coût optionnel, notes.
Future<void> showMaintenanceDoneSheet(BuildContext context, {required Bike bike, required MaintenanceItem item}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _MaintenanceDoneForm(bike: bike, item: item),
    ),
  );
}

class _MaintenanceDoneForm extends ConsumerStatefulWidget {
  const _MaintenanceDoneForm({required this.bike, required this.item});

  final Bike bike;
  final MaintenanceItem item;

  @override
  ConsumerState<_MaintenanceDoneForm> createState() => _MaintenanceDoneFormState();
}

class _MaintenanceDoneFormState extends ConsumerState<_MaintenanceDoneForm> {
  late final _odometer = TextEditingController(text: widget.bike.odometerKm.round().toString());
  final _cost = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _odometer.dispose();
    _cost.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(garageRepositoryProvider);
    final now = DateTime.now();
    final odo = parseUserNumber(_odometer.text) ?? widget.bike.odometerKm;
    final cost = parseUserNumber(_cost.text);
    await repo.upsertMaintenanceItem(markMaintenanceDone(widget.item, odometerKm: odo, date: now));
    await repo.addMaintenanceLog(
      maintenanceLogFor(
        widget.item,
        id: const Uuid().v4(),
        odometerKm: odo,
        date: now,
        cost: cost != null && cost > 0 ? cost : null,
        notes: _notes.text.trim(),
      ),
    );
    // Le compteur saisi peut faire avancer celui de la moto.
    final fresh = await repo.bike(widget.bike.id);
    if (fresh != null && odo > fresh.odometerKm) {
      await repo.upsertBike(fresh.copyWith(odometerKm: odo));
    }
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text('${widget.item.displayName} : c’est noté, nickel !')));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, CmSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.item.displayName, style: Theme.of(context).textTheme.headlineSmall),
          Text("Fait aujourd'hui", style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: CmSpacing.lg),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _odometer,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9\s]'))],
                  decoration: const InputDecoration(labelText: 'Compteur', suffixText: 'km'),
                ),
              ),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: TextField(
                  controller: _cost,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
                  decoration: const InputDecoration(labelText: 'Coût (facultatif)', suffixText: '€'),
                ),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.sm),
          TextField(
            controller: _notes,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Notes', hintText: 'Huile 10W40, garage du coin…'),
          ),
          const SizedBox(height: CmSpacing.lg),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.task_alt_rounded),
            label: const Text("C'est fait"),
          ),
        ],
      ),
    );
  }
}

/// Création / modification d'un élément d'entretien.
Future<void> showMaintenanceItemForm(BuildContext context, {required Bike bike, MaintenanceItem? item}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _MaintenanceItemForm(bike: bike, item: item),
    ),
  );
}

class _MaintenanceItemForm extends ConsumerStatefulWidget {
  const _MaintenanceItemForm({required this.bike, this.item});

  final Bike bike;
  final MaintenanceItem? item;

  @override
  ConsumerState<_MaintenanceItemForm> createState() => _MaintenanceItemFormState();
}

class _MaintenanceItemFormState extends ConsumerState<_MaintenanceItemForm> {
  late MaintenanceType _type;
  late final TextEditingController _label;
  late final TextEditingController _km;
  late final TextEditingController _months;
  late final TextEditingController _lastKm;
  DateTime? _lastDate;
  bool _submitted = false;

  bool get _creating => widget.item == null;

  @override
  void initState() {
    super.initState();
    final i = widget.item;
    _type = i?.type ?? MaintenanceType.autre;
    _label = TextEditingController(text: i?.label ?? '');
    _km = TextEditingController(text: i?.intervalKm?.toString() ?? '');
    _months = TextEditingController(text: i?.intervalMonths?.toString() ?? '');
    _lastKm = TextEditingController(
      text: (i?.lastDoneKm ?? (i == null ? widget.bike.odometerKm : null))?.round().toString() ?? '',
    );
    _lastDate = i?.lastDoneDate?.toLocal() ?? (i == null ? DateTime.now() : null);
  }

  @override
  void dispose() {
    _label.dispose();
    _km.dispose();
    _months.dispose();
    _lastKm.dispose();
    super.dispose();
  }

  void _selectType(MaintenanceType t) {
    setState(() {
      _type = t;
      if (_creating) {
        _km.text = t.defaultIntervalKm?.toString() ?? '';
        _months.text = t.defaultIntervalMonths?.toString() ?? '';
      }
    });
  }

  String? get _labelError => _type == MaintenanceType.autre && _label.text.trim().isEmpty ? 'Donne-lui un nom' : null;

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _lastDate ?? DateTime.now(),
      firstDate: DateTime(1990),
      lastDate: DateTime.now(),
      helpText: 'Fait la dernière fois le',
    );
    if (d != null && mounted) setState(() => _lastDate = d);
  }

  Future<void> _save() async {
    setState(() => _submitted = true);
    if (_labelError != null) return;
    final navigator = Navigator.of(context);
    final base = widget.item ?? MaintenanceItem(id: const Uuid().v4(), bikeId: widget.bike.id, type: _type);
    final edited = editMaintenanceItem(
      MaintenanceItem(id: base.id, bikeId: base.bikeId, type: _type, notes: base.notes),
      label: _label.text.trim(),
      intervalKm: int.tryParse(_km.text.replaceAll(RegExp(r'\s'), '')),
      intervalMonths: int.tryParse(_months.text.trim()),
      lastDoneKm: parseUserNumber(_lastKm.text),
      lastDoneDate: _lastDate,
    );
    await ref.read(garageRepositoryProvider).upsertMaintenanceItem(edited);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.allow(RegExp(r'[0-9\s]'))];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, CmSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _creating ? 'Suivre un entretien' : 'Modifier l’échéance',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: CmSpacing.md),
          if (_creating) ...[
            Wrap(
              spacing: CmSpacing.sm,
              runSpacing: CmSpacing.sm,
              children: [
                for (final t in MaintenanceType.values)
                  ChoiceChip(
                    avatar: Icon(t.icon, size: 18),
                    label: Text(t == MaintenanceType.autre ? 'Perso' : t.label),
                    selected: t == _type,
                    onSelected: (_) => _selectType(t),
                  ),
              ],
            ),
            const SizedBox(height: CmSpacing.md),
          ],
          TextField(
            controller: _label,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: _type == MaintenanceType.autre ? 'Nom' : 'Nom personnalisé (facultatif)',
              hintText: _type == MaintenanceType.autre ? 'Filtre à air, batterie…' : _type.label,
              errorText: _submitted ? _labelError : null,
            ),
          ),
          const SizedBox(height: CmSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _km,
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  decoration: const InputDecoration(labelText: 'Tous les', suffixText: 'km'),
                ),
              ),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: TextField(
                  controller: _months,
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  decoration: const InputDecoration(labelText: 'ou tous les', suffixText: 'mois'),
                ),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.md),
          Text('Dernière fois', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: CmSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lastKm,
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  decoration: const InputDecoration(labelText: 'Au compteur', suffixText: 'km'),
                ),
              ),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Le',
                      suffixIcon: Icon(Icons.calendar_today_rounded, size: 18),
                    ),
                    child: Text(_lastDate == null ? '—' : Fmt.date(_lastDate!)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.lg),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check_rounded),
            label: Text(_creating ? 'Ajouter' : 'Enregistrer'),
          ),
        ],
      ),
    );
  }
}
