import 'package:flutter/material.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

import 'app.dart';
import 'backend.dart';
import 'contestants.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await Backend.launch();
  final playground = Playground(backend);
  // The agents set up here and the local LLM servers running: every tab offers them.
  playground.loadAgents();
  playground.scan();
  runApp(PlaygroundApp(settings: Settings(Places.fromEnv()), playground: playground, args: args));
}
