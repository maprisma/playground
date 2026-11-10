import 'package:flutter/material.dart';

import 'backend.dart';
import 'theme.dart';
import 'widgets.dart';

/// An agent from agents.list.
final class Agent {
  Agent(Map<String, dynamic> j)
    : command = '${j['command']}',
      name = '${j['name']}',
      installed = j['installed'] == true,
      setUp = j['set_up'] == true,
      canAsk = j['can_ask'] == true,
      playsChess = j['plays_chess'] == true,
      takesImages = j['takes_images'] == true,
      readsUntrusted = j['reads_untrusted'] == true;
  final String command, name;
  final bool installed, setUp, canAsk, playsChess, takesImages, readsUntrusted;

  /// Offered on the tabs: installed, set up (signed in or on a local LLM) and askable.
  bool get ready => installed && setUp && canAsk;
}

/// What a test asks (the plugin's contestant): an agent, or a model of a local LLM server.
final class Contestant {
  Contestant.agent(Agent a) : id = a.command, name = a.name, agent = a, port = null, model = '', runtime = '';
  Contestant.local({required int this.port, required this.runtime, required String server, required this.model})
    : id = 'local:$runtime:$port:$model',
      name = '$server · $model',
      agent = null;
  final String id, name, model, runtime;
  final Agent? agent;
  final int? port;
  bool get isAgent => agent != null;

  Map<String, dynamic> get target => isAgent
      ? {'kind': 'agent', 'command': agent!.command, 'model': '', 'level': 'normal'}
      : {'kind': 'local', 'port': port, 'model': model, 'runtime': runtime};
}

/// The agents set up here and the local LLM servers running: shared by every tab, refreshed by
/// Local LLMs' Look again (and on start).
final class Playground extends ChangeNotifier {
  Playground(this.backend);
  final Backend backend;
  List<Agent> agents = const [];
  List<Contestant> locals = const [];
  List<String> notes = const [];
  bool scanning = false, loaded = false;

  List<Agent> get ready => agents.where((a) => a.ready).toList();

  /// The agents that are set up, then every model of the local LLM servers found.
  List<Contestant> contestants({bool withModels = true}) => [
    for (final a in ready) Contestant.agent(a),
    if (withModels) ...locals,
  ];

  Future<void> loadAgents() async {
    try {
      final r = await backend.call('agents.list');
      agents = [for (final a in (r['agents'] as List? ?? const [])) Agent((a as Map).cast<String, dynamic>())];
    } on Object {
      agents = const [];
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> scan() async {
    scanning = true;
    notifyListeners();
    try {
      final r = await backend.call('local.servers');
      final found = <Contestant>[], problems = <String>[];
      for (final raw in (r['servers'] as List? ?? const [])) {
        final s = (raw as Map).cast<String, dynamic>();
        final name = '${s['name'] ?? s['runtime']}';
        if (s['error'] is String && (s['error'] as String).isNotEmpty) {
          problems.add('$name: ${s['error'] == 'another account' ? 'runs under another account; not asked' : s['error']}');
          continue;
        }
        for (final m in (s['models'] as List? ?? const [])) {
          found.add(Contestant.local(port: s['port'] as int, runtime: '${s['runtime']}', server: name, model: '$m'));
        }
      }
      locals = found;
      notes = problems;
    } on Object catch (e) {
      locals = const [];
      notes = ['$e'];
    }
    scanning = false;
    notifyListeners();
  }

  /// Before two or more local models answer together (gpu_check): null to cancel, else whether
  /// to ask one after the other. alternating: they answer in turn anyway (chess).
  Future<bool?> gpuGuard(BuildContext context, List<Contestant> chosen, {bool alternating = false}) async {
    if (chosen.length < 2) return false;
    Map<String, dynamic> check;
    try {
      check = await backend.call('gpu.check', {'targets': [for (final c in chosen) c.target]});
    } on Object {
      return false;
    }
    if (check['fits'] == true || !context.mounted) return false;
    return showDialog<bool?>(
      context: context,
      builder: (context) => _GpuDialog(check: check, alternating: alternating),
    );
  }
}

class _GpuDialog extends StatelessWidget {
  const _GpuDialog({required this.check, required this.alternating});
  final Map<String, dynamic> check;
  final bool alternating;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    String gb(Object? b) => b is num ? (b / (1 << 30)).toStringAsFixed(1) : '?';
    final lines = <String>[
      for (final raw in (check['needs'] as List? ?? const []))
        switch ((raw as Map).cast<String, dynamic>()) {
          final n when n['loaded'] == true => '${n['label']}: loaded already',
          final n when n['size'] == null => '${n['label']}: size not found',
          final n => '${n['label']}: about ${gb(n['bytes_needed'])} GB',
        },
      if (check['total'] != null && check['fits'] == false)
        'Together about ${gb(check['needed'])} GB more are needed; ${gb(check['free'])} GB of ${gb(check['total'])} GB '
            'GPU memory are free.'
      else if (check['total'] != null)
        '${gb(check['free'])} GB of ${gb(check['total'])} GB GPU memory are free; not every size was found.'
      else if ('${check['message'] ?? ''}'.isNotEmpty)
        '${check['message']}',
      alternating
          ? 'They answer in turn, but both may stay loaded: the local LLM may have to swap them for every move (slow), '
                'or loading the second one fails.'
          : 'Loading them at once can fail or make the computer stall. One after the other asks the next only when '
                'the one before has answered.',
    ];
    return AlertDialog(
      title: Text(
        'These local models may not fit in GPU memory together',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: look.fg),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 6), child: AnswerText(l))],
        ),
      ),
      actions: [
        SmallButton('Cancel', onPressed: () => Navigator.pop(context)),
        if (alternating)
          SmallButton('Play anyway', onPressed: () => Navigator.pop(context, false))
        else ...[
          SmallButton('Both at once', onPressed: () => Navigator.pop(context, false)),
          ActionButton('One after the other', onPressed: () => Navigator.pop(context, true)),
        ],
      ],
    );
  }
}

