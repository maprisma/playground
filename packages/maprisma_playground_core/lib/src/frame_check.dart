import 'dart:async';
import 'package:collection/collection.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import 'agent_run.dart';
import 'agents.dart';
import 'gpu_check.dart';
import 'local_hold.dart';
import 'local_llm.dart';
import 'loopback.dart';
import 'netfetch.dart';
import 'picture_gen.dart';
import 'private_files.dart';
import 'runner.dart';

const probePrompt = 'What colour is the square in this picture? Answer with one English word.';
const providerKeys = {
  'llama-local': 'llamacpp',
  'ollama-local': 'ollama',
  'lmstudio-local': 'lmstudio',
  'vllm-local': 'vllm',
  'jan-local': 'jan',
  'koboldcpp-local': 'koboldcpp',
  'llamacpp': 'llamacpp',
  'llama.cpp': 'llamacpp',
  'ollama': 'ollama',
  'lmstudio': 'lmstudio',
  'vllm': 'vllm',
  'jan': 'jan',
  'koboldcpp': 'koboldcpp',
};
final safeProjectorPath = RegExp(r'^/[\w./+@ -]{1,1000}$');
final repoPattern = RegExp(r'^[A-Za-z0-9][\w.-]{0,95}/[A-Za-z0-9][\w.-]{0,95}$');
String? iniWithMmproj(String text, String section, String path) {
  if (!safeProjectorPath.hasMatch(path)) return null;
  final headers = RegExp(r'^\[([^\]\n]{1,120})\][ \t]*\r?$', multiLine: true).allMatches(text).toList();
  final places = <int>[];
  var found = false;
  for (var i = 0; i < headers.length; i++) {
    final h = headers[i];
    if (h[1]!.trim().toLowerCase() != section.trim().toLowerCase()) continue;
    found = true;
    if (!hasMmproj(text.substring(h.end, i + 1 < headers.length ? headers[i + 1].start : text.length))) {
      places.add(h.end);
    }
  }
  if (!found) return null;
  final nl = text.contains('\r\n') ? '\r\n' : '\n';
  for (final at in places.reversed) {
    final end = text.startsWith('\n', at) ? at + 1 : at;
    text = '${text.substring(0, end)}${end > at ? '' : nl}mmproj = $path$nl${text.substring(end)}';
  }
  return text;
}

bool piEntryFixed(Map<String, dynamic> entry, bool thinkingSwitch) {
  var changed = false;
  if (entry['input'] is! List || !(entry['input'] as List).contains('image')) {
    entry['input'] = ['text', 'image'];
    changed = true;
  }
  final compat = entry['compat'] is Map ? (entry['compat'] as Map).cast<String, dynamic>() : <String, dynamic>{};
  if (thinkingSwitch && (compat['thinkingFormat'] == null || compat['thinkingFormat'] == '')) {
    entry['reasoning'] = true;
    entry['compat'] = {
      ...compat,
      'thinkingFormat': 'chat-template',
      'chatTemplateKwargs': {
        'enable_thinking': {r'$var': 'thinking.enabled'},
      },
    };
    changed = true;
  }
  return changed;
}

class VisionResult {
  VisionResult(this.state, this.message, {this.seconds = 0, this.download});
  final String state, message;
  final double seconds;
  final Map<String, dynamic>? download;
}

class FrameCheck {
  FrameCheck(this.runner, this.http, {this.holdFactory});
  final LocalHold Function(String)? holdFactory;
  final ProcessRunner runner;
  final LocalHttp http;
  final Map<String, (DateTime, VisionResult)> _cache = {};
  final Map<String, Map<String, dynamic>> _offers = {};
  Future<void> _serial = Future.value();
  String get home => runner.environment['HOME'] ?? '/';
  String get ini => '$home/.config/llama.cpp/models.ini';
  void forget(String command) => _cache.removeWhere((key, value) => key.startsWith('$command|'));
  void sharedWrite(String path, String text) {
    final old = File(path);
    if (!ownRegularFile(path)) throw StateError('Cannot change a shared file owned by another account.');
    final mode = old.statSync().mode & 0x1ff;
    final backupDir = Directory('$home/.local/state/ai-playground/backups/${DateTime.now().millisecondsSinceEpoch}');
    backupDir.createSync(recursive: true);
    Process.runSync('/bin/chmod', ['700', backupDir.path]);
    final copy = StagingFile(p.join(backupDir.path, p.basename(path)), exclusive: true, mode: mode);
    try {
      copy.add(old.readAsBytesSync());
    } finally {
      copy.close();
    }
    final tmp = p.join(p.dirname(path), '.${p.basename(path)}.ai-playground');
    final output = StagingFile(tmp, resume: false, mode: mode);
    try {
      output.add(utf8.encode(text));
      output.publish(path);
    } finally {
      output.close();
    }
  }

