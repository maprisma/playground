import 'package:maprisma_playground_core/maprisma_playground_core.dart'
    show sharedHelperAuto, sharedHelperCommand, tr, trf;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart' as rules;
import 'package:maprisma_playground_core/maprisma_playground_core.dart'
    show ChessGame, ChessMode, Move, Position, Settings;

import '../app.dart';
import '../backend.dart';
import '../chess_board.dart';
import '../contestants.dart';
import '../esc_close.dart';
import '../theme.dart';
import '../widgets.dart';
import '../window.dart';
import '../work.dart';

/// The Chess tab (ai_playground.build_chess_tab, chess_page.py, chess_import.py): the opponent
/// and Import video…, the drop strip, the board with its piece cards, the Game and Saved games
/// cards, and the replay bar.
class ChessPage extends StatefulWidget {
  const ChessPage({super.key, required this.host, required this.active, this.playground, this.session});
  final Host host;
  final Playground? playground;

  /// The chess tab is the one in view: only then do drops and Ctrl+V reach it.
  final bool active;

  /// Tests hand in their own (with a fake core); the app uses the one of its Playground.
  final ChessSession? session;

  /// Ctrl+V on the chess tab (the Shell forwards it): a YouTube link from the clipboard.
  static void paste() => _paste?.call();
  static VoidCallback? _paste;

  @override
  State<ChessPage> createState() => _ChessPageState();
}

const _takenW = 40.0; // the columns of captured pieces beside the board
const _takenOrder = 'QRBNP';
const _maxDrop = 64 * 1024;

class _ChessPageState extends State<ChessPage> {
  late final ChessSession s = widget.session ?? ChessSession.of(widget.playground!, widget.host.settings);
  final _board = GlobalKey<ChessBoardState>();
  final _body = GlobalKey();
  final _look = MenuController();
  final _subscriptions = <StreamSubscription>[];
  double _side = boardMin; // _fit grows it to what the window allows
  bool _dragOver = false;
  bool get _visible => widget.active;

  @override
  void initState() {
    super.initState();
    s.toast = widget.host.toast;
    s.addListener(_changed);
    ChessPage._paste = _paste;
    EscFallback.menus.add(_look); // Esc closes the Board and pieces menu before anything else
    _subscriptions
      ..add(
        AppWindow.instance.dragging.stream.listen((at) {
          final over = at != null && _visible;
          if (over != _dragOver && mounted) setState(() => _dragOver = over);
        }),
      )
      ..add(AppWindow.instance.drops.stream.listen(_dropped));
  }

