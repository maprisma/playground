import 'package:maprisma_playground_core/maprisma_playground_core.dart' show tr;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart' as rules show legalMoves, inCheck, files;
import 'package:maprisma_playground_core/maprisma_playground_core.dart' show Move, ChessGame, ChessMode, colorOf;

import 'theme.dart';

/// The chess board of the plugin's chess_page.py: drawn squares and Unicode pieces, moves by
/// click-click or drag, a promotion choice, and in define mode placing and removing pieces.

const glyphs = {'K': '♚', 'Q': '♛', 'R': '♜', 'B': '♝', 'N': '♞', 'P': '♟'}; // solid shapes
const outlines = {'K': '♔', 'Q': '♕', 'R': '♖', 'B': '♗', 'N': '♘', 'P': '♙'}; // contours and details
const kinds = ['K', 'Q', 'R', 'B', 'N', 'P'];
Map<String, String> get kindNames => {
  'K': tr("King"),
  'Q': tr("Queen"),
  'R': tr("Rook"),
  'B': tr("Bishop"),
  'N': tr("Knight"),
  'P': tr("Pawn"),
};

/// Board and pieces › Board: the squares' colours (light, dark); "theme" from the desktop's colours.
List<(String, String, (Color, Color)?)> get boards => <(String, String, (Color, Color)?)>[
  ('theme', tr("Theme colours"), null),
  ('wood', tr("Wood"), (Color(0xfff0d9b5), Color(0xffb58863))),
  ('green', tr("Green"), (Color(0xffeeeed2), Color(0xff769656))),
  ('blue', tr("Blue"), (Color(0xffdee3e6), Color(0xff8ca2ad))),
  ('grey', tr("Grey"), (Color(0xffe6e6e6), Color(0xff9a9a9a))),
];
List<(String, String)> get pieceStyles => <(String, String)>[
  ('classic', tr("Classic")),
  ('flat', tr("Flat")),
  ('theme', tr("Theme colours")),
];
const boardMin = 320.0, boardMax = 560.0;

/// Fonts whose chess glyphs are solid shapes (PIECE_FONTS).
const pieceFont = 'DejaVu Sans';
const pieceFallback = ['Noto Sans Symbols 2'];

/// chess_squares: the light and dark squares of a board style.
(Color, Color) chessSquares(Look look, String style) {
  for (final b in boards) {
    if (b.$1 == style && b.$3 != null) return b.$3!;
  }
  return (Color.lerp(look.bg, look.fg, .62)!, Color.lerp(look.bg, look.accent, .45)!);
}

const _light = Color.fromRGBO(247, 245, 237, 1); // (0.97, 0.96, 0.93)
const _ink = Color.fromRGBO(26, 26, 31, 1); // (0.10, 0.10, 0.12)
const _halo = Color.fromRGBO(235, 232, 222, .85); // (0.92, 0.91, 0.87, 0.85)

TextPainter _glyph(String text, double size, Paint paint) => TextPainter(
  text: TextSpan(
    text: text,
    style: TextStyle(fontFamily: pieceFont, fontFamilyFallback: pieceFallback, fontSize: size, foreground: paint),
  ),
  textDirection: TextDirection.ltr,
)..layout();

