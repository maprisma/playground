import 'dart:convert';
import 'dart:io';

import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late LookPaths paths;
  setUp(() {
    root = Directory.systemTemp.createTempSync('playground-look-');
    paths = LookPaths(config: '${root.path}/config', state: '${root.path}/state');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('Hyprland is its own desktop', () {
    expect(detectDesktop({'XDG_CURRENT_DESKTOP': 'Hyprland'}), DesktopId.hyprland);
    expect(detectDesktop({'XDG_CURRENT_DESKTOP': 'KDE'}), DesktopId.kde);
    expect(detectDesktop({'XDG_CURRENT_DESKTOP': 'GNOME'}), DesktopId.other);
  });

  test('Hyprland: the colours come from Caelestia\'s scheme', () {
    File('${root.path}/state/maprisma-shell/scheme.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'name': 'dynamic',
        'colours': {
          'primary': '89B4FA', 'surface': '1e1e2e', 'onSurface': 'cdd6f4', 'outline': '585b70',
          'surfaceContainerHighest': '45475a', 'error': 'f38ba8', 'yellow': 'f9e2af',
          'peach': 'fab387', 'green': 'nope',
        },
      }));
    final look = desktopLook(desktop: DesktopId.hyprland, paths: paths);
    expect(look['desktop'], 'hyprland');
    expect(look['colors'], {
      'accent': '#89b4fa', 'background': '#1e1e2e', 'foreground': '#cdd6f4', 'muted': '#585b70',
      'selection': '#45475a', 'red': '#f38ba8', 'yellow': '#f9e2af', 'orange': '#fab387',
    });
    expect(look['is_dark'], isTrue);
  });

  test('Hyprland without Caelestia (or a broken file): no colours, nothing throws', () {
    expect(desktopLook(desktop: DesktopId.hyprland, paths: paths)['colors'], isEmpty);
    File('${root.path}/state/maprisma-shell/scheme.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    expect(desktopLook(desktop: DesktopId.hyprland, paths: paths)['colors'], isEmpty);
  });

  test('state defaults to .local/state next to the config folder', () {
    expect(LookPaths(config: '/home/u/.config').state, '/home/u/.local/state');
    expect(LookPaths.fromEnv({'HOME': '/h', 'XDG_STATE_HOME': '/s'}).state, '/s');
  });

  group('Hyprland rounding (a fake hyprctl, never the session\'s)', () {
    test('parses .int and keeps it in 0–64', () {
      expect(parseHyprRounding('{"option": "decoration:rounding", "int": 15, "set": true }'), 15);
      expect(parseHyprRounding('{"int": 200}'), 64);
      expect(parseHyprRounding('{"int": -3}'), 0);
      expect(parseHyprRounding('{"float": 2.0}'), isNull);
      expect(parseHyprRounding('no json'), isNull);
    });

    test('the look takes hyprctl\'s rounding on Hyprland only', () async {
      final asked = <List<String>>[];
      final hypr = HyprRounding(run: (args, _) async {
        asked.add(args);
        return '{"option": "decoration:rounding", "int": 15, "set": true }';
      });
      expect((await readDesktopLook(desktop: DesktopId.hyprland, paths: paths, hypr: hypr))['rounding'], 15);
      expect(asked, [['-j', 'getoption', 'decoration:rounding']]);
      expect((await readDesktopLook(desktop: DesktopId.kde, paths: paths, hypr: hypr))['rounding'], 8);
      expect((await readDesktopLook(desktop: DesktopId.other, paths: paths, hypr: hypr))['rounding'], isNull);
      expect(asked, hasLength(1));
      expect(desktopLook(desktop: DesktopId.hyprland, paths: paths)['rounding'], isNull);
    });

    test('asks at most every 30 s; a failed answer keeps the last one', () async {
      var now = DateTime(2026);
      var answer = '{"int": 10}';
      var calls = 0;
      final hypr = HyprRounding(clock: () => now, run: (_, _) async {
        calls++;
        return answer;
      });
      expect(await hypr.read(), 10);
      answer = '{"int": 20}';
      now = now.add(const Duration(seconds: 29));
      expect(await hypr.read(), 10);
      expect(calls, 1);
      now = now.add(const Duration(seconds: 2));
      expect(await hypr.read(), 20);
      answer = 'broken';
      now = now.add(const Duration(seconds: 31));
      expect(await hypr.read(), 20);
      expect(calls, 3);
    });

    test('runs hyprctl from the given PATH, and gives up after the timeout', () async {
      final bin = Directory('${root.path}/bin')..createSync();
      final fake = File('${bin.path}/hyprctl')
        ..writeAsStringSync('#!/bin/sh\n[ "\$1 \$2 \$3" = "-j getoption decoration:rounding" ] || exit 2\necho \'{"option": "decoration:rounding", "int": 7, "set": true }\'\n');
      Process.runSync('/bin/chmod', ['755', fake.path]);
      expect(await HyprRounding(environment: {'PATH': bin.path}).read(), 7);
      fake.writeAsStringSync('#!/bin/sh\nexec /bin/sleep 5\n');
      final slow = HyprRounding(environment: {'PATH': bin.path}, timeout: const Duration(milliseconds: 200));
      final watch = Stopwatch()..start();
      expect(await slow.read(), isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(await HyprRounding(environment: {'PATH': '${root.path}/nothing'}).read(), isNull);
    });
  });
}
