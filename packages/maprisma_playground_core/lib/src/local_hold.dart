import 'dart:async';
import 'dart:io';
import 'agents.dart';
import 'local_llm.dart';
import 'loopback.dart';
import 'netfetch.dart';
import 'runner.dart';

Map<String, List<String>> iniSections(String text) {
  final headers = RegExp(
    r'^\[([^\]\n]{1,120})\][ \t]*\r?$',
    multiLine: true,
  ).allMatches(text).toList();
  final result = <String, List<String>>{};
  for (var i = 0; i < headers.length; i++) {
    result
        .putIfAbsent(headers[i][1]!.trim().toLowerCase(), () => [])
        .add(
          text.substring(
            headers[i].end,
            i + 1 < headers.length ? headers[i + 1].start : text.length,
          ),
        );
  }
  return result;
}

bool hasMmproj(String body) =>
    RegExp(r'^\s*mmproj\s*=\s*\S', multiLine: true).hasMatch(body);
const localServices = {
  'llamacpp': 'llama-server',
  'ollama': 'ollama',
  'vllm': 'vllm',
  'jan': 'jan',
  'koboldcpp': 'koboldcpp',
};
String readyPath(String runtime) =>
    const {
      'llamacpp': '/health',
      'ollama': '/api/version',
      'koboldcpp': '/api/v1/model',
    }[runtime] ??
    '/v1/models';
Future<bool?> seesPictures(
  LocalHttp http,
  String runtime,
  String model, {
  required Map<String, String> environment,
  int? port,
  CancelToken? cancel,
}) async {
  try {
    if (runtime == 'llamacpp' || runtime == 'llama.cpp') {
      final text = readConfig(
        '${environment['HOME'] ?? '/'}/.config/llama.cpp/models.ini',
        maxBytes: 1024 * 1024,
      );
      var name = model.trim().toLowerCase();
      if (name.endsWith('.gguf')) name = name.substring(0, name.length - 5);
      final bodies = iniSections(text)[name];
      return bodies?.every(hasMmproj);
    }
    if (runtime == 'ollama') {
      final reply = await http.json(
        port ?? portOf(runtime),
        '/api/show',
        data: {'model': model},
        timeout: const Duration(seconds: 2),
        cancel: cancel,
      );
      final caps = reply is Map ? reply['capabilities'] : null;
      return caps is List ? caps.contains('vision') : null;
    }
    if (runtime == 'lmstudio') {
      final reply = await http.json(
        port ?? portOf(runtime),
        '/api/v0/models',
        timeout: const Duration(seconds: 2),
        cancel: cancel,
      );
      if (reply is Map && reply['data'] is List) {
        for (final row in reply['data']) {
          if (row is Map &&
              row['id'].toString().toLowerCase() == model.toLowerCase()) {
            if (row['type'] == 'vlm') return true;
            if (row['type'] == 'llm') return false;
          }
        }
      }
    }
  } on Cancelled {
    rethrow;
  } on Object {
    /* unknown */
  }
  return null;
}