  @override
  void didUpdateWidget(ChessPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && _dragOver) _dragOver = false;
  }

  @override
  void dispose() {
    s.removeListener(_changed);
    if (ChessPage._paste == _paste) ChessPage._paste = null;
    EscFallback.menus.remove(_look);
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  // --- drops and Ctrl+V -----------------------------------------------------------------------

  void _dropped(Drop drop) {
    if (!_visible || !mounted) return;
    setState(() => _dragOver = false);
    if (!drop.type.startsWith('text/')) return;
    if (drop.data.length > _maxDrop) {
      widget.host.toast(tr("That drop was too large or too slow to read."));
      return;
    }
    _droppedText(utf8.decode(drop.data, allowMalformed: true));
  }

  /// chess_dropped: a file (file://) or a YouTube link.
  void _droppedText(String text) {
    final url = youtubeUrl(text);
    final lines = [
      for (final l in const LineSplitter().convert(text))
        if (l.trim().isNotEmpty && !l.startsWith('#')) l.trim(),
    ];
    if (url.isEmpty && lines.isNotEmpty && lines.first.startsWith('file://')) {
      final path = localPath(lines.first);
      if (path == null) {
        widget.host.toast(tr("That is not a video file (MP4, MKV, WebM, MOV, AVI)."));
        return;
      }
      _importAsk(path: path);
      return;
    }
    _importAsk(url: url);
  }

  Future<void> _paste() async {
    if (!_visible) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    var text = (data?.text ?? '').trim();
    if (text.length > _maxDrop) text = '';
    if (text.startsWith('/') && !text.contains('\n')) {
      _importAsk(path: Uri.file(text).toFilePath()); // a bare absolute path, taken as it is
    } else if (youtubeUrl(text).isNotEmpty || text.startsWith('file://')) {
      _droppedText(text);
    } else {
      widget.host.toast(tr("Copy a YouTube link first, then press Ctrl+V on the chess tab."));
    }
  }

  Future<void> _pickVideo() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: tr("Videos"), mimeTypes: ['video/*']),
      ],
      confirmButtonText: tr("Open"),
    );
    if (file != null) _importAsk(path: file.path);
  }

  /// chess_import_ask: which agent reads, how often a frame is taken, what it costs.
  Future<void> _importAsk({String path = '', String url = ''}) async {
    final toast = widget.host.toast;
    if (s.importing) {
      toast(tr("A video is being read already."));
      return;
    }
    if (path.isNotEmpty &&
        (!videoTypes.any((t) => path.toLowerCase().endsWith(t)) || !FileSystemEntity.isFileSync(path))) {
      toast(tr("That is not a video file (MP4, MKV, WebM, MOV, AVI)."));
      return;
    }
    if (path.isEmpty && url.isEmpty) {
      toast(tr("Drop a video file or a YouTube link."));
      return;
    }
    List<String> seeingCommands, textCommands;
    Map<String, dynamic>? before;
    double? seconds;
    try {
      final r = await s.core('import.readers', {if (path.isNotEmpty) 'path': path else 'url': url}).result;
      seeingCommands = [for (final c in (r['readers'] as List? ?? const [])) '$c'];
      textCommands = [for (final c in (r['text_readers'] as List? ?? const [])) '$c'];
      before = (r['before'] as Map?)?.cast<String, dynamic>();
      seconds = (r['seconds'] as num?)?.toDouble();
    } on CoreFailure catch (e) {
      toast(e.message);
      return;
    }
    if (!mounted || !widget.active) return;
    s.playground?.readHelperChoice(); // the helper for every Maprisma app, as it is now
    final choice = s.playground?.helperChoice ?? sharedHelperAuto;
    final ready = s.agentsOf().where((a) => a.ready).toList();
    final seeing = ready.where((a) => seeingCommands.contains(a.command)).toList();
    final everyone = ready.where((a) => textCommands.contains(a.command)).toList();
    if ((url.isNotEmpty ? everyone : seeing).isEmpty) {
      final blind = [
        for (final a in ready)
          if (a.readsUntrusted) a.name,
      ];
      final tools = [
        for (final a in ready)
          if (!a.readsUntrusted) a.name,
      ];
      final body = StringBuffer(
        tr(
          "Reading the moves needs an agent that sees pictures and runs without tools: Claude Code or Pi, signed in or connected to a local vision model.",
        ),
      );
      body.write('\n\n');
      if (blind.isNotEmpty) body.write('${trf("Set up here: {0}. They cannot see pictures.", [blind.join(', ')])}\n\n');
      if (tools.isNotEmpty) {
        body.write(
          '${trf("Left out: {0}. It can read files on this computer, and a video's text or pictures could ask it to.", [tools.join(', ')])}\n\n',
        );
      }
      if (ready.isEmpty) body.write('${tr("No agent is set up here yet.")}\n\n');
      body.write(tr("Set up one of them (AI Agents Map can install it and sign you in), then drop the video again."));
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            tr("No agent here can read a video"),
            style: Theme.of(context).textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w700),
          ),
          content: SizedBox(width: 460, child: AnswerText(body.toString())),
          actions: [SmallButton(tr("OK"), onPressed: () => Navigator.pop(context))],
        ),
      );
      return;
    }
    final earlier = before == null ? null : SavedGame(before);
    final picked = await showDialog<_ImportChoice>(
      context: context,
      builder: (context) => _ImportDialog(
        path: path,
        url: url,
        seeing: seeing,
        shared: choice == sharedHelperAuto ? null : sharedHelperCommand(choice),
        everyone: everyone,
        opponent: s.opponent,
        before: earlier,
        seconds: seconds,
      ),
    );
    if (picked == null) return;
    s.importStart(
      path: path,
      url: url,
      reader: picked.reader.command,
      gap: picked.gap,
      limitSeconds: picked.limitMinutes * 60,
      way: picked.way,
      replaceId: earlier?.id ?? '',
    );
  }

  // --- the board's size -----------------------------------------------------------------------

  /// chess_fit: the board as big as the room allows (320…560), so the page fits without scrolling.
  void _fit(BoxConstraints view) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final body = _body.currentContext?.size;
      if (body == null) return;
      final other = body.height - _side;
      var side = (view.maxHeight - other - 4).clamp(0.0, view.maxWidth - 2 * (_takenW + 8) - 40 - 48);
      side = ((side / 8).floor() * 8).toDouble().clamp(boardMin, boardMax);
      if ((side - _side).abs() >= 8) setState(() => _side = side);
    });
  }

  // --- building -------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final radius = corners(context);
    final page = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _opponentRow(look),
              vgap,
              s.importing ? _importBar(look, radius) : _dropHint(look, radius),
              vgap,
              Row(
                children: [
                  Expanded(child: SectionTitle(s.title)),
                  _lookButton(look),
                ],
              ),
              const SizedBox(height: gap),
              Divider(height: 1, thickness: 1, color: look.fg.withValues(alpha: .12)),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, view) {
              _fit(view);
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, gap, 32, 16),
                child: Column(
                  key: _body,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _controls(look),
                    if (s.game.mode == ChessMode.define) ...[vgap, _setupRow()],
                    vgap,
                    _boardArea(look, radius),
                    vgap,
                    _gameCard(look, radius),
                    vgap,
                    _savedCard(look),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
    // The frame while something is dragged over the tab (.am-drop-zone.am-drop-active).
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: _dragOver ? Border.all(color: look.accent, width: 2) : null,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: ColoredBox(color: _dragOver ? look.accent.withValues(alpha: .06) : Colors.transparent, child: page),
    );
  }

  Widget _opponentRow(Look look) {
    final agents = s.playable;
    return Row(
      children: [
        Text(tr("Opponent"), style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: look.fg)),
        const SizedBox(width: 8),
        Choice<String>(
          value: s.opponent?.command,
          items: [for (final a in agents) a.command],
          label: s.nameOf,
          empty: tr("No agent is set up"),
          tooltip: tr("The agent you play against; with “Agent against agent” it plays Black"),
          onChanged: (c) => s.pickOpponent(agents.firstWhere((a) => a.command == c)),
        ),
        const SizedBox(width: 8),
        SmallButton(
          tr("Import video…"),
          onPressed: _pickVideo,
          tooltip: tr(
            "A chess video (a file, or a YouTube link dropped here): an agent that sees reads the moves, and the game is saved to replay",
          ),
        ),
      ],
    );
  }

  /// .am-drop-hint: a dashed strip that says what can be dropped.
  Widget _dropHint(Look look, double radius) => CustomPaint(
    painter: _Dashed(look.fg.withValues(alpha: .30), radius),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.upload_file_outlined, size: 18, color: look.dim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr(
                "Drop a chess video here, a file or a YouTube link, anywhere on this tab, or copy a YouTube link and press Ctrl+V: an agent that sees reads its moves and the game is saved below to replay.",
              ),
              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: look.dim, height: 1.3),
            ),
          ),
        ],
      ),
    ),
  );

  /// .am-import-bar: while a video is read, in place of the hint.
  Widget _importBar(Look look, double radius) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: look.accent.withValues(alpha: .10),
      border: Border.all(color: look.accent),
      borderRadius: BorderRadius.circular(radius),
    ),
    child: Row(
      children: [
        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: look.fg)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.importTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w600, color: look.fg),
              ),
              const SizedBox(height: 4),
              Text(
                s.importText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: look.fg),
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: s.importFraction, color: look.accent),
            ],
          ),
        ),
        const SizedBox(width: 8),
        SmallButton(tr("Cancel"), onPressed: s.importStopping ? null : s.cancelImport),
      ],
    ),
  );

  /// build_chess_look: the Board and pieces menu (a tile per board and per piece style).
  Widget _lookButton(Look look) => MenuAnchor(
    controller: _look,
    alignmentOffset: const Offset(-330, 4),
    menuChildren: [_LookMenu(session: s)],
    child: IconSmallButton(
      Icons.palette,
      tooltip: tr("Board and pieces"),
      onPressed: () => _look.isOpen ? _look.close() : _look.open(),
    ),
  );

  Widget _controls(Look look) {
    final agents = s.choice == 'agents';
    final rivals = s.rivals;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Choice<String>(
          value: s.choice,
          items: [for (final c in choices) c.$1],
          label: (k) => labelOf(choices, k),
          tooltip: tr("A new game, or a position set up by hand"),
          onChanged: (k) {
            s.choice = k;
            s.start(context);
          },
        ),
        if (agents) ...[
          Choice<String>(
            value: s.rivalPick?.command,
            items: [for (final a in rivals) a.command],
            label: s.nameOf,
            tooltip: tr("The agent that plays White against it"),
            onChanged: (c) {
              s.rivalPick = rivals.firstWhere((a) => a.command == c);
              s.start(context);
            },
          ),
          Choice<String>(
            value: s.rivalStrength,
            items: [for (final e in strengthLabels) e.$1],
            label: (k) => labelOf(strengthLabels, k),
            tooltip: tr("White's strength: how strongly the agent playing White is asked to play"),
            onChanged: (k) {
              s.rivalStrength = k;
              s.save({'chess_rival_strength': k});
              setState(() {});
            },
          ),
        ],
        Choice<String>(
          value: s.thinking,
          items: [for (final e in thinkingLabels) e.$1],
          label: (k) => labelOf(thinkingLabels, k),
          tooltip: tr(
            "Thinking time: how long the agent may take for a move. Longer also lets its model think harder.",
          ),
          onChanged: (k) {
            s.thinking = k;
            s.save({'chess_thinking': k});
            setState(() {});
          },
        ),
        Choice<String>(
          value: s.strength,
          items: [for (final e in strengthLabels) e.$1],
          label: (k) => labelOf(strengthLabels, k),
          tooltip: agents
              ? tr("Black's strength: how strongly the agent playing Black is asked to play")
              : tr(
                  "Strength: how strongly the agent is asked to play. A beginner makes mistakes now and then; the strongest play also wants a long thinking time.",
                ),
          onChanged: (k) {
            s.strength = k;
            s.save({'chess_strength': k});
            setState(() {});
          },
        ),
        SmallButton(tr("Start"), onPressed: () => s.start(context)),
        if (s.rival != null && s.game.mode == ChessMode.game)
          _Toggle(
            label: tr("Pause"),
            on: s.game.paused,
            tooltip: tr("Agent against agent: no new move is asked for until you go on"),
            onChanged: s.setPaused,
          ),
        if (s.game.thinking)
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: look.fg)),
      ],
    );
  }

  /// Setting up a position: whose move, and the rest of the tools.
  Widget _setupRow() => Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Choice<String>(
        value: s.turnChoice,
        items: const ['w', 'b'],
        label: (k) => k == 'w' ? tr("White to move") : tr("Black to move"),
        onChanged: s.setTurn,
      ),
      SmallButton(tr("Empty board"), onPressed: () => s.fill(empty: true)),
      SmallButton(tr("Start position"), onPressed: () => s.fill(empty: false)),
      SmallButton(tr("Play it with White"), onPressed: () => s.playSetup('w')),
      SmallButton(tr("Play it with Black"), onPressed: () => s.playSetup('b')),
    ],
  );

  Widget _boardArea(Look look, double radius) {
    final define = s.game.mode == ChessMode.define;
    final flipped = s.game.playerSide == 'b' && !define;
    final taken = define ? const <String>[] : s.game.takenPieces;
    Widget takenColumn(String side) {
      final mine = taken.where((p) => side == 'w' ? p == p.toUpperCase() : p == p.toLowerCase()).toList()
        ..sort((a, b) => _takenOrder.indexOf(a.toUpperCase()).compareTo(_takenOrder.indexOf(b.toUpperCase())));
      return SizedBox(
        width: _takenW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in mine)
              Tooltip(
                message: trf("{0} captured", [kindNames[p.toUpperCase()]]),
                child: SizedBox(height: 22, child: PieceGlyph(p, size: 20)),
              ),
          ],
        ),
      );
    }

    final board = DragTarget<String>(
      onWillAcceptWithDetails: (_) => define,
      onAcceptWithDetails: (d) {
        final sq = _board.currentState?.squareAtGlobal(d.offset);
        if (sq != null) s.edit(sq, d.data);
      },
      builder: (context, _, _) => ChessBoard(
        key: _board,
        game: s.game,
        side: _side,
        boardStyle: s.boardStyle,
        pieceStyle: s.pieceStyle,
        coordinates: s.coordinates,
        palette: s.palette,
        canMove: s.rival == null && !s.game.thinking,
        onMove: s.humanMove,
        onEdit: s.edit,
      ),
    );
    final replaying = s.game.mode == ChessMode.replay;
    final column = SizedBox(
      width: _side,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _cards(flipped ? 'w' : 'b', define, look, radius),
          const SizedBox(height: 8),
          board,
          const SizedBox(height: 8),
          _cards(flipped ? 'b' : 'w', define, look, radius),
        ],
      ),
    );
    return Column(
      children: [
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [takenColumn('b'), const SizedBox(width: 8), column, const SizedBox(width: 8), takenColumn('w')],
          ),
        ),
        // Beneath the board while a saved game is replayed (one line, as wide as it needs).
        if (replaying) ...[const SizedBox(height: 8), _replayBar()],
      ],
    );
  }

  /// chess_fill_cards: a card per kind of piece with how many are on the board; while a position
  /// is set up, the pieces to place (click one, then squares; or drag it onto the board).
  Widget _cards(String side, bool define, Look look, double radius) {
    final board = s.game.position.board;
    Widget card(String kind) {
      final piece = side == 'w' ? kind : kind.toLowerCase();
      final count = board.where((p) => p == piece).length;
      final picked = define && s.palette == piece;
      final inner = Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: picked ? look.accent.withValues(alpha: .16) : look.fg.withValues(alpha: .04),
          border: Border.all(color: picked ? look.accent : look.fg.withValues(alpha: .12), width: picked ? 2 : 1),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Column(
          children: [
            PieceGlyph(piece),
            Text(
              '${kindNames[kind]} ×$count',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: look.dim),
            ),
          ],
        ),
      );
      if (!define) {
        return Tooltip(
          message: trf("{0} on the board", [kindNames[kind]]),
          child: Opacity(opacity: count == 0 ? .4 : 1, child: inner),
        );
      }
      return Tooltip(
        message: trf("Place: {0}", [kindNames[kind]]),
        child: Draggable<String>(
          data: piece,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Transform.translate(offset: const Offset(-20, -24), child: PieceGlyph(piece, size: 36)),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(key: ValueKey('card-$piece'), onTap: () => s.pick(piece), child: inner),
          ),
        ),
      );
    }

    return Row(
      children: [
        for (var i = 0; i < kinds.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: card(kinds[i])),
        ],
      ],
    );
  }

  /// Beneath the board while a saved game is replayed.
  Widget _replayBar() => Wrap(
    spacing: 4,
    runSpacing: 4,
    alignment: WrapAlignment.center,
    children: [
      IconSmallButton(Icons.first_page, tooltip: tr("First move"), onPressed: () => s.step('first')),
      IconSmallButton(Icons.chevron_left, tooltip: tr("Back one move"), onPressed: () => s.step('back')),
      IconSmallButton(Icons.chevron_right, tooltip: tr("Next move"), onPressed: () => s.step('next')),
      IconSmallButton(Icons.last_page, tooltip: tr("Last move"), onPressed: () => s.step('last')),
      SmallButton(
        s.autoPlaying ? tr("Pause") : tr("Auto"),
        icon: s.autoPlaying ? Icons.pause : Icons.play_arrow,
        tooltip: s.autoPlaying ? tr("Stop at this move") : tr("Play the moves one after another"),
        onPressed: () => s.setAuto(!s.autoPlaying),
      ),
      SmallButton(
        tr("Play from here"),
        tooltip: tr("Go on from the move in view against the opponent; you play the side to move"),
        onPressed: s.playFromHere,
      ),
    ],
  );

  /// The Game card: whose move it is, what the agent said, and the moves so far.
  Widget _gameCard(Look look, double radius) {
    final g = s.game;
    final define = g.mode == ChessMode.define;
    final said = [g.comment, g.error].where((t) => t.isNotEmpty).join('\n');
    final status = s.status;
    return FoldCard(
      title: tr("Game"),
      icon: Icons.sports_esports,
      summary: status,
      initiallyOpen: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            status,
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w600, color: look.fg),
          ),
          if (said.isNotEmpty && !define) ...[
            const SizedBox(height: gap),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: look.accent.withValues(alpha: .08),
                border: Border(left: BorderSide(color: look.accent, width: 3)),
                borderRadius: BorderRadius.circular(radius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    trf("{0} says", [s.saidBy]),
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(fontWeight: FontWeight.w700, color: look.fg),
                  ),
                  const SizedBox(height: 4),
                  AnswerText(said),
                  if (g.error.isNotEmpty && !g.thinking) ...[
                    const SizedBox(height: 4),
                    SmallButton(tr("Ask again"), onPressed: s.askAgain),
                  ],
                ],
              ),
            ),
          ],
          if (g.moves.isNotEmpty && !define) ...[
            const SizedBox(height: gap),
            SelectableText(g.notation, style: Theme.of(context).textTheme.bodyMedium!.copyWith(height: 1.4, color: look.dim)),
          ],
          if (g.mode == ChessMode.game && g.moves.isNotEmpty) ...[
            const SizedBox(height: gap),
            SmallButton(
              s.savedId.isEmpty ? tr("Save game") : tr("Save again"),
              tooltip: tr(
                "Keep this game with the saved games (with who played and the result); a finished game is kept by itself",
              ),
              onPressed: () => s.saveCurrent(),
            ),
          ],
        ],
      ),
    );
  }

  /// chess_fill_card: the newest saved games with Replay; the symbol opens the Games page.
  Widget _savedCard(Look look) {
    final games = s.games;
    final total = s.gamesTotal;
    final none = tr("None yet. Drop a chess video or a YouTube link on this tab, or use Import video…");
    return FoldCard(
      title: tr("Saved games"),
      icon: Icons.history,
      summary: total == 1 ? tr("1 game") : trf("{0} games", [total]),
      initiallyOpen: true,
      action: IconSmallButton(
        Icons.format_list_bulleted,
        tooltip: tr("Manage saved games: search, rename, save as PGN, delete"),
        onPressed: () => widget.host.show('games'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (games.isEmpty) Hint(none),
          if (s.gamesError.isNotEmpty) ...[const SizedBox(height: 4), Hint(s.gamesError, error: true)],
          for (final g in games)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      g.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: look.fg,
                        fontWeight: g.id == s.replayId && s.game.mode == ChessMode.replay
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Hint(movesCount(g.moveTexts.length) + (g.date.isNotEmpty ? ' · ${g.date}' : '')),
                  const SizedBox(width: 8),
                  if (g.source.isNotEmpty) ...[
                    OriginalButton(game: g, toast: widget.host.toast),
                    const SizedBox(width: 8),
                  ],
                  IconSmallButton(
                    Icons.play_arrow,
                    tooltip: tr("Replay game: on the board, with the controls beneath it"),
                    onPressed: () => s.openReplay(g),
                  ),
                ],
              ),
            ),
          if (total > onCard)
            SmallButton(
              total == 1 ? tr("All 1 game…") : trf("All {0} games…", [total]),
              onPressed: () => widget.host.show('games'),
            ),
        ],
      ),
    );
  }
}