  Future<String> addMmproj(String section, String projector, CancelToken token) async {
    final text = readConfig(ini), updated = iniWithMmproj(text, section, projector);
    if (updated == null) return "its section is missing in llama.cpp's models.ini";
    sharedWrite(ini, updated);
    final port = portOf('llamacpp');
    if (loopbackListeners(port).isNotEmpty) {
      if (localClients(port) > 0) return 'llama.cpp is in use now; it reads the vision file when it starts next time';
      await runner.run(
        ['systemctl', '--user', 'restart', 'llama-server.service'],
        timeout: const Duration(seconds: 60),
        cancel: token,
      );
    }
    return '';
  }

  String? modelFile(String model) {
    final roots = <String>[];
    for (final line in readConfig('$home/.config/llama.cpp/server.env').split('\n')) {
      final at = line.indexOf('=');
      if (at < 0) continue;
      if (['LLAMA_MODELS_DIR', 'LLAMA_ARG_MODELS_DIR'].contains(line.substring(0, at).trim()) &&
          line.substring(at + 1).trim().startsWith('/')) {
        roots.add(line.substring(at + 1).trim());
      }
    }
    roots.addAll(GpuGuard(http, runner).modelRoots());
    final wanted = '${model.toLowerCase().replaceFirst(RegExp(r'\.gguf$'), '')}.gguf';
    String? visit(Directory dir, int depth) {
      if (depth > 3) return null;
      try {
        for (final e in dir.listSync(followLinks: false).take(20000)) {
          if (e is Directory) {
            final found = visit(e, depth + 1);
            if (found != null) return found;
          } else if (p.basename(e.path).toLowerCase() == wanted) {
            final real = e.resolveSymbolicLinksSync();
            if (File(real).existsSync()) return real;
          }
        }
      } on FileSystemException {
        return null;
      }
      return null;
    }

    for (final root in roots) {
      final found = visit(Directory(root), 0);
      if (found != null) return found;
    }
    return null;
  }

