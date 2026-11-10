import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'loopback.dart';
import 'runner.dart';

typedef ListenerGuard = void Function(int port);

/// Only literal IPv4 loopback HTTP. No proxies, redirects or unbounded reads.
class LocalHttp {
  LocalHttp({ListenerGuard? guard, HttpClient Function()? clientFactory})
    : guard = guard ?? requireOwnListener,
      clientFactory = clientFactory ?? HttpClient.new;
  final ListenerGuard guard;
  final HttpClient Function() clientFactory;
  final Map<HttpClient, void Function(Object)> _live = {};
  bool _closed = false;
  Future<List<int>> fetch(
    int port,
    String path, {
    Object? data,
    String? method,
    int maxBytes = 1024 * 1024,
    Duration timeout = const Duration(seconds: 5),
    CancelToken? cancel,
  }) async {
    if (_closed) throw StateError('the app is closing');
    if (!path.startsWith('/') || path.startsWith('//') || path.contains('#')) {
      throw ArgumentError('not a local path');
    }
    if (maxBytes < 0) throw ArgumentError('not a byte limit');
    cancel?.check();
    guard(port);
    final client = clientFactory()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = timeout;
    final stopped = Completer<List<int>>();
    void stop(Object error) {
      if (!stopped.isCompleted) stopped.completeError(error);
      client.close(force: true);
    }

    _live[client] = stop;
    final timer = Timer(
      timeout,
      () => stop(TimeoutException('127.0.0.1 did not answer')),
    );
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          if (_live.containsKey(client)) stop(Cancelled());
        }),
      );
    }
    try {
      final work = () async {
        final request = await client.openUrl(
          method ?? (data == null ? 'GET' : 'POST'),
          Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path),
        );
        request.followRedirects = false;
        if (data != null) {
          request.headers.contentType = ContentType.json;
          request.add(utf8.encode(jsonEncode(data)));
        }
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        if (response.contentLength > maxBytes) {
          throw const HttpException('answer too large');
        }
        final bytes = BytesBuilder(copy: false);
        var size = 0;
        await for (final chunk in response) {
          size += chunk.length;
          if (size > maxBytes) throw const HttpException('answer too large');
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      }();
      return await Future.any([work, stopped.future]);
    } finally {
      timer.cancel();
      _live.remove(client);
      client.close(force: true);
    }
  }

  Future<dynamic> json(
    int port,
    String path, {
    Object? data,
    String? method,
    int maxBytes = 1024 * 1024,
    Duration timeout = const Duration(seconds: 5),
    CancelToken? cancel,
  }) async => jsonDecode(
    utf8.decode(
      await fetch(
        port,
        path,
        data: data,
        method: method,
        maxBytes: maxBytes,
        timeout: timeout,
        cancel: cancel,
      ),
      allowMalformed: true,
    ),
  );
  void dispose() {
    _closed = true;
    for (final stop in _live.values.toList()) {
      stop(StateError('the app is closing'));
    }
  }
}
