import 'package:flutter/material.dart';
import 'package:maprisma_playground_core/src/settings.dart';

import 'app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(PlaygroundApp(settings: Settings(Places.fromEnv()), args: args));
}
