import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/app.dart';
import 'package:maprisma_playground/backend.dart';
import 'package:maprisma_playground/window.dart';
import 'package:maprisma_playground/work.dart';

/// Rule 5a for the Playground: Esc on a tab never stops running work; it hides the window then.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('running: hide; nothing running: close', () {
    expect(escWindow(running: true), EscWindow.hide);
    expect(escWindow(running: false), EscWindow.close);
  });

  test('Work: any watched source that runs counts, until it is unwatched', () {
    final game = Object(), automaton = Object();
    var playing = false;
    Work.watch(game, () => false);
    Work.watch(automaton, () => playing);
    addTearDown(() {
      Work.unwatch(game);
      Work.unwatch(automaton);
    });
    expect(Work.running, isFalse);
    playing = true;
    expect(Work.running, isTrue);
    Work.unwatch(automaton);
    expect(Work.running, isFalse);
  });

  test('an idle core is not busy', () {
    expect(Backend.idle().busy, isFalse);
  });

  test('Esc on a tab: the runner gets "hide" while work runs, "close" otherwise', () async {
    final calls = <String>[];
    const channel = MethodChannel('maprisma-playground/window');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final owner = Object();
    var running = true;
    Work.watch(owner, () => running);
    addTearDown(() => Work.unwatch(owner));
    closeOrHide();
    await pumpEventQueue();
    expect(calls, ['hide']);
    running = false;
    closeOrHide();
    await pumpEventQueue();
    expect(calls, ['hide', 'close']);
  });

  test('--toggle asks "busy": the runner hides while work runs, closes otherwise', () async {
    AppWindow.instance; // its handler answers the runner
    const codec = StandardMethodCodec();
    Future<Object?> ask() async {
      final reply = Completer<Object?>();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'maprisma-playground/window',
        codec.encodeMethodCall(const MethodCall('busy')),
        (data) => reply.complete(codec.decodeEnvelope(data!)),
      );
      return reply.future;
    }

    final owner = Object();
    var running = true;
    Work.watch(owner, () => running);
    addTearDown(() => Work.unwatch(owner));
    expect(await ask(), isTrue);
    running = false;
    expect(await ask(), isFalse);
  });

  test('busy marker: the pid while work runs, gone when it stops', () {
    expect(busyMarkerPath({}), isNull);
    expect(busyMarkerPath({'XDG_RUNTIME_DIR': '/run/user/1000'}), '/run/user/1000/maprisma-playground/busy');
    final dir = Directory.systemTemp.createTempSync('busy-marker');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(busyMarkerPath({'XDG_RUNTIME_DIR': dir.path})!);
    final marker = BusyMarker(file.path);
    marker.update(false);
    expect(file.existsSync(), isFalse);
    marker.update(true);
    expect(file.readAsStringSync().trim(), '$pid');
    marker.update(false);
    expect(file.existsSync(), isFalse);
    BusyMarker(null).update(true); // no runtime dir: nothing happens
  });
}
