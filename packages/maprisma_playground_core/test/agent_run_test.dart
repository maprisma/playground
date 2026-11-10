import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';

void main() {
  late TestEnvironment e;
  setUp(() => e = TestEnvironment());
  tearDown(() => e.dispose());
  test('effort, model validation, Hermes insertion', () {
    expect(runArgv('claude', 'P', level: 'deep').sublist(6), [
      '--effort',
      'high',
      'P',
    ]);
    expect(runArgv('hermes', 'P', level: 'deep'), [
      'hermes',
      '--reasoning',
      'high',
      '-t',
      'todo',
      '--ignore-rules',
      '-z',
      'P',
    ]);
    expect(runArgv('codex', 'P', level: 'max').sublist(8), [
      '-c',
      'model_reasoning_effort=high',
      'P',
    ]);
    expect(runArgv('pi', 'P', level: 'quick').sublist(8), [
      '--thinking',
      'low',
      'P',
    ]);
    expect(
      runArgv('claude', 'P', model: 'vendor/model:tag'),
      containsAllInOrder(['--model', 'vendor/model:tag']),
    );
    for (final bad in ['-option', '@file', 'a b', 'x\n', 'x\nBAD', 'a' * 161]) {
      expect(runArgv('pi', 'P', model: bad), isEmpty, reason: bad);
    }
    expect(runArgv('hermes', 'P', model: 'model'), isEmpty);
    expect(runArgv('unknown', 'P'), isEmpty);
  });
  for (final command in ['claude', 'codex', 'hermes', 'pi']) {
    test('$command prompt transport and private folder cleanup', () async {
      e.script(command, r'''
import os,sys,json
value=json.dumps({'argv':sys.argv[1:],'stdin':sys.stdin.read(),'cwd':os.getcwd(),'mode':os.stat('.').st_mode & 0o777,'files':os.listdir('.')})
if os.path.basename(sys.argv[0])=='claude': print(json.dumps({'type':'result','result':value,'usage':{'input_tokens':2,'output_tokens':3},'total_cost_usd':0.01}))
else: print(value)
''');
      const prompt = r'-@ secret; $(rm -rf ~) "quotes"';
      final answer = await askAgent(e.runner, command, prompt);
      expect(answer.error, isEmpty);
      final data = jsonDecode(answer.text);
      expect(data['mode'], 448);
      expect(data['files'], isEmpty);
      expect(Directory(data['cwd']).existsSync(), isFalse);
      if (command == 'hermes') {
        expect(data['argv'].last, prompt);
        expect(data['stdin'], '');
      } else {
        expect(data['argv'], isNot(contains(prompt)));
        expect(data['stdin'], prompt);
      }
      if (command == 'codex') expect(data['argv'].last, '-');
      if (command == 'claude') {
        expect(answer.tokensIn, 2);
        expect(answer.tokensOut, 3);
        expect(answer.cost, 0.01);
      }
    });
  }
  test('Claude result parsing sums cached input and handles stream JSON', () {
    final out =
        '{"type":"assistant"}\n${jsonEncode({
          'type': 'result',
          'result': ' answer ',
          'usage': {'input_tokens': 2, 'cache_creation_input_tokens': 4, 'cache_read_input_tokens': 8, 'output_tokens': 16},
          'total_cost_usd': 0.12,
        })}\n';
    final a = parseAnswer('claude', out);
    expect(a.text, 'answer');
    expect(a.tokensIn, 14);
    expect(a.tokensOut, 16);
    expect(a.cost, 0.12);
    expect(parseAnswer('claude', 'plain').text, 'plain');
    expect(
      parseAnswer('claude', '{"type":"result","is_error":true}').error,
      contains('reported an error'),
    );
    expect(
      parseAnswer(
        'claude',
        '{"type":"result","usage":{"input_tokens":true,"output_tokens":false}}',
      ).tokensIn,
      0,
    );
  });
  test('image argv and base64 stream, thinking off', () {
    e.file('image.png', 'bytes');
    final image = '${e.home}/image.png';
    final claude = buildAsk('claude', 'look', images: [image]);
    expect(
      claude.argv,
      containsAll(['--input-format', 'stream-json', '--verbose']),
    );
    final data = jsonDecode(utf8.decode(claude.stdin!));
    expect(
      data['message']['content'][0]['source']['data'],
      base64Encode(utf8.encode('bytes')),
    );
    expect(data['message']['content'][1]['text'], 'look');
    expect(
      buildAsk('codex', 'p', images: [image]).argv,
      containsAllInOrder(['-i', image, '-']),
    );
    final pi = buildAsk('pi', 'p', images: [image], think: false);
    expect(pi.argv, contains('@$image'));
    expect(pi.argv, containsAllInOrder(['--thinking', 'off']));
  });
  test('pictures copied under safe names into private folder', () async {
    e.file('-@odd.png', 'bytes');
    e.script('pi', r'''
import os,sys,json
print(json.dumps({'argv':sys.argv[1:],'files':os.listdir('.'),'cwd':os.getcwd()}))
''');
    final a = await askAgent(
      e.runner,
      'pi',
      'look',
      images: ['${e.home}/-@odd.png'],
    );
    final data = jsonDecode(a.text);
    expect(data['files'], ['picture-1.png']);
    expect(
      (data['argv'] as List).where((v) => (v as String).startsWith('@')).single,
      '@${data['cwd']}/picture-1.png',
    );
    expect(Directory(data['cwd']).existsSync(), isFalse);
  });
  test(
    'unsupported/missing/oversized images and untrusted policy fail closed',
    () async {
      expect(
        (await askAgent(e.runner, 'hermes', 'p', images: ['x.png'])).error,
        contains('cannot be sent pictures'),
      );
      expect(checkImage('x.bmp'), contains('Only PNG'));
      expect(checkImage('missing.png'), contains('missing'));
      e.file('large.png', 'x' * (8 * 1024 * 1024 + 1));
      expect(checkImage('${e.home}/large.png'), contains('larger'));
      expect(
        (await askAgent(e.runner, 'codex', 'hostile', untrusted: true)).error,
        contains('untrusted'),
      );
      expect(
        (await askAgent(e.runner, 'unknown', 'p')).error,
        contains('cannot be asked'),
      );
    },
  );
  test('empty output, timeout and cancellation cleanup', () async {
    e.script('pi', '');
    expect(
      (await askAgent(e.runner, 'pi', 'p')).error,
      contains('empty answer'),
    );
    e.script('pi', "import time\ntime.sleep(60)");
    expect(
      (await askAgent(
        e.runner,
        'pi',
        'p',
        timeout: const Duration(milliseconds: 100),
      )).error,
      contains('took too long'),
    );
    final token = CancelToken()..cancel();
    await expectLater(
      askAgent(e.runner, 'pi', 'p', cancel: token),
      throwsA(isA<Cancelled>()),
    );
  });
}