/// chess_paint_piece: a piece centred on `c`. Classic: White the solid shape filled light with
/// the outline glyph dark on top; Black a light halo round the dark solid shape. Flat: the solid
/// shape with a thin edge. Theme colours: White in the text colour with details in the
/// background, Black a dark tint of the accent with an edge in the text colour.
void paintPiece(Canvas canvas, String piece, Offset c, double cell, String style, Look look, {double? fontSize}) {
  final kind = piece.toUpperCase();
  final white = piece == kind;
  final size = fontSize ?? math.max(8, cell * .62).toDouble();
  void at(TextPainter tp) => tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  if (style == 'flat' || style == 'theme') {
    final theme = style == 'theme';
    final light = theme ? look.fg : _light;
    final dark = theme ? Color.lerp(look.bg, look.accent, .3)! : _ink;
    final fill = white ? light : dark;
    final edge = theme ? (white ? look.bg : light) : (white ? _ink : _light);
    canvas.save();
    at(
      _glyph(
        glyphs[kind]!,
        size,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.2, cell / 30)
          ..strokeJoin = StrokeJoin.round
          ..color = edge.withValues(alpha: .9),
      ),
    );
    at(_glyph(glyphs[kind]!, size, Paint()..color = fill));
    if (theme && white) {
      canvas
        ..translate(c.dx, c.dy)
        ..scale(1.12)
        ..translate(-c.dx, -c.dy);
      at(_glyph(outlines[kind]!, size, Paint()..color = look.bg));
    }
    canvas.restore();
    return;
  }
  canvas.save();
  if (white) {
    canvas
      ..translate(c.dx, c.dy)
      ..scale(1.12)
      ..translate(-c.dx, -c.dy);
    at(_glyph(glyphs[kind]!, size, Paint()..color = _light));
    at(_glyph(outlines[kind]!, size, Paint()..color = _ink));
  } else {
    at(
      _glyph(
        glyphs[kind]!,
        size,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, cell / 22)
          ..strokeJoin = StrokeJoin.round
          ..color = _halo,
      ),
    );
    at(_glyph(glyphs[kind]!, size, Paint()..color = _ink));
  }
  canvas.restore();
}

/// A piece glyph as the cards draw it (.am-chess-glyph with .am-chess-white/black).
class PieceGlyph extends StatelessWidget {
  const PieceGlyph(this.piece, {super.key, this.size = 26});
  final String piece;
  final double size;
  @override
  Widget build(BuildContext context) {
    final white = piece == piece.toUpperCase();
    final shade = white ? const Color(0xff1e1e24) : const Color(0xffd8d6cc);
    return Text(
      glyphs[piece.toUpperCase()]!,
      style: TextStyle(
        fontFamily: pieceFont,
        fontFamilyFallback: pieceFallback,
        fontSize: size,
        height: 1.15,
        color: white ? const Color(0xfff7f5ee) : const Color(0xff19191e),
        shadows: [
          Shadow(color: shade, blurRadius: 1),
          Shadow(color: shade, blurRadius: 2),
        ],
      ),
    );
  }
}

/// Where the board is drawn inside its box (chess_geometry): whole-pixel squares, centred.
({double x0, double y0, double cell}) boardGeometry(Size size) {
  final side = math.max(8.0, math.min(math.min(size.width, size.height), boardMax));
  final cell = (side / 8).floorToDouble();
  return (
    x0: ((size.width - cell * 8) / 2).floorToDouble(),
    y0: ((size.height - cell * 8) / 2).floorToDouble(),
    cell: cell,
  );
}

/// The board: [game] is drawn, a human move goes to [onMove], a define-mode edit to [onEdit].
class ChessBoard extends StatefulWidget {
  const ChessBoard({
    super.key,
    required this.game,
    required this.side,
    required this.boardStyle,
    required this.pieceStyle,
    required this.coordinates,
    required this.onMove,
    required this.onEdit,
    this.palette,
    this.canMove = true,
  });
  final ChessGame game;
  final double side;
  final String boardStyle, pieceStyle;
  final bool coordinates;

  /// Your move (the game asks the agent afterwards).
  final ValueChanged<Move> onMove;

  /// Define mode: a square's piece changed ("" empties it).
  final void Function(int square, String piece) onEdit;

  /// Define mode: the piece placed by a click.
  final String? palette;

  /// You may move now (not while agents play each other or one thinks).
  final bool canMove;
  @override
  State<ChessBoard> createState() => ChessBoardState();
}

class ChessBoardState extends State<ChessBoard> {
  int? selected;
  _Drag? _drag;
  final _box = GlobalKey();

