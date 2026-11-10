import 'i18n.dart';
import 'chess_rules.dart' as rules;
import 'chess_agent.dart';
import 'agent_run.dart' show seconds;
import 'agents.dart' show adapter;

enum ChessMode { game, define, replay }

/// Synchronous board/controller. I/O belongs to the app through chess.ask.
/// Pass revision from beginAgentMove to reject replies after an undo/reset.
class ChessGame {
  ChessGame({
    rules.Position? position,
    this.playerSide = 'w',
    this.agent = 'claude',
    this.rival,
    this.strength = 'club',
    this.rivalStrength = 'club',
    this.level = 'normal',
  }) : _start = position ?? rules.start(),
       _position = position ?? rules.start();
  rules.Position _start, _position;
  final List<rules.Move> _moves = [];
  List<rules.Move> _replay = [];
  ChessMode mode = ChessMode.game;
  String playerSide, agent, strength, rivalStrength, level;
  String? rival;
  bool paused = false, thinking = false;
  String comment = '', commentBy = '', error = '', replayTitle = '';
  int revision = 0;
  rules.Position get startPosition => _start;
  rules.Position get position => _position;
  List<rules.Move> get moves => List.unmodifiable(_moves);
  List<rules.Position> get history {
    var pos = _start;
    return [_start, for (final move in _moves) pos = rules.apply(pos, move)];
  }

