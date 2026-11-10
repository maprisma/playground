import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final class Cancelled implements Exception {
  @override
  String toString() => 'cancelled';
}

final class CancelToken {
  final Completer<void> _done = Completer<void>();
  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!isCancelled) _done.complete();
  }

  void check() {
    if (isCancelled) throw Cancelled();
  }
}

Map<String, String> dropAgentSessionVars(Map<String, String> env) =>
    Map.of(env)..removeWhere(
      (k, v) =>
          const {
            'CLAUDECODE',
            'CLAUDE_PID',
            'CLAUDE_EFFORT',
            'AI_AGENTS_MAP_NO_PROVIDERS',
          }.contains(k) ||
          k.startsWith('CLAUDE_CODE_'),
    );

final class RunResult {
  const RunResult(this.output, this.ok, {this.reason = ''});
  final List<int> output;
  final bool ok;
  final String reason;
  String get text => utf8.decode(output, allowMalformed: true);
}

/// Linux process-session runner. All streams and exit share one deadline.
final class ProcessRunner {
  ProcessRunner({Map<String, String>? environment})
    : environment = Map.of(environment ?? Platform.environment);
  final Map<String, String> environment;
  final Map<int, Future<void> Function()> _live = {};
  final Set<Future<RunResult>> _pending = {};
  bool _closing = false;
  int get liveCount => _live.length;
  Future<void> dispose() async {
    _closing = true;
    await Future.wait(_live.values.toList().map((kill) => kill()));
    await Future.wait(
      _pending.toList().map(
        (f) => f.then<void>((_) {}, onError: (Object e, StackTrace st) {}),
      ),
    );
  }

  Future<RunResult> run(
    List<String> argv, {
    List<int>? stdin,
    String? cwd,
    Map<String, String>? env,
    int maxBytes = 64 * 1024,
    Duration timeout = const Duration(seconds: 5),
    CancelToken? cancel,
    bool mergeStderr = false,
  }) {
    final future = _run(
      argv,
      stdin: stdin,
      cwd: cwd,
      env: env,
      maxBytes: maxBytes,
      timeout: timeout,
      cancel: cancel,
      mergeStderr: mergeStderr,
    );
    _pending.add(future);
    unawaited(
      future.then(
        (_) => _pending.remove(future),
        onError: (Object e, StackTrace st) => _pending.remove(future),
      ),
    );
    return future;
  }

  Future<RunResult> _run(
    List<String> argv, {
    List<int>? stdin,
    String? cwd,
    Map<String, String>? env,
    required int maxBytes,
    required Duration timeout,
    CancelToken? cancel,
    required bool mergeStderr,
  }) async {
    if (argv.isEmpty || maxBytes < 0 || _closing) {
      return const RunResult([], false, reason: 'stopped');
    }
    cancel?.check();
    final clock = Stopwatch()..start();
    Process proc;
    try {
      proc = await Process.start(
        '/usr/bin/setsid',
        ['--', ...argv],
        workingDirectory: cwd,
        environment: dropAgentSessionVars(env ?? environment)
          ..['NO_COLOR'] = '1',
        includeParentEnvironment: false,
        mode: ProcessStartMode.normal,
        runInShell: false,
      );
    } on Object {
      return const RunResult([], false, reason: 'start failed');
    }
    Future<void>? killing;
    Future<void> kill() => killing ??= () async {
      // setsid execs in place with normal Process.start (the child is not a group leader).
      await Process.run('/bin/kill', ['-KILL', '--', '-${proc.pid}']);
      proc.kill(ProcessSignal.sigkill);
    }();
    _live[proc.pid] = kill;
    final bytes = BytesBuilder(copy: false);
    final stopped = Completer<String>();
    void stop(String why) {
      if (!stopped.isCompleted) stopped.complete(why);
    }

    var count = 0;
    void read(List<int> chunk) {
      final remaining = maxBytes - count;
      if (remaining > 0) {
        bytes.add(
          chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
        );
      }
      count += chunk.length;
      if (count > maxBytes) stop('output limit');
    }

    final outDone = Completer<void>(), errDone = Completer<void>();
    final out = proc.stdout.listen(
      read,
      onDone: () => outDone.complete(),
      onError: (Object e) {
        stop('read failed');
        if (!outDone.isCompleted) outDone.complete();
      },
    );
    final err = proc.stderr.listen(
      mergeStderr ? read : (_) {},
      onDone: () => errDone.complete(),
      onError: (Object e) {
        if (!errDone.isCompleted) errDone.complete();
      },
    );
    // Delivery must never hold up reading, cancellation or the deadline.
    final feed = () async {
      try {
        if (stdin != null) proc.stdin.add(stdin);
        await proc.stdin.close();
      } on Object {
        /* broken pipe */
      }
    }();
    final remaining = timeout - clock.elapsed;
    final timer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => stop('timeout'),
    );
    if (cancel != null) {
      unawaited(cancel.whenCancelled.then((_) => stop('cancelled')));
    }
    if (_closing) stop('stopped');
    final complete = () async {
      final code = await proc.exitCode;
      await Future.wait([outDone.future, errDone.future, feed]);
      return code == 0 ? '' : 'exit failed';
    }();
    String reason;
    try {
      reason = await Future.any([complete, stopped.future]);
      // Reap descendants even if the parent exited successfully with closed pipes.
      await kill();
      await proc.exitCode;
    } finally {
      timer.cancel();
      await out.cancel();
      await err.cancel();
      _live.remove(proc.pid);
    }
    if (cancel?.isCancelled ?? false) throw Cancelled();
    return RunResult(bytes.takeBytes(), reason.isEmpty, reason: reason);
  }
}
