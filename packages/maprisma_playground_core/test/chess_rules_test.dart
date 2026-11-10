import 'package:maprisma_playground_core/maprisma_playground_core.dart' as c;
import 'package:test/test.dart';

const kiwipete =
    'r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1';
const position3 = '8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1';

int perft(c.Position pos, int depth) => depth == 0
    ? 1
    : c
          .legalMoves(pos)
          .fold(0, (n, m) => n + perft(c.apply(pos, m), depth - 1));
c.Position play(List<String> sans) {
  var pos = c.start();
  for (final text in sans) {
    final move = c.parse(pos, text);
    expect(move, isNotNull, reason: text);
    pos = c.apply(pos, move!);
  }
  return pos;
}

void main() {
  group('MoveGeneration', () {
    // Standard perft counts: any wrong castling, en passant, promotion or check rule changes them.
    test('start_position', () {
      expect(
        [
          for (final d in [1, 2, 3]) perft(c.start(), d),
        ],
        [20, 400, 8902],
      );
    });
    test('kiwipete', () {
      final pos = c.fromFen(kiwipete);
      expect(
        [
          for (final d in [1, 2]) perft(pos, d),
        ],
        [48, 2039],
      );
    });
    test('position3_with_en_passant_and_pins', () {
      final pos = c.fromFen(position3);
      expect(
        [
          for (final d in [1, 2, 3]) perft(pos, d),
        ],
        [14, 191, 2812],
      );
    });
  });
  group('Fen', () {
    test('round_trip', () {
      for (final fen in [c.startFen, kiwipete, position3]) {
        expect(c.fen(c.fromFen(fen)), fen);
      }
    });
    test('after_moves', () {
      expect(
        c.fen(play(['e4'])),
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
      );
    });
    test('bad_fen_is_refused', () {
      for (final bad in [
        '',
        '8/8/8 w - - 0 1',
        'rnbqkbnr/pppppppp/9/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        'rnbqkbnr/ppppxppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        c.startFen.replaceAll(' w ', ' x '),
        '${c.startFen} extra',
        c.startFen.replaceAll(' 0 1', ' -1 1'),
      ]) {
        expect(() => c.fromFen(bad), throwsA(isA<c.FenError>()), reason: bad);
      }
    });
    test('castling_rights_need_king_and_rook_at_home', () {
      final pos = c.fromFen('4k3/8/8/8/8/8/8/4K2R w KQkq - 0 1');
      expect(pos.castling, 'K');
    });
    test('problems_of_a_position_set_up_by_hand', () {
      expect(c.problems(c.start()), isEmpty);
      expect(
        c.problems(c.fromFen('4k3/8/8/8/8/8/8/8 w - - 0 1')),
        contains('White needs exactly one king'),
      );
      expect(
        c.problems(c.fromFen('4k3/8/8/8/8/8/8/P3K3 w - - 0 1')),
        contains('Pawns cannot stand on the first or last rank'),
      );
      // Black to move while White is in check cannot happen.
      expect(
        c.problems(c.fromFen('4k3/8/8/8/8/8/4r3/4K3 b - - 0 1')),
        contains('The side not to move must not be in check'),
      );
    });
  });
  group('Notation', () {
    test('san_and_parse', () {
      final pos = play(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ba4', 'Nf6']);
      expect(c.san(pos, c.parse(pos, 'O-O')!), 'O-O');
      expect(c.parse(pos, '0-0'), c.parse(pos, 'e1g1'));
      expect(c.parse(pos, 'Ke2x'), isNull);
      expect(
        c.parse(pos, 'Qd3'),
        isNull,
        reason: 'the queen on d1 is blocked by the d2 pawn',
      );
    });
    test('check_and_mate_marks', () {
      final pos = play(['f3', 'e5', 'g4']);
      final mate = c.parse(pos, 'Qh4')!;
      expect(c.san(pos, mate), 'Qh4#');
      final after = c.apply(pos, mate);
      expect(c.status(after), 'checkmate');
    });
    test('disambiguation', () {
      var pos = c.fromFen('4k3/8/8/8/8/8/4K3/R6R w - - 0 1');
      expect(c.san(pos, c.parse(pos, 'a1d1')!), 'Rad1');
      expect(c.parse(pos, 'Rhd1'), c.parse(pos, 'h1d1'));
      pos = c.fromFen('4k3/R7/8/8/8/8/8/R3K3 w - - 0 1');
      expect(c.san(pos, c.parse(pos, 'a1a4')!), 'R1a4');
    });
    test('promotion_and_en_passant', () {
      var pos = c.fromFen('4k3/1P6/8/8/8/8/8/4K3 w - - 0 1');
      expect(c.san(pos, c.parse(pos, 'b8=Q')!), 'b8=Q+');
      expect(c.parse(pos, 'b8Q'), c.parse(pos, 'b7b8q'));
      pos = play(['e4', 'a6', 'e5', 'd5']);
      final move = c.parse(pos, 'exd6')!;
      expect(c.san(pos, move), 'exd6');
      expect(c.apply(pos, move).at(c.square('d5')), '');
    });
    test('stalemate', () {
      final pos = c.fromFen('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1');
      expect(c.status(pos), 'stalemate');
    });
    test('game_san', () {
      final start = c.start();
      final moves = <c.Move>[];
      var pos = start;
      for (final text in ['e4', 'e5', 'Nf3']) {
        final move = c.parse(pos, text)!;
        moves.add(move);
        pos = c.apply(pos, move);
      }
      expect(c.gameSan(start, moves), '1. e4 e5 2. Nf3');
      final blackStart = c.fromFen('4k3/8/8/8/8/8/4P3/4K3 b - - 0 7');
      expect(c.gameSan(blackStart, [c.parse(blackStart, 'Kd7')!]), '7... Kd7');
    });
  });
  group('Captured', () {
    test('captures_in_order_with_en_passant', () {
      final start = c.start(), moves = <c.Move>[];
      var pos = c.start();
      for (final text in [
        'e4',
        'd5',
        'exd5',
        'Qxd5',
        'Nc3',
        'a6',
        'Nxd5',
        'c5',
        'd4',
        'c4',
        'b4',
        'cxb3',
      ]) {
        final move = c.parse(pos, text)!;
        moves.add(move);
        pos = c.apply(pos, move);
      }
      expect(c.captured(start, moves), [
        'p',
        'P',
        'q',
        'P',
      ]); // The last one en passant.
    });
  });
  group('AnswersOfAgents', () {
    late c.Position pos;
    setUp(() {
      pos = play(['e4']);
    });
    (String?, String) find(String answer) {
      final (move, token) = c.findMove(pos, answer);
      return (move == null ? null : c.san(pos, move), token);
    }

    test('first_line_wins', () {
      expect(find('e5\nA classical answer; Nf6 was possible too.').$1, 'e5');
    });
    test('markdown_and_move_numbers', () {
      expect(find('**1... c5** — the Sicilian.').$1, 'c5');
      expect(find('`Nf6`').$1, 'Nf6');
    });
    test('square_before_a_full_stop', () {
      expect(find('I answer with e5.').$1, 'e5');
    });
    test('uci_and_illegal_moves', () {
      expect(find('g8f6').$1, 'Nf6');
      expect(find('Qh4 would be nice but I play d5').$1, 'd5');
    });
    test('no_move', () {
      expect(find('I cannot play chess today.'), (null, ''));
      expect(find(''), (null, ''));
      expect(find('x' * 100000), (null, ''));
    });
  });
}
