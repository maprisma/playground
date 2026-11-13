// An agent from Maprisma's helpers catalog that nobody has tried with it yet is offered as
// "(untested)" on every tab, in every language.
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/contestants.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

void main() {
  tearDown(() => setLanguage('en'));

  test('an unverified agent is named (untested); a bundled or tested one is not', () {
    Agent agent(Object? verified) => Agent({
      'command': 'gemini',
      'name': 'Gemini CLI',
      'installed': true,
      'set_up': true,
      'can_ask': true,
      'verified': ?verified,
    });
    expect(agent(false).name, 'Gemini CLI (untested)');
    expect(agent(false).verified, isFalse);
    expect(agent(false).ready, isTrue);
    expect(agent(true).name, 'Gemini CLI');
    expect(agent(null).name, 'Gemini CLI');
    expect(Contestant.agent(agent(false)).name, 'Gemini CLI (untested)');
    for (final code in ['de', 'fr', 'es', 'it', 'pt', 'nl', 'pl']) {
      setLanguage(code);
      expect(agent(false).name, allOf(startsWith('Gemini CLI ('), isNot('Gemini CLI (untested)')), reason: code);
    }
  });
}