/// Keeps the server connected between questions; stops only a service started here,
/// after its own connection has closed, and only if no clients remain.
class LocalHold {
  LocalHold(
    this.runtime,
    this.http,
    this.runner, {
    this.serviceExists,
    this.controlService,
    List<int> Function(int)? listeners,
    int Function(int)? clients,
    HttpClient Function()? clientFactory,
    this.pollInterval = const Duration(milliseconds: 500),
  }) : listeners = listeners ?? loopbackListeners,
       clients = clients ?? localClients,
       clientFactory = clientFactory ?? HttpClient.new;
  final bool Function()? serviceExists;
  final Future<bool> Function(bool start)? controlService;
  final List<int> Function(int) listeners;
  final int Function(int) clients;
  final HttpClient Function() clientFactory;
  final Duration pollInterval;
  final String runtime;
  final LocalHttp http;
  final ProcessRunner runner;
  String error = '';
  bool _started = false, _released = false;
  Timer? _timer;
  Future<void>? _releaseFuture;
  HttpClient? _connection;
  Future<void>? _pinging;
  static final Set<LocalHold> _holds = {};
  String get service => localServices[runtime] ?? '';
  bool get _hasService =>
      serviceExists?.call() ??
      (service.isNotEmpty &&
          [
            '${runner.environment['HOME'] ?? '/'}/.config/systemd/user',
            '/etc/systemd/user',
            '/usr/lib/systemd/user',
          ].any((d) => File('$d/$service.service').existsSync()));
  Future<void> open({
    Duration wait = const Duration(seconds: 120),
    CancelToken? cancel,
  }) async {
    _holds.add(this);
    final port = portOf(runtime);
    if (port == 0) {
      error = 'unknown local LLM';
      return;
    }
    try {
      cancel?.check();
      try {
        http.guard(port);
      } on Object {
        // A foreign listener must never trigger start or receive a request.
        if (listeners(port).isNotEmpty) rethrow;
        if (!_hasService) {
          error = 'it is not running and cannot be started from here';
          return;
        }
        final started = controlService != null
            ? await controlService!(true)
            : (await runner.run(
                ['systemctl', '--user', 'start', '$service.service'],
                cancel: cancel,
                timeout: const Duration(seconds: 30),
              )).ok;
        if (!started) {
          error = 'it did not start';
          return;
        }
        _started = true;
      }
      final clock = Stopwatch()..start();
      while (!_released) {
        cancel?.check();
        try {
          await http.json(
            port,
            readyPath(runtime),
            timeout: const Duration(seconds: 2),
            cancel: cancel,
          );
          break;
        } on Cancelled {
          rethrow;
        } on Object {
          if (clock.elapsed >= wait) {
            error = 'it did not answer';
            return;
          }
        }
        await Future<void>.delayed(pollInterval);
      }
      if (_released) {
        error = 'the app is closing';
        await _stopOwn();
        return;
      }
      _connection = clientFactory()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionTimeout = const Duration(seconds: 5);
      await _ping();
      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_ping()),
      );
    } on Cancelled {
      await release();
      rethrow;
    } on Object catch (e) {
      error = e.toString();
      await release();
    } finally {
      if (error.isNotEmpty) await release();
    }
  }

  Future<void> _ping() async {
    if (_released || _pinging != null || _connection == null) return;
    final work = () async {
      try {
        http.guard(portOf(runtime));
        await (() async {
          final req = await _connection!.getUrl(
            Uri.parse(
              'http://127.0.0.1:${portOf(runtime)}${readyPath(runtime)}',
            ),
          );
          req.followRedirects = false;
          final res = await req.close();
          if (res.statusCode < 200 || res.statusCode >= 300) {
            throw StateError('not ready');
          }
          var bytes = 0;
          await for (final chunk in res) {
            bytes += chunk.length;
            if (bytes > 64 * 1024) throw StateError('answer too large');
          }
        })().timeout(const Duration(seconds: 5));
      } on Object {
        _connection?.close(force: true);
        if (!_released) {
          _connection = clientFactory()..findProxy = ((_) => 'DIRECT');
        }
      }
    }();
    _pinging = work;
    await work;
    _pinging = null;
  }

  Future<void> _stopOwn() async {
    if (_started && clients(portOf(runtime)) == 0) {
      _started = false;
      if (controlService != null) {
        await controlService!(false);
      } else {
        await runner.run([
          'systemctl',
          '--user',
          'stop',
          '$service.service',
        ], timeout: const Duration(seconds: 10));
      }
    }
  }

  Future<void> release() => _releaseFuture ??= _release();
  Future<void> _release() async {
    _released = true;
    _timer?.cancel();
    _connection?.close(force: true);
    if (_pinging != null) await _pinging;
    await _stopOwn();
    _holds.remove(this);
  }

  static Future<void> stopAll() async {
    await Future.wait(_holds.toList().map((h) => h.release()));
  }
}
