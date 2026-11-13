import 'dart:io';

import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('playground-shared-ai-');
    file = p.join(dir.path, 'config/maprisma-ai/settings.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void put(String text) => File(file)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  test('the file sits next to the app folder: XDG_CONFIG_HOME (else ~/.config)/maprisma-ai', () {
    final home = p.join(dir.path, 'home');
    expect(Places.fromEnv({'HOME': home}).sharedAiFile, '$home/.config/maprisma-ai/settings.json');
    expect(Places.fromEnv({'HOME': home, 'XDG_CONFIG_HOME': '/x/cfg'}).sharedAiFile, '/x/cfg/maprisma-ai/settings.json');
    expect(Places.fromEnv({'HOME': home, 'XDG_CONFIG_HOME': 'rel'}).sharedAiFile, '$home/.config/maprisma-ai/settings.json');
  });

  test('read: missing or broken file and invalid values are auto; valid ids pass; unknown keys ignored', () {
    expect(readSharedHelper(file), 'auto');
    for (final (text, want) in [
      ('not json', 'auto'),
      ('[1]', 'auto'),
      ('{}', 'auto'),
      ('{"helper": null}', 'auto'),
      ('{"helper": 3}', 'auto'),
      ('{"helper": ""}', 'auto'),
      ('{"helper": "-x"}', 'auto'),
      ('{"helper": "a b"}', 'auto'),
      ('{"helper": "${'a' * 162}"}', 'auto'),
      ('{"helper": "auto"}', 'auto'),
      ('{"helper": "codex", "other": {"k": 1}}', 'codex'),
      ('{"helper": "pi:ollama/qwen3:8b"}', 'pi:ollama/qwen3:8b'),
      ('{"helper": "${'a' * 161}"}', 'a' * 161),
    ]) {
      put(text);
      expect(readSharedHelper(file), want, reason: text);
    }
  });

  test('read: a link is not followed (auto)', () {
    final real = p.join(dir.path, 'real.json');
    File(real).writeAsStringSync('{"helper": "codex"}');
    Directory(p.dirname(file)).createSync(recursive: true);
    Link(file).createSync(real);
    expect(readSharedHelper(file), 'auto');
  });

  test('resolve: the chosen agent when ready, else the first ready one (auto), else none', () {
    expect(sharedHelperCommand('pi:ollama/qwen3:8b'), 'pi');
    expect(sharedHelperCommand('claude'), 'claude');
    expect(resolveSharedHelper('auto', ['claude', 'codex']), 'claude');
    expect(resolveSharedHelper('codex', ['claude', 'codex']), 'codex');
    expect(resolveSharedHelper('pi:ollama/x', ['claude', 'pi']), 'pi');
    expect(resolveSharedHelper('grok', ['claude', 'codex']), 'claude', reason: 'not installed: auto');
    expect(resolveSharedHelper('codex', []), isNull);
  });
}
