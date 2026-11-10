import 'i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'agents.dart';
import 'runner.dart';
import 'private_files.dart';

const thinkingSeconds = {'quick': 30, 'normal': 90, 'deep': 180, 'max': 360};
int seconds(String level) => thinkingSeconds[level] ?? 90;
const strengthPrompts = {
  'beginner':
      'like a beginner who has just learned the rules: simple moves, and now and then miss a threat or leave a piece undefended',
  'casual': 'at the level of a casual club player',
  'club': 'strongly, at the level of a good club player',
  'master': 'at master level',
  'max': 'as strongly as you can',
};
const imageTypes = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
};

class Answer {
  Answer({this.text = '', this.seconds = 0, this.tokensIn, this.tokensOut, this.cost, this.error = ''});
  String text, error;
  double seconds;
  num? tokensIn, tokensOut, cost;
  double? get perSecond => tokensOut != null && tokensOut! > 0 && seconds > 0 ? tokensOut! / seconds : null;
  Map<String, Object?> toJson() => {
    'text': text,
    'seconds': seconds,
    if (tokensIn != null) 'tokens_in': tokensIn,
    if (tokensOut != null) 'tokens_out': tokensOut,
    if (cost != null) 'cost': cost,
    if (perSecond != null) 'per_second': perSecond,
    'error': error,
  };
}

List<String> runArgv(String command, String text, {String level = 'normal', List<String>? effort, String model = ''}) {
  final a = adapter(command);
  if (a == null) return [];
  if (model.isNotEmpty && (!modelFlags.containsKey(command) || modelName.stringMatch(model) != model)) {
    return [];
  }
  final options = [
    if (model.isNotEmpty) ...[modelFlags[command]!, model],
    ...effort ?? a.effort(level),
  ];
  final placed = a.argv.contains('{effort}');
  return [
    for (final arg in a.argv)
      if (arg == '{effort}') ...options else if (arg == '{prompt}') ...[if (!placed) ...options, text] else arg,
  ];
}

class BuiltAsk {
  BuiltAsk(this.argv, this.stdin);
  final List<String> argv;
  final List<int>? stdin;
}

BuiltAsk buildAsk(
  String command,
  String prompt, {
  List<String> images = const [],
  String level = 'normal',
  bool think = true,
  String model = '',
}) {
  const marker = '\u0000prompt\u0000';
  final argv = runArgv(
    command,
    marker,
    level: level,
    effort: !think && command == 'pi' ? ['--thinking', 'off'] : null,
    model: model,
  );
  if (argv.isEmpty) return BuiltAsk([], null);
  var at = argv.indexOf(marker);
  if (command == 'claude') {
    if (images.isNotEmpty) {
      final blocks = [
        for (final path in images)
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': imageTypes[p.extension(path).toLowerCase()],
              'data': base64Encode(File(path).readAsBytesSync()),
            },
          },
        {'type': 'text', 'text': prompt},
      ];
      argv.replaceRange(at, at + 1, ['--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose']);
      return BuiltAsk(
        argv,
        utf8.encode(
          '${jsonEncode({
            'type': 'user',
            'message': {'role': 'user', 'content': blocks},
          })}\n',
        ),
      );
    }
    argv.insertAll(at, ['--output-format', 'json']);
    at += 2;
  }
  if (command == 'codex') {
    final opts = [
      for (final path in images) ...['-i', path],
    ];
    argv.insertAll(at, opts);
    at += opts.length;
  }
  if (command == 'pi') {
    argv.insertAll(at, images.map((path) => '@$path'));
    at += images.length;
  }
  if (const ['claude', 'codex', 'pi'].contains(command)) {
    if (command == 'codex') {
      argv[at] = '-';
    } else {
      argv.removeAt(at);
    }
    return BuiltAsk(argv, utf8.encode(prompt));
  }
  argv[at] = prompt;
  return BuiltAsk(argv, null);
}

