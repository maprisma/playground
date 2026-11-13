import 'package:maprisma_playground_core/maprisma_playground_core.dart' show tr, trf;
import 'package:flutter/material.dart';

import '../app.dart';
import '../backend.dart';
import '../contestants.dart';
import '../theme.dart';
import '../widgets.dart';
import 'page_head.dart';

/// The capability cards, in order: key, title, what it means (analyze.CARDS).
List<(String, String, String)> get analyzeCards => <(String, String, String)>[
  (
    'text',
    tr("Text"),
    tr(
      "Answers a question in writing: the base of everything else. One small sum is asked; the time, and tokens and cost where the agent reports them, are shown.",
    ),
  ),
  (
    'pictures',
    tr("Pictures"),
    tr(
      "Sees a picture sent with the question (screenshots, photos, the Vision tab). One test picture is sent: a red square, and the agent is asked for its colour. A local model is set up for it first where it can be.",
    ),
  ),
  (
    'video',
    tr("Chess videos"),
    tr(
      "Reads the moves from a chess video frame by frame (Chess tab › Import video). Each frame is one question with a picture, so it needs pictures and quick answers; the time of the test picture tells.",
    ),
  ),
  (
    'thinking',
    tr("Thinking time"),
    tr(
      "Can be told to think briefly or long (Thinking time on the Chess tab, quick answers for video frames). Read from the agent's settings and the model's own description.",
    ),
  ),
  ('chess', tr("Chess"), tr("Plays chess on the Chess tab: one legal opening move is asked.")),
  (
    'context',
    tr("Context"),
    tr(
      "How much text it keeps in mind at once (prompt, files, the conversation), in tokens; a page of text is about 500. Read from the model's description.",
    ),
  ),
  (
    'making',
    tr("Making pictures"),
    tr(
      "Draws a new picture from a text. Agents asked for one answer here have no drawing tool; the Generate tab makes pictures on this computer's graphics card.",
    ),
  ),
];

Mark markOf(String? state) => switch (state) {
  'yes' => Mark.yes,
  'no' => Mark.no,
  'slow' => Mark.slow,
  'skipped' => Mark.skipped,
  'waiting' || 'running' || null => Mark.running,
  _ => Mark.unknown,
};

/// One card's finding (analyze.Finding): state, summary, detail, and a vision file to download.
final class Finding {
  Finding(Map<String, dynamic> j)
    : state = '${j['state'] ?? j['mark'] ?? 'unknown'}',
      summary = '${j['summary'] ?? ''}',
      detail = '${j['detail'] ?? j['text'] ?? ''}',
      download = (j['download'] ?? j['offer']) is Map
          ? ((j['download'] ?? j['offer']) as Map).cast<String, dynamic>()
          : null;
  Finding.waiting() : state = 'waiting', summary = tr('waiting…'), detail = '', download = null;
  final String state, summary, detail;
  final Map<String, dynamic>? download;
}

/// AnalyzeTab: what an agent and one of its models can do, a card per capability with a mark. A
/// header symbol's page (the test tube beside ⓘ and Settings), with Back like Settings: its heading
/// stays while the rest scrolls.
class AnalyzePage extends StatefulWidget {
  const AnalyzePage({super.key, required this.host, required this.playground, required this.onBack});
  final Host host;
  final Playground playground;
  final VoidCallback onBack;
  @override
  State<AnalyzePage> createState() => _AnalyzePageState();
}

class _AnalyzePageState extends State<AnalyzePage> {
  String? _agent; // command
  bool _picked = false; // chosen here: the shared helper choice no longer moves it
  List<Map<String, dynamic>>? _choices; // null: looking
  int _choice = 0;
  Map<String, Finding> _findings = {};
  Job? _job, _fetch;
  bool _running = false;
  String? _fetchText;
  int _run = 0;

  @override
  void initState() {
    super.initState();
    widget.playground.addListener(_changed);
    _changed();
  }

