import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Which desktop this is (XDG_CURRENT_DESKTOP).
enum DesktopId { cosmic, kde, hyprland, other }

/// From XDG_CURRENT_DESKTOP; without it (a service or launcher with a short environment) the
/// session's other marks count: XDG_SESSION_DESKTOP, DESKTOP_SESSION, then
/// a live Hyprland ([hyprlandSocketLive]) and KDE_FULL_SESSION (as Maprisma Settings' detectDesktop).
DesktopId detectDesktop([Map<String, String>? env]) {
  final e = env ?? Platform.environment;
  DesktopId? named(String? v) {
    final names = (v ?? '').toUpperCase().split(RegExp(r'[:/]'));
    if (names.contains('COSMIC')) return DesktopId.cosmic;
    if (names.contains('KDE') || names.contains('PLASMA') || names.contains('PLASMAWAYLAND') || names.contains('PLASMAX11')) return DesktopId.kde;
    if (names.contains('HYPRLAND')) return DesktopId.hyprland;
    return null;
  }

  final current = e['XDG_CURRENT_DESKTOP'] ?? '';
  if (current.trim().isNotEmpty) return named(current) ?? DesktopId.other;
  return named(e['XDG_SESSION_DESKTOP']) ??
      named(e['DESKTOP_SESSION']) ??
      (hyprlandSocketLive(e)
          ? DesktopId.hyprland
          : e['KDE_FULL_SESSION'] == 'true'
              ? DesktopId.kde
              : DesktopId.other);
}

/// HYPRLAND_INSTANCE_SIGNATURE names a Hyprland whose socket is there
/// (`$XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock`). The variable alone proves nothing: after a
/// Hyprland session it stays in the systemd user environment, so COSMIC and KDE apps see it too.
bool hyprlandSocketLive(Map<String, String> env) {
  final signature = env['HYPRLAND_INSTANCE_SIGNATURE'] ?? '', runtime = env['XDG_RUNTIME_DIR'] ?? '';
  if (signature.isEmpty || signature.contains('/') || signature.startsWith('.') || !runtime.startsWith('/')) return false;
  return FileSystemEntity.typeSync(p.join(runtime, 'hypr', signature, '.socket.sock')) != FileSystemEntityType.notFound;
}

