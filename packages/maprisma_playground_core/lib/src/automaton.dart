import 'i18n.dart';
import 'dart:math';
import 'dart:typed_data';

/// The Automaton tab's engine: a grid of cells and a Life-like rule.
///
/// A rule is written `B<born>/S<survive>`, optionally `/C<states>` for "Generations" rules (Brian's
/// Brain is B2/S/C3): a live cell that does not survive starts dying and goes through the
/// states 2 … C-1 before it is dead; only state 1 counts as a live neighbour.

/// A rule in B/S(/C) notation.
final class Rule {
  Rule(Iterable<int> born, Iterable<int> survive, {this.states = 2})
    : born = Set.unmodifiable(born),
      survive = Set.unmodifiable(survive) {
    if (states < 2 || states > 25) throw FormatException(tr("2 to 25 states"));
  }

  final Set<int> born, survive;
  final int states;

  static final _pattern = RegExp(r'^B([0-8]*)/S([0-8]*)(?:/C([0-9]{1,2}))?$', caseSensitive: false);

  /// "B3/S23", "b36/s23", "B2/S/C3"; also the old "23/3" (survive/born). FormatException when not.
  static Rule parse(String text) {
    final t = text.replaceAll(' ', '');
    final m = _pattern.firstMatch(t);
    if (m != null) {
      final states = m[3] == null ? 2 : int.parse(m[3]!);
      return Rule(_digits(m[1]!), _digits(m[2]!), states: states);
    }
    final old = RegExp(r'^([0-8]*)/([0-8]+)$').firstMatch(t);
    if (old != null) return Rule(_digits(old[2]!), _digits(old[1]!));
    throw FormatException(tr("Not a rule: write it as B3/S23 (born with / survive with neighbours)."), text);
  }

  static Iterable<int> _digits(String s) => s.split('').map(int.parse);

  /// The rule written the standard way: B3/S23, B2/S/C3.
  String get notation {
    String list(Set<int> s) => (s.toList()..sort()).join();
    return 'B${list(born)}/S${list(survive)}${states > 2 ? '/C$states' : ''}';
  }

  @override
  bool operator ==(Object other) => other is Rule && other.notation == notation;
  @override
  int get hashCode => notation.hashCode;
  @override
  String toString() => notation;
}

/// The rules offered by name (their usual names).
final Map<String, String> namedRules = {
  "Conway's Life": 'B3/S23',
  'HighLife': 'B36/S23',
  'Seeds': 'B2/S',
  'Day & Night': 'B3678/S34678',
  'Maze': 'B3/S12345',
  'Life without Death': 'B3/S012345678',
  'Replicator': 'B1357/S1357',
  "Brian's Brain": 'B2/S/C3',
  'Star Wars': 'B2/S345/C4',
  // Materials: plastics and adhesives, shown (not measured) with simple rules.
  'Plastics: demixing of a blend': 'B4678/S35678',
  'Plastics: crystallization': 'B1/S012345678',
  'Adhesive: curing': 'B35678/S012345678',
};

/// The named rules of the materials group (for a heading in the menu).
bool isMaterialsRule(String name) => name.startsWith('Plastics: ') || name.startsWith('Adhesive: ');

/// The static mixer of a two-component adhesive is not a rule: each generation is one mixer element
/// (see [Automaton.mixing]).
const mixerName = 'Adhesive: static mixer (2K)';

/// The name of a rule, or null for one typed by the user.
String? ruleName(Rule rule) {
  for (final e in namedRules.entries) {
    if (Rule.parse(e.value) == rule) return e.key;
  }
  return null;
}

/// A pattern to stamp, as rows of '.' (dead) and 'O' (alive).
final class CellPattern {
  const CellPattern(this.name, this.rows, {this.about = ''});
  final String name, about;
  final List<String> rows;
  int get width => rows.fold(0, (w, r) => max(w, r.length));
  int get height => rows.length;

  /// The live cells as (x, y) from the top left.
  Iterable<(int, int)> get cells sync* {
    for (var y = 0; y < rows.length; y++) {
      for (var x = 0; x < rows[y].length; x++) {
        if (rows[y][x] == 'O') yield (x, y);
      }
    }
  }
}

