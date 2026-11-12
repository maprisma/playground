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
}
