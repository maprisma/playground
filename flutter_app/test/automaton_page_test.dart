import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/app.dart';
import 'package:maprisma_playground/pages/automaton_page.dart';
import 'package:maprisma_playground/theme.dart';
import 'package:maprisma_playground_core/src/settings.dart';

void main() {
  late Directory home;
  late Settings settings;
  setUp(() {
    home = Directory.systemTemp.createTempSync('playground-test-');
    settings = Settings(Places(config: '${home.path}/config', data: '${home.path}/data', cache: '${home.path}/cache'));
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final host = Host(settings: settings, toast: (_) {}, show: (_) {});
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark, const {}, 8),
      home: Scaffold(body: AutomatonPage(host: host, active: true)),
    ));
    await tester.pump();
  }

  testWidgets('starts filled, Play runs generations, Pause stops them', (tester) async {
    await pump(tester);
    expect(find.textContaining('Generation 0'), findsOneWidget);
    expect(find.textContaining(RegExp(r'[1-9][0-9]* alive')), findsOneWidget);
    await tester.tap(find.text('Play'));
    await tester.pump(const Duration(milliseconds: 1050)); // 10 per second
    expect(find.text('Pause'), findsOneWidget);
    expect(find.textContaining(RegExp(r'Generation (5|10)\b')), findsOneWidget);
    await tester.tap(find.text('Pause'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('Clear empties, Step counts, a typed rule is kept', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(find.textContaining('0 alive'), findsOneWidget);
    await tester.tap(find.text('Step'));
    await tester.pump();
    expect(find.textContaining('Generation 1'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'b36/s23');
    await tester.tap(find.text('Use rule'));
    await tester.pump();
    expect(settings.text('automaton_rule'), 'B36/S23');
    expect(find.textContaining('HighLife'), findsOneWidget);
  });

  testWidgets('a rule that is not one is refused', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'nonsense');
    await tester.tap(find.text('Use rule'));
    await tester.pump();
    expect(settings.text('automaton_rule'), 'B3/S23');
  });
}
