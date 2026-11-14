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

  test('without XDG_CURRENT_DESKTOP: the session\'s other marks', () {
    expect(detectDesktop({'XDG_SESSION_DESKTOP': 'KDE'}), DesktopId.kde);
    expect(detectDesktop({'XDG_CURRENT_DESKTOP': '', 'DESKTOP_SESSION': 'plasma'}), DesktopId.kde);
    expect(detectDesktop({'XDG_SESSION_DESKTOP': 'COSMIC'}), DesktopId.cosmic);
    // the signature counts only with its socket (a stale one stays in systemd's environment)
    expect(detectDesktop({'HYPRLAND_INSTANCE_SIGNATURE': 'abc'}), DesktopId.other);
    final live = {'HYPRLAND_INSTANCE_SIGNATURE': 'abc', 'XDG_RUNTIME_DIR': '${root.path}/run'};
    expect(detectDesktop(live), DesktopId.other);
    File('${root.path}/run/hypr/abc/.socket.sock').createSync(recursive: true);
    expect(detectDesktop(live), DesktopId.hyprland);
    expect(detectDesktop({...live, 'XDG_CURRENT_DESKTOP': 'KDE'}), DesktopId.kde);
    expect(detectDesktop({...live, 'HYPRLAND_INSTANCE_SIGNATURE': '../abc'}), DesktopId.other);
    expect(detectDesktop({'KDE_FULL_SESSION': 'true'}), DesktopId.kde);
    expect(detectDesktop({'XDG_SESSION_DESKTOP': 'gnome'}), DesktopId.other);
    expect(detectDesktop({'XDG_CURRENT_DESKTOP': 'GNOME', 'HYPRLAND_INSTANCE_SIGNATURE': 'abc'}), DesktopId.other);
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
      final gtk = GtkFonts(run: (_, _) async => null);
      expect((await readDesktopLook(desktop: DesktopId.hyprland, paths: paths, hypr: hypr, gtk: gtk))['rounding'], 15);
      expect(asked, [['-j', 'getoption', 'decoration:rounding']]);
      expect((await readDesktopLook(desktop: DesktopId.kde, paths: paths, hypr: hypr, gtk: gtk))['rounding'], 8);
      expect((await readDesktopLook(desktop: DesktopId.other, paths: paths, hypr: hypr, gtk: gtk))['rounding'], isNull);
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

  test('COSMIC 1.x: the theme in v2 (v1 empty), the user\'s before the system\'s', () {
    final cosmic = '${root.path}/config/cosmic';
    void write(String path, String text) => File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    Directory('$cosmic/com.system76.CosmicTheme.Dark/v1').createSync(recursive: true);
    write('$cosmic/com.system76.CosmicTheme.Mode/v1/is_dark', 'true');
    write('$cosmic/com.system76.CosmicTheme.Dark/v2/accent', '(\n    base: "#FF0000FF",\n)'); // v2: hex strings
    write('$cosmic/com.system76.CosmicTheme.Dark/v2/corner_radii', '(\n    radius_s: (4.0, 4.0, 4.0, 4.0),\n)');
    final system = '${root.path}/sys/usr/share/cosmic/com.system76.CosmicTheme.Dark';
    write('$system/v1/accent', '(\n    base: (red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0),\n)');
    write('$system/v2/background', '(\n    base: "#333333FF",\n    component: (\n        on: "#000000FF",\n    ),\n    on: "#FFFFFFFF",\n)');
    final look = desktopLook(desktop: DesktopId.cosmic, paths: LookPaths(config: '${root.path}/config', root: '${root.path}/sys', state: '${root.path}/state'));
    expect(look['colors']['accent'], '#ff0000');
    expect(look['colors']['background'], '#333333');
    expect(look['colors']['foreground'], '#ffffff', reason: 'the top level on, not the component\'s');
    expect(look['rounding'], 4);
  });

  group('fonts', () {
    void write(String path, String text) => File('${root.path}/config/$path')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    LookPaths sys() => LookPaths(config: '${root.path}/config', root: '${root.path}/sys', state: '${root.path}/state');

    test('COSMIC: CosmicTk\'s interface and monospace families (v2 first)', () {
      expect(desktopLook(desktop: DesktopId.cosmic, paths: sys())['fonts'], isEmpty);
      write('cosmic/com.system76.CosmicTk/v1/interface_font', '(\n    family: "Open Sans",\n    weight: Normal,\n)');
      write('cosmic/com.system76.CosmicTk/v1/monospace_font', '(\n    family: "Hack",\n    weight: Normal,\n)');
      expect(desktopLook(desktop: DesktopId.cosmic, paths: sys())['fonts'], {'ui': 'Open Sans', 'mono': 'Hack'});
      write('cosmic/com.system76.CosmicTk/v2/interface_font', '(family: "Inter")');
      expect(desktopLook(desktop: DesktopId.cosmic, paths: sys())['fonts'], {'ui': 'Inter', 'mono': 'Hack'});
    });

    test('KDE: kdeglobals\' font and fixed, the first field', () {
      expect(desktopLook(desktop: DesktopId.kde, paths: paths)['fonts'], isEmpty);
      write('kdeglobals', '[General]\nfixed=Hack,10,-1,5,400,0,0,0,0,0\nfont=Noto Sans,10,-1,5,400,0,0,0,0,0\n');
      expect(desktopLook(desktop: DesktopId.kde, paths: paths)['fonts'], {'ui': 'Noto Sans', 'mono': 'Hack'});
      write('kdeglobals', '[General]\nfont= ,10\nfixed=${'x' * 101}\n');
      expect(desktopLook(desktop: DesktopId.kde, paths: paths)['fonts'], isEmpty);
    });

    test('Hyprland and other: gsettings without the size, asked at most every 30 s', () async {
      final bin = Directory('${root.path}/bin')..createSync();
      final log = '${root.path}/gs.log';
      final fake = File('${bin.path}/gsettings')
        ..writeAsStringSync('#!/bin/sh\necho "\$@" >> "$log"\ncase "\$3" in font-name) echo "\'Noto Sans  10\'";; '
            'monospace-font-name) echo "\'Hack, 10.5\'";; esac\n');
      Process.runSync('/bin/chmod', ['755', fake.path]);
      final gtk = GtkFonts(environment: {'PATH': bin.path});
      final hypr = HyprRounding(run: (_, _) async => null);
      expect((await readDesktopLook(desktop: DesktopId.hyprland, paths: paths, hypr: hypr, gtk: gtk))['fonts'], {'ui': 'Noto Sans', 'mono': 'Hack'});
      expect((await readDesktopLook(desktop: DesktopId.other, paths: paths, hypr: hypr, gtk: gtk))['fonts'], {'ui': 'Noto Sans', 'mono': 'Hack'});
      expect(File(log).readAsLinesSync(), hasLength(2));
      // without gsettings: none
      expect(await GtkFonts(environment: {'PATH': '${root.path}/nothing'}).read(), (null, null));
      expect(desktopLook(desktop: DesktopId.hyprland, paths: paths)['fonts'], isEmpty);
      expect(pangoFamily('JetBrains Mono Nerd Font 12'), 'JetBrains Mono Nerd Font');
      expect(pangoFamily('Hack'), 'Hack');
    });
  });
}
