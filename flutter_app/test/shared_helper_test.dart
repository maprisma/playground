import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/backend.dart';
import 'package:maprisma_playground/contestants.dart';
import 'package:maprisma_playground/pages/chess_page.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

Agent _agent(String command) => Agent({
  'command': command,
  'name': command.toUpperCase(),
  'installed': true,
  'set_up': true,
  'can_ask': true,
  'plays_chess': true,
  'takes_images': true,
  'reads_untrusted': true,
});

void main() {
  late Directory home;
  late String shared;
  late Playground playground;
  setUp(() {
    setLanguage('en');
    home = Directory.systemTemp.createTempSync('playground-shared-helper-');
    shared = '${home.path}/config/maprisma-ai/settings.json';
    playground = Playground(Backend.idle(), sharedAiFile: shared)..agents = [_agent('claude'), _agent('codex')];
  });
  tearDown(() => home.deleteSync(recursive: true));

  void choose(String helper) => File(shared)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('{"helper": "$helper", "kept": 1}');

  test('the shared choice is read again on demand; listeners hear a change only', () {
    var heard = 0;
    playground.addListener(() => heard++);
    playground.readHelperChoice();
    expect((playground.helperChoice, heard), ('auto', 0));
    expect(playground.preferred(['claude', 'codex']), 'claude');
    choose('codex');
    playground.readHelperChoice();
    playground.readHelperChoice();
    expect((playground.helperChoice, heard), ('codex', 1));
    expect(playground.preferred(['claude', 'codex']), 'codex');
    expect(playground.preferred(['claude']), 'claude', reason: 'not offered here: the first one');
    choose('bad id!');
    playground.readHelperChoice();
    expect(playground.helperChoice, 'auto');
    expect(File(shared).readAsStringSync(), contains('"kept": 1'), reason: 'only read, never written');
  });

  test('chess: the opponent is the shared choice until one is picked on the tab', () {
    choose('codex');
    playground.readHelperChoice();
    final settings = Settings(Places(config: '${home.path}/config/maprisma-playground', data: '${home.path}/d', cache: '${home.path}/c'));
    final session = ChessSession(
      core: (m, p, [e]) => CoreCall(Future.value(<String, dynamic>{}), () {}),
      settings: settings,
      agentsOf: () => playground.agents,
      playground: playground,
    );
    addTearDown(session.dispose);
    expect(session.opponent?.command, 'codex');
    choose('auto');
    playground.readHelperChoice();
    expect(session.opponent?.command, 'claude', reason: 'no game yet: it follows');
    session.pickOpponent(playground.agents.last);
    choose('claude');
    playground.readHelperChoice();
    expect(session.opponent?.command, 'codex', reason: 'picked on the tab: it stays');
  });
}
