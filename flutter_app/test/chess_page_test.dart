import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/app.dart';
import 'package:maprisma_playground/chess_board.dart';
import 'package:maprisma_playground/contestants.dart';
import 'package:maprisma_playground/pages/chess_page.dart';
import 'package:maprisma_playground/theme.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

/// A core that answers games.* at once and holds every chess.ask until the test answers it.
final class FakeCore {
  final calls = <(String, Map<String, dynamic>)>[];
  final asks = <Completer<Map<String, dynamic>>>[];
  var cancelled = 0;
  Map<String, dynamic> readers = const {'readers': [], 'text_readers': []};

  CoreCall start(String method, Map<String, dynamic> params, [void Function(String, Map<String, dynamic>)? onEvent]) {
    calls.add((method, params));
    if (method == 'chess.ask') {
      final c = Completer<Map<String, dynamic>>();
      asks.add(c);
      return CoreCall(c.future, () => cancelled++);
    }
    if (method == 'games.list') return CoreCall(Future.value({'games': [], 'total': 0}), () {});
    if (method == 'import.readers') return CoreCall(Future.value(readers), () {});
    return CoreCall(Future.value(<String, dynamic>{}), () {});
  }

  List<Map<String, dynamic>> get chessAsks => [for (final c in calls) if (c.$1 == 'chess.ask') c.$2];
}

