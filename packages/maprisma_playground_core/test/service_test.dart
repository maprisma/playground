import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';
import 'fake_http.dart';

void main() {
  late TestEnvironment e;
  late CoreService service;
  var next = 0;
  setUp(() {
    e = TestEnvironment();
    service = CoreService(e.env, runner: e.runner, http: FakeHttp());
  });
  tearDown(() async {
    await service.dispose();
    await e.dispose();
  });
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> params = const {}]) async => jsonDecode(
    await service.handleAsync(jsonEncode({'protocol': 1, 'id': ++next, 'method': method, 'params': params})),
  );
  test('app info and all settings keys defaults/update/reset', () async {
    final info = await call('app.info');
    expect(info['result']['version'], '0.1.0');
    expect((await call('settings.get'))['result']['values'].keys, containsAll(schema.keys));
    expect(
      (await call('settings.set', {
        'values': {'chess_strength': 'master'},
      }))['result'],
      {},
    );
    expect(
      (await call('settings.get', {
        'keys': ['chess_strength'],
      }))['result']['values']['chess_strength'],
      'master',
    );
    await call('settings.set', {
      'values': {'chess_strength': null},
    });
    expect(
      (await call('settings.get', {
        'keys': ['chess_strength'],
      }))['result']['values']['chess_strength'],
      'club',
    );
  });
  test('bad frames, params and unknown methods return protocol errors', () async {
    for (final frame in ['{', '[]', '{"id":1,"method":"x"}']) {
      expect(jsonDecode(await service.handleAsync(frame))['error']['code'], 'bad_params');
    }
    expect((await call('unknown'))['error']['code'], 'not_found');
    for (final method in ['analyze.run', 'pictures.prepare', 'generate.run', 'import.start']) {
      expect((await call(method))['error']['code'], 'bad_params');
    }
    expect((await call('games.list'))['result'], {'games': [], 'total': 0});
    for (final params in [
      {
        'values': {'unknown': true},
      },
      {
        'values': {'chess_strength': 'bad'},
      },
      {'values': 1},
    ]) {
      expect((await call('settings.set', params))['error']['code'], 'bad_params');
    }
    expect(
      (await call('ask.run', {
        'target': {'kind': 'local', 'port': '8080', 'model': 'x', 'runtime': 'llamacpp'},
        'prompt': 'p',
      }))['error']['code'],
      'bad_params',
    );
  });
  test('agent inventory uses temp HOME and fake PATH', () async {
    e.script('pi', '');
    e.file('.pi/agent/auth.json', 'secret');
    final agents = (await call('agents.list'))['result']['agents'] as List;
    expect(agents.length, adapters.length);
    final pi = agents.firstWhere((a) => a['command'] == 'pi');
    expect(pi['installed'], isTrue);
    expect(pi['set_up'], isTrue);
    expect(agents.first['installed'], isFalse);
  });
  test('agent ask events, JSON result and chess.ask', () async {
    e.script('claude', r'''
import sys,json
text=sys.stdin.read()
answer='e4\nI claim the centre.' if 'We are playing a game of chess.' in text else '4'
print(json.dumps({'type':'result','result':answer}))
''');
    final events = <Map>[];
    service.onEvent = (s) => events.add(jsonDecode(s));
    final a = await call('ask.run', {
      'target': {'kind': 'agent', 'command': 'claude'},
      'prompt': '2+2',
    });
    expect(a['result']['text'], '4');
    expect(events.single['event'], 'progress');
    expect(events.single['id'], a['id']);
    final c = await call('chess.ask', {
      'command': 'claude',
      'start_fen': startFen,
      'moves': <String>[],
      'strength': 'club',
      'level': 'quick',
    });
    expect(c['result']['move'], 'e2e4');
    expect(c['result']['comment'], 'I claim the centre.');
    expect(
      (await call('chess.ask', {
        'command': 'claude',
        'start_fen': startFen,
        'moves': ['e2e5'],
      }))['error']['code'],
      'bad_params',
    );
  });
  test('untrusted input is explicitly refused for Codex', () async {
    final reply = await call('ask.run', {
      'target': {'kind': 'agent', 'command': 'codex'},
      'prompt': 'hostile',
      'untrusted': true,
    });
    expect(reply['error']['code'], 'bad_params');
  });
  test('cancel control frame kills job and cleans temp folder', () async {
    e.script('pi', r'''
import os,time
with open(os.environ['HOME']+'/cwd','w') as f: f.write(os.getcwd())
time.sleep(60)
''');
    final job = service.handleAsync(
      jsonEncode({
        'protocol': 1,
        'id': 100,
        'method': 'ask.run',
        'params': {
          'target': {'kind': 'agent', 'command': 'pi'},
          'prompt': 'p',
        },
      }),
    );
    while (!File('${e.home}/cwd').existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final cwd = File('${e.home}/cwd').readAsStringSync();
    expect(await service.handleAsync('{"cancel":100}'), 'null');
    expect(jsonDecode(await job)['error']['code'], 'cancelled');
    expect(Directory(cwd).existsSync(), isFalse);
    expect(e.runner.liveCount, 0);
  });
  test('null shutdown waits for jobs and private directory cleanup', () async {
    e.script('pi', r'''
import os,time
with open(os.environ['HOME']+'/cwd','w') as f: f.write(os.getcwd())
time.sleep(60)
''');
    final job = service.handleAsync(
      jsonEncode({
        'protocol': 1,
        'id': 101,
        'method': 'ask.run',
        'params': {
          'target': {'kind': 'agent', 'command': 'pi'},
          'prompt': 'p',
        },
      }),
    );
    while (!File('${e.home}/cwd').existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final cwd = File('${e.home}/cwd').readAsStringSync();
    expect(await service.handleAsync('null'), 'null');
    expect(jsonDecode(await job)['error']['code'], 'cancelled');
    expect(Directory(cwd).existsSync(), isFalse);
    expect((await call('app.info'))['error']['code'], 'cancelled');
  });
  test('duplicate active request ids do not cancel or replace original', () async {
    e.script('pi', "import time\ntime.sleep(60)");
    final frame = jsonEncode({
      'protocol': 1,
      'id': 102,
      'method': 'ask.run',
      'params': {
        'target': {'kind': 'agent', 'command': 'pi'},
        'prompt': 'p',
      },
    });
    final job = service.handleAsync(frame);
    expect(jsonDecode(await service.handleAsync(frame))['error']['code'], 'bad_params');
    await service.handleAsync('{"cancel":102}');
    expect(jsonDecode(await job)['error']['code'], 'cancelled');
  });
  test('chess automatically retries an invalid move once', () async {
    e.script('pi', r'''
import os,sys
path=os.environ['HOME']+'/asked'
n=int(open(path).read()) if os.path.exists(path) else 0
open(path,'w').write(str(n+1))
text=sys.stdin.read()
if n==0: print('No move.')
else:
 assert 'Your previous answer did not contain' in text
 print('e4')
''');
    final reply = await call('chess.ask', {'command': 'pi', 'start_fen': startFen, 'moves': <String>[]});
    expect(reply['result']['move'], 'e2e4');
    expect(File('${e.home}/asked').readAsStringSync(), '2');
    e.script('pi', "print('No move.')");
    final failed = await call('chess.ask', {'command': 'pi', 'start_fen': startFen, 'moves': <String>[]});
    expect(failed['result']['error'], contains('did not name one of its legal moves'));
  });
}
