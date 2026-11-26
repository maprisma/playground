import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_playground/app.dart';
import 'package:maprisma_playground/pages/settings_page.dart';
import 'package:maprisma_playground/skin.dart';
import 'package:maprisma_playground/theme.dart';
import 'package:maprisma_playground/widgets.dart';
import 'package:maprisma_ui/window_style.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart' show Places, Settings;
import 'package:path/path.dart' as p;

void main() {
  test('appSkins order and normalizeSkin', () {
    expect(appSkins, ['native', 'synthwave', 'cozy', 'terminal', 'disco', 'zen']);
    for (final s in appSkins) {
      expect(normalizeSkin(s), s);
    }
    expect(normalizeSkin(null), 'native');
    expect(normalizeSkin(''), 'native');
    expect(normalizeSkin('unknown'), 'native');
  });

  test('skinStyle returns exact palettes and null for native', () {
    expect(skinStyle('native'), isNull);
    expect(skinStyle(null), isNull);
    expect(skinStyle('bogus'), isNull);

    final synth = skinStyle('synthwave')!;
    expect(synth.accent, const Color(0xffff2e93));
    expect(synth.borderTint, const Color(0xff00e5ff));
    expect(synth.bgTint, const Color(0xff3a1259));
    expect(synth.windowBg, const Color(0xff130924));
    expect(synth.foreground, const Color(0xfff4eaff));
    expect(synth.borderWidth, 1.5);
    expect(synth.toDesktopColors(), {
      'accent': '#ff2e93',
      'background': '#130924',
      'foreground': '#f4eaff',
    });

    final cozy = skinStyle('cozy')!;
    expect(cozy.accent, const Color(0xfff09a36));
    expect(cozy.borderTint, const Color(0xffe0822a));
    expect(cozy.bgTint, const Color(0xff593012));
    expect(cozy.windowBg, const Color(0xff21150e));
    expect(cozy.foreground, const Color(0xfff5e8d6));
    expect(cozy.borderWidth, 1.25);

    final term = skinStyle('terminal')!;
    expect(term.accent, const Color(0xff2ce868));
    expect(term.borderTint, const Color(0xff22c55e));
    expect(term.bgTint, const Color(0xff0d381a));
    expect(term.windowBg, const Color(0xff09130b));
    expect(term.foreground, const Color(0xffd2fce0));
    expect(term.borderWidth, 1.25);

    final disco = skinStyle('disco')!;
    expect(disco.accent, const Color(0xffd946ef));
    expect(disco.borderTint, const Color(0xfffacc15));
    expect(disco.bgTint, const Color(0xff4c1666));
    expect(disco.windowBg, const Color(0xff1c0c2b));
    expect(disco.foreground, const Color(0xfff8ecff));
    expect(disco.borderWidth, 1.5);

    final zen = skinStyle('zen')!;
    expect(zen.accent, const Color(0xff52b798));
    expect(zen.borderTint, const Color(0xff64c2a4));
    expect(zen.bgTint, const Color(0xff1e3832));
    expect(zen.windowBg, const Color(0xff141d1c));
    expect(zen.foreground, const Color(0xffe2f0ec));
    expect(zen.borderWidth, 1.0);
  });

  test('applySkinToTheme keeps native untouched and skins cards, Look, and borders', () {
    final lightBase = appTheme(Brightness.light, {'background': '#ffffff', 'foreground': '#111111'}, 10);
    expect(identical(applySkinToTheme(lightBase, 'native'), lightBase), isTrue);

    final skinned = appTheme(Brightness.light, {'background': '#ffffff', 'foreground': '#111111'}, 10, skin: 'terminal');
    final st = skinStyle('terminal')!;
    expect(skinned.brightness, Brightness.dark);
    expect(skinned.scaffoldBackgroundColor, st.windowBg);
    expect(skinned.colorScheme.primary, st.accent);
    expect(skinned.colorScheme.onSurface, st.foreground);
    expect(skinned.colorScheme.outlineVariant, st.borderTint.withValues(alpha: 0.42));
    expect(skinned.cardTheme.color, Color.alphaBlend(st.bgTint.withValues(alpha: 0.28), st.windowBg));
    final shape = skinned.cardTheme.shape! as RoundedRectangleBorder;
    expect(shape.side.color, st.borderTint.withValues(alpha: 0.48));
    expect(shape.side.width, st.borderWidth);
    final look = skinned.extension<Look>()!;
    expect(look.bg, st.windowBg);
    expect(look.fg, st.foreground);
    expect(look.accent, st.accent);
    expect(skinned.extension<AppSkinTheme>()?.skin, 'terminal');
  });

  test('skinned theme composes cleanly with withWindowAlpha', () {
    final base = appTheme(Brightness.dark, const {}, 12, skin: 'zen');
    final glassy = withWindowAlpha(base, glassyAlpha);
    expect(glassy.scaffoldBackgroundColor.a, closeTo(glassyAlpha, 1e-6));
    expect(glassy.cardTheme.color!.a, closeTo((1 + glassyAlpha) / 2, 1e-6));
    expect(glassy.colorScheme.surfaceContainerLow.a, closeTo((1 + glassyAlpha) / 2, 1e-6));
    expect(glassy.popupMenuTheme.color!.a, closeTo(1.0, 1e-6));
    expect(glassy.dialogTheme.backgroundColor!.a, closeTo(1.0, 1e-6));
  });

  testWidgets('FoldCard applies active skin tint and border', (tester) async {
    final theme = appTheme(Brightness.dark, const {}, 12, skin: 'cozy');
    final st = skinStyle('cozy')!;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: FoldCard(title: 'Demo', child: Text('Body')),
        ),
      ),
    );
    final container = tester.widget<Container>(find.descendant(of: find.byType(FoldCard), matching: find.byType(Container)).first);
    final deco = container.decoration! as BoxDecoration;
    expect(deco.color, Color.alphaBlend(st.bgTint.withValues(alpha: 0.28), st.windowBg));
    final border = deco.border! as Border;
    expect(border.top.color, st.borderTint.withValues(alpha: 0.48));
    expect(border.top.width, st.borderWidth);
  });

  testWidgets('SettingsPage offers App skin next to Corners and omits skin when Native is chosen', (tester) async {
    final folder = Directory.systemTemp.createTempSync('playground-skin-ui-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final settings = Settings(Places(config: p.join(folder.path, 'c'), data: folder.path, cache: folder.path));
    var lookChanges = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, const {}, 12),
        home: Scaffold(
          body: SettingsPage(
            host: Host(settings: settings, toast: (_) {}, show: (_) {}),
            onBack: () {},
            onLookChanged: () => lookChanges++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('App skin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-skin')));
    await tester.pumpAndSettle();

    for (final label in ['Synthwave', 'Cozy', 'Terminal', 'Disco', 'Zen']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('Disco'));
    await tester.pumpAndSettle();
    expect(settings.text('skin'), 'disco');
    expect(settings.stored('skin'), isTrue);
    expect(lookChanges, 1);

    await tester.tap(find.byKey(const ValueKey('app-skin')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Native'));
    await tester.pumpAndSettle();
    expect(settings.text('skin'), 'native');
    expect(settings.stored('skin'), isFalse);
    expect(lookChanges, 2);
  });
}
