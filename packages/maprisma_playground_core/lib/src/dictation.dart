import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'private_files.dart';

/// Speak instead of typing: a microphone in the question fields (AI Playground's dictation.py).
///
/// It uses the desktop's own dictation (Omarchy: `omarchy-dictation`, the backend chosen in
/// Setup › Defaults › Dictation, e.g. Superwhisper or Voxtype). A click puts the cursor in the field
/// and starts the dictation; the backend writes what is said at the cursor; a second click stops it.
/// Maprisma Playground records nothing itself and sends nothing anywhere; where the words are
/// recognised (on this PC or a cloud service) is the backend's own setting. With no backend set up
/// yet, a click explains how to set one up; away from Omarchy there is no microphone.

/// A backend's name as `omarchy-default-dictation` prints it.
final dictationName = RegExp(r'^[a-z0-9][a-z0-9-]{0,40}$');

/// Omarchy's menu: Setup › Defaults › Dictation.
const dictationSetupRoute = 'setup.default.dictation';

const dictationSetupTitle = 'Set up dictation';
const dictationSetupText =
    "To speak instead of typing, choose a dictation program first: in Omarchy's menu under Setup › "
    'Defaults › Dictation, pick Superwhisper or Voxtype; Omarchy installs and sets it up. Then click '
    'the microphone again.';
const dictationSetupButton = 'Open dictation setup';
const dictationNotSetUpTip =
    'Speak instead of typing: no dictation program is set up yet. Click for how to set one up.';
const dictationTip = 'Speak instead of typing: {0} writes what you say at the cursor. Click again to stop.';

String dictationDisplayName(String name) => const {'superwhisper': 'Superwhisper', 'voxtype': 'Voxtype'}[name] ?? name;

/// An executable file of that name in a PATH folder, or null.
String? onPath(String command, [Map<String, String>? environment]) {
  final path = (environment ?? Platform.environment)['PATH'] ?? '';
  for (final dir in path.split(':')) {
    if (dir.isEmpty || !p.isAbsolute(dir)) continue;
    final file = p.join(dir, command);
    if (FileSystemEntity.isFileSync(file) && executableByUser(file)) return file;
  }
  return null;
}

/// Runs a program (argv, no shell) and gives (exit code, stdout).
typedef DictationRun = Future<(int, String)> Function(List<String> argv);

/// Starts a program (argv, no shell) without waiting for it.
typedef DictationSpawn = void Function(List<String> argv);

/// Bytes read from a helper's answer; more ends it.
const dictationOutputLimit = 64 * 1024;

/// Run argv (no shell) and read at most [limit] bytes of its output within [timeout]; null when it
/// cannot start, takes too long or says too much (then it is killed). Undecodable bytes are
/// replaced, so a broken helper cannot throw here.
Future<(int, String)?> readOutput(
  List<String> argv, {
  Duration timeout = const Duration(seconds: 3),
  int limit = dictationOutputLimit,
}) async {
  final Process process;
  try {
    process = await Process.start(argv.first, argv.sublist(1));
  } on Object {
    return null;
  }
  process.stdin.close().ignore();
  process.stderr.drain<void>().ignore();
  final bytes = BytesBuilder(copy: false);
  final done = Completer<bool>(); // true: the output ended within the limit
  final reading = process.stdout.listen(
    (chunk) {
      bytes.add(chunk);
      if (bytes.length > limit && !done.isCompleted) done.complete(false);
    },
    onDone: () => done.isCompleted ? null : done.complete(true),
    onError: (Object _) => done.isCompleted ? null : done.complete(false),
    cancelOnError: true,
  );
  final deadline = DateTime.now().add(timeout);
  try {
    final ended = await done.future.timeout(timeout, onTimeout: () => false);
    if (!ended) throw TimeoutException('helper');
    final left = deadline.difference(DateTime.now());
    final code = await process.exitCode.timeout(left.isNegative ? Duration.zero : left);
    return (code, utf8.decode(bytes.takeBytes(), allowMalformed: true));
  } on Object {
    process.kill(ProcessSignal.sigkill);
    return null;
  } finally {
    await reading.cancel();
  }
}

Future<(int, String)> _run(List<String> argv) async => await readOutput(argv) ?? (-1, '');

void _spawn(List<String> argv) {
  Process.start(argv.first, argv.sublist(1), mode: ProcessStartMode.detached).ignore();
}

/// The desktop's dictation, as the question fields use it. Tests replace [instance].
final class Dictation {
  Dictation({String? Function(String)? which, DictationRun? run, DictationSpawn? spawn, DateTime Function()? clock})
    : _which = which ?? onPath,
      _runner = run ?? _run,
      _spawner = spawn ?? _spawn,
      _clock = clock ?? DateTime.now;

  static Dictation instance = Dictation();

  final String? Function(String) _which;
  final DictationRun _runner;
  final DictationSpawn _spawner;
  final DateTime Function() _clock;
  DateTime? _askedAt;
  String? _backend;

  /// The desktop has a dictation command to call (Omarchy).
  bool get supported {
    try {
      return _which('omarchy-dictation') != null && _which('omarchy-default-dictation') != null;
    } on Object {
      return false; // a broken PATH: no microphone, never a window that cannot build
    }
  }

  /// The one microphone that is recording (one recorder for the whole app): how to stop it.
  void Function()? _active;

  /// A microphone starts: the one recording in another field stops first.
  void claim(void Function() stop) {
    final other = _active;
    if (other != null && other != stop) other(); // == : tear-offs of one button's method are equal
    _active = stop;
  }

  /// A microphone stopped (only its own claim is let go).
  void release(void Function() stop) {
    if (_active == stop) _active = null;
  }

  /// The app closes: a dictation it started must not go on writing into another window.
  void stopAll() {
    final active = _active;
    _active = null;
    active?.call();
  }

  /// The configured backend whose own program is installed (as Omarchy's key bindings check it),
  /// e.g. "superwhisper", or null; asked at most every 30 s unless [fresh].
  Future<String?> backend({bool fresh = false}) async {
    final now = _clock();
    if (!fresh && _askedAt != null && now.difference(_askedAt!) < const Duration(seconds: 30)) return _backend;
    String? found;
    if (supported) {
      try {
        final (code, out) = await _runner([_which('omarchy-default-dictation')!]);
        final name = out.trim();
        if (code == 0 &&
            dictationName.hasMatch(name) &&
            _which('omarchy-dictation-$name') != null &&
            _which(name) != null) {
          found = name;
        }
      } on Object {
        found = null;
      }
    }
    _askedAt = now;
    _backend = found;
    return found;
  }

  /// omarchy-dictation start|stop|toggle, without a shell, not waited for; nothing away from
  /// Omarchy. The programs are started by the path found on PATH, not looked up again.
  void act(String action) {
    if (!const ['start', 'stop', 'toggle'].contains(action) || !supported) return;
    _spawner([_which('omarchy-dictation')!, action]);
  }

  /// Superwhisper says whether it records; other backends: unknown (null).
  Future<bool?> recording(String? name) async {
    final program = _which('superwhisper');
    if (name != 'superwhisper' || program == null || !supported) return null;
    try {
      final (_, out) = await _runner([program, 'status']);
      final data = jsonDecode(out);
      return data is Map ? data['phase'] == 'recording' : null;
    } on Object {
      return null;
    }
  }

  /// Omarchy's menu at Setup › Defaults › Dictation (argv, not waited for).
  void openSetup() {
    final menu = _which('omarchy-menu');
    if (menu != null && supported) _spawner([menu, 'summon', dictationSetupRoute]);
  }
}
