import 'dart:io';

/// What runs right now (layout rule 5a): a game, a generation, an agent, a download, a model
/// load, the automaton. Esc on a tab must never stop it: the window hides then (the tray brings
/// it back); with nothing running Esc closes as the close button does.
abstract final class Work {
  static final _sources = <Object, bool Function()>{};

  /// [owner] reports whether its work runs, until [unwatch].
  static void watch(Object owner, bool Function() running) => _sources[owner] = running;
  static void unwatch(Object owner) => _sources.remove(owner);

  static bool get running => _sources.values.any((running) => running());
}

/// What Esc on a tab with nothing open does to the window.
enum EscWindow { hide, close }

EscWindow escWindow({required bool running}) => running ? EscWindow.hide : EscWindow.close;

/// Where the tray reads whether work runs: `$XDG_RUNTIME_DIR/maprisma-playground/busy`, holding
/// this app's pid while [Work.running] (the tray colours its gamepad then), gone otherwise.
String? busyMarkerPath(Map<String, String> env) {
  final dir = env['XDG_RUNTIME_DIR'] ?? '';
  return dir.isEmpty ? null : '$dir/maprisma-playground/busy';
}

/// Keeps the busy marker in step with [Work.running]; writes only when the state changes.
class BusyMarker {
  BusyMarker(this.path);
  final String? path;
  bool? _written;

  void update(bool running) {
    final path = this.path;
    if (path == null || running == _written) return;
    try {
      final file = File(path);
      if (running) {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('$pid\n');
      } else if (file.existsSync()) {
        file.deleteSync();
      }
      _written = running;
    } on FileSystemException {
      // the tray keeps the plain icon
    }
  }
}