/// A Gtk.ToggleButton as .am-small-btn: Pause.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.on, required this.onChanged, this.tooltip});
  final String label;
  final bool on;
  final ValueChanged<bool> onChanged;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final button = OutlinedButton(
      onPressed: () => onChanged(!on),
      style: OutlinedButton.styleFrom(
        foregroundColor: on ? look.accent : look.fg,
        backgroundColor: on ? look.accent.withValues(alpha: .14) : null,
        side: BorderSide(color: on ? look.accent : look.fg.withValues(alpha: .35)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        minimumSize: const Size(0, 30),
        textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// The dashed frame of .am-drop-hint.
class _Dashed extends CustomPainter {
  _Dashed(this.color, this.radius);
  final Color color;
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)).deflate(.5));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 6) {
        canvas.drawPath(metric.extractPath(d, d + 3), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Dashed old) => old.color != color || old.radius != radius;
}

/// The Board and pieces menu: tiles for the board and the pieces, the chosen ones framed in the
/// accent colour, and the coordinates switch. The board shows each change at once.
class _LookMenu extends StatefulWidget {
  const _LookMenu({required this.session});
  final ChessSession session;
  @override
  State<_LookMenu> createState() => _LookMenuState();
}

class _LookMenuState extends State<_LookMenu> {
  ChessSession get s => widget.session;

