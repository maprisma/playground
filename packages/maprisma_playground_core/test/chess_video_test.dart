// Port of upstream tests/test_chess_video.py. No media tools or agents run.
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart' as c;
import 'test_environment.dart';
import 'fake_http.dart';

List<String> boardAfter(List<String> sans) {
  var pos = c.start();
  for (final san in sans) {
    pos = c.apply(pos, c.parse(pos, san)!);
  }
  return pos.board;
}

void main() {
  late TestEnvironment e;
  setUp(() => e = TestEnvironment());
  tearDown(() => e.dispose());
  test('YouTube https only; drop finds a link', () {
    const valid = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s';
    expect(c.youtubeUrl('look: $valid'), valid);
    expect(c.youtubeUrl('https://youtu.be/dQw4w9WgXcQ'), 'https://youtu.be/dQw4w9WgXcQ');
    for (final bad in [
      'http://youtube.com/watch?v=dQw4w9WgXcQ',
      'https://evil.com/watch?v=dQw4w9WgXcQ',
      'https://youtube.com.evil.com/watch?v=abcdefg',
      '--exec rm https://youtu.be/',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ;rm',
    ]) {
      expect(c.youtubeUrl(bad), '', reason: bad);
    }
  });
  test('same video across URL forms and symlinks', () {
    const id = 'dQw4w9WgXcQ';
    for (final link in [
      'https://youtu.be/$id',
      'https://www.youtube.com/watch?v=$id&t=42s',
      'https://m.youtube.com/watch?v=$id',
      'https://www.youtube.com/shorts/$id',
    ]) {
      expect(c.videoKey(link), 'youtube:$id');
    }
    e.file('game.mp4', 'x');
    Link('${e.home}/link.mp4').createSync('${e.home}/game.mp4');
    expect(c.videoKey('${e.home}/link.mp4'), c.videoKey('${e.home}/game.mp4'));
  });
  test('placements, spaced placements and missing kings', () {
    final fen = c.startFen.split(' ').first;
    for (final text in ['`$fen`', 'Here: $fen w KQkq - 0 1', fen.split('').join(' ')]) {
      expect(c.placement(text), c.start().board);
    }
    expect(c.placement('NONE'), isNull);
    expect(c.placement('8/8/8/8/8/8/8/8'), isNull);
  });
  test('follow one move, two moves, still frames and unmatched frames', () {
    final r = c.Reading();
    for (final sans in <List<String>>[
      [],
      [],
      ['e4'],
      ['e4', 'e5', 'Nf3'],
      ['e4', 'e5', 'Nf3'],
      [],
      ['e4', 'e5', 'Nf3', 'Nc6'],
    ]) {
      c.follow(r, boardAfter(sans));
    }
    expect(r.moves.map((m) => m.uci()), ['e2e4', 'e7e5', 'g1f3', 'b8c6']);
    expect(r.unmatched, 1);
  });
  test('mid-game may start with Black to move', () {
    final r = c.Reading();
    c.follow(r, boardAfter(['d4']));
    c.follow(r, boardAfter(['d4', 'd5']));
    expect(r.moves.map((m) => m.uci()), ['d7d5']);
    expect(r.start!.turn, 'b');
  });
  test('compression noise ignored; moved pieces counted', () {
    final still = List.filled(4096, 100);
    expect(c.changed(still, List.generate(4096, (i) => 100 + i % 7)), false);
    expect(c.changed(still, [...List.filled(4000, 100), ...List.filled(20, 200), ...List.filled(76, 100)]), true);
    expect(c.changed([], still), true);
  });
  test('description SAN, adjoining numbers, stop at results', () {
    final moves = c.movesInText(
      'Great game! Timestamps 0:00 intro 3:12 opening\n[Event "Europe"]\n1. e4 c5 2. Nf3 d6 3. d4 cxd4 4.Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 7. Nb3 1-0\nFollow me on Twitch',
    );
    expect(moves.length, 13);
    expect(moves.take(4).map((m) => m.uci()), ['e2e4', 'c7c5', 'g1f3', 'd7d6']);
    expect(c.movesInText('No moves here, 1. just talk'), isEmpty);
    expect(c.movesInText('1.e4 e5 2.Qh5 Nc6 3.Bc4 Nf6 4.Qxf7#').length, 7);
  });
  test('captions prefer original language and remove repetition and stage directions', () {
    final info = {
      'language': 'de',
      'subtitles': {
        'live_chat': [
          {'ext': 'json', 'url': 'x'},
        ],
      },
      'automatic_captions': {
        'en': [
          {'ext': 'json3', 'url': 'https://www.youtube.com/api/en'},
        ],
        'de-orig': [
          {'ext': 'json3', 'url': 'https://www.youtube.com/api/de'},
        ],
      },
    };
    expect(c.captionTrack(info), ('json3', 'https://www.youtube.com/api/de'));
    expect(
      c.parseCaptions(
        'json3',
        jsonEncode({
          'events': [
            {
              'segs': [
                {'utf8': 'Springer'},
                {'utf8': ' f3'},
              ],
            },
            {
              'segs': [
                {'utf8': 'Springer f3'},
              ],
            },
            {
              'segs': [
                {'utf8': '[Musik]'},
              ],
            },
            {
              'segs': [
                {'utf8': 'Läufer c4'},
              ],
            },
          ],
        }),
      ),
      'Springer f3 Läufer c4',
    );
    expect(c.parseCaptions('vtt', 'WEBVTT\n00:01 --> 00:02\n<b>e4</b>\ne4\n[Music]\ne5'), 'e4 e5');
  });
  Map<String, dynamic> game(String title, {String source = ''}) => {
    'name': title,
    'start_fen': c.startFen,
    'moves': ['e2e4', 'c7c5'],
    'source': source,
    'white': 'You',
    'black': 'Pi',
  };
  test('private store, load, update, search, rename and delete', () {
    final store = c.GamesStore('${e.home}/config/games.json');
    final first = store.save(game('Carlsen vs Nakamura, blitz'));
    store.save(game('Sicilian lesson', source: '${e.home}/sicilian.mp4'));
    expect(File(store.path).statSync().mode & 511, 384);
    expect(store.list(query: 'nakamura BLITZ')['total'], 1);
    expect(store.list(offset: 1, limit: 1)['games'], hasLength(1));
    store.rename(first['id'], '  Blitz   game ');
    expect(store.get(first['id'])['name'], 'Blitz game');
    store.rename(first['id'], ' ');
    expect(store.get(first['id'])['name'], 'Blitz game');
    store.save({
      ...first,
      'moves': ['e2e4'],
    });
    expect(store.load(), hasLength(2));
    store.delete(first['id']);
    expect(store.load(), hasLength(1));
  });
  test('same-source replacement, duplicate moves, old ids and invalid input', () {
    final store = c.GamesStore('${e.home}/games.json');
    final first = store.save(game('A', source: 'https://youtu.be/dQw4w9WgXcQ'));
    final again = store.save(game('B', source: 'https://youtube.com/watch?v=dQw4w9WgXcQ&t=1s'));
    expect(again['id'], first['id']);
    expect(store.load(), hasLength(1));
    expect(store.save(game('Twin'), deduplicate: true)['id'], first['id']);
    expect(
      () => store.save({
        ...game('bad'),
        'moves': ['e2e5'],
      }),
      throwsArgumentError,
    );
    File(store.path).writeAsStringSync(
      jsonEncode([
        {
          'title': 'old',
          'start': c.startFen,
          'moves': ['e2e4'],
        },
      ]),
    );
    expect(store.load().single['id'], matches(RegExp(r'^[0-9a-f]{32}$')));
    File(store.path).writeAsStringSync('broken');
    expect(store.load(), isEmpty);
  });
  test('PGN tags, escaping, result and mid-game FEN', () {
    final store = c.GamesStore('${e.home}/games.json');
    final first = store.save(game('A "quoted" title', source: 'https://youtu.be/abcdefg'));
    final text = c.gamePgn(first);
    expect(text, contains('[Event "A \'quoted\' title"]'));
    expect(text, contains('[Site "https://youtu.be/abcdefg"]'));
    expect(text.trim(), endsWith('1. e4 c5 *'));
    expect(text, isNot(contains('[FEN')));
    var pos = c.apply(c.start(), c.parse(c.start(), 'd4')!);
    final mid = store.save({
      'name': 'mid',
      'start_fen': c.fen(pos),
      'moves': ['d7d5'],
    });
    expect(c.gamePgn(mid), contains('[SetUp "1"]'));
    expect(c.gamePgn(mid), contains('1... d5'));
    store.export(first['id'], '${e.home}/export.pgn');
    expect(File('${e.home}/export.pgn').statSync().mode & 511, 384);
    pos = c.start();
    final moves = <String>[];
    for (final san in ['f3', 'e5', 'g4', 'Qh4']) {
      final m = c.parse(pos, san)!;
      moves.add(m.uci());
      pos = c.apply(pos, m);
    }
    final mate = store.save({'name': 'Mate', 'start_fen': c.startFen, 'moves': moves, 'result': '0-1'});
    expect(c.gamePgn(mate).trim(), endsWith('Qh4# 0-1'));
  });
  c.ChessImport importer() {
    final http = FakeHttp();
    return c.ChessImport(
      e.runner,
      http,
      c.Pictures(e.runner),
      c.FrameCheck(e.runner, http),
      c.GamesStore('${e.home}/games.json'),
    );
  }

  test('yt-dlp download has no config or hooks and validates result path', () async {
    e.script(
      'yt-dlp',
      "import os,sys,json\nopen(os.environ['HOME']+'/argv','w').write(json.dumps(sys.argv))\np=os.path.join(os.getcwd(),'A_game.mp4')\nopen(p,'w').write('x')\nprint(p)",
    );
    final dir = c.createPrivateTempDirectory();
    addTearDown(() => dir.deleteSync(recursive: true));
    final result = await importer().download('https://youtu.be/dQw4w9WgXcQ', dir.path, c.CancelToken());
    expect(result.$2, 'A game');
    final argv = jsonDecode(File('${e.home}/argv').readAsStringSync()) as List;
    expect(argv, containsAll(['--ignore-config', '--no-exec', '--no-playlist']));
    expect(argv.sublist(argv.length - 2), ['--', 'https://youtu.be/dQw4w9WgXcQ']);
    e.script('yt-dlp', "print('/etc/passwd')");
    await expectLater(importer().download('https://youtu.be/dQw4w9WgXcQ', dir.path, c.CancelToken()), throwsStateError);
  });
  test('video info argv and forbidden caption host', () async {
    e.script(
      'yt-dlp',
      "import os,sys,json\nopen(os.environ['HOME']+'/argv','w').write(json.dumps(sys.argv))\nprint(json.dumps({'title':'T','description':'1. e4'}))",
    );
    final imp = importer();
    expect((await imp.videoInfo('https://youtu.be/dQw4w9WgXcQ', c.CancelToken()))['title'], 'T');
    final argv = jsonDecode(File('${e.home}/argv').readAsStringSync());
    expect(argv, containsAll(['--ignore-config', '--no-exec', '--skip-download']));
    expect(
      await imp.captions({
        'language': 'de',
        'automatic_captions': {
          'de-orig': [
            {'ext': 'json3', 'url': 'https://evil.example/x'},
          ],
        },
      }, c.CancelToken()),
      '',
    );
  });
}
