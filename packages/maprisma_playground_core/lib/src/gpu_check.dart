import 'dart:io';
import 'dart:convert';
import 'agents.dart';
import 'local_llm.dart';
import 'netfetch.dart';
import 'runner.dart';

const gib = 1024 * 1024 * 1024;

class ModelNeed {
  ModelNeed(this.label, this.runtime, this.model, {this.size, this.loaded = false});
  final String label, runtime, model;
  final int? size;
  final bool loaded;
  int get bytesNeeded => loaded || size == null ? 0 : (size! * 1.1).toInt() + gib ~/ 2;
}

class GpuCheck {
  GpuCheck(this.needs, {this.free = 0, this.total = 0});
  final List<ModelNeed> needs;
  final int free, total;
  int get needed => needs.fold(0, (v, n) => v + n.bytesNeeded);
  bool? get fits => total == 0
      ? null
      : needed > free
      ? false
      : needs.any((n) => !n.loaded && n.size == null)
      ? null
      : true;
  Map<String, Object?> toJson() {
    String gb(int bytes) => (bytes / gib).toStringAsFixed(1);
    final lines = [
      for (final n in needs)
        n.loaded
            ? '${n.label}: loaded already'
            : n.size == null
            ? '${n.label}: size not found'
            : '${n.label}: about ${gb(n.bytesNeeded)} GB',
    ];
    if (fits == false) {
      lines.add(
        'Together about ${gb(needed)} GB more are needed; ${gb(free)} GB of ${gb(total)} GB GPU memory are free.',
      );
    } else if (fits == null) {
      lines.add('${gb(free)} GB of ${gb(total)} GB GPU memory are free; not every size was found.');
    }
    return {
      'fits': total == 0 ? true : fits,
      'needs': [
        for (final n in needs)
          {
            'label': n.label,
            'loaded': n.loaded,
            'size': n.size,
            'bytes_needed': n.loaded
                ? 0
                : n.size == null
                ? null
                : n.bytesNeeded,
          },
      ],
      'needed': needed,
      'free': total == 0 ? null : free,
      'total': total == 0 ? null : total,
      'message': total == 0 || fits == true ? '' : lines.join('\n'),
    };
  }
}

/// GGUF weights, deduplicated by real path; split shards combined; projectors excluded.
Map<String, int> ggufSizes(List<String> roots, {int maxFiles = 20000}) {
  final parts = <String, Map<String, int>>{};
  for (final root in roots) {
    var count = 0;
    void visit(Directory dir) {
      if (count >= maxFiles) return;
      try {
        final entries = dir.listSync(followLinks: false);
        var dirs = 0;
        for (final entity in entries) {
          if (entity is Directory) {
            if (!entity.path.split('/').last.startsWith('.') && dirs++ < 500) {
              visit(entity);
            }
            continue;
          }
          if (++count > maxFiles) return;
          final name = entity.path.split('/').last.toLowerCase();
          if (!name.endsWith('.gguf') || name.startsWith('mmproj')) continue;
          try {
            final real = entity.resolveSymbolicLinksSync(), size = File(entity.path).lengthSync();
            final stem = name.substring(0, name.length - 5).replaceFirst(RegExp(r'-\d{5}-of-\d{5}$'), '');
            parts.putIfAbsent(stem, () => {})[real] = size;
          } on FileSystemException {
            /* unavailable */
          }
        }
      } on FileSystemException {
        /* unavailable */
      }
    }

    visit(Directory(root));
  }
  return parts.map((k, v) => MapEntry(k, v.values.fold(0, (a, b) => a + b)));
}

class GpuGuard {
  GpuGuard(this.http, this.runner);
  final LocalHttp http;
  final ProcessRunner runner;
  Future<(int, int)> totals({CancelToken? cancel}) async {
    var used = 0, total = 0;
    try {
      for (final dir in Directory('/sys/class/drm').listSync()) {
        if (!RegExp(r'^card\d+$').hasMatch(dir.path.split('/').last)) continue;
        final path = '${dir.path}/device';
        final t = int.tryParse(readConfig('$path/mem_info_vram_total').trim()) ?? 0;
        final u = int.tryParse(readConfig('$path/mem_info_vram_used').trim()) ?? 0;
        total += t;
        used += u;
      }
    } on FileSystemException {
      /* no AMD GPU */
    }
    if (total > 0) return (used, total);
    final exe = executableOnPath('nvidia-smi', runner.environment);
    if (exe == null) return (0, 0);
    final result = await runner.run([
      exe,
      '--query-gpu=memory.used,memory.total',
      '--format=csv,noheader,nounits',
    ], cancel: cancel);
    if (result.ok) {
      for (final line in result.text.split('\n')) {
        final cols = line.split(',').map((s) => int.tryParse(s.trim())).toList();
        if (cols.length == 2 && cols.every((n) => n != null)) {
          used += cols[0]! * 1024 * 1024;
          total += cols[1]! * 1024 * 1024;
        }
      }
    }
    return (used, total);
  }

