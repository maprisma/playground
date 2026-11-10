import 'package:maprisma_playground_core/src/automaton.dart';
import 'package:test/test.dart';

Automaton grid(List<String> rows, {String rule = 'B3/S23', bool wrap = false}) {
  final a = Automaton(rows.first.length, rows.length, rule: Rule.parse(rule), wrap: wrap);
  for (var y = 0; y < rows.length; y++) {
    for (var x = 0; x < rows[y].length; x++) {
      if (rows[y][x] == 'O') a.set(x, y, 1);
    }
  }
  return a;
}

void main() {
  group('Rule', () {
    test('parses B/S and old S/B notation', () {
      expect(Rule.parse('B3/S23').notation, 'B3/S23');
      expect(Rule.parse('b36/s23').notation, 'B36/S23');
      expect(Rule.parse('23/3').notation, 'B3/S23');
      expect(Rule.parse('B2/S').notation, 'B2/S');
      expect(Rule.parse('B2/S/C3').states, 3);
    });
    test('refuses what is not a rule', () {
      for (final bad in ['', 'B9/S23', 'hello', 'B3/S23/C1', 'B3/S23/C99']) {
        expect(() => Rule.parse(bad), throwsFormatException, reason: bad);
      }
    });
    test('every named rule parses and is found by name', () {
      for (final e in namedRules.entries) {
        expect(ruleName(Rule.parse(e.value)), e.key);
      }
      expect(ruleName(Rule.parse('B1/S1')), isNull);
    });
  });

  group('Life', () {
    test('a blinker turns', () {
      final a = grid(['.....', '.....', '.OOO.', '.....', '.....']);
      a.step();
      expect(a.rows, ['.....', '..O..', '..O..', '..O..', '.....']);
      a.step();
      expect(a.rows, ['.....', '.....', '.OOO.', '.....', '.....']);
      expect(a.generation, 2);
      expect(a.history, [3, 3]);
    });
    test('a block stays and step says nothing changed', () {
      final a = grid(['....', '.OO.', '.OO.', '....']);
      expect(a.step(), isFalse);
      expect(a.population, 4);
    });
    test('a glider comes back around a wrapping grid', () {
      final a = Automaton(8, 8, rule: Rule.parse('B3/S23'));
      a.stamp(patterns.first, 0, 0);
      final start = a.rows;
      for (var i = 0; i < 32; i++) {
        a.step();
      }
      expect(a.rows, start); // 4 generations per cell, 8 cells
    });
    test('dead edges stop a glider', () {
      final a = Automaton(6, 6, rule: Rule.parse('B3/S23'), wrap: false);
      a.stamp(patterns.first, 2, 2);
      for (var i = 0; i < 40; i++) {
        a.step();
      }
      expect(a.population, 4); // it ends as a block in the corner
    });
  });

  test("Brian's Brain: alive, dying, dead", () {
    final a = grid(['....', '.OO.', '....', '....'], rule: 'B2/S/C3');
    a.step();
    expect(a.rows, ['.OO.', '.22.', '.OO.', '....']);
    a.step();
    expect(a.cell(1, 1), 0);
    expect(a.cell(1, 0), 2);
  });

  test('a rule with fewer states clears dying cells', () {
    final a = grid(['....', '.OO.', '....', '....'], rule: 'B2/S/C3');
    a.step();
    a.setRule(Rule.parse('B3/S23'));
    expect(a.rows.join(), isNot(contains('2')));
  });

  test('resize keeps the cells from the top left', () {
    final a = grid(['O..', '.O.', '..O']);
    a.resize(2, 4);
    expect(a.rows, ['O.', '.O', '..', '..']);
  });

  test('randomize with a seed repeats, clear empties', () {
    final a = Automaton(20, 20, rule: Rule.parse('B3/S23'))..randomize(.3, seed: 1);
    final b = Automaton(20, 20, rule: Rule.parse('B3/S23'))..randomize(.3, seed: 1);
    expect(a.rows, b.rows);
    expect(a.population, inInclusiveRange(60, 180));
    a.clear();
    expect(a.empty, isTrue);
    expect(a.generation, 0);
  });

  test('patterns are well formed', () {
    for (final p in patterns) {
      expect(p.cells, isNotEmpty, reason: p.name);
      expect(p.rows.every((r) => RegExp(r'^[.O]+$').hasMatch(r)), isTrue, reason: p.name);
    }
    final gun = patterns.firstWhere((p) => p.name == 'Gosper glider gun');
    expect(gun.cells.length, 36);
  });
}
