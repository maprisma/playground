import 'i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'agent_run.dart';
import 'agents.dart';
import 'chess_rules.dart' as rules;
import 'chess_video.dart';
import 'frame_check.dart';
import 'local_hold.dart';
import 'local_llm.dart';
import 'netfetch.dart';
import 'picture_gen.dart';
import 'pictures.dart';
import 'private_files.dart';
import 'runner.dart';

const framePrompt =
    "This is one frame of a chess video. If a chess board with pieces is visible, write its position as the piece placement part of a FEN (eight ranks from rank 8 to rank 1, seen from White's side even when the board is shown turned) alone on the first line. If no board is visible, write NONE. Write nothing else.";
const videoTextPrompt =
    'Below are the title, the description and the spoken words of a chess video. Write the moves of the main game in it, from the usual start position, in standard algebraic notation with move numbers (for example: 1. e4 e5 2. Nf3 Nc6), all on one line, as far as they can be told. If no game can be told, write NONE. Write nothing else.\n\n';

(String, String)? captionTrack(Map info) {
  final spoken = '${info['language'] ?? ''}'.split('-').first.toLowerCase();
  for (final key in ['subtitles', 'automatic_captions']) {
    final tracks = info[key];
    if (tracks is! Map) continue;
    final keys = tracks.keys
        .whereType<String>()
        .where((k) => k != 'live_chat' && tracks[k] is List && (tracks[k] as List).isNotEmpty)
        .toList();
    final preferred = [
      ...keys.where((k) => key == 'automatic_captions' && k.endsWith('-orig')),
      ...keys.where((k) => spoken.isNotEmpty && k.split('-').first.toLowerCase() == spoken),
    ];
    if (key == 'subtitles' && preferred.isEmpty) preferred.addAll(keys.take(1));
    for (final k in preferred) {
      final formats = {
        for (final row in tracks[k])
          if (row is Map && row['url'] is String) row['ext']: row['url'],
      };
      for (final ext in ['json3', 'vtt']) {
        if (formats[ext] is String) return (ext, formats[ext]);
      }
    }
  }
  return null;
}

String parseCaptions(String format, String raw) {
  List<String> lines;
  if (format == 'json3') {
    final data = jsonDecode(raw), events = data is Map ? data['events'] : null;
    lines = [
      for (final event in events is List ? events : [])
        if (event is Map)
          [
            for (final seg in event['segs'] is List ? event['segs'] : [])
              if (seg is Map && seg['utf8'] is String) seg['utf8'],
          ].join(),
    ];
  } else {
    lines = raw
        .split('\n')
        .where((s) => s.trim().isNotEmpty && !s.contains('-->') && !['WEBVTT', 'Kind:', 'Language:'].any(s.startsWith))
        .map((s) => s.replaceAll(RegExp(r'<[^>]+>'), ''))
        .toList();
  }
  final words = <String>[];
  String? previous;
  for (var line in lines) {
    line = line.replaceAll(RegExp(r'\[[^\]]{1,30}\]'), ' ').trim();
    if (line.isNotEmpty && line != previous) {
      words.add(line);
      previous = line;
    }
  }
  final text = words.join(' ');
  return text.substring(0, text.length.clamp(0, 20000));
}

class ChessImport {
  ChessImport(this.runner, this.http, this.pictures, this.frames, this.games);
  final ProcessRunner runner;
  final LocalHttp http;
  final Pictures pictures;
  final FrameCheck frames;
  final GamesStore games;
  Future<List<Map<String, Object?>>> readers(CancelToken token) async {
    final result = <Map<String, Object?>>[
      for (final a in adapters)
        if (takesImages(a.command) &&
            readsUntrusted(a.command) &&
            agentInfo(a, runner.environment)['can_ask'] == true &&
            agentInfo(a, runner.environment)['set_up'] == true &&
            executableOnPath(a.command, runner.environment) != null)
          {'command': a.command, 'name': a.name},
    ];
    for (final server in await LocalLlm(http).servers(cancel: token)) {
      for (final model in server['models'] as List) {
        if (await seesPictures(
              http,
              '${server['runtime']}',
              '$model',
              environment: runner.environment,
              port: server['port'] as int,
              cancel: token,
            ) ==
            true) {
          result.add({
            'command': 'local:${server['port']}:$model',
            'name': '$model (${server['name']})',
            'local': {'runtime': server['runtime'], 'port': server['port'], 'model': model},
          });
        }
      }
    }
    return result;
  }