  void _set(Map<String, Object?> values) {
    s.setLook(values);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final radius = corners(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: look.fg),
      ),
    );
    Widget tile(bool on, Widget picture, String name, VoidCallback pick) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: pick,
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: on ? look.accent.withValues(alpha: .12) : null,
            border: Border.all(color: on ? look.accent : Colors.transparent, width: 2),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Column(
            children: [
              picture,
              const SizedBox(height: 4),
              Text(name, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: look.fg)),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          heading(tr("Board")),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final b in boards)
                tile(s.boardStyle == b.$1, LookTile(board: b.$1), b.$2, () => _set({'chess_board': b.$1})),
            ],
          ),
          const SizedBox(height: 8),
          heading(tr("Pieces")),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in pieceStyles)
                tile(
                  s.pieceStyle == p.$1,
                  LookTile(board: s.boardStyle, pieces: p.$1),
                  p.$2,
                  () => _set({'chess_pieces': p.$1}),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 5 * 70,
            child: Row(
              children: [
                Expanded(
                  child: Text(tr("Coordinates"), style: Theme.of(context).textTheme.bodySmall!.copyWith(color: look.fg)),
                ),
                Switch(value: s.coordinates, onChanged: (v) => _set({'chess_coordinates': v})),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The open-in-new symbol: the video the game was read from (YouTube in the browser, a file in
/// the video player).
class OriginalButton extends StatelessWidget {
  const OriginalButton({super.key, required this.game, required this.toast});
  final SavedGame game;
  final void Function(String) toast;
  @override
  Widget build(BuildContext context) => IconSmallButton(
    Icons.open_in_new,
    tooltip: trf("Open the original video: {0}", [game.source]),
    onPressed: () => openOriginal(game.source, toast),
  );
}

Future<void> openOriginal(String source, void Function(String) toast) async {
  final url = youtubeUrl(source);
  String target;
  if (url.isNotEmpty) {
    target = url;
  } else if (source.startsWith('/') && FileSystemEntity.isFileSync(source)) {
    target = source;
  } else {
    toast(trf("The original video is not there any more: {0}", [source]));
    return;
  }
  try {
    await Process.start('xdg-open', [target], mode: ProcessStartMode.detached);
  } on Object catch (e) {
    toast('$e');
  }
}

/// What the import dialog returns.
final class _ImportChoice {
  _ImportChoice(this.reader, this.gap, this.limitMinutes, this.way);
  final Agent reader;
  final int gap, limitMinutes;
  final String way; // text or frames
}

const _intervals = [2, 4, 8]; // seconds between frames
const _limits = [0, 5, 15, 30]; // minutes read from the start (0: the whole video)
const _maxFrames = 600; // chess_video.MAX_FRAMES

/// The import dialog: the way (a link), which agent reads, how often a frame is taken, how much.
class _ImportDialog extends StatefulWidget {
  const _ImportDialog({
    required this.path,
    required this.url,
    required this.seeing,
    required this.everyone,
    required this.opponent,
    required this.before,
    this.shared,
    this.seconds,
  });
  final String path, url;
  final List<Agent> seeing, everyone;
  final Agent? opponent;
  final SavedGame? before;

  /// The agent of the helper chosen for every Maprisma app (null: automatic).
  final String? shared;

  /// The video's length (a file), when the core could tell.
  final double? seconds;
  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  int _way = 0, _every = 1, _part = 0;
  String? _reader;

  bool get _watching => widget.url.isEmpty || _way == 1;
  List<Agent> get _readers => _watching ? widget.seeing : widget.everyone;

  String? get _chosen {
    final commands = [for (final a in _readers) a.command];
    if (_reader != null && commands.contains(_reader)) return _reader;
    if (widget.shared != null && commands.contains(widget.shared)) return widget.shared;
    if (widget.opponent != null && commands.contains(widget.opponent!.command)) return widget.opponent!.command;
    return commands.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final readers = _readers;
    final chosen = _chosen;
    final blind = widget.opponent != null && !readers.any((a) => a.command == widget.opponent!.command);
    final seconds = widget.seconds;
    String? length;
    if (seconds != null && seconds > 0) {
      final gap = _intervals[_every], limit = _limits[_part] * 60;
      final span = limit > 0 && limit < seconds ? limit.toDouble() : seconds;
      final most = math.min(_maxFrames, span ~/ gap + 1);
      final spoken = seconds < 90
          ? trf("{0} s", [seconds.toStringAsFixed(0)])
          : trf("{0} min", [(seconds / 60).toStringAsFixed(0)]);
      length = trf(
        "{0} of video: at most {1} frames. Only frames where the picture changed are sent, each one question to the agent (it may count against your plan).",
        [spoken, most],
      );
    }
    final note =
        length ??
        (!_watching
            ? tr(
                "No download: the moves come from the description, or from one question to the agent about the description and what is said. Only if no game is found there, the video is downloaded and its frames are watched.",
              )
            : tr(
                "The video is downloaded first (at most 480p, 1 GB). Only frames where the picture changed are sent, each one question to the agent (it may count against your plan).",
              ));
    Widget line(Widget w) => Padding(padding: const EdgeInsets.only(bottom: 8), child: w);
    return AlertDialog(
      title: Text(tr("Read the moves from this video?"), style: Theme.of(context).textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w700)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            line(AnswerText(widget.path.isNotEmpty ? widget.path.split('/').last : widget.url)),
            if (widget.url.isNotEmpty)
              line(
                Choice<int>(
                  value: _way,
                  items: const [0, 1],
                  label: (i) => i == 0
                      ? tr("Fast: the description and the commentary")
                      : tr("Watch the board, frame by frame (slower)"),
                  tooltip: tr(
                    "Fast: no download; the moves come from the video's description (often a PGN) or from what is said, in seconds. If no game is found there, the frames are watched.",
                  ),
                  onChanged: (i) => setState(() => _way = i),
                ),
              ),
            line(
              Choice<String>(
                value: chosen,
                items: [for (final a in readers) a.command],
                label: (c) => readers.firstWhere((a) => a.command == c).name,
                empty: tr("No agent sees pictures"),
                onChanged: (c) => setState(() => _reader = c),
              ),
            ),
            line(
              Choice<int>(
                value: _every,
                items: const [0, 1, 2],
                label: (i) => trf("A frame every {0} s", [_intervals[i]]),
                onChanged: (i) => setState(() => _every = i),
              ),
            ),
            line(
              Choice<int>(
                value: _part,
                items: const [0, 1, 2, 3],
                label: (i) => i == 0 ? tr("The whole video") : trf("The first {0} minutes", [_limits[i]]),
                tooltip: tr("Long videos: only their start is read (faster, fewer questions)"),
                onChanged: (i) => setState(() => _part = i),
              ),
            ),
            line(AnswerText(note)),
            if (blind)
              line(
                Text(
                  trf("{0}, your opponent, cannot see pictures: the agent chosen here reads the video.", [
                    widget.opponent!.name,
                  ]),
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: look.fg),
                ),
              ),
            if (widget.before != null)
              line(
                Text(
                  trf("Read before: {0} ({1}); its game is replaced by the new reading.", [
                    widget.before!.title,
                    widget.before!.date,
                  ]),
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: look.fg),
                ),
              ),
          ],
        ),
      ),
      actions: [
        SmallButton(tr("Cancel"), onPressed: () => Navigator.pop(context)),
        ActionButton(
          tr("Read the moves"),
          onPressed: chosen == null
              ? null
              : () => Navigator.pop(
                  context,
                  _ImportChoice(
                    readers.firstWhere((a) => a.command == chosen),
                    _intervals[_every],
                    _limits[_part],
                    _watching ? 'frames' : 'text',
                  ),
                ),
        ),
      ],
    );
  }
}

