import 'dart:io';

import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Rule 5a: the window's size as the user left it; a broken value is no size (the default).
void main() {
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('playground-size-'));
  tearDown(() => folder.deleteSync(recursive: true));

  test('window_size: [width, height] kept, broken values fall back to none', () {
    final places = Places(config: p.join(folder.path, 'c'), data: folder.path, cache: folder.path);
    final settings = Settings(places);
    expect(settings.get('window_size'), isNull);
    settings.update({
      'window_size': [1000, 720],
    });
    expect(settings.get('window_size'), [1000, 720]);
    for (final broken in [
      [1000],
      ['1000', 720],
      [0, 720],
      [1000, 90000],
      'big',
    ]) {
      settings.update({'window_size': broken});
      expect(settings.get('window_size'), isNull, reason: '$broken');
    }
  });

  test('window_position: [x, y] kept (may be negative), broken values fall back to none', () {
    final places = Places(config: p.join(folder.path, 'c'), data: folder.path, cache: folder.path);
    final settings = Settings(places);
    expect(settings.get('window_position'), isNull);
    settings.update({
      'window_position': [-20, 42],
    });
    expect(settings.get('window_position'), [-20, 42]);
    for (final broken in [
      [1],
      [1.5, 2],
      [200000, 2],
      'left',
    ]) {
      settings.update({'window_position': broken});
      expect(settings.get('window_position'), isNull, reason: '$broken');
    }
  });
}