  Future<Map<String, Object?>> readerInfo(Map<String, dynamic> params, CancelToken token) async {
    final source = params['path'] ?? params['url'] ?? '';
    if (source is! String) throw ArgumentError(tr("Invalid video source."));
    final before = source.isEmpty
        ? null
        : games
              .load()
              .where(
                (g) => sourceValue(g['source']).isNotEmpty && videoKey(sourceValue(g['source'])) == videoKey(source),
              )
              .firstOrNull;
    final available = await readers(token);
    final result = <String, Object?>{
      'readers': [for (final r in available) r['command']],
      'reader_details': available,
      'text_readers': [
        for (final a in adapters)
          if (readsUntrusted(a.command) &&
              agentSetUp(a.command, runner.environment) &&
              executableOnPath(a.command, runner.environment) != null)
            a.command,
      ],
      if (before != null)
        'before': {
          for (final k in ['id', 'title', 'date']) k: before[k],
        },
    };
    if (params['path'] is String && source.isNotEmpty) {
      if (!p.isAbsolute(source) || !File(source).existsSync()) throw ArgumentError(tr("Choose a video file."));
      final out = await runner.run(
        mediaArgv(
          runner,
          'ffprobe',
          ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1'],
          source,
          [],
        ),
        cancel: token,
      );
      final seconds = double.tryParse(out.text.trim());
      if (out.ok && seconds != null && seconds.isFinite && seconds >= 0) result['seconds'] = seconds;
    }
    return result;
  }

  Future<Map<String, dynamic>> videoInfo(String url, CancelToken token) async {
    if (youtubeUrl(url) != url) return {};
    final out = await runner.run(
      [
        'yt-dlp',
        '--ignore-config',
        '--no-exec',
        '--no-playlist',
        '--skip-download',
        '--dump-single-json',
        '--no-warnings',
        '--',
        url,
      ],
      maxBytes: 8 * 1024 * 1024,
      timeout: const Duration(seconds: 60),
      cancel: token,
    );
    if (!out.ok) return {};
    try {
      final data = jsonDecode(out.text);
      return data is Map ? data.cast<String, dynamic>() : {};
    } on FormatException {
      return {};
    }
  }

  Future<String> captions(Map info, CancelToken token) async {
    final track = captionTrack(info);
    if (track == null) return '';
    final uri = Uri.tryParse(track.$2);
    if (uri == null || uri.scheme != 'https' || !['.youtube.com', '.googlevideo.com'].any(uri.host.endsWith)) return '';
    final out = await runner.run(
      ['curl', '-fsS', '--proto', '=https', '--max-time', '20', '--max-filesize', '4194304', '--', track.$2],
      maxBytes: 4194304,
      timeout: const Duration(seconds: 25),
      cancel: token,
    );
    if (!out.ok) return '';
    try {
      return parseCaptions(track.$1, out.text);
    } on Object {
      return '';
    }
  }

