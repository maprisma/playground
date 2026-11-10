import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'chess_rules.dart' as rules;
import 'private_files.dart';

final youtubePattern = RegExp(
  r'https://(?:(?:www\.|m\.)?youtube\.com/(?:watch\?v=|shorts/|live/)|youtu\.be/)[A-Za-z0-9_-]{6,20}(?:[?&#][A-Za-z0-9_=&%.-]{0,200})?',
);
String youtubeUrl(String text) {
  for (final word in text.split(RegExp(r'\s+')).take(20)) {
    if (word.length <= 300 && youtubePattern.stringMatch(word) == word) return word;
  }
  return '';
}

String videoKey(String source) {
  if (youtubeUrl(source).isNotEmpty) {
    return 'youtube:${RegExp(r'(?:v=|youtu\.be/|/shorts/|/live/)([A-Za-z0-9_-]{6,20})').firstMatch(source)![1]}';
  }
  try {
    return File(source).resolveSymbolicLinksSync();
  } on Object {
    return p.isAbsolute(source) ? p.normalize(source) : source;
  }
}

List<String>? placement(String answer) {
  final joined = answer.replaceAllMapped(RegExp(r'([pnbrqkPNBRQK1-8/])[ \t]+(?=[pnbrqkPNBRQK1-8/])'), (m) => m[1]!);
  final pattern = RegExp(r'(?:[pnbrqkPNBRQK1-8]{1,8}/){7}[pnbrqkPNBRQK1-8]{1,8}');
  for (final word in [...answer.split(RegExp(r'\s+')).take(50), ...joined.split(RegExp(r'\s+')).take(50)]) {
    final m = pattern.firstMatch(word);
    if (m == null) continue;
    try {
      final board = rules.fromFen('${m[0]} w - - 0 1').board;
      if (board.where((s) => s == 'K').length == 1 && board.where((s) => s == 'k').length == 1) return board;
    } on FormatException {
      continue;
    }
  }
  return null;
}

class Reading {
  rules.Position? start, pos;
  final List<rules.Move> moves = [];
  int unmatched = 0;
  bool guessedTurn = false;
}

rules.Position _position(List<String> board, String turn) =>
    rules.fromFen(rules.fen(rules.Position(board, turn, 'KQkq')));
bool follow(Reading reading, List<String> board) {
  const equal = ListEquality<String>();
  if (reading.pos == null) {
    reading.guessedTurn = !equal.equals(board, rules.start().board);
    reading.start = reading.pos = reading.guessedTurn ? _position(board, 'w') : rules.start();
    return true;
  }
  if (equal.equals(board, reading.pos!.board)) return true;
  final tries = [reading.pos!, if (reading.guessedTurn && reading.moves.isEmpty) _position(reading.pos!.board, 'b')];
  bool played(rules.Position pos, List<rules.Move> moves) {
    if (reading.moves.isEmpty) reading.start = pos;
    for (final move in moves) {
      reading.moves.add(move);
      pos = rules.apply(pos, move);
    }
    reading.pos = pos;
    return true;
  }

  for (final pos in tries) {
    final moves = rules.legalMoves(pos);
    for (final move in moves) {
      if (equal.equals(rules.apply(pos, move).board, board)) return played(pos, [move]);
    }
    for (final move in moves) {
      final after = rules.apply(pos, move);
      for (final reply in rules.legalMoves(after)) {
        if (equal.equals(rules.apply(after, reply).board, board)) return played(pos, [move, reply]);
      }
    }
  }
  reading.unmatched++;
  return false;
}

bool changed(List<int> a, List<int> b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) return true;
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() >= 30 && ++n >= 3) return true;
  }
  return false;
}

const maxDescriptionLength = 20000;
const maxDescriptionStarts = 8;
const maxDescriptionMoves = 256;

