/// Chess rules for the chess page: positions, legal moves, FEN, SAN and UCI.
///
/// Pure Dart, no UI, so it is tested on its own (test/chess_rules_test.dart).
/// A square is an index 0..63, a1 = 0, h1 = 7, a8 = 56. A piece is a letter,
/// upper case for White ("PNBRQK"), lower case for Black; an empty square is "".
/// Positions never change: a move gives a new one.
library;

import 'i18n.dart';

import 'dart:collection';

const files = 'abcdefgh';
const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const knight = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)];
const king = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)];
const rookDirs = [(1, 0), (-1, 0), (0, 1), (0, -1)];
const bishopDirs = [(1, 1), (1, -1), (-1, 1), (-1, -1)];
const maxText = 4000; // How much of an answer is searched for a move.

class FenError extends FormatException {
  const FenError(super.message);
}

int square(String name) {
  final file = files.indexOf(name[0]);
  if (file < 0) throw ArgumentError.value(name);
  return file + 8 * (int.parse(name[1]) - 1);
}

String name(int sq) => files[sq % 8] + ((sq / 8).floor() + 1).toString();
bool white(String piece) => piece.toUpperCase() == piece && piece.toLowerCase() != piece;
String colorOf(String piece) => white(piece) ? 'w' : 'b';

class Move {
  final int start;
  final int end;
  final String promotion; // "q", "r", "b" or "n" (always lower case here).
  const Move(this.start, this.end, [this.promotion = '']);
  String uci() => name(start) + name(end) + promotion;
  @override
  bool operator ==(Object other) =>
      other is Move && start == other.start && end == other.end && promotion == other.promotion;
  @override
  int get hashCode => Object.hash(start, end, promotion);
}

// Tuple-like value equality matters when comparing boards read from video frames.
class _Board extends ListBase<String> {
  final List<String> _pieces;
  _Board(Iterable<String> pieces) : _pieces = List.unmodifiable(pieces);
  @override
  int get length => _pieces.length;
  @override
  set length(int value) => throw UnsupportedError('Immutable board');
  @override
  String operator [](int index) => _pieces[index < 0 ? length + index : index];
  @override
  void operator []=(int index, String value) => throw UnsupportedError('Immutable board');
  @override
  bool operator ==(Object other) =>
      other is _Board && length == other.length && Iterable<int>.generate(length).every((i) => this[i] == other[i]);
  @override
  int get hashCode => Object.hashAll(_pieces);
}

class Position {
  final List<String> board; // 64 pieces ("" for empty).
  final String turn;
  final String castling; // "" when nobody may castle.
  final int? enPassant;
  final int halfmove;
  final int fullmove;
  Position(
    Iterable<String> board, [
    this.turn = 'w',
    this.castling = 'KQkq',
    this.enPassant,
    this.halfmove = 0,
    this.fullmove = 1,
  ]) : board = _Board(board);
  String at(int sq) => board[sq];
  @override
  bool operator ==(Object other) =>
      other is Position &&
      board == other.board &&
      turn == other.turn &&
      castling == other.castling &&
      enPassant == other.enPassant &&
      halfmove == other.halfmove &&
      fullmove == other.fullmove;
  @override
  int get hashCode => Object.hash(board, turn, castling, enPassant, halfmove, fullmove);
}

bool _fullMatch(String pattern, String text) => RegExp('^(?:$pattern)\$').firstMatch(text)?.group(0) == text;

