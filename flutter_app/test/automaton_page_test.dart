import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/app.dart';
import 'package:maprisma_playground/pages/automaton_page.dart';
import 'package:maprisma_playground/theme.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

void main() {
  late Directory home;
  late Settings settings;
  setUp(() {
    setLanguage('en');
    home = Directory.systemTemp.createTempSync('playground-test-');
    settings = Settings(Places(config: '${home.path}/config', data: '${home.path}/data', cache: '${home.path}/cache'));
  });
  tearDown(() => home.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final host = Host(settings: settings, toast: (_) {}, show: (_) {});
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, const {}, 8),
        home: Scaffold(body: AutomatonPage(host: host, active: true)),
      ),
    );
    await tester.pump();
  }

  testWidgets('language changes labels while rule and drawing keys stay usable', (tester) async {
    await pump(tester);
    setLanguage('de');
    await pump(tester);
    expect(find.text(tr('Play')), findsOneWidget);
    expect(find.textContaining("Conway's Life"), findsOneWidget);
    expect(find.text(tr('Draw cells')), findsOneWidget);
    await tester.tap(find.text(tr('Clear')));
    await tester.pump();
    expect(find.textContaining('0 lebendig'), findsOneWidget);
    await tester.tap(find.text(tr('Step')));
    await tester.pump();
    expect(find.textContaining('Generation 1'), findsOneWidget);
    setLanguage('en');
  });

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
    expect(find.textContaining('HighLife  B36/S23'), findsOneWidget);
  });

  testWidgets('a rule that is not one is refused', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'nonsense');
    await tester.tap(find.text('Use rule'));
    await tester.pump();
    expect(settings.text('automaton_rule'), 'B3/S23');
  });

  String what(String scenario) => ruleInfo[scenario]!.whatText;

  testWidgets('the text under the heading follows the scenario; an own rule shows the general intro', (tester) async {
    await pump(tester);
    expect(find.text(what("Conway's Life")), findsOneWidget); // the saved one from the start
    await tester.enterText(find.byType(TextField), 'b36/s23');
    await tester.tap(find.text('Use rule'));
    await tester.pump();
    expect(find.text(what('HighLife')), findsOneWidget); // a typed rule that is a named scenario
    await tester.enterText(find.byType(TextField), 'B1/S1');
    await tester.tap(find.text('Use rule'));
    await tester.pump();
    expect(find.textContaining('A cellular automaton: each cell lives or dies'), findsOneWidget);
  });

  testWidgets('a saved scenario explains itself from the start', (tester) async {
    settings.update({'automaton_rule': 'B2/S'});
    await pump(tester);
    expect(find.text(what('Seeds')), findsOneWidget);
  });

  Future<void> openPatternHint(WidgetTester tester) async {
    await tester.tap(find.byTooltip('About this pattern'));
    await tester.pumpAndSettle();
  }

  Future<void> closeHint(WidgetTester tester) async {
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  }

  testWidgets('the second ⓘ with Draw cells follows the scenario', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'b36/s23');
    await tester.tap(find.text('Use rule'));
    await tester.pump();
    await openPatternHint(tester);
    final high = ruleInfo['HighLife']!, draw = patternInfo['draw']!;
    expect(find.text('Draw cells · HighLife'), findsOneWidget);
    expect(find.text(draw.whatText), findsOneWidget);
    expect(find.text(high.watchText), findsOneWidget);
    expect(find.text(high.tryText), findsOneWidget);
    expect(find.text(draw.watchText), findsNothing);
    final links = drawingInfo('HighLife').links;
    expect(find.text('All links (${links.length})'), findsOneWidget);
    await closeHint(tester);
  });

  testWidgets('a Life pattern under another rule says it is made for Conway\'s Life', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Draw cells'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Glider').last);
    await tester.pumpAndSettle();
    await openPatternHint(tester);
    expect(find.text('Good to know'), findsNothing); // Conway's Life: as described
    await closeHint(tester);
    await tester.enterText(find.byType(TextField), 'B2/S');
    await tester.tap(find.text('Use rule'));
    await tester.pump();
    await openPatternHint(tester);
    expect(find.text('GOOD TO KNOW'), findsOneWidget);
    expect(find.textContaining('This pattern is made for Conway\'s Life. Under the rule of “Seeds”'), findsOneWidget);
    await closeHint(tester);
  });

  testWidgets('Read more is one "All links" drop-down that opens a link and stays a list', (tester) async {
    final opened = <String>[];
    final links = ruleInfo["Conway's Life"]!.links;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, const {}, 8),
        home: Scaffold(
          body: Center(child: LinksChoice(links, open: opened.add)),
        ),
      ),
    );
    expect(find.text('All links (${links.length})'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing); // no separate link buttons
    await tester.tap(find.text('All links (${links.length})'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('${links[1].$1}  ↗'));
    await tester.pumpAndSettle();
    expect(opened, [links[1].$2]);
    expect(find.text('All links (${links.length})'), findsOneWidget);
  });

  testWidgets('the controls wrap in groups in a narrow window', (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final host = Host(settings: settings, toast: (_) {}, show: (_) {});
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, const {}, 8),
        home: Scaffold(body: AutomatonPage(host: host, active: true)),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    // A choice and its ⓘ stay on one line.
    final rule = tester.getRect(find.textContaining("Conway's Life  B3/S23"));
    final about = tester.getRect(find.byTooltip('About this rule'));
    expect((about.center.dy - rule.center.dy).abs(), lessThan(4));
    final draw = tester.getRect(find.text('Draw cells'));
    final aboutPattern = tester.getRect(find.byTooltip('About this pattern'));
    expect((aboutPattern.center.dy - draw.center.dy).abs(), lessThan(4));
  });

  testWidgets('the grid paints again for new corners and when the static mixer is left', (tester) async {
    await pump(tester);
    GridPainter painter() =>
        tester.widget<CustomPaint>(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is GridPainter)).painter!
            as GridPainter;
    final first = painter();
    final rounder = GridPainter(first.grid, first.cell, first.look, first.radius + 4, first.ticks, byAge: first.byAge);
    expect(rounder.shouldRepaint(first), isTrue);
    await tester.tap(find.textContaining("Conway's Life  B3/S23"));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr(mixerName)).last);
    await tester.pumpAndSettle();
    expect(first.grid.mixing, isTrue);
    final before = painter().ticks.value;
    await tester.tap(find.text(tr(mixerName)).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('Own rule…')).last);
    await tester.pumpAndSettle();
    expect(first.grid.mixing, isFalse);
    expect(painter().ticks.value, greaterThan(before));
  });
}
