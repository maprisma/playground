import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'private_files.dart';
import 'runner.dart';
import 'settings.dart';

typedef Progress = void Function(double fraction, String text);
const modelFiles = <(String, String, int, String)>[
  (
    'leejet/Z-Image-Turbo-GGUF',
    'z_image_turbo-Q8_0.gguf',
    6577440704,
    'df1c5baa86d1398c979495a6072dbcee79444fdb884a2445582ba0769c44e9a1',
  ),
  (
    'Comfy-Org/z_image_turbo',
    'split_files/vae/ae.safetensors',
    335304388,
    'afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38',
  ),
  (
    'unsloth/Qwen3-4B-Instruct-2507-GGUF',
    'Qwen3-4B-Instruct-2507-Q8_0.gguf',
    4280405600,
    '391c1e410fd9f4cf2de2b510273b56a84c19ce18f4fa3bfb3774031dac4ef068',
  ),
];
const generationSizes = {'square': (1024, 1024), 'landscape': (1280, 768), 'portrait': (768, 1280)};
final releaseTag = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final releaseAsset = RegExp(r'^sd-[A-Za-z0-9.-]+-bin-Linux-Ubuntu-[0-9.]+-x86_64-vulkan\.zip$');
final checksum = RegExp(r'^[0-9a-f]{64}$');

Future<void> downloadFile(
  ProcessRunner runner,
  String url,
  String target,
  int size,
  String digest,
  CancelToken token,
  void Function(double) progress, {
  bool resume = true,
}) async {
  if (!checksum.hasMatch(digest) || size <= 0) throw StateError('no checksum: nothing is downloaded');
  if (!url.startsWith('https://')) throw ArgumentError('HTTPS required');
  Directory(p.dirname(target)).createSync(recursive: true);
  final part = StagingFile('$target.part', resume: resume, mode: 0x1a4);
  try {
    if (part.size > size) part.truncate();
    final have = part.size;
    part.seekEnd();
    if (have < size) {
      final out = await runner.run(
        [
          'curl',
          '-fsSL',
          '--proto',
          '=https',
          '--proto-redir',
          '=https',
          '--max-redirs',
          '5',
          '--max-filesize',
          '$size',
          '--speed-limit',
          '1024',
          '--speed-time',
          '120',
          if (have > 0) ...['-C', '$have'],
          '--',
          url,
        ],
        cancel: token,
        timeout: const Duration(hours: 6),
        captureOutput: false,
        onOutput: (chunk) {
          if (part.size + chunk.length > size) throw StateError('${p.basename(target)} is larger than announced');
          part.add(chunk);
          progress(part.size / size);
        },
      );
      if (!out.ok) {
        throw StateError('download failed: ${out.stderr.trim().substring(0, out.stderr.trim().length.clamp(0, 400))}');
      }
    }
    token.check();
    if (part.size != size) throw StateError('${p.basename(target)}: download incomplete');
    final digestOutput = _DigestSink();
    final hash = sha256.startChunkedConversion(digestOutput);
    await for (final chunk in File('/proc/self/fd/${part.fd}').openRead()) {
      token.check();
      hash.add(chunk);
    }
    hash.close();
    final actual = digestOutput.value!;
    token.check();
    if (actual.toString() != digest) {
      part.truncate();
      throw StateError('${p.basename(target)} does not match its checksum; it was not kept');
    }
    part.publish(target);
    progress(1);
  } finally {
    part.close();
    if (!resume) {
      final f = File('$target.part');
      if (f.existsSync()) f.deleteSync();
    }
  }
}

/// Validate the complete central directory before inflating any entry.
void unpackRelease(String archivePath, String folder) {
  final input = InputFileStream(archivePath);
  try {
    if (File(archivePath).lengthSync() > 512 * 1024 * 1024) throw StateError('the release is too large');
    final directory = ZipDirectory();
    var announced = 0;
    final names = <String>{};
    for (final header in directory.headers(input, verify: true, files: false)) {
      final name = header.filename, mode = header.externalFileAttributes >> 16;
      if (name.startsWith('.') ||
          !RegExp(r'^[A-Za-z0-9._+\-]{1,128}$').hasMatch(name) ||
          !names.add(name) ||
          mode & 0xf000 == 0x4000) {
        throw StateError('unexpected entry in the release: $name');
      }
      if (mode & 0xf000 == 0xa000) throw StateError('a link in the release: $name');
      announced += header.uncompressedSize;
      if (announced > 1024 * 1024 * 1024) throw StateError('the release unpacks too large');
    }
    if (directory.filePosition < 0) throw StateError('unexpected release archive');
    final archive = ZipDecoder().decodeStream(input, verify: true);
    var total = 0;
    for (final file in archive.files) {
      final name = file.name;
      if (!file.isFile || name.startsWith('.') || !RegExp(r'^[A-Za-z0-9._+\-]{1,128}$').hasMatch(name)) {
        throw StateError('unexpected entry in the release: ${name.substring(0, name.length.clamp(0, 80))}');
      }
      if (file.isSymbolicLink || file.mode & 0xf000 == 0xa000) throw StateError('a link in the release: $name');
      total += file.size;
      if (total > 1024 * 1024 * 1024) throw StateError('the release unpacks too large');
    }
    Directory(folder).createSync(recursive: true);
    for (final file in archive.files) {
      final output = StagingFile(
        p.join(folder, file.name),
        exclusive: true,
        mode: ['sd-cli', 'sd-server'].contains(file.name) ? 0x1ed : 0x1a4,
      );
      try {
        output.add(file.content);
      } finally {
        output.close();
      }
    }
  } finally {
    input.closeSync();
  }
}

