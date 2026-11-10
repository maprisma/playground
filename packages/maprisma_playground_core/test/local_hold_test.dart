import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';
import 'fake_http.dart';

void main() {
  late TestEnvironment e;
  setUp(() => e = TestEnvironment());
  tearDown(() async {
    await LocalHold.stopAll();
    await e.dispose();
  });
  test('hold starts once, waits for readiness, keeps connection, stops own service once', () async {
    var up = false;
    final control = <bool>[];
    final client = FakeClient();
    var probes = 0;
    final http = LocalHttp(
      guard: (_) {
        if (!up) throw StateError('not running');
      },
      clientFactory: () {
        probes++;
        return FakeClient();
      },
    );
    final hold = LocalHold(
      'llamacpp',
      http,
      e.runner,
      serviceExists: () => true,
      listeners: (_) => [],
      clients: (_) => 0,
      controlService: (start) async {
        control.add(start);
        up = start;
        return true;
      },
      clientFactory: () => client,
      pollInterval: Duration.zero,
    );
    await hold.open();
    expect(hold.error, isEmpty);
    expect(control, [true]);
    expect(probes, 1);
    expect(client.requests.single.redirects, isFalse);
    await LocalHold.stopAll();
    await LocalHold.stopAll();
    expect(control, [true, false]);
    expect(client.closed, isTrue);
  });
  test('running service is never stopped by release', () async {
    final http = LocalHttp(guard: (_) {}, clientFactory: () => FakeClient());
    final control = <bool>[];
    final hold = LocalHold(
      'ollama',
      http,
      e.runner,
      clients: (_) => 0,
      controlService: (start) async {
        control.add(start);
        return true;
      },
      clientFactory: () => FakeClient(),
    );
    await hold.open();
    await hold.release();
    expect(control, isEmpty);
  });
  test('service started here stays up if another client is connected', () async {
    var up = false;
    final control = <bool>[];
    final http = LocalHttp(
      guard: (_) {
        if (!up) throw StateError('not running');
      },
      clientFactory: () => FakeClient(),
    );
    final hold = LocalHold(
      'ollama',
      http,
      e.runner,
      serviceExists: () => true,
      listeners: (_) => [],
      clients: (_) => 1,
      controlService: (start) async {
        control.add(start);
        up = start;
        return true;
      },
      clientFactory: () => FakeClient(),
    );
    await hold.open();
    await hold.release();
    expect(control, [true]);
  });
  test('foreign listener is neither asked nor started', () async {
    var called = false;
    final http = LocalHttp(
      guard: (_) => throw StateError('other account'),
      clientFactory: () {
        called = true;
        return FakeClient();
      },
    );
    final hold = LocalHold(
      'llamacpp',
      http,
      e.runner,
      listeners: (_) => [123],
      serviceExists: () => true,
      controlService: (_) async {
        called = true;
        return true;
      },
    );
    await hold.open();
    expect(hold.error, contains('other account'));
    expect(called, isFalse);
  });
  test('not running without a controllable service', () async {
    final http = LocalHttp(guard: (_) => throw StateError('not running'));
    final hold = LocalHold('llamacpp', http, e.runner, listeners: (_) => [], serviceExists: () => false);
    await hold.open();
    expect(hold.error, contains('cannot be started'));
  });
  test('readiness deadline and precancel release hold', () async {
    final http = LocalHttp(guard: (_) {}, clientFactory: () => FakeClient()..status = 503);
    final hold = LocalHold('llamacpp', http, e.runner);
    await hold.open(wait: Duration.zero);
    expect(hold.error, 'it did not answer');
    final token = CancelToken()..cancel();
    final cancelled = LocalHold('llamacpp', http, e.runner);
    await expectLater(cancelled.open(cancel: token), throwsA(isA<Cancelled>()));
  });
}
