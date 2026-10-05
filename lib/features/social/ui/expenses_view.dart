import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/ui/widgets.dart';
import '../../../services/social/social_api.dart';
import '../expenses.dart';
import '../social_models.dart';
import '../social_providers.dart';
import 'profile_editor.dart';
import 'social_widgets.dart';

String _euros(int cents) => Fmt.euros(ExpenseMath.toEuros(cents));

/// Onglet « Frais » d'un groupe : soldes, qui doit quoi, dépenses.
class ExpensesView extends ConsumerWidget {
  const ExpensesView({super.key, required this.group});

  final Group group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(myUidProvider) ?? '';
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final g = group;
    final balances = g.balances;
    final transfers = g.transfers;
    final myBalance = balances[me] ?? 0;
    String nameOf(String uid) => uid == me ? 'Toi' : g.nameOf(uid);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-expense-${g.id}',
        onPressed: () => showAddExpenseSheet(context, g),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Dépense'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.lg, CmSpacing.lg, 110),
        children: [
          StatGrid(
            columns: 3,
            compact: true,
            children: [
              StatTile(label: 'Total', value: Fmt.number(ExpenseMath.toEuros(ExpenseMath.total(g.expenses)), decimals: 2), unit: '€', icon: Icons.functions_rounded),
              StatTile(label: 'Ma part', value: Fmt.number(ExpenseMath.toEuros(ExpenseMath.consumedBy(me, g.expenses)), decimals: 2), unit: '€', icon: Icons.person_rounded),
              StatTile(
                label: 'Mon solde',
                value: '${myBalance > 0 ? '+' : ''}${Fmt.number(ExpenseMath.toEuros(myBalance), decimals: 2)}',
                unit: '€',
                icon: Icons.account_balance_wallet_rounded,
                color: myBalance > 0 ? CmColors.green : (myBalance < 0 ? CmColors.red : null),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.lg),
          // ------------------------------------------------- Qui doit quoi
          SocialCard(
            padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.lg, CmSpacing.sm, CmSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.swap_horiz_rounded, color: CmColors.orange),
                    const SizedBox(width: CmSpacing.sm),
                    Flexible(child: Text('Qui doit quoi', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
                  ],
                ),
                const SizedBox(height: CmSpacing.sm),
                if (transfers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: CmSpacing.sm),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle_rounded, color: CmColors.green),
                        const SizedBox(width: CmSpacing.sm),
                        Expanded(
                          child: Text(
                            g.expenses.isEmpty ? 'Aucune dépense pour l\'instant.' : 'Tout le monde est quitte. Champagne (sans alcool) !',
                            style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  for (final tr in transfers)
                    _TransferRow(
                      transfer: tr,
                      group: g,
                      me: me,
                      label: ExpenseMath.sentence(tr, nameOf: (u) => u == me ? 'toi' : g.nameOf(u), amount: _euros(tr.amountCents), me: me),
                    ),
                if (transfers.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: CmSpacing.xs, right: CmSpacing.sm),
                    child: Text(
                      '${transfers.length} remboursement${transfers.length > 1 ? 's' : ''} suffi${transfers.length > 1 ? 'sent' : 't'} pour solder les comptes.',
                      style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: CmSpacing.md),
          // ------------------------------------------------------- Soldes
          if (g.expenses.isNotEmpty) ...[
            SocialCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Soldes', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: CmSpacing.md),
                  _BalanceBars(group: g, balances: balances, me: me),
                ],
              ),
            ),
            const SizedBox(height: CmSpacing.md),
          ],
          // ----------------------------------------------------- Dépenses
          SectionHeader('Dépenses', padding: const EdgeInsets.fromLTRB(CmSpacing.xs, CmSpacing.md, 0, CmSpacing.sm)),
          if (g.expenses.isEmpty)
            SocialCard(
              child: Column(
                children: [
                  const Icon(Icons.receipt_long_rounded, size: 40, color: CmColors.orange),
                  const SizedBox(height: CmSpacing.sm),
                  Text('Le plein, le péage, la pause resto…', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                    'Note les dépenses au fil de la balade, l\'app calcule qui doit quoi à qui.',
                    textAlign: TextAlign.center,
                    style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          else
            SocialCard(
              padding: const EdgeInsets.symmetric(vertical: CmSpacing.xs),
              child: Column(
                children: [
                  for (final e in g.expenses) _ExpenseTile(expense: e, group: g, me: me, nameOf: nameOf),
                ],
              ),
            ),
          // ----------------------------------------------- Remboursements
          if (g.settlements.isNotEmpty) ...[
            SectionHeader('Remboursements faits', padding: const EdgeInsets.fromLTRB(CmSpacing.xs, CmSpacing.lg, 0, CmSpacing.sm)),
            SocialCard(
              padding: const EdgeInsets.symmetric(vertical: CmSpacing.xs),
              child: Column(
                children: [
                  for (final s in g.settlements)
                    ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: Color(0x2622C55E),
                        child: Icon(Icons.handshake_rounded, color: CmColors.green),
                      ),
                      title: Text('${nameOf(s.from)} → ${nameOf(s.to)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(Fmt.dateTime(s.createdAt)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_euros(s.amountCents), style: CmTheme.numbers(size: 20, color: CmColors.green)),
                          IconButton(
                            tooltip: 'Annuler ce remboursement',
                            icon: const Icon(Icons.undo_rounded),
                            onPressed: () async {
                              final ok = await confirmAction(
                                context,
                                title: 'Annuler ce remboursement ?',
                                message: 'Les soldes seront recalculés comme s\'il n\'avait pas eu lieu.',
                                confirm: 'Annuler le remboursement',
                              );
                              if (ok && context.mounted) {
                                await _run(context, () => ref.read(socialActionsProvider).deleteSettlement(g.id, s.id));
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> _run(BuildContext context, Future<bool> Function() op, {String? success}) async {
  try {
    final synced = await op();
    if (!context.mounted) return;
    if (!synced) {
      showCmSnack(context, 'Enregistré, envoi dès que le réseau revient');
    } else if (success != null) {
      showCmSnack(context, success);
    }
  } on SocialException catch (e) {
    if (context.mounted) showCmSnack(context, e.message, error: true);
  }
}

class _TransferRow extends ConsumerWidget {
  const _TransferRow({required this.transfer, required this.group, required this.me, required this.label});

  final Transfer transfer;
  final Group group;
  final String me;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final from = group.member(transfer.from);
    final involved = transfer.from == me || transfer.to == me;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          RiderAvatar(name: group.nameOf(transfer.from), color: from?.color ?? Colors.grey, size: 34),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.arrow_forward_rounded, size: 16),
          ),
          RiderAvatar(name: group.nameOf(transfer.to), color: group.member(transfer.to)?.color ?? Colors.grey, size: 34),
          const SizedBox(width: CmSpacing.md),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontWeight: involved ? FontWeight.w800 : FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () async {
              final ok = await confirmAction(
                context,
                title: 'Remboursement fait ?',
                message: '$label : on le note comme réglé ?',
                confirm: 'C\'est réglé',
                destructive: false,
              );
              if (ok && context.mounted) {
                await _run(context, () => ref.read(socialActionsProvider).settle(group.id, transfer),
                    success: 'Remboursement noté');
              }
            },
            child: const Text('Réglé'),
          ),
        ],
      ),
    );
  }
}

class _BalanceBars extends StatelessWidget {
  const _BalanceBars({required this.group, required this.balances, required this.me});

  final Group group;
  final Map<String, int> balances;
  final String me;

  @override
  Widget build(BuildContext context) {
    final entries = balances.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final maxAbs = entries.fold<int>(1, (m, e) => math.max(m, e.value.abs()));
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    e.key == me ? 'Toi' : group.nameOf(e.key),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: e.key == me ? FontWeight.w800 : FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(builder: (context, c) {
                    final half = c.maxWidth / 2;
                    final w = half * (e.value.abs() / maxAbs);
                    final color = e.value >= 0 ? CmColors.green : CmColors.red;
                    return SizedBox(
                      height: 22,
                      child: Stack(
                        children: [
                          Positioned(
                            left: half - 0.5,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 1, color: scheme.outlineVariant),
                          ),
                          Positioned(
                            left: e.value >= 0 ? half : half - w,
                            top: 3,
                            bottom: 3,
                            child: Container(
                              width: math.max(w, e.value == 0 ? 0 : 3),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
                SizedBox(
                  width: 84,
                  child: Text(
                    '${e.value > 0 ? '+' : ''}${_euros(e.value)}',
                    textAlign: TextAlign.right,
                    style: CmTheme.numbers(
                      size: 18,
                      color: e.value > 0 ? CmColors.green : (e.value < 0 ? CmColors.red : scheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ExpenseTile extends ConsumerWidget {
  const _ExpenseTile({required this.expense, required this.group, required this.me, required this.nameOf});

  final Expense expense;
  final Group group;
  final String me;
  final String Function(String uid) nameOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = expense;
    final everyone = group.members.isNotEmpty && group.members.every((m) => e.participants.contains(m.uid));
    final forWho = everyone
        ? 'pour tout le monde'
        : (e.participants.length == 1 ? 'pour ${nameOf(e.participants.first)}' : 'pour ${e.participants.length} potes');
    return ListTile(
      onTap: () => _showExpenseDetails(context, ref),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: e.category.color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(e.category.icon, color: e.category.color),
      ),
      title: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text('${nameOf(e.paidBy)} a payé $forWho · ${Fmt.date(e.createdAt)}', maxLines: 2),
      trailing: Text(_euros(e.amountCents), style: CmTheme.numbers(size: 20)),
    );
  }

  Future<void> _showExpenseDetails(BuildContext context, WidgetRef ref) {
    final e = expense;
    final shares = ExpenseMath.shares(e);
    return showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(CmSpacing.xl, 0, CmSpacing.xl, CmSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitle(
                icon: e.category.icon,
                color: e.category.color,
                title: e.label,
                subtitle: '${_euros(e.amountCents)} · payé par ${nameOf(e.paidBy)} · ${Fmt.dateTime(e.createdAt)}',
              ),
              const SizedBox(height: CmSpacing.lg),
              Text('Répartition', style: Theme.of(ctx).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: CmSpacing.xs),
              for (final s in shares.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      RiderAvatar(name: group.nameOf(s.key), color: group.member(s.key)?.color ?? Colors.grey, size: 28),
                      const SizedBox(width: CmSpacing.sm),
                      Expanded(child: Text(nameOf(s.key))),
                      Text(_euros(s.value), style: CmTheme.numbers(size: 18)),
                    ],
                  ),
                ),
              const SizedBox(height: CmSpacing.lg),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: CmColors.red),
                onPressed: () async {
                  final ok = await confirmAction(
                    ctx,
                    title: 'Supprimer cette dépense ?',
                    message: '« ${e.label} » (${_euros(e.amountCents)}) sera retirée pour tout le groupe.',
                    confirm: 'Supprimer',
                  );
                  if (!ok || !ctx.mounted) return;
                  Navigator.pop(ctx);
                  await _run(context, () => ref.read(socialActionsProvider).deleteExpense(group.id, e.id),
                      success: 'Dépense supprimée');
                },
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Supprimer la dépense'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Feuille « Ajouter une dépense ».
Future<void> showAddExpenseSheet(BuildContext context, Group group) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _AddExpenseSheet(group: group),
  );
}

class _AddExpenseSheet extends ConsumerStatefulWidget {
  const _AddExpenseSheet({required this.group});

  final Group group;

  @override
  ConsumerState<_AddExpenseSheet> createState() => _AddExpenseSheetState();
}

class _AddExpenseSheetState extends ConsumerState<_AddExpenseSheet> {
  final _label = TextEditingController();
  final _amount = TextEditingController();
  var _category = ExpenseCategory.essence;
  late String _paidBy;
  late Set<String> _participants;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final me = ref.read(myUidProvider);
    final members = widget.group.members.map((m) => m.uid).toList();
    _paidBy = (me != null && members.contains(me)) ? me : (members.isNotEmpty ? members.first : '');
    _participants = members.toSet();
    _amount.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _label.dispose();
    _amount.dispose();
    super.dispose();
  }

  static const _hints = {
    ExpenseCategory.essence: 'ex : Plein à Saint-Flour',
    ExpenseCategory.peage: 'ex : Péage A75',
    ExpenseCategory.resto: 'ex : Burger au col',
    ExpenseCategory.autre: 'ex : Cafés, parking…',
  };

  Future<void> _save() async {
    final cents = ExpenseMath.parseAmount(_amount.text);
    if (cents == null) {
      setState(() => _error = 'Indique un montant valide (ex : 23,50).');
      return;
    }
    if (_participants.isEmpty) {
      setState(() => _error = 'Choisis au moins une personne concernée.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final synced = await ref.read(socialActionsProvider).addExpense(
            widget.group.id,
            label: _label.text,
            amountCents: cents,
            paidBy: _paidBy,
            participants: _participants.toList()..sort(),
            category: _category,
          );
      if (!mounted) return;
      Navigator.pop(context);
      if (!synced) showCmSnack(context, 'Enregistrée, envoi dès que le réseau revient');
    } on SocialException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final me = ref.watch(myUidProvider);
    final members = widget.group.members;
    final cents = ExpenseMath.parseAmount(_amount.text);
    final each = (cents != null && _participants.isNotEmpty) ? cents / _participants.length / 100 : null;
    String label(GroupMember m) => m.uid == me ? 'Moi' : m.name;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(CmSpacing.xl, 0, CmSpacing.xl, CmSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetTitle(icon: Icons.receipt_long_rounded, title: 'Nouvelle dépense', color: CmColors.green),
              const SizedBox(height: CmSpacing.lg),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in ExpenseCategory.values)
                    ChoiceChip(
                      avatar: Icon(c.icon, size: 18, color: _category == c ? Colors.white : c.color),
                      label: Text(c.label),
                      selected: _category == c,
                      selectedColor: c.color,
                      labelStyle: TextStyle(
                        color: _category == c ? Colors.white : null,
                        fontWeight: FontWeight.w700,
                      ),
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _category = c),
                    ),
                ],
              ),
              const SizedBox(height: CmSpacing.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _label,
                      textCapitalization: TextCapitalization.sentences,
                      maxLength: 60,
                      decoration: InputDecoration(labelText: 'Libellé', hintText: _hints[_category], counterText: ''),
                    ),
                  ),
                  const SizedBox(width: CmSpacing.md),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _amount,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: CmTheme.numbers(size: 24),
                      decoration: const InputDecoration(labelText: 'Montant', suffixText: '€'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: CmSpacing.lg),
              Text('Payé par', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: CmSpacing.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in members)
                    ChoiceChip(
                      avatar: RiderAvatar(name: m.name, color: m.color, size: 24),
                      label: Text(label(m)),
                      selected: _paidBy == m.uid,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _paidBy = m.uid),
                    ),
                ],
              ),
              const SizedBox(height: CmSpacing.lg),
              Row(
                children: [
                  Expanded(child: Text('Pour qui', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800))),
                  TextButton(
                    onPressed: () => setState(() {
                      final all = members.map((m) => m.uid).toSet();
                      _participants = _participants.length == all.length ? <String>{} : all;
                    }),
                    child: Text(_participants.length == members.length ? 'Personne' : 'Tout le monde'),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in members)
                    FilterChip(
                      avatar: RiderAvatar(name: m.name, color: m.color, size: 24),
                      label: Text(label(m)),
                      selected: _participants.contains(m.uid),
                      onSelected: (v) => setState(() => v ? _participants.add(m.uid) : _participants.remove(m.uid)),
                    ),
                ],
              ),
              const SizedBox(height: CmSpacing.md),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: each == null
                    ? const SizedBox(height: 20)
                    : Text(
                        _participants.length == 1
                            ? 'Tout pour une seule personne'
                            : 'Soit environ ${Fmt.euros(each)} chacun (${_participants.length} personnes)',
                        key: ValueKey(each),
                        style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
              ),
              if (_error != null) ...[
                const SizedBox(height: CmSpacing.md),
                InlineError(_error!),
              ],
              const SizedBox(height: CmSpacing.lg),
              BusyButton(label: 'Ajouter la dépense', busy: _busy, onPressed: _save, color: CmColors.green),
            ],
          ),
        ),
      ),
    );
  }
}
