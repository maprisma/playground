// Port of upstream tests/test_picture_gen.py; curl and sd-cli are fake scripts.
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';

void main() {
  late TestEnvironment e;
  late PictureGen gen;
  setUp(() {
    e = TestEnvironment();
    gen = PictureGen(e.runner, Places.fromEnv(e.env));
  });
  tearDown(() async {
    gen.dispose();
    await e.dispose();
  });
  String program([String body = '']) {
    final dir = Directory('${gen.places.data}/sd/master-1')..createSync(recursive: true);
    final exe = File('${dir.path}/sd-cli')..writeAsStringSync('#!/usr/bin/python3\n$body\n');
    Process.runSync('/bin/chmod', ['755', exe.path]);
    Link('${gen.places.data}/sd/current').createSync('master-1');
    return exe.path;
  }

  String archive(List<(String, String, int?)> entries) {
    final a = Archive();
    for (final (name, text, mode) in entries) {
      final f = ArchiveFile.string(name, text);
      if (mode != null) f.mode = mode;
      a.addFile(f);
    }
    final path = '${e.home}/r.zip';
    File(path).writeAsBytesSync(ZipEncoder().encode(a));
    return path;
  }

  test('status program and models; wrong sizes and links do not count', () {
    expect(gen.status()['ready'], false);
    expect(gen.status()['program'], false);
    expect(gen.status()['to_download'], modelFiles.fold<int>(0, (n, f) => n + f.$3));
    expect(gen.status()['folder'], '~/data/maprisma-playground');
    expect(gen.binary, isNull);
    expect(program(), gen.binary);
    final model = File(gen.modelPath(modelFiles[1]));
    model.parent.createSync(recursive: true);
    model.writeAsStringSync('x');
    expect(gen.missing, contains(modelFiles[1]));
    model.deleteSync();
    Link(model.path).createSync('${e.home}/elsewhere');
    expect(gen.missing, contains(modelFiles[1]));
  });
  test('current must name a plain release folder', () {
    Directory('${gen.places.data}/sd').createSync(recursive: true);
    for (final target in ['../../etc', '.', '..', 'a/b']) {
      final link = Link('${gen.places.data}/sd/current')..createSync(target);
      expect(gen.binary, isNull);
      link.deleteSync();
    }
  });
  test('generation argv, sizes, seed, steps and prompt last', () {
    final exe = program();
    final argv = gen.build('  a red\nfox ', '/tmp/x.png', size: 'landscape', seed: 7);
    expect(argv.first, exe);
    expect(argv.sublist(argv.length - 2), ['-p', 'a red fox']);
    for (final pair in {
      '-W': '1280',
      '-H': '768',
      '-s': '7',
      '--steps': '8',
      '--diffusion-model': gen.modelPath(modelFiles[0]),
    }.entries) {
      expect(argv[argv.indexOf(pair.key) + 1], pair.value);
    }
    expect(gen.build('x' * 5000, '/tmp/x.png').last.length, 2000);
    expect(() => gen.build('  ', '/tmp/x.png'), throwsArgumentError);
  });
  test('build needs program', () {
    expect(() => gen.build('fox', '/tmp/x.png'), throwsStateError);
  });
  test('unpack flat files with correct modes', () {
    unpackRelease(archive([('sd-cli', 'bin', null), ('libggml.so.0', 'lib', null)]), '${e.home}/out');
    expect(File('${e.home}/out/sd-cli').statSync().mode & 73, isNot(0));
    expect(File('${e.home}/out/libggml.so.0').statSync().mode & 73, 0);
  });
  for (final bad in ['../evil', 'dir/file', '.hidden', 'a b', 'dir\\file', 'directory/']) {
    test('unpack rejects $bad', () {
      expect(() => unpackRelease(archive([(bad, 'x', null)]), '${e.home}/out'), throwsStateError);
    });
  }
  test('unpack refuses symlinks', () {
    expect(() => unpackRelease(archive([('sd-cli', '/etc/passwd', 0xa1ff)]), '${e.home}/out'), throwsStateError);
  });
  test('unpack refuses duplicate names and oversized declarations before decoding', () {
    final bytes = File(archive([('sd-cli', 'x', null)])).readAsBytesSync();
    // Central-directory uncompressed size: force a large announcement without allocating it.
    for (var i = 0; i < bytes.length - 28; i++) {
      if (bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 1 && bytes[i + 3] == 2) {
        bytes[i + 24] = 255;
        bytes[i + 25] = 255;
        bytes[i + 26] = 255;
        bytes[i + 27] = 127;
        break;
      }
    }
    final path = '${e.home}/bomb.zip';
    File(path).writeAsBytesSync(bytes);
    expect(() => unpackRelease(path, '${e.home}/out'), throwsStateError);
  });
  test('no download without checksum; wrong completed part is emptied', () async {
    final target = '${e.home}/m.gguf';
    await expectLater(
      downloadFile(e.runner, 'https://example.org/m', target, 10, '', CancelToken(), (_) {}),
      throwsStateError,
    );
    expect(File('$target.part').existsSync(), false);
    File('$target.part').writeAsStringSync('0123456789');
    await expectLater(
      downloadFile(e.runner, 'https://example.org/m', target, 10, '0' * 64, CancelToken(), (_) {}),
      throwsStateError,
    );
    expect(File(target).existsSync(), false);
    expect(File('$target.part').lengthSync(), 0);
  });
  test('staging refuses symlinks, hard links, FIFO and simultaneous lock', () {
    final path = '${e.home}/m.part', victim = '${e.home}/victim';
    Link(path).createSync(victim);
    expect(() => StagingFile(path), throwsA(isA<FileSystemException>()));
    expect(File(victim).existsSync(), false);
    Link(path).deleteSync();
    File(victim).writeAsStringSync('safe');
    Process.runSync('/bin/ln', [victim, path]);
    expect(() => StagingFile(path), throwsA(isA<FileSystemException>()));
    File(path).deleteSync();
    Process.runSync('/usr/bin/mkfifo', [path]);
    expect(() => StagingFile(path), throwsA(isA<FileSystemException>()));
    File(path).deleteSync();
    final first = StagingFile(path);
    try {
      expect(() => StagingFile(path), throwsStateError);
    } finally {
      first.close();
    }
    final second = StagingFile(path, resume: false);
    expect(second.size, 0);
    second.close();
  });
  test('download resumes only own part, checks SHA, publishes atomically', () async {
    e.script(
      'curl',
      "import os,sys,json\nopen(os.environ['HOME']+'/argv','w').write(json.dumps(sys.argv))\nsys.stdout.buffer.write(b'456789')",
    );
    final target = '${e.home}/m';
    File('$target.part').writeAsStringSync('0123');
    final fractions = <double>[];
    await downloadFile(
      e.runner,
      'https://example.org/m',
      target,
      10,
      sha256.convert(utf8.encode('0123456789')).toString(),
      CancelToken(),
      fractions.add,
    );
    expect(File(target).readAsStringSync(), '0123456789');
    expect(File('$target.part').existsSync(), false);
    expect(fractions.last, 1);
    final argv = jsonDecode(File('${e.home}/argv').readAsStringSync());
    expect(argv, containsAll(['-C', '4', '--proto', '=https', '--proto-redir']));
  });
  test('cancel leaves a resumable part and kills download process group', () async {
    e.script('curl', "import sys,time\nsys.stdout.buffer.write(b'0123');sys.stdout.flush();time.sleep(30)");
    final token = CancelToken(), target = '${e.home}/m';
    final future = downloadFile(e.runner, 'https://example.org/m', target, 10, 'a' * 64, token, (f) {
      token.cancel();
    });
    await expectLater(future, throwsA(isA<Cancelled>()));
    expect(File('$target.part').readAsStringSync(), '0123');
    expect(e.runner.liveCount, 0);
  });
  test('download oversize never publishes', () async {
    e.script('curl', "import sys\nsys.stdout.buffer.write(b'x'*100)");
    final path = '${e.home}/m';
    await expectLater(
      downloadFile(e.runner, 'https://example.org/m', path, 10, 'a' * 64, CancelToken(), (_) {}),
      throwsStateError,
    );
    expect(File(path).existsSync(), false);
    expect(File('$path.part').lengthSync(), 0);
  });
  test('generation streams progress, returns output, clear and dispose', () async {
    program(
      "import sys\nprint('| 1/8 -',flush=True)\nopen(sys.argv[sys.argv.index('-o')+1],'wb').write(b'png')\nprint('| 8/8 -',flush=True)",
    );
    final progress = <(double, String)>[];
    final result = await gen.generate('fox', 'portrait', 7, CancelToken(), (f, t) => progress.add((f, t)));
    expect(result['seed'], 7);
    expect(result['seconds'], isNonNegative);
    expect(gen.contains(result['path'] as String), true);
    expect(progress.first, (0.0, 'loading the model'));
    expect(progress.last, (1.0, '8/8'));
    gen.clear();
    expect(File(result['path'] as String).existsSync(), false);
    final folder = gen.folder.path;
    gen.dispose();
    expect(Directory(folder).existsSync(), false);
  });
  test('generation cancellation kills group and removes incomplete output', () async {
    program(
      "import sys,time\nopen(sys.argv[sys.argv.index('-o')+1],'wb').write(b'partial')\nprint('| 1/8 -',flush=True)\ntime.sleep(30)",
    );
    final token = CancelToken();
    await expectLater(
      gen.generate('fox', 'square', 1, token, (f, t) {
        if (f > 0) token.cancel();
      }),
      throwsA(isA<Cancelled>()),
    );
    expect(e.runner.liveCount, 0);
    expect(gen.folder.listSync(), isEmpty);
  });
  test('pinned model digests and paths', () {
    for (final file in modelFiles) {
      expect(file.$3, greaterThan(0));
      expect(file.$4, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(file.$2, isNot(contains('..')));
    }
  });
  test('setup validates release digest and installs program and models with fake curl', () async {
    final release = archive([('sd-cli', '#!/bin/sh\n', null), ('libggml.so', 'x', null)]);
    final releaseBytes = File(release).readAsBytesSync();
    final tiny = [
      for (var i = 0; i < 3; i++) ('test/repo', 'model-$i', 4, sha256.convert(utf8.encode('data')).toString()),
    ];
    final fixture = PictureGen(e.runner, gen.places, files: tiny);
    addTearDown(fixture.dispose);
    final listing = {
      'tag_name': 'master-2',
      'assets': [
        {
          'name': 'sd-test-bin-Linux-Ubuntu-24.04-x86_64-vulkan.zip',
          'digest': 'sha256:${sha256.convert(releaseBytes)}',
          'size': releaseBytes.length,
          'browser_download_url': 'https://github.com/test/release.zip',
        },
      ],
    };
    e.script(
      'curl',
      "import sys,base64,json\nurl=sys.argv[-1]\nif url.endswith('/latest'):print(${jsonEncode(jsonEncode(listing))})\nelif url.endswith('release.zip'):sys.stdout.buffer.write(base64.b64decode('${base64Encode(releaseBytes)}'))\nelse:sys.stdout.buffer.write(b'data')",
    );
    final events = <(double, String)>[];
    await fixture.setup(CancelToken(), (f, t) => events.add((f, t)));
    expect(fixture.status()['ready'], true);
    expect(fixture.status()['to_download'], 0);
    expect(events.any((e) => e.$2 == '(program)'), true);
    expect(events.last.$1, 1);
    expect(fixture.binary, endsWith('/master-2/sd-cli'));
    await fixture.setup(CancelToken(), (_, _) {});
  });
  test('release without checksum refused before asset download', () async {
    e.script(
      'curl',
      "import json\nprint(json.dumps({'tag_name':'master-1','assets':[{'name':'sd-test-bin-Linux-Ubuntu-24.04-x86_64-vulkan.zip','size':10,'browser_download_url':'https://github.com/test/r.zip'}]}))",
    );
    await expectLater(gen.setup(CancelToken(), (_, _) {}), throwsStateError);
    expect(gen.binary, isNull);
  });
  test('status reports remaining bytes for an own resumable model', () {
    final path = gen.modelPath(modelFiles.first);
    Directory(File(path).parent.path).createSync(recursive: true);
    File('$path.part').writeAsStringSync('1234');
    expect(gen.status()['to_download'], modelFiles.fold<int>(0, (n, f) => n + f.$3) - 4);
  });
}
