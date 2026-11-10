import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'test_environment.dart';

void main() {
  late TestEnvironment e;
  setUp(() => e = TestEnvironment());
  tearDown(() => e.dispose());
  Future<ProcessResult> cli(List<String> args) => Process.run(
    Platform.resolvedExecutable,
    ['${Directory.current.path}/bin/maprisma_playground_core.dart', ...args],
    environment: e.env,
    includeParentEnvironment: false,
  );
  test('CLI agents and call use the same protocol service', () async {
    final agents = await cli(['agents']);
    expect(agents.exitCode, 0);
    expect((jsonDecode(agents.stdout)['result']['agents'] as List).length, 4);
    final info = await cli(['call', 'app.info', '{}']);
    expect(info.exitCode, 0);
    expect(jsonDecode(info.stdout)['result']['version'], '0.1.0');
  });
  test('CLI ask runs only the fake agent', () async {
    e.script('pi', "import sys\nassert sys.stdin.read()=='2+2'\nprint('4')");
    final result = await cli(['ask', 'pi', '2+2']);
    expect(result.exitCode, 0);
    expect(jsonDecode(result.stdout)['result']['text'], '4');
  });
  test('CLI errors use a failing exit code', () async {
    expect((await cli(['call', 'unknown', '{}'])).exitCode, 1);
    expect((await cli(['ask'])).exitCode, 2);
  });
}
