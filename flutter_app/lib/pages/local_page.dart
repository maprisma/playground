import 'package:maprisma_playground_core/maprisma_playground_core.dart' show tr;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../contestants.dart';
import '../theme.dart';
import '../widgets.dart';

String get localPrompt => tr("In one sentence: what is a large language model?");

/// LocalTab: one question to a model of a local LLM server running here, optionally compared with
/// a second one, with time and tokens per second.
class LocalPage extends StatefulWidget {
  const LocalPage({super.key, required this.host, required this.playground});
  final Host host;
  final Playground playground;
  @override
  State<LocalPage> createState() => _LocalPageState();
}

class _LocalPageState extends State<LocalPage> {
  String _defaultPrompt = localPrompt;
  final _prompt = TextEditingController(text: localPrompt);
  String? _first, _second; // ids; _second null: no second model
  List<Run> _runs = const [];
  int _run = 0;
  Timer? _clock;
  List<String> _shownNotes = const [];

  @override
  void didUpdateWidget(covariant LocalPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final translated = localPrompt;
    if (_prompt.text == _defaultPrompt) _prompt.text = translated;
    _defaultPrompt = translated;
  }

  @override
  void initState() {
    super.initState();
    widget.playground.addListener(_changed);
  }

  void _changed() {
    final notes = widget.playground.notes;
    if (notes.isNotEmpty && !identical(notes, _shownNotes)) {
      _shownNotes = notes;
      widget.host.toast(notes.join(' · '));
    }
    setState(() {});
  }

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

  Future<void> _ask() async {
    final locals = widget.playground.locals;
    final prompt = _prompt.text.trim();
    if (locals.isEmpty || prompt.isEmpty) return;
    final first = locals.firstWhere((c) => c.id == _first, orElse: () => locals.first);
    final picked = [first];
    final second = locals.where((c) => c.id == _second && c.id != first.id).firstOrNull;
    if (second != null) picked.add(second);
    final oneByOne = await widget.playground.gpuGuard(context, picked);
    if (oneByOne == null || !mounted) return;
    for (final r in _runs) {
      r.job?.cancel();
    }
    final run = ++_run;
    setState(() => _runs = [for (final c in picked) Run(c)]);
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
    final look = Look.of(context);
    final p = widget.playground;
    final locals = p.locals;
    final first = locals.where((c) => c.id == _first).firstOrNull ?? locals.firstOrNull;
    final second = locals.where((c) => c.id == _second).firstOrNull;
    return PageScroll(
      children: [
        TabIntro(
          tr("Local LLMs"),
          tr(
            "The local LLM servers running on this computer (llama.cpp, Ollama, LM Studio, vLLM, Jan, KoboldCpp): one question to a model, with its time and tokens per second. Only servers that run under your own account are asked.",
          ),
        ),
        vgap,
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Choice<Contestant>(
              value: p.scanning ? null : first,
              items: p.scanning ? const [] : locals,
              label: (c) => c.name,
              empty: p.scanning ? tr("Looking…") : tr("No local LLM server is running"),
              onChanged: (c) => setState(() => _first = c.id),
            ),
            Text(tr("compared with"), style: TextStyle(fontSize: 13, color: look.fg)),
            Tooltip(
              message: tr(
                "A second model gets the same question; if both may not fit in GPU memory together, you are asked first",
              ),
              child: Choice<Contestant?>(
                value: second,
                items: [null, ...locals],
                label: (c) => c?.name ?? tr("no second model"),
                empty: tr("no second model"),
                onChanged: (c) => setState(() => _second = c?.id),
              ),
            ),
            SmallButton(tr("Look again"), onPressed: p.scanning ? null : p.scan),
          ],
        ),
        vgap,
        PromptField(controller: _prompt, minLines: 2, onSubmit: _ask),
        vgap,
        ActionButton(tr("Ask"), onPressed: locals.isEmpty || p.scanning ? null : _ask),
        vgap,
        for (final r in _runs) RunCard(r, waiting: tr("asking… (a model that is not loaded yet loads first)")),
      ],
    );
  }
}