class PictureGen {
  PictureGen(this.runner, this.places, {this.files = modelFiles});
  final List<(String, String, int, String)> files;
  final ProcessRunner runner;
  final Places places;
  late final Directory folder = createPrivateTempDirectory(prefix: 'maprisma-generated-');
  int _next = 0;
  bool _settingUp = false;
  String modelPath((String, String, int, String) entry) =>
      p.join(places.data, 'models', 'z-image-turbo', p.basename(entry.$2));
  String? get binary {
    try {
      final tag = Link(p.join(places.data, 'sd', 'current')).targetSync();
      if (!releaseTag.hasMatch(tag) || tag == '.' || tag == '..') return null;
      final path = p.join(places.data, 'sd', tag, 'sd-cli');
      return ownRegularFile(path) && File(path).statSync().mode & 0x49 != 0 ? path : null;
    } on Object {
      return null;
    }
  }

  List<(String, String, int, String)> get missing =>
      files.where((e) => !ownRegularFile(modelPath(e)) || File(modelPath(e)).lengthSync() != e.$3).toList();
  Map<String, Object?> status() {
    final home = runner.environment['HOME'] ?? '/';
    return {
      'ready': binary != null && missing.isEmpty,
      'program': binary != null,
      'to_download': missing.fold<int>(0, (n, e) {
        final partial = '${modelPath(e)}.part';
        final have = ownRegularFile(partial) ? File(partial).lengthSync() : 0;
        return n + e.$3 - (have <= e.$3 ? have : 0);
      }),
      'folder': p.isWithin(home, places.data) ? '~/${p.relative(places.data, from: home)}' : places.data,
    };
  }

  Future<void> setup(CancelToken token, Progress progress) async {
    if (_settingUp) throw StateError('it is being downloaded already');
    _settingUp = true;
    Directory(places.data).createSync(recursive: true);
    StagingFile? lock;
    try {
      lock = StagingFile(p.join(places.data, '.setup.lock'));
      if (binary == null) {
        progress(0, '(program)');
        final out = await runner.run(
          [
            'curl',
            '-fsSL',
            '--proto',
            '=https',
            '--max-time',
            '20',
            '--max-filesize',
            '4000000',
            '-H',
            'Accept: application/vnd.github+json',
            'https://api.github.com/repos/leejet/stable-diffusion.cpp/releases/latest',
          ],
          maxBytes: 4000000,
          timeout: const Duration(seconds: 30),
          cancel: token,
        );
        if (!out.ok) throw StateError('GitHub could not be reached');
        final data = jsonDecode(out.text);
        final tag = data is Map ? data['tag_name'] : null;
        if (tag is! String || !releaseTag.hasMatch(tag) || tag == '.' || tag == '..') {
          throw StateError('unexpected release list');
        }
        Map? asset;
        for (final a in data['assets'] is List ? data['assets'] : []) {
          if (a is Map && a['name'] is String && releaseAsset.hasMatch(a['name'])) {
            asset = a;
            break;
          }
        }
        if (asset == null) throw StateError('the release has no Linux Vulkan build');
        final digest = asset['digest'], url = asset['browser_download_url'], size = asset['size'];
        if (digest is! String ||
            !digest.startsWith('sha256:') ||
            !checksum.hasMatch(digest.substring(7)) ||
            url is! String ||
            !url.startsWith('https://github.com/') ||
            size is! int ||
            size <= 0 ||
            size > 512 * 1024 * 1024) {
          throw StateError('the release lists no checksum for its Linux build');
        }
        final root = p.join(places.data, 'sd'), archive = p.join(root, asset['name']);
        await downloadFile(runner, url, archive, size, digest.substring(7), token, (f) => progress(f, '(program)'));
        final staging = Directory(p.join(root, '.$tag.partial'));
        if (staging.existsSync()) staging.deleteSync(recursive: true);
        try {
          unpackRelease(archive, staging.path);
          token.check();
          final dest = Directory(p.join(root, tag));
          if (dest.existsSync()) dest.deleteSync(recursive: true);
          staging.renameSync(dest.path);
          final fresh = Link(p.join(root, '.current.new'));
          if (FileSystemEntity.typeSync(fresh.path, followLinks: false) != FileSystemEntityType.notFound) {
            fresh.deleteSync();
          }
          fresh.createSync(tag);
          fresh.renameSync(p.join(root, 'current'));
        } finally {
          if (staging.existsSync()) staging.deleteSync(recursive: true);
          File(archive).deleteSync();
        }
      }
      final files = missing, total = missing.fold<int>(0, (n, e) => n + e.$3);
      var done = 0;
      for (final e in files) {
        await downloadFile(
          runner,
          'https://huggingface.co/${e.$1}/resolve/main/${e.$2}',
          modelPath(e),
          e.$3,
          e.$4,
          token,
          (f) {
            final fraction = (done + f * e.$3) / total;
            progress(fraction, '(${(fraction * 100).round()} %)');
          },
        );
        done += e.$3;
      }
    } finally {
      lock?.close();
      _settingUp = false;
    }
  }

