import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';
import 'fake_http.dart';

void main() {
  late TestEnvironment e;
  late CoreService core;
  var serial = 0;
  setUp(() {
    e = TestEnvironment();
    core = CoreService(e.env, runner: e.runner, http: FakeHttp());
  });
  tearDown(() async {
    await core.dispose();
    await e.dispose();
  });
  Future<Map> call(String method, [Map params = const {}]) async =>
      jsonDecode(
            await core.handleAsync(jsonEncode({'protocol': 1, 'id': ++serial, 'method': method, 'params': params})),
          )
          as Map;

  test('UI game records, title search, duplicate and in-place update', () async {
    final game = {
      'id': 'plugin-id',
      'title': 'Opening',
      'date': '2026-01-02',
      'start': startFen,
      'moves': ['e2e4'],
      'white': 'You',
      'black': 'Pi',
    };
    expect((await call('games.save', {'game': game}))['result'], {'id': 'plugin-id'});
    expect(
      (await call('games.save', {
        'game': {...game}..remove('id'),
      }))['result'],
      {'id': 'plugin-id', 'duplicate': true},
    );
    await call('games.save', {
      'game': {
        ...game,
        'id': 'second',
        'title': 'Second',
        'moves': ['d2d4'],
      },
    });
    await call('games.save', {
      'game': {
        ...game,
        'title': 'Updated',
        'moves': ['e2e4', 'e7e5'],
      },
    });
    final listed = (await call('games.list', {'offset': 1, 'limit': 1}))['result'];
    expect(listed['total'], 2);
    final record = (listed['games'] as List).single as Map;
    expect(record, containsPair('id', 'plugin-id'));
    expect(record, containsPair('title', 'Updated'));
    expect(record, containsPair('source', ''));
    expect(record, containsPair('kind', 'played'));
    expect(record, containsPair('start', startFen));
    expect(record, containsPair('result', '*'));
    expect(record['date'], '2026-01-02 00:00');
    expect(record['date'], matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d$')));
    await call('games.rename', {'id': 'plugin-id', 'name': 'Renamed'});
    final found = (await call('games.list', {'query': 'renamed', 'limit': 0}))['result'];
    expect(found, {'games': [], 'total': 1});
  });

  test('usual install folders resolve absolute executables and extend shim PATH', () async {
    final original = e.script(
      'pi',
      "import sys,subprocess\nsys.stdin.read();print(subprocess.check_output(['shim-helper']).decode().strip())",
    );
    final folder = Directory('${e.home}/.local/share/mise/shims')..createSync(recursive: true);
    File(original).renameSync('${folder.path}/pi');
    final helper = e.script('shim-helper', "print('shim works')");
    File(helper).renameSync('${folder.path}/shim-helper');
    e.file('.pi/agent/auth.json', '{}');
    expect(executableOnPath('pi', e.env), '${folder.path}/pi');
    final agents = (await call('agents.list'))['result']['agents'] as List;
    expect(agents.firstWhere((a) => a['command'] == 'pi')['installed'], true);
    final answer = (await call('ask.run', {
      'target': {'kind': 'agent', 'command': 'pi'},
      'prompt': 'Q',
    }))['result'];
    expect(answer['text'], 'shim works');
    expect(answer.containsKey('per_second'), false);
    File('${folder.path}/pi').writeAsStringSync('no exec');
    await Process.run('/bin/chmod', ['600', '${folder.path}/pi']);
    expect(executableOnPath('pi', e.env), isNull);
    Directory('${e.home}/bin/pi').createSync();
    expect(executableOnPath('pi', e.env), isNull);
  });

  test('reader commands, text-only Hermes, video-key before and duration', () async {
    e.script('claude', '');
    e.script('hermes', '');
    e.file('.claude/.credentials.json', '{}');
    e.file('.hermes/auth.json', '{}');
    final saved = core.games.save({
      'title': 'Video',
      'source': 'https://youtu.be/abcdefg',
      'start': startFen,
      'moves': ['e2e4'],
    });
    var info = (await call('import.readers', {'url': 'https://youtube.com/watch?v=abcdefg&t=1s'}))['result'];
    expect(info['readers'], ['claude']);
    expect(info['text_readers'], containsAll(['claude', 'hermes']));
    expect(info['before'], {'id': saved['id'], 'title': 'Video', 'date': saved['date']});
    e.file('video.mp4', 'fake');
    e.script('ffprobe', "print('123.5')");
    info = (await call('import.readers', {'path': '${e.home}/video.mp4'}))['result'];
    expect(info['seconds'], 123.5);
  });

  test('cancelled text import retains short description; empty reading stays cancelled', () async {
    e.script('yt-dlp', "import json\nprint(json.dumps({'title':'Short','description':'1. e4'}))");
    final events = <Map>[];
    core.onEvent = (frame) {
      final event = jsonDecode(frame) as Map;
      events.add(event);
      if (event['data']['text'] == 'Reading the commentary…') {
        core.handleAsync(jsonEncode({'cancel': event['id']}));
      }
    };
    var reply = await call('import.start', {'url': 'https://youtu.be/abcdefg', 'reader': 'claude', 'way': 'text'});
    expect(reply['result']['game']['moves'], ['e2e4']);
    expect(reply['result']['read'], 'description');
    expect(reply['result']['unmatched'], 0);
    expect(events.every((e) => !(e['data'] as Map).containsKey('fraction')), true);
    core.onEvent = (frame) {
      final event = jsonDecode(frame) as Map;
      core.handleAsync(jsonEncode({'cancel': event['id']}));
    };
    reply = await call('import.start', {'url': 'https://youtu.be/hijklmn', 'reader': 'claude', 'way': 'text'});
    expect(reply['error']['code'], 'cancelled');
    expect(core.games.load(), hasLength(1));
  });

  test('null shutdown kills a child and its grandchild and removes session folders', () async {
    e.script(
      'pi',
      "import subprocess,os,sys,time\nsys.stdin.read()\np=subprocess.Popen(['/bin/sleep','30'])\nopen(os.environ['HOME']+'/pids','w').write(str(os.getpid())+' '+str(p.pid))\ntime.sleep(30)",
    );
    final work = call('ask.run', {
      'target': {'kind': 'agent', 'command': 'pi'},
      'prompt': 'Q',
    });
    final file = File('${e.home}/pids');
    for (var i = 0; i < 1000 && !file.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(file.existsSync(), true);
    final children = file.readAsStringSync().split(' ');
    final folders = [core.pictures.folder.path, core.generation.folder.path];
    expect(await core.handleAsync('null').timeout(const Duration(seconds: 3)), 'null');
    expect((await work)['error']['code'], 'cancelled');
    expect(e.runner.liveCount, 0);
    for (final folder in folders) {
      expect(Directory(folder).existsSync(), false);
    }
    for (final child in children) {
      final stat = File('/proc/$child/stat');
      expect(!stat.existsSync() || stat.readAsStringSync().split(' ')[2] == 'Z', true);
    }
  });
}
