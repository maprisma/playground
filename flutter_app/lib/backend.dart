import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

/// An error the core replied with: `code` (bad_params, not_found, cancelled, failed) and its
/// English message, shown as it is.
final class CoreFailure implements Exception {
  CoreFailure(this.code, this.message);
  final String code;
  final String message;
  bool get cancelled => code == 'cancelled';
  @override
  String toString() => message.isEmpty ? code : message;
}

void _serve((SendPort, Map<String, String>) args) {
  final inbox = ReceivePort();
  final service = CoreService(args.$2, onEvent: args.$1.send);
  args.$1.send(inbox.sendPort);
  inbox.listen((message) async {
    if (message == null) {
      await service.handleAsync('null');
      args.$1.send('{"closed":true}');
      inbox.close();
    } else if (message is String) {
      final reply = await service.handleAsync(message);
      if (reply != 'null') args.$1.send(reply);
    }
  });
}

/// A running request: its reply, and a way to stop it (agents, downloads, imports).
final class Job {
  Job._(this.id, this._backend, this.result);
  final int id;
  final Backend _backend;
  final Future<Map<String, dynamic>> result;
  void cancel() => _backend._cancel(id);
}

/// The core in a background isolate, spoken to with protocol frames (docs/protocol.md), as
/// Maprisma Theme does it. Nothing the core does (agents, pictures, hashing) blocks the window.
final class Backend {
  Backend._();
  final _inbox = ReceivePort(), _errors = ReceivePort();
  final _ready = Completer<SendPort>();
  final _closed = Completer<void>();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _listeners = <int, void Function(String event, Map<String, dynamic> data)>{};
  Isolate? _isolate;
  SendPort? _send;
  var _id = 0;
  var _down = false;

  /// A core that never answers (widget tests of the whole window): every request stays pending.
  @visibleForTesting
  Backend.idle() : _idle = true;
  bool _idle = false;

  static Future<Backend> launch() async {
    final b = Backend._();
    b._ready.future.ignore();
    b._inbox.listen(b._receive);
    b._errors.listen((_) => b._fail(CoreFailure('failed', tr("The core stopped."))));
    b._isolate = await Isolate.spawn(
      _serve,
      (b._inbox.sendPort, Map<String, String>.of(Platform.environment)),
      onError: b._errors.sendPort,
      errorsAreFatal: true,
    );
    b._send = await b._ready.future.timeout(const Duration(seconds: 10));
    return b;
  }

  void _receive(dynamic message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    if (message is! String) return;
    final data = jsonDecode(message);
    if (data is! Map<String, dynamic>) return;
    if (data['closed'] == true) {
      if (!_closed.isCompleted) _closed.complete();
      return;
    }
    if (data['event'] case final String event) {
      final id = data['id'];
      if (id is int) _listeners[id]?.call(event, (data['data'] as Map?)?.cast<String, dynamic>() ?? const {});
      return;
    }
    final id = data['id'];
    if (id is! int) return;
    _listeners.remove(id);
    final pending = _pending.remove(id);
    if (pending == null) return;
    if (data['error'] case final Map error) {
      pending.completeError(CoreFailure('${error['code']}', '${error['message'] ?? ''}'));
    } else {
      pending.complete((data['result'] as Map?)?.cast<String, dynamic>() ?? const {});
    }
  }

  /// Start a request; `onEvent` hears its progress and findings until the reply.
  Job start(
    String method, [
    Map<String, dynamic> params = const {},
    void Function(String event, Map<String, dynamic> data)? onEvent,
  ]) {
    final id = ++_id;
    final pending = Completer<Map<String, dynamic>>();
    if (_idle) return Job._(id, this, pending.future);
    if (_down) {
      pending.completeError(CoreFailure('failed', tr("The core is closed.")));
      return Job._(id, this, pending.future);
    }
    _pending[id] = pending;
    if (onEvent != null) _listeners[id] = onEvent;
    _send!.send(jsonEncode({'protocol': 1, 'id': id, 'method': method, 'params': params}));
    return Job._(id, this, pending.future);
  }

  /// A request is waiting for its reply: an agent, a generation, a download, an import, a model
  /// load (Work: Esc then hides the window instead of closing it).
  bool get busy => _pending.isNotEmpty;

  /// A request and its reply.
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) =>
      start(method, params).result;

  void _cancel(int id) {
    if (!_down && _pending.containsKey(id)) _send?.send(jsonEncode({'cancel': id}));
  }

  /// Before the app quits: every job is cancelled, temp folders go, held local models are let go.
  Future<void> shutdown() async {
    if (_down) return;
    _send?.send(null);
    await _closed.future.timeout(const Duration(seconds: 4), onTimeout: () {});
    _fail(CoreFailure('cancelled', tr("The app is closing.")));
  }

  void _fail(CoreFailure error) {
    if (_down) return;
    _down = true;
    for (final p in _pending.values) {
      p.completeError(error);
    }
    _pending.clear();
    _listeners.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _inbox.close();
    _errors.close();
  }
}
