import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_playground_core/src/automaton.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';

const _ownRule = 'Own rule…';
const _paint = 'Draw cells';
const _densities = [.1, .2, .3, .4, .5];

/// The Automaton tab (new in Maprisma Playground, after Chess): a cellular automaton to draw on,
/// run, step and change the rule of while it runs.
class AutomatonPage extends StatefulWidget {
  const AutomatonPage({super.key, required this.host, required this.active});
  final Host host;

  /// The tab is in view: it only runs then (a hidden tab costs nothing).
  final bool active;
  @override
  State<AutomatonPage> createState() => _AutomatonPageState();
}

class _AutomatonPageState extends State<AutomatonPage> {
  late Automaton _grid;
  final _repaint = ValueNotifier(0);
  final _ruleText = TextEditingController();
  final _focus = FocusNode(debugLabel: 'automaton');
  Timer? _timer;
  bool _playing = false;
  bool _seeded = false;
  late int _speed, _cell;
  String _ruleChoice = "Conway's Life";
  String _tool = _paint;
  double _density = .3;
  String? _ruleError;
  int? _paintState; // while dragging: 1 draws, 0 erases

  @override
  void initState() {
    super.initState();
    final s = widget.host.settings;
    _speed = s.get('automaton_speed') as int;
    _cell = s.get('automaton_cell') as int;
    Rule rule;
    try {
      rule = Rule.parse(s.text('automaton_rule'));
    } on FormatException {
      rule = Rule.parse('B3/S23');
    }
    _ruleChoice = ruleName(rule) ?? _ownRule;
    _ruleText.text = rule.notation;
    _grid = Automaton(80, 50, rule: rule, wrap: s.flag('automaton_wrap'));
  }

