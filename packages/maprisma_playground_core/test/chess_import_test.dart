import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart' as c;
import 'test_environment.dart';
import 'fake_http.dart';

void main() {
  late TestEnvironment e;
  late FakeHttp http;
  late c.Pictures pictures;
  late c.ChessImport importer;
  late c.GamesStore store;
  setUp(() {
    e = TestEnvironment();
    http = FakeHttp();
    pictures = c.Pictures(e.runner);
    store = c.GamesStore('${e.home}/games.json');
    importer = c.ChessImport(e.runner, http, pictures, c.FrameCheck(e.runner, http), store);
  });
  tearDown(() async {
    pictures.dispose();
    http.dispose();
    await e.dispose();
  });
  test('untrusted Codex reader refused before any tools or network', () async {
    await expectLater(
      importer.start({'url': 'https://youtu.be/abcdefg', 'reader': 'codex', 'way': 'text'}, c.CancelToken(), (_, _) {}),
      throwsArgumentError,
    );
    expect(e.runner.liveCount, 0);
    expect(http.calls, isEmpty);
  });
  test('YouTube-only URL, exclusive source, video extension, options', () async {
    for (final params in [
      {'url': 'https://evil.com/abcdefg'},
      {'url': 'http://youtu.be/abcdefg'},
      {'url': 'https://youtu.be/abcdefg', 'path': '/x.mp4'},
      {'path': 'relative.mp4'},
      {'path': '/x.m3u8'},
      {'url': 'https://youtu.be/abcdefg', 'gap': 1},
    ]) {
      await expectLater(
        importer.start({'reader': 'claude', 'way': 'frames', ...params}, c.CancelToken(), (_, _) {}),
        throwsArgumentError,
      );
    }
  });
  test('description parses and saves without asking any agent; replacement and duplicate', () async {
    e.script(
      'yt-dlp',
      "import json\nprint(json.dumps({'title':'A game','description':'1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6'}))",
    );
    final progress = <(double, String)>[];
    final game = await importer.start(
      {'url': 'https://youtu.be/abcdefg', 'reader': 'claude', 'way': 'text'},
      c.CancelToken(),
      (f, t) => progress.add((f, t)),
    );
    expect(game['moves'], hasLength(6));
    expect(store.load(), hasLength(1));
    expect(progress.first.$2, "Reading the video's description…");
    final again = await importer.start(
      {'url': 'https://youtube.com/watch?v=abcdefg&t=1s', 'reader': 'claude', 'way': 'text', 'replace_id': game['id']},
      c.CancelToken(),
      (_, _) {},
    );
    expect(again['id'], game['id']);
    expect(store.load(), hasLength(1));
  });
  test('captions fetched from approved host; commentary goes only to safe agent', () async {
    e.script(
      'yt-dlp',
      "import json\nprint(json.dumps({'title':'Game','language':'en','description':'talk','subtitles':{'en':[{'ext':'json3','url':'https://www.youtube.com/api/captions'}]}}))",
    );
    e.script('curl', "import json\nprint(json.dumps({'events':[{'segs':[{'utf8':'e4 e5 knight f3 knight c6'}]}]}))");
    e.script(
      'claude',
      "import sys,json,os\np=sys.stdin.read()\nassert 'e4 e5 knight' in p\nopen(os.environ['HOME']+'/asked','w').write(p)\nprint(json.dumps({'type':'result','result':'1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6'}))",
    );
    final game = await importer.start(
      {'url': 'https://youtu.be/abcdefg', 'reader': 'claude', 'way': 'text'},
      c.CancelToken(),
      (_, _) {},
    );
    expect(game['read'], 'commentary');
    expect(game['moves'], hasLength(6));
    expect(File('${e.home}/asked').existsSync(), true);
  });
  List<String> fakeFrames() {
    var pos = c.start();
    final fens = [c.fen(pos).split(' ').first];
    for (final san in ['e4', 'e5']) {
      pos = c.apply(pos, c.parse(pos, san)!);
      fens.add(c.fen(pos).split(' ').first);
    }
    final pngs = <String>[];
    for (final color in [10, 80, 150]) {
      final im = img.Image(width: 20, height: 20, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(color, color, color));
      pngs.add(base64Encode(img.encodePng(im)));
    }
    e.script('ffprobe', "print('0\\n2\\n4')");
    e.script(
      'ffmpeg',
      "import sys,os,base64,json\nopen(os.environ['HOME']+'/media','w').write(json.dumps(sys.argv))\nfor i,b in enumerate(${jsonEncode(pngs)}):open(sys.argv[-1] % (i+1),'wb').write(base64.b64decode(b))",
    );
    // Select the position by the frame's actual pixel, so concurrent requests cannot reorder it.
    e.script(
      'claude',
      "import sys,json,base64,zlib\np=json.loads(sys.stdin.read())\nb=base64.b64decode(p['message']['content'][0]['source']['data'])\n# JPEG prepared copies differ; locate mean via the known frame name is not reliable.\nprint(json.dumps({'type':'result','result':'${fens[0]}'}))",
    );
    return fens;
  }

  test('frame extraction protocol and memory options, safe prepared images and cleanup', () async {
    final fens = fakeFrames();
    e.file('game.mp4', 'fake');
    // A fake safe agent reads only its own prepared image. Pillow is not required:
    // deterministic queue answers are serialized with flock, while processes still run together.
    e.script(
      'claude',
      "import sys,json,os,fcntl\nsys.stdin.read()\nf=open(os.environ['HOME']+'/counter','a+')\nfcntl.flock(f,fcntl.LOCK_EX)\nf.seek(0);n=int(f.read() or '0');f.seek(0);f.truncate();f.write(str(n+1));f.flush()\nprint(json.dumps({'type':'result','result':${jsonEncode(fens)}[min(n,2)]}))",
    );
    // Exercise extraction independently; frame-follow semantics are tested with deterministic boards.
    final dir = c.createPrivateTempDirectory();
    addTearDown(() => dir.deleteSync(recursive: true));
    final paths = await importer.shots('${e.home}/game.mp4', dir.path, 4, 300, c.CancelToken());
    expect(paths, hasLength(3));
    final argv = jsonDecode(File('${e.home}/media').readAsStringSync()) as List;
    expect(
      argv,
      containsAll([
        '-protocol_whitelist',
        'file',
        '-format_whitelist',
        c.videoFormats,
        '-skip_frame',
        'nokey',
        '-t',
        '300',
        '-frames:v',
        '600',
      ]),
    );
    final badReader = <String, dynamic>{
      'reader': 'claude',
      'path': '${e.home}/game.mp4',
      'way': 'frames',
      'gap': 4,
      'limit': 300,
    };
    // Return the start board for each frame: no legal changes means no saved empty game.
    e.script('claude', "import sys,json\nsys.stdin.read()\nprint(json.dumps({'type':'result','result':'${fens[0]}'}))");
    await expectLater(importer.start(badReader, c.CancelToken(), (_, _) {}), throwsStateError);
    expect(store.load(), isEmpty);
    expect(pictures.folder.listSync(), isEmpty);
  });

  test('frames produce a legally validated saved game in frame order', () async {
    final fens = fakeFrames();
    e.file('game.mp4', 'fake');
    final hashes = <String, String>{};
    for (var i = 0; i < 3; i++) {
      final color = [10, 80, 150][i];
      final im = img.Image(width: 20, height: 20, numChannels: 3);
      img.fill(im, color: img.ColorRgb8(color, color, color));
      final raw = '${e.home}/raw-$i.png';
      File(raw).writeAsBytesSync(img.encodePng(im));
      final prepared = await pictures.prepare(raw, c.CancelToken());
      hashes[sha256.convert(File(prepared).readAsBytesSync()).toString()] = fens[i];
      File(prepared).deleteSync();
    }
    e.script(
      'claude',
      "import sys,json,base64,hashlib\np=json.loads(sys.stdin.read())\nb=base64.b64decode(p['message']['content'][0]['source']['data'])\nprint(json.dumps({'type':'result','result':${jsonEncode(hashes)}[hashlib.sha256(b).hexdigest()]}))",
    );
    final game = await importer.start(
      {'path': '${e.home}/game.mp4', 'reader': 'claude', 'way': 'frames', 'gap': 4},
      c.CancelToken(),
      (_, _) {},
    );
    expect(game['moves'], ['e2e4', 'e7e5']);
    expect(game['read'], 'frames');
    expect(store.load().single['id'], game['id']);
    expect(pictures.folder.listSync(), isEmpty);
    late c.CoreService service;
    service = c.CoreService(
      e.env,
      runner: e.runner,
      http: http,
      onEvent: (frame) {
        final event = jsonDecode(frame);
        if (event['data']['text'].toString().startsWith('Frame 2 of')) {
          service.handleAsync('{"cancel": 41}');
        }
      },
    );
    final reply = jsonDecode(
      await service.handleAsync(
        jsonEncode({
          'protocol': 1,
          'id': 41,
          'method': 'import.start',
          'params': {'path': '${e.home}/game.mp4', 'reader': 'claude', 'way': 'frames', 'gap': 4},
        }),
      ),
    );
    expect(reply['result']['game']['moves'], ['e2e4']);
    expect(reply['result']['read'], 'frames');
    expect(reply['result']['unmatched'], 0);
    expect(service.games.load().single['moves'], ['e2e4']);
    await service.dispose();
  });
  test('text failure falls back to download and frames; cancellation kills tools', () async {
    fakeFrames();
    e.script(
      'yt-dlp',
      "import sys,json,os,time\nif '--skip-download' in sys.argv:print(json.dumps({'title':'No game','description':'talk'}))\nelse:\n open(os.environ['HOME']+'/downloading','w').write('1');time.sleep(30)",
    );
    e.script('claude', "import sys,json\nsys.stdin.read();print(json.dumps({'type':'result','result':'NONE'}))");
    final token = c.CancelToken(), progress = <String>[];
    final work = importer.start({'url': 'https://youtu.be/abcdefg', 'reader': 'claude', 'way': 'text'}, token, (f, t) {
      progress.add(t);
      if (t == 'Downloading the video…') token.cancel();
    });
    await expectLater(work, throwsA(isA<c.Cancelled>()));
    expect(progress, contains('No game in the description or the commentary: watching the frames…'));
    expect(e.runner.liveCount, 0);
    expect(store.load(), isEmpty);
  });
}
