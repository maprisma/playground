import 'i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'private_files.dart';

import 'package:path/path.dart' as p;

/// Maprisma Playground's own folders.
final class Places {
  Places({required this.config, required this.data, required this.cache});

  factory Places.fromEnv([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final home = e['HOME'] ?? '/';
    String xdg(String key, String fallback) {
      final v = e[key];
      return v != null && p.isAbsolute(v) ? v : p.join(home, fallback);
    }

    return Places(
      config: p.join(xdg('XDG_CONFIG_HOME', '.config'), 'maprisma-playground'),
      data: p.join(xdg('XDG_DATA_HOME', '.local/share'), 'maprisma-playground'),
      cache: p.join(xdg('XDG_CACHE_HOME', '.cache'), 'maprisma-playground'),
    );
  }

  /// settings.json, games.json (0600, folder 0700).
  final String config;

  /// The picture program and model (Generate).
  final String data;

  /// Scratch space that may go any time.
  final String cache;

  String get settingsFile => p.join(config, 'settings.json');
  String get gamesFile => p.join(config, 'games.json');
}

/// One declared setting: its default and the shape a stored value must have.
final class Setting {
  const Setting(this.fallback, this.valid, this.about);
  final Object? fallback;
  final bool Function(Object?) valid;
  final String about;
}

bool _text(Object? v) => v is String;
bool _bool(Object? v) => v is bool;
bool _texts(Object? v) => v is List && v.every((x) => x is String);
bool _map(Object? v) => v is Map;
bool _size(Object? v) => v is List && v.length == 2 && v.every((x) => x is int && x > 0);
bool Function(Object?) _oneOf(List<String> choices) =>
    (v) => choices.contains(v);

const strengths = ['beginner', 'casual', 'club', 'master', 'max'];
const thinkingLevels = ['quick', 'normal', 'deep', 'max'];

/// Every key of settings.json (the plugin's settings_schema, the playground's part; no language
/// or look: Maprisma Playground speaks English and follows the desktop's colours).
final Map<String, Setting> schema = {
  'choice_text': Setting('bright', _oneOf(['bright', 'dim']), 'Settings › Text in choice boxes'),
  'language': Setting('auto', _text, 'Settings › Language: "auto" (the system\'s) or a language code'),
  'corners': Setting(
    'windows',
    _oneOf(['windows', 'rounded', 'square']),
    "Settings › Corners: the desktop's, rounded or square",
  ),
  'window_size': Setting(null, _size, "the window's size when it was last closed: [width, height]"),
  'automaton_rule': Setting('B3/S23', _text, 'Automaton › Rule'),
  'automaton_speed': Setting(10, (v) => v is int && v >= 1 && v <= 60, 'Automaton › Speed (generations per second)'),
  'automaton_colors': Setting('age', _oneOf(['age', 'plain']), 'Automaton › Colours: by age or one colour'),
  'automaton_wrap': Setting(true, _bool, 'Automaton › Edges wrap'),
  'automaton_cell': Setting(10, (v) => v is int && v >= 4 && v <= 24, 'Automaton › Cell size'),
  'playground_tab': Setting('chess', _text, 'the tab open when the window was last closed'),
  'playground_agents': Setting(<String>[], _texts, 'Speed and cost: the agents ticked'),
  'duel_scores': Setting(<String, Object?>{}, _map, 'Head to head: {"a|b": [a wins, ties, b wins]}'),
  'chess_thinking': Setting('normal', _oneOf(thinkingLevels), 'Chess › Thinking time'),
  'chess_strength': Setting('club', _oneOf(strengths), 'Chess › Strength'),
  'chess_rival_strength': Setting('club', _oneOf(strengths), "Chess › agent against agent: White's strength"),
  'chess_board': Setting(
    'theme',
    _oneOf(['theme', 'wood', 'green', 'blue', 'grey']),
    'Chess › Board and pieces › Board',
  ),
  'chess_pieces': Setting('classic', _oneOf(['classic', 'flat', 'theme']), 'Chess › Board and pieces › Pieces'),
  'chess_coordinates': Setting(true, _bool, 'Chess › Board and pieces › Coordinates'),
};

const _maxBytes = 1024 * 1024;

/// settings.json: read with a size cap, never through a link; written owner-only and atomically.
final class Settings {
  Settings(this.places);
  final Places places;

  Map<String, Object?> _load() {
    final path = places.settingsFile;
    try {
      requirePrivateFolder(places.config);
      final data = jsonDecode(readRegularNoFollow(path, maxBytes: _maxBytes, requireOwner: true));
      return data is Map ? data.cast<String, Object?>() : {};
    } on Object {
      return {};
    }
  }

  /// The stored value when it has the declared shape, else the default (a fresh copy).
  Object? get(String key) {
    final setting = schema[key];
    if (setting == null) throw ArgumentError(trf("not a declared setting: {0}", [key]));
    final stored = _load()[key];
    if (stored != null && setting.valid(stored)) return stored;
    final d = setting.fallback;
    return d is List
        ? List.of(d)
        : d is Map
        ? Map.of(d)
        : d;
  }

  /// Whether settings.json holds a valid value of its own for this key (not just the default).
  bool stored(String key) {
    final setting = schema[key];
    if (setting == null) throw ArgumentError(trf("not a declared setting: {0}", [key]));
    final v = _load()[key];
    return v != null && setting.valid(v);
  }

  String text(String key) => get(key) as String;
  bool flag(String key) => get(key) as bool;
  List<String> texts(String key) => (get(key) as List).cast<String>();

  /// Write settings (null removes one). Only declared keys.
  void update(Map<String, Object?> values) {
    final unknown = values.keys.where((k) => !schema.containsKey(k)).toList();
    if (unknown.isNotEmpty) throw ArgumentError(trf("not a declared setting: {0}", [unknown.join(', ')]));
    final data = _load();
    values.forEach((k, v) => v == null ? data.remove(k) : data[k] = v);
    writePrivate(places.settingsFile, const JsonEncoder.withIndent('  ').convert(data));
  }
}

/// Write a file only its owner can read (folder 0700), via a temp file moved over it: a link at the
/// path is replaced, never followed.
void writePrivate(String path, String text) {
  atomicPrivateWrite(path, text, privateFolder: true);
}
