import 'agent_run.dart';
import 'agents.dart';
import 'chess_agent.dart';
import 'chess_rules.dart' as rules;
import 'frame_check.dart';
import 'local_hold.dart';
import 'local_llm.dart';
import 'netfetch.dart';
import 'runner.dart';

class Analyze {
  Analyze(this.runner, this.http, this.frames);
  final ProcessRunner runner;
  final LocalHttp http;
  final FrameCheck frames;
  Future<List<Map<String, dynamic>>> choices(String command, CancelToken token) async {
    if (!canAsk(command)) throw ArgumentError('This agent cannot be asked.');
    final home = runner.environment['HOME'] ?? '/', local = localAgentModel(command, runner.environment);
    var own = '';
    if (command == 'codex') own = '${readConfigToml('$home/.codex/config.toml')['model'] ?? ''}';
    if (command == 'claude') own = '${readConfigJson('$home/.claude/settings.json')['model'] ?? ''}';
    if (command == 'pi') own = '${readConfigJson('$home/.pi/agent/settings.json')['defaultModel'] ?? ''}';
    final first = <String, dynamic>{
      'label': own.isEmpty ? 'Its own model' : 'Its own model ($own)',
      'arg': '',
      if (local != null) 'local': {'runtime': local.$1, 'model': local.$2},
    };
    final listed = <Map<String, dynamic>>[];
    if (command == 'claude') {
      for (final alias in ['fable', 'opus', 'sonnet']) {
        listed.add({'label': '${alias[0].toUpperCase()}${alias.substring(1)}', 'arg': alias});
      }
    }
    if (command == 'codex') {
      final rows = readConfigJson('$home/.codex/models_cache.json')['models'];
      for (final row in rows is List ? rows : []) {
        if (row is! Map ||
            row['visibility'] != 'list' ||
            row['slug'] is! String ||
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$').hasMatch(row['slug'])) {
          continue;
        }
        final kinds = row['input_modalities'],
            levels = [
              for (final l in row['supported_reasoning_levels'] is List ? row['supported_reasoning_levels'] : [])
                if (l is Map && l['effort'] is String) l['effort'],
            ];
        final label = '${row['display_name'] ?? row['slug']}';
        listed.add({
          'label': label.substring(0, label.length.clamp(0, 60)),
          'arg': row['slug'],
          if (kinds is List) 'images': kinds.contains('image'),
          'thinking': levels.isEmpty ? null : true,
          'levels': levels,
          if (row['context_window'] is int) 'context': row['context_window'],
        });
        if (listed.length == 12) break;
      }
    }
    if (command == 'pi') {
      final result = await runner.run(
        ['pi', '--list-models'],
        maxBytes: 65536,
        timeout: const Duration(seconds: 30),
        cancel: token,
      );
      final pattern = RegExp(r'^(\S+)\s+(\S+)\s+([\d.]+[KM]?)\s+\S+\s+(yes|no)\s+(yes|no)\s*$');
      for (final line in result.text.split('\n').skip(1)) {
        final m = pattern.firstMatch(line.trim());
        if (m == null) continue;
        final arg = '${m[1]}/${m[2]}';
        if (modelName.stringMatch(arg) != arg) continue;
        final context = m[3]!,
            factor = context.endsWith('K')
                ? 1000
                : context.endsWith('M')
                ? 1000000
                : 1;
        listed.add({
          'label': '${m[2]} (${m[1]})',
          'arg': arg,
          if (providerKeys.containsKey(m[1])) 'local': {'runtime': providerKeys[m[1]], 'model': m[2]},
          'images': m[5] == 'yes',
          'thinking': m[4] == 'yes',
          'context': ((double.tryParse(context.replaceAll(RegExp('[KM]'), '')) ?? 0) * factor).toInt(),
        });
      }
    }
    for (final c in listed) {
      if (c['arg'] == own ||
          local != null && c['local'] is Map && c['local']['runtime'] == local.$1 && c['local']['model'] == local.$2) {
        for (final key in ['images', 'thinking', 'levels', 'context']) {
          if (c.containsKey(key)) first[key] = c[key];
        }
      }
    }
    return [
      first,
      ...listed.where(
        (c) =>
            c['arg'] != own &&
            !(local != null &&
                c['local'] is Map &&
                c['local']['runtime'] == local.$1 &&
                c['local']['model'] == local.$2),
      ),
    ];
  }