List<rules.Move> movesInText(String text) {
  text = text.substring(0, min(text.length, maxDescriptionLength));
  text = text.replaceAll(RegExp(r'\{[^}]*\}|\[[^\]]*\]'), ' ');
  final tokens = text.split(RegExp(r'\s+'));
  final starts = <int>[];
  final start = RegExp(r'(?<!\d)1\.(?!\.)');
  final number = RegExp(r'^\d+\.(\.\.)?');
  final punctuation = RegExp(r'^[,;()]+|[,;()]+$');
  for (var i = 0; i < tokens.length; i++) {
    final match = start.firstMatch(tokens[i]);
    if (match != null && starts.length < maxDescriptionStarts) {
      tokens[i] = tokens[i].substring(match.start);
      starts.add(i);
    }
    tokens[i] = tokens[i].replaceFirst(number, '').replaceAll(punctuation, '');
  }
  var best = <rules.Move>[];
  for (final index in starts) {
    var pos = rules.start();
    final moves = <rules.Move>[];
    for (var i = index; i < tokens.length && moves.length < maxDescriptionMoves; i++) {
      final token = tokens[i];
      if (token.isEmpty) continue;
      if (['1-0', '0-1', '1/2-1/2', '½-½', '*'].contains(token)) break;
      final move = rules.parse(pos, token);
      if (move == null) break;
      moves.add(move);
      pos = rules.apply(pos, move);
    }
    if (moves.length > best.length) best = moves;
  }
  return best;
}

String _id() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String cleanTitle(String value) {
  final text = value.trim().split(RegExp(r'\s+')).join(' ');
  return text.substring(0, text.length.clamp(0, 200));
}

String sourceValue(Object? source) => source is Map
    ? '${source['value'] ?? ''}'
    : source is String
    ? source
    : '';

String _gameDate(Object? value) {
  final date = DateTime.tryParse('$value') ?? DateTime.now();
  return date.toIso8601String().replaceFirst('T', ' ').substring(0, 16);
}

class GamesStore {
  GamesStore(this.path);
  final String path;
  List<Map<String, dynamic>> load() {
    try {
      final data = jsonDecode(readRegularNoFollow(path, maxBytes: 4 * 1024 * 1024));
      if (data is! List) return [];
      return [
        for (final g in data)
          if (g is Map &&
              (g['name'] ?? g['title']) is String &&
              (g['start_fen'] ?? g['start']) is String &&
              g['moves'] is List &&
              (g['moves'] as List).every((m) => m is String))
            normalize(g.cast<String, dynamic>()),
      ].take(200).toList();
    } on Object {
      return [];
    }
  }

  Map<String, dynamic> normalize(Map<String, dynamic> g) {
    final source = sourceValue(g['source']);
    return {
      ...g,
      'id': g['id'] is String && (g['id'] as String).isNotEmpty ? g['id'] : _id(),
      'name': cleanTitle('${g['title'] ?? g['name'] ?? ''}'),
      'title': cleanTitle('${g['title'] ?? g['name'] ?? ''}'),
      'source': source,
      'kind': g['kind'] == 'video' || source.isNotEmpty ? 'video' : 'played',
      'result': ['1-0', '0-1', '1/2-1/2', '*'].contains(g['result']) ? g['result'] : '*',
      'start': g['start'] ?? g['start_fen'] ?? rules.startFen,
      'date': _gameDate(g['date'] ?? g['created']),
      'white': '${g['white'] ?? '?'}',
      'black': '${g['black'] ?? '?'}',
      'start_fen': g['start'] ?? g['start_fen'] ?? rules.startFen,
      'moves': g['moves'] ?? <String>[],
      'created': g['created'] ?? g['date'] ?? DateTime.now().toIso8601String(),
    };
  }

  void write(List<Map<String, dynamic>> games) {
    final text = jsonEncode(games.take(200).toList());
    if (utf8.encode(text).length > 4 * 1024 * 1024) throw ArgumentError('The game could not be saved.');
    atomicPrivateWrite(path, text);
  }

