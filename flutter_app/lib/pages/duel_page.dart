import 'package:maprisma_playground_core/maprisma_playground_core.dart' show tr, trf;

import 'dart:math';

import 'package:flutter/material.dart';

import '../app.dart';
import '../backend.dart';
import '../contestants.dart';
import '../theme.dart';
import '../widgets.dart';

String get duelPrompt => tr("Explain in three sentences why the sky is blue, for a ten-year-old.");

/// DuelTab: one question to two agents or local models; you pick the better answer and the score
/// is kept. Blind: who wrote which shows only after the vote.
class DuelPage extends StatefulWidget {
  const DuelPage({super.key, required this.host, required this.playground});
  final Host host;
  final Playground playground;
  @override
  State<DuelPage> createState() => _DuelPageState();
}

class _DuelPageState extends State<DuelPage> {
  String _defaultPrompt = duelPrompt;
  final _prompt = TextEditingController(text: duelPrompt);
  String? _a, _b; // contestant ids
  bool _blind = true;
  List<Contestant>? _pair;
  List<Map<String, dynamic>?> _answers = [null, null];
  List<String?> _errors = [null, null];
  final List<Job?> _jobs = [null, null];
  bool _voted = false;
  String _score = '';
  int _run = 0;

  @override
  void didUpdateWidget(covariant DuelPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final translated = duelPrompt;
    if (_prompt.text == _defaultPrompt) _prompt.text = translated;
    _defaultPrompt = translated;
  }

  @override
  void initState() {
    super.initState();
    widget.playground.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _run++; // a side still to come does not start any more
    widget.playground.removeListener(_changed);
    for (final j in _jobs) {
      j?.cancel();
    }
    _prompt.dispose();
    super.dispose();
  }

  /// What was chosen stays chosen; else the first and the second one.
  Contestant? _pick(List<Contestant> all, String? id, int fallback) {
    if (all.isEmpty) return null;
    return all.firstWhere((c) => c.id == id, orElse: () => all[min(fallback, all.length - 1)]);
  }

  bool get _answered => _pair != null && [0, 1].every((s) => _answers[s] != null || _errors[s] != null);

  Future<void> _ask() async {
    final all = widget.playground.contestants();
    final a = _pick(all, _a, 0), b = _pick(all, _b, 1);
    final prompt = _prompt.text.trim();
    if (a == null || b == null || prompt.isEmpty) return;
    final oneByOne = await widget.playground.gpuGuard(context, [a, b]);
    if (oneByOne == null || !mounted) return;
    for (final j in _jobs) {
      j?.cancel();
    }
    final pair = [a, b];
    if (_blind) pair.shuffle();
    final run = ++_run;
    setState(() {
      _pair = pair;
      _answers = [null, null];
      _errors = [null, null];
      _voted = false;
      _score = '';
    });
    final backend = widget.playground.backend;
    Future<void> side(int s) async {
      if (run != _run || !mounted) return;
      _jobs[s] = backend.start('ask.run', {'target': pair[s].target, 'prompt': prompt});
      try {
        final answer = await _jobs[s]!.result;
        if (run == _run && mounted) setState(() => _answers[s] = answer);
      } on CoreFailure catch (e) {
        if (run == _run && mounted) setState(() => _errors[s] = e.cancelled ? tr("Stopped.") : e.message);
      }
      if (oneByOne && run == _run && mounted) {
        try {
          await backend.call('local.make_room', {'target': pair[s].target});
        } on Object {
          // nothing to unload
        }
      }
    }

    if (oneByOne) {
      await side(0);
      await side(1);
    } else {
      await Future.wait([side(0), side(1)]);
    }
  }

  String _name(int s, {bool reveal = false}) =>
      _blind && !reveal && !_voted ? (s == 0 ? tr("Left") : tr("Right")) : _pair![s].name;

  String _title(int s) {
    final answer = _answers[s];
    final showLine = answer != null && (!_blind || _voted);
    return showLine ? '${_name(s)} · ${resultLine(answer, rate: !_pair![s].isAgent)}' : _name(s);
  }

  /// The names (and times) show; this pair's score goes up.
  void _vote(int? winner) {
    final pair = _pair!;
    setState(() => _voted = true);
    final ids = [pair[0].id, pair[1].id]..sort();
    final first = ids[0], second = ids[1];
    if (first == second) {
      setState(() => _score = tr("The same one twice: no score is kept."));
      return;
    }
    final scores = Map<String, Object?>.from(widget.host.settings.get('duel_scores') as Map);
    final key = '$first|$second';
    final stored = scores[key];
    final score = stored is List && stored.length == 3 && stored.every((v) => v is int)
        ? List<int>.from(stored)
        : [0, 0, 0];
    if (winner == null) {
      score[1]++;
    } else {
      score[pair[winner].id == first ? 0 : 2]++;
    }
    try {
      widget.host.settings.update({
        'duel_scores': {...scores, key: score},
      });
    } on Object {
      // the score is shown but not kept
    }
    final names = {for (final c in pair) c.id: c.name};
    setState(
      () => _score = trf("Score: {0} {1} · ties {2} · {3} {4}", [
        names[first],
        score[0],
        score[1],
        names[second],
        score[2],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final all = widget.playground.contestants();
    final a = _pick(all, _a, 0), b = _pick(all, _b, 1);
    Widget card(int s) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: look.fg.withValues(alpha: .03),
        border: Border.all(color: look.fg.withValues(alpha: .10)),
        borderRadius: BorderRadius.circular(corners(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(_title(s)),
          const SizedBox(height: 6),
          AnswerText(
            _errors[s] ??
                (_answers[s] == null
                    ? tr('asking…')
                    : '${_answers[s]!['text'] ?? ''}'.isEmpty
                    ? '${_answers[s]!['error'] ?? ''}'
                    : '${_answers[s]!['text']}'),
            error: _errors[s] != null,
          ),
        ],
      ),
    );
    return PageScroll(
      children: [
        TabIntro(
          tr("Head to head"),
          tr(
            "One question to two agents or local models; you pick the better answer and the score is kept. Blind: you see which one wrote which only after you have chosen.",
          ),
        ),
        vgap,
        PromptField(controller: _prompt, onSubmit: _ask),
        vgap,
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Choice<Contestant>(
              value: a,
              items: all,
              label: (c) => c.name,
              empty: tr("No agent is set up"),
              onChanged: (c) => setState(() => _a = c.id),
            ),
            Text(tr('against'), style: TextStyle(fontSize: 13, color: look.fg)),
            Choice<Contestant>(
              value: b,
              items: all,
              label: (c) => c.name,
              empty: tr("No agent is set up"),
              onChanged: (c) => setState(() => _b = c.id),
            ),
            CheckLabel(label: tr("Blind"), value: _blind, onChanged: (v) => setState(() => _blind = v)),
          ],
        ),
        vgap,
        ActionButton(tr("Ask"), onPressed: all.isEmpty ? null : _ask, tooltip: tr("Both get the same question")),
        if (_pair != null) ...[
          vgap,
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: card(0)),
                const SizedBox(width: gap),
                Expanded(child: card(1)),
              ],
            ),
          ),
        ],
        if (_answered && !_voted) ...[
          vgap,
          Wrap(
            spacing: 8,
            children: [
              SmallButton(tr("Left is better"), onPressed: () => _vote(0)),
              SmallButton(tr("A tie"), onPressed: () => _vote(null)),
              SmallButton(tr("Right is better"), onPressed: () => _vote(1)),
            ],
          ),
        ],
        if (_score.isNotEmpty) ...[vgap, Hint(_score)],
      ],
    );
  }
}