  @override
  void didUpdateWidget(AutomatonPage old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _repaint.dispose();
    _ruleText.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save(Map<String, Object?> values) {
    try {
      widget.host.settings.update(values);
    } on Object {
      // not remembered: the next start uses the defaults
    }
  }

  // --- running -----------------------------------------------------------------------------

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_playing && widget.active) {
      _timer = Timer.periodic(Duration(microseconds: 1000000 ~/ _speed), (_) => _tick());
    }
  }

  void _tick() {
    final changed = _grid.step();
    _repaint.value++;
    if (!changed || _grid.empty) {
      // Nothing moves any more: stop, so a still life does not burn CPU.
      setState(() => _playing = false);
      _schedule();
    } else if (_grid.generation % 5 == 0) {
      setState(() {}); // the counters; the grid repaints on its own every tick
    }
  }

  void _playPause() {
    setState(() => _playing = !_playing);
    _schedule();
  }

  void _step() {
    if (_playing) _playPause();
    _grid.step();
    _repaint.value++;
    setState(() {});
  }

  void _clear() {
    _grid.clear();
    _repaint.value++;
    setState(() => _playing = false);
    _schedule();
  }

  void _random() {
    _grid.randomize(_density);
    _repaint.value++;
    setState(() {});
  }

  // --- the rule ------------------------------------------------------------------------------

  void _pickRule(String name) {
    setState(() => _ruleChoice = name);
    if (name == _ownRule) return; // the field below takes it
    _applyRule(namedRules[name]!);
  }

  void _applyRule(String text) {
    try {
      final rule = Rule.parse(text);
      _grid.setRule(rule);
      _ruleText.text = rule.notation;
      _save({'automaton_rule': rule.notation});
      setState(() {
        _ruleError = null;
        _ruleChoice = ruleName(rule) ?? _ownRule;
      });
      _repaint.value++;
    } on FormatException catch (e) {
      setState(() => _ruleError = e.message);
    }
  }

  // --- drawing -------------------------------------------------------------------------------

  (int, int)? _cellAt(Offset at) {
    final x = at.dx ~/ _cell, y = at.dy ~/ _cell;
    if (x < 0 || y < 0 || x >= _grid.width || y >= _grid.height) return null;
    return (x, y);
  }

  void _down(PointerDownEvent e) {
    _focus.requestFocus();
    final c = _cellAt(e.localPosition);
    if (c == null) return;
    final erase = e.buttons & kSecondaryMouseButton != 0;
    if (!erase && _tool != _paint) {
      final pattern = patterns.firstWhere((p) => p.name == _tool);
      // The pattern's middle goes where the click was.
      _grid.stamp(pattern, c.$1 - pattern.width ~/ 2, c.$2 - pattern.height ~/ 2);
      _paintState = null;
    } else {
      // A click on a live cell with the left button erases it, as in most Life programs.
      _paintState = erase ? 0 : (_grid.cell(c.$1, c.$2) == 1 ? 0 : 1);
      _grid.set(c.$1, c.$2, _paintState!);
    }
    _repaint.value++;
    setState(() {});
  }

  void _move(PointerMoveEvent e) {
    if (_paintState == null) return;
    final c = _cellAt(e.localPosition);
    if (c == null) return;
    // Fill the cells between two pointer events, so a fast stroke stays a line.
    final last = _cellAt(e.localPosition - e.delta) ?? c;
    final steps = max((c.$1 - last.$1).abs(), (c.$2 - last.$2).abs());
    for (var i = 0; i <= steps; i++) {
      final t = steps == 0 ? 1.0 : i / steps;
      _grid.set((last.$1 + (c.$1 - last.$1) * t).round(), (last.$2 + (c.$2 - last.$2) * t).round(), _paintState!);
    }
    _repaint.value++;
  }

  void _scroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !HardwareKeyboard.instance.isControlPressed) return;
    final next = (_cell + (e.scrollDelta.dy < 0 ? 1 : -1)).clamp(4, 24);
    if (next == _cell) return;
    setState(() => _cell = next);
    _save({'automaton_cell': next});
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.space) {
      _playPause();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      _step();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- the page ------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final controls = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Choice<String>(
          value: _ruleChoice,
          items: [...namedRules.keys, _ownRule],
          label: (n) => n == _ownRule ? n : '$n  ${namedRules[n]}',
          onChanged: _pickRule,
          tooltip: 'Rule',
        ),
        SizedBox(
          width: 150,
          child: TextField(
            controller: _ruleText,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: 'B3/S23',
              errorText: _ruleError == null ? null : '',
              errorStyle: const TextStyle(height: 0, fontSize: 0),
            ),
            onSubmitted: _applyRule,
            onTapOutside: (_) => FocusScope.of(context).unfocus(),
          ),
        ),
        SmallButton('Use rule', onPressed: () => _applyRule(_ruleText.text), tooltip: 'B: neighbours a dead cell '
            'needs to be born, S: neighbours a live cell needs to stay, C: states of a Generations rule'),
        const SizedBox(width: 8),
        Choice<String>(
          value: _tool,
          items: [_paint, ...patterns.map((p) => p.name)],
          label: (n) => n,
          onChanged: (n) => setState(() => _tool = n),
          tooltip: 'What a click does: draw (the right button erases) or place a pattern',
        ),
      ],
    );

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ActionButton(_playing ? 'Pause' : 'Play', onPressed: _playPause, tooltip: 'Space'),
        SmallButton('Step', icon: Icons.skip_next, onPressed: _step, tooltip: 'One generation (→)'),
        SmallButton('Clear', onPressed: _clear),
        SmallButton('Random', onPressed: _random, tooltip: 'Fill at random with the density beside it'),
        Choice<double>(
          value: _density,
          items: _densities,
          label: (d) => '${(d * 100).round()} %',
          onChanged: (d) => setState(() => _density = d),
          tooltip: 'Density of a random fill',
        ),
        const SizedBox(width: 8),
        Text('Speed', style: TextStyle(fontSize: 13, color: look.fg)),
        SizedBox(
          width: 160,
          child: Slider(
            value: _speed.toDouble(),
            min: 1,
            max: 60,
            divisions: 59,
            label: '$_speed / s',
            onChanged: (v) {
              setState(() => _speed = v.round());
              _schedule();
            },
            onChangeEnd: (v) => _save({'automaton_speed': v.round()}),
          ),
        ),
        Text('$_speed / s', style: TextStyle(fontSize: 12, color: look.muted)),
        const SizedBox(width: 8),
        CheckLabel(
          label: 'Edges wrap',
          value: _grid.wrap,
          tooltip: 'On: what leaves at one edge comes back at the other. Off: outside the grid is dead.',
          onChanged: (v) {
            setState(() => _grid.wrap = v);
            _save({'automaton_wrap': v});
          },
        ),
      ],
    );

    final status = Row(
      children: [
        Text(
          'Generation ${_grid.generation}  ·  ${_grid.population} alive  ·  ${_grid.width} × ${_grid.height} cells',
          style: TextStyle(fontSize: 12, color: look.muted),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 22,
            child: ValueListenableBuilder(
              valueListenable: _repaint,
              builder: (_, _, _) => CustomPaint(painter: _Sparkline(List.of(_grid.history), look.accent)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text('Ctrl + wheel: cell size ($_cell px)', style: TextStyle(fontSize: 12, color: look.dim)),
      ],
    );

    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(17, 6, 17, 17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TabIntro(
              'Automaton',
              'A cellular automaton: each cell lives or dies by how many of its eight neighbours are alive. Draw '
                  'cells with the mouse (the right button erases), place a pattern, or fill at random, then Play. '
                  'The rule can be changed while it runs: B is how many neighbours bring a cell to life, S how many '
                  'keep it alive.',
            ),
            vgap,
            controls,
            vgap,
            actions,
            vgap,
            status,
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final cols = max(1, box.maxWidth ~/ _cell), rows = max(1, box.maxHeight ~/ _cell);
                  if (cols != _grid.width || rows != _grid.height) {
                    _grid.resize(cols, rows);
                    // The size in the status line.
                    WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
                  }
                  if (!_seeded) {
                    // The first fill once the grid has its real size (after this layout).
                    _seeded = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      if (_grid.empty) _grid.randomize(_density);
                      _repaint.value++;
                      setState(() {});
                    });
                  }
                  return Listener(
                    onPointerDown: _down,
                    onPointerMove: _move,
                    onPointerUp: (_) => _paintState = null,
                    onPointerSignal: _scroll,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.precise,
                      child: GestureDetector(
                        onSecondaryTapDown: (_) {}, // keeps the right button for erasing
                        child: CustomPaint(
                          size: Size(cols * _cell.toDouble(), rows * _cell.toDouble()),
                          painter: _GridPainter(_grid, _cell.toDouble(), look, corners(context), _repaint),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The cells: live ones in the accent colour, dying ones fading towards the background, on a mat
/// with faint grid lines when the cells are big enough to see them.
class _GridPainter extends CustomPainter {
  _GridPainter(this.grid, this.cell, this.look, this.radius, Listenable repaint) : super(repaint: repaint);
  final Automaton grid;
  final double cell;
  final Look look;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & Size(grid.width * cell, grid.height * cell);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(area, Radius.circular(radius)));
    canvas.drawRect(area, Paint()..color = look.fg.withValues(alpha: .04));
    if (cell >= 8) {
      final line = Paint()
        ..color = look.fg.withValues(alpha: .06)
        ..strokeWidth = 1;
      for (var x = 1; x < grid.width; x++) {
        canvas.drawLine(Offset(x * cell, 0), Offset(x * cell, area.height), line);
      }
      for (var y = 1; y < grid.height; y++) {
        canvas.drawLine(Offset(0, y * cell), Offset(area.width, y * cell), line);
      }
    }
    final states = grid.rule.states;
    final paths = List.generate(states, (_) => Path());
    final inset = cell >= 8 ? 1.0 : 0.0;
    final r = Radius.circular(cell >= 10 ? 2 : 0);
    for (var y = 0; y < grid.height; y++) {
      for (var x = 0; x < grid.width; x++) {
        final c = grid.cell(x, y);
        if (c == 0) continue;
        paths[c].addRRect(
          RRect.fromLTRBR(x * cell + inset, y * cell + inset, (x + 1) * cell - inset, (y + 1) * cell - inset, r),
        );
      }
    }
    for (var s = 1; s < states; s++) {
      // State 1 is alive; the dying states fade from the accent to the background.
      final t = states <= 2 ? 0.0 : (s - 1) / (states - 1);
      final color = s == 1 ? look.accent : Color.lerp(look.yellow, look.bg, t * .8)!;
      canvas.drawPath(paths[s], Paint()..color = color);
    }
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(area.deflate(.5), Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = look.fg.withValues(alpha: .12),
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.cell != cell || old.look != look || old.grid != grid;
}

/// The population over the last generations.
class _Sparkline extends CustomPainter {
  _Sparkline(this.values, this.color);
  final List<int> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final top = values.reduce(max).toDouble(), bottom = values.reduce(min).toDouble();
    final span = max(1.0, top - bottom);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (Automaton.historyLength - 1);
      final y = size.height - 2 - (values[i] - bottom) / span * (size.height - 4);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_Sparkline old) => true;
}
