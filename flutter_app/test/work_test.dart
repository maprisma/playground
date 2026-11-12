import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/app.dart';
import 'package:maprisma_playground/backend.dart';
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
}
