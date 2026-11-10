import 'package:maprisma_playground_core/src/automaton.dart';
import 'package:maprisma_playground_core/src/automaton_info.dart';
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

  group('ages and traces (the colours)', () {
    test('a block grows old, a blinker stays young, its lost ends leave a trace', () {
      final block = grid(['....', '.OO.', '.OO.', '....']);
      expect(block.age(1, 1), 1);
      for (var i = 0; i < 5; i++) {
        block.step();
      }
      expect(block.age(1, 1), 6);
      final blinker = grid(['.....', '.....', '.OOO.', '.....', '.....']);
      blinker.step();
      expect(blinker.age(2, 2), 2, reason: 'the middle stays');
      expect(blinker.age(2, 1), 1, reason: 'the new ends are born');
      expect(blinker.justDied(1, 2), isTrue, reason: 'the old ends died');
      expect(blinker.justDied(2, 2), isFalse);
      blinker.step();
      expect(blinker.justDied(1, 2), isFalse, reason: 'a trace lasts one generation');
    });
    test('drawing makes a newborn, erasing and clear leave no age', () {
      final a = Automaton(4, 4, rule: Rule.parse('B3/S23'));
      a.set(1, 1, 1);
      expect(a.age(1, 1), 1);
      a.set(1, 1, 0);
      expect(a.age(1, 1), 0);
      a.randomize(.5, seed: 2);
      a.clear();
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          expect(a.age(x, y), 0);
        }
      }
    });
  });

  test('every rule and pattern has its explanation, and every "Try it" can be set up', () {
    for (final name in [...namedRules.keys, mixerName]) {
      expect(ruleInfo, contains(name), reason: name);
    }
    expect(ruleInfo, contains('own'));
    for (final p in patterns) {
      expect(patternInfo, contains(p.name), reason: p.name);
    }
    expect(patternInfo, contains('draw'));
    for (final info in [...ruleInfo.values, ...patternInfo.values]) {
      final s = info.setup;
      if (s.rule != null) Rule.parse(s.rule!);
      if (s.pattern != null) expect(findPattern(s.pattern!), isNotNull, reason: s.pattern);
      expect(s.density != null && s.pattern != null, isFalse, reason: 'a fill or a pattern, not both');
      expect(info.links, isNotEmpty, reason: info.what);
      for (final (title, url) in info.links) {
        expect(url, startsWith('https://en.wikipedia.org/wiki/'), reason: title);
      }
    }
  });

  group('the static mixer', () {
    test('each element doubles the layers until they are one cell thin', () {
      final a = Automaton(16, 16, rule: Rule.parse('B3/S23'))..mixing = true;
      a.fillHalves();
      expect(a.layers, 2);
      for (final n in [4, 8, 16]) {
        expect(a.step(), isTrue);
        expect(a.layers, n);
        expect(a.population, 128, reason: 'as much resin as before: half of the grid');
      }
      expect(a.step(), isFalse, reason: 'one cell per layer: mixed, the mixer stops');
      expect(a.layers, 16);
    });
    test('the materials rules are named and grouped', () {
      for (final name in ['Plastics: demixing of a blend', 'Plastics: crystallization', 'Adhesive: curing']) {
        expect(ruleName(Rule.parse(namedRules[name]!)), name);
        expect(isMaterialsRule(name), isTrue);
      }
      expect(isMaterialsRule("Conway's Life"), isFalse);
    });
  });

  group('the second ⓘ and Read more (AI Playground 0.4.8–0.4.10)', () {
    test('mergeLinks keeps the order and each address once', () {
      final merged = mergeLinks([
        [('A', 'https://a'), ('B', 'https://b')],
        [('B again', 'https://b'), ('C', 'https://c')],
      ]);
      expect(merged, [('A', 'https://a'), ('B', 'https://b'), ('C', 'https://c')]);
    });

    test('Draw cells takes what to look for, what to try and Try it from the scenario', () {
      final draw = patternInfo['draw']!, high = ruleInfo['HighLife']!;
      final info = drawingInfo('HighLife');
      expect(info.what, draw.what);
      expect(info.watch, high.watch);
      expect(info.tryIt, high.tryIt);
      expect(info.setup, same(high.setup));
      // The scenario's links first, then the drawing's, each address once.
      expect(info.links.take(high.links.length), high.links);
      expect(info.links.map((l) => l.$2).toSet().length, info.links.length);
      expect(info.links.map((l) => l.$2), containsAll(draw.links.map((l) => l.$2)));
    });

    test('Draw cells with an own rule keeps the drawing\'s own texts', () {
      final draw = patternInfo['draw']!;
      final info = drawingInfo('own');
      expect([info.watch, info.tryIt], [draw.watch, draw.tryIt]);
      expect(info.setup, same(draw.setup));
      expect(info.links.take(ruleInfo['own']!.links.length), ruleInfo['own']!.links);
    });

    test('a pattern window lists its links, then the scenario\'s', () {
      final glider = patternInfo['Glider']!;
      final info = patternWindowInfo('Glider', "Brian's Brain");
      expect(info.what, glider.what);
      expect(info.links.first, glider.links.first);
      expect(info.links.map((l) => l.$2), containsAll(ruleInfo["Brian's Brain"]!.links.map((l) => l.$2)));
      expect(info.links.every((l) => l.$2.startsWith('https://')), isTrue);
    });

    test('the Life note: not under B3/S23 or B36/S23, always in the static mixer', () {
      expect(needsPatternNote('B3/S23'), isFalse);
      expect(needsPatternNote('B36/S23'), isFalse);
      expect(needsPatternNote('B2/S'), isTrue);
      expect(needsPatternNote('B3/S23', mixing: true), isTrue);
      expect(patternNote, contains('{0}'));
    });

    test('every scenario has a key the windows can find', () {
      for (final name in [...namedRules.keys, mixerName, 'own']) {
        expect(scenarioInfo(name), same(ruleInfo[name]), reason: name);
      }
    });
  });
}
