import 'dart:async';
import 'dart:convert';
import 'agents.dart';
import 'agent_run.dart';
import 'chess_agent.dart';
import 'chess_rules.dart' as rules;
import 'desktop_look.dart';
import 'gpu_check.dart';
import 'local_hold.dart';
import 'local_llm.dart';
import 'netfetch.dart';
import 'runner.dart';
import 'settings.dart';

class CoreError implements Exception {
  const CoreError(this.code, this.message);
  final String code, message;
}

/// JSON frame endpoint for an app-owned background isolate. Control frames return
/// the JSON string `null`; only request frames produce an id-bearing reply.
class CoreService {
  CoreService(
    Map<String, String> environment, {
    this.onEvent,
    ProcessRunner? runner,
    LocalHttp? http,
  }) : environment = Map.unmodifiable(environment),
       runner = runner ?? ProcessRunner(environment: environment),
       http = http ?? LocalHttp(),
       settings = Settings(Places.fromEnv(environment));
  final Map<String, String> environment;
  final ProcessRunner runner;
  final LocalHttp http;
  final Settings settings;
  void Function(String frame)? onEvent;
  final Map<Object, CancelToken> _jobs = {};
  bool _closing = false;
  Future<void>? _disposing;
  Future<String> handleAsync(String frame) => _handle(frame);
  Future<String> _handle(String frame) async {
    Object? id;
    try {
      final decoded = jsonDecode(frame);
      if (decoded == null) {
        await dispose();
        return 'null';
      }
      if (decoded is! Map<String, dynamic>) {
        throw const CoreError('bad_params', 'Expected a request object.');
      }
      if (decoded.containsKey('cancel')) {
        _jobs[decoded['cancel']]?.cancel();
        return 'null';
      }
      id = decoded['id'];
      if (decoded['protocol'] != 1 ||
          (id is! int && id is! String) ||
          decoded['method'] is! String) {
        throw const CoreError('bad_params', 'Invalid protocol request.');
      }
      if (_closing) throw Cancelled();
      if (_jobs.containsKey(id)) {
        throw const CoreError(
          'bad_params',
          'A request with this id is already running.',
        );
      }
      final params = decoded['params'] ?? <String, dynamic>{};
      if (params is! Map<String, dynamic>) {
        throw const CoreError('bad_params', 'Expected params to be an object.');
      }
      final token = CancelToken();
      _jobs[id!] = token;
      try {
        final result = await _dispatch(decoded['method'], params, token, id);
        token.check();
        return jsonEncode({'id': id, 'result': result});
      } finally {
        _jobs.remove(id);
      }
    } on Cancelled {
      return jsonEncode({
        'id': id,
        'error': {'code': 'cancelled', 'message': 'Cancelled.'},
      });
    } on CoreError catch (e) {
      return jsonEncode({
        'id': id,
        'error': {'code': e.code, 'message': e.message},
      });
    } on FormatException catch (e) {
      return jsonEncode({
        'id': id,
        'error': {'code': 'bad_params', 'message': e.message},
      });
    } on ArgumentError catch (e) {
      return jsonEncode({
        'id': id,
        'error': {'code': 'bad_params', 'message': e.message.toString()},
      });
    } on Object catch (e) {
      return jsonEncode({
        'id': id,
        'error': {'code': 'failed', 'message': e.toString()},
      });
    }
  }

  String _string(Map p, String key, {String? fallback}) {
    final value = p[key] ?? fallback;
    if (value is! String) {
      throw CoreError('bad_params', 'Expected $key to be a string.');
    }
    return value;
  }

  List<String> _strings(Object? value) {
    if (value is! List || value.any((v) => v is! String)) {
      throw const CoreError('bad_params', 'Expected a list of strings.');
    }
    return value.cast<String>();
  }