/// Where the desktop's settings are (tests point it at a folder of their own).
final class LookPaths {
  LookPaths({required this.config, this.root = '/', String? state})
      : state = state ?? p.join(p.dirname(config), '.local', 'state');
  factory LookPaths.fromEnv([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final home = e['HOME'] ?? '/';
    return LookPaths(
      config: e['XDG_CONFIG_HOME'] ?? p.join(home, '.config'),
      state: e['XDG_STATE_HOME'] ?? p.join(home, '.local', 'state'),
    );
  }
  final String config, root;

  /// XDG_STATE_HOME (Maprisma Shell keeps its colour scheme there).
  final String state;
}

final class _Ctx {
  _Ctx(this.desktop, this.paths);
  final DesktopId desktop;
  final LookPaths paths;
}

/// The desktop's palette and window corners, as Maprisma Launcher and Manager read them
/// (copied from maprisma_manager_core desktop_look.dart), so the Playground looks like them.
/// `{desktop, colors: {accent, background, foreground, muted, selection, red, yellow, orange, green}, rounding, is_dark}`.
/// On Hyprland the windows' rounding comes from `hyprctl` (a process): [hyprRounding] passes it
/// in (see [readDesktopLook], which asks [HyprRounding] for it); without it it is null.
Map<String, dynamic> desktopLook({DesktopId? desktop, LookPaths? paths, int? hyprRounding}) =>
    _look(_Ctx(desktop ?? detectDesktop(), paths ?? LookPaths.fromEnv()), hyprRounding);

/// [desktopLook] with Hyprland's window rounding read from `hyprctl` (through [hypr], by default
/// one shared reader that asks at most every 30 s).
Future<Map<String, dynamic>> readDesktopLook({DesktopId? desktop, LookPaths? paths, HyprRounding? hypr}) async {
  final id = desktop ?? detectDesktop();
  final rounding = id == DesktopId.hyprland ? await (hypr ?? HyprRounding.shared).read() : null;
  return desktopLook(desktop: id, paths: paths, hyprRounding: rounding);
}

/// Runs `hyprctl` with these arguments; its standard output, or null when it failed or took
/// longer than [timeout].
typedef HyprctlRun = Future<String?> Function(List<String> args, Duration timeout);

/// Hyprland's window rounding (`hyprctl -j getoption decoration:rounding` → `.int`, 0–64):
/// asked at most once per [every]; meanwhile the last answer stands. Tests inject [run] (or a
/// PATH with a fake hyprctl in [environment]), never the session's hyprctl.
final class HyprRounding {
  HyprRounding({
    HyprctlRun? run,
    Map<String, String>? environment,
    this.every = const Duration(seconds: 30),
    this.timeout = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _run = run ?? _processRun(environment ?? Platform.environment),
       _clock = clock ?? DateTime.now;

  /// The app's reader (the real hyprctl from PATH).
  static final shared = HyprRounding();

  final HyprctlRun _run;
  final DateTime Function() _clock;
  final Duration every, timeout;
  DateTime? _asked;
  int? _value;
  Future<int?>? _running;

  Future<int?> read() {
    final running = _running;
    if (running != null) return running;
    final asked = _asked;
    if (asked != null && _clock().difference(asked) < every) return Future.value(_value);
    _asked = _clock();
    return _running = () async {
      try {
        final out = await _run(const ['-j', 'getoption', 'decoration:rounding'], timeout);
        final value = out == null ? null : parseHyprRounding(out);
        if (value != null) _value = value; // a failed ask keeps the last answer
        return _value;
      } on Object {
        return _value;
      } finally {
        _running = null;
      }
    }();
  }
}

/// `hyprctl -j getoption decoration:rounding`'s answer as the radius (0–64), or null.
int? parseHyprRounding(String text) {
  try {
    final data = jsonDecode(text);
    final v = data is Map ? data['int'] : null;
    return v is int ? v.clamp(0, 64) : null;
  } on FormatException {
    return null;
  }
}

/// hyprctl from [environment]'s PATH, without a shell; killed after the timeout.
HyprctlRun _processRun(Map<String, String> environment) => (args, timeout) async {
  String? exe;
  for (final dir in (environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    final candidate = p.join(dir, 'hyprctl');
    if (FileSystemEntity.typeSync(candidate) == FileSystemEntityType.file) {
      exe = candidate;
      break;
    }
  }
  if (exe == null) return null;
  final Process process;
  try {
    process = await Process.start(exe, args, environment: environment, includeParentEnvironment: false);
  } on ProcessException {
    return null;
  }
  unawaited(process.stdin.close());
  final out = process.stdout.transform(utf8.decoder).join();
  process.stderr.drain<void>().ignore();
  try {
    final code = await process.exitCode.timeout(timeout);
    final text = await out.timeout(const Duration(seconds: 1));
    return code == 0 ? text : null;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    return null;
  }
};

Map<String, dynamic> _look(_Ctx ctx, int? hyprRounding) {
  final colors = switch (ctx.desktop) {
    DesktopId.cosmic => _cosmicColors(ctx),
    DesktopId.kde => _kdeColors(ctx),
    DesktopId.hyprland => _shellColors(ctx),
    DesktopId.other => <String, String>{},
  };
  final bg = colors['background'];
  return {
    'desktop': ctx.desktop.name,
    'colors': colors,
    'rounding': switch (ctx.desktop) {
      DesktopId.cosmic => _cosmicRounding(ctx),
      DesktopId.kde => 8,
      DesktopId.hyprland => hyprRounding?.clamp(0, 64),
      DesktopId.other => null,
    },
    'is_dark': bg == null ? null : _dark(bg),
  };
}

const _light = {
  'background': '#fafafb', 'foreground': '#323233', 'muted': '#77767b',
  'selection': '#dedddf', 'red': '#e01b24', 'yellow': '#c88800',
  'orange': '#e66100', 'green': '#26a269',
};
const _darkColors = {
  'background': '#222226', 'foreground': '#ffffff', 'muted': '#9a9996',
  'selection': '#3a3a3e', 'red': '#ff7b63', 'yellow': '#f8e45c',
  'orange': '#ffa348', 'green': '#8ff0a4',
};

bool _dark(String hex) {
  final v = int.parse(hex.substring(1), radix: 16);
  final r = (v >> 16) & 255, g = (v >> 8) & 255, b = v & 255;
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 < 0.5;
}

String? _read(String path, int max) {
  try {
    final f = File(path);
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file || f.lengthSync() > max) return null;
    return utf8.decode(f.readAsBytesSync(), allowMalformed: true);
  } on FileSystemException {
    return null;
  }
}

// --- COSMIC ----------------------------------------------------------------------------

/// The user's config, else the system's defaults; in each the newest schema first (COSMIC 1.x
/// keeps its themes in `v2` and leaves `v1` empty or stale; the Mode is still `v1`).
String? _cosmicConfig(_Ctx ctx, String component, String key) {
  for (final base in [p.join(ctx.paths.config, 'cosmic'), p.join(ctx.paths.root, 'usr/share/cosmic')]) {
    for (final version in const ['v2', 'v1']) {
      final text = _read(p.join(base, component, version, key), 256 * 1024);
      if (text != null) return text;
    }
  }
  return null;
}

bool _cosmicDark(_Ctx ctx) => (_cosmicConfig(ctx, 'com.system76.CosmicTheme.Mode', 'is_dark') ?? 'true').trim() != 'false';

/// COSMIC's theme: accent, background (base and on), success/warning/destructive.
Map<String, String> _cosmicColors(_Ctx ctx) {
  final dark = _cosmicDark(ctx);
  final theme = dark ? 'com.system76.CosmicTheme.Dark' : 'com.system76.CosmicTheme.Light';
  String? container(String key, String field) {
    final text = _cosmicConfig(ctx, theme, key);
    return text == null ? null : ronColor(ronField(text, field));
  }

  final accent = container('accent', 'base') ?? ronColor(_cosmicConfig(ctx, theme, 'accent'));
  return {
    ...(dark ? _darkColors : _light),
    'accent': accent ?? '#63d0df',
    'background': ?container('background', 'base'),
    'foreground': ?container('background', 'on'),
    'green': ?container('success', 'base'),
    'yellow': ?container('warning', 'base'),
    'red': ?container('destructive', 'base'),
  };
}

int _cosmicRounding(_Ctx ctx) {
  final theme = _cosmicDark(ctx) ? 'com.system76.CosmicTheme.Dark' : 'com.system76.CosmicTheme.Light';
  final radii = _cosmicConfig(ctx, theme, 'corner_radii');
  final small = radii == null ? null : ronField(radii, 'radius_s');
  final first = small == null ? null : RegExp(r'([0-9.]+)').firstMatch(small)?[1];
  return first == null ? 8 : double.tryParse(first)?.round() ?? 8;
}

/// The value after `key:` at the first nesting level of a RON struct, or null.
String? ronField(String text, String key) {
  var depth = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '(' || c == '[') {
      depth++;
    } else if (c == ')' || c == ']') {
      depth--;
    } else if (depth == 1 && text.startsWith(key, i) && (i == 0 || !RegExp(r'[\w]').hasMatch(text[i - 1]))) {
      var j = i + key.length;
      while (j < text.length && text[j] == ' ') {
        j++;
      }
      if (j >= text.length || text[j] != ':') continue;
      j++;
      final start = j;
      var d = 0;
      for (; j < text.length; j++) {
        final cj = text[j];
        if (cj == '(' || cj == '[') d++;
        if (cj == ')' || cj == ']') {
          if (d == 0) break;
          d--;
        }
        if (cj == ',' && d == 0) break;
      }
      return text.substring(start, j).trim();
    }
  }
  return null;
}

/// A RON colour `(red: 0.1, green: …, blue: …)` (schema v1) or `"#RRGGBBAA"` (v2) as #rrggbb, or
/// null.
String? ronColor(String? value) {
  if (value == null) return null;
  // COSMIC 1.x (schema v2) writes colours as "#RRGGBBAA" strings.
  final hexString = RegExp(r'^"?#([0-9a-fA-F]{6})(?:[0-9a-fA-F]{2})?"?$').firstMatch(value.trim());
  if (hexString != null) return '#${hexString[1]!.toLowerCase()}';
  int? part(String name) {
    final m = RegExp('$name:\\s*([0-9.eE+-]+)').firstMatch(value);
    final v = m == null ? null : double.tryParse(m[1]!);
    return v == null ? null : (v.clamp(0, 1) * 255).round();
  }

  final r = part('red'), g = part('green'), b = part('blue');
  if (r == null || g == null || b == null) return null;
  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${hex(r)}${hex(g)}${hex(b)}';
}

// --- Hyprland with Maprisma Shell -----------------------------------------------------------

/// Maprisma Shell's colour scheme (XDG_STATE_HOME/maprisma-shell/scheme.json, written by
/// Maprisma Theme; Material names, hex without '#'); empty without it, so the app keeps its
/// own colours.
Map<String, String> _shellColors(_Ctx ctx) {
  final text = _read(p.join(ctx.paths.state, 'maprisma-shell', 'scheme.json'), 256 * 1024);
  if (text == null) return {};
  Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    return {};
  }
  final colours = data is Map ? data['colours'] : null;
  if (colours is! Map) return {};
  String? c(String key) {
    final v = colours[key];
    return v is String && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(v) ? '#${v.toLowerCase()}' : null;
  }

