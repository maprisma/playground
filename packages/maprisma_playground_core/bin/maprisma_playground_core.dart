import 'dart:convert';
import 'dart:io';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

Future<void> main(List<String> args) async {
  // Events (progress, Analyze findings) go out as their own lines before the reply.
  final service = CoreService(Platform.environment, onEvent: stdout.writeln);
  final signals = [
    ProcessSignal.sigint.watch().listen((_) => service.dispose()),
    ProcessSignal.sigterm.watch().listen((_) => service.dispose()),
  ];
  try {
    String method;
    Map<String, Object?> params = {};
    switch (args.firstOrNull) {
      case 'agents':
        method = 'agents.list';
      case 'servers':
        method = 'local.servers';
      case 'ask':
        if (args.length < 3) {
          throw const FormatException('ask <command> <prompt>');
        }
        method = 'ask.run';
        params = {
          'target': {'kind': 'agent', 'command': args[1]},
          'prompt': args.sublist(2).join(' '),
        };
      case 'call':
        if (args.length != 3) {
          throw const FormatException('call <method> <json>');
        }
        method = args[1];
        final value = jsonDecode(args[2]);
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Expected a JSON object.');
        }
        params = value;
      default:
        throw const FormatException('Usage: agents | servers | ask <command> <prompt> | call <method> <json>');
    }
    final reply = await service.handleAsync(jsonEncode({'protocol': 1, 'id': 1, 'method': method, 'params': params}));
    stdout.writeln(reply);
    if ((jsonDecode(reply) as Map).containsKey('error')) exitCode = 1;
  } on Object catch (e) {
    stderr.writeln(e);
    exitCode = 2;
  } finally {
    await service.dispose();
    for (final sub in signals) {
      await sub.cancel();
    }
  }
}
