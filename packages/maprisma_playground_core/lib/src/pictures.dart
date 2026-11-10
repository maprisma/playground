import 'i18n.dart';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'agents.dart';
import 'private_files.dart';
import 'runner.dart';

const maxPicturePixels = 16 * 1024 * 1024;
const maxPictureFile = 64 * 1024 * 1024;
const videoFormats = 'mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,flv,mpegts';

(int, int, int)? declaredSize(Uint8List b) {
  final d = ByteData.sublistView(b);
  bool at(int i, String s) => i + s.length <= b.length && String.fromCharCodes(b.sublist(i, i + s.length)) == s;
  bool fits(int w, int h) => w > 0 && h > 0 && w <= 16384 && h <= 16384 && w * h <= maxPicturePixels;
  if (b.length >= 24 && at(0, '\x89PNG\r\n\x1a\n') && at(12, 'IHDR')) {
    return (d.getUint32(16), d.getUint32(20), 1);
  }
  if (b.length >= 13 && (at(0, 'GIF87a') || at(0, 'GIF89a'))) {
    final w = d.getUint16(6, Endian.little), h = d.getUint16(8, Endian.little);
    var i = 13 + (b[10] & 128 != 0 ? 3 * (1 << ((b[10] & 7) + 1)) : 0);
    var frames = 0;
    bool blocks() {
      while (i < b.length) {
        final n = b[i++];
        if (n == 0) return true;
        i += n;
      }
      return false;
    }

    while (i < b.length) {
      final kind = b[i++];
      if (kind == 0x3b) return frames > 0 && i == b.length ? (w, h, frames) : null;
      if (kind == 0x21) {
        if (i >= b.length) return null;
        i++; // extension label, followed by length-delimited subblocks
        if (!blocks()) return null;
      } else if (kind == 0x2c) {
        if (i + 9 > b.length) return null;
        final x = d.getUint16(i, Endian.little), y = d.getUint16(i + 2, Endian.little);
        final fw = d.getUint16(i + 4, Endian.little), fh = d.getUint16(i + 6, Endian.little);
        if (!fits(fw, fh) || x + fw > w || y + fh > h) return null;
        final packed = b[i + 8];
        i += 9 + (packed & 128 != 0 ? 3 * (1 << ((packed & 7) + 1)) : 0);
        if (i >= b.length || b[i] < 2 || b[i] > 8) return null;
        i++; // LZW minimum code size
        if (!blocks()) return null;
        frames++;
      } else {
        return null;
      }
    }
    return null;
  }
  if (b.length >= 20 && at(0, 'RIFF') && at(8, 'WEBP')) {
    if (d.getUint32(4, Endian.little) + 8 != b.length) return null;
    int u24(int i) => b[i] | b[i + 1] << 8 | b[i + 2] << 16;
    (int, int)? imageSize(int i, int n) {
      final payload = i + 8;
      if (at(i, 'VP8 ')) {
        if (n < 10 || !at(payload + 3, '\x9d\x01\x2a')) return null;
        return (d.getUint16(payload + 6, Endian.little) & 0x3fff, d.getUint16(payload + 8, Endian.little) & 0x3fff);
      }
      if (n < 5 || b[payload] != 0x2f) return null;
      final bits = d.getUint32(payload + 1, Endian.little);
      if (bits >> 29 != 0) return null; // VP8L version must be zero.
      return (1 + (bits & 0x3fff), 1 + ((bits >> 14) & 0x3fff));
    }

    var w = 0, h = 0, frames = 0, images = 0;
    var animated = false, animationHeader = false;
    for (var i = 12; i < b.length;) {
      if (i + 8 > b.length) return null;
      final n = d.getUint32(i + 4, Endian.little), payload = i + 8;
      final end = payload + n;
      if (end + (n & 1) > b.length) return null;
      if (at(i, 'VP8X')) {
        if (i != 12 || n != 10) return null;
        animated = b[payload] & 2 != 0;
        w = 1 + u24(payload + 4);
        h = 1 + u24(payload + 7);
      } else if (at(i, 'ANIM')) {
        if (!animated || animationHeader || n != 6 || frames != 0) return null;
        animationHeader = true;
      } else if (at(i, 'ANMF')) {
        if (!animationHeader || n < 16) return null;
        final fw = 1 + u24(payload + 6), fh = 1 + u24(payload + 9);
        if (!fits(fw, fh) || 2 * u24(payload) + fw > w || 2 * u24(payload + 3) + fh > h) return null;
        var frameImages = 0;
        for (var j = payload + 16; j < end;) {
          if (j + 8 > end) return null;
          final length = d.getUint32(j + 4, Endian.little);
          if (j + 8 + length + (length & 1) > end) return null;
          if (at(j, 'VP8 ') || at(j, 'VP8L')) {
            if (++frameImages > 1) return null;
            final size = imageSize(j, length);
            if (size == null || size.$1 != fw || size.$2 != fh || !fits(size.$1, size.$2)) return null;
          } else if (!at(j, 'ALPH')) {
            return null;
          }
          j += 8 + length + (length & 1);
        }
        if (frameImages != 1) return null;
        frames++;
      } else if (at(i, 'VP8 ') || at(i, 'VP8L')) {
        if (animated || ++images > 1) return null;
        final size = imageSize(i, n);
        if (size == null) return null;
        final (iw, ih) = size;
        if (!fits(iw, ih)) return null;
        if (w == 0) {
          w = iw;
          h = ih;
        }
        if (iw != w || ih != h) return null;
      }
      i = end + (n & 1);
    }
    return (animated ? frames > 0 : images == 1) ? (w, h, max(1, frames)) : null;
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
      size.$1 * size.$2 <= maxPicturePixels;
}

List<String> mediaArgv(ProcessRunner runner, String tool, List<String> options, String video, List<String> rest) {
  if (!p.isAbsolute(video)) throw ArgumentError(tr("a video path must be absolute"));
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
      throw StateError(tr("That picture cannot be read."));
    }
  }

  Future<String> _prepare(String path, CancelToken token) async {
    token.check();
    final file = File(path);
    if (file.statSync().type != FileSystemEntityType.file) throw StateError(tr("That picture cannot be read."));
    final handle = await file.open();
    late Uint8List bytes;
    try {
      final size = await handle.length();
      if (size > maxPictureFile) throw StateError(tr("That picture cannot be read."));
      bytes = await handle.read(size);
      if (!acceptableHeader(bytes, size)) throw StateError(tr("That picture cannot be read."));
    } finally {
      await handle.close();
    }
    token.check();
    final img.Decoder decoder;
    if (bytes[0] == 0x89) {
      decoder = img.PngDecoder(maxPixels: maxPicturePixels);
    } else if (bytes[0] == 0xff) {
      decoder = img.JpegDecoder(maxPixels: maxPicturePixels);
    } else if (bytes[0] == 0x47) {
      decoder = (img.GifDecoder()..maxPixels = maxPicturePixels);
    } else {
      decoder = (img.WebPDecoder()..maxPixels = maxPicturePixels);
    }
    var picture = decoder.decode(bytes, frame: 0);
    if (picture == null) throw StateError(tr("That picture cannot be read."));
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
    try {
      await File(out).writeAsBytes(img.encodeJpg(clean, quality: 90));
      token.check();
      return out;
    } on Object {
      if (File(out).existsSync()) File(out).deleteSync();
      rethrow;
    }
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
          throw StateError(tr("The screenshot did not work."));
        }
        argv = ['cosmic-screenshot', '--interactive=false', '--save-dir', raw.path];
      } else {
        argv = ['grim', path];
      }
      final result = await runner.run(argv, timeout: const Duration(seconds: 30), cancel: token);
      if (!result.ok) throw StateError(tr("The screenshot did not work."));
      final files = raw.listSync().whereType<File>().toList();
      if (files.isEmpty) throw StateError(tr("The screenshot did not work."));
      return await prepare(files.first.path, token);
    } finally {
      raw.deleteSync(recursive: true);
    }
  }

  Future<List<String>> videoFrames(String video, CancelToken token) async {
    final raw = createPrivateTempDirectory(prefix: 'maprisma-frames-');
    final paths = <String>[];
    try {
      final duration = await videoDuration(runner, video, token);
      if (duration <= 0) throw StateError(tr("No frames could be taken from that video."));
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
        if (!result.ok) throw StateError(tr("No frames could be taken from that video."));
        paths.add(await prepare(out, token));
      }
      return paths;
    } on Object {
      clear(paths: paths);
      rethrow;
    } finally {
      raw.deleteSync(recursive: true);
    }
  }

  /// Paths are owned by the operation receiving them. Omission clears Vision only.
  void clear({List<String>? paths}) {
    final owned = paths ?? (folder.existsSync() ? folder.listSync().map((f) => f.path).toList() : <String>[]);
    for (final path in owned) {
      if (contains(path)) File(path).deleteSync();
    }
  }

  void dispose() {
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  }
}
