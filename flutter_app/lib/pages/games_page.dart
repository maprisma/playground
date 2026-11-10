import 'package:maprisma_playground_core/maprisma_playground_core.dart' show tr, trf;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../backend.dart';
import '../theme.dart';
import '../widgets.dart';
import 'chess_page.dart';
import 'page_head.dart';

const _searchFrom = 6; // games from which on a search field shows
const _newest = 10; // games shown before Show all

/// build_games_page: every saved game, newest first, a search from six games on, and per game
/// Replay, Rename…, Save as PGN… and Delete (chess_import.chess_fill_page).
class GamesPage extends StatefulWidget {
  const GamesPage({super.key, required this.host, required this.session, required this.onBack});
  final Host host;
  final ChessSession session;
  final VoidCallback onBack;
  @override
  State<GamesPage> createState() => _GamesPageState();
}

class _GamesPageState extends State<GamesPage> {
  final _search = TextEditingController();
  List<SavedGame> _games = const [];
  int _total = 0, _everything = 0, _run = 0;
  bool _all = false, _loaded = false;
  String _error = '';

  ChessSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final run = ++_run;
    final query = _search.text.trim();
    try {
      final r = await s.core('games.list', {
        if (query.isNotEmpty) 'query': query,
        'offset': 0,
        'limit': _all || query.isNotEmpty ? 1000 : _newest,
      }).result;
      if (!mounted || run != _run) return;
      setState(() {
        _games = [for (final g in (r['games'] as List? ?? const [])) SavedGame((g as Map).cast<String, dynamic>())];
        _total = (r['total'] as num?)?.toInt() ?? _games.length;
        if (query.isEmpty) _everything = _total;
        _error = '';
        _loaded = true;
      });
    } on CoreFailure catch (e) {
      if (!mounted || run != _run) return;
      setState(() {
        _games = const [];
        _error = e.message;
        _loaded = true;
      });
    }
  }

  Future<void> _changedGames() async {
    await _load();
    await s.refreshGames();
  }

  Future<void> _call(String method, Map<String, dynamic> params) async {
    try {
      await s.core(method, params).result;
    } on CoreFailure catch (e) {
      widget.host.toast(e.message);
      return;
    }
    await _changedGames();
  }

  Future<void> _rename(SavedGame g) async {
    final field = TextEditingController(text: g.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr("Rename the game"), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: field,
            autofocus: true,
            maxLength: 200,
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          SmallButton(tr("Cancel"), onPressed: () => Navigator.pop(context)),
          ActionButton(tr("Rename"), onPressed: () => Navigator.pop(context, field.text)),
        ],
      ),
    );
    field.dispose();
    if (name == null || name.trim().isEmpty) return;
    await _call('games.rename', {'id': g.id, 'name': name.trim()});
  }

  Future<void> _delete(SavedGame g) async {
    final look = Look.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr("Delete this game?"), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: AnswerText(g.title),
        actions: [
          SmallButton(tr("Cancel"), onPressed: () => Navigator.pop(context)),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, true),
            style: OutlinedButton.styleFrom(
              foregroundColor: look.red,
              side: BorderSide(color: look.red),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
            ),
            child: Text(tr("Delete"), style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (yes == true) await _call('games.delete', {'id': g.id});
  }

  /// chess_save_pgn: a .pgn file where you choose.
  Future<void> _pgn(SavedGame g) async {
    final safe = g.title
        .split('')
        .map((c) => RegExp(r'[A-Za-z0-9 _-]').hasMatch(c) ? c : ' ')
        .join()
        .trim()
        .split(RegExp(r'\s+'))
        .join(' ');
    final name = '${safe.isEmpty ? 'game' : (safe.length > 80 ? safe.substring(0, 80) : safe)}.pgn';
    final where = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PGN', extensions: ['pgn']),
      ],
    );
    if (where == null) return;
    try {
      await s.core('games.pgn', {'id': g.id, 'path': where.path}).result;
      widget.host.toast(trf("Saved: {0}", [where.path.split('/').last]));
    } on CoreFailure catch (e) {
      widget.host.toast(e.message);
    }
  }

  void _replay(SavedGame g) {
    s.openReplay(g);
    widget.host.show('chess');
  }

  Widget _card(SavedGame g) {
    final count = movesCount(g.moveTexts.length);
    final result = g.result != '*' && g.result.isNotEmpty ? ' · ${g.result}' : '';
    final summary = count + result + (g.date.isNotEmpty ? ' · ${g.date}' : '');
    final moves = g.movesText;
    return Padding(
      padding: const EdgeInsets.only(bottom: gap),
      child: FoldCard(
        key: ValueKey('game-${g.id}'),
        title: g.title,
        icon: g.kind == 'played' ? Icons.sports_esports : Icons.movie_outlined,
        summary: summary,
        initiallyOpen: g.id == s.replayId,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              summary + (g.source.isNotEmpty ? ' · ${g.source}' : ''),
              style: TextStyle(fontSize: 13, color: Look.of(context).muted),
            ),
            if (moves.isNotEmpty) ...[const SizedBox(height: gap), AnswerText(moves)],
            const SizedBox(height: gap),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (g.source.isNotEmpty) OriginalButton(game: g, toast: widget.host.toast),
                IconSmallButton(
                  Icons.play_arrow,
                  tooltip: tr("Replay game: on the board, with the controls beneath it"),
                  onPressed: () => _replay(g),
                ),
                SmallButton(tr("Rename…"), onPressed: () => _rename(g)),
                SmallButton(
                  tr("Save as PGN…"),
                  tooltip: tr("PGN: the chess programs' format (Lichess, ChessBase, Scid…)"),
                  onPressed: () => _pgn(g),
                ),
                IconSmallButton(Icons.delete_outline, tooltip: tr("Delete this game"), onPressed: () => _delete(g)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim();
    final none = tr("None yet. Drop a chess video or a YouTube link on this tab, or use Import video…");
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHead(title: tr("Saved games"), onBack: widget.onBack),
        Expanded(
          child: PageScroll(
            children: [
              Hint(
                tr(
                  "Your saved games and the ones read from chess videos, newest first. The play symbol puts one on the board; Save as PGN gives it to other chess programs.",
                ),
              ),
              vgap,
              if (_everything >= _searchFrom || query.isNotEmpty) ...[
                TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: tr("Search saved games"),
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                  onChanged: (_) => _load(),
                ),
                vgap,
              ],
              if (_error.isNotEmpty) ...[Hint(_error, error: true), vgap],
              if (_loaded && _games.isEmpty && query.isEmpty) Hint(none),
              if (_loaded && _games.isEmpty && query.isNotEmpty) Hint(tr("No saved game has that in its title.")),
              for (final g in _games) _card(g),
              if (!_all && query.isEmpty && _total > _games.length)
                SmallButton(
                  _total == 1 ? tr("Show all 1 game") : trf("Show all {0} games", [_total]),
                  onPressed: () {
                    _all = true;
                    _load();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