  Map<String, dynamic> _target(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const CoreError('bad_params', 'Expected a target.');
    }
    final kind = value['kind'];
    if (kind == 'agent') {
      final command = _string(value, 'command');
      if (!canAsk(command)) {
        throw const CoreError('not_found', 'This agent cannot be asked.');
      }
      final model = _string(value, 'model', fallback: '');
      if (model.isNotEmpty &&
          (!modelFlags.containsKey(command) ||
              modelName.stringMatch(model) != model)) {
        throw const CoreError('bad_params', 'Invalid model name.');
      }
      final level = _string(value, 'level', fallback: 'normal');
      if (!thinkingSeconds.containsKey(level)) {
        throw const CoreError('bad_params', 'Invalid thinking time.');
      }
    } else if (kind == 'local') {
      if (value['port'] is! int || value['port'] < 1 || value['port'] > 65535) {
        throw const CoreError('bad_params', 'Invalid port.');
      }
      _string(value, 'model');
      value = Map<String, dynamic>.of(value);
      value['runtime'] = serverKey(_string(value, 'runtime'));
    } else {
      throw const CoreError('bad_params', 'Invalid target kind.');
    }
    return value;
  }

  void _event(Object id, String event, Map<String, Object?> data) {
    onEvent?.call(jsonEncode({'event': event, 'id': id, 'data': data}));
  }

  Future<Object?> _dispatch(
    String method,
    Map<String, dynamic> p,
    CancelToken token,
    Object id,
  ) async {
    switch (method) {
      case 'app.info':
        final desktop = detectDesktop(environment);
        return {
          'version': '0.1.0',
          'desktop': desktop.name,
          'look': desktopLook(
            desktop: desktop,
            paths: LookPaths.fromEnv(environment),
          ),
        };
      case 'settings.get':
        final keys = p.containsKey('keys')
            ? _strings(p['keys'])
            : schema.keys.toList();
        if (keys.any((k) => !schema.containsKey(k))) {
          throw const CoreError('bad_params', 'Unknown setting.');
        }
        return {
          'values': {for (final key in keys) key: settings.get(key)},
        };
      case 'settings.set':
        final values = p['values'];
        if (values is! Map<String, dynamic>) {
          throw const CoreError(
            'bad_params',
            'Expected values to be an object.',
          );
        }
        for (final entry in values.entries) {
          final setting = schema[entry.key];
          if (setting == null ||
              (entry.value != null && !setting.valid(entry.value))) {
            throw CoreError('bad_params', 'Invalid setting: ${entry.key}');
          }
        }
        settings.update(values);
        return {};
      case 'agents.list':
        return {
          'agents': adapters.map((a) => agentInfo(a, environment)).toList(),
        };
      case 'local.servers':
        return {'servers': await LocalLlm(http).servers(cancel: token)};
      case 'gpu.check':
        if (p['targets'] is! List) {
          throw const CoreError('bad_params', 'Expected targets.');
        }
        final wanted = <(String, String, String)>[];
        for (final raw in p['targets']) {
          final t = _target(raw);
          if (t['kind'] == 'local') {
            wanted.add((t['model'], t['runtime'], t['model']));
          } else {
            final m = localAgentModel(t['command'], environment);
            if (m != null) wanted.add((t['command'], m.$1, m.$2));
          }
        }
        final check = await GpuGuard(http, runner).check(wanted, cancel: token);
        token.check();
        return check?.toJson() ??
            {'fits': true, 'message': '', 'alternating_ok': true};
      case 'local.make_room':
        final target = _target(p['target']);
        final m = target['kind'] == 'agent'
            ? localAgentModel(target['command'], environment)
            : null;
        await GpuGuard(http, runner).unload(
          m?.$1 ?? target['runtime'] ?? '',
          m?.$2 ?? target['model'] ?? '',
          port: target['port'],
          cancel: token,
        );
        return {};
      case 'ask.run':
        final t = _target(p['target']);
        final prompt = _string(p, 'prompt');
        final images = p.containsKey('images')
            ? _strings(p['images'])
            : <String>[];
        if (p.containsKey('untrusted') && p['untrusted'] is! bool) {
          throw const CoreError(
            'bad_params',
            'Expected untrusted to be a boolean.',
          );
        }
        _event(id, 'progress', {'fraction': 0, 'text': 'Asking…'});
        Answer answer;
        if (t['kind'] == 'agent') {
          if (p['untrusted'] == true && !readsUntrusted(t['command'])) {
            throw const CoreError(
              'bad_params',
              'This agent cannot read untrusted input.',
            );
          }
          answer = await askAgent(
            runner,
            t['command'],
            prompt,
            images: images,
            level: t['level'] ?? 'normal',
            model: t['model'] ?? '',
            cancel: token,
            untrusted: p['untrusted'] == true,
          );
        } else {
          if (images.isNotEmpty &&
              await seesPictures(
                    http,
                    t['runtime'],
                    t['model'],
                    environment: environment,
                    port: t['port'],
                    cancel: token,
                  ) !=
                  true) {
            throw const CoreError(
              'bad_params',
              'This local model cannot be sent pictures.',
            );
          }
          answer = await LocalLlm(
            http,
          ).ask(t['port'], t['model'], prompt, images: images, cancel: token);
        }
        return answer.toJson();
      case 'chess.ask':
        final command = _string(p, 'command');
        if (!plays(command)) {
          throw const CoreError(
            'not_found',
            'This agent cannot be asked for a move.',
          );
        }
        final start = rules.fromFen(_string(p, 'start_fen'));
        final moves = <rules.Move>[];
        var pos = start;
        for (final uci in _strings(p['moves'])) {
          final move = rules.parse(pos, uci);
          if (move == null || move.uci() != uci) {
            throw const CoreError('bad_params', 'Illegal chess move.');
          }
          moves.add(move);
          pos = rules.apply(pos, move);
        }
        final strength = _string(p, 'strength', fallback: 'club'),
            level = _string(p, 'level', fallback: 'normal');
        if (!strengthPrompts.containsKey(strength) ||
            !thinkingSeconds.containsKey(level)) {
          throw const CoreError(
            'bad_params',
            'Invalid strength or thinking time.',
          );
        }
        var prompt = chessPrompt(
          start,
          moves,
          pos.turn,
          level: level,
          strength: strength,
        );
        if (p.containsKey('retry_of')) {
          prompt = retryPrompt(prompt, _string(p, 'retry_of'));
        }
        var reply = await askChess(
          runner,
          command,
          prompt,
          pos,
          level: level,
          cancel: token,
        );
        // The chess page retries one answer without a legal move automatically.
        if (reply.move == null &&
            reply.error.isEmpty &&
            !p.containsKey('retry_of')) {
          reply = await askChess(
            runner,
            command,
            retryPrompt(prompt, reply.comment.isEmpty ? ' ' : reply.comment),
            pos,
            level: level,
            cancel: token,
          );
        }
        if (reply.move == null && reply.error.isEmpty) {
          reply = ChessReply(
            null,
            reply.written,
            reply.comment,
            error:
                '${adapter(command)!.name} did not name one of its legal moves.',
          );
        }
        return reply.toJson();
      default:
        throw CoreError('not_found', 'Unknown method: $method');
    }
  }

  Future<void> dispose() => _disposing ??= () async {
    _closing = true;
    for (final token in _jobs.values) {
      token.cancel();
    }
    http.dispose();
    await LocalHold.stopAll();
    await runner.dispose();
    // Requests own their temporary folders and remove them before replying.
    while (_jobs.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }();
}
