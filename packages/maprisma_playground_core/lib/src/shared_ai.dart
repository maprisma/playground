/// The AI helper chosen for every Maprisma app (Maprisma Settings → AI):
/// `${XDG_CONFIG_HOME:-$HOME/.config}/maprisma-ai/settings.json`, a JSON object whose `helper` is
/// `"auto"` or a helper id. A missing or broken file or value is "auto" (Maprisma Playground had
/// no own choice of one helper, so there is nothing to carry over).
///
/// "auto" is the first ready agent in the catalog's order; a chosen helper that is not installed
/// or set up falls back to it. Maprisma Playground compares agents and only reads the choice: a
/// tab that tests one agent (Analyze, the chess opponent, the video reader) starts with it.
library;

import 'dart:convert';

import 'private_files.dart';

const sharedHelperAuto = 'auto';
final _helperId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,160}$');

/// A helper id the shared file may hold (not "auto").
bool validSharedHelperId(Object? v) => v is String && v != sharedHelperAuto && _helperId.hasMatch(v);

/// The shared choice in [path]: "auto" or a helper id (read bounded, never through a link, only
/// the account's own file).
String readSharedHelper(String path) {
  try {
    final data = jsonDecode(readRegularNoFollow(path, maxBytes: 64 * 1024, requireOwner: true));
    final v = data is Map ? data['helper'] : null;
    return validSharedHelperId(v) ? v as String : sharedHelperAuto;
  } on Object {
    return sharedHelperAuto;
  }
}

/// The agent command a helper id names: Maprisma's helper ids are the agents' commands; a model
/// of one (`pi:<provider>/<model>`, as Maprisma Theme lists them) names that agent.
String sharedHelperCommand(String id) {
  final colon = id.indexOf(':');
  return colon > 0 ? id.substring(0, colon) : id;
}

/// The agent to start with: [choice]'s agent when it is among [ready] (commands in the catalog's
/// order), else the first ready one (auto); null when none is ready.
String? resolveSharedHelper(String choice, List<String> ready) {
  if (choice != sharedHelperAuto) {
    final command = sharedHelperCommand(choice);
    if (ready.contains(command)) return command;
  }
  return ready.firstOrNull;
}