/// A position from FEN; a malformed one raises FenError. Only the placement is required.
Position fromFen(String? fen) {
  final text = (fen ?? '').trim();
  final parts = text.isEmpty ? <String>[] : text.split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.length > 6) {
    throw FenError(tr("FEN has the wrong number of fields"));
  }
  final rows = parts[0].split('/');
  if (rows.length != 8) throw FenError(tr("FEN needs eight ranks"));
  final board = List.filled(64, '');
  for (var r = 0; r < 8; r++) {
    var f = 0;
    for (final ch in rows[r].split('')) {
      if (_fullMatch(r'[0-9]', ch)) {
        f += int.parse(ch);
      } else if ('PNBRQKpnbrqk'.contains(ch)) {
        if (f > 7) throw FenError(tr("a rank has more than eight squares"));
        board[(7 - r) * 8 + f++] = ch;
      } else {
        throw FenError(trf("unknown piece “{0}”", [ch]));
      }
    }
    if (f != 8) throw FenError(tr("a rank does not have eight squares"));
  }
  final turn = parts.length > 1 ? parts[1] : 'w';
  if (turn != 'w' && turn != 'b') {
    throw FenError(tr("side to move must be w or b"));
  }
  final castling = parts.length > 2 ? parts[2] : '-';
  if (castling != '-' && !_fullMatch(r'K?Q?k?q?', castling)) {
    throw FenError(tr("bad castling field"));
  }
  final ep = parts.length > 3 ? parts[3] : '-';
  if (ep != '-' && !_fullMatch(r'[a-h][36]', ep)) {
    throw FenError(tr("bad en passant field"));
  }
  int counter(String s) {
    if (!_fullMatch(r'[+-]?[0-9](?:_?[0-9])*', s)) {
      throw FenError(tr("move counters must be numbers"));
    }
    // Parse as BigInt so arbitrarily large Python counters report the same error.
    final n = BigInt.parse(s.replaceAll('_', ''));
    if (n < BigInt.zero || n > BigInt.from(10000)) {
      throw FenError(tr("move counters out of range"));
    }
    return n.toInt();
  }

  final half = parts.length > 4 ? counter(parts[4]) : 0;
  final full = parts.length > 5 ? counter(parts[5]) : 1;
  if (full < 1) throw FenError(tr("move counters out of range"));
  final pos = Position(board, turn, castling == '-' ? '' : castling, ep == '-' ? null : square(ep), half, full);
  return Position(board, turn, _possibleCastling(pos), pos.enPassant, half, full);
}

String fen(Position pos) {
  final rows = <String>[];
  for (var rank = 7; rank >= 0; rank--) {
    var row = '', empty = 0;
    for (var f = 0; f < 8; f++) {
      final piece = pos.board[rank * 8 + f];
      if (piece.isNotEmpty) {
        row += (empty != 0 ? '$empty' : '') + piece;
        empty = 0;
      } else {
        empty++;
      }
    }
    rows.add(row + (empty != 0 ? '$empty' : ''));
  }
  final ep = pos.enPassant == null ? '-' : name(pos.enPassant!);
  return '${rows.join('/')} ${pos.turn} ${pos.castling.isEmpty ? '-' : pos.castling} $ep ${pos.halfmove} ${pos.fullmove}';
}

Position start() => fromFen(startFen);

/// Only the castling rights whose king and rook still stand at home.
String _possibleCastling(Position pos) {
  var keep = '';
  for (final (flag, k, r, king, rook) in [
    ('K', 4, 7, 'K', 'R'),
    ('Q', 4, 0, 'K', 'R'),
    ('k', 60, 63, 'k', 'r'),
    ('q', 60, 56, 'k', 'r'),
  ]) {
    if (pos.castling.contains(flag) && pos.board[k] == king && pos.board[r] == rook) {
      keep += flag;
    }
  }
  return keep;
}

/// Why a position set up by hand cannot be played (empty when it can).
List<String> problems(Position pos) {
  final out = <String>[];
  for (final king in ['K', 'k']) {
    if (pos.board.where((p) => p == king).length != 1) {
      out.add(king == 'K' ? tr('White needs exactly one king') : tr('Black needs exactly one king'));
    }
  }
  if ([
    ...List.generate(8, (i) => i),
    ...List.generate(8, (i) => i + 56),
  ].any((sq) => ['P', 'p'].contains(pos.board[sq]))) {
    out.add(tr("Pawns cannot stand on the first or last rank"));
  }
  for (final piece in ['P', 'p']) {
    if (pos.board.where((p) => p == piece).length > 8) {
      out.add(tr("A side cannot have more than eight pawns"));
    }
  }
  if (out.isEmpty && inCheck(pos, pos.turn == 'w' ? 'b' : 'w')) {
    out.add(tr("The side not to move must not be in check"));
  }
  return out;
}

