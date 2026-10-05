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

/// Ajout rapide d'une dépense (péage, resto, équipement…).
/// Retourne la dépense enregistrée, ou null si annulé.
Future<Expense?> showExpenseForm(
  BuildContext context, {
  String? rideId,
  String? bikeId,
  ExpenseCategory? category,
  DateTime? date,
}) {
  return showModalBottomSheet<Expense>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: ExpenseForm(rideId: rideId, bikeId: bikeId, category: category, date: date),
    ),
  );
}

class ExpenseForm extends ConsumerStatefulWidget {
  const ExpenseForm({super.key, this.rideId, this.bikeId, this.category, this.date});

  final String? rideId;
  final String? bikeId;
  final ExpenseCategory? category;
  final DateTime? date;

  @override
  ConsumerState<ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends ConsumerState<ExpenseForm> {
  final _amount = TextEditingController();
  final _label = TextEditingController();
  late ExpenseCategory _category;
  late DateTime _date;
  bool _submitted = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _category = widget.category ?? (widget.rideId != null ? ExpenseCategory.peage : ExpenseCategory.entretien);
    _date = widget.date?.toLocal() ?? DateTime.now();
  }

  @override
  void dispose() {
    _amount.dispose();
    _label.dispose();
    super.dispose();
  }

  String? get _amountError {
    final a = parseUserNumber(_amount.text);
    if (a == null) return 'Combien ?';
    if (a <= 0 || a > 100000) return 'Montant improbable';
    return null;
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d != null && mounted) setState(() => _date = DateTime(d.year, d.month, d.day, _date.hour, _date.minute));
  }

  Future<void> _save() async {
    setState(() => _submitted = true);
    if (_amountError != null || _saving) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final expense = Expense(
      id: const Uuid().v4(),
      date: _date.toUtc(),
      amount: parseUserNumber(_amount.text)!,
      category: _category,
      label: _label.text.trim(),
      rideId: widget.rideId,
      bikeId: widget.bikeId ?? ref.read(defaultBikeProvider)?.id,
    );
    try {
      await ref.read(garageRepositoryProvider).upsertExpense(expense);
      navigator.pop(expense);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showCmSnack(context, "Impossible d'enregistrer la dépense : $e", error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, CmSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.rideId != null ? 'Dépense de la balade' : 'Nouvelle dépense', style: text.headlineSmall),
          const SizedBox(height: CmSpacing.md),
          Wrap(
            spacing: CmSpacing.sm,
            runSpacing: CmSpacing.sm,
            children: [
              for (final c in ExpenseCategory.values)
                ChoiceChip(
                  avatar: Icon(c.icon, size: 18),
                  label: Text(c.label),
                  selected: c == _category,
                  onSelected: (_) => setState(() => _category = c),
                ),
            ],
          ),
          const SizedBox(height: CmSpacing.lg),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
            style: CmTheme.numbers(size: 34, color: scheme.onSurface),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Montant',
              suffixText: '€',
              errorText: _submitted ? _amountError : null,
            ),
          ),
          const SizedBox(height: CmSpacing.sm),
          TextField(
            controller: _label,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Détail (facultatif)',
              hintText: switch (_category) {
                ExpenseCategory.peage => 'A43 Chambéry',
                ExpenseCategory.resto => 'Pause café au col',
                ExpenseCategory.parking => 'Parking centre-ville',
                ExpenseCategory.equipement => 'Gants été',
                ExpenseCategory.entretien => 'Kit chaîne',
                ExpenseCategory.autre => 'Lavage',
              },
            ),
          ),
          const SizedBox(height: CmSpacing.sm),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_today_rounded),
            title: Text(Fmt.dateLong(_date)),
            trailing: const Icon(Icons.edit_calendar_rounded),
            onTap: _pickDate,
          ),
          const SizedBox(height: CmSpacing.md),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check_rounded),
            label: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }
}
