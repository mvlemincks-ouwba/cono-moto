import 'dart:math' as math;

import 'package:cono_moto/features/social/expenses.dart';
import 'package:flutter_test/flutter_test.dart';

Expense exp(String id, int cents, String paidBy, List<String> forWho,
        {ExpenseCategory cat = ExpenseCategory.essence}) =>
    Expense(
      id: id,
      label: id,
      amountCents: cents,
      paidBy: paidBy,
      participants: forWho,
      category: cat,
      createdAt: DateTime.utc(2026, 6, 1),
    );

/// Applique les virements et vérifie que tout le monde est soldé.
void expectSettles(Map<String, int> balances, List<Transfer> transfers) {
  final b = Map.of(balances);
  for (final t in transfers) {
    expect(t.amountCents, greaterThan(0));
    b[t.from] = b[t.from]! + t.amountCents;
    b[t.to] = b[t.to]! - t.amountCents;
  }
  expect(b.values.every((v) => v == 0), isTrue, reason: '$b');
}

void main() {
  group('Parts', () {
    test('partage équitable au centime près', () {
      final s = ExpenseMath.shares(exp('plein', 1000, 'a', ['a', 'b', 'c']));
      expect(s, {'a': 334, 'b': 333, 'c': 333});
      expect(s.values.reduce((x, y) => x + y), 1000);
    });

    test('participants en double ignorés', () {
      final s = ExpenseMath.shares(exp('x', 100, 'a', ['b', 'b', 'a']));
      expect(s, {'a': 50, 'b': 50});
    });

    test('le payeur peut ne pas être concerné', () {
      final b = ExpenseMath.balances(expenses: [exp('resto de Bob', 3000, 'a', ['b'])]);
      expect(b, {'a': 3000, 'b': -3000});
    });
  });

  group('Soldes', () {
    test('la somme des soldes est toujours nulle', () {
      final r = math.Random(7);
      final people = ['a', 'b', 'c', 'd', 'e'];
      final expenses = [
        for (var i = 0; i < 60; i++)
          exp('e$i', 1 + r.nextInt(20000), people[r.nextInt(5)], {
            'a',
            for (final p in people)
              if (r.nextBool()) p,
          }.toList()),
      ];
      final b = ExpenseMath.balances(members: people, expenses: expenses);
      expect(b.values.reduce((x, y) => x + y), 0);
    });

    test('membres sans dépense présents à zéro', () {
      final b = ExpenseMath.balances(members: ['a', 'b', 'z'], expenses: [exp('x', 200, 'a', ['a', 'b'])]);
      expect(b, {'a': 100, 'b': -100, 'z': 0});
    });

    test('les remboursements enregistrés soldent les comptes', () {
      final expenses = [exp('plein', 6000, 'a', ['a', 'b', 'c'])];
      final settlements = [
        Settlement(id: 's1', from: 'b', to: 'a', amountCents: 2000, createdAt: DateTime.utc(2026)),
      ];
      final b = ExpenseMath.balances(expenses: expenses, settlements: settlements);
      expect(b, {'a': 2000, 'b': 0, 'c': -2000});
      expect(ExpenseMath.settle(b), [const Transfer(from: 'c', to: 'a', amountCents: 2000)]);
    });

    test('totaux, part consommée et avancée', () {
      final e = [exp('plein', 3000, 'a', ['a', 'b']), exp('péage', 990, 'b', ['a', 'b', 'c'])];
      expect(ExpenseMath.total(e), 3990);
      expect(ExpenseMath.consumedBy('a', e), 1500 + 330);
      expect(ExpenseMath.paidBy('b', e), 990);
    });
  });

  group('Qui doit quoi', () {
    test('un payeur pour trois', () {
      final b = ExpenseMath.balances(expenses: [exp('plein', 4500, 'a', ['a', 'b', 'c'])]);
      final t = ExpenseMath.settle(b);
      expect(t, unorderedEquals(const [
        Transfer(from: 'b', to: 'a', amountCents: 1500),
        Transfer(from: 'c', to: 'a', amountCents: 1500),
      ]));
    });

    test('déjà soldé : aucun virement', () {
      expect(ExpenseMath.settle({'a': 0, 'b': 0}), isEmpty);
      expect(ExpenseMath.settle({}), isEmpty);
    });

    test('nombre minimal de virements (sous-groupes à somme nulle)', () {
      // a doit 10 à b, c doit 7 à d, e doit 3 à f : 3 virements suffisent,
      // alors qu'un glouton naïf pourrait en faire plus.
      final b = {'a': -1000, 'b': 1000, 'c': -700, 'd': 700, 'e': -300, 'f': 300};
      final t = ExpenseMath.settle(b);
      expect(t.length, 3);
      expectSettles(b, t);
      expect(t, contains(const Transfer(from: 'a', to: 'b', amountCents: 1000)));
    });

    test('cas où le glouton ferait 4 virements au lieu de 3', () {
      // Créanciers +6 et +4, débiteurs -4, -3, -3. Le glouton (plus gros
      // débiteur vers plus gros créancier) fait 4 virements ; l'optimal en
      // fait 3 : {+4, -4} puis {+6, -3, -3}.
      final b = {'c1': 600, 'c2': 400, 'd1': -400, 'd2': -300, 'd3': -300};
      final t = ExpenseMath.settle(b);
      expect(t.length, 3);
      expectSettles(b, t);
    });

    test('résultat toujours soldant et ≤ n-1 virements (aléatoire)', () {
      final r = math.Random(3);
      for (var round = 0; round < 50; round++) {
        final n = 2 + r.nextInt(9);
        final people = [for (var i = 0; i < n; i++) 'p$i'];
        final expenses = [
          for (var i = 0; i < 1 + r.nextInt(12); i++)
            exp('e$i', 1 + r.nextInt(15000), people[r.nextInt(n)],
                {for (final p in people) if (r.nextInt(3) > 0) p, people[r.nextInt(n)]}.toList()),
        ];
        final b = ExpenseMath.balances(members: people, expenses: expenses);
        final t = ExpenseMath.settle(b);
        final nonZero = b.values.where((v) => v != 0).length;
        expect(t.length, lessThanOrEqualTo(math.max(0, nonZero - 1)));
        expectSettles(b, t);
      }
    });

    test('grands groupes (> 16) : repli glouton qui solde quand même', () {
      final r = math.Random(11);
      final people = [for (var i = 0; i < 25; i++) 'p$i'];
      final expenses = [
        for (var i = 0; i < 40; i++) exp('e$i', 100 + r.nextInt(9000), people[r.nextInt(25)], people),
      ];
      final b = ExpenseMath.balances(expenses: expenses);
      final t = ExpenseMath.settle(b);
      expectSettles(b, t);
      expect(t.length, lessThan(25));
    });

    test('soldes incohérents refusés', () {
      expect(() => ExpenseMath.settle({'a': 10, 'b': -5}), throwsArgumentError);
    });

    test('phrases au tutoiement', () {
      String nameOf(String u) => {'a': 'Max', 'b': 'Julie'}[u] ?? u;
      const t = Transfer(from: 'a', to: 'b', amountCents: 1250);
      expect(ExpenseMath.sentence(t, nameOf: nameOf, amount: '12,50 €'), 'Max doit 12,50 € à Julie');
      expect(ExpenseMath.sentence(t, nameOf: nameOf, amount: '12,50 €', me: 'a'), 'Tu dois 12,50 € à Julie');
      expect(ExpenseMath.sentence(t, nameOf: nameOf, amount: '12,50 €', me: 'b'), 'Max te doit 12,50 €');
    });
  });

  group('Saisie des montants', () {
    test('formats acceptés', () {
      expect(ExpenseMath.parseAmount('12,50'), 1250);
      expect(ExpenseMath.parseAmount('12.5'), 1250);
      expect(ExpenseMath.parseAmount('12'), 1200);
      expect(ExpenseMath.parseAmount(' 7,05 € '), 705);
      expect(ExpenseMath.parseAmount('1 234,56'), 123456);
      expect(ExpenseMath.parseAmount('1 234,56'), 123456);
      expect(ExpenseMath.parseAmount('1.234,56'), 123456);
      expect(ExpenseMath.parseAmount(',5'), 50);
      expect(ExpenseMath.parseAmount('12,'), 1200);
    });

    test('formats refusés', () {
      expect(ExpenseMath.parseAmount(''), isNull);
      expect(ExpenseMath.parseAmount('abc'), isNull);
      expect(ExpenseMath.parseAmount('0'), isNull);
      expect(ExpenseMath.parseAmount('0,00'), isNull);
      expect(ExpenseMath.parseAmount('-5'), isNull);
      expect(ExpenseMath.parseAmount('12,5x'), isNull);
      expect(ExpenseMath.parseAmount('99999999'), isNull);
    });
  });

  group('Sérialisation', () {
    test('dépense aller-retour (format RTDB)', () {
      final e = exp('Péage A75', 990, 'a', ['b', 'a'], cat: ExpenseCategory.peage);
      final raw = <Object?, Object?>{...e.toMap()};
      final back = Expense.fromMap('k1', raw)!;
      expect(back.id, 'k1');
      expect(back.label, 'Péage A75');
      expect(back.amountCents, 990);
      expect(back.paidBy, 'a');
      expect(back.participants, ['a', 'b']);
      expect(back.category, ExpenseCategory.peage);
      expect(back.createdAt, e.createdAt);
    });

    test('dépense invalide ignorée', () {
      expect(Expense.fromMap('x', {'amount': 100, 'paidBy': 'a'}), isNull, reason: 'sans participants');
      expect(Expense.fromMap('x', {'amount': -1, 'paidBy': 'a', 'participants': {'a': true}}), isNull);
      expect(Expense.fromMap('x', 'pas une map'), isNull);
    });

    test('remboursement aller-retour', () {
      final s = Settlement(id: 's', from: 'a', to: 'b', amountCents: 500, createdAt: DateTime.utc(2026, 1, 2));
      final back = Settlement.fromMap('s', <Object?, Object?>{...s.toMap()})!;
      expect([back.from, back.to, back.amountCents, back.createdAt], ['a', 'b', 500, s.createdAt]);
      expect(Settlement.fromMap('s', {'from': 'a', 'to': 'a', 'amount': 5}), isNull);
    });
  });
}
