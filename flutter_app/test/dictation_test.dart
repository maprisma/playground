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
        if (argv.first == 'omarchy-default-dictation') return backend.isEmpty ? (1, '') : (0, '$backend\n');
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
      ['omarchy-menu', 'summon', 'setup.default.dictation'],
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
      ['omarchy-dictation', 'start'],
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
    expect(spawned.last, ['omarchy-dictation', 'stop']);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
  });

  testWidgets('Superwhisper stopped with its own shortcut switches the button off', (tester) async {
    var status = '{"phase": "recording"}';
    Dictation.instance = Dictation(
      which: (name) => '/usr/bin/$name',
      run: (argv) async => argv.first == 'omarchy-default-dictation' ? (0, 'superwhisper\n') : (0, status),
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
      ['omarchy-dictation', 'start'],
    ]);
  });
}