List<CellPattern> get patterns => <CellPattern>[
  CellPattern('Glider', ['.O.', '..O', 'OOO'], about: tr("flies diagonally, 4 generations per step")),
  CellPattern('Lightweight spaceship', ['.O..O', 'O....', 'O...O', 'OOOO.'], about: tr("flies sideways")),
  CellPattern('Pulsar', [
    '..OOO...OOO..',
    '.............',
    'O....O.O....O',
    'O....O.O....O',
    'O....O.O....O',
    '..OOO...OOO..',
    '.............',
    '..OOO...OOO..',
    'O....O.O....O',
    'O....O.O....O',
    'O....O.O....O',
    '.............',
    '..OOO...OOO..',
  ], about: tr("blinks with period 3")),
  CellPattern('Gosper glider gun', [
    '........................O...........',
    '......................O.O...........',
    '............OO......OO............OO',
    '...........O...O....OO............OO',
    'OO........O.....O...OO..............',
    'OO........O...O.OO....O.O...........',
    '..........O.....O.......O...........',
    '...........O...O....................',
    '............OO......................',
  ], about: tr("shoots a glider every 30 generations")),
  CellPattern('R-pentomino', ['.OO', 'OO.', '.O.'], about: tr("five cells, settles after 1103 generations")),
  CellPattern('Acorn', ['.O.....', '...O...', 'OO..OOO'], about: tr("seven cells, 5206 generations")),
  CellPattern('Diehard', ['......O.', 'OO......', '.O...OOO'], about: tr("vanishes after 130 generations")),
];

/// Small shapes that only "Try it" uses (not in the pattern menu).
const setupPatterns = <CellPattern>[
  CellPattern('Blinker', ['OOO'], about: 'three cells in a row: an oscillator of period 2'),
  CellPattern('Seeds pair', ['OO'], about: 'two cells side by side: the seed of an explosion in Seeds'),
];

/// A pattern by its name (the menu's or a setup one), or null.
CellPattern? findPattern(String name) {
  for (final p in [...patterns, ...setupPatterns]) {
    if (p.name == name) return p;
  }
  return null;
}

/// The grid and its history. Cells: 0 dead, 1 alive, 2 … states-1 dying (Generations rules).
final class Automaton {
  Automaton(this.width, this.height, {required this.rule, this.wrap = true})
    : _cells = Uint8List(width * height),
      _ages = Uint16List(width * height),
      _died = Uint8List(width * height) {
    if (width < 1 || height < 1) throw ArgumentError(tr("empty grid"));
  }

  int width, height;
  Rule rule;
  bool wrap;
  Uint8List _cells;

  /// For each live cell: the generations it has been alive (1: born in the last one). It colours
  /// the cells: what moves is young, what stands still grows old.
  Uint16List _ages;

  /// 1 where a live cell died in the last generation (its trace shows where things vanish).
  Uint8List _died;
  int generation = 0;

  /// The static mixer (2K adhesive): instead of the rule, each generation is one mixer element. It
  /// cuts the flow in two and stacks the halves, so the layers of resin (live cells) and hardener
  /// (dead cells) double in number each time: 2, 4, 8, 16 … (the striations of mixing theory).
  bool mixing = false;

  /// Population after each of the last [historyLength] generations (for the sparkline).
  final List<int> history = [];
  static const historyLength = 200;

  int cell(int x, int y) => _cells[y * width + x];

  /// Generations a live cell has been alive (1: just born); 0 for a cell that is not alive.
  int age(int x, int y) => _ages[y * width + x];

  /// Whether a cell was alive before the last generation and is not now.
  bool justDied(int x, int y) => _died[y * width + x] == 1;

