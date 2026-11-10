// Live checks of the real app with the real core, agents and local LLMs: they ask Claude Code a few
// short questions (a little of the plan) and a local Ollama model. Not part of `flutter test`:
//
//   MAPRISMA_PLAYGROUND_NON_UNIQUE=1 XDG_CONFIG_HOME=$(mktemp -d) flutter test integration_test/live_test.dart -d linux
//
// Each check is skipped when what it needs (Claude Code set up, the Ollama model) is not there.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maprisma_playground/app.dart';
import 'package:maprisma_playground/backend.dart';
import 'package:maprisma_playground/chess_board.dart';
import 'package:maprisma_playground/contestants.dart';
import 'package:maprisma_playground/pages/vision_page.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

const localModel = 'Ollama · gemma-4-e2b-it-q4_k_m:latest';

// A 64 × 64 red PNG.
const redPng =
    'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAf0lEQVR4nNXOQREAIAzAsFIh8y8KMYjgsWsU5NwZyiRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4iRO4twO/HoInQGY8Ba5YAAAAABJRU5ErkJggg==';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Backend backend;
  late Playground playground;

  /// Pumps until [done] or [limit]; frames keep coming meanwhile (answers arrive from the core).
  Future<bool> until(WidgetTester tester, bool Function() done, {Duration limit = const Duration(seconds: 60)}) async {
    final end = DateTime.now().add(limit);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (done()) return true;
    }
    return false;
  }

  bool shows(Pattern text) => find.textContaining(text).evaluate().isNotEmpty;

  Future<void> tab(WidgetTester tester, String name) async {
    await tester.tap(find.widgetWithText(TextButton, name).first);
    await tester.pump(const Duration(milliseconds: 300));
  }

  bool claudeReady() => playground.ready.any((a) => a.command == 'claude');

  testWidgets('live: every tab, a local answer, a chess move, a picture, a blind duel', (tester) async {
    backend = await Backend.launch();
    playground = Playground(backend);
    playground.loadAgents();
    playground.scan();
    final settings = Settings(Places.fromEnv());
    await tester.pumpWidget(PlaygroundApp(settings: settings, playground: playground, args: const ['--test', 'automaton']));
    expect(await until(tester, () => playground.loaded && !playground.scanning, limit: const Duration(seconds: 30)), isTrue);

    // --- Automaton: Play runs generations, Pause stops them ----------------------------------------
    await tab(tester, 'Automaton');
    await tester.tap(find.text('Play'));
    expect(await until(tester, () => shows(RegExp(r'Generation ([1-9]\d*)')), limit: const Duration(seconds: 5)), isTrue);
    await tester.tap(find.text('Pause'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Play'), findsOneWidget);

    // --- Local LLMs: the small Gemma answers, with tokens per second --------------------------------
    await tab(tester, 'Local LLMs');
    if (playground.locals.any((c) => c.name == localModel)) {
      await tester.tap(find.textContaining('Ollama ·').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(localModel).last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Ask'));
      expect(await until(tester, () => shows('tokens per second'), limit: const Duration(seconds: 180)), isTrue,
          reason: 'the local model answered');
    } else {
      debugPrint('skipped: $localModel is not served');
    }

    if (!claudeReady()) {
      debugPrint('skipped: Claude Code is not set up');
      await backend.shutdown();
      return;
    }

    // --- Chess: 1. e4, and Claude Code answers with a legal move ------------------------------------
    await tab(tester, 'Chess');
    await tester.pump(const Duration(milliseconds: 500));
    Offset center(String square) {
      final rect = tester.getRect(find.byType(ChessBoard));
      final g = boardGeometry(rect.size);
      final file = 'abcdefgh'.indexOf(square[0]), rank = int.parse(square[1]) - 1;
      return rect.topLeft + Offset(g.x0 + (file + .5) * g.cell, g.y0 + (7 - rank + .5) * g.cell);
    }

    await tester.tapAt(center('e2'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tapAt(center('e4'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(shows('Claude Code is thinking'), isTrue);
    expect(await until(tester, () => shows(RegExp(r'1\. e4 \S+')), limit: const Duration(seconds: 150)), isTrue,
        reason: 'Claude Code answered 1. e4 with a legal move');
    expect(shows('Your move.'), isTrue);

    // --- Vision: a red square, only Claude Code asked ------------------------------------------------
    final picture = File('${Directory.systemTemp.createTempSync('playground-live-').path}/red.png')
      ..writeAsBytesSync(base64Decode(redPng));
    await tab(tester, 'Vision');
    visionInbox.value = picture.path;
    expect(await until(tester, () => find.byType(Image).evaluate().isNotEmpty, limit: const Duration(seconds: 20)), isTrue,
        reason: 'the picture was prepared');
    for (final other in ['Pi']) {
      final box = find.widgetWithText(InkWell, other);
      if (box.evaluate().isNotEmpty) await tester.tap(box.first); // only Claude Code is asked
    }
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField).first, 'What colour is this picture? Answer with one word.');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Ask'));
    expect(await until(tester, () => shows(RegExp('red', caseSensitive: false)), limit: const Duration(seconds: 120)),
        isTrue, reason: 'Claude Code saw red');

    // --- Head to head: Claude Code against the local model, blind, then a vote and a score ----------
    await tab(tester, 'Head to head');
    if (playground.locals.any((c) => c.name == localModel)) {
      await tester.tap(find.text('Codex').evaluate().isNotEmpty ? find.text('Codex').first : find.text('Pi').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(localModel).last);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField).first, 'Name one planet. One word.');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Ask'));
      expect(await until(tester, () => shows('Left is better'), limit: const Duration(seconds: 180)), isTrue,
          reason: 'both answered');
      expect(shows('LEFT') && shows('RIGHT'), isTrue, reason: 'blind: no names before the vote');
      await tester.tap(find.text('Left is better'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(shows('Score: '), isTrue);
    }

    await backend.shutdown();
  }, timeout: const Timeout(Duration(minutes: 15)));
}
