import 'package:flutter/material.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

import 'app.dart';
import 'backend.dart';
import 'contestants.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings(Places.fromEnv());
  setLanguage(resolveLanguage(settings.text('language'))); // the core sets its own the same way
  final backend = await Backend.launch();
  final playground = Playground(backend);
  // The agents set up here and the local LLM servers running: every tab offers them.
  playground.loadAgents();
  playground.scan();
  runApp(PlaygroundApp(settings: settings, playground: playground, args: args));
}
