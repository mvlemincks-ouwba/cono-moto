import 'package:flutter/material.dart';

/// Partage des frais façon Tricount — logique pure (montants en centimes,
/// donc sans erreur d'arrondi). Testée dans `test/social/expenses_test.dart`.

/// Catégorie de dépense.
enum ExpenseCategory {
  essence('Essence', Icons.local_gas_station_rounded, Color(0xFFFF6B1A)),
  peage('Péage', Icons.toll_rounded, Color(0xFF4EA8FF)),
  resto('Resto', Icons.restaurant_rounded, Color(0xFF2EC4B6)),
  autre('Autre', Icons.receipt_long_rounded, Color(0xFFA78BFA));

  const ExpenseCategory(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;

  static ExpenseCategory fromName(String? n) =>
      ExpenseCategory.values.firstWhere((c) => c.name == n, orElse: () => ExpenseCategory.autre);
}

/// Une dépense payée par un membre pour un sous-ensemble du groupe.
@immutable
class Expense {
  const Expense({
    required this.id,
    required this.label,
    required this.amountCents,
    required this.paidBy,
    required this.participants,
    this.category = ExpenseCategory.autre,
    required this.createdAt,
    this.createdBy = '',
  });

  final String id;
  final String label;

  /// Montant total en centimes (> 0).
  final int amountCents;

  /// uid de celui qui a payé.
  final String paidBy;

  /// uids de ceux pour qui la dépense a été faite (le payeur peut en faire partie ou non).
  final List<String> participants;
  final ExpenseCategory category;
  final DateTime createdAt;
  final String createdBy;

  Map<String, Object?> toMap() => {
        'label': label,
        'amount': amountCents,
        'paidBy': paidBy,
        'participants': {for (final p in participants) p: true},
        'category': category.name,
        'ts': createdAt.millisecondsSinceEpoch,
        'createdBy': createdBy,
      };

  static Expense? fromMap(String id, Object? raw) {
    if (raw is! Map) return null;
    final amount = raw['amount'];
    final paidBy = raw['paidBy'];
    if (amount is! num || paidBy is! String) return null;
    final parts = raw['participants'];
    final participants = <String>[];
    if (parts is Map) {
      for (final e in parts.entries) {
        if (e.value == true) participants.add('${e.key}');
      }
    } else if (parts is List) {
      participants.addAll(parts.whereType<String>());
    }
    participants.sort();
    if (participants.isEmpty || amount <= 0) return null;
    final ts = raw['ts'];
    return Expense(
      id: id,
      label: (raw['label'] as String?)?.trim().isNotEmpty == true ? (raw['label'] as String).trim() : 'Dépense',
      amountCents: amount.round(),
      paidBy: paidBy,
      participants: participants,
      category: ExpenseCategory.fromName(raw['category'] as String?),
      createdAt: ts is num ? DateTime.fromMillisecondsSinceEpoch(ts.toInt(), isUtc: true) : DateTime.utc(2000),
      createdBy: (raw['createdBy'] as String?) ?? '',
    );
  }
}

/// Remboursement enregistré : [from] a donné [amountCents] à [to].
@immutable
class Settlement {
  const Settlement({
    required this.id,
    required this.from,
    required this.to,
    required this.amountCents,
    required this.createdAt,
    this.createdBy = '',
  });

  final String id;
  final String from;
  final String to;
  final int amountCents;
  final DateTime createdAt;
  final String createdBy;

  Map<String, Object?> toMap() => {
        'from': from,
        'to': to,
        'amount': amountCents,
        'ts': createdAt.millisecondsSinceEpoch,
        'createdBy': createdBy,
      };

  static Settlement? fromMap(String id, Object? raw) {
    if (raw is! Map) return null;
    final from = raw['from'], to = raw['to'], amount = raw['amount'];
    if (from is! String || to is! String || amount is! num || amount <= 0 || from == to) return null;
    final ts = raw['ts'];
    return Settlement(
      id: id,
      from: from,
      to: to,
      amountCents: amount.round(),
      createdAt: ts is num ? DateTime.fromMillisecondsSinceEpoch(ts.toInt(), isUtc: true) : DateTime.utc(2000),
      createdBy: (raw['createdBy'] as String?) ?? '',
    );
  }
}

/// Virement à faire pour solder les comptes.
@immutable
class Transfer {
  const Transfer({required this.from, required this.to, required this.amountCents});

