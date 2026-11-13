import 'package:flutter/material.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

import 'app.dart';
import 'backend.dart';
import 'contestants.dart';
import 'window.dart';
import 'window_size.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings(Places.fromEnv());
  // Rule 5a: the window opens at the size the user left it (clamped to the screen by the runner).
  try {
    final size = parseWindowSize(settings.get('window_size'));
    if (size != null) AppWindow.instance.resize(size.$1, size.$2);
  } on Object {
    // the default size
  }
  setLanguage(resolveLanguage(settings.text('language'))); // the core sets its own the same way
  final backend = await Backend.launch();
  final playground = Playground(backend, sharedAiFile: settings.places.sharedAiFile);
  // The agents set up here and the local LLM servers running: every tab offers them.
  playground.loadAgents();
  playground.scan();
  // The desktop's colours and corners before the first frame (then again while it runs).
  final look = await readDesktopLook().catchError((_) => <String, dynamic>{});
  runApp(PlaygroundApp(settings: settings, playground: playground, args: args, look: look));
}