// --- the chess tab's state ------------------------------------------------------------------------

/// The chess tab's state, kept for the app's life (chess_page.py's chess_* fields and
/// chess_import.py's): the game, the agent's turn, saved games, the replay and a running import.
/// It outlives the page, so Settings, Information and the Games page leave a game as it is.

/// A started core request: its reply and a way to stop it.
final class CoreCall {
  CoreCall(this.result, this.cancel);
  final Future<Map<String, dynamic>> result;
  final VoidCallback cancel;
}

/// How the chess tab speaks to the core (Backend.start, or a fake in tests).
typedef CoreStarter = CoreCall Function(
  String method,
  Map<String, dynamic> params, [
  void Function(String, Map<String, dynamic>)? onEvent,
]);

CoreStarter backendStarter(Backend backend) => (method, params, [onEvent]) {
  final job = backend.start(method, params, onEvent);
  return CoreCall(job.result, job.cancel);
};

List<(String, String)> get choices => <(String, String)>[
  ('white', tr("New game with White")),
  ('black', tr("New game with Black")),
  ('agents', tr("Agent against agent")),
  ('define', tr("Define position")),
];
List<(String, String)> get thinkingLabels => <(String, String)>[
  ('quick', tr("Quick (30 s)")),
  ('normal', tr("Normal (1½ min)")),
  ('deep', tr("Deep (3 min)")),
  ('max', tr("Maximum (6 min)")),
];
List<(String, String)> get strengthLabels => <(String, String)>[
  ('beginner', tr("Beginner")),
  ('casual', tr("Casual player")),
  ('club', tr("Club player")),
  ('master', tr("Master")),
  ('max', tr("As strong as it can")),
];
String labelOf(List<(String, String)> table, String key) =>
    table.firstWhere((e) => e.$1 == key, orElse: () => table.first).$2;