  final String from;
  final String to;
  final int amountCents;

  @override
  bool operator ==(Object other) =>
      other is Transfer && other.from == from && other.to == to && other.amountCents == amountCents;

  @override
  int get hashCode => Object.hash(from, to, amountCents);

  @override
  String toString() => 'Transfer($from → $to : $amountCents c)';
}

class ExpenseMath {
  ExpenseMath._();

  /// Au-delà, on retombe sur l'algorithme glouton (≤ n-1 virements).
  static const _exactLimit = 16;

  /// Part de chaque participant (centimes). Les centimes restants sont
  /// répartis un par un, dans l'ordre alphabétique des uids : la somme des
  /// parts vaut toujours exactement le montant.
  static Map<String, int> shares(Expense e) {
    final people = e.participants.toSet().toList()..sort();
    if (people.isEmpty) return const {};
    final base = e.amountCents ~/ people.length;
    final rest = e.amountCents - base * people.length;
    return {
      for (var i = 0; i < people.length; i++) people[i]: base + (i < rest ? 1 : 0),
    };
  }

  /// Solde de chacun en centimes : positif = on lui doit de l'argent,
  /// négatif = il doit de l'argent. La somme des soldes vaut toujours 0.
  static Map<String, int> balances({
    Iterable<String> members = const [],
    required Iterable<Expense> expenses,
    Iterable<Settlement> settlements = const [],
  }) {
    final out = <String, int>{for (final m in members) m: 0};
    for (final e in expenses) {
      out[e.paidBy] = (out[e.paidBy] ?? 0) + e.amountCents;
      for (final s in shares(e).entries) {
        out[s.key] = (out[s.key] ?? 0) - s.value;
      }
    }
    for (final s in settlements) {
      out[s.from] = (out[s.from] ?? 0) + s.amountCents;
      out[s.to] = (out[s.to] ?? 0) - s.amountCents;
    }
    return out;
  }

  /// Total dépensé par le groupe.
  static int total(Iterable<Expense> expenses) => expenses.fold(0, (a, e) => a + e.amountCents);

  /// Ce que [uid] a consommé (sa part de toutes les dépenses).
  static int consumedBy(String uid, Iterable<Expense> expenses) =>
      expenses.fold(0, (a, e) => a + (shares(e)[uid] ?? 0));

  /// Ce que [uid] a avancé.
  static int paidBy(String uid, Iterable<Expense> expenses) =>
      expenses.where((e) => e.paidBy == uid).fold(0, (a, e) => a + e.amountCents);

  /// Liste minimale de virements pour remettre tous les soldes à zéro.
  ///
  /// Exacte (nombre minimal de virements) jusqu'à 16 personnes non soldées :
  /// on cherche le partage en un maximum de sous-groupes à somme nulle, chacun
  /// se soldant en (taille - 1) virements. Au-delà : algorithme glouton.
  static List<Transfer> settle(Map<String, int> balances) {
    final entries = balances.entries.where((e) => e.value != 0).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (entries.isEmpty) return const [];
    final sum = entries.fold<int>(0, (a, e) => a + e.value);
    if (sum != 0) {
      throw ArgumentError('Les soldes doivent s\'annuler (somme = $sum)');
    }
    if (entries.length > _exactLimit) return _greedy(Map.fromEntries(entries));

    final n = entries.length;
    final values = [for (final e in entries) e.value];
    final full = (1 << n) - 1;
    final sums = List<int>.filled(1 << n, 0);
    final dp = List<int>.filled(1 << n, 0);
    for (var mask = 1; mask <= full; mask++) {
      final low = mask & -mask;
      final i = low.bitLength - 1;
      sums[mask] = sums[mask ^ low] + values[i];
      var best = 0;
      for (var j = 0; j < n; j++) {
        if (mask & (1 << j) != 0) {
          final v = dp[mask ^ (1 << j)];
          if (v > best) best = v;
        }
      }
      dp[mask] = best + (sums[mask] == 0 ? 1 : 0);
    }

    // Reconstitue un ordre des personnes où chaque préfixe à somme nulle
    // ferme un sous-groupe.
    final order = <int>[];
    var mask = full;
    while (mask != 0) {
      final target = dp[mask] - (sums[mask] == 0 ? 1 : 0);
      for (var j = 0; j < n; j++) {
        if (mask & (1 << j) != 0 && dp[mask ^ (1 << j)] == target) {
          order.add(j);
          mask ^= 1 << j;
          break;
        }
      }
    }
    final ordered = order.reversed.toList();
    final transfers = <Transfer>[];
    var group = <String, int>{};
    var running = 0;
    for (final j in ordered) {
      group[entries[j].key] = values[j];
      running += values[j];
      if (running == 0) {
        transfers.addAll(_greedy(group));
        group = {};
      }
    }
    return transfers;
  }

