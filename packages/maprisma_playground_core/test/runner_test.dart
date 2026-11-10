import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';

void main() {
  late TestEnvironment e;
  setUp(() => e = TestEnvironment());
  tearDown(() => e.dispose());
  test(
    'argv is literal, stdin concurrent, environment cleaned, new session',
    () async {
      final exe = e.script('fake', r'''
import os,sys,json
print(json.dumps([sys.argv[1:],sys.stdin.read(),dict(os.environ),os.getpid(),os.getpgrp(),os.getsid(0)]))
''');
      final out = await e.runner.run(
        [exe, r'$(touch BAD); "quoted"'],
        stdin: utf8.encode('private'),
        env: {
          ...e.env,
          'CLAUDECODE': '1',
          'CLAUDE_CODE_CHILD_SESSION': 'x',
          'CLAUDE_PID': '2',
          'CLAUDE_EFFORT': 'max',
          'AI_AGENTS_MAP_NO_PROVIDERS': '1',
          'KEEP': 'yes',
        },
      );
      expect(out.ok, isTrue);
      final data = jsonDecode(out.text);
      expect(data[0], ['\$(touch BAD); "quoted"']);
      expect(data[1], 'private');
      expect(data[2]['KEEP'], 'yes');
      expect(data[2]['NO_COLOR'], '1');
      for (final key in [
        'CLAUDECODE',
        'CLAUDE_CODE_CHILD_SESSION',
        'CLAUDE_PID',
        'CLAUDE_EFFORT',
        'AI_AGENTS_MAP_NO_PROVIDERS',
      ]) {
        expect(data[2].containsKey(key), isFalse);
      }
      expect(data[3], data[4]);
      expect(data[4], data[5]);
      expect(e.runner.liveCount, 0);
    },
  );
  test('byte cap kills flood including merged stderr', () async {
    final exe = e.script('flood', r'''
import os
while True: os.write(2,b'x'*65536)
''');
    final out = await e.runner.run([exe], maxBytes: 1234, mergeStderr: true);
    expect(out.ok, isFalse);
    expect(out.reason, 'output limit');
    expect(out.output.length, 1234);
  });
  test(
    'stdout flood is byte bounded independently of UTF-8 boundaries',
    () async {
      final exe = e.script(
        'stdout-flood',
        "import os\nwhile True: os.write(1,bytes([0xc3,0xa9])*32768)",
      );
      final out = await e.runner.run([exe], maxBytes: 1001);
      expect(out.reason, 'output limit');
      expect(out.output.length, 1001);
      expect(out.text.length, 501);
    },
  );
  test('stderr drained but excluded by default', () async {
    final exe = e.script(
      'stderr',
      "import os\nos.write(2,b'x'*1000000)\nprint('answer')",
    );
    final out = await e.runner.run([exe]);
    expect(out.ok, isTrue);
    expect(out.text.trim(), 'answer');
  });
  test(
    'one deadline covers child retaining stdout and ignoring TERM',
    () async {
      final exe = e.script('fork', r'''
import os,signal,time
child=os.fork()
if child:
 print(child,flush=True)
 os._exit(0)
signal.signal(signal.SIGTERM,signal.SIG_IGN)
time.sleep(60)
''');
      final clock = Stopwatch()..start();
      final out = await e.runner.run([
        exe,
      ], timeout: const Duration(milliseconds: 300));
      expect(out.reason, 'timeout');
      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
      final child = int.parse(out.text.trim());
      final status = File('/proc/$child/status');
      if (status.existsSync()) {
        expect(status.readAsStringSync(), contains('State:\tZ'));
      }
    },
  );
  test('never reading stdin cannot block deadline', () async {
    final exe = e.script(
      'no-read',
      "import time\nprint('ready',flush=True)\ntime.sleep(60)",
    );
    final out = await e.runner.run(
      [exe],
      stdin: List.filled(8 * 1024 * 1024, 65),
      timeout: const Duration(milliseconds: 200),
    );
    expect(out.reason, 'timeout');
    expect(out.text, contains('ready'));
  });
  test('deadline includes parent that closes stdout and stays alive', () async {
    final exe = e.script(
      'closed',
      "import os,time\nos.close(1)\nos.close(2)\ntime.sleep(60)",
    );
    expect(
      (await e.runner.run([
        exe,
      ], timeout: const Duration(milliseconds: 150))).reason,
      'timeout',
    );
  });
  test('cancel kills active group', () async {
    final exe = e.script('wait', "import time\ntime.sleep(60)");
    final token = CancelToken();
    final job = e.runner.run([exe], cancel: token);
    Timer(const Duration(milliseconds: 100), token.cancel);
    await expectLater(job, throwsA(isA<Cancelled>()));
    expect(e.runner.liveCount, 0);
  });
  test('pre-cancel never starts', () async {
    final token = CancelToken()..cancel();
    await expectLater(
      e.runner.run(['/bin/true'], cancel: token),
      throwsA(isA<Cancelled>()),
    );
  });
  test('shutdown terminates all live groups and refuses new work', () async {
    final exe = e.script('wait', "import time\ntime.sleep(60)");
    final jobs = [
      e.runner.run([exe]),
      e.runner.run([exe]),
    ];
    while (e.runner.liveCount < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await e.runner.dispose();
    final results = await Future.wait(jobs);
    expect(results.every((r) => !r.ok), isTrue);
    expect(e.runner.liveCount, 0);
    expect((await e.runner.run([exe])).ok, isFalse);
  });
  test('failed exec, nonzero status, exact cap', () async {
    expect((await e.runner.run(['/not/a/program'])).ok, isFalse);
    final exe = e.script('exit', "print('abc',end='')\nraise SystemExit(2)");
    final out = await e.runner.run([exe], maxBytes: 3);
    expect(out.text, 'abc');
    expect(out.ok, isFalse);
    final yes = e.script('yes', "print('abc',end='')");
    expect((await e.runner.run([yes], maxBytes: 3)).ok, isTrue);
  });
}