  List<String> get takenPieces => rules.captured(_start, _moves);
  rules.Move? get lastMove => _moves.isEmpty ? null : _moves.last;
  String get notation => rules.gameSan(_start, _moves);
  String? agentFor(String side) => side == playerSide
      ? rival
      : agent.isEmpty
      ? null
      : agent;
  bool get yourTurn =>
      mode == ChessMode.game && !thinking && agentFor(_position.turn) == null && rules.status(_position) == 'ongoing';
  bool get needsAgentMove =>
      mode == ChessMode.game &&
      !thinking &&
      !(rival != null && paused) &&
      agentFor(_position.turn) != null &&
      rules.status(_position) == 'ongoing';
  String get currentStrength => rival != null && _position.turn == playerSide ? rivalStrength : strength;
  String get statusText => status();
  String _agentName(String? command) => command == null ? '' : adapter(command)?.name ?? command;
  String status({Duration elapsed = Duration.zero}) {
    if (mode == ChessMode.define) {
      return tr("Pick a piece below or above, then click squares; a right click empties a square.");
    }
    if (mode == ChessMode.replay) {
      return replayTitle.isEmpty
          ? trf("Move {0} of {1}", [_moves.length, _replay.length])
          : trf("{0}: move {1} of {2}", [replayTitle, _moves.length, _replay.length]);
    }
    final mover = agentFor(_position.turn);
    if (thinking) {
      String time(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
      return trf("{0} is thinking… {1} of {2}", [_agentName(mover), time(elapsed.inSeconds), time(seconds(level))]);
    }
    final status = rules.status(_position);
    if (status == 'checkmate') {
      final winner = agentFor(_position.turn == 'w' ? 'b' : 'w');
      return winner == null ? tr("Checkmate: you win.") : trf("Checkmate: {0} wins.", [_agentName(winner)]);
    }
    final over = {
      'stalemate': tr("Stalemate: a draw."),
      'fifty': tr("Draw by the fifty-move rule."),
      'material': tr("Draw: neither side can still mate."),
    }[status];
    if (over != null) return over;
    final turn = mover == null ? tr('Your move.') : trf('{0} is to move.', [_agentName(mover)]);
    return rules.inCheck(_position, _position.turn) ? '$turn ${tr('Check!')}' : turn;
  }

  void reset({rules.Position? position, String? player, String? rival, ChessMode mode = ChessMode.game}) {
    _start = position ?? rules.start();
    _position = _start;
    _moves.clear();
    _replay = [];
    replayTitle = '';
    if (player != null) {
      _side(player);
      playerSide = player;
    }
    this.rival = rival;
    this.mode = mode;
    paused = false;
    _invalidate();
  }

  void _invalidate() {
    revision++;
    thinking = false;
    comment = '';
    commentBy = '';
    error = '';
  }

  void pause() => paused = true;
  void resume() => paused = false;
  bool playMove(rules.Move move) {
    if (mode != ChessMode.game || thinking || !rules.legalMoves(_position).contains(move)) {
      return false;
    }
    _moves.add(move);
    _position = rules.apply(_position, move);
    _invalidate();
    return true;
  }

  bool play(String sanOrUci) {
    final move = rules.parse(_position, sanOrUci);
    return move != null && playMove(move);
  }

  int? beginAgentMove() {
    if (!needsAgentMove) return null;
    thinking = true;
    error = '';
    return revision;
  }

  bool applyAgentMove(
    Object move, {
    int? expectedRevision,
    String comment = '',
    String written = '',
    String error = '',
  }) {
    if (expectedRevision != null && expectedRevision != revision) return false;
    if (mode != ChessMode.game) return false;
    final mover = agentFor(_position.turn);
    final parsed = move is rules.Move
        ? move
        : move is String
        ? rules.parse(_position, move)
        : null;
    thinking = false;
    if (error.isNotEmpty || parsed == null || !rules.legalMoves(_position).contains(parsed)) {
      this.error = error.isNotEmpty ? error : trf("{0} did not name one of its legal moves.", [_agentName(mover)]);
      this.comment = comment;
      commentBy = mover ?? '';
      return false;
    }
    final ok = playMove(parsed);
    this.comment = comment;
    commentBy = mover ?? '';
    return ok;
  }

  bool applyAgentReply(ChessReply reply, {int? expectedRevision}) => applyAgentMove(
    reply.move ?? '',
    expectedRevision: expectedRevision,
    comment: reply.comment,
    written: reply.written,
    error: reply.error,
  );
  void undo() {
    if (mode == ChessMode.replay) {
      seek((_moves.length - 1).clamp(0, _replay.length));
      return;
    }
    if (_moves.isEmpty) return;
    _moves.removeLast();
    // Return to the human's turn when the agent had already answered.
    if (rival == null && _moves.isNotEmpty && _positionAt(_moves.length).turn != playerSide) {
      _moves.removeLast();
    }
    _position = _positionAt(_moves.length);
    _invalidate();
  }

  rules.Position _positionAt(int n) {
    var pos = _start;
    for (final m in _moves.take(n)) {
      pos = rules.apply(pos, m);
    }
    return pos;
  }

  void define() {
    reset(position: _position, player: playerSide, mode: ChessMode.define);
  }

  void setSquare(int square, String piece) {
    if (mode != ChessMode.define) throw StateError(tr("not defining a position"));
    if (square < 0 || square > 63 || (piece.isNotEmpty && !'PNBRQKpnbrqk'.split('').contains(piece))) {
      throw ArgumentError(tr("not a square or piece"));
    }
    final board = List<String>.of(_position.board)..[square] = piece;
    _position = rules.Position(board, _position.turn, '');
    _invalidate();
  }

  void clear() {
    mode = ChessMode.define;
    _position = rules.Position(List.filled(64, ''), 'w', '');
    _invalidate();
  }

  void resetEditor() {
    mode = ChessMode.define;
    _position = rules.start();
    _invalidate();
  }

  void _side(String side) {
    if (side != 'w' && side != 'b') throw ArgumentError(tr("not a side"));
  }

  void setSideToMove(String side) {
    _side(side);
    if (mode != ChessMode.define) throw StateError(tr("not defining a position"));
    _position = rules.Position(_position.board, side, _position.castling);
    _invalidate();
  }

  bool playFromHere({String? player, String? rival}) {
    var pos = _position;
    if (mode == ChessMode.define) {
      pos = rules.fromFen(rules.fen(rules.Position(pos.board, pos.turn, 'KQkq')));
    }
    final problems = rules.problems(pos);
    if (problems.isNotEmpty) {
      error = problems.first;
      return false;
    }
    if (rules.status(pos) != 'ongoing') {
      error = tr("In this position the game is already over.");
      return false;
    }
    if (mode == ChessMode.replay) {
      _side(player ?? playerSide);
      playerSide = player ?? playerSide;
      this.rival = rival;
      mode = ChessMode.game;
      _replay = [];
      replayTitle = '';
      paused = false;
      _invalidate();
    } else {
      reset(position: pos, player: player ?? playerSide, rival: rival);
    }
    return true;
  }

  void replay(rules.Position start, List<rules.Move> moves, {int index = 0}) {
    var pos = start;
    for (final m in moves) {
      if (!rules.legalMoves(pos).contains(m)) {
        throw ArgumentError(tr("illegal replay move"));
      }
      pos = rules.apply(pos, m);
    }
    reset(position: start, mode: ChessMode.replay);
    _replay = List.of(moves);
    seek(index);
  }

  int get replayLength => _replay.length;
  void seek(int index) {
    if (mode != ChessMode.replay) throw StateError(tr("not replaying"));
    if (index < 0 || index > _replay.length) {
      throw RangeError.range(index, 0, _replay.length);
    }
    _moves
      ..clear()
      ..addAll(_replay.take(index));
    _position = _positionAt(index);
    _invalidate();
  }
}
