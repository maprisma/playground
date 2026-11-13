// Relevant upstream test_untrusted_input.py guards and picture lifecycle.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';
import 'fake_http.dart';

Uint8List pngHeader(int w, int h) {
  final b = Uint8List(24)
    ..setAll(0, [137, 80, 78, 71, 13, 10, 26, 10])
    ..setAll(12, 'IHDR'.codeUnits);
  ByteData.sublistView(b)
    ..setUint32(16, w)
    ..setUint32(20, h);
  return b;
}

void main() {
  late TestEnvironment e;
  late Pictures pictures;
  setUp(() {
    e = TestEnvironment();
    pictures = Pictures(e.runner);
  });
  tearDown(() async {
    pictures.dispose();
    await e.dispose();
  });
  test('PNG side and total pixel guards before decoding', () async {
    expect(declaredSize(pngHeader(1920, 1080)), (1920, 1080, 1));
    expect(acceptableHeader(pngHeader(1920, 1080), 24), true);
    for (final (w, h) in [(60000, 60000), (20000, 10), (16384, 16384), (0, 1)]) {
      expect(acceptableHeader(pngHeader(w, h), 24), false);
    }
    expect(acceptableHeader(pngHeader(1, 1), maxPictureFile + 1), false);
    final bomb = '${e.home}/bomb.png';
    File(bomb).writeAsBytesSync(pngHeader(60000, 60000));
    await expectLater(pictures.prepare(bomb, CancelToken()), throwsStateError);
    expect(pictures.folder.listSync(), isEmpty);
  });
  test('JPEG SOF and malformed animation structures', () {
    final jpg = Uint8List.fromList([
      255,
      216,
      255,
      225,
      0,
      6,
      ...'Exif'.codeUnits,
      255,
      192,
      0,
      17,
      8,
      156,
      64,
      156,
      64,
      ...List.filled(20, 0),
    ]);
    expect(declaredSize(jpg), (40000, 40000, 1));
    expect(acceptableHeader(jpg, jpg.length), false);
    final gif = Uint8List(18)..setAll(0, 'GIF89a'.codeUnits);
    ByteData.sublistView(gif)
      ..setUint16(6, 300, Endian.little)
      ..setUint16(8, 200, Endian.little);
    expect(declaredSize(gif), isNull);
    expect(acceptableHeader(gif, 18), false);
    final webp = Uint8List(30)
      ..setAll(0, 'RIFF'.codeUnits)
      ..setAll(8, 'WEBPVP8X'.codeUnits)
      ..setAll(24, [128, 62, 0, 128, 62, 0]);
    expect(declaredSize(webp), isNull);
    expect(acceptableHeader(webp, 30), false);
    final apng = Uint8List(32)
      ..setAll(0, pngHeader(1000, 1000))
      ..setAll(24, 'acTL'.codeUnits);
    ByteData.sublistView(apng).setUint32(28, 100);
    expect(acceptableHeader(apng, 32), true); // Frame zero only; acTL bytes are not scanned.
  });
  test('unknown or broken formats refused', () {
    for (final b in [
      Uint8List.fromList('not a picture'.codeUnits),
      Uint8List.fromList([255, 216, 255, 225, 0]),
      Uint8List(0),
    ]) {
      expect(declaredSize(b), isNull);
    }
  });
  test('prepare scales and strips metadata in private folder', () async {
    final original = img.Image(width: 1800, height: 900, numChannels: 3);
    img.fill(original, color: img.ColorRgb8(255, 0, 0));
    original.exif.imageIfd.imageDescription = 'private metadata';
    final path = '${e.home}/source.jpg';
    File(path).writeAsBytesSync(img.encodeJpg(original));
    final result = await pictures.prepare(path, CancelToken()), bytes = File(result).readAsBytesSync();
    final decoded = img.decodeJpg(bytes)!;
    expect((decoded.width, decoded.height), (1600, 800));
    expect(decoded.exif.imageIfd.imageDescription, isNull);
    expect(utf8.decode(bytes, allowMalformed: true), isNot(contains('private metadata')));
    expect(pictures.folder.statSync().mode & 511, 448);
    expect(pictures.contains(result), true);
    expect(pictures.contains(path), false);
    pictures.clear();
    expect(File(result).existsSync(), false);
    final folder = pictures.folder.path;
    pictures.dispose();
    expect(Directory(folder).existsSync(), false);
  });
  test('symlink escape refused', () {
    e.file('outside.jpg', 'secret');
    Link('${pictures.folder.path}/link.jpg').createSync('${e.home}/outside.jpg');
    expect(pictures.contains('${pictures.folder.path}/link.jpg'), false);
  });
  test('media protocol, format and memory guards', () {
    e.script('prlimit', '');
    final argv = mediaArgv(e.runner, 'ffprobe', ['-v', 'error'], '/videos/game.mp4', ['-of', 'csv']);
    expect(argv.take(3), ['${e.home}/bin/prlimit', '--as=4294967296', '--']);
    expect(argv[argv.indexOf('-protocol_whitelist') + 1], 'file');
    expect(argv[argv.indexOf('-format_whitelist') + 1], videoFormats);
    expect(argv.indexOf('-format_whitelist'), lessThan(argv.indexOf('-i')));
    expect(() => mediaArgv(e.runner, 'ffprobe', [], '-i.mp4', []), throwsArgumentError);
  });
  test('fake tools yield four prepared frames and remove raw files', () async {
    final png = base64Encode(img.encodePng(img.Image(width: 20, height: 12, numChannels: 3)));
    e.script('ffprobe', "print('100')");
    e.script(
      'ffmpeg',
      "import sys,base64,json,os\nopen(os.environ['HOME']+'/ffmpeg','a').write(json.dumps(sys.argv)+'\\n')\nopen(sys.argv[-1],'wb').write(base64.b64decode('$png'))",
    );
    final paths = await pictures.videoFrames('/fake/video.mp4', CancelToken());
    expect(paths, hasLength(4));
    expect(paths.every(pictures.contains), true);
    final runs = File('${e.home}/ffmpeg').readAsLinesSync().map((s) => jsonDecode(s) as List).toList();
    expect(runs.map((a) => a[a.indexOf('-ss') + 1]), ['12.50', '37.50', '62.50', '87.50']);
    expect(Directory(File(runs.first.last as String).parent.path).existsSync(), false);
    expect(runs.every((a) => a.contains('-format_whitelist')), true);
  });
  test('fake probe rejects playlist without decoding', () async {
    e.script('ffprobe', "import sys\nsys.exit(1)");
    await expectLater(pictures.videoFrames('/fake/playlist.mp4', CancelToken()), throwsStateError);
  });
  // KDE/COSMIC by session: XDG_CURRENT_DESKTOP unset (a short environment), XDG_SESSION_DESKTOP set
  for (final named in ['KDE', 'COSMIC', 'sway', 'session:KDE', 'session:COSMIC']) {
    final desktop = named.replaceFirst('session:', '');
    test('$named screenshot flags and raw cleanup', () async {
      final png = base64Encode(img.encodePng(img.Image(width: 20, height: 20, numChannels: 3)));
      if (named.startsWith('session:')) {
        e.env.remove('XDG_CURRENT_DESKTOP');
        e.env['XDG_SESSION_DESKTOP'] = desktop;
      } else {
        e.env['XDG_CURRENT_DESKTOP'] = desktop;
      }
      final runner = ProcessRunner(environment: e.env), shots = Pictures(ProcessRunner(environment: e.env));
      addTearDown(() async {
        shots.dispose();
        await shots.runner.dispose();
        await runner.dispose();
      });
      final tool = desktop == 'KDE'
          ? 'spectacle'
          : desktop == 'COSMIC'
          ? 'cosmic-screenshot'
          : 'grim';
      e.script(
        tool,
        "import sys,os,base64,json\nif '--help' in sys.argv:\n print('--interactive --save-dir');sys.exit(0)\nopen(os.environ['HOME']+'/shot','w').write(json.dumps(sys.argv))\np=(os.path.join(sys.argv[-1],'raw.png') if '--save-dir' in sys.argv else sys.argv[-1])\nopen(p,'wb').write(base64.b64decode('$png'))",
      );
      expect(shots.contains(await shots.screenshot(CancelToken())), true);
      final argv = jsonDecode(File('${e.home}/shot').readAsStringSync()) as List;
      if (desktop == 'KDE') expect(argv.sublist(1, 5), ['-b', '-n', '-f', '-o']);
      if (desktop == 'COSMIC') expect(argv, contains('--interactive=false'));
      expect(FileSystemEntity.typeSync(argv.last as String), FileSystemEntityType.notFound);
    });
  }
  test('ask rejects arbitrary image paths before agent or HTTP', () async {
    final service = CoreService(e.env, runner: e.runner, http: FakeHttp());
    addTearDown(service.dispose);
    e.file('secret.jpg', 'secret');
    final r = jsonDecode(
      await service.handleAsync(
        jsonEncode({
          'protocol': 1,
          'id': 1,
          'method': 'ask.run',
          'params': {
            'target': {'kind': 'agent', 'command': 'claude'},
            'prompt': 'Q',
            'images': ['${e.home}/secret.jpg'],
          },
        }),
      ),
    );
    expect(r['error']['code'], 'bad_params');
    expect(e.runner.liveCount, 0);
  });
}
