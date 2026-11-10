// Port of upstream test_playground.py AnalyzeTest and FrameCheckTest.
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';
import 'fake_http.dart';

class TestHold extends LocalHold {
  TestHold(super.runtime, super.http, super.runner);
  @override
  Future<void> open({Duration wait = const Duration(seconds: 120), CancelToken? cancel}) async {
    cancel?.check();
  }

  @override
  Future<void> release() async {}
}

class ProbeFrames extends FrameCheck {
  ProbeFrames(super.runner, super.http) : super(holdFactory: (runtime) => TestHold(runtime, http, runner));
  Answer answer = Answer(text: 'Red', seconds: 3);
  int probes = 0;
  @override
  Future<Answer> probe(String command, String model, CancelToken token) async {
    token.check();
    probes++;
    return answer;
  }
}

void main() {
  late TestEnvironment e;
  late FakeHttp http;
  late ProbeFrames frames;
  late Analyze analyze;
  setUp(() {
    e = TestEnvironment();
    http = FakeHttp();
    frames = ProbeFrames(e.runner, http);
    analyze = Analyze(e.runner, http, frames);
  });
  tearDown(() async {
    http.dispose();
    await e.dispose();
  });
  test('Pi model list preserves provider, context, thinking and images', () async {
    e.script(
      'pi',
      "print('provider model context max-out thinking images\\nllama-local gemma-4-26B-A4B-it-UD-Q4_K_M 98.3K 8.2K yes yes\\nllama-local qwen3-tts-12hz-0.6b-base-q8_0 131.1K 8.2K no no\\nanthropic claude-sonnet-5 1M 64K yes yes')",
    );
    final found = await analyze.choices('pi', CancelToken());
    expect(found.first['label'], 'Its own model');
    expect(found[1]['arg'], 'llama-local/gemma-4-26B-A4B-it-UD-Q4_K_M');
    expect(found[1]['local'], {'runtime': 'llamacpp', 'model': 'gemma-4-26B-A4B-it-UD-Q4_K_M'});
    expect(found[1]['context'], 98300);
    expect(found[1]['thinking'], true);
    expect(found[1]['images'], true);
    expect(found[2]['images'], false);
    expect(found[2]['thinking'], false);
    expect(found[3]['context'], 1000000);
    expect(found[3].containsKey('local'), false);
  });
  test('own Pi local model first with metadata and no duplicate', () async {
    e.file('.pi/agent/settings.json', jsonEncode({'defaultProvider': 'llama-local', 'defaultModel': 'gemma'}));
    e.script('pi', "print('provider model context max-out thinking images\\nllama-local gemma 98.3K 8.2K yes yes')");
    final found = await analyze.choices('pi', CancelToken());
    expect(found, hasLength(1));
    expect(found.first['images'], true);
    expect(found.first['arg'], '');
    expect(found.first['local'], {'runtime': 'llamacpp', 'model': 'gemma'});
  });
  test('Codex cached models carry input kinds, levels and context; hidden invalid omitted', () async {
    e.file('.codex/config.toml', 'model = "gpt-a"\n');
    e.file(
      '.codex/models_cache.json',
      jsonEncode({
        'models': [
          {
            'slug': 'gpt-a',
            'display_name': 'GPT A',
            'visibility': 'list',
            'input_modalities': ['text', 'image'],
            'supported_reasoning_levels': [
              {'effort': 'low'},
              {'effort': 'high'},
            ],
            'context_window': 272000,
          },
          {'slug': 'hidden', 'visibility': 'hide'},
          {
            'slug': 'gpt-b',
            'visibility': 'list',
            'input_modalities': ['text'],
          },
          {'slug': '--evil', 'visibility': 'list'},
        ],
      }),
    );
    final found = await analyze.choices('codex', CancelToken());
    expect(found.map((c) => c['arg']), ['', 'gpt-b']);
    expect(found.first['images'], true);
    expect(found.first['levels'], ['low', 'high']);
    expect(found.first['context'], 272000);
    expect(found.last['images'], false);
  });
  test('Claude aliases and Hermes own model', () async {
    expect((await analyze.choices('claude', CancelToken())).map((c) => c['arg']), ['', 'fable', 'opus', 'sonnet']);
    expect((await analyze.choices('hermes', CancelToken())).single['arg'], '');
  });
  void agent({bool bad = false}) {
    e.script(
      'claude',
      "import sys,json,os\np=sys.stdin.read()\nopen(os.environ['HOME']+'/argv','a').write(json.dumps(sys.argv)+'\\n')\nprint(json.dumps({'type':'result','result':${bad ? "'wrong'" : "'391' if '17 times' in p else 'e4'"},'total_cost_usd':0.01}))",
    );
  }

  test('every card gets finding and chosen model reaches every agent question', () async {
    agent();
    final found = <String, Map<String, Object?>>{};
    await analyze.run('claude', {'arg': 'sonnet'}, CancelToken(), (f) => found[f['key'] as String] = f);
    expect(found.map((k, v) => MapEntry(k, v['state'])), {
      'text': 'yes',
      'pictures': 'yes',
      'video': 'yes',
      'thinking': 'yes',
      'chess': 'yes',
      'context': 'unknown',
      'making': 'no',
    });
    expect(found['text']!['summary'], contains('\$0.0100'));
    final runs = File('${e.home}/argv').readAsLinesSync().map((s) => jsonDecode(s) as List);
    expect(runs.every((a) => a[a.indexOf('--model') + 1] == 'sonnet'), true);
  });
  test('no text skips all remaining probes', () async {
    agent(bad: true);
    final findings = <Map<String, Object?>>[];
    await analyze.run('claude', {}, CancelToken(), findings.add);
    expect(findings.firstWhere((f) => f['key'] == 'pictures')['state'], 'skipped');
    expect(frames.probes, 0);
  });
  test('no images, slow vision and thinking facts', () async {
    agent();
    frames.answer = Answer(text: 'Red', seconds: 30);
    final found = <String, Map<String, Object?>>{};
    await analyze.run(
      'claude',
      {'thinking': false, 'context': 1000000},
      CancelToken(),
      (f) => found[f['key'] as String] = f,
    );
    expect(found['video']!['state'], 'slow');
    expect(found['thinking']!['state'], 'no');
    expect(found['context']!['summary'], '1,000,000 tokens');
    found.clear();
    await analyze.run('claude', {'images': false}, CancelToken(), (f) => found[f['key'] as String] = f);
    expect(found['pictures']!['summary'], 'text only');
    expect(found['video']!['state'], 'no');
  });
  test('cancellation stops outstanding questions', () async {
    e.script('claude', "import time,sys\nsys.stdin.read();time.sleep(30)");
    final token = CancelToken();
    final future = analyze.run('claude', {}, token, (f) {
      if (f['key'] == 'making') token.cancel();
    });
    await expectLater(future, throwsA(isA<Cancelled>()));
    expect(e.runner.liveCount, 0);
  });
  test('vision INI duplicate sections, CRLF, idempotence and injection guards', () {
    const text = '[*]\r\nctx-size = 1\r\n[Qwen-27B] \r\nctx-size = 2\r\n[Other]\r\n[Qwen-27B]\r\nctx-size = 3\r\n';
    final updated = iniWithMmproj(text, 'qwen-27b', '/m/mmproj-q.gguf')!;
    expect('mmproj = /m/mmproj-q.gguf\r\n'.allMatches(updated), hasLength(2));
    expect(iniWithMmproj(updated, 'qwen-27b', '/m/mmproj-q.gguf'), updated);
    expect(iniWithMmproj(text, 'missing', '/m/x.gguf'), isNull);
    expect(iniWithMmproj(text, 'qwen-27b', '/m/x\n[evil]'), isNull);
    expect(iniWithMmproj(text, 'qwen-27b', 'relative.gguf'), isNull);
  });
  test('Pi pictures and thinking switch applied once, preserve other model', () async {
    e.file(
      '.pi/agent/models.json',
      jsonEncode({
        'providers': {
          'llama-local': {
            'models': [
              {
                'id': 'Gemma',
                'input': ['text'],
              },
              {'id': 'Other'},
            ],
          },
        },
      }),
    );
    http.replies['/props?model=gemma'] = {'chat_template': 'enable_thinking'};
    await frames.fixPi('llamacpp', 'gemma', CancelToken());
    final data =
        jsonDecode(File('${e.home}/.pi/agent/models.json').readAsStringSync())['providers']['llama-local']['models']
            as List;
    expect(data.first['input'], ['text', 'image']);
    expect(data.first['reasoning'], true);
    expect(data.first['compat']['thinkingFormat'], 'chat-template');
    expect(data.last.containsKey('input'), false);
    final backup = Directory('${e.home}/.local/state/ai-playground/backups');
    final count = backup.listSync().length;
    await frames.fixPi('llamacpp', 'gemma', CancelToken());
    expect(backup.listSync(), hasLength(count));
    final entry = <String, dynamic>{'id': 'm'};
    expect(piEntryFixed(entry, false), true);
    expect(entry.containsKey('compat'), false);
  });
  test('HF selects BF16 checksum, sanitizes section, keeps target next to model', () async {
    e.script(
      'curl',
      "import json\nprint(json.dumps([{'path':'mmproj-F32.gguf','lfs':{'size':2000,'oid':'${'a' * 64}'}},{'path':'mmproj-BF16.gguf','lfs':{'size':1000,'oid':'${'a' * 64}'}},{'path':'sub/mmproj.gguf','lfs':{'size':10,'oid':'${'a' * 64}'}},{'path':'mmproj-bad.gguf','lfs':{'size':10,'oid':'bad'}}]))",
    );
    final d = await frames.hfMmproj('unsloth/x', e.home, '../../.bashrc\n[x]', CancelToken());
    expect(d!['path'], 'mmproj-BF16.gguf');
    expect(d['size'], 1000);
    expect(File(d['target']).parent.path, e.home);
    expect(d['target'], isNot(contains('\n')));
    Process.runSync('/bin/chmod', ['777', e.home]);
    try {
      expect(await frames.hfMmproj('unsloth/x', e.home, 'x', CancelToken()), isNull);
    } finally {
      Process.runSync('/bin/chmod', ['700', e.home]);
    }
  });
  test('Ollama no vision is explained and ready probe cached until forget', () async {
    http.replies['/api/show'] = {
      'capabilities': ['completion'],
    };
    expect((await frames.check('pi', 'ollama', 'm', '', CancelToken())).state, 'no');
    frames.forget('pi');
    http.replies['/api/show'] = {
      'capabilities': ['vision'],
    };
    expect((await frames.check('pi', 'ollama', 'm', '', CancelToken())).state, 'ready');
    expect((await frames.check('pi', 'ollama', 'm', '', CancelToken())).state, 'ready');
    expect(frames.probes, 1);
    frames.forget('pi');
    await frames.check('pi', 'ollama', 'm', '', CancelToken());
    expect(frames.probes, 2);
  });
  test('unknown projector request cannot write to arbitrary destination', () async {
    await expectLater(frames.setup('pi', {'target': '${e.home}/.bashrc'}, CancelToken(), (_) {}), throwsArgumentError);
  });
}
