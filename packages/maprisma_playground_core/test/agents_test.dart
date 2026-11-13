import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';

void main() {
  late TestEnvironment e;
  setUp(() => e = TestEnvironment());
  tearDown(() => e.dispose());
  test('four bundled adapters and distinct capabilities; the catalog\'s other agents can only be asked', () {
    final own = [for (final a in adapters) if (!a.fromCatalog) a.command];
    expect(own, ['claude', 'codex', 'hermes', 'pi']);
    for (final a in adapters) {
      expect(canAsk(a.command), isTrue);
      expect(plays(a.command), a.fromCatalog ? isFalse : isTrue, reason: a.command);
      expect(plays(a.command, 'poker'), isFalse);
      if (a.fromCatalog) {
        expect(takesImages(a.command), isFalse);
        expect(readsUntrusted(a.command), isFalse, reason: 'tools or not, it is not trusted with outside input');
      }
    }
    expect(takesImages('codex'), isTrue);
    expect(readsUntrusted('codex'), isFalse);
    expect(takesImages('hermes'), isFalse);
    expect(readsUntrusted('hermes'), isTrue);
    expect(canAsk('opencode'), isFalse);
  });
  test('installed uses supplied PATH and executable bit', () {
    expect(executableOnPath('claude', e.env), isNull);
    e.file('bin/claude', 'not executable');
    expect(executableOnPath('claude', e.env), isNull);
    final path = e.script('claude', '');
    expect(executableOnPath('claude', e.env), path);
  });
  for (final command in ['claude', 'codex', 'hermes', 'pi']) {
    test('$command credentials are stat-only (invalid and unreadable content)', () {
      final a = adapter(command)!;
      expect(agentSetUp(command, e.env), isFalse);
      e.file(a.files.first, 'not JSON; secret content never parsed');
      Process.runSync('/bin/chmod', ['000', '${e.home}/${a.files.first}']);
      expect(agentSetUp(command, e.env), isTrue);
    });
  }
  test('credential env and missing credential file', () {
    expect(agentSetUp('claude', {...e.env, 'ANTHROPIC_API_KEY': 'key'}), isTrue);
    expect(agentSetUp('codex', {...e.env, 'OPENAI_API_KEY': ''}), isFalse);
    expect(agentSetUp('unknown', e.env), isFalse);
  });
  test('local provider readiness includes inactive configured entries', () {
    e.file('.pi/agent/settings.json', '{"defaultProvider":"remote"}');
    e.file('.pi/agent/models.json', '{"providers":{"unused":{"baseUrl":"http://localhost:8080/v1"}}}');
    e.file(
      '.codex/config.toml',
      'model_provider="remote"\n[model_providers.local]\nbase_url="http://127.0.0.1:8080/v1"\n',
    );
    e.file(
      '.hermes/config.yaml',
      'model:\n  default: test\n  provider: remote\nproviders:\n  local:\n    api: http://localhost:8080/v1\n',
    );
    for (final command in ['pi', 'codex', 'hermes']) {
      expect(agentSetUp(command, e.env), isTrue, reason: command);
    }
    // Claude's adapter has no local_ok, even when its config names a local URL.
    e.file('.claude/settings.json', '{"env":{"ANTHROPIC_BASE_URL":"http://localhost:8080"}}');
    expect(hasLocalProvider('claude', e.env), isTrue);
    expect(agentSetUp('claude', e.env), isFalse);
  });
  test('remote, malformed and oversized configs are not local providers', () {
    e.file('.pi/agent/models.json', '{"providers":{"x":{"baseUrl":"https://localhost.evil.test"}}}');
    expect(agentSetUp('pi', e.env), isFalse);
    e.file('.codex/config.toml', '[model_providers.x]\nbase_url = "https://example.test"');
    expect(agentSetUp('codex', e.env), isFalse);
    e.file('.hermes/config.yaml', 'model:\n  base_url: https://example.test\n');
    expect(agentSetUp('hermes', e.env), isFalse);
    e.file('.pi/agent/models.json', 'x' * (1024 * 1024 + 1));
    expect(agentSetUp('pi', e.env), isFalse);
  });
  test('selected model for GPU guard', () {
    e.file('.pi/agent/settings.json', '{"defaultProvider":"ollama-local","defaultModel":"tiny"}');
    expect(localAgentModel('pi', e.env), ('ollama', 'tiny'));
    e.file('.codex/config.toml', 'model="gemma"\nmodel_provider="llama-local"\n');
    expect(localAgentModel('codex', e.env), ('llamacpp', 'gemma'));
    e.file('.hermes/config.yaml', 'model:\n  default: gemma\n  provider: llama-local\n');
    expect(localAgentModel('hermes', e.env), ('llamacpp', 'gemma'));
  });
  test('TOML inline tables and JSON comments use real configuration readers', () {
    e.file('.codex/config.toml', 'model_providers = { local = { base_url = "http://localhost:8080/v1" } }');
    expect(agentSetUp('codex', e.env), isTrue);
    e.file(
      '.pi/agent/models.json',
      '{"providers": { // configured providers\n"local":{"baseUrl":"http://127.0.0.1:8080",},},}',
    );
    expect(agentSetUp('pi', e.env), isTrue);
    e.file('.codex/config.toml', '[broken');
    expect(agentSetUp('codex', e.env), isFalse);
  });
  test('provider config links are not followed', () {
    e.file('actual.json', '{"providers":{"x":{"baseUrl":"http://localhost:8080"}}}');
    Directory('${e.home}/.pi/agent').createSync(recursive: true);
    Link('${e.home}/.pi/agent/models.json').createSync('${e.home}/actual.json');
    expect(agentSetUp('pi', e.env), isFalse);
  });
  test('Hermes provider parsing uses upstream block depths and duplicate semantics', () {
    e.file(
      '.hermes/config.yaml',
      'model:\n  provider: local\n  base_url: https://remote.test\nproviders:\n  local:\n    api: http://localhost:8080\n',
    );
    expect(agentSetUp('hermes', e.env), isFalse);
    e.file('.hermes/config.yaml', 'providers:\n  local:\n    models:\n      api: http://localhost:8080\n');
    expect(agentSetUp('hermes', e.env), isFalse);
    e.file('.hermes/config.yaml', 'model:\n  api: http://localhost:8080\n');
    expect(agentSetUp('hermes', e.env), isFalse);
  });
}