const agentsPause = Duration(milliseconds: 1200); // agent against agent: a moment to see each move
const replayStep = Duration(milliseconds: 1200); // Auto: one move every so often
const onCard = 3; // saved games on the chess tab's card

final youtube = RegExp(
  r'^https://(?:(?:www\.|m\.)?youtube\.com/(?:watch\?v=|shorts/|live/)|youtu\.be/)'
  r'[A-Za-z0-9_-]{6,20}(?:[?&#][A-Za-z0-9_=&%.-]{0,200})?$',
);
const videoTypes = ['.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v'];

/// The YouTube address in a dropped or pasted text, or "".
String youtubeUrl(String text) {
  for (final word in text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(20)) {
    if (word.length <= 300 && youtube.hasMatch(word)) return word;
  }
  return '';
}

/// The local path of a dropped or pasted file:// address, or null (another host, or not a path).
String? localPath(String uri) {
  final parsed = Uri.tryParse(uri.trim());
  if (parsed == null || parsed.scheme != 'file') return null;
  if (parsed.host.isNotEmpty && parsed.host != 'localhost') return null;
  try {
    final path = parsed.replace(host: '').toFilePath(); // file://localhost/… is local too
    return path.startsWith('/') ? path : null;
  } on Object {
    return null;
  }
}

/// A saved game as games.list gives it (chess_video.played_record):
/// {id, title, source, kind: played/video, date, start: FEN, moves: [uci], white, black, result}.
final class SavedGame {
  SavedGame(this.raw)
    : id = '${raw['id'] ?? ''}',
      title = '${raw['title'] ?? ''}',
      source = '${raw['source'] ?? ''}',
      kind = '${raw['kind'] ?? 'played'}',
      date = '${raw['date'] ?? ''}',
      result = '${raw['result'] ?? '*'}',
      moveTexts = [for (final m in (raw['moves'] as List? ?? const [])) '$m'];
  final Map<String, dynamic> raw;
  final String id, title, source, kind, date, result;
  final List<String> moveTexts;

  /// (start, moves) for the board; moves that are not legal there end it.
  (Position?, List<Move>) replay() {
    Position start;
    try {
      start = rules.fromFen('${raw['start'] ?? rules.startFen}');
    } on Object {
      return (null, const []);
    }
    final moves = <Move>[];
    var pos = start;
    for (final text in moveTexts.take(2000)) {
      final move = rules.parse(pos, text);
      if (move == null) break;
      moves.add(move);
      pos = rules.apply(pos, move);
    }
    return (start, moves);
  }

  String get movesText {
    final (start, moves) = replay();
    return start == null || moves.isEmpty ? '' : rules.gameSan(start, moves);
  }
}

String movesCount(int n) => n == 1 ? tr("1 move") : trf("{0} moves", [n]);

final class ChessSession extends ChangeNotifier {
  ChessSession({required this.core, required this.settings, required this.agentsOf, this.playground}) {
    // An agent thinking, a replay playing or an import: Esc hides the window, it does not quit.
    Work.watch(this, () => _ask != null || _auto != null || _import != null);
    boardStyle = _text('chess_board');
    pieceStyle = _text('chess_pieces');
    coordinates = _flag('chess_coordinates');
    thinking = _text('chess_thinking');
    strength = _text('chess_strength');
    rivalStrength = _text('chess_rival_strength');
    playground?.addListener(syncAgents);
    syncAgents();
  }

  static final _sessions = <Playground, ChessSession>{};

  /// The one session of the app (the chess tab and the Games page share it).
  static ChessSession of(Playground playground, Settings settings) => _sessions[playground] ??= ChessSession(
    core: backendStarter(playground.backend),
    settings: settings,
    agentsOf: () => playground.agents,
    playground: playground,
  )..refreshGames();

  /// The app closes: every cached session cancels its agent's Job and its import, stops its
  /// timers, lets go of its listeners, and is dropped.
  static void disposeAll() {
    final all = _sessions.values.toList();
    _sessions.clear();
    for (final s in all) {
      s.dispose();
    }
  }

  final CoreStarter core;
  final Settings settings;
  final List<Agent> Function() agentsOf;
  final Playground? playground;
  void Function(String text) toast = (_) {};

  final game = ChessGame(agent: '');
  Agent? opponent, rival, rivalPick;

  /// The opponent was chosen on the tab: the shared helper choice no longer moves it.
  bool opponentPicked = false;
  String choice = 'white';
  String turnChoice = 'w'; // define: who moves
  String? palette; // define: the piece a click places
  String? notice; // a problem with a set-up position, in place of the status
  late String boardStyle, pieceStyle, thinking, strength, rivalStrength;
  late bool coordinates;
  DateTime? _thinkStart;
  Timer? _clock, _auto, _next;
  CoreCall? _ask;
  String savedId = '';

  // Replaying a saved game.
  String replayId = '', replayTitle = '';
  bool get autoPlaying => _auto != null;

  // The saved games' card (the newest few) and how many there are.
  List<SavedGame> games = const [];
  int gamesTotal = 0;
  String gamesError = '';

  // A video being read.
  CoreCall? _import;
  bool get importing => _import != null;
  String importTitle = '', importText = '';
  double? importFraction;
  bool importStopping = false;

  bool _gone = false;

  String _text(String key) {
    try {
      return settings.text(key);
    } on Object {
      return '';
    }
  }

  bool _flag(String key) {
    try {
      return settings.flag(key);
    } on Object {
      return true;
    }
  }

  /// Board and pieces: saved, and the board shows it at once.
  void setLook(Map<String, Object?> values) {
    save(values);
    boardStyle = (values['chess_board'] as String?) ?? boardStyle;
    pieceStyle = (values['chess_pieces'] as String?) ?? pieceStyle;
    coordinates = (values['chess_coordinates'] as bool?) ?? coordinates;
    _changed();
  }

  void save(Map<String, Object?> values) {
    try {
      settings.update(values);
    } on Object {
      // not remembered: the next start uses the defaults
    }
  }

  void _changed() {
    if (!_gone) notifyListeners();
  }

  @override
  void dispose() {
    if (_gone) return;
    _gone = true;
    Work.unwatch(this);
    playground?.removeListener(syncAgents);
    _stopAsking();
    _auto?.cancel();
    _import?.cancel();
    super.dispose();
  }

  // --- the agents -----------------------------------------------------------------------------

  /// can_play_chess: installed, set up, askable, and it plays chess.
  List<Agent> get playable => agentsOf().where((a) => a.ready && a.playsChess).toList();
  bool get agentsLoaded => playground?.loaded ?? true;

  Agent? agentNamed(String? command) {
    if (command == null || command.isEmpty) return null;
    for (final a in agentsOf()) {
      if (a.command == command) return a;
    }
    return null;
  }

  String nameOf(String? command) => agentNamed(command)?.name ?? (command ?? '');