  Future<(String, String)> download(String url, String folder, CancelToken token) async {
    if (youtubeUrl(url) != url) throw ArgumentError(tr("not a YouTube link"));
    final out = await runner.run(
      [
        'yt-dlp',
        '--ignore-config',
        '--no-exec',
        '--no-playlist',
        '--no-progress',
        '--no-mtime',
        '--no-cache-dir',
        '--restrict-filenames',
        '--max-filesize',
        '1G',
        '-f',
        'bv*[height<=480][ext=mp4]/bv*[height<=480]/b[height<=480]/b',
        '-o',
        p.join(folder, '%(title).80B.%(ext)s'),
        '--print',
        'after_move:filepath',
        '--',
        url,
      ],
      cwd: folder,
      maxBytes: 65536,
      timeout: const Duration(minutes: 30),
      cancel: token,
    );
    final lines = out.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (!out.ok || lines.isEmpty) throw StateError(tr("The video could not be downloaded."));
    String real;
    try {
      real = File(lines.last).resolveSymbolicLinksSync();
    } on Object {
      throw StateError(tr("The video could not be downloaded."));
    }
    if (!p.isWithin(folder, real) || !File(real).existsSync() || File(real).lengthSync() > 1024 * 1024 * 1024) {
      throw StateError(tr("The video could not be downloaded."));
    }
    return (real, p.basenameWithoutExtension(real).replaceAll('_', ' '));
  }

  Future<List<String>> shots(String video, String folder, int gap, int limit, CancelToken token) async {
    final keyframes = await runner.run(
      mediaArgv(
        runner,
        'ffprobe',
        [
          '-v',
          'error',
          '-select_streams',
          'v:0',
          '-skip_frame',
          'nokey',
          '-read_intervals',
          '%+60',
          '-show_entries',
          'frame=pts_time',
          '-of',
          'csv=p=0',
        ],
        video,
        [],
      ),
      maxBytes: 256 * 1024,
      timeout: const Duration(seconds: 30),
      cancel: token,
    );
    final times = keyframes.ok
        ? keyframes.text
              .split('\n')
              .map((s) => double.tryParse(s.replaceAll(',', '').trim()))
              .whereType<double>()
              .where((n) => n.isFinite)
              .toList()
        : <double>[];
    var distance = 0.0;
    for (var i = 1; i < times.length; i++) {
      final d = times[i] - times[i - 1];
      if (d > distance) distance = d;
    }
    final out = await runner.run(
      mediaArgv(
        runner,
        'ffmpeg',
        [
          '-nostdin',
          '-v',
          'error',
          '-y',
          if (distance > 0 && distance <= gap) ...['-skip_frame', 'nokey'],
        ],
        video,
        [
          if (limit > 0) ...['-t', '$limit'],
          '-vf',
          "fps=1/$gap,scale='min(1024,iw)':-2",
          '-frames:v',
          '600',
          p.join(folder, 'frame-%04d.png'),
        ],
      ),
      maxBytes: 65536,
      timeout: const Duration(minutes: 20),
      cancel: token,
    );
    if (!out.ok) return [];
    return Directory(folder)
        .listSync()
        .whereType<File>()
        .where((f) => RegExp(r'^frame-\d+\.png$').hasMatch(p.basename(f.path)))
        .map((f) => f.path)
        .take(600)
        .toList()
      ..sort();
  }

