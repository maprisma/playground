import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'agents.dart';
import 'private_files.dart';
import 'runner.dart';

const maxPictureFile = 64 * 1024 * 1024;
const videoFormats = 'mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,flv,mpegts';

(int, int, int)? declaredSize(Uint8List b) {
  final d = ByteData.sublistView(b);
  bool at(int i, String s) => i + s.length <= b.length && String.fromCharCodes(b.sublist(i, i + s.length)) == s;
  int count(String s) {
    var n = 0;
    for (var i = 0; i <= b.length - s.length; i++) {
      if (at(i, s)) n++;
    }
    return max(1, n);
  }

  if (b.length >= 24 && at(0, '\x89PNG\r\n\x1a\n') && at(12, 'IHDR')) {
    var frames = 1;
    for (var i = 0; i + 8 <= b.length; i++) {
      if (at(i, 'acTL')) {
        frames = max(1, d.getUint32(i + 4));
        break;
      }
    }
    return (d.getUint32(16), d.getUint32(20), frames);
  }
  if (b.length >= 10 && (at(0, 'GIF87a') || at(0, 'GIF89a'))) {
    return (d.getUint16(6, Endian.little), d.getUint16(8, Endian.little), count('\x00\x2c'));
  }
  if (b.length >= 30 && at(0, 'RIFF') && at(8, 'WEBP')) {
    int u24(int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16;
    if (at(12, 'VP8X')) return (1 + u24(24), 1 + u24(27), count('ANMF'));
    if (at(12, 'VP8 ') && at(23, '\x9d\x01\x2a')) {
      return (d.getUint16(26, Endian.little) & 0x3fff, d.getUint16(28, Endian.little) & 0x3fff, 1);
    }
    if (at(12, 'VP8L') && b[20] == 0x2f) {
      final bits = d.getUint32(21, Endian.little);
      return (1 + (bits & 0x3fff), 1 + ((bits >> 14) & 0x3fff), 1);
    }
  }
  if (b.length >= 2 && b[0] == 255 && b[1] == 216) {
    var i = 2;
    while (i + 4 <= b.length) {
      if (b[i] != 255) return null;
      final marker = b[i + 1];
      if (marker == 255) {
        i++;
        continue;
      }
      if (marker == 216 || marker == 1 || marker >= 208 && marker <= 215) {
        i += 2;
        continue;
      }
      final length = d.getUint16(i + 2);
      if (length < 2) return null;
      if (const [192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207].contains(marker)) {
        if (i + 9 > b.length) return null;
        return (d.getUint16(i + 7), d.getUint16(i + 5), 1);
      }
      i += 2 + length;
    }
  }
  return null;
}

bool acceptableHeader(Uint8List bytes, int fileSize) {
  if (fileSize > maxPictureFile) return false;
  final size = declaredSize(bytes);
  return size != null &&
      size.$1 > 0 &&
      size.$2 > 0 &&
      size.$1 <= 16384 &&
      size.$2 <= 16384 &&
      size.$1 * size.$2 * size.$3 <= maxPictureFile;
}

List<String> mediaArgv(ProcessRunner runner, String tool, List<String> options, String video, List<String> rest) {
  if (!p.isAbsolute(video)) throw ArgumentError('a video path must be absolute');
  final argv = [
    tool,
    ...options,
    '-protocol_whitelist',
    'file',
    '-format_whitelist',
    videoFormats,
    '-i',
    video,
    ...rest,
  ];
  final prlimit = executableOnPath('prlimit', runner.environment);
  return prlimit == null ? argv : [prlimit, '--as=4294967296', '--', ...argv];
}

Future<double> videoDuration(ProcessRunner runner, String video, CancelToken token) async {
  final out = await runner.run(
    mediaArgv(
      runner,
      'ffprobe',
      ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1'],
      video,
      [],
    ),
    maxBytes: 4096,
    timeout: const Duration(seconds: 30),
    cancel: token,
  );
  final seconds = out.ok ? double.tryParse(out.text.trim()) ?? 0 : 0.0;
  return seconds.isFinite && seconds > 0 ? seconds : 0;
}

class Pictures {
  Pictures(this.runner);
  final ProcessRunner runner;
  late final Directory folder = createPrivateTempDirectory(prefix: 'maprisma-pictures-');
  int _next = 0;
  bool contains(String path) {
    try {
      return p.isWithin(folder.path, File(path).resolveSymbolicLinksSync()) &&
          FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file;
    } on Object {
      return false;
    }
  }

  Future<String> prepare(String path, CancelToken token) async {
    try {
      return await _prepare(path, token);
    } on Cancelled {
      rethrow;
    } on Object {
      throw StateError('That picture cannot be read.');
    }
  }

  Future<String> _prepare(String path, CancelToken token) async {
    token.check();
    final file = File(path);
    if (file.statSync().type != FileSystemEntityType.file) throw StateError('That picture cannot be read.');
    final handle = await file.open();
    late Uint8List bytes;
    try {
      final size = await handle.length();
      final head = await handle.read(min(size, 1024 * 1024));
      if (!acceptableHeader(head, size)) throw StateError('That picture cannot be read.');
      await handle.setPosition(0);
      bytes = await handle.read(size);
    } finally {
      await handle.close();
    }
    token.check();
    var picture = img.decodeImage(bytes);
    if (picture == null) throw StateError('That picture cannot be read.');
    if (max(picture.width, picture.height) > 1600) {
      picture = img.copyResize(
        picture,
        width: picture.width >= picture.height ? 1600 : null,
        height: picture.height > picture.width ? 1600 : null,
      );
    }
    // Copy only pixels: even EXIF carried by the decoder is discarded.
    final clean = img.Image(width: picture.width, height: picture.height, numChannels: 3);
    img.compositeImage(clean, picture);
    final out = p.join(folder.path, 'picture-${_next++}.jpg');
    await File(out).writeAsBytes(img.encodeJpg(clean, quality: 90));
    token.check();
    return out;
  }

  Future<String> screenshot(CancelToken token) async {
    final raw = createPrivateTempDirectory(prefix: 'maprisma-screenshot-');
    try {
      final path = p.join(raw.path, 'screen.png');
      final desktop = (runner.environment['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase();
      List<String> argv;
      if (desktop.contains('kde')) {
        argv = ['spectacle', '-b', '-n', '-f', '-o', path];
      } else if (desktop.contains('cosmic')) {
        final help = await runner.run(['cosmic-screenshot', '--help'], cancel: token);
        if (!help.ok || !help.text.contains('--interactive') || !help.text.contains('--save-dir')) {
          throw StateError('The screenshot did not work.');
        }
        argv = ['cosmic-screenshot', '--interactive=false', '--save-dir', raw.path];
      } else {
        argv = ['grim', path];
      }
      final result = await runner.run(argv, timeout: const Duration(seconds: 30), cancel: token);
      if (!result.ok) throw StateError('The screenshot did not work.');
      final files = raw.listSync().whereType<File>().toList();
      if (files.isEmpty) throw StateError('The screenshot did not work.');
      return await prepare(files.first.path, token);
    } finally {
      raw.deleteSync(recursive: true);
    }
  }

  Future<List<String>> videoFrames(String video, CancelToken token) async {
    final raw = createPrivateTempDirectory(prefix: 'maprisma-frames-');
    try {
      final duration = await videoDuration(runner, video, token);
      if (duration <= 0) throw StateError('No frames could be taken from that video.');
      final paths = <String>[];
      for (var i = 0; i < 4; i++) {
        final out = p.join(raw.path, '$i.png');
        final result = await runner.run(
          mediaArgv(
            runner,
            'ffmpeg',
            ['-nostdin', '-v', 'error', '-y', '-ss', (duration * (i + 0.5) / 4).toStringAsFixed(2)],
            video,
            ['-frames:v', '1', '-vf', "scale='min(1600,iw)':-2", out],
          ),
          maxBytes: 4096,
          timeout: const Duration(seconds: 30),
          cancel: token,
        );
        if (!result.ok) throw StateError('No frames could be taken from that video.');
        paths.add(await prepare(out, token));
      }
      return paths;
    } finally {
      raw.deleteSync(recursive: true);
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
