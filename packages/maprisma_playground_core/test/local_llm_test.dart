import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';
import 'fake_http.dart';

void main() {
  late TestEnvironment e;
  setUp(() => e = TestEnvironment());
  tearDown(() => e.dispose());
  test('proc listener ownership IPv4/IPv6 wildcard and foreign uid', () {
    final dir = '${e.home}/proc';
    Directory(dir).createSync();
    File('$dir/tcp').writeAsStringSync(
      'header\n 0: 0100007F:1F90 00000000:0000 0A 0 0 0 1001\n 1: 00000000:1F90 00000000:0000 0A 0 0 0 1002\n 2: 0101A8C0:1F90 00000000:0000 0A 0 0 0 999\n',
    );
    File('$dir/tcp6').writeAsStringSync(
      'header\n 0: 00000000000000000000000001000000:1F90 0:0000 0A 0 0 0 1001\n',
    );
    expect(loopbackListeners(8080, procNet: dir), [1001, 1002, 1001]);
    expect(
      () => requireOwnListener(8080, procNet: dir, uid: 1001),
      throwsStateError,
    );
    expect(
      () => requireOwnListener(9000, procNet: dir, uid: 1001),
      throwsStateError,
    );
    File('$dir/tcp').writeAsStringSync('header\n');
    requireOwnListener(8080, procNet: dir, uid: 1001);
  });
  test('HTTP is literal loopback, direct, no redirects, JSON body', () async {
    final client = FakeClient()..chunks = [utf8.encode('{"ok":true}')];
    final guards = <int>[];
    final http = LocalHttp(guard: guards.add, clientFactory: () => client);
    addTearDown(http.dispose);
    expect(
      await http.json(
        8080,
        '/v1/chat/completions',
        data: {'prompt': 'private'},
      ),
      {'ok': true},
    );
    expect(guards, [8080]);
    final request = client.requests.single;
    expect(request.uri.toString(), 'http://127.0.0.1:8080/v1/chat/completions');
    expect(client.proxy!(request.uri), 'DIRECT');
    expect(request.method, 'POST');
    expect(request.redirects, isFalse);
    expect(jsonDecode(utf8.decode(request.bytes)), {'prompt': 'private'});
    expect(client.closed, isTrue);
  });
  test('foreign listener prevents even constructing a client', () async {
    var created = false;
    final http = LocalHttp(
      guard: (_) => throw StateError('foreign'),
      clientFactory: () {
        created = true;
        return FakeClient();
      },
    );
    await expectLater(http.fetch(8080, '/'), throwsStateError);
    expect(created, isFalse);
  });
  test('redirect, status, content-length and streaming caps', () async {
    for (final status in [301, 302, 307, 400, 500]) {
      final client = FakeClient()..status = status;
      await expectLater(
        LocalHttp(guard: (_) {}, clientFactory: () => client).fetch(8080, '/'),
        throwsA(isA<HttpException>()),
      );
      expect(client.requests.length, 1);
      expect(client.closed, isTrue);
    }
    final big = FakeClient()..length = 100;
    await expectLater(
      LocalHttp(
        guard: (_) {},
        clientFactory: () => big,
      ).fetch(8080, '/', maxBytes: 10),
      throwsA(isA<HttpException>()),
    );
    final streaming = FakeClient()
      ..chunks = [List.filled(7, 65), List.filled(7, 66)];
    await expectLater(
      LocalHttp(
        guard: (_) {},
        clientFactory: () => streaming,
      ).fetch(8080, '/', maxBytes: 10),
      throwsA(isA<HttpException>()),
    );
  });
  test(
    'HTTP deadline and cancellation close the client without network',
    () async {
      final client = FakeClient()..waiting = Completer<HttpClientResponse>();
      await expectLater(
        LocalHttp(
          guard: (_) {},
          clientFactory: () => client,
        ).fetch(8080, '/', timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
      expect(client.closed, isTrue);
      final cancel = CancelToken(),
          other = FakeClient()..waiting = Completer<HttpClientResponse>();
      final job = LocalHttp(
        guard: (_) {},
        clientFactory: () => other,
      ).fetch(8080, '/', cancel: cancel);
      cancel.cancel();
      await expectLater(job, throwsA(isA<Cancelled>()));
      expect(other.closed, isTrue);
    },
  );
  test('shutdown closes and ends pending HTTP immediately', () async {
    final client = FakeClient()..waiting = Completer<HttpClientResponse>();
    final http = LocalHttp(guard: (_) {}, clientFactory: () => client);
    final job = http.fetch(8080, '/');
    http.dispose();
    await expectLater(job, throwsStateError);
    expect(client.closed, isTrue);
  });
  test('invalid HTTP paths rejected; dispose prevents new work', () async {
    final http = LocalHttp(guard: (_) {}, clientFactory: () => FakeClient());
    for (final path in ['http://evil.test', '//evil.test', '/bad#fragment']) {
      await expectLater(http.fetch(8080, path), throwsArgumentError);
    }
    http.dispose();
    await expectLater(http.fetch(8080, '/'), throwsStateError);
  });
  test('model and answer parsing are bounded and type checked', () {
    expect(
      modelIds({
        'data': [
          {'id': 'ok'},
          {'id': 'bad\n'},
          {'id': 2},
          {'id': ''},
        ],
      }),
      ['ok'],
    );
    expect(
      modelIds({
        'data': List.generate(300, (i) => {'id': 'm$i'}),
      }).length,
      200,
    );
    final a = chatAnswer({
      'choices': [
        {
          'message': {'content': ' answer '},
        },
      ],
      'usage': {'prompt_tokens': 3, 'completion_tokens': 5},
    })..seconds = 2;
    expect(a.text, 'answer');
    expect(a.tokensIn, 3);
    expect(a.perSecond, 2.5);
    expect(chatAnswer(null).error, 'no answer');
    expect(
      chatAnswer({
        'usage': {'prompt_tokens': true, 'completion_tokens': -1},
      }).tokensOut,
      isNull,
    );
  });
  test(
    'discovery excludes other accounts and asks only own listeners',
    () async {
      final http = FakeHttp()
        ..replies['/v1/models'] = {
          'data': [
            {'id': 'tiny'},
          ],
        };
      final local = LocalLlm(
        http,
        listeners: (p) => p == 8080
            ? [1001]
            : p == 11434
            ? [1002]
            : [],
        uid: 1001,
      );
      final servers = await local.servers();
      expect(servers.length, 1);
      expect(servers.single['models'], ['tiny']);
      expect(http.calls.single.$1, 8080);
    },
  );
  test('local chat payload and usage', () async {
    final http = FakeHttp()
      ..replies['/v1/chat/completions'] = {
        'choices': [
          {
            'message': {'content': 'four'},
          },
        ],
        'usage': {'completion_tokens': 2},
      };
    final a = await LocalLlm(http).ask(8080, 'tiny', '2+2');
    expect(a.text, 'four');
    expect(a.tokensOut, 2);
    expect(http.calls.single.$3, {
      'model': 'tiny',
      'messages': [
        {'role': 'user', 'content': '2+2'},
      ],
      'stream': false,
    });
  });
  test('GGUF sizes combine shards, exclude projectors, deduplicate links', () {
    e.file('models/Model-00001-of-00002.gguf', '123');
    e.file('models/Model-00002-of-00002.gguf', '4567');
    e.file('models/mmproj-model.gguf', '0' * 20);
    Link(
      '${e.home}/models/copy.gguf',
    ).createSync('${e.home}/models/Model-00001-of-00002.gguf');
    expect(ggufSizes(['${e.home}/models'])['model'], 7);
    expect(
      ggufSizes(['${e.home}/models']).containsKey('mmproj-model'),
      isFalse,
    );
  });
  test('GPU fit, unknown sizes, loaded weights, distinct models', () async {
    final guard = GpuGuard(FakeHttp(), e.runner);
    expect(
      await guard.check(
        [('A', 'llamacpp', 'x'), ('A', 'llamacpp', 'X')],
        memory: (0, 10 * gib),
        files: {},
      ),
      isNull,
    );
    final check = await guard.check(
      [('A', 'llamacpp', 'x'), ('B', 'llamacpp', 'y')],
      memory: (0, 2 * gib),
      files: {'x': gib, 'y': gib},
    );
    expect(check!.fits, isFalse);
    expect(check.needed, greaterThan(2 * gib));
    final unknown = await guard.check(
      [('A', 'llamacpp', 'x'), ('B', 'llamacpp', 'y')],
      memory: (0, 10 * gib),
      files: {'x': gib},
    );
    expect(unknown!.fits, isNull);
    final fits = await guard.check(
      [('A', 'llamacpp', 'x'), ('B', 'llamacpp', 'y')],
      memory: (0, 10 * gib),
      files: {'x': gib, 'y': gib},
    );
    expect(fits!.fits, isTrue);
    expect(
      ModelNeed('A', 'ollama', 'x', size: 100, loaded: true).bytesNeeded,
      0,
    );
  });
  test('unload Ollama payload, no-op other servers', () async {
    final http = FakeHttp()..replies['/api/generate'] = {};
    final guard = GpuGuard(http, e.runner);
    await guard.unload('llamacpp', 'x');
    expect(http.calls, isEmpty);
    await guard.unload('ollama', 'x');
    expect(http.calls.single.$3, {'model': 'x', 'keep_alive': 0});
  });
  test(
    'vision readiness requires every duplicate ini section to name projector',
    () async {
      final http = FakeHttp();
      e.file(
        '.config/llama.cpp/models.ini',
        '[tiny]\nmmproj = /model/mmproj.gguf\n[tiny]\nmmproj = second\n',
      );
      expect(
        await seesPictures(http, 'llamacpp', 'tiny.gguf', environment: e.env),
        isTrue,
      );
      e.file(
        '.config/llama.cpp/models.ini',
        '[tiny]\nmmproj = one\n[tiny]\n# mmproj = absent\n',
      );
      expect(
        await seesPictures(http, 'llamacpp', 'tiny', environment: e.env),
        isFalse,
      );
      expect(
        await seesPictures(http, 'llamacpp', 'other', environment: e.env),
        isNull,
      );
      http.replies['/api/show'] = {
        'capabilities': ['vision'],
      };
      expect(
        await seesPictures(http, 'ollama', 'x', environment: e.env),
        isTrue,
      );
      http.replies['/api/v0/models'] = {
        'data': [
          {'id': 'x', 'type': 'vlm'},
        ],
      };
      expect(
        await seesPictures(http, 'lmstudio', 'x', environment: e.env),
        isTrue,
      );
    },
  );
  test(
    'GPU loaded states match runtime APIs and LM Studio CLI fallback',
    () async {
      final http = FakeHttp()
        ..replies['/models'] = {
          'data': [
            {
              'id': 'warm',
              'status': {'value': 'sleeping'},
            },
            {
              'id': 'cold',
              'status': {'value': 'unloaded'},
            },
          ],
        };
      final guard = GpuGuard(http, e.runner);
      expect(await guard.loaded('llamacpp', 8080), {'warm'});
      e.script('lms', "print('[{\"type\":\"llm\",\"identifier\":\"Small\"}]')");
      expect(await guard.loaded('lmstudio', 1234), {'small'});
    },
  );
  test('GPU fallback CLI honours job cancellation', () async {
    e.script('lms', 'import time\ntime.sleep(60)');
    final token = CancelToken();
    final job = GpuGuard(
      FakeHttp(),
      e.runner,
    ).loaded('lmstudio', 1234, cancel: token);
    Timer(const Duration(milliseconds: 50), token.cancel);
    await expectLater(job, throwsA(isA<Cancelled>()));
    expect(e.runner.liveCount, 0);
  });
}