  List<String> build(String prompt, String out, {String size = 'square', int seed = -1}) {
    final exe = binary;
    if (exe == null) throw StateError('stable-diffusion.cpp is not set up');
    prompt = prompt.trim().split(RegExp(r'\s+')).join(' ');
    if (prompt.length > 2000) prompt = prompt.substring(0, 2000);
    if (prompt.isEmpty) throw ArgumentError('empty prompt');
    final (width, height) = generationSizes[size] ?? generationSizes['square']!;
    return [
      exe,
      '--diffusion-model',
      modelPath(files[0]),
      '--vae',
      modelPath(files[1]),
      '--llm',
      modelPath(files[2]),
      '--cfg-scale',
      '1.0',
      '--steps',
      '8',
      '-W',
      '$width',
      '-H',
      '$height',
      '-s',
      '$seed',
      '--offload-to-cpu',
      '--flash-attn',
      'off,diffusion=on',
      '-o',
      out,
      '-p',
      prompt,
    ];
  }

  Future<Map<String, Object?>> generate(
    String prompt,
    String size,
    int seed,
    CancelToken token,
    Progress progress,
  ) async {
    final out = p.join(folder.path, 'picture-${_next++}.png');
    final argv = build(prompt, out, size: size, seed: seed);
    progress(0, 'loading the model');
    final clock = Stopwatch()..start();
    var tail = '';
    try {
      final result = await runner.run(
        argv,
        cwd: folder.path,
        timeout: const Duration(minutes: 15),
        cancel: token,
        mergeStderr: true,
        captureOutput: false,
        onOutput: (b) {
          tail += utf8.decode(b, allowMalformed: true);
          if (tail.length > 8192) tail = tail.substring(tail.length - 8192);
          final matches = RegExp(r'\|\s*(\d+)/(\d+)\s*[-|]').allMatches(tail);
          if (matches.isNotEmpty) {
            final m = matches.last, step = int.parse(matches.last[1]!), steps = int.parse(matches.last[2]!);
            progress((step / (steps == 0 ? 1 : steps)).clamp(0, 1), '${m[1]}/${m[2]}');
          }
        },
      );
      if (!result.ok || !ownRegularFile(out)) {
        if (result.reason == 'timeout') throw StateError('it took longer than 15 minutes');
        final lines = tail.split('\n').where((s) => s.trim().isNotEmpty).toList();
        final text = lines.skip((lines.length - 3).clamp(0, lines.length)).join(' / ');
        throw StateError(
          text.isEmpty ? 'sd-cli ended with ${result.reason}' : text.substring(0, text.length.clamp(0, 400)),
        );
      }
      return {'path': out, 'seconds': clock.elapsedMicroseconds / 1e6, 'seed': seed};
    } on Object {
      final f = File(out);
      if (f.existsSync()) f.deleteSync();
      rethrow;
    }
  }

  bool contains(String path) {
    try {
      return p.isWithin(folder.path, File(path).resolveSymbolicLinksSync()) && ownRegularFile(path);
    } on Object {
      return false;
    }
  }

  void clear() {
    if (folder.existsSync()) {
      for (final f in folder.listSync()) {
        f.deleteSync(recursive: true);
      }
    }
  }

  void dispose() {
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