  ChessGame get game => widget.game;
  bool get _define => game.mode == ChessMode.define;
  bool get flipped => game.playerSide == 'b' && game.mode == ChessMode.game;

  @override
  void didUpdateWidget(ChessBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A move played or the game changed: the selection goes.
    if (selected != null && (game.position.at(selected!).isEmpty || !widget.canMove && !_define)) selected = null;
  }

  int? squareAt(Offset p) {
    final box = _box.currentContext?.size;
    if (box == null) return null;
    final g = boardGeometry(box);
    final col = ((p.dx - g.x0) / g.cell).floor(), row = ((p.dy - g.y0) / g.cell).floor();
    if (col < 0 || col > 7 || row < 0 || row > 7) return null;
    final (file, rank) = flipped ? (7 - col, row) : (col, 7 - row);
    return rank * 8 + file;
  }

  /// A square of the board in global coordinates (for a piece dragged from a card).
  int? squareAtGlobal(Offset global) {
    final render = _box.currentContext?.findRenderObject() as RenderBox?;
    return render == null ? null : squareAt(render.globalToLocal(global));
  }

  bool get _yourTurn => widget.canMove && game.yourTurn;

  void _down(PointerDownEvent e) {
    if (e.buttons & kSecondaryMouseButton != 0) {
      final sq = squareAt(e.localPosition);
      if (_define && sq != null) widget.onEdit(sq, '');
      return;
    }
    if (e.buttons & kPrimaryButton == 0) return;
    final sq = squareAt(e.localPosition);
    final piece = sq == null ? '' : game.position.at(sq);
    final movable = piece.isNotEmpty && (_define || (_yourTurn && colorOf(piece) == game.position.turn));
    _drag = _Drag(sq, piece, e.localPosition, movable);
  }

  void _move(PointerMoveEvent e) {
    final d = _drag;
    if (d == null) return;
    d.at = e.localPosition;
    if (d.movable && (d.moving || (d.at - d.start).distance > 6)) {
      if (!d.moving && !_define) selected = d.from; // its legal squares show while it is dragged
      d.moving = true;
      setState(() {});
    }
  }

  void _up(PointerUpEvent e) {
    final d = _drag;
    _drag = null;
    if (d == null) return;
    if (!d.moving) {
      _clicked(d.from, e.localPosition);
      return;
    }
    final target = squareAt(e.localPosition);
    if (_define) {
      widget.onEdit(d.from!, '');
      if (target != null) widget.onEdit(target, d.piece); // off the board: the piece is taken away
      setState(() {});
      return;
    }
    final moves = rules.legalMoves(game.position).where((m) => m.start == d.from && m.end == target).toList();
    if (moves.length > 1) {
      _promote(moves, e.position);
    } else if (moves.isNotEmpty) {
      _made(moves.first);
    } else {
      setState(() => selected = null);
    }
  }

  void _clicked(int? sq, Offset local) {
    if (sq == null) return;
    if (_define) {
      final piece = game.position.at(sq);
      widget.onEdit(sq, widget.palette == null || piece == widget.palette ? '' : widget.palette!);
      return;
    }
    if (!_yourTurn) return;
    final pos = game.position;
    if (selected != null) {
      final moves = rules.legalMoves(pos).where((m) => m.start == selected && m.end == sq).toList();
      if (moves.length > 1) {
        final render = _box.currentContext!.findRenderObject() as RenderBox;
        _promote(moves, render.localToGlobal(local));
        return;
      }
      if (moves.isNotEmpty) {
        _made(moves.first);
        return;
      }
    }
    final piece = pos.at(sq);
    setState(() => selected = piece.isNotEmpty && colorOf(piece) == pos.turn ? sq : null);
  }

  void _made(Move move) {
    setState(() => selected = null);
    widget.onMove(move);
  }

