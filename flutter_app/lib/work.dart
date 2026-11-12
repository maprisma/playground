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
