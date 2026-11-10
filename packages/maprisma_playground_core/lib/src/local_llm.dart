import 'dart:convert';
import 'dart:io';
import 'agent_run.dart';
import 'netfetch.dart';
import 'runner.dart';
import 'loopback.dart';

const localServers = [
  ('llamacpp', 'llama.cpp', 8080),
  ('ollama', 'Ollama', 11434),
  ('lmstudio', 'LM Studio', 1234),
  ('vllm', 'vLLM', 8000),
  ('jan', 'Jan', 1337),
  ('koboldcpp', 'KoboldCpp', 5001),
];
String serverKey(String runtime) {
  for (final s in localServers) {
    if (runtime == s.$1 || runtime == s.$2) return s.$1;
  }
  return runtime;
}

int portOf(String runtime) {
  for (final s in localServers) {
    if (s.$1 == runtime || s.$2 == runtime) return s.$3;
  }
  return 0;
}

String runtimeOf(int port) {
  for (final s in localServers) {
    if (s.$3 == port) return s.$1;
  }
  return '';
}

List<String> modelIds(Object? data) {
  if (data is! Map || data['data'] is! List) return [];
  return [
        for (final row in data['data'])
          if (row is Map && row['id'] is String) row['id'] as String,
      ]
      .where(
        (s) =>
            s.isNotEmpty &&
            s.length <= 300 &&
            !RegExp(r'[\x00-\x1f\x7f]').hasMatch(s),
      )
      .take(200)
      .toList();
}

Answer chatAnswer(Object? data) {
  if (data is! Map) return Answer(error: 'no answer');
  final choices = data['choices'];
  final message = choices is List && choices.isNotEmpty && choices.first is Map
      ? choices.first['message']
      : null;
  final usage = data['usage'] is Map ? data['usage'] as Map : {};
  int? count(String key) =>
      usage[key] is int && usage[key] >= 0 ? usage[key] as int : null;
  return Answer(
    text: message is Map && message['content'] is String
        ? (message['content'] as String).trim()
        : '',
    tokensIn: count('prompt_tokens'),
    tokensOut: count('completion_tokens'),
  );
}

class LocalLlm {
  LocalLlm(this.http, {List<int> Function(int)? listeners, int? uid})
    : listeners = listeners ?? loopbackListeners,
      uid = uid ?? currentUid();
  final LocalHttp http;
  final List<int> Function(int) listeners;
  final int uid;
  Future<List<Map<String, Object?>>> servers({CancelToken? cancel}) async {
    final found = <Map<String, Object?>>[];
    for (final (key, name, port) in localServers) {
      final owners = listeners(port);
      if (owners.isEmpty || owners.any((v) => v != uid)) continue;
      try {
        found.add({
          'port': port,
          'runtime': key,
          'name': name,
          'models': modelIds(
            await http.json(port, '/v1/models', cancel: cancel),
          ),
        });
      } on Cancelled {
        rethrow;
      } on Object {
        found.add({
          'port': port,
          'runtime': key,
          'name': name,
          'models': <String>[],
        });
      }
    }
    return found;
  }

  Future<Answer> ask(
    int port,
    String model,
    String prompt, {
    Duration timeout = const Duration(seconds: 180),
    CancelToken? cancel,
    List<String> images = const [],
  }) async {
    final clock = Stopwatch()..start();
    try {
      // Vision must be positively identified by LocalHold.seesPictures before this call.
      Object content = prompt;
      if (images.isNotEmpty) {
        if (images.length > 8) return Answer(error: 'Too many pictures.');
        final blocks = <Map<String, Object?>>[
          {'type': 'text', 'text': prompt},
        ];
        for (final path in images) {
          final error = checkImage(path);
          if (error.isNotEmpty) return Answer(error: error);
          final type = imageTypes.entries
              .firstWhere((e) => path.toLowerCase().endsWith(e.key))
              .value;
          blocks.add({
            'type': 'image_url',
            'image_url': {
              'url':
                  'data:$type;base64,${base64Encode(await File(path).readAsBytes())}',
            },
          });
        }
        content = blocks;
      }
      final data = await http.json(
        port,
        '/v1/chat/completions',
        data: {
          'model': model,
          'messages': [
            {'role': 'user', 'content': content},
          ],
          'stream': false,
        },
        timeout: timeout,
        cancel: cancel,
      );
      return chatAnswer(data)..seconds = clock.elapsedMicroseconds / 1e6;
    } on Cancelled {
      rethrow;
    } on Object catch (e) {
      return Answer(
        error: e.toString(),
        seconds: clock.elapsedMicroseconds / 1e6,
      );
    }
  }
}