  Future<Map<String, dynamic>?> hfMmproj(String repo, String folder, String section, CancelToken token) async {
    if (!repoPattern.hasMatch(repo) || !ownFolder(folder)) return null;
    final out = await runner.run(
      [
        'curl',
        '-fsSL',
        '--proto',
        '=https',
        '--proto-redir',
        '=https',
        '--max-time',
        '20',
        '--max-filesize',
        '4194304',
        '--',
        'https://huggingface.co/api/models/$repo/tree/main',
      ],
      maxBytes: 4194304,
      timeout: const Duration(seconds: 25),
      cancel: token,
    );
    if (!out.ok) return null;
    Object? data;
    try {
      data = jsonDecode(out.text);
    } on FormatException {
      return null;
    }
    if (data is! List) return null;
    final files = <Map<String, dynamic>>[];
    for (final row in data) {
      if (row is! Map || row['path'] is! String || row['lfs'] is! Map) continue;
      final path = row['path'] as String, lfs = row['lfs'] as Map;
      if (path.contains('/') ||
          !path.toLowerCase().endsWith('.gguf') ||
          !path.toLowerCase().contains('mmproj') ||
          lfs['size'] is! int ||
          lfs['size'] <= 0 ||
          lfs['size'] > 8 * gib ||
          lfs['oid'] is! String ||
          !checksum.hasMatch(lfs['oid'])) {
        continue;
      }
      String safe(String s) => s.replaceAll(RegExp(r'[^\w.-]+'), '-').replaceAll(RegExp(r'^[-_.]+|[-_.]+$'), '');
      final stem = safe(path.substring(0, path.length - 5).replaceAll('mmproj', ''));
      final name = safe(section);
      var base = 'mmproj-${name.isEmpty ? 'model' : name}-${stem.isEmpty ? 'vision' : stem}';
      if (base.length > 190) base = base.substring(0, 190);
      files.add({
        'repo': repo,
        'path': path,
        'size': lfs['size'],
        'sha256': lfs['oid'],
        'target': p.join(folder, '$base.gguf'),
        'section': section,
      });
    }
    int rank(Map m) => '${m['path']}'.toLowerCase().contains('bf16')
        ? 0
        : '${m['path']}'.toLowerCase().contains('f16')
        ? 1
        : 2;
    files.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r == 0 ? (a['size'] as int).compareTo(b['size']) : r;
    });
    if (files.isEmpty) return null;
    final result = files.first;
    _offers[jsonEncode(result)] = result;
    return result;
  }

  Future<bool> fixPi(String runtime, String model, CancelToken token) async {
    final path = '$home/.pi/agent/models.json', data = readConfigJson(path);
    final providers = data['providers'];
    if (providers is! Map) return false;
    final providerId =
        const {
          'llamacpp': 'llama-local',
          'ollama': 'ollama-local',
          'lmstudio': 'lmstudio-local',
          'vllm': 'vllm-local',
          'jan': 'jan-local',
          'koboldcpp': 'koboldcpp-local',
        }[runtime] ??
        runtime;
    final provider = providers[providerId];
    if (provider is! Map || provider['models'] is! List) return false;
    final mine = (provider['models'] as List)
        .whereType<Map>()
        .where((e) => '${e['id']}'.toLowerCase() == model.toLowerCase())
        .toList();
    var hasSwitch = false;
    if (runtime == 'llamacpp' && mine.isNotEmpty) {
      try {
        final props = await http.json(
          portOf(runtime),
          '/props?model=${Uri.encodeQueryComponent(model)}',
          cancel: token,
        );
        hasSwitch = props is Map && '${props['chat_template']}'.contains('enable_thinking');
      } on Cancelled {
        rethrow;
      } on Object {
        /* optional */
      }
    }
    var changed = false;
    for (final e in mine) {
      final typed = e.cast<String, dynamic>();
      if (piEntryFixed(typed, hasSwitch)) changed = true;
    }
    if (changed) sharedWrite(path, '${const JsonEncoder.withIndent('  ').convert(data)}\n');
    return changed;
  }

  Future<Answer> probe(String command, String model, CancelToken token) async {
    final folder = createPrivateTempDirectory(prefix: 'maprisma-probe-');
    try {
      final picture = img.Image(width: 96, height: 96, numChannels: 3);
      img.fill(picture, color: img.ColorRgb8(255, 255, 255));
      img.fillRect(picture, x1: 24, y1: 24, x2: 71, y2: 71, color: img.ColorRgb8(208, 16, 16));
      final path = p.join(folder.path, 'probe.png');
      File(path).writeAsBytesSync(img.encodePng(picture));
      return await askAgent(
        runner,
        command,
        probePrompt,
        images: [path],
        level: 'quick',
        think: false,
        model: model,
        timeout: const Duration(seconds: 120),
        cancel: token,
      );
    } finally {
      folder.deleteSync(recursive: true);
    }
  }

  Future<VisionResult> check(String command, String runtime, String model, String arg, CancelToken token) async {
    final previous = _serial;
    final done = Completer<void>();
    _serial = done.future;
    try {
      await previous;
      token.check();
      final key = '$command|$runtime|$model|$arg', cached = _cache['$command|$runtime|$model|$arg'];
      if (cached != null && (cached.$2.state == 'ready' || DateTime.now().difference(cached.$1).inSeconds < 120)) {
        return cached.$2;
      }
      final result = await _check(command, runtime, model, arg, token);
      if (result.state == 'ready' || result.state == 'no') _cache[key] = (DateTime.now(), result);
      return result;
    } finally {
      done.complete();
    }
  }

  Future<VisionResult> _check(String command, String runtime, String model, String arg, CancelToken token) async {
    final name = adapter(command)!.name;
    final done = <String>[];
    VisionResult no(String why) => VisionResult('no', '$name cannot read the frames with $model: $why.');
    if (runtime == 'llamacpp' &&
        await seesPictures(http, runtime, model, environment: runner.environment, cancel: token) != true) {
      final section = iniSections(
        readConfig(ini),
      ).keys.where((s) => s == model.toLowerCase().replaceFirst(RegExp(r'\.gguf$'), '')).firstOrNull;
      final path = modelFile(model);
      if (section == null || path == null) return no("its file or its section in llama.cpp's models.ini was not found");
      String? projector;
      if (ownFolder(p.dirname(path))) {
        final files =
            Directory(p.dirname(path))
                .listSync()
                .where(
                  (f) =>
                      p.basename(f.path).toLowerCase().contains('mmproj') &&
                      f.path.toLowerCase().endsWith('.gguf') &&
                      ownRegularFile(f.path) &&
                      safeProjectorPath.hasMatch(f.path),
                )
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        if (files.isNotEmpty) projector = files.first.path;
      }
      if (projector == null) {
        final repo = '${p.basename(p.dirname(p.dirname(path)))}/${p.basename(p.dirname(path))}';
        final d = await hfMmproj(repo, p.dirname(path), section, token);
        if (d == null) return no('it has no vision file (mmproj), and none was found for it');
        return VisionResult(
          'download',
          "$model needs its vision file to see pictures: ${d['path']} (${((d['size'] as int) / gib).toStringAsFixed(1)} GB) from ${d['repo']}.",
          download: d,
        );
      }
      final why = await addMmproj(section, projector, token);
      if (why.isNotEmpty) return no(why);
      done.add("the vision file in llama.cpp's models.ini");
    }
    final hold = holdFactory?.call(runtime) ?? LocalHold(runtime, http, runner);
    try {
      await hold.open(cancel: token);
      if (hold.error.isNotEmpty) return no('the local LLM did not start (${hold.error})');
      if (['ollama', 'lmstudio'].contains(runtime) &&
          await seesPictures(http, runtime, model, environment: runner.environment, cancel: token) == false) {
        return no(
          '${runtime == 'ollama' ? 'Ollama' : 'LM Studio'} says this model does not see pictures; choose a vision model there',
        );
      }
      if (command == 'pi' && await fixPi(runtime, model, token)) {
        done.add("Pi's settings for this model (pictures, thinking off)");
      }
      final answer = await probe(command, arg, token);
      if (!answer.text.toLowerCase().contains('red')) {
        return no(
          'it did not answer the test picture (${answer.error.isNotEmpty
              ? answer.error
              : answer.text.isEmpty
              ? 'no answer'
              : answer.text.substring(0, answer.text.length.clamp(0, 80))})',
        );
      }
      return VisionResult(
        'ready',
        '$name reads pictures with $model${answer.seconds >= 15 ? ', but slowly' : ''}: about ${answer.seconds.toStringAsFixed(0)} s per frame.${done.isEmpty ? '' : ' Set up for it: ${done.join('; ')}.'}',
        seconds: answer.seconds,
      );
    } finally {
      await hold.release();
    }
  }

  Future<void> setup(
    String command,
    Map<String, dynamic> download,
    CancelToken token,
    void Function(double) progress,
  ) async {
    // Only a previously offered, server-derived destination may be written.
    final wanted = _offers.values.where((d) => const DeepCollectionEquality().equals(d, download)).firstOrNull;
    if (wanted == null || !ownFolder(p.dirname(wanted['target']))) throw ArgumentError('Unknown vision file download.');
    await downloadFile(
      runner,
      'https://huggingface.co/${wanted['repo']}/resolve/main/${Uri.encodeComponent(wanted['path'])}',
      wanted['target'],
      wanted['size'],
      wanted['sha256'],
      token,
      progress,
      resume: false,
    );
    final why = await addMmproj(wanted['section'], wanted['target'], token);
    forget(command);
    if (why.isNotEmpty) throw StateError(why);
  }
}
