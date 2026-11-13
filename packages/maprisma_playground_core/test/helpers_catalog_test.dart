import 'dart:convert';
import 'dart:io';

import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'package:maprisma_playground_core/src/helpers_shipped.g.dart';
import 'package:test/test.dart';

import 'fake_http.dart';
import 'test_environment.dart';

String catalogText(int version, List<Object?> helpers) => jsonEncode({'version': version, 'helpers': helpers});

Map<String, Object?> entry(String id, {List<Object?>? argv, bool stdin = false, bool verified = false, bool ask = true}) => {
  'id': id,
  'name': id.toUpperCase(),
  'command': id,
  'ask': ask ? {'argv': argv ?? [id, '-p', '{prompt}'], 'stdin': stdin} : null,
  'task': {'argv': [id, '{prompt}']},
  'verified': verified,
};

void main() {
  final root = Directory.current.path.endsWith('maprisma_playground_core') ? '.' : 'packages/maprisma_playground_core';
  late TestEnvironment e;
  late String saved;
  late String system;
  setUp(() {
    e = TestEnvironment();
    saved = systemHelpersCatalog;
    system = '${e.home}/usr/lib/maprisma/data/helpers.json';
    systemHelpersCatalog = system;
  });
  tearDown(() {
    systemHelpersCatalog = saved;
    e.dispose();
  });

  test('the shipped catalog is data/helpers.json, built in', () {
    expect(jsonDecode(shippedHelpersJson), jsonDecode(File('$root/data/helpers.json').readAsStringSync()), reason: 'run tools/gen-helpers.py');
    final ids = [for (final h in shippedHelpersCatalog.helpers) h.id];
    expect(ids.take(2), ['claude', 'codex']);
    expect(ids, containsAll(['agy', 'cursor-agent', 'copilot', 'grok', 'hermes', 'omp', 'openclaw', 'pi']));
    expect(ids, isNot(contains('gemini')), reason: 'interactive only: its tools stay on in one-shot mode');
    expect(ids, isNot(contains('opencode')), reason: 'no ask');
  });

  test('catalog parse: broken entries and repeated ids are left out', () {
    final c = parseHelpersCatalog(catalogText(2, [
      entry('good', verified: true),
      entry('noask', ask: false),
      entry('../evil'),
      entry('noprompt', argv: ['noprompt', '-p']),
      entry('other', argv: ['sh', '-c', '{prompt}']),
      entry('nums', argv: ['nums', 1, '{prompt}']),
      entry('piped', argv: ['piped'], stdin: true),
      {'id': 'good', 'command': 'again', 'ask': {'argv': ['again', '{prompt}']}},
      42,
    ]))!;
    expect(c.version, 2);
    expect([for (final h in c.helpers) (h.id, h.verified, h.stdin)], [('good', true, false), ('piped', false, true)]);
    for (final bad in ['', '[]', '{"version": 1}', '{"version": "1", "helpers": []}']) {
      expect(parseHelpersCatalog(bad), isNull, reason: bad);
    }
  });

  test("Maprisma's installed catalog wins when it parses and is at least as new", () {
    final v = shippedHelpersCatalog.version;
    expect(helpersCatalog().helpers.first.id, 'claude');
    e.file('usr/lib/maprisma/data/helpers.json', catalogText(v, [entry('tie')]));
    expect([for (final h in helpersCatalog().helpers) h.id], ['tie']);
    e.file('usr/lib/maprisma/data/helpers.json', catalogText(v + 1, [entry('newer'), entry('gemini')]));
    expect([for (final a in adapters) a.command], ['newer', 'gemini', 'claude', 'codex', 'hermes', 'pi'],
        reason: 'the bundled four are always there');
    e.file('usr/lib/maprisma/data/helpers.json', catalogText(v - 1, [entry('older')]));
    expect(helpersCatalog().helpers.first.id, 'claude');
    e.file('usr/lib/maprisma/data/helpers.json', '{broken');
    expect(helpersCatalog().helpers.first.id, 'claude');
  });

  test('the agents: catalog order, the bundled four keep their adapters', () {
    final list = adapters;
    final commands = [for (final a in list) a.command];
    expect(commands.take(4), ['claude', 'codex', 'agy', 'cursor-agent']);
    expect(commands.indexOf('hermes'), lessThan(commands.indexOf('pi')));
    for (final own in ['claude', 'codex', 'hermes', 'pi']) {
      final a = adapter(own)!;
      expect(a.fromCatalog, isFalse, reason: own);
      expect(a.verified, isTrue, reason: own);
      expect(plays(own), isTrue);
    }
    expect(adapter('pi')!.argv, contains('--no-context-files'), reason: 'stricter than the catalog');
    final cursor = adapter('cursor-agent')!;
    expect(cursor.fromCatalog, isTrue);
    expect(cursor.verified, isFalse);
    expect(cursor.name, 'Cursor CLI');
    expect(cursor.argv, shippedHelpersCatalog.helpers.firstWhere((h) => h.id == 'cursor-agent').argv);
    expect(plays('cursor-agent'), isFalse);
    expect(takesImages('cursor-agent'), isFalse);
    expect(readsUntrusted('cursor-agent'), isFalse);
    expect(canAsk('opencode'), isFalse);
    expect(adapter('gemini'), isNull, reason: 'no one-shot ask in catalog version 2');
    expect(canAsk('gemini'), isFalse);
  });

  test('detection: PATH and the user folders, else mise which (for a command it has a shim for)', () {
    expect(agentExecutable('cursor-agent', e.env), isNull);
    e.file('.npm-global/bin/copilot', '#!/bin/sh\n');
    Process.runSync('/bin/chmod', ['700', '${e.home}/.npm-global/bin/copilot']);
    expect(agentExecutable('copilot', e.env), '${e.home}/.npm-global/bin/copilot');
    // mise in its own data folder (no shims on any searched path): asked `which`, nothing runs
    final real = '${e.home}/installs/cursor-agent';
    e.file('installs/cursor-agent', '#!/bin/sh\necho ran > "${e.home}/ran"\n');
    Process.runSync('/bin/chmod', ['700', real]);
    e.script('mise', 'echo "\$@" >> "${e.home}/mise-args"\n[ "\$1" = which ] && [ "\$2" = cursor-agent ] && echo "$real" && exit 0\nexit 1', interpreter: '/bin/sh');
    final env = {...e.env, 'PATH': '${e.home}/bin:/usr/bin:/bin', 'MISE_DATA_DIR': '${e.home}/mise'};
    expect(agentExecutable('cursor-agent', env), isNull, reason: 'no shim: not asked');
    expect(File('${e.home}/mise-args').existsSync(), isFalse);
    e.file('mise/shims/cursor-agent', '');
    expect(agentExecutable('cursor-agent', env), real);
    expect(File('${e.home}/mise-args').readAsStringSync(), 'which cursor-agent\n');
    expect(agentExecutable('cursor-agent', env), real, reason: 'remembered');
    expect(File('${e.home}/mise-args').readAsStringSync(), 'which cursor-agent\n');
    expect(File('${e.home}/ran').existsSync(), isFalse);
    final info = agentInfo(adapter('cursor-agent')!, env);
    expect(info['installed'], isTrue);
    expect(info['set_up'], isTrue, reason: 'its sign-in is not known here');
    expect(info['verified'], isFalse);
    expect(agentInfo(adapter('claude')!, env)['verified'], isTrue);
  });

  test('argv: the prompt as one argument, never an option, NULs dropped; stdin entries get it there', () {
    const odd = "two words; \$(rm -rf ~) `x` \"q\" 's'\nline";
    final cursor = buildAsk('cursor-agent', odd);
    expect(cursor.argv, ['cursor-agent', '-p', '--mode', 'ask', '--sandbox', 'enabled', '--output-format', 'text', odd]);
    expect(cursor.stdin, isNull);
    expect(buildAsk('cursor-agent', '--version').argv.last, ' --version');
    expect(buildAsk('cursor-agent', 'a\x00b').argv.last, 'ab');
    expect(buildAsk('cursor-agent', 'x', model: 'm').argv, isEmpty, reason: 'no model flag');
    expect(buildAsk('cursor-agent', 'x', images: ['/p.png']).argv, isEmpty);
    expect(catalogAskArgv(['a', '--p={prompt}', '{effort}', '{prompt}'], '-x'), ['a', '--p=-x', ' -x']);
    expect(catalogAskArgv(['a', '-', '{prompt}'], 'x', stdin: true), ['a', '-']);
    e.file('usr/lib/maprisma/data/helpers.json', catalogText(shippedHelpersCatalog.version, [entry('piped', argv: ['piped', '-'], stdin: true)]));
    final piped = buildAsk('piped', 'hello');
    expect(piped.argv, ['piped', '-']);
    expect(utf8.decode(piped.stdin!), 'hello');
  });

  test('the bundled four keep their special handling', () {
    final claude = buildAsk('claude', 'q');
    expect(claude.argv, containsAll(['--output-format', 'json', '--strict-mcp-config']));
    expect(claude.argv, isNot(contains('q')));
    expect(utf8.decode(claude.stdin!), 'q');
    final codex = buildAsk('codex', 'q', images: ['/x.png']);
    expect(codex.argv.last, '-');
    expect(codex.argv, containsAll(['-i', '/x.png', '--sandbox', 'read-only']));
    expect(buildAsk('pi', 'q').argv, contains('--no-skills'));
    expect(buildAsk('hermes', 'q', level: 'deep').argv, containsAll(['--reasoning', 'high', '-z', 'q']));
    expect(parseAnswer('claude', '{"type":"result","result":"hi","usage":{"output_tokens":3}}').tokensOut, 3);
    expect(parseAnswer('cursor-agent', '  the answer \n').text, 'the answer');
  });

  test('askAgent runs a catalog agent with the prompt as its argument; stdout is the answer', () async {
    e.script('cursor-agent', r'''
import sys, os
open(os.environ['HOME'] + '/args', 'w').write('\n'.join(sys.argv[1:]))
open(os.environ['HOME'] + '/stdin', 'w').write(sys.stdin.read())
print('the answer')
''');
    final a = await askAgent(e.runner, 'cursor-agent', '-what is 2+2?');
    expect(a.error, '');
    expect(a.text, 'the answer');
    expect(File('${e.home}/args').readAsStringSync(), '-p\n--mode\nask\n--sandbox\nenabled\n--output-format\ntext\n -what is 2+2?');
    expect(File('${e.home}/stdin').readAsStringSync(), '');
    final long = await askAgent(e.runner, 'cursor-agent', 'x' * (argvPromptMax + 1));
    expect(long.error, contains('too long'));
    expect((await askAgent(e.runner, 'cursor-agent', 'x', images: ['/x.png'])).error, contains('cannot be sent pictures'));
    expect((await askAgent(e.runner, 'cursor-agent', 'x', untrusted: true)).error, contains('untrusted'));
  });

  test('agents.list offers an installed catalog agent as ready and untested', () async {
    final service = CoreService(e.env, runner: e.runner, http: FakeHttp());
    addTearDown(service.dispose);
    e.script('grok', 'print(1)');
    final r = jsonDecode(await service.handleAsync(jsonEncode({'protocol': 1, 'id': 1, 'method': 'agents.list', 'params': {}})));
    final grok = (r['result']['agents'] as List).firstWhere((a) => a['command'] == 'grok');
    expect(grok['installed'], isTrue);
    expect(grok['set_up'], isTrue);
    expect(grok['can_ask'], isTrue);
    expect(grok['plays_chess'], isFalse);
    expect(grok['verified'], isFalse);
  });
}