  Future<void> run(
    String command,
    Map<String, dynamic> choice,
    CancelToken token,
    void Function(Map<String, Object?>) report,
  ) async {
    if (!canAsk(command)) throw ArgumentError('This agent cannot be asked.');
    final model = choice['arg'] ?? '';
    if (model is! String || model.isNotEmpty && modelName.stringMatch(model) != model) {
      throw ArgumentError('Invalid model name.');
    }
    final agent = adapter(command)!;
    void finding(String key, String state, String summary, [String detail = '', Map<String, dynamic>? download]) {
      token.check();
      report({'key': key, 'state': state, 'summary': summary, 'detail': detail, 'download': ?download});
    }

    final local = choice['local'];
    final hold = local is Map ? LocalHold(serverKey('${local['runtime']}'), http, runner) : null;
    try {
      if (hold != null) await hold.open(cancel: token);
      final levels = (agent.data['ask']['effort'] as Map).keys.cast<String>().toList();
      final named = choice['levels'] is List ? (choice['levels'] as List).join(', ') : '';
      if (named.isNotEmpty) {
        finding(
          'thinking',
          'yes',
          named,
          levels.isEmpty
              ? ''
              : "The model has these reasoning levels; AI Playground uses ${levels.length} of the agent's: ${levels.join(', ')}.",
        );
      } else if (choice['thinking'] == false) {
        finding('thinking', 'no', 'the model does not think', 'It answers at once; there is no thinking time to set.');
      } else if (levels.isNotEmpty) {
        finding(
          'thinking',
          'yes',
          levels.join(', '),
          '${agent.name} takes a thinking time for each question: ${levels.join(', ')}.',
        );
      } else {
        finding('thinking', 'unknown', 'not stated', "The agent's settings name no thinking time.");
      }
      final context = choice['context'];
      if (context is int && context > 0) {
        finding('context', 'yes', '${_commas(context)} tokens', 'About ${_commas(context ~/ 500)} pages of text.');
      } else {
        finding('context', 'unknown', 'not stated', 'The agent does not say how much this model keeps in mind.');
      }
      finding(
        'making',
        'no',
        'not with one answer',
        'Use the Generate tab: it makes pictures on this computer, without an agent.',
      );
      if (hold != null && hold.error.isNotEmpty) {
        for (final key in ['text', 'pictures', 'video', 'chess']) {
          finding(key, 'no', 'The local LLM did not start: ${hold.error}');
        }
        return;
      }
      final answer = await askAgent(
        runner,
        command,
        'What is 17 times 23? Answer with the number only.',
        level: 'quick',
        model: model,
        think: local == null,
        cancel: token,
      );
      if (!answer.text.contains('391')) {
        finding(
          'text',
          'no',
          answer.error.isEmpty ? 'a wrong answer' : answer.error,
          answer.text.isEmpty ? answer.error : 'Answer: ${_short(answer.text, 200)}',
        );
        for (final key in ['pictures', 'video', 'chess']) {
          finding(key, 'skipped', 'not tested: no text answer');
        }
        return;
      }
      finding(
        'text',
        'yes',
        [
          _seconds(answer.seconds),
          if (answer.tokensOut != null) '${answer.tokensOut} tokens',
          ?answer.cost == null ? null : '\$${answer.cost!.toStringAsFixed(4)}',
        ].join(' · '),
        'Answer: ${_short(answer.text, 80)}',
      );
      if (!takesImages(command) || choice['images'] == false) {
        final why = !takesImages(command)
            ? '${agent.name} cannot be sent pictures from here (Claude Code, Codex and Pi can).'
            : "The model's description says it takes text only.";
        finding('pictures', 'no', !takesImages(command) ? 'no pictures' : 'text only', why);
        finding('video', 'no', 'needs pictures', why);
      } else {
        VisionResult seen;
        if (local is Map) {
          seen = await frames.check(command, serverKey('${local['runtime']}'), '${local['model']}', model, token);
        } else {
          final probe = await frames.probe(command, model, token);
          seen = probe.text.toLowerCase().contains('red')
              ? VisionResult('ready', 'It named the colour of the test picture.', seconds: probe.seconds)
              : VisionResult(
                  'no',
                  "It did not name the test picture's colour: ${probe.error.isEmpty
                      ? probe.text.isEmpty
                            ? 'no answer'
                            : _short(probe.text, 120)
                      : probe.error}",
                );
        }
        if (seen.state == 'ready') {
          finding('pictures', 'yes', _seconds(seen.seconds), seen.message);
          finding(
            'video',
            seen.seconds >= 15 ? 'slow' : 'yes',
            'about ${_seconds(seen.seconds)} per frame',
            seen.seconds >= 15
                ? 'Usable, but a long video takes a while.'
                : 'A video frame is larger than the test picture: it may take a little longer.',
          );
        } else {
          finding('pictures', 'no', seen.state == 'download' ? 'not yet' : 'no', seen.message, seen.download);
          finding('video', 'no', 'needs pictures', seen.message);
        }
      }
      if (!plays(command)) {
        finding('chess', 'no', 'not offered', 'Its adapter does not offer chess.');
        return;
      }
      final pos = rules.start();
      final reply = await askAgent(
        runner,
        command,
        chessPrompt(pos, [], 'w', level: 'quick'),
        level: 'quick',
        model: model,
        think: local == null,
        cancel: token,
      );
      final (move, written) = rules.findMove(pos, reply.text);
      if (move != null) {
        finding('chess', 'yes', '1. $written · ${_seconds(reply.seconds)}', 'It answered with a legal opening move.');
      } else {
        finding(
          'chess',
          'no',
          reply.error.isEmpty ? 'no legal move' : reply.error,
          reply.text.isEmpty ? reply.error : 'Answer: ${_short(reply.text, 200)}',
        );
      }
    } finally {
      await hold?.release();
    }
  }
}

String _short(String s, int n) => s.trim().substring(0, s.trim().length.clamp(0, n));
String _seconds(double s) => '${s.toStringAsFixed(1)} s';
String _commas(int value) => value.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