int? _step(int sq, int df, int dr) {
  final f = sq % 8 + df, r = sq ~/ 8 + dr;
  return f >= 0 && f < 8 && r >= 0 && r < 8 ? r * 8 + f : null;
}

/// Is the square attacked by side `by` ("w" or "b")?
bool attacked(Position pos, int sq, String by) {
  bool mine(String piece, String kinds) =>
      piece.isNotEmpty && colorOf(piece) == by && kinds.contains(piece.toUpperCase());
  final pawnDr = by == 'w' ? -1 : 1; // A white pawn attacks from one rank below.
  for (final df in [-1, 1]) {
    final t = _step(sq, df, pawnDr);
    if (t != null && mine(pos.board[t], 'P')) return true;
  }
  for (final (dirs, kinds) in [(knight, 'N'), (king, 'K')]) {
    for (final (df, dr) in dirs) {
      final t = _step(sq, df, dr);
      if (t != null && mine(pos.board[t], kinds)) return true;
    }
  }
  for (final (dirs, kinds) in [(rookDirs, 'RQ'), (bishopDirs, 'BQ')]) {
    for (final (df, dr) in dirs) {
      var t = _step(sq, df, dr);
      while (t != null) {
        if (pos.board[t].isNotEmpty) {
          if (mine(pos.board[t], kinds)) return true;
          break;
        }
        t = _step(t, df, dr);
      }
    }
  }
  return false;
}

bool inCheck(Position pos, String side) {
  final sq = pos.board.indexOf(side == 'w' ? 'K' : 'k');
  return sq >= 0 && attacked(pos, sq, side == 'w' ? 'b' : 'w');
}

Iterable<Move> _pseudo(Position pos) sync* {
  final board = pos.board, side = pos.turn;
  for (var sq = 0; sq < board.length; sq++) {
    final piece = board[sq];
    if (piece.isEmpty || colorOf(piece) != side) continue;
    final kind = piece.toUpperCase();
    if (kind == 'P') {
      final dr = side == 'w' ? 1 : -1, last = side == 'w' ? 7 : 0, home = side == 'w' ? 1 : 6;
      final one = _step(sq, 0, dr);
      if (one != null && board[one].isEmpty) {
        yield* _pawn(sq, one, last);
        final two = _step(one, 0, dr);
        if (sq ~/ 8 == home && two != null && board[two].isEmpty) {
          yield Move(sq, two);
        }
      }
      for (final df in [-1, 1]) {
        final t = _step(sq, df, dr);
        if (t == null) continue;
        if (board[t].isNotEmpty && colorOf(board[t]) != side) {
          yield* _pawn(sq, t, last);
        } else if (t == pos.enPassant) {
          yield Move(sq, t);
        }
      }
    } else if ('NK'.contains(kind)) {
      for (final (df, dr) in kind == 'N' ? knight : king) {
        final t = _step(sq, df, dr);
        if (t != null && (board[t].isEmpty || colorOf(board[t]) != side)) {
          yield Move(sq, t);
        }
      }
      if (kind == 'K') yield* _castles(pos, sq);
    } else {
      final dirs = kind == 'R'
          ? rookDirs
          : kind == 'B'
          ? bishopDirs
          : [...rookDirs, ...bishopDirs];
      for (final (df, dr) in dirs) {
        var t = _step(sq, df, dr);
        while (t != null) {
          if (board[t].isNotEmpty) {
            if (colorOf(board[t]) != side) yield Move(sq, t);
            break;
          }
          yield Move(sq, t);
          t = _step(t, df, dr);
        }
      }
    }
  }
}

Iterable<Move> _pawn(int startSq, int end, int last) sync* {
  if (end ~/ 8 == last) {
    for (final p in 'qrbn'.split('')) {
      yield Move(startSq, end, p);
    }
  } else {
    yield Move(startSq, end);
  }
}

