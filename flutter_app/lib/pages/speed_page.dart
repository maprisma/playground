import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../contestants.dart';
import '../widgets.dart';

const speedPrompt =
    'Write a Python function that tells whether a string is a palindrome, ignoring case and spaces. '
    'Answer with the code only.';

/// SpeedTab: the same question to several agents and local models at once.
class SpeedPage extends StatefulWidget {
  const SpeedPage({super.key, required this.host, required this.playground});
  final Host host;
  final Playground playground;
  @override
  State<SpeedPage> createState() => _SpeedPageState();
}

class _SpeedPageState extends State<SpeedPage> {
  final _prompt = TextEditingController(text: speedPrompt);
  List<Run> _runs = const [];
  int _run = 0;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    widget.playground.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    widget.playground.removeListener(_changed);
    _clock?.cancel();
    for (final r in _runs) {
      r.job?.cancel();
    }
    _prompt.dispose();
    super.dispose();
  }

  /// Ticked: as saved; before anything is saved, every agent and no local model.
  Set<String> get _ticked {
    final saved = widget.host.settings.texts('playground_agents');
    final all = widget.playground.contestants();
    return saved.isNotEmpty ? saved.toSet() : {for (final c in all.where((c) => c.isAgent)) c.id};
  }

  void _tick(Contestant c, bool on) {
    final now = {..._ticked};
    on ? now.add(c.id) : now.remove(c.id);
    try {
      widget.host.settings.update({'playground_agents': now.toList()});
    } on Object {
      // not remembered
    }
    setState(() {});
  }

  Future<void> _ask() async {
    final prompt = _prompt.text.trim();
    final ticked = _ticked;
    final chosen = widget.playground.contestants().where((c) => ticked.contains(c.id)).toList();
    if (prompt.isEmpty || chosen.isEmpty) return;
    final oneByOne = await widget.playground.gpuGuard(context, chosen);
    if (oneByOne == null || !mounted) return;
    for (final r in _runs) {
      r.job?.cancel();
    }
    final run = ++_run;
    setState(() => _runs = [for (final c in chosen) Run(c)]);
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(milliseconds: 500), (_) => mounted ? setState(() {}) : null);
    await askAll(
      widget.playground.backend,
      _runs,
      prompt,
      oneByOne: oneByOne,
      current: () => mounted && run == _run,
      update: () => setState(() {}),
    );
    if (run == _run) _clock?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.playground.contestants();
    final ticked = _ticked;
    return PageScroll(
      children: [
        const TabIntro(
          'Speed and cost',
          'The same question to several agents and local models at once: how long each one takes, and its tokens '
              'and cost where it reports them (Claude Code and the local LLMs do).',
        ),
        vgap,
        PromptField(controller: _prompt, onSubmit: _ask),
        vgap,
        if (all.isEmpty)
          Hint(widget.playground.loaded ? 'No agent that can be asked is set up.' : 'Looking…')
        else
          LayoutBuilder(
            builder: (context, box) {
              final columns = (box.maxWidth / 360).floor().clamp(1, 6);
              final width = box.maxWidth / columns;
              return Wrap(
                runSpacing: 4,
                children: [
                  for (final c in all)
                    SizedBox(
                      width: width,
                      child: CheckLabel(label: c.name, value: ticked.contains(c.id), onChanged: (v) => _tick(c, v)),
                    ),
                ],
              );
            },
          ),
        vgap,
        ActionButton('Ask', onPressed: all.isEmpty ? null : _ask, tooltip: 'Every ticked agent gets the question'),
        vgap,
        for (final r in _runs) RunCard(r),
      ],
    );
  }
}
