import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/theme.dart';
import 'package:maprisma_playground/widgets.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

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

  testWidgets('with Superwhisper: start with the cursor at the end, lit while it records, a second click stops', (
    tester,
  ) async {
    omarchy(backend: 'superwhisper');
    final controller = await pump(tester);
    expect(find.byTooltip(trf(dictationTip, ['Superwhisper'])), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pump();
    expect(spawned, [
      ['/usr/bin/omarchy-dictation', 'start'],
    ]);
    expect(controller.selection, const TextSelection.collapsed(offset: 7));
    expect(
      tester.widget<Icon>(find.descendant(of: find.byKey(const ValueKey('dictate')), matching: find.byType(Icon))).icon,
      Icons.mic,
    );
    // Still recording after a second (Superwhisper's status); a second click stops it.
    await tester.pump(const Duration(seconds: 1));
    expect(find.byIcon(Icons.mic), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pump();
    expect(spawned.last, ['/usr/bin/omarchy-dictation', 'stop']);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
  });

  testWidgets('Superwhisper stopped with its own shortcut switches the button off', (tester) async {
    var status = '{"phase": "recording"}';
    Dictation.instance = Dictation(
      which: (name) => '/usr/bin/$name',
      run: (argv) async => argv.first.endsWith('/omarchy-default-dictation') ? (0, 'superwhisper\n') : (0, status),
      spawn: spawned.add,
    );
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pump();
    expect(find.byIcon(Icons.mic), findsOneWidget);
    status = '{"phase": "idle"}';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(spawned, [
      ['/usr/bin/omarchy-dictation', 'start'],
    ]);
  });

  testWidgets('a second click while the backend is asked starts nothing twice and opens one hint', (tester) async {
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
    // With a backend: two quick clicks start once.
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pump();
    asked.last.complete((0, 'voxtype'));
    await tester.pump();
    expect(spawned, [
      ['/usr/bin/omarchy-dictation', 'start'],
    ]);
    expect(find.byIcon(Icons.mic), findsOneWidget);
  });

  testWidgets('a late status answer of an earlier session does not switch a new one off', (tester) async {
    final status = <Completer<(int, String)>>[];
    Dictation.instance = Dictation(
      which: (name) => '/usr/bin/$name',
      run: (argv) {
        if (argv.first.endsWith('/omarchy-default-dictation')) return Future.value((0, 'superwhisper'));
        final c = Completer<(int, String)>();
        status.add(c);
        return c.future;
      },
      spawn: spawned.add,
    );
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // the first session asks for its status …
    expect(status, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('dictate'))); // … is stopped …
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dictate'))); // … and a new one starts
    await tester.pump();
    expect(find.byIcon(Icons.mic), findsOneWidget);
    status.first.complete((0, '{"phase": "idle"}')); // the old answer comes late
    await tester.pump();
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(spawned.map((a) => a.last), ['start', 'stop', 'start']);
    await tester.tap(find.byKey(const ValueKey('dictate')));
    await tester.pump();
  });

  testWidgets('one recorder: the microphone of another field stops the first one; stopAll stops it', (tester) async {
    omarchy(backend: 'voxtype');
    final a = TextEditingController(), b = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, const {}, 8),
        home: Scaffold(
          body: Column(
            children: [
              PromptField(key: const ValueKey('a'), controller: a),
              PromptField(key: const ValueKey('b'), controller: b),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    Finder mic(String field) =>
        find.descendant(of: find.byKey(ValueKey(field)), matching: find.byKey(const ValueKey('dictate')));
    Finder lit(String field) => find.descendant(of: find.byKey(ValueKey(field)), matching: find.byIcon(Icons.mic));
    await tester.tap(mic('a'));
    await tester.pump();
    expect(lit('a'), findsOneWidget);
    await tester.tap(mic('b'));
    await tester.pump();
    expect(lit('a'), findsNothing);
    expect(lit('b'), findsOneWidget);
    expect(spawned.map((x) => x.last), ['start', 'stop', 'start']);
    Dictation.instance.stopAll(); // the app closes
    await tester.pump();
    expect(lit('b'), findsNothing);
    expect(spawned.map((x) => x.last), ['start', 'stop', 'start', 'stop']);
    // A field that goes away stops its dictation too.
    await tester.tap(mic('a'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(spawned.map((x) => x.last), ['start', 'stop', 'start', 'stop', 'start', 'stop']);
  });
}