Iterable<Move> _castles(Position pos, int kingSq) sync* {
  final side = pos.turn, other = pos.turn == 'w' ? 'b' : 'w';
  final home = side == 'w' ? 4 : 60;
  if (kingSq != home || attacked(pos, home, other)) return;
  final short = side == 'w' ? 'K' : 'k', long = side == 'w' ? 'Q' : 'q';
  if (pos.castling.contains(short) &&
      pos.board[home + 1].isEmpty &&
      pos.board[home + 2].isEmpty &&
      !attacked(pos, home + 1, other) &&
      !attacked(pos, home + 2, other)) {
    yield Move(home, home + 2);
  }
  if (pos.castling.contains(long) &&
      pos.board[home - 1].isEmpty &&
      pos.board[home - 2].isEmpty &&
      pos.board[home - 3].isEmpty &&
      !attacked(pos, home - 1, other) &&
      !attacked(pos, home - 2, other)) {
    yield Move(home, home - 2);
  }
}

/// The position after a move (assumed legal: see legalMoves).
Position apply(Position pos, Move move) {
  final board = pos.board.toList();
  var piece = board[move.start], captured = board[move.end];
  final pawnMoved = piece.toUpperCase() == 'P';
  board[move.start] = '';
  int? ep;
  if (piece.toUpperCase() == 'P') {
    if (move.end == pos.enPassant && captured.isEmpty) {
      board[move.end + (piece == 'P' ? -8 : 8)] = '';
      captured = 'p';
    }
    if ((move.end - move.start).abs() == 16) ep = (move.start + move.end) ~/ 2;
    if (move.promotion.isNotEmpty) {
      piece = piece == 'P' ? move.promotion.toUpperCase() : move.promotion;
    }
  }
  if (piece.toUpperCase() == 'K' && (move.end - move.start).abs() == 2) {
    final (rookFrom, rookTo) = move.end > move.start
        ? (move.start + 3, move.start + 1)
        : (move.start - 4, move.start - 1);
    board[rookTo] = board[rookFrom];
    board[rookFrom] = '';
  }
  board[move.end] = piece;
  var castling = pos.castling;
  for (final (sq, flags) in [(4, 'KQ'), (60, 'kq'), (0, 'Q'), (7, 'K'), (56, 'q'), (63, 'k')]) {
    if (move.start == sq || move.end == sq) {
      castling = castling.split('').where((c) => !flags.contains(c)).join();
    }
  }
  final half = pawnMoved || captured.isNotEmpty ? 0 : pos.halfmove + 1;
  return Position(board, pos.turn == 'w' ? 'b' : 'w', castling, ep, half, pos.fullmove + (pos.turn == 'b' ? 1 : 0));
}

List<Move> legalMoves(Position pos) => _pseudo(pos).where((move) => !inCheck(apply(pos, move), pos.turn)).toList();

/// "checkmate", "stalemate", "fifty" (fifty-move rule), "material" (no mate possible) or "ongoing".
String status(Position pos) {
  if (legalMoves(pos).isEmpty) {
    return inCheck(pos, pos.turn) ? 'checkmate' : 'stalemate';
  }
  if (pos.halfmove >= 100) return 'fifty';
  final rest = pos.board.where((p) => p.isNotEmpty && p.toUpperCase() != 'K').map((p) => p.toUpperCase()).toList()
    ..sort();
  if (rest.isEmpty || (rest.length == 1 && ['B', 'N'].contains(rest[0]))) {
    return 'material';
  }
  return 'ongoing';
}

/// Standard algebraic notation of a legal move, with + or #.
String san(Position pos, Move move) {
  final piece = pos.at(move.start), kind = pos.at(move.start).toUpperCase();
  String text;
  if (kind == 'K' && (move.end - move.start).abs() == 2) {
    text = move.end > move.start ? 'O-O' : 'O-O-O';
  } else {
    final capture = pos.at(move.end).isNotEmpty || (kind == 'P' && move.end == pos.enPassant);
    if (kind == 'P') {
      text = (capture ? '${files[move.start % 8]}x' : '') + name(move.end);
      if (move.promotion.isNotEmpty) text += '=${move.promotion.toUpperCase()}';
    } else {
      final others = legalMoves(
        pos,
      ).where((m) => m.end == move.end && m.start != move.start && pos.at(m.start) == piece).toList();
      var hint = '';
      if (others.isNotEmpty) {
        if (others.every((m) => m.start % 8 != move.start % 8)) {
          hint = files[move.start % 8];
        } else if (others.every((m) => m.start ~/ 8 != move.start ~/ 8)) {
          hint = '${move.start ~/ 8 + 1}';
        } else {
          hint = name(move.start);
        }
      }
      text = kind + hint + (capture ? 'x' : '') + name(move.end);
    }
  }
  final after = apply(pos, move);
  if (inCheck(after, after.turn)) text += legalMoves(after).isEmpty ? '#' : '+';
  return text;
}