  final out = {
    'accent': c('primary'),
    'background': c('surface') ?? c('background'),
    'foreground': c('onSurface'),
    'muted': c('outline'),
    'selection': c('surfaceContainerHighest'),
    'red': c('error') ?? c('red'),
    'yellow': c('yellow'),
    'orange': c('peach'),
    'green': c('green'),
  };
  return {for (final e in out.entries) if (e.value != null) e.key: e.value!};
}

// --- KDE ---------------------------------------------------------------------------------

String? _kdeIni(String text, String group, String key) {
  String? current, found;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      current = line.substring(1, line.length - 1);
    } else if (current == group) {
      final eq = line.indexOf('=');
      if (eq > 0 && line.substring(0, eq).trim() == key) found = line.substring(eq + 1).trim();
    }
  }
  return found;
}

String? _kdeColor(String? value) {
  if (value == null) return null;
  final parts = value.split(',').map((v) => int.tryParse(v.trim())).toList();
  if ((parts.length != 3 && parts.length != 4) || parts.any((v) => v == null || v < 0 || v > 255)) return null;
  String hex(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${hex(parts[0]!)}${hex(parts[1]!)}${hex(parts[2]!)}';
}

/// Plasma's colour scheme from kdeglobals (as the Launcher reads it).
Map<String, String> _kdeColors(_Ctx ctx) {
  final text = _read(p.join(ctx.paths.config, 'kdeglobals'), 1024 * 1024) ?? '';
  String? c(String group, String key) => _kdeColor(_kdeIni(text, group, key));
  final bg = c('Colors:Window', 'BackgroundNormal');
  return {
    ...(bg == null || _dark(bg) ? _darkColors : _light),
    'accent': c('General', 'AccentColor') ?? c('Colors:View', 'DecorationFocus') ?? c('Colors:Selection', 'BackgroundNormal') ?? '#3daee9',
    'background': ?bg,
    'foreground': ?c('Colors:Window', 'ForegroundNormal'),
    'selection': ?c('Colors:Selection', 'BackgroundNormal'),
    'muted': ?c('Colors:Window', 'ForegroundInactive'),
    'red': ?c('Colors:View', 'ForegroundNegative'),
    'yellow': ?c('Colors:View', 'ForegroundNeutral'),
    'green': ?c('Colors:View', 'ForegroundPositive'),
  };
}