Answer parseAnswer(String command, String out) {
  if (command != 'claude') return Answer(text: out.trim());
  Map? last;
  for (final line in [out, ...const LineSplitter().convert(out)]) {
    try {
      final v = jsonDecode(line);
      if (v is Map && v['type'] == 'result') last = v;
    } on FormatException {
      /* not result */
    }
  }
  if (last == null) return Answer(text: out.trim());
  final usage = last['usage'] is Map ? last['usage'] as Map : {};
  num? number(Object? v) => v is num ? v : null;
  final text = last['result'] is String ? (last['result'] as String).trim() : '';
  return Answer(
    text: text,
    tokensIn: usage.isEmpty
        ? null
        : [
            'input_tokens',
            'cache_creation_input_tokens',
            'cache_read_input_tokens',
          ].fold<num>(0, (n, k) => n + (number(usage[k]) ?? 0)),
    tokensOut: number(usage['output_tokens']),
    cost: number(last['total_cost_usd']),
    error: last['is_error'] == true && text.isEmpty ? tr("The agent reported an error.") : '',
  );
}

String checkImage(String path) {
  if (!imageTypes.containsKey(p.extension(path).toLowerCase())) {
    return tr("Only PNG, JPEG, WebP or GIF pictures can be sent.");
  }
  try {
    if (!File(path).existsSync() || File(path).lengthSync() > 8 * 1024 * 1024) {
      return tr("The picture is missing or larger than 8 MB.");
    }
  } on FileSystemException {
    return tr("The picture cannot be read.");
  }
  return '';
}

Future<Answer> askAgent(
  ProcessRunner runner,
  String command,
  String prompt, {
  List<String> images = const [],
  String level = 'normal',
  Duration? timeout,
  bool think = true,
  String model = '',
  CancelToken? cancel,
  bool untrusted = false,
  int maxBytes = 512 * 1024,
}) async {
  if (untrusted && !readsUntrusted(command)) {
    return Answer(error: tr("This agent cannot read untrusted input."));
  }
  if (images.isNotEmpty && !takesImages(command)) {
    return Answer(error: tr("This agent cannot be sent pictures."));
  }
  final folder = createPrivateTempDirectory();
  final clock = Stopwatch()..start();
  try {
    final copies = <String>[];
    for (final image in images.take(8)) {
      final problem = checkImage(image);
      if (problem.isNotEmpty) return Answer(error: problem);
      final dest = p.join(folder.path, 'picture-${copies.length + 1}${p.extension(image).toLowerCase()}');
      await File(image).copy(dest);
      copies.add(dest);
    }
    final built = buildAsk(command, prompt, images: copies, level: level, think: think, model: model);
    if (built.argv.isEmpty) return Answer(error: tr("This agent cannot be asked."));
    // Resolve against the supplied PATH, not the host process's PATH.
    final exe = executableOnPath(command, runner.environment);
    if (exe == null) return Answer(error: tr("This agent cannot be asked."));
    built.argv[0] = exe;
    final out = await runner.run(
      built.argv,
      env: {...runner.environment, 'PATH': '${p.dirname(exe)}:${runner.environment['PATH'] ?? ''}'},
      stdin: built.stdin,
      cwd: folder.path,
      maxBytes: maxBytes,
      timeout: timeout ?? Duration(seconds: seconds(level) + 15),
      cancel: cancel,
    );
    final result = parseAnswer(command, out.text)..seconds = clock.elapsedMicroseconds / 1e6;
    if (result.text.isEmpty && result.error.isEmpty) {
      result.error = out.ok
          ? tr("The agent gave an empty answer.")
          : tr("No answer: the agent took too long or stopped.");
    }
    return result;
  } on Cancelled {
    rethrow;
  } on Object catch (e) {
    return Answer(error: e.toString());
  } finally {
    await folder.delete(recursive: true);
  }
}