  /// chess_ask_promotion: a row of the four pieces where the pawn was let go.
  Future<void> _promote(List<Move> moves, Offset global) async {
    final look = Look.of(context);
    final white = game.position.turn == 'w';
    moves.sort((a, b) => 'qrbn'.indexOf(a.promotion).compareTo('qrbn'.indexOf(b.promotion)));
    final chosen = await showGeneralDialog<Move>(
      context: context,
      barrierDismissible: true,
      barrierLabel: tr("Promotion"),
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (context, _, _) {
        final screen = MediaQuery.sizeOf(context);
        const width = 4 * 52.0 + 16;
        return Stack(
          children: [
            Positioned(
              left: (global.dx - width / 2).clamp(4, math.max(4, screen.width - width - 4)),
              top: (global.dy + 8).clamp(4, math.max(4, screen.height - 70)),
              child: Material(
                color: Color.lerp(look.bg, look.fg, .08),
                elevation: 6,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(corners(context)),
                  side: BorderSide(color: look.fg.withValues(alpha: .2)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final m in moves)
                        Tooltip(
                          message: kindNames[m.promotion.toUpperCase()]!,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(cornerSizes(context).small),
                            onTap: () => Navigator.pop(context, m),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: PieceGlyph(white ? m.promotion.toUpperCase() : m.promotion, size: 28),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (chosen == null) {
      setState(() => selected = null);
    } else {
      _made(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    return SizedBox(
      key: _box,
      width: widget.side,
      height: widget.side,
      child: Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: (_) => setState(() => _drag = null),
        child: CustomPaint(
          size: Size.square(widget.side),
          painter: _BoardPainter(
            game: game,
            look: look,
            flipped: flipped,
            selected: _define ? null : selected,
            drag: _drag?.moving == true ? _drag : null,
            boardStyle: widget.boardStyle,
            pieceStyle: widget.pieceStyle,
            coordinates: widget.coordinates,
            stamp: Object.hash(game.position, game.lastMove, game.revision),
            radius: cornerSizes(context).board,
          ),
        ),
      ),
    );
  }
}

class _Drag {
  _Drag(this.from, this.piece, this.start, this.movable) : at = start;
  final int? from;
  final String piece;
  final Offset start;
  final bool movable;
  Offset at;
  bool moving = false;
}

class _BoardPainter extends CustomPainter {
  _BoardPainter({
    required this.game,
    required this.look,
    required this.flipped,
    required this.selected,
    required this.drag,
    required this.boardStyle,
    required this.pieceStyle,
    required this.coordinates,
    required this.stamp,
    this.radius = 0,
  }) : dragAt = drag?.at;
  final ChessGame game;
  final Look look;
  final bool flipped, coordinates;
  final int? selected;
  final _Drag? drag;
  final Offset? dragAt;
  final String boardStyle, pieceStyle;
  final int stamp;

  /// Settings › Corners, as the cards (at most 12): the squares are clipped to it.
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final (light, dark) = chessSquares(look, boardStyle);
    final g = boardGeometry(size);
    final cell = g.cell;
    final frame = Rect.fromLTWH(g.x0, g.y0, cell * 8, cell * 8);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(frame, Radius.circular(radius)));
    final pos = game.position;
    final last = game.mode == ChessMode.define ? null : game.lastMove;
    final targets = selected == null
        ? const <int>{}
        : {
            for (final m in rules.legalMoves(pos))
              if (m.start == selected) m.end,
          };
    int? check;
    final king = pos.turn == 'w' ? 'K' : 'k';
    if (pos.board.contains(king) && rules.inCheck(pos, pos.turn)) check = pos.board.indexOf(king);
    final coordSize = math.max(7, (cell / 6).floor()).toDouble();
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        final (file, rank) = flipped ? (7 - col, row) : (col, 7 - row);
        final sq = rank * 8 + file;
        final rect = Rect.fromLTWH(g.x0 + col * cell, g.y0 + row * cell, cell, cell);
        final base = (file + rank).isOdd ? light : dark;
        canvas.drawRect(rect, Paint()..color = base);
        if (last != null && (sq == last.start || sq == last.end)) {
          canvas.drawRect(rect, Paint()..color = look.accent.withValues(alpha: .35));
        }
        if (sq == selected) canvas.drawRect(rect, Paint()..color = look.accent.withValues(alpha: .6));
        if (sq == check) {
          canvas.drawCircle(rect.center, cell * .48, Paint()..color = look.red.withValues(alpha: .55));
        }
        // File letters on the bottom row, rank numbers on the left column.
        final ink = base == light ? dark : light;
        void label(String text, Offset at) => (TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(fontSize: coordSize, fontWeight: FontWeight.w700, color: ink, height: 1),
          ),
          textDirection: TextDirection.ltr,
        )..layout()).paint(canvas, at);
        if (coordinates && row == 7) {
          label(rules.files[file], Offset(rect.left + cell - (cell / 5).floor(), rect.top + cell - (cell / 4).floor()));
        }
        if (coordinates && col == 0) label('${rank + 1}', Offset(rect.left + 3, rect.top + 2));
        final piece = pos.at(sq);
        final dragged = drag != null && drag!.from == sq;
        if (piece.isNotEmpty && !dragged) paintPiece(canvas, piece, rect.center, cell, pieceStyle, look);
        if (targets.contains(sq)) {
          final paint = Paint()..color = look.accent.withValues(alpha: .85);
          if (piece.isNotEmpty) {
            paint
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(2, cell / 18);
          }
          canvas.drawCircle(rect.center, cell * (piece.isNotEmpty ? .42 : .14), paint);
        }
      }
    }
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(frame.deflate(.5), Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = look.fg.withValues(alpha: .35),
    );
    if (drag != null && dragAt != null) {
      paintPiece(
        canvas,
        drag!.piece,
        dragAt!,
        cell * 1.1,
        pieceStyle,
        look,
        fontSize: math.max(8, cell * .62).toDouble(),
      );
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) =>
      old.stamp != stamp ||
      old.selected != selected ||
      old.dragAt != dragAt ||
      (old.drag == null) != (drag == null) ||
      old.flipped != flipped ||
      old.boardStyle != boardStyle ||
      old.pieceStyle != pieceStyle ||
      old.coordinates != coordinates ||
      old.radius != radius ||
      old.look != look;
}

/// A preview tile of the Board and pieces menu: a 4×4 corner of a board, or a white and a black
/// knight in a piece style on the chosen board's two colours.
class LookTile extends StatelessWidget {
  const LookTile({super.key, required this.board, this.pieces});
  final String board;
  final String? pieces;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size.square(52), painter: _TilePainter(Look.of(context), board, pieces));
}

class _TilePainter extends CustomPainter {
  _TilePainter(this.look, this.board, this.pieces);
  final Look look;
  final String board;
  final String? pieces;
  @override
  void paint(Canvas canvas, Size size) {
    final (light, dark) = chessSquares(look, board);
    if (pieces == null) {
      final cell = size.width / 4;
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 4; c++) {
          canvas.drawRect(
            Rect.fromLTWH(c * cell, r * cell, cell + .5, cell + .5),
            Paint()..color = (r + c).isEven ? light : dark,
          );
        }
      }
      return;
    }
    final half = size.width / 2;
    for (var i = 0; i < 2; i++) {
      canvas.drawRect(Rect.fromLTWH(i * half, 0, half + .5, size.height), Paint()..color = i == 0 ? light : dark);
      paintPiece(
        canvas,
        i == 0 ? 'N' : 'n',
        Offset(i * half + half / 2, size.height / 2),
        half,
        pieces!,
        look,
        fontSize: (half * 1.15).floorToDouble(),
      );
    }
  }

  @override
  bool shouldRepaint(_TilePainter old) => old.board != board || old.pieces != pieces || old.look != look;
}
