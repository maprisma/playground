import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/app.dart';
import 'package:maprisma_playground/backend.dart';
import 'package:maprisma_playground/contestants.dart';
import 'package:maprisma_playground/pages/chess_page.dart';
import 'package:maprisma_playground/theme.dart';
import 'package:maprisma_playground/widgets.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

/// The window as a whole (app.dart): the header with its tabs and symbols, the Analyze page,
/// keys, F12 and Settings, on a core that never answers.
void main() {
  late Directory home;
  late Settings settings;
  setUp(() {
    setLanguage('en');
    Dictation.instance = Dictation(which: (_) => null); // not Omarchy: no microphone, nothing asked
    home = Directory.systemTemp.createTempSync('playground-shell-');
    settings = Settings(Places(config: '${home.path}/config', data: '${home.path}/data', cache: '${home.path}/cache'));
  });
  tearDown(() {
    ChessSession.disposeAll();
    home.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, {double width = 1400, double radius = 8, List<String> args = const []}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, const {}, radius),
        builder: windowFrame,
        home: Shell(
          settings: settings,
          playground: Playground(Backend.idle()),
          args: args,
          onLookChanged: () {},
          screenshots: '${home.path}/Pictures/Maprisma Playground',
        ),
      ),
    );
    await tester.pump();
  }

  bool lit(WidgetTester tester, String key) => tester.widget<HeaderSymbol>(find.byKey(ValueKey('symbol-$key'))).active;

  testWidgets('Analyze is a header symbol, not a tab; Chess is the first of seven tabs', (tester) async {
    await pump(tester);
    expect(tabs.map((t) => t.$1), ['chess', 'automaton', 'speed', 'duel', 'vision', 'generate', 'local']);
    expect(find.byKey(const ValueKey('tab-analyze')), findsNothing);
    for (final key in ['analyze', 'info', 'settings']) {
      expect(find.byKey(ValueKey('symbol-$key')), findsOneWidget);
      expect(lit(tester, key), isFalse);
    }
    expect(find.text('CHESS'), findsWidgets); // the saved tab's default
  });

  testWidgets('the test tube opens Analyze with Back; Esc goes back to the last tab', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('tab-automaton')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('symbol-analyze')));
    await tester.pump();
    expect(lit(tester, 'analyze'), isTrue);
    expect(find.text('ANALYZE'), findsOneWidget);
    expect(find.byTooltip('Back (Esc)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(lit(tester, 'analyze'), isFalse);
    expect(find.text('AUTOMATON'), findsOneWidget);
    expect(settings.text('playground_tab'), 'automaton'); // Analyze is never remembered as a tab
    // Backspace and the Back button do the same.
    await tester.tap(find.byKey(const ValueKey('symbol-analyze')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.text('AUTOMATON'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('symbol-settings')));
    await tester.pump();
    expect(lit(tester, 'settings'), isTrue);
    await tester.tap(find.byTooltip('Back (Esc)'));
    await tester.pump();
    expect(lit(tester, 'settings'), isFalse);
  });

  testWidgets('Ctrl+1 … Ctrl+7 switch tabs, Ctrl+8 does nothing', (tester) async {
    await pump(tester);
    Future<void> ctrl(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    await ctrl(LogicalKeyboardKey.digit7);
    expect(settings.text('playground_tab'), 'local');
    await ctrl(LogicalKeyboardKey.digit2);
    expect(settings.text('playground_tab'), 'automaton');
    await ctrl(LogicalKeyboardKey.digit8);
    expect(settings.text('playground_tab'), 'automaton');
    await ctrl(LogicalKeyboardKey.digit1);
    expect(settings.text('playground_tab'), 'chess');
  });

  testWidgets('a saved "analyze" falls back to the first tab; --test analyze opens it', (tester) async {
    settings.update({'playground_tab': 'analyze'});
    await pump(tester);
    expect(lit(tester, 'analyze'), isFalse);
    expect(find.text('CHESS'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await pump(tester, args: ['--test', 'analyze']);
    expect(lit(tester, 'analyze'), isTrue);
  });

  group('the tabs fill the header and wrap', () {
    test('fitTabs: one line fills, wrapped lines fill but the last', () {
      expect(fitTabs([50, 50], 200, spacing: 4), [
        [(0, 98.0), (1, 98.0)],
      ]);
      final lines = fitTabs([60, 60, 60, 60], 130, spacing: 4);
      expect(lines.length, 2);
      expect(lines.first.map((t) => t.$2), [63.0, 63.0]);
      expect(lines.last.map((t) => t.$2), [60.0, 60.0]); // wrapped: the last line keeps its own width
      final short = fitTabs([60, 60, 60], 130, spacing: 4);
      expect(short.last, [(2, 60.0)]);
      expect(fitTabs([300], 100, spacing: 4), [
        [(0, 100.0)],
      ]);
    });

    Rect rectOf(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

    testWidgets('wide: one line up to the symbols', (tester) async {
      await pump(tester, width: 1600);
      final first = rectOf(tester, 'tab-chess'), last = rectOf(tester, 'tab-local');
      expect(last.top, first.top);
      expect(rectOf(tester, 'symbol-analyze').left - last.right, closeTo(8, 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow: more lines, full lines fill, symbols in view', (tester) async {
      await pump(tester, width: 720);
      final tops = {for (final t in tabs) rectOf(tester, 'tab-${t.$1}').top};
      expect(tops.length, greaterThan(1));
      final firstLine = [
        for (final t in tabs)
          if (rectOf(tester, 'tab-${t.$1}').top == tops.first) rectOf(tester, 'tab-${t.$1}'),
      ];
      expect(rectOf(tester, 'symbol-analyze').left - firstLine.last.right, closeTo(8, 1));
      final settingsBox = rectOf(tester, 'symbol-settings');
      expect(settingsBox.right, lessThanOrEqualTo(720));
      expect(settingsBox.width, settingsBox.height); // square
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('every tab and page fits the smallest window (720 px)', (tester) async {
    await pump(tester, width: 720);
    for (final t in tabs) {
      await tester.tap(find.byKey(ValueKey('tab-${t.$1}')));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: t.$1);
    }
    for (final key in ['analyze', 'info', 'settings']) {
      await tester.tap(find.byKey(ValueKey('symbol-$key')));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: key);
    }
  });

  testWidgets('Information shows Maprisma Launcher with the other apps', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('symbol-info')));
    await tester.pump();
    expect(find.text('Maprisma Launcher'), findsOneWidget);
    expect(find.text('Apps, shortcuts and updates, with AI package advice'), findsOneWidget);
  });

  testWidgets('Settings: four corner choices and the F12 switch', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('symbol-settings')));
    await tester.pump();
    expect(find.text('F12 saves a screenshot'), findsOneWidget);
    await tester.tap(find.text('Like windows'));
    await tester.pumpAndSettle();
    expect(find.text('Slightly rounded (6 px)'), findsOneWidget);
    expect(find.text('Rounded (12 px)'), findsOneWidget);
    await tester.tap(find.text('Slightly rounded (6 px)'));
    await tester.pumpAndSettle();
    expect(settings.text('corners'), 'slight');
    await tester.tap(find.byKey(const ValueKey('screenshot-key')));
    await tester.pump();
    expect(settings.flag('screenshot_key'), isFalse);
  });

  group('F12', () {
    String shots() => '${home.path}/Pictures/Maprisma Playground';
    List<String> files() => Directory(shots()).existsSync()
        ? (Directory(shots()).listSync().map((f) => f.uri.pathSegments.last).toList()..sort())
        : <String>[];

    Future<void> press(WidgetTester tester, {bool ctrl = false}) async {
      await tester.runAsync(() async {
        if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.f12);
        if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        // The picture is drawn and encoded off the test's fake clock.
        for (var i = 0; i < 50 && files().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('saves a private PNG, asks for a note and writes it beside the picture', (tester) async {
      await pump(tester);
      await press(tester);
      final saved = files();
      expect(saved, hasLength(1));
      expect(saved.single, matches(RegExp(r'^maprisma-playground-\d{8}-\d{6}\.png$')));
      final png = File('${shots()}/${saved.single}');
      expect(png.readAsBytesSync().take(4), [0x89, 0x50, 0x4e, 0x47]);
      expect(FileStat.statSync(png.path).mode & 0x1ff, 0x180);
      expect(FileStat.statSync(shots()).mode & 0x1ff, 0x1c0);
      expect(find.text('Screenshot saved'), findsOneWidget);
      expect(find.textContaining('Saved as '), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('screenshot-note')), 'The gear is cut off');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(files(), [saved.single, saved.single.replaceFirst('.png', '.txt')]);
      expect(
        File('${shots()}/${saved.single.replaceFirst('.png', '.txt')}').readAsStringSync(),
        'The gear is cut off\n',
      );
    });

    testWidgets('F12 while the note is asked for opens no second dialog; Esc keeps the note', (tester) async {
      await pump(tester);
      await press(tester);
      await tester.enterText(find.byKey(const ValueKey('screenshot-note')), 'Twice?');
      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.f12);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(find.text('Screenshot saved'), findsOneWidget);
      expect(files(), hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.text('Screenshot saved'), findsNothing);
      expect(files(), hasLength(2));
      expect(File('${shots()}/${files().last}').readAsStringSync(), 'Twice?\n');
    });

    testWidgets('no note, no .txt; Ctrl+F12 and a switched-off key save nothing', (tester) async {
      await pump(tester);
      await press(tester);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(files(), hasLength(1));
      await press(tester, ctrl: true);
      expect(find.text('Screenshot saved'), findsNothing);
      settings.update({'screenshot_key': false});
      await press(tester);
      expect(files(), hasLength(1));
      expect(find.text('Screenshot saved'), findsNothing);
    });
  });

  group('corners in three sizes', () {
    test('slight is 6; the sizes follow the radius; Square squares all', () {
      expect(cornerRadius('slight', 20), 6);
      expect(cornerRadius('rounded', null), 12);
      expect(cornerRadius('square', 10), 0);
      expect(cornerRadius('windows', 10), 10);
      expect(cornerRadius('nonsense', null), 12);
      const big = Corners(14), square = Corners(0), slight = Corners(6);
      expect([big.radius, big.control, big.small, big.board], [14, 8, 4, 12]);
      expect([slight.control, slight.small], [6, 4]);
      expect([square.radius, square.control, square.small, square.board], [0, 0, 0, 0]);
    });

    Future<double> buttonRadius(WidgetTester tester, double radius) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark, const {}, radius),
          home: const Scaffold(
            body: Center(child: SmallButton('Step', onPressed: _nothing)),
          ),
        ),
      );
      await tester.pumpAndSettle(); // MaterialApp fades to a new theme
      final material = tester.widget<Material>(
        find.descendant(of: find.byType(OutlinedButton), matching: find.byType(Material)).first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      return (shape.borderRadius as BorderRadius).topLeft.x;
    }

    testWidgets('buttons take min(radius, 8), Square 0, and stay 22 px high', (tester) async {
      expect(await buttonRadius(tester, 12), 8);
      expect(tester.getSize(find.byType(OutlinedButton)).height, controlHeight);
      expect(await buttonRadius(tester, 6), 6);
      expect(await buttonRadius(tester, 0), 0);
    });

    testWidgets('the theme gives check boxes, progress bars and tooltips their size', (tester) async {
      final theme = appTheme(Brightness.dark, const {}, 12);
      expect((theme.checkboxTheme.shape! as RoundedRectangleBorder).borderRadius, BorderRadius.circular(4));
      expect(theme.progressIndicatorTheme.borderRadius, BorderRadius.circular(4));
      expect((theme.tooltipTheme.decoration! as BoxDecoration).borderRadius, BorderRadius.circular(8));
      expect((theme.dialogTheme.shape! as RoundedRectangleBorder).borderRadius, BorderRadius.circular(12));
      expect(appTheme(Brightness.dark, const {}, 0).sliderTheme.thumbShape, isA<KnobShape>());
      expect((appTheme(Brightness.dark, const {}, 0).sliderTheme.thumbShape! as KnobShape).square, isTrue);
      expect((theme.sliderTheme.thumbShape! as KnobShape).square, isFalse);
    });
  });
}

void _nothing() {}