  /// Glouton : le plus gros débiteur rembourse le plus gros créancier.
  static List<Transfer> _greedy(Map<String, int> balances) {
    final debtors = <MapEntry<String, int>>[];
    final creditors = <MapEntry<String, int>>[];
    for (final e in balances.entries) {
      if (e.value < 0) debtors.add(MapEntry(e.key, -e.value));
      if (e.value > 0) creditors.add(MapEntry(e.key, e.value));
    }
    int cmp(MapEntry<String, int> a, MapEntry<String, int> b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    }

    final out = <Transfer>[];
    while (debtors.isNotEmpty && creditors.isNotEmpty) {
      debtors.sort(cmp);
      creditors.sort(cmp);
      final d = debtors.first, c = creditors.first;
      final amount = d.value < c.value ? d.value : c.value;
      out.add(Transfer(from: d.key, to: c.key, amountCents: amount));
      debtors[0] = MapEntry(d.key, d.value - amount);
      creditors[0] = MapEntry(c.key, c.value - amount);
      debtors.removeWhere((e) => e.value == 0);
      creditors.removeWhere((e) => e.value == 0);
    }
    return out;
  }

  /// Lit un montant saisi (« 12,50 », « 12.5 », « 1 234,56 € ») en centimes.
  /// Retourne null si la saisie est invalide ou ≤ 0.
  static int? parseAmount(String input) {
    var s = input.trim().replaceAll('€', '').replaceAll(RegExp(r'[\s  ]'), '');
    if (s.isEmpty) return null;
    final lastComma = s.lastIndexOf(',');
    final lastDot = s.lastIndexOf('.');
    final decimalPos = lastComma > lastDot ? lastComma : lastDot;
    String intPart, decPart;
    if (decimalPos >= 0 && s.length - decimalPos - 1 <= 2) {
      intPart = s.substring(0, decimalPos).replaceAll(RegExp(r'[.,]'), '');
      decPart = s.substring(decimalPos + 1);
    } else {
      intPart = s.replaceAll(RegExp(r'[.,]'), '');
      decPart = '';
    }
    if (intPart.isEmpty) intPart = '0';
    if (!RegExp(r'^\d+$').hasMatch(intPart) || !RegExp(r'^\d{0,2}$').hasMatch(decPart)) return null;
    if (intPart.length > 7) return null; // garde-fou : 10 M€
    final cents = int.parse(intPart) * 100 + (decPart.isEmpty ? 0 : int.parse(decPart.padRight(2, '0')));
    return cents > 0 ? cents : null;
  }

  /// Phrase « Max doit 12,50 € à Julie » (tutoiement si je suis concerné).
  static String sentence(
    Transfer t, {
    required String Function(String uid) nameOf,
    required String amount,
    String? me,
  }) {
    if (t.from == me) return 'Tu dois $amount à ${nameOf(t.to)}';
    if (t.to == me) return '${nameOf(t.from)} te doit $amount';
    return '${nameOf(t.from)} doit $amount à ${nameOf(t.to)}';
  }

  /// Centimes → euros (pour l'affichage).
  static double toEuros(int cents) => cents / 100.0;
}