  void _changed() {
    final ready = widget.playground.ready;
    // The helper chosen for every Maprisma app first (Maprisma Manager → AI), until one is
    // chosen here; else the first one set up.
    final start = widget.playground.preferred(ready.map((a) => a.command));
    final keep = _agent != null && (_picked || _running) && ready.any((a) => a.command == _agent);
    if (!keep && start != null && start != _agent) {
      _agent = start;
      _loadChoices();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.playground.removeListener(_changed);
    _job?.cancel();
    _fetch?.cancel();
    super.dispose();
  }

  Future<void> _loadChoices() async {
    final asked = _agent;
    if (asked == null) return;
    _clear();
    setState(() => _choices = null);
    List<Map<String, dynamic>> found;
    try {
      final r = await widget.playground.backend.call('analyze.choices', {'command': asked});
      found = [for (final c in (r['choices'] as List? ?? const [])) (c as Map).cast<String, dynamic>()];
    } on Object {
      found = [];
    }
    if (!mounted || _agent != asked) return;
    setState(() {
      _choices = found.isEmpty
          ? [
              {'label': tr("Its own model")},
            ]
          : found;
      _choice = 0;
    });
  }

  void _clear() {
    _job?.cancel();
    _fetch?.cancel();
    _run++;
    setState(() {
      _findings = {};
      _running = false;
      _fetchText = null;
    });
  }

  Future<void> _start() async {
    final choices = _choices;
    if (_agent == null || choices == null || choices.isEmpty) return;
    _clear();
    final run = _run;
    setState(() {
      _running = true;
      _findings = {for (final c in analyzeCards) c.$1: Finding.waiting()};
    });
    _job = widget.playground.backend.start('analyze.run', {'command': _agent, 'choice': choices[_choice]}, (
      event,
      data,
    ) {
      if (event != 'finding' || run != _run || !mounted) return;
      final key = '${data['key']}';
      setState(() => _findings[key] = Finding(data));
    });
    try {
      await _job!.result;
    } on CoreFailure catch (e) {
      if (run == _run && mounted && !e.cancelled) widget.host.toast(e.message);
    }
    if (run == _run && mounted) setState(() => _running = false);
  }

  /// The pictures card offers a vision file (a local model's projector): fetch it, then all again.
  Future<void> _download(Map<String, dynamic> wanted) async {
    final run = _run;
    setState(() => _fetchText = trf("Downloading the vision file… {0:.0f} %", [0]));
    _fetch = widget.playground.backend.start(
      'vision.setup',
      {'command': _agent, 'choice': _choices![_choice], 'download': wanted},
      (event, data) {
        if (event == 'progress' && run == _run && mounted) {
          final f = (data['fraction'] as num?) ?? 0;
          setState(() => _fetchText = trf("Downloading the vision file… {0:.0f} %", [(f * 100).toStringAsFixed(0)]));
        }
      },
    );
    try {
      await _fetch!.result;
      if (run == _run && mounted) _start(); // all again, now with the vision file
    } on CoreFailure catch (e) {
      if (run == _run && mounted) {
        setState(() => _fetchText = e.cancelled ? null : trf("The vision file could not be set up: {0}", [e.message]));
      }
    }
  }

  Widget _card(String key, String title, String meaning) {
    final f = _findings[key]!;
    final look = Look.of(context);
    final size = f.download?['size'];
    return Padding(
      padding: const EdgeInsets.only(bottom: gap),
      child: FoldCard(
        title: title,
        initiallyOpen: true,
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Tooltip(
                message: f.summary,
                child: Text(
                  f.summary,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall!.copyWith(color: look.dim),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(message: f.summary, child: MarkText(markOf(f.state))),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hint(meaning),
            if (key == 'pictures' && _fetchText != null) ...[
              const SizedBox(height: 8),
              AnswerText(_fetchText!),
            ] else if (f.detail.isNotEmpty) ...[
              const SizedBox(height: 8),
              AnswerText(f.detail),
            ],
            if (f.download != null) ...[
              const SizedBox(height: 8),
              SmallButton(
                size is num
                    ? trf("Download the vision file ({0:.1f} GB)", [(size / (1 << 30)).toStringAsFixed(1)])
                    : tr("Download the vision file"),
                onPressed: _fetchText != null && _fetchText!.startsWith(tr("Downloading…"))
                    ? null
                    : () => _download(f.download!),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = widget.playground.ready;
    final agent = ready.where((a) => a.command == _agent).firstOrNull;
    final choices = _choices;
    final none = ready.isEmpty;
    final body = PageScroll(
      children: [
        Hint(
          tr(
            "What an agent can do with one of its models: text, pictures, chess videos, thinking time, chess, how much it keeps in mind. A few short test questions are asked (they may count against your plan); a local model is set up for pictures where it can be.",
          ),
        ),
        vgap,
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Choice<Agent>(
              value: agent,
              items: ready,
              label: (a) => a.name,
              empty: widget.playground.loaded ? tr("No agent is set up") : tr("Looking…"),
              tooltip: tr("The agent to analyze"),
              onChanged: _running
                  ? null
                  : (a) {
                      setState(() {
                        _agent = a.command;
                        _picked = true;
                      });
                      _loadChoices();
                    },
            ),
            Choice<int>(
              value: choices == null || choices.isEmpty ? null : _choice,
              items: [for (var i = 0; i < (choices?.length ?? 0); i++) i],
              label: (i) => '${choices![i]['label']}',
              empty: none ? tr("No agent is set up here yet") : tr("Looking…"),
              tooltip: tr("The model it is asked with (its own, or another one it lists)"),
              onChanged: _running
                  ? null
                  : (i) {
                      setState(() => _choice = i);
                      _clear(); // findings were for the other one
                    },
            ),
          ],
        ),
        vgap,
        ActionButton(tr("Analyze"), onPressed: none || choices == null || _running ? null : _start),
        vgap,
        if (_findings.isNotEmpty)
          for (final (k, t, m) in analyzeCards) _card(k, t, m),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHead(title: tr("Analyze"), onBack: widget.onBack),
        Expanded(child: body),
      ],
    );
  }
}