  Map<String, dynamic> save(Map<String, dynamic> raw, {String? replaceId, bool deduplicate = false}) {
    final game = normalize(raw), games = load();
    final start = rules.fromFen(game['start_fen']);
    var pos = start;
    if (game['moves'] is! List || (game['moves'] as List).length > 2000) throw ArgumentError('Too many moves.');
    for (final uci in game['moves']) {
      if (uci is! String) throw ArgumentError('Illegal chess move.');
      final move = rules.parse(pos, uci);
      if (move == null || move.uci() != uci) throw ArgumentError('Illegal chess move.');
      pos = rules.apply(pos, move);
    }
    final source = sourceValue(game['source']);
    final same = games.firstWhereOrNull(
      (g) => source.isNotEmpty && videoKey(sourceValue(g['source'])) == videoKey(source),
    );
    if (replaceId != null && replaceId.isNotEmpty) {
      game['id'] = replaceId;
    } else if (!raw.containsKey('id') && same != null) {
      game['id'] = same['id'];
    }
    if (deduplicate) {
      final twin = games.firstWhereOrNull(
        (g) =>
            g['id'] != game['id'] &&
            g['start_fen'] == game['start_fen'] &&
            const ListEquality().equals(g['moves'], game['moves']),
      );
      if (twin != null) return {...twin, 'duplicate': true, 'duplicate_of': twin['id']};
    }
    final index = games.indexWhere((g) => g['id'] == game['id']);
    if (index >= 0) {
      games[index] = game;
      write(games);
    } else {
      write([game, ...games]);
    }
    return game;
  }

  Map<String, dynamic> list({String query = '', int offset = 0, int limit = 20}) {
    final words = query.toLowerCase().split(RegExp(r'\s+'));
    final games = load().where((g) => words.every((w) => '${g['name']}'.toLowerCase().contains(w))).toList();
    return {'games': games.skip(offset.clamp(0, 200)).take(limit.clamp(0, 200)).toList(), 'total': games.length};
  }

  Map<String, dynamic> get(String id) =>
      load().firstWhere((g) => g['id'] == id, orElse: () => throw StateError('Game not found.'));
  void rename(String id, String name) {
    final title = cleanTitle(name);
    write([
      for (final g in load())
        if (g['id'] == id && title.isNotEmpty) {...g, 'name': title, 'title': title} else g,
    ]);
  }

  void delete(String id) => write(load().where((g) => g['id'] != id).toList());
  void export(String id, String target) => atomicPrivateWrite(target, gamePgn(get(id)));
}

String gamePgn(Map<String, dynamic> game) {
  final start = rules.fromFen(game['start_fen']);
  var pos = start;
  final moves = <rules.Move>[];
  for (final text in (game['moves'] as List).take(2000)) {
    final move = rules.parse(pos, text);
    if (move == null) break;
    moves.add(move);
    pos = rules.apply(pos, move);
  }
  final result = ['1-0', '0-1', '1/2-1/2', '*'].contains(game['result']) ? game['result'] : '*';
  String tag(String key, Object? value) =>
      '[$key "${'$value'.replaceAll('\\', '').replaceAll('"', "'").replaceAll(RegExp(r'[\r\n]'), ' ')}"]';
  final date = '${game['created'] ?? ''}';
  final tags = [
    tag('Event', game['name']),
    tag('Site', sourceValue(game['source']).isEmpty ? '?' : sourceValue(game['source'])),
    tag('Date', date.length >= 10 ? date.substring(0, 10).replaceAll('-', '.') : '????.??.??'),
    tag('White', game['white'] ?? '?'),
    tag('Black', game['black'] ?? '?'),
    tag('Result', result),
    tag('Annotator', 'AI Playground'),
    if (rules.fen(start) != rules.startFen) ...[tag('SetUp', '1'), tag('FEN', rules.fen(start))],
  ];
  final lines = <String>[];
  var line = '';
  for (final word in '${rules.gameSan(start, moves)} $result'.trim().split(' ')) {
    if (line.length + word.length + 1 > 80) {
      lines.add(line);
      line = word;
    } else {
      line = '$line $word'.trim();
    }
  }
  lines.add(line);
  return '${tags.join('\n')}\n\n${lines.join('\n')}\n';
}