String _plain(String text) =>
    text.trim().replaceFirst(RegExp(r'[+#!?]+$'), '').replaceAll('0-0-0', 'O-O-O').replaceAll('0-0', 'O-O');

/// A legal move from SAN ("Nf3", "exd5", "e8=Q", "O-O") or UCI ("g1f3", "e7e8q"); null otherwise.
Move? parse(Position pos, String? text) {
  final word = _plain(text ?? '');
  if (word.isEmpty || word.length > 12) return null;
  final moves = legalMoves(pos), low = word.toLowerCase();
  if (_fullMatch(r'[a-h][1-8][a-h][1-8][qrbn]?', low)) {
    for (final m in moves) {
      if (m.uci() == low) return m;
    }
  }
  for (final m in moves) {
    if (_plain(san(pos, m)) == word) return m;
  }
  // A promotion written without "=" ("e8Q") or a pawn capture with a lower-case piece letter.
  if (_fullMatch(r'[a-h](x[a-h])?[18][QRBN]', word)) {
    return parse(pos, '${word.substring(0, word.length - 1)}=${word[word.length - 1]}');
  }
  return null;
}

final token = RegExp(
  r'O-O-O|O-O|0-0-0|0-0|[KQRBN]?[a-h]?[1-8]?x?[a-h][1-8](?:=?[QRBNqrbn])?[+#]?|[a-h][1-8][a-h][1-8][qrbn]?',
);

/// The move an agent's answer names: the first legal move in it, its first line first.
/// Returns (move, the text it was written as); (null, "") when the answer names none.
(Move?, String) findMove(Position pos, String? answer) {
  final text = String.fromCharCodes((answer ?? '').runes.take(maxText));
  final lines = text.split(RegExp(r'\r\n|[\n\r\v\f\x1c-\x1e\x85\u2028\u2029]')).where((line) => line.trim().isNotEmpty);
  for (final line in lines) {
    // Move numbers ("12." or "12...") go; a square before a full stop ("e4.") stays.
    final cleaned = line
        .replaceAll('*', ' ')
        .replaceAll('`', ' ')
        .replaceAll(RegExp(r'(?<![A-Za-z])\d+\s*\.(\.\.)?'), ' ');
    for (final match in token.allMatches(cleaned)) {
      final written = match.group(0)!;
      final move = parse(pos, written);
      if (move != null) return (move, written);
    }
  }
  return (null, '');
}

/// The pieces taken in the game so far, in order ("p" a black pawn, "Q" a white queen; en passant too).
List<String> captured(Position start, List<Move> moves) {
  final taken = <String>[];
  var pos = start;
  for (final move in moves) {
    final piece = pos.at(move.start), target = pos.at(move.end);
    if (target.isNotEmpty) {
      taken.add(target);
    } else if (piece.toLowerCase() == 'p' && move.start % 8 != move.end % 8) {
      taken.add(piece == 'P' ? 'p' : 'P'); // En passant: the pawn beside it.
    }
    pos = apply(pos, move);
  }
  return taken;
}

/// The moves of a game as numbered SAN ("1. e4 e5 2. Nf3"), from its start position.
String gameSan(Position startPos, List<Move> moves) {
  var pos = startPos;
  final parts = <String>[];
  for (var i = 0; i < moves.length; i++) {
    if (pos.turn == 'w') {
      parts.add('${pos.fullmove}.');
    } else if (i == 0) {
      parts.add('${pos.fullmove}...');
    }
    parts.add(san(pos, moves[i]));
    pos = apply(pos, moves[i]);
  }
  return parts.join(' ');
}