  Future<Map<String, dynamic>> start(Map<String, dynamic> params, CancelToken token, Progress progress) async {
    final raw = params['reader'];
    final reader = raw is String
        ? <String, dynamic>{'command': raw}
        : raw is Map
        ? raw.cast<String, dynamic>()
        : throw ArgumentError(tr("Expected a reader."));
    var command = reader['command'];
    var local = reader['local'];
    if (local == null && command is String && command.startsWith('local:')) {
      final m = RegExp(r'^local:(\d+):(.+)$').firstMatch(command);
      if (m == null) throw ArgumentError(tr("Invalid local reader."));
      final port = int.parse(m[1]!);
      final runtime = localServers.where((s) => s.$3 == port).firstOrNull;
      if (runtime == null) throw ArgumentError(tr("Invalid local reader."));
      local = {'port': port, 'runtime': runtime.$1, 'model': m[2]!};
    }
    if (local is! Map &&
        (command is! String || !readsUntrusted(command) || (params['way'] != 'text' && !takesImages(command)))) {
      throw ArgumentError(tr("Only an agent without tools may read a video."));
    }
    final url = params['url'] ?? '', path = params['path'] ?? '';
    if (url is! String || path is! String || (url.isEmpty == path.isEmpty)) {
      throw ArgumentError(tr("Choose a video file or YouTube link."));
    }
    if (url.isNotEmpty && youtubeUrl(url) != url) throw ArgumentError(tr("not a YouTube link"));
    if (path.isNotEmpty &&
        (!p.isAbsolute(path) ||
            !['.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v'].contains(p.extension(path).toLowerCase()) ||
            !File(path).existsSync())) {
      throw ArgumentError(tr("Choose a video file."));
    }
    final gap = params['gap'] ?? 4, limit = params['limit'] ?? 0, way = params['way'] ?? 'frames';
    if (![2, 4, 8].contains(gap) ||
        ![0, 5, 15, 30, 300, 900, 1800].contains(limit) ||
        !['text', 'frames'].contains(way)) {
      throw ArgumentError(tr("Invalid video options."));
    }
    Future<Answer> ask(String prompt, [List<String> images = const []]) async {
      if (local is Map) {
        final port = local['port'], model = local['model'];
        if (port is! int || port < 1 || port > 65535 || model is! String) {
          throw ArgumentError(tr("Invalid local reader."));
        }
        if (images.isNotEmpty &&
            await seesPictures(
                  http,
                  '${local['runtime']}',
                  model,
                  environment: runner.environment,
                  port: port,
                  cancel: token,
                ) !=
                true) {
          throw ArgumentError(tr("This local model cannot be sent pictures."));
        }
        return LocalLlm(http).ask(port, model, prompt, images: images, cancel: token);
      }
      return askAgent(
        runner,
        command,
        prompt,
        images: images,
        level: 'quick',
        think: localAgentModel(command, runner.environment) == null,
        untrusted: true,
        cancel: token,
      );
    }

    final used = local is Map
        ? ('${local['runtime']}', '${local['model']}')
        : localAgentModel(command, runner.environment);
    final hold = used == null ? null : LocalHold(serverKey(used.$1), http, runner);
    LocalHold? watcherHold;
    final folder = createPrivateTempDirectory(prefix: 'maprisma-video-');
    final pictures = Pictures(runner);
    var name = path.isEmpty ? url : p.basenameWithoutExtension(path), how = 'frames';
    final reading = Reading();
    Map<String, dynamic> saveReading() => games.save(
      {
        'name': name,
        'source': url.isEmpty ? path : url,
        'kind': 'video',
        'start_fen': rules.fen(reading.start!),
        'moves': reading.moves.map((m) => m.uci()).toList(),
        'read': how,
        'unmatched': reading.unmatched,
      },
      replaceId: params['replace_id'] as String?,
      deduplicate: true,
    );
    try {
      await hold?.open(cancel: token);
      if (hold != null && hold.error.isNotEmpty) {
        throw StateError(trf("The local LLM did not start: {0}", [hold.error]));
      }
      if (way == 'text' && url.isNotEmpty) {
        progress(0, tr("Reading the video's description…"));
        final info = await videoInfo(url, token);
        if (info.isNotEmpty) {
          name = cleanTitle('${info['title'] ?? url}');
          final description = '${info['description'] ?? ''}';
          var moves = movesInText(description);
          how = 'description';
          void remember(List<rules.Move> moves) {
            reading.start = reading.pos = rules.start();
            reading.moves.clear();
            for (final move in moves) {
              reading.moves.add(move);
              reading.pos = rules.apply(reading.pos!, move);
            }
          }

          remember(moves);
          if (moves.length < 6) {
            progress(0, tr("Reading the commentary…"));
            final spoken = await captions(info, token);
            var text = '${videoTextPrompt}Title: $name\n\nDescription:\n$description\n\nSpoken:\n$spoken';
            if (text.length > 20000 + videoTextPrompt.length) text = text.substring(0, 20000 + videoTextPrompt.length);
            final answer = await ask(text);
            final said = movesInText(answer.text);
            if (said.length > moves.length) {
              moves = said;
              how = 'commentary';
              remember(moves);
            }
          }
        }
        token.check();
        if (reading.moves.length < 6) {
          reading.moves.clear();
          reading.start = reading.pos = null;
        }
        if (reading.moves.isEmpty) {
          progress(0, tr("No game in the description or the commentary: watching the frames…"));
        }
      }
      if (reading.moves.isEmpty) {
        how = 'frames';
        var video = path;
        if (local is! Map && !takesImages(command)) {
          final seeing = (await readers(token)).where((r) => r['local'] == null).firstOrNull;
          if (seeing == null) {
            throw StateError(
              tr("No game in the description or the commentary, and no agent here sees pictures to watch the frames."),
            );
          }
          command = seeing['command'];
          final watcherModel = localAgentModel(command, runner.environment);
          if (watcherModel != null) {
            watcherHold = LocalHold(watcherModel.$1, http, runner);
            await watcherHold.open(cancel: token);
            if (watcherHold.error.isNotEmpty) {
              throw StateError(trf("The local LLM did not start: {0}", [watcherHold.error]));
            }
            final verdict = await frames.check(command, watcherModel.$1, watcherModel.$2, '', token);
            if (verdict.state != 'ready') throw StateError(verdict.message);
          }
        }
        if (url.isNotEmpty) {
          progress(0, tr("Downloading the video…"));
          final result = await download(url, folder.path, token);
          video = result.$1;
          name = result.$2;
        }
        if (local is! Map && used != null) {
          final verdict = await frames.check(command, used.$1, used.$2, '', token);
          if (verdict.state != 'ready') throw StateError(verdict.message);
        }
        progress(0, tr("Taking frames…"));
        final paths = await shots(video, folder.path, gap as int, (limit as int) < 60 ? limit * 60 : limit, token);
        if (paths.isEmpty) throw StateError(tr("No frames could be taken from that video."));
        var previous = <int>[];
        final picks = <String>[];
        try {
          for (final path in paths) {
            token.check();
            final prepared = await pictures.prepare(path, token);
            final picture = img.copyResize(img.decodeJpg(File(prepared).readAsBytesSync())!, width: 64, height: 64);
            final thumb = [for (final pixel in picture) ((pixel.r + pixel.g + pixel.b) / 3).floor()];
            if (changed(previous, thumb)) {
              previous = thumb;
              picks.add(prepared);
            } else {
              File(prepared).deleteSync();
            }
          }
          final atOnce = used != null || watcherHold != null ? 1 : 3;
          // Ask up to three cloud readers together, always follow answers in time order.
          for (var offset = 0; offset < picks.length; offset += atOnce) {
            token.check();
            final batch = picks.skip(offset).take(atOnce).toList();
            final answers = await Future.wait(batch.map((path) => ask(framePrompt, [path])));
            for (var index = 0; index < answers.length; index++) {
              token.check();
              final board = placement(answers[index].text);
              if (board != null) follow(reading, board);
              final count = offset + index + 1;
              progress(
                count / picks.length,
                '${trf('Frame {0} of {1}', [count, picks.length])} · ${trf('Moves read: {0}', [reading.moves.length])}',
              );
            }
          }
        } finally {
          for (final path in picks) {
            final file = File(path);
            if (file.existsSync()) file.deleteSync();
          }
        }
      }
      token.check();
      if (reading.moves.isEmpty) throw StateError(tr("No moves could be read from that video."));
      return saveReading();
    } on Cancelled {
      if (reading.moves.isEmpty) rethrow;
      return saveReading();
    } finally {
      await watcherHold?.release();
      await hold?.release();
      pictures.dispose();
      folder.deleteSync(recursive: true);
    }
  }
}
