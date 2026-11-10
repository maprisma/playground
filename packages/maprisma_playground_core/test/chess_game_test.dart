import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

void main() {
  test('human move, requested agent reply, history, SAN, captures', () {
    final g = ChessGame();
    expect(g.yourTurn, isTrue);
    expect(g.statusText, 'Your move.');
    expect(g.play('e4'), isTrue);
    expect(g.needsAgentMove, isTrue);
    final token = g.beginAgentMove();
    expect(g.thinking, isTrue);
    expect(g.needsAgentMove, isFalse);
    expect(g.applyAgentMove('d5', expectedRevision: token, comment: 'Centre.'), isTrue);
    expect(g.comment, 'Centre.');
    expect(g.commentBy, 'claude');
    expect(g.play('exd5'), isTrue);
    expect(g.takenPieces, ['p']);
    expect(g.history.length, 4);
    expect(g.notation, contains('exd5'));
    expect(() => g.moves.clear(), throwsUnsupportedError);
  });
  test('undo returns to human turn and rejects stale replies', () {
    final g = ChessGame();
    g.play('e4');
    final token = g.beginAgentMove();
    g.undo();
    expect(g.position, start());
    expect(g.applyAgentMove('e5', expectedRevision: token), isFalse);
    g.play('e4');
    g.applyAgentMove('e5');
    g.undo();
    expect(g.position, start());
  });
  test('agent against agent has independent strengths and pause/resume', () {
    final g = ChessGame(rival: 'pi', strength: 'master', rivalStrength: 'beginner');
    expect(g.currentStrength, 'beginner');
    expect(g.agentFor('w'), 'pi');
    expect(g.agentFor('b'), 'claude');
    g.pause();
    expect(g.needsAgentMove, isFalse);
    g.resume();
    expect(g.needsAgentMove, isTrue);
    final token = g.beginAgentMove();
    g.pause();
    expect(g.applyAgentMove('e4', expectedRevision: token), isTrue);
    expect(g.currentStrength, 'master');
    expect(g.needsAgentMove, isFalse);
  });
  test('illegal moves and errors do not modify board, retry available', () {
    final g = ChessGame(playerSide: 'b');
    final before = g.position;
    final token = g.beginAgentMove();
    expect(g.applyAgentMove('e5', expectedRevision: token), isFalse);
    expect(g.error, isNotEmpty);
    expect(g.position, before);
    expect(g.needsAgentMove, isTrue);
    expect(g.play('nonsense'), isFalse);
  });
  test('position editor clear/reset/place/side/play from here', () {
    final g = ChessGame();
    g.define();
    expect(g.mode, ChessMode.define);
    g.clear();
    expect(g.position.board.every((s) => s.isEmpty), isTrue);
    expect(g.playFromHere(), isFalse);
    expect(g.error, isNotEmpty);
    g.setSquare(square('e1'), 'K');
    g.setSquare(square('e8'), 'k');
    g.setSquare(square('a1'), 'R');
    g.setSideToMove('b');
    expect(g.playFromHere(player: 'b'), isTrue);
    expect(g.position.turn, 'b');
    expect(g.playerSide, 'b');
    expect(g.moves, isEmpty);
    g.resetEditor();
    expect(g.position, start());
    expect(g.mode, ChessMode.define);
    expect(g.statusText, contains('Pick a piece'));
  });
  test('replay seek and play from here preserves current position', () {
    var pos = start();
    final moves = <Move>[];
    for (final text in ['e4', 'e5', 'Nf3']) {
      final m = parse(pos, text)!;
      moves.add(m);
      pos = apply(pos, m);
    }
    final g = ChessGame()..replay(start(), moves, index: 2);
    expect(g.moves.length, 2);
    expect(g.replayLength, 3);
    g.seek(3);
    expect(g.position, pos);
    expect(g.playFromHere(), isTrue);
    expect(g.startPosition, pos);
    expect(g.moves, isEmpty);
    expect(g.mode, ChessMode.game);
  });
  test('status text mate, check and draws', () {
    final g = ChessGame(agent: '');
    for (final m in ['f3', 'e5', 'g4', 'Qh4#']) {
      expect(g.play(m), isTrue);
    }
    expect(g.statusText, 'Checkmate: you win.');
    expect(g.needsAgentMove, isFalse);
    g.reset(position: fromFen('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1'));
    expect(g.statusText, 'Stalemate: a draw.');
  });
}