  /// chess_fill_rivals: every agent that plays, the opened one first (it may play itself).
  List<Agent> get rivals {
    final all = playable;
    final first = opponent;
    if (first == null) return all;
    return [first, ...all.where((a) => a.command != first.command)];
  }

  void syncAgents() {
    final all = playable;
    // The helper chosen for every Maprisma app (Maprisma Manager → AI) is the opponent until one
    // is chosen here; it changes only before a game has begun.
    final start = agentNamed(playground?.preferred(all.map((a) => a.command))) ?? all.firstOrNull;
    final settled =
        opponentPicked || game.moves.isNotEmpty || game.mode != ChessMode.game || rival != null || _ask != null;
    final here = opponent != null && all.any((a) => a.command == opponent!.command);
    if (here && (settled || start == null || start.command == opponent!.command)) {
      opponent = all.firstWhere((a) => a.command == opponent!.command);
      _changed();
      return;
    }
    if (start != null) {
      open(start);
    } else {
      opponent = null;
      game.agent = '';
      _changed();
    }
  }

  /// The opponent chosen on the tab.
  void pickOpponent(Agent agent) {
    opponentPicked = true;
    open(agent);
  }

  /// open_chess: a game against this agent (the same agent again: the game goes on).
  void open(Agent agent) {
    final same = opponent?.command == agent.command;
    opponent = agent;
    final list = rivals;
    if (rivalPick == null || !list.any((a) => a.command == rivalPick!.command)) {
      rivalPick = list.length > 1 ? list[1] : list.first;
    }
    if (!same || (game.moves.isEmpty && game.mode != ChessMode.define)) {
      choice = 'white';
      newGame('w');
    } else {
      _changed();
    }
  }

  /// chess_title_text: Chess · the agent, or Chess · White's agent – Black's agent.
  String get title {
    if (game.mode == ChessMode.replay && replayTitle.isNotEmpty) return trf("Chess · {0}", [replayTitle]);
    if (opponent == null) return tr("Chess");
    if (rival != null) return trf("Chess · {0} – {1}", [rival!.name, opponent!.name]);
    return trf("Chess · {0}", [opponent!.name]);
  }

  // --- starting -------------------------------------------------------------------------------

  /// chess_start_choice: picking an entry starts it; Start begins the chosen one again. Agent
  /// against agent with two local models asks about GPU memory first.
  Future<void> start(BuildContext? context) async {
    notice = null;
    if (choice == 'agents') {
      final black = opponent;
      if (black == null) return;
      final white = rivalPick ?? black;
      if (playground != null && context != null) {
        final go = await playground!.gpuGuard(context, [
          Contestant.agent(white),
          Contestant.agent(black),
        ], alternating: true);
        if (go == null) return;
      }
      newGame('w', rival: white);
      return;
    }
    if (choice == 'define') {
      _stopAsking();
      _leaveReplay();
      rival = null;
      game.define();
      turnChoice = game.position.turn;
      palette = null;
      _changed();
      return;
    }
    newGame(choice == 'white' ? 'w' : 'b');
  }

  void newGame(String player, {Position? from, Agent? rival}) {
    _stopAsking();
    _leaveReplay();
    this.rival = rival;
    game.agent = opponent?.command ?? '';
    game.reset(position: from, player: player, rival: rival?.command);
    savedId = '';
    palette = null;
    _changed();
    _askAgent();
  }

  // --- the agent's move ------------------------------------------------------------------------

  void _stopAsking() {
    _ask?.cancel();
    _ask = null;
    _clock?.cancel();
    _clock = null;
    _next?.cancel();
    _next = null;
  }

  Duration get thinkingFor => _thinkStart == null ? Duration.zero : DateTime.now().difference(_thinkStart!);

