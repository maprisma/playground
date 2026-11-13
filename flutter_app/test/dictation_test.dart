import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/theme.dart';
import 'package:maprisma_playground/widgets.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

import 'voice_fake.dart';

/// The microphone in the question fields: only on Omarchy, a set-up hint without a backend,
/// start and stop with a backend, never anything else run.
void main() {
  late List<List<String>> spawned, ran;
  setUp(() {
    setLanguage('en');
    spawned = [];
    ran = [];
  });
  tearDown(() => Dictation.instance = Dictation());

  void omarchy({String backend = '', Set<String> missing = const {}, String status = '{"phase": "recording"}'}) {
    Dictation.instance = Dictation(
      which: (name) => missing.contains(name) ? null : '/usr/bin/$name',
      run: (argv) async {
        ran.add(argv);
        if (argv.first.endsWith('/omarchy-default-dictation')) return backend.isEmpty ? (1, '') : (0, '$backend\n');
        return (0, status);
      },
      spawn: spawned.add,
    );
  }

  Future<TextEditingController> pump(WidgetTester tester) async {
    final controller = TextEditingController(text: 'What is');
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, const {}, 8),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: PromptField(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('away from Omarchy there is no microphone', (tester) async {
    Dictation.instance = Dictation(which: (_) => null, run: (a) async => (0, ''), spawn: spawned.add);
    await pump(tester);
    expect(find.byKey(const ValueKey('dictate')), findsNothing);
  });

  testWidgets('no backend set up: the click explains and runs nothing; Open runs only the setup menu', (tester) async {
    omarchy();
    await pump(tester);
    expect(find.byKey(const ValueKey('dictate')), findsOneWidget);
    expect(find.byTooltip(dictationNotSetUpTip), findsOneWidget);
    // The button sits in the lower right corner of the field.
    final field = tester.getRect(find.byType(TextField)), mic = tester.getRect(find.byKey(const ValueKey('dictate')));
    expect(field.right - mic.right, closeTo(6, 1));
    expect(field.bottom - mic.bottom, closeTo(6, 1));
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pumpAndSettle();
    expect(find.text('Set up dictation'), findsOneWidget);
    expect(spawned, isEmpty);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(spawned, isEmpty);
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open dictation setup'));
    await tester.pumpAndSettle();
    expect(spawned, [
      ['/usr/bin/omarchy-menu', 'summon', 'setup.default.dictation'],
    ]);
  });

  testWidgets('a backend whose program is missing counts as not set up', (tester) async {
    omarchy(backend: 'superwhisper', missing: {'superwhisper'});
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pumpAndSettle();
    expect(find.text('Set up dictation'), findsOneWidget);
    expect(spawned, isEmpty);
  });

  testWidgets('a second click while the program is asked toggles nothing twice and opens one hint', (tester) async {
    final asked = <Completer<(int, String)>>[];
    Dictation.instance = Dictation(
      which: (name) => '/usr/bin/$name',
      run: (argv) {
        final c = Completer<(int, String)>();
        asked.add(c);
        return c.future;
      },
      spawn: spawned.add,
    );
    await pump(tester);
    asked.single.complete((1, '')); // the first look at start: nothing set up
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pump();
    expect(asked, hasLength(2)); // the second click was not asked again
    asked.last.complete((1, ''));
    await tester.pumpAndSettle();
    expect(find.text('Set up dictation'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    // With a backend: two quick clicks toggle once.
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pump();
    asked.last.complete((0, 'voxtype'));
    await tester.pump();
    expect(spawned, [
      ['/usr/bin/omarchy-dictation', 'toggle'],
    ]);
  });

  testWidgets('a click runs exactly omarchy-dictation toggle once, with the cursor at the end of the field', (
    tester,
  ) async {
    omarchy(backend: 'superwhisper');
    final controller = await pump(tester);
    expect(find.byTooltip(trf(dictationTip, ['Superwhisper'])), findsOneWidget);
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pump();
    expect(spawned, [
      ['/usr/bin/omarchy-dictation', 'toggle'],
    ]);
    expect(controller.selection, const TextSelection.collapsed(offset: 7));
    expect(tester.testTextInput.hasAnyClients, isTrue); // the field has the keyboard
    // No state: the next click is the same toggle (Omarchy's dictation stops it when it runs).
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pump();
    expect(spawned, [
      ['/usr/bin/omarchy-dictation', 'toggle'],
      ['/usr/bin/omarchy-dictation', 'toggle'],
    ]);
    expect(ran.where((a) => a.first.endsWith('/superwhisper')), isEmpty); // no status is polled
  });

  group('the shared voice service (fake maprisma-voice)', () {
    late FakeVoice voice;
    setUp(() async => voice = await FakeVoice.create());
    tearDown(() => voice.dispose());

    testWidgets('not ready: no voice mic; on Omarchy its dictation key stays', (tester) async {
      voice.status(ready: false);
      omarchy(backend: 'voxtype');
      await pump(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey('voice-mic')), findsNothing);
      expect(find.byKey(const ValueKey('dictate')), findsOneWidget);
    });

    testWidgets('ready: its mic replaces Omarchy\'s, in the lower right corner; the words go in at the cursor', (tester) async {
      omarchy(backend: 'voxtype');
      final controller = await pump(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey('dictate')), findsNothing);
      final mic = find.byKey(const ValueKey('voice-mic'));
      expect(mic, findsOneWidget);
      final field = tester.getRect(find.byType(TextField)), button = tester.getRect(mic);
      expect(field.right - button.right, closeTo(4, 1));
      expect(field.bottom - button.bottom, closeTo(4, 1));
      await tester.tap(mic);
      await settle(tester);
      expect(find.text('hello'), findsOneWidget);
      await tester.tap(mic);
      await settle(tester);
      expect(controller.text, 'What is hello world');
      expect(find.byKey(const ValueKey('voice-heard')), findsNothing);
      expect(voice.args.last, 'dictate --events --release --app-id com.maprisma.Playground');
      expect(spawned, isEmpty); // Omarchy's dictation never ran
    });
  });
}