void main() {
  late Directory home;
  late Settings settings;
  late FakeCore core;
  late ChessSession session;
  final claude = Agent({
    'command': 'claude',
    'name': 'Claude Code',
    'installed': true,
    'set_up': true,
    'can_ask': true,
    'plays_chess': true,
    'takes_images': true,
    'reads_untrusted': true,
  });

  setUp(() {
    home = Directory.systemTemp.createTempSync('playground-chess-test-');
    settings = Settings(Places(config: '${home.path}/config', data: '${home.path}/data', cache: '${home.path}/cache'));
    core = FakeCore();
    session = ChessSession(core: core.start, settings: settings, agentsOf: () => [claude]);
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, {bool active = true}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final host = Host(settings: settings, toast: (_) {}, show: (_) {});
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, const {}, 8),
        home: Scaffold(body: ChessPage(host: host, session: session, active: active)),
      ),
    );
    await tester.pump();
    await tester.pump(); // the board fitted to the room
  }

  /// Ends a test: the page goes, then the session with its timers.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  }

  Offset center(WidgetTester tester, String square, {bool flipped = false}) {
    final rect = tester.getRect(find.byType(ChessBoard));
    final g = boardGeometry(rect.size);
    final file = 'abcdefgh'.indexOf(square[0]), rank = int.parse(square[1]) - 1;
    final (col, row) = flipped ? (7 - file, rank) : (file, 7 - rank);
    return rect.topLeft + Offset(g.x0 + (col + .5) * g.cell, g.y0 + (row + .5) * g.cell);
  }

  /// A menu opens or closes (pumpAndSettle would wait on the thinking spinner for ever).
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  void clipboard(WidgetTester tester, String text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': text};
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  String at(String name) => session.game.position.at(square(name));

  testWidgets('shows the plugin layout: opponent, title, choices, cards, game and saved games', (tester) async {
    await pump(tester);
    expect(find.text('Opponent'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Import video…'), findsOneWidget);
    expect(find.text('CHESS · CLAUDE CODE'), findsOneWidget);
    expect(find.text('New game with White'), findsOneWidget);
    expect(find.text('Normal (1½ min)'), findsOneWidget);
    expect(find.text('Club player'), findsOneWidget);
    expect(find.text('King ×1'), findsNWidgets(2));
    expect(find.text('Pawn ×8'), findsNWidgets(2));
    expect(find.text('GAME'), findsOneWidget);
    expect(find.text('Your move.'), findsOneWidget);
    expect(find.text('SAVED GAMES'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a piece moves by click and click, and the agent is asked with the moves', (tester) async {
    await pump(tester);
    await tester.tapAt(center(tester, 'e2'));
    await tester.pump();
    await tester.tapAt(center(tester, 'e4'));
    await tester.pump();
    expect(at('e4'), 'P');
    expect(at('e2'), '');
    expect(core.chessAsks.single['moves'], ['e2e4']);
    expect(core.chessAsks.single['command'], 'claude');
    expect(core.chessAsks.single['strength'], 'club');
    expect(find.textContaining('Claude Code is thinking…'), findsWidgets);
    core.asks.single.complete({'move': 'e7e5', 'written': 'e5', 'comment': 'The centre.', 'error': ''});
    await tester.pump();
    expect(at('e5'), 'p');
    expect(find.text('Claude Code says'), findsOneWidget);
    expect(find.text('The centre.'), findsOneWidget);
    expect(find.text('1. e4 e5'), findsOneWidget);
    expect(find.text('Your move.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a piece moves by dragging it', (tester) async {
    await pump(tester);
    final gesture = await tester.startGesture(center(tester, 'g1'));
    await gesture.moveTo(center(tester, 'g1') + const Offset(10, -10));
    await tester.pump();
    await gesture.moveTo(center(tester, 'f3'));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(at('f3'), 'N');
    expect(at('g1'), '');
    expect(core.chessAsks.single['moves'], ['g1f3']);
    await finish(tester);
  });

  testWidgets('an illegal move is refused, and the agent\'s pieces cannot be moved', (tester) async {
    await pump(tester);
    await tester.tapAt(center(tester, 'e2'));
    await tester.pump();
    await tester.tapAt(center(tester, 'e5'));
    await tester.pump();
    expect(at('e2'), 'P');
    expect(at('e5'), '');
    final gesture = await tester.startGesture(center(tester, 'e7'));
    await gesture.moveTo(center(tester, 'e5'));
    await gesture.up();
    await tester.pump();
    expect(at('e7'), 'p');
    expect(session.game.moves, isEmpty);
    expect(core.chessAsks, isEmpty);
    await finish(tester);
  });

  testWidgets('a pawn on the last rank asks which piece it becomes', (tester) async {
    await pump(tester);
    session.newGame('w', from: fromFen('8/P6p/8/8/8/8/8/k6K w - - 0 1'));
    await tester.pump();
    await tester.tapAt(center(tester, 'a7'));
    await tester.pump();
    await tester.tapAt(center(tester, 'a8'));
    await tester.pump();
    expect(find.byTooltip('Queen'), findsOneWidget);
    expect(find.byTooltip('Rook'), findsOneWidget);
    await tester.tap(find.byTooltip('Knight'));
    await tester.pump();
    expect(at('a8'), 'N');
    expect(core.chessAsks.single['moves'], ['a7a8n']);
    await finish(tester);
  });

  testWidgets('define mode: a picked card places a piece, a right click empties a square, a card drags in',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('New game with White'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Define position').last);
    await tester.pumpAndSettle();
    expect(session.game.mode, ChessMode.define);
    expect(find.text('Empty board'), findsOneWidget);
    expect(find.text('Play it with Black'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('card-q')));
    await tester.pump();
    await tester.tapAt(center(tester, 'e4'));
    await tester.pump();
    expect(at('e4'), 'q');
    await tester.tapAt(center(tester, 'e4'), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(at('e4'), '');
    // A white knight dragged from its card onto d5.
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('card-N'))));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(center(tester, 'd5'));
    await tester.pump();
    await gesture.moveTo(center(tester, 'd5') + const Offset(1, 1));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(at('d5'), 'N');
    // Two white kings: the position is refused with the rules' reason.
    await tester.tap(find.byKey(const ValueKey('card-K')));
    await tester.pump();
    await tester.tapAt(center(tester, 'a3'));
    await tester.pump();
    await tester.tap(find.text('Play it with White'));
    await tester.pump();
    expect(session.game.mode, ChessMode.define);
    expect(find.text('White needs exactly one king'), findsWidgets);
    await finish(tester);
  });

  testWidgets('replay: the bar seeks through a saved game, Play from here goes on with its moves', (tester) async {
    await pump(tester);
    session.openReplay(
      SavedGame({
        'id': 'g1',
        'title': 'Test game',
        'start': startFen,
        'moves': ['e2e4', 'e7e5', 'g1f3'],
      }),
    );
    await tester.pump();
    expect(find.text('CHESS · TEST GAME'), findsOneWidget);
    expect(find.text('Test game: move 0 of 3'), findsOneWidget);
    await tester.tap(find.byTooltip('Next move'));
    await tester.pump();
    expect(find.text('Test game: move 1 of 3'), findsOneWidget);
    expect(at('e4'), 'P');
    await tester.tap(find.byTooltip('Last move'));
    await tester.pump();
    expect(find.text('Test game: move 3 of 3'), findsOneWidget);
    await tester.tap(find.byTooltip('Back one move'));
    await tester.pump();
    expect(find.text('Test game: move 2 of 3'), findsOneWidget);
    expect(at('f3'), '');
    await tester.tap(find.byTooltip('First move'));
    await tester.pump();
    expect(find.text('Test game: move 0 of 3'), findsOneWidget);
    await tester.tap(find.text('Auto'));
    await tester.pump(const Duration(milliseconds: 1250));
    expect(find.text('Test game: move 1 of 3'), findsOneWidget);
    await tester.tap(find.text('Pause'));
    await tester.pump();
    await tester.tap(find.text('Play from here'));
    await tester.pump();
    expect(session.game.mode, ChessMode.game);
    expect(session.game.moves.length, 1);
    expect(session.game.playerSide, 'b'); // you play the side to move
    expect(find.text('1. e4'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a reply that comes after a new game is dropped; an error offers Ask again', (tester) async {
    await pump(tester);
    await tester.tap(find.text('New game with White'));
    await settle(tester);
    await tester.tap(find.text('New game with Black').last);
    await settle(tester);
    expect(session.game.playerSide, 'b');
    expect(core.chessAsks.length, 1); // the agent opens with White
    session.newGame('b');
    await tester.pump();
    expect(core.cancelled, 1);
    core.asks.first.complete({'move': 'e2e4', 'written': 'e4', 'comment': '', 'error': ''});
    await tester.pump();
    expect(session.game.moves, isEmpty);
    core.asks.last.complete({'written': '', 'comment': 'Hmm.', 'error': 'Claude Code did not name one of its legal moves.'});
    await tester.pump();
    expect(find.text('Hmm.\nClaude Code did not name one of its legal moves.'), findsOneWidget);
    expect(core.chessAsks.length, 2); // no second ask by itself: the core retries inside chess.ask
    await tester.pump(const Duration(milliseconds: 300)); // the Game card has grown
    await tester.ensureVisible(find.text('Ask again'));
    await tester.pump();
    await tester.tap(find.text('Ask again'));
    await tester.pump();
    expect(core.chessAsks.length, 3);
    core.asks.last.complete({'move': 'd2d4', 'written': 'd4', 'comment': '', 'error': ''});
    await tester.pump();
    expect(at('d4'), 'P');
    await finish(tester);
  });

  testWidgets('agent against agent asks both in turn, with each side\'s strength', (tester) async {
    await pump(tester);
    session
      ..rivalStrength = 'master'
      ..strength = 'beginner'
      ..choice = 'agents';
    await session.start(null);
    await tester.pump();
    expect(find.text('CHESS · CLAUDE CODE – CLAUDE CODE'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(core.chessAsks.single['strength'], 'master'); // White
    core.asks.last.complete({'move': 'e2e4', 'written': 'e4', 'comment': '', 'error': ''});
    await tester.pump(const Duration(milliseconds: 1300));
    expect(core.chessAsks.length, 2);
    expect(core.chessAsks.last['strength'], 'beginner'); // Black
    await finish(tester);
  });

  test('file addresses: only local ones, decoded safely', () {
    expect(localPath('file:///home/me/a%20b.mp4'), '/home/me/a b.mp4');
    expect(localPath('file://localhost/home/me/c.mp4'), '/home/me/c.mp4');
    expect(localPath('file://other.host/home/me/c.mp4'), isNull);
    expect(localPath('file:///home/%E0%A4%A.mp4'), isNull);
    expect(localPath('https://example.com/x.mp4'), isNull);
  });

  testWidgets('Ctrl+V with a video file asks the core about it and offers the replacement and the length',
      (tester) async {
    final video = File('${home.path}/My game #1 %.mp4')..writeAsStringSync('x');
    core.readers = {
      'readers': ['claude'],
      'text_readers': ['claude'],
      'before': {'id': 'old', 'title': 'Earlier reading', 'date': '2026-11-01 10:00'},
      'seconds': 600,
    };
    await pump(tester);
    clipboard(tester, video.path); // a bare path: % and # stay as they are
    ChessPage.paste();
    await tester.pump();
    await tester.pump();
    final ask = core.calls.firstWhere((c) => c.$1 == 'import.readers').$2;
    expect(ask, {'path': video.path});
    expect(find.text('Read the moves from this video?'), findsOneWidget);
    expect(find.textContaining('Read before: Earlier reading (2026-11-01 10:00)'), findsOneWidget);
    expect(find.textContaining('10 min of video: at most 151 frames.'), findsOneWidget);
    await tester.tap(find.text('Read the moves'));
    await tester.pump();
    final start = core.calls.firstWhere((c) => c.$1 == 'import.start').$2;
    expect(start['path'], video.path);
    expect(start['replace_id'], 'old');
    expect(start['reader'], 'claude');
    expect(start['way'], 'frames');
    expect(start['gap'], 4);
    await tester.pump();
    await finish(tester);
  });

  testWidgets('a tab that is not in view ignores Ctrl+V', (tester) async {
    await pump(tester, active: false);
    clipboard(tester, 'https://www.youtube.com/watch?v=abcdefgh');
    ChessPage.paste();
    await tester.pump();
    await tester.pump();
    expect(core.calls.where((c) => c.$1 == 'import.readers'), isEmpty);
    await finish(tester);
  });

  test('disposeAll is safe with no session made', ChessSession.disposeAll);
}