  /// chess_ask_agent: when the agent is to move, chess.ask (the core asks once more itself when
  /// an answer holds no legal move). A reply after a new game or an undo is dropped (revision).
  void _askAgent() {
    if (game.agent.isEmpty) return;
    game
      ..level = thinking
      ..strength = strength
      ..rivalStrength = rivalStrength;
    final command = game.agentFor(game.position.turn);
    final revision = game.beginAgentMove();
    if (revision == null || command == null) return;
    _thinkStart = DateTime.now();
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _changed());
    final call = core('chess.ask', {
      'command': command,
      'start_fen': rules.fen(game.startPosition),
      'moves': [for (final m in game.moves) m.uci()],
      'strength': game.currentStrength,
      'level': game.level,
    });
    _ask = call;
    _changed();
    call.result.then(
      (reply) => _answered(call, revision, reply),
      onError: (Object e) => _answered(call, revision, {
        'error': e is CoreFailure ? e.message : '$e',
        'cancelled': e is CoreFailure && e.cancelled,
      }),
    );
  }

  void _answered(CoreCall call, int revision, Map<String, dynamic> reply) {
    if (_gone || !identical(call, _ask) || revision != game.revision) return; // a new game meanwhile
    _ask = null;
    _clock?.cancel();
    _clock = null;
    if (reply['cancelled'] == true) {
      game.thinking = false;
      _changed();
      return;
    }
    final played = game.applyAgentMove(
      '${reply['move'] ?? ''}',
      expectedRevision: revision,
      comment: '${reply['comment'] ?? ''}',
      written: '${reply['written'] ?? ''}',
      error: '${reply['error'] ?? ''}',
    );
    if (played) {
      _finished();
      if (game.rival != null) {
        final after = game.revision; // agent against agent: the other one next
        _next = Timer(agentsPause, () {
          if (after == game.revision) _askAgent();
        });
      }
    }
    _changed();
  }

  /// Ask again (after an error).
  void askAgain() => _askAgent();

  void setPaused(bool on) {
    on ? game.pause() : game.resume();
    _changed();
    if (!on) _askAgent();
  }

  // --- your move ------------------------------------------------------------------------------

  void humanMove(Move move) {
    notice = null;
    if (!game.playMove(move)) return;
    _finished();
    _changed();
    _askAgent();
  }

  /// A finished game is kept by itself.
  void _finished() {
    if (game.mode == ChessMode.game && rules.status(game.position) != 'ongoing') saveCurrent(auto: true);
  }

  // --- setting up a position ------------------------------------------------------------------

  void pick(String piece) {
    palette = palette == piece ? null : piece;
    _changed();
  }

  void edit(int square, String piece) {
    if (game.mode != ChessMode.define) return;
    game.setSquare(square, piece);
    notice = null;
    _changed();
  }

  void fill({required bool empty}) {
    empty ? game.clear() : game.resetEditor();
    notice = null;
    _changed();
  }

  void setTurn(String side) {
    turnChoice = side;
    _changed();
  }

  /// chess_play_setup: the position as set up, with castling only where king and rook stand at home.
  void playSetup(String player) {
    game.setSideToMove(turnChoice);
    if (!game.playFromHere(player: player)) {
      notice = game.error;
      game.error = '';
      _changed();
      return;
    }
    notice = null;
    rival = null;
    savedId = '';
    _changed();
    _askAgent();
  }

  // --- status ---------------------------------------------------------------------------------

  String get status {
    if (notice != null) return notice!;
    if (opponent == null && game.mode == ChessMode.game) {
      return agentsLoaded
          ? tr(
              "No agent that plays chess is set up: Claude Code, Codex, Hermes or Pi, signed in or connected to a local LLM.",
            )
          : '';
    }
    if (game.mode == ChessMode.replay) {
      return trf("{0}: move {1} of {2}", [replayTitle, game.moves.length, game.replayLength]);
    }
    return game.status(elapsed: thinkingFor);
  }

  /// "{name} says" above the agent's words.
  String get saidBy => nameOf(game.commentBy.isNotEmpty ? game.commentBy : game.agentFor(game.position.turn));

  // --- replaying ------------------------------------------------------------------------------

  void openReplay(SavedGame saved) {
    final (start, moves) = saved.replay();
    if (start == null || moves.isEmpty) {
      toast(tr("That game cannot be replayed."));
      return;
    }
    _stopAsking();
    setAuto(false);
    rival = null;
    try {
      game.replay(start, moves);
    } on Object {
      toast(tr("That game cannot be replayed."));
      return;
    }
    replayId = saved.id;
    replayTitle = saved.title;
    _changed();
  }

  void seek(int index) {
    if (game.mode != ChessMode.replay) return;
    game.seek(index.clamp(0, game.replayLength));
    _changed();
  }

  /// first, back, next, last
  void step(String how) {
    final i = game.moves.length;
    seek(switch (how) {
      'first' => 0,
      'back' => i - 1,
      'next' => i + 1,
      _ => game.replayLength,
    });
  }

  void setAuto(bool on) {
    _auto?.cancel();
    _auto = null;
    if (on && game.mode == ChessMode.replay) {
      _auto = Timer.periodic(replayStep, (_) {
        if (game.mode != ChessMode.replay || game.moves.length >= game.replayLength) {
          setAuto(false);
          return;
        }
        seek(game.moves.length + 1);
      });
    }
    _changed();
  }

  void _leaveReplay() {
    _auto?.cancel();
    _auto = null;
    replayId = '';
    replayTitle = '';
  }

  /// chess_play_from_here: the game goes on from the move in view; you play the side to move.
  void playFromHere() {
    if (opponent == null) {
      toast(tr("Choose an opponent first."));
      return;
    }
    _leaveReplay();
    rival = null;
    game.agent = opponent!.command;
    if (!game.playFromHere(player: game.position.turn)) {
      toast(game.error);
      game.error = '';
    }
    savedId = '';
    _changed();
  }

  // --- saved games ----------------------------------------------------------------------------

  Future<void> refreshGames() async {
    try {
      final r = await core('games.list', {'offset': 0, 'limit': onCard}).result;
      games = [for (final g in (r['games'] as List? ?? const [])) SavedGame((g as Map).cast<String, dynamic>())];
      gamesTotal = (r['total'] as num?)?.toInt() ?? games.length;
      gamesError = '';
    } on CoreFailure catch (e) {
      games = const [];
      gamesTotal = 0;
      gamesError = e.message;
    } on Object catch (e) {
      gamesError = '$e';
    }
    _changed();
  }

  String _player(String side) => nameOf(game.agentFor(side)).isEmpty ? tr("You") : nameOf(game.agentFor(side));

  String get _result {
    final state = rules.status(game.position);
    if (state == 'checkmate') return game.position.turn == 'w' ? '0-1' : '1-0';
    return const ['stalemate', 'fifty', 'material'].contains(state) ? '1/2-1/2' : '*';
  }

  /// chess_save_current: this game with the saved games; the same entry again when it was saved
  /// before (under its title as it may have been renamed).
  Future<void> saveCurrent({bool auto = false}) async {
    if (game.mode != ChessMode.game || game.moves.isEmpty) return;
    final white = _player('w'), black = _player('b');
    final before = games.where((g) => g.id == savedId && savedId.isNotEmpty).firstOrNull;
    final name = before?.title ?? '$white – $black';
    final record = {
      if (savedId.isNotEmpty) 'id': savedId,
      'title': name,
      'kind': 'played',
      'source': '',
      'start': rules.fen(game.startPosition),
      'moves': [for (final m in game.moves) m.uci()],
      'white': white,
      'black': black,
      'result': _result,
    };
    try {
      final r = await core('games.save', {'game': record}).result;
      savedId = '${r['id'] ?? savedId}';
    } on CoreFailure catch (e) {
      toast(e.message.isEmpty ? tr("The game could not be saved.") : e.message);
      return;
    }
    await refreshGames();
    toast(auto ? trf("Game over: saved as {0}", [name]) : trf("Saved: {0}", [name]));
  }

  // --- reading a video ------------------------------------------------------------------------

  /// chess_import_start: import.start with its progress in the bar at the top of the tab.
  Future<void> importStart({
    String path = '',
    String url = '',
    required String reader,
    required int gap,
    required int limitSeconds,
    required String way,
    String replaceId = '',
  }) async {
    if (_import != null) return;
    final name = path.isNotEmpty ? path.split('/').last.replaceFirst(RegExp(r'\.[^.]*$'), '') : url;
    importTitle = trf("Reading a video: {0}", [name]);
    importText = tr("Starting…");
    importFraction = null;
    importStopping = false;
    toast(tr("Reading the moves from the video; the bar at the top of the chess tab shows how far."));
    final call = core(
      'import.start',
      {
        if (path.isNotEmpty) 'path': path,
        if (url.isNotEmpty) 'url': url,
        'reader': reader,
        'gap': gap,
        'limit': limitSeconds,
        'way': way,
        if (replaceId.isNotEmpty) 'replace_id': replaceId,
      },
      (event, data) {
        if (event != 'progress') return;
        if (!importStopping && data['text'] is String) importText = data['text'] as String;
        if (data['fraction'] is num) importFraction = (data['fraction'] as num).toDouble().clamp(0, 1);
        _changed();
      },
    );
    _import = call;
    _changed();
    try {
      final r = await call.result;
      final raw = r['game'];
      if (raw is Map) {
        final saved = SavedGame(raw.cast<String, dynamic>());
        var note = trf("Saved: {0}, {1}", [saved.title, movesCount(saved.moveTexts.length)]);
        final how = {
          'description': tr("read from the description"),
          'commentary': tr("read from the commentary"),
          'frames': tr("read from the frames"),
        }['${raw['read'] ?? ''}'];
        if (how != null) note += ' · $how';
        toast(note);
        await refreshGames();
        openReplay(saved);
      } else {
        toast(tr("No moves could be read from that video."));
      }
    } on CoreFailure catch (e) {
      if (!e.cancelled) toast(e.message);
    } on Object catch (e) {
      toast('$e');
    } finally {
      _import = null;
      _changed();
    }
  }

  void cancelImport() {
    if (_import == null) return;
    importStopping = true;
    importText = tr("Stopping after this frame…");
    _import!.cancel();
    _changed();
  }
}