  void set(int x, int y, int state) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    final i = y * width + x;
    final v = state.clamp(0, rule.states - 1);
    if (v == 1 && _cells[i] != 1) _ages[i] = 1; // drawn: a newborn
    if (v != 1) _ages[i] = 0;
    _died[i] = 0;
    _cells[i] = v;
  }

  int get population {
    var n = 0;
    for (final c in _cells) {
      if (c == 1) n++;
    }
    return n;
  }

  bool get empty => !_cells.any((c) => c != 0);

  /// One generation. Returns whether anything changed.
  bool step() {
    if (mixing) return _mixStep();
    final next = Uint8List(_cells.length);
    final ages = Uint16List(_cells.length);
    final died = Uint8List(_cells.length);
    var changed = false;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final c = _cells[i];
        int n;
        if (c == 0 || c == 1) {
          n = _neighbours(x, y);
        } else {
          n = 0;
        }
        final int v;
        if (c == 0) {
          v = rule.born.contains(n) ? 1 : 0;
        } else if (c == 1) {
          v = rule.survive.contains(n) ? 1 : (rule.states > 2 ? 2 : 0);
        } else {
          v = c + 1 >= rule.states ? 0 : c + 1;
        }
        next[i] = v;
        if (v == 1) {
          ages[i] = c == 1 ? min(_ages[i] + 1, 65535) : 1;
        } else if (c == 1) {
          died[i] = 1;
        }
        if (v != c) changed = true;
      }
    }
    _cells = next;
    _ages = ages;
    _died = died;
    generation++;
    _remember();
    return changed;
  }

  /// One mixer element: every row takes the one at twice its distance from the top, so the grid
  /// holds two squeezed copies of itself on top of each other: twice the layers, each half as thick.
  bool _mixStep() {
    // Mixed down to one cell per layer: another element would only lose layers (the grid is too
    // coarse to show thinner ones), so the mixer stops here.
    final before = layers;
    if (before * 2 > height) return false;
    final next = Uint8List(_cells.length);
    final ages = Uint16List(_cells.length);
    final died = Uint8List(_cells.length);
    var changed = false;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final from = ((2 * y) % height) * width + x;
        final v = _cells[from] == 1 ? 1 : 0;
        next[i] = v;
        if (v == 1) {
          ages[i] = _cells[i] == 1 ? min(_ages[i] + 1, 65535) : 1;
        } else if (_cells[i] == 1) {
          died[i] = 1;
        }
        if (v != _cells[i]) changed = true;
      }
    }
    _cells = next;
    _ages = ages;
    _died = died;
    generation++;
    _remember();
    return changed;
  }

  /// The two components before mixing: resin (live cells) in the top half, hardener below.
  void fillHalves() {
    clear();
    for (var y = 0; y < height ~/ 2; y++) {
      for (var x = 0; x < width; x++) {
        _cells[y * width + x] = 1;
        _ages[y * width + x] = 1;
      }
    }
    history.add(population);
  }

  /// The layers of resin and hardener, counted down the first column (the mixer's stripes).
  int get layers {
    if (height == 0) return 0;
    var n = 1;
    for (var y = 1; y < height; y++) {
      if ((_cells[y * width] == 1) != (_cells[(y - 1) * width] == 1)) n++;
    }
    return n;
  }

  int _neighbours(int x, int y) {
    var n = 0;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        var nx = x + dx, ny = y + dy;
        if (wrap) {
          nx = (nx + width) % width;
          ny = (ny + height) % height;
        } else if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
          continue;
        }
        if (_cells[ny * width + nx] == 1) n++;
      }
    }
    return n;
  }

  void _remember() {
    history.add(population);
    if (history.length > historyLength) history.removeAt(0);
  }

  void clear() {
    _cells = Uint8List(width * height);
    _ages = Uint16List(width * height);
    _died = Uint8List(width * height);
    generation = 0;
    history.clear();
  }

  /// Random live cells with this density (0 … 1); a seed makes it repeatable.
  void randomize(double density, {int? seed}) {
    final r = Random(seed);
    for (var i = 0; i < _cells.length; i++) {
      _cells[i] = r.nextDouble() < density ? 1 : 0;
      _ages[i] = _cells[i];
      _died[i] = 0;
    }
    generation = 0;
    history
      ..clear()
      ..add(population);
  }

  /// Stamp a pattern with its top left at (x, y); it wraps when the edges do.
  void stamp(CellPattern pattern, int x, int y) {
    for (final (px, py) in pattern.cells) {
      var cx = x + px, cy = y + py;
      if (wrap) {
        cx %= width;
        cy %= height;
      }
      set(cx, cy, 1);
    }
  }

  /// A new size; the cells stay where they are from the top left (what falls outside is lost).
  void resize(int newWidth, int newHeight) {
    if (newWidth < 1 || newHeight < 1 || (newWidth == width && newHeight == height)) return;
    final next = Uint8List(newWidth * newHeight);
    final ages = Uint16List(newWidth * newHeight);
    final died = Uint8List(newWidth * newHeight);
    for (var y = 0; y < min(height, newHeight); y++) {
      for (var x = 0; x < min(width, newWidth); x++) {
        next[y * newWidth + x] = _cells[y * width + x];
        ages[y * newWidth + x] = _ages[y * width + x];
        died[y * newWidth + x] = _died[y * width + x];
      }
    }
    _cells = next;
    _ages = ages;
    _died = died;
    width = newWidth;
    height = newHeight;
  }

  /// A new rule; cells in states the new rule does not have become dead.
  void setRule(Rule next) {
    rule = next;
    for (var i = 0; i < _cells.length; i++) {
      if (_cells[i] >= next.states) _cells[i] = 0;
    }
  }

  /// The grid as text rows ('.' dead, 'O' alive, digits for dying states): for tests.
  List<String> get rows => [
    for (var y = 0; y < height; y++)
      String.fromCharCodes([
        for (var x = 0; x < width; x++)
          switch (cell(x, y)) {
            0 => 46, // .
            1 => 79, // O
            final s => 48 + s,
          },
      ]),
  ];
}
