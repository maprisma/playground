import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

/// Entirely in-memory HTTP fixture: never opens a socket.
class FakeClient implements HttpClient {
  final List<FakeRequest> requests = [];
  List<List<int>> chunks = [utf8.encode('{}')];
  int status = 200, length = -1;
  bool closed = false;
  String Function(Uri)? proxy;
  Duration? connectTimeout;
  Completer<HttpClientResponse>? waiting;
  @override
  set findProxy(String Function(Uri)? value) {
    proxy = value;
  }

  @override
  set connectionTimeout(Duration? value) {
    connectTimeout = value;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = FakeRequest(this, method, url);
    requests.add(request);
    return request;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHeaders implements HttpHeaders {
  ContentType? type;
  @override
  set contentType(ContentType? value) {
    type = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRequest implements HttpClientRequest {
  FakeRequest(this.client, this.method, this.uri);
  final FakeClient client;
  @override
  final String method;
  @override
  final Uri uri;
  bool redirects = true;
  final bytes = <int>[];
  @override
  final FakeHeaders headers = FakeHeaders();
  @override
  set followRedirects(bool value) {
    redirects = value;
  }

  @override
  void add(List<int> data) {
    bytes.addAll(data);
  }

  @override
  Future<HttpClientResponse> close() async =>
      client.waiting == null ? FakeResponse(client) : await client.waiting!.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  FakeResponse(this.client);
  final FakeClient client;
  @override
  int get statusCode => client.status;
  @override
  int get contentLength => client.length;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream.fromIterable(client.chunks).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttp extends LocalHttp {
  FakeHttp()
    : super(
        guard: (_) {
          throw StateError('No real HTTP in tests');
        },
      );
  final Map<String, Object?> replies = {};
  final List<(int, String, Object?)> calls = [];
  @override
  Future<dynamic> json(
    int port,
    String path, {
    Object? data,
    String? method,
    int maxBytes = 1024 * 1024,
    Duration timeout = const Duration(seconds: 5),
    CancelToken? cancel,
  }) async {
    cancel?.check();
    calls.add((port, path, data));
    if (!replies.containsKey(path)) {
      throw StateError('No fake response for $path');
    }
    return replies[path];
  }
}