/// 12.3 s · 450 tokens · $0.0210 · 35.2 tokens per second, as far as the answer reports them.
/// Tokens per second only for local models: an agent's time includes its own start-up.
String resultLine(Map<String, dynamic> a, {bool rate = true}) {
  final parts = <String>['${((a['seconds'] as num?) ?? 0).toStringAsFixed(1)} s'];
  if (a['tokens_out'] is num) parts.add('${a['tokens_out']} tokens');
  if (a['cost'] is num) parts.add('\$${(a['cost'] as num).toStringAsFixed(4)}');
  if (rate && a['per_second'] is num) parts.add('${(a['per_second'] as num).toStringAsFixed(1)} tokens per second');
  return parts.join(' · ');
}

/// One answer as the plugin's result card: the name, "asking… 3.5 s" while it runs, then the
/// time line and the text.
final class Run {
  Run(this.contestant);
  final Contestant contestant;
  final started = DateTime.now();
  Map<String, dynamic>? answer;
  String? error;
  Job? job;
  bool get done => answer != null || error != null;
  String get text => error ?? (answer?['error'] is String && '${answer!['error']}'.isNotEmpty && '${answer!['text'] ?? ''}'.isEmpty
      ? '${answer!['error']}'
      : '${answer?['text'] ?? ''}');
  bool get failed => error != null || ('${answer?['text'] ?? ''}'.isEmpty && '${answer?['error'] ?? ''}'.isNotEmpty);
  String summary() {
    if (!done) {
      final s = DateTime.now().difference(started).inMilliseconds / 1000;
      return 'asking… ${s.toStringAsFixed(1)} s';
    }
    if (failed) return text;
    return resultLine(answer!, rate: !contestant.isAgent);
  }
}

class RunCard extends StatelessWidget {
  const RunCard(this.run, {super.key, this.waiting = 'asking…'});
  final Run run;
  final String waiting;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: gap),
    child: FoldCard(
      title: run.contestant.name,
      initiallyOpen: true, // the time line stays in view, open or folded (as the plugin's)
      action: Text(run.summary(), style: TextStyle(fontSize: 11, color: Look.of(context).dim)),
      child: AnswerText(run.done ? run.text : waiting, error: run.failed),
    ),
  );
}

/// Asks every contestant (at once, or one after the other with room made in between); `update`
/// is called whenever something changed. Returns when all have answered.
Future<void> askAll(
  Backend backend,
  List<Run> runs,
  String prompt, {
  required bool oneByOne,
  required VoidCallback update,
  required bool Function() current,
  List<String> images = const [],
  bool untrusted = false,
}) async {
  Future<void> one(Run run) async {
    if (!current()) return;
    run.job = backend.start('ask.run', {
      'target': run.contestant.target,
      'prompt': prompt,
      if (images.isNotEmpty) 'images': images,
      // Pictures may carry planted words: only agents without tools take them (the core checks).
      if (untrusted) 'untrusted': true,
    });
    try {
      run.answer = await run.job!.result;
    } on CoreFailure catch (e) {
      run.error = e.cancelled ? 'Stopped.' : e.message;
    } on Object catch (e) {
      run.error = '$e';
    }
    if (current()) update();
    if (oneByOne && current()) {
      try {
        await backend.call('local.make_room', {'target': run.contestant.target}); // room for the next one
      } on Object {
        // nothing to unload
      }
    }
  }

  if (oneByOne) {
    for (final r in runs) {
      await one(r);
    }
  } else {
    await Future.wait(runs.map(one));
  }
}
