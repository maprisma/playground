import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';
import 'fake_http.dart';

void main() {
  late TestEnvironment e;
  late CoreService service;
  late List<Map<String, dynamic>> events;
  var next = 0;
  setUp(() {
    e = TestEnvironment();
    events = [];
    service = CoreService(
      e.env,
      runner: e.runner,
      http: FakeHttp(),
      onEvent: (f) => events.add((jsonDecode(f) as Map).cast<String, dynamic>()),
    );
  });
  tearDown(() async {
    await service.dispose();
    await e.dispose();
  });
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async =>
      (jsonDecode(
                await service.handleAsync(
                  jsonEncode({'protocol': 1, 'id': next++, 'method': method, 'params': params}),
                ),
              )
              as Map)
          .cast<String, dynamic>();
  test('GPU missing figures and unknown sizes retain exact tri-state shape', () async {
    expect((await call('gpu.check', {'targets': []}))['result'], {
      'fits': true,
      'message': '',
      'needs': [],
      'needed': null,
      'free': null,
      'total': null,
    });
    final unknown = GpuCheck(
      [ModelNeed('a', 'ollama', 'a'), ModelNeed('b', 'ollama', 'b', loaded: true)],
      free: gib,
      total: 2 * gib,
    ).toJson();
    expect(unknown['fits'], isNull);
    expect(unknown['needs'], [
      {'label': 'a', 'loaded': false, 'size': null, 'bytes_needed': null},
      {'label': 'b', 'loaded': true, 'size': null, 'bytes_needed': 0},
    ]);
    expect(unknown['needed'], 0);
    expect(GpuCheck([ModelNeed('a', 'ollama', 'a')]).toJson()['fits'], true);
  });
  test('new methods return UI field names and prepared images can be asked', () async {
    final raw = '${e.home}/raw.png';
    File(raw).writeAsBytesSync(img.encodePng(img.Image(width: 3, height: 3, numChannels: 3)));
    final prepared = (await call('pictures.prepare', {'path': raw}))['result']['path'];
    expect(prepared, isA<String>());
    e.script('claude', "import sys,json\nsys.stdin.read();print(json.dumps({'type':'result','result':'Red'}))");
    expect(
      (await call('ask.run', {
        'target': {'kind': 'agent', 'command': 'claude'},
        'prompt': 'Q',
        'images': [prepared],
      }))['result']['text'],
      'Red',
    );
    final rejected = await call('ask.run', {
      'target': {'kind': 'agent', 'command': 'codex'},
      'prompt': 'Q',
      'images': [prepared],
    });
    expect(rejected['error']['code'], 'bad_params');
    expect((await call('pictures.clear'))['result'], {});
    expect(File(prepared).existsSync(), false);
    final status = (await call('generate.status'))['result'];
    expect(status.keys.toSet(), {'ready', 'program', 'to_download', 'folder'});
    expect((await call('generate.clear'))['result'], {});
    expect((await call('pictures.prepare', {'path': '$raw-missing'}))['error'], {
      'code': 'failed',
      'message': 'That picture cannot be read.',
    });
  });
  test('service analyze emits exactly seven final findings then empty result', () async {
    e.script(
      'claude',
      "import sys,json\np=sys.stdin.read();print(json.dumps({'type':'result','result':'391' if '17 times' in p else 'red' if 'colour' in p else 'e4'}))",
    );
    final choices = (await call('analyze.choices', {'command': 'claude'}))['result']['choices'] as List;
    expect(choices.first, {'label': 'Its own model', 'arg': ''});
    expect((await call('analyze.run', {'command': 'claude', 'choice': choices[2]}))['result'], {});
    final findings = events.where((e) => e['event'] == 'finding').map((e) => e['data'] as Map).toList();
    expect(findings, hasLength(7));
    expect(findings.map((f) => f['key']).toSet(), {
      'text',
      'pictures',
      'video',
      'thinking',
      'chess',
      'context',
      'making',
    });
    expect(findings.every((f) => f.keys.contains('state') && f.keys.contains('detail')), true);
  });
  test('saved-game method results, paging, private PGN and deletion', () async {
    final result = (await call('games.save', {
      'game': {
        'name': 'A game',
        'start_fen': startFen,
        'moves': ['e2e4'],
        'white': 'You',
        'black': 'Pi',
      },
    }))['result'];
    final id = result['id'];
    expect(id, isA<String>());
    var listed = (await call('games.list', {'query': 'game', 'offset': 0, 'limit': 10}))['result'];
    expect(listed['total'], 1);
    expect(listed['games'].single['name'], 'A game');
    expect(listed['games'].single['start_fen'], startFen);
    expect((await call('games.rename', {'id': id, 'name': 'New title'}))['result'], {});
    final path = '${e.home}/game.pgn';
    expect((await call('games.pgn', {'id': id, 'path': path}))['result'], {});
    expect(File(path).readAsStringSync(), contains('[Event "New title"]'));
    expect(File(path).statSync().mode & 511, 384);
    expect((await call('games.delete', {'id': id}))['result'], {});
    listed = (await call('games.list'))['result'];
    expect(listed, {'games': [], 'total': 0});
  });
  test('projector offer is downloaded, checked, backed up and written to shared INI', () async {
    e.file('.config/llama.cpp/models.ini', '[M]\nctx-size = 1\n');
    final digest = sha256.convert(utf8.encode('vision')).toString();
    e.script(
      'curl',
      "import sys,json\nif '/api/models/' in sys.argv[-1]:print(json.dumps([{'path':'mmproj-BF16.gguf','lfs':{'size':6,'oid':'$digest'}}]))\nelse:sys.stdout.buffer.write(b'vision')",
    );
    e.script('systemctl', '');
    final offer = await service.frames.hfMmproj('publisher/model', e.home, 'M', CancelToken());
    expect(offer, isNotNull);
    expect(
      (await call('vision.setup', {
        'command': 'pi',
        'choice': {'arg': ''},
        'download': offer,
      }))['result'],
      {},
    );
    expect(File(offer!['target']).readAsStringSync(), 'vision');
    expect(File('${e.home}/.config/llama.cpp/models.ini').readAsStringSync(), contains('mmproj = ${offer['target']}'));
    expect(Directory('${e.home}/.local/state/ai-playground/backups').listSync(), isNotEmpty);
    expect(events.where((e) => e['event'] == 'progress').last['data']['fraction'], 1);
    expect(
      (await call('vision.setup', {
        'command': 'pi',
        'choice': {},
        'download': {...offer, 'target': '${e.home}/.bashrc'},
      }))['error']['code'],
      'bad_params',
    );
  });
  test('cancel frame interrupts analyze and disposal removes session folders', () async {
    e.script('claude', "import sys,time\nsys.stdin.read();time.sleep(30)");
    final id = next++;
    final work = service.handleAsync(
      jsonEncode({
        'protocol': 1,
        'id': id,
        'method': 'analyze.run',
        'params': {'command': 'claude', 'choice': {}},
      }),
    );
    for (var i = 0; i < 500 && e.runner.liveCount == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await service.handleAsync(jsonEncode({'cancel': id}));
    expect(jsonDecode(await work)['error']['code'], 'cancelled');
    final a = service.pictures.folder.path, b = service.generation.folder.path;
    await service.dispose();
    expect(Directory(a).existsSync(), false);
    expect(Directory(b).existsSync(), false);
    expect(e.runner.liveCount, 0);
  });
}