  List<String> modelRoots() {
    final home = runner.environment['HOME'] ?? '/';
    final roots = <String>[];
    for (final path in ['$home/.config/omarchy/ai-agents-map/settings.json', '$home/.config/asterism/settings.json']) {
      final v = readConfigJson(path)['models_root'];
      if (v is String && (v.startsWith('/') || v.startsWith('~/'))) {
        roots.add(v.startsWith('~/') ? '$home/${v.substring(2)}' : v);
      }
    }
    return [
      ...roots,
      for (final dir in [
        '.lmstudio/models',
        '.cache/lm-studio/models',
        '.cache/llama.cpp',
        'models',
        'Models',
        '.local/share/jan/models',
      ])
        '$home/$dir',
    ];
  }

  Future<Set<String>> _lmsLoaded({CancelToken? cancel}) async {
    final home = runner.environment['HOME'] ?? '/';
    final binary =
        executableOnPath('lms', runner.environment) ??
        (File('$home/.lmstudio/bin/lms').statSync().mode & 73 != 0 ? '$home/.lmstudio/bin/lms' : null);
    if (binary == null) return {};
    final out = await runner.run([binary, 'ps', '--json'], maxBytes: 1024 * 1024, cancel: cancel);
    if (!out.ok) return {};
    try {
      final rows = jsonDecode(out.text);
      return rows is List
          ? {
              for (final row in rows.take(100))
                if (row is Map && row['type'] == 'llm' && row['identifier'] is String)
                  (row['identifier'] as String).toLowerCase().substring(
                    0,
                    (row['identifier'] as String).length.clamp(0, 200),
                  ),
            }
          : {};
    } on Object {
      return {};
    }
  }

  Future<Set<String>> loaded(String runtime, int port, {CancelToken? cancel}) async {
    try {
      final path = switch (runtime) {
        'ollama' => '/api/ps',
        'llamacpp' || 'jan' => '/models',
        'lmstudio' => '/api/v0/models',
        _ => '/v1/models',
      };
      final reply = await http.json(port, path, cancel: cancel);
      final rows = reply is Map ? reply[runtime == 'ollama' ? 'models' : 'data'] : null;
      if (rows is! List) return {};
      if (runtime == 'koboldcpp') {
        final first = rows.isNotEmpty && rows.first is Map ? rows.first['id'] : null;
        return first is String && first.startsWith('koboldcpp/') ? {'${first.substring(10).toLowerCase()}.kcpps'} : {};
      }
      return {
        for (final row in rows.take(500))
          if (row is Map &&
              (runtime == 'ollama' ||
                  runtime == 'vllm' ||
                  ((runtime == 'llamacpp' || runtime == 'jan') &&
                      row['status'] is Map &&
                      const ['loaded', 'loading', 'sleeping'].contains(row['status']['value'])) ||
                  (runtime == 'lmstudio' && row['state'] == 'loaded')))
            (row[runtime == 'ollama' ? 'name' : 'id'] ?? '').toString().toLowerCase(),
      };
    } on Cancelled {
      rethrow;
    } on Object {
      return runtime == 'lmstudio' ? await _lmsLoaded(cancel: cancel) : {};
    }
  }

  Future<GpuCheck?> check(
    List<(String, String, String)> wanted, {
    (int, int)? memory,
    Map<String, int>? files,
    CancelToken? cancel,
  }) async {
    final distinct = <String, (String, String, String)>{for (final v in wanted) '${v.$2}|${v.$3.toLowerCase()}': v};
    if (distinct.length < 2) return null;
    final (used, total) = memory ?? await totals(cancel: cancel);
    final sizes = files ?? ggufSizes(modelRoots());
    final loadedByServer = <String, Set<String>>{}, ollama = <String, int>{};
    final needs = <ModelNeed>[];
    for (final (label, runtime, model) in distinct.values) {
      loadedByServer[runtime] ??= files != null ? {} : await loaded(runtime, portOf(runtime), cancel: cancel);
      if (runtime == 'ollama' && files == null && ollama.isEmpty) {
        try {
          final reply = await http.json(portOf(runtime), '/api/tags', cancel: cancel);
          if (reply is Map && reply['models'] is List) {
            for (final row in reply['models']) {
              if (row is Map && row['name'] is String && row['size'] is int) {
                ollama[(row['name'] as String).toLowerCase()] = row['size'];
              }
            }
          }
        } on Cancelled {
          rethrow;
        } on Object {
          /* unknown size */
        }
      }
      final name = model.toLowerCase();
      needs.add(
        ModelNeed(
          label,
          runtime,
          model,
          size: ollama[name] ?? sizes[name] ?? sizes[name.replaceFirst(RegExp(r'\.gguf$'), '')],
          loaded: loadedByServer[runtime]!.contains(name),
        ),
      );
    }
    return GpuCheck(needs, free: (total - used).clamp(0, total), total: total);
  }

  Future<void> unload(String runtime, String model, {int? port, CancelToken? cancel}) async {
    if (runtime != 'ollama') return;
    try {
      await http.json(
        port ?? 11434,
        '/api/generate',
        data: {'model': model, 'keep_alive': 0},
        maxBytes: 65536,
        timeout: const Duration(seconds: 30),
        cancel: cancel,
      );
    } on Cancelled {
      rethrow;
    } on Object {
      /* best effort, as upstream */
    }
  }
}
