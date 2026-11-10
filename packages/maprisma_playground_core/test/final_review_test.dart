import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:maprisma_playground_core/maprisma_playground_core.dart' as c;
import 'package:test/test.dart';
import 'fake_http.dart';
import 'test_environment.dart';

class TestSocket implements Socket {
  bool destroyed = false;
  @override
  void destroy() => destroyed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List webp(List<int> chunks) {
  final result = Uint8List.fromList([...utf8.encode('RIFF'), 0, 0, 0, 0, ...utf8.encode('WEBP'), ...chunks]);
  ByteData.sublistView(result).setUint32(4, result.length - 8, Endian.little);
  return result;
}

List<int> chunk(String kind, List<int> data) => [
  ...utf8.encode(kind),
  ...Uint8List(4)..buffer.asByteData().setUint32(0, data.length, Endian.little),
  ...data,
  if (data.length.isOdd) 0,
];

void main() {
  late TestEnvironment e;
  setUp(() => e = TestEnvironment());
  tearDown(() => e.dispose());

  test('quiet promotions reset the pawn clock for both colours and all pieces', () {
    for (final (fen, prefix) in [
      ('7k/P7/8/8/8/8/8/7K w - - 99 1', 'a7a8'),
      ('7k/8/8/8/8/8/p7/7K b - - 99 1', 'a2a1'),
    ]) {
      for (final piece in ['q', 'r', 'b', 'n']) {
        final pos = c.fromFen(fen);
        final after = c.apply(pos, c.parse(pos, '$prefix$piece')!);
        expect(after.halfmove, 0);
      }
    }
  });

  test('description length, candidate starts and moves have hard limits', () {
    expect(c.movesInText('${'x' * c.maxDescriptionLength} 1. e4 e5'), isEmpty);
    expect(c.movesInText('${'1. invalid ' * c.maxDescriptionStarts} 1. e4 e5'), isEmpty);
    final repeated = '1. ${'Nf3 Nf6 Ng1 Ng8 ' * 100}';
    expect(c.movesInText(repeated), hasLength(c.maxDescriptionMoves));
    final clock = Stopwatch()..start();
    expect(c.movesInText('1. ' * 1000000), isEmpty);
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    expect(c.movesInText('notes 1.e4 e5 2.Nf3 Nc6 1-0').map((m) => m.uci()), ['e2e4', 'e7e5', 'g1f3', 'b8c6']);
  });

  test('settings reject public or linked folders, FIFOs and oversized files', () {
    final places = c.Places(config: '${e.home}/private', data: e.home, cache: e.home);
    final settings = c.Settings(places);
    settings.update({'automaton_speed': 15});
    expect(c.fileIdentity(places.config)!.mode & 511, 448);
    expect(c.fileIdentity(places.settingsFile)!.mode & 511, 384);
    expect(settings.get('automaton_speed'), 15);
    Process.runSync('/bin/chmod', ['755', places.config]);
    expect(settings.get('automaton_speed'), 10);
    expect(() => settings.update({'automaton_speed': 20}), throwsA(isA<FileSystemException>()));
    Process.runSync('/bin/chmod', ['700', places.config]);
    File(places.settingsFile).deleteSync();
    Process.runSync('/usr/bin/mkfifo', [places.settingsFile]);
    expect(settings.get('automaton_speed'), 10);
    settings.update({'automaton_speed': 20}); // Atomic replacement does not open the FIFO.
    expect(settings.get('automaton_speed'), 20);
    File(places.settingsFile).writeAsStringSync(' ' * (1024 * 1024 + 1));
    expect(settings.get('automaton_speed'), 10);
    Directory(places.config).renameSync('${places.config}-real');
    Link(places.config).createSync('${places.config}-real');
    expect(() => settings.update({'automaton_speed': 20}), throwsA(isA<FileSystemException>()));
    expect(settings.get('automaton_speed'), 10);
  });

  test('GIF frame zero only, structural parsing extends beyond the old prefix', () async {
    final pictures = c.Pictures(e.runner);
    addTearDown(pictures.dispose);
    final animation = img.Image(width: 1000, height: 1000, numChannels: 3);
    img.fill(animation, color: img.ColorRgb8(240, 10, 10));
    // Aggregate decoded animation exceeds the configured budget, but frame zero fits.
    for (var i = 0; i < 17; i++) {
      animation.addFrame(img.Image(width: 1000, height: 1000, numChannels: 3));
    }
    final encoded = img.encodeGif(animation);
    final header = encoded.sublist(0, 13 + (encoded[10] & 128 != 0 ? 3 * (1 << ((encoded[10] & 7) + 1)) : 0));
    final rest = encoded.sublist(header.length);
    final comments = <int>[];
    // Length-delimited comments contain fake image markers and extend past 1 MiB.
    for (var i = 0; i < 4200; i++) {
      comments.addAll([0x21, 0xfe, 255, ...List.generate(255, (j) => j.isEven ? 0 : 0x2c), 0]);
    }
    final bytes = Uint8List.fromList([...header, ...comments, ...rest]);
    expect(c.declaredSize(bytes), (1000, 1000, 18));
    final source = File('${e.home}/animation.gif')..writeAsBytesSync(bytes);
    final output = await pictures.prepare(source.path, c.CancelToken());
    expect(img.decodeJpg(File(output).readAsBytesSync())!.getPixel(0, 0).r, greaterThan(200));
    source.writeAsBytesSync(bytes.sublist(0, bytes.length - 1));
    await expectLater(pictures.prepare(source.path, c.CancelToken()), throwsStateError);
    final oversized = Uint8List.fromList(bytes);
    ByteData.sublistView(oversized).setUint16(6, 16384, Endian.little);
    ByteData.sublistView(oversized).setUint16(8, 16384, Endian.little);
    expect(c.acceptableHeader(oversized, oversized.length), false);
  });

  test('WebP chunk lengths and animation frames, never payload marker counts', () {
    final vp8l = [0x2f, 0, 0, 0, 0]; // 1x1 lossless header
    final bytes = webp([
      ...chunk('VP8X', [2, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      ...chunk('ANIM', List.filled(6, 0)),
      ...chunk('EXIF', utf8.encode('ANMF' * 300000)),
      ...chunk('ANMF', [...List.filled(16, 0), ...chunk('VP8L', vp8l)]),
    ]);
    expect(c.declaredSize(bytes), (1, 1, 1));
    expect(c.declaredSize(Uint8List.sublistView(bytes, 0, bytes.length - 1)), isNull);
    final bad = Uint8List.fromList(bytes);
    ByteData.sublistView(bad).setUint32(16, 0x7fffffff, Endian.little);
    expect(c.declaredSize(bad), isNull);
  });

  test('exact established connection owner beats a valid listener and unrelated tuples', () {
    final dir = Directory('${e.home}/procnet')..createSync();
    const server = '0100007F:1F90', client = '0100007F:CAFE';
    void table(List<String> rows) => File('${dir.path}/tcp').writeAsStringSync('header\n${rows.join('\n')}\n');
    final me = c.fileOwnerUid;
    table(['0: $server 00000000:0000 0A 0 0 0 $me', '1: $server $client 01 0 0 0 ${me + 1}']);
    expect(() => c.requireOwnConnectionPorts(8080, 0xcafe, procNet: dir.path), throwsStateError);
    table(['1: $server 0100007F:CAFF 01 0 0 0 $me']);
    expect(() => c.requireOwnConnectionPorts(8080, 0xcafe, procNet: dir.path), throwsStateError);
    table(['1: $server $client 01 0 0 0 $me']);
    c.requireOwnConnectionPorts(8080, 0xcafe, procNet: dir.path);
  });

  test('connected socket ownership rejection sends no HTTP or prompt bytes', () async {
    final socket = TestSocket();
    final client = FakeClient()..simulateConnection = true;
    var connected = false;
    final http = c.LocalHttp(
      guard: (_) {},
      clientFactory: () => client,
      connector: (_) async {
        connected = true;
        return ConnectionTask.fromSocket(Future.value(socket), () {});
      },
      connectionGuard: (_) {
        expect(connected, true);
        throw StateError('foreign established peer');
      },
    );
    await expectLater(http.fetch(8080, '/prompt', data: {'secret': 'prompt'}), throwsStateError);
    expect(client.requests, isEmpty);
    expect(socket.destroyed, true);
    expect(client.closed, true);
  });

  test('selective picture clear and no-argument clear preserve import folders', () async {
    final vision = c.Pictures(e.runner), imported = c.Pictures(e.runner);
    addTearDown(vision.dispose);
    addTearDown(imported.dispose);
    final source = File('${e.home}/image.png')..writeAsBytesSync(img.encodePng(img.Image(width: 2, height: 2)));
    final a = await vision.prepare(source.path, c.CancelToken());
    final b = await vision.prepare(source.path, c.CancelToken());
    final chess = await imported.prepare(source.path, c.CancelToken());
    vision.clear(paths: []);
    expect(File(a).existsSync(), true);
    vision.clear(paths: [a, chess, source.path]);
    expect(File(a).existsSync(), false);
    expect(File(b).existsSync(), true);
    expect(File(chess).existsSync(), true);
    expect(source.existsSync(), true);
    vision.clear();
    expect(File(b).existsSync(), false);
    expect(File(chess).existsSync(), true);
  });

  test('dispose kills every child group before bounded slow service stops', () async {
    var up = false;
    final client = FakeClient();
    final http = c.LocalHttp(
      guard: (_) {
        if (!up) throw StateError('down');
      },
      clientFactory: () => FakeClient(),
    );
    final core = c.CoreService(e.env, runner: e.runner, http: http);
    final pids = File('${e.home}/children');
    final exe = e.script(
      'children',
      "import os,time\nc=os.fork()\nif c == 0:\n time.sleep(60);os._exit(0)\nopen(os.environ['HOME']+'/children','w').write(str(os.getpid())+' '+str(c))\ntime.sleep(60)",
    );
    final job = e.runner.run([exe], timeout: const Duration(seconds: 60));
    while (!pids.existsSync() || pids.readAsStringSync().trim().split(' ').length != 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final ids = pids.readAsStringSync().split(' ');
    final hold = c.LocalHold(
      'ollama',
      http,
      e.runner,
      serviceExists: () => true,
      listeners: (_) => [],
      clients: (_) => 0,
      clientFactory: () => client,
      controlService: (start) async {
        if (start) {
          up = true;
          return true;
        }
        expect(e.runner.liveCount, 0);
        for (final pid in ids) {
          final status = File('/proc/$pid/status');
          if (status.existsSync()) expect(status.readAsStringSync(), contains('State:\tZ'));
        }
        return Completer<bool>().future; // Permanently stalled system service.
      },
    );
    await hold.open();
    final clock = Stopwatch()..start();
    await core.dispose();
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    expect(clock.elapsed, greaterThan(const Duration(seconds: 2)));
    expect((await job).ok, false);
    expect(client.connect, isNotNull); // LocalHold installs the exact-connection guard too.
  });
  test('animated WebP prepares frame zero with a budget, not the full animation', () async {
    final pictures = c.Pictures(e.runner);
    addTearDown(pictures.dispose);
    final frame = img.Image(width: 1000, height: 1000, numChannels: 3);
    img.fill(frame, color: img.ColorRgb8(10, 230, 10));
    final still = img.encodeWebP(frame);
    // Each frame embeds the still image's VP8L chunk, without its RIFF wrapper.
    final size = Uint8List(6);
    size.setAll(0, [231, 3, 0, 231, 3, 0]); // 1000 - 1 in little-endian u24
    final bytes = webp([
      ...chunk('VP8X', [2, 0, 0, 0, ...size]),
      ...chunk('ANIM', List.filled(6, 0)),
      for (var i = 0; i < 18; i++) ...chunk('ANMF', [...List.filled(6, 0), ...size, 1, 0, 0, 0, ...still.sublist(12)]),
    ]);
    expect(c.declaredSize(bytes), (1000, 1000, 18));
    final source = File('${e.home}/animation.webp')..writeAsBytesSync(bytes);
    final output = await pictures.prepare(source.path, c.CancelToken());
    expect(img.decodeJpg(File(output).readAsBytesSync())!.getPixel(0, 0).g, greaterThan(200));
  });

  test('LocalHold rejects a substituted connected peer before sending a ping', () async {
    final socket = TestSocket();
    final probe = FakeClient(), holdClient = FakeClient()..simulateConnection = true;
    final http = c.LocalHttp(
      guard: (_) {},
      clientFactory: () => probe,
      connector: (_) async => ConnectionTask.fromSocket(Future.value(socket), () {}),
      connectionGuard: (_) => throw StateError('foreign peer'),
    );
    final hold = c.LocalHold('ollama', http, e.runner, clientFactory: () => holdClient);
    await hold.open();
    expect(holdClient.requests, isEmpty);
    expect(socket.destroyed, true);
    await hold.release();
  });

  test('clear protocol validates paths and releases exactly the listed pictures', () async {
    final core = c.CoreService(e.env, runner: e.runner, http: FakeHttp());
    addTearDown(core.dispose);
    final source = File('${e.home}/image.png')..writeAsBytesSync(img.encodePng(img.Image(width: 2, height: 2)));
    final a = await core.pictures.prepare(source.path, c.CancelToken());
    final b = await core.pictures.prepare(source.path, c.CancelToken());
    Future<Map> clear(Map params) async =>
        jsonDecode(
              await core.handleAsync(
                jsonEncode({'protocol': 1, 'id': 10, 'method': 'pictures.clear', 'params': params}),
              ),
            )
            as Map;
    expect(
      (await clear({
        'paths': [a],
      }))['result'],
      {},
    );
    expect(File(a).existsSync(), false);
    expect(File(b).existsSync(), true);
    expect((await clear({'paths': 'invalid'}))['error']['code'], 'bad_params');
    expect(File(b).existsSync(), true);
    await clear({});
    expect(File(b).existsSync(), false);
  });

  test('stalled systemctl stop is killed and reaped within three seconds', () async {
    e.script(
      'systemctl',
      "import os,sys,time\nif 'start' in sys.argv:\n open(os.environ['HOME']+'/up','w').write('1')\nelse:\n open(os.environ['HOME']+'/stopper','w').write(str(os.getpid()));time.sleep(60)",
    );
    final realHttp = c.LocalHttp(
      guard: (_) {
        if (!File('${e.home}/up').existsSync()) throw StateError('down');
      },
      clientFactory: () => FakeClient(),
    );
    final realHold = c.LocalHold(
      'ollama',
      realHttp,
      e.runner,
      serviceExists: () => true,
      listeners: (_) => [],
      clients: (_) => 0,
      clientFactory: () => FakeClient(),
    );
    await realHold.open();
    await e.runner.dispose();
    final clock = Stopwatch()..start();
    await realHold.release();
    expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    final pid = File('${e.home}/stopper').readAsStringSync();
    expect(File('/proc/$pid/status').existsSync(), false);
    realHttp.dispose();
  });
}
