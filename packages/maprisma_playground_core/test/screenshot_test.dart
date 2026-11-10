import 'dart:io';

import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// F12 screenshots (AI Playground's tests/test_screenshot.py): new names only, notes next to the
/// picture, no file for an empty note, never through a link, private files and folder.
void main() {
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('playground-shot-'));
  tearDown(() => folder.deleteSync(recursive: true));

  int mode(String path) => FileStat.statSync(path).mode & 0x1ff;

  test('free name never reuses a picture or a note', () {
    final where = folder.path;
    final first = freeScreenshotName(where, '20261110-120000');
    expect(p.basename(first), 'maprisma-playground-20261110-120000.png');
    File(first).writeAsBytesSync([1]);
    final second = freeScreenshotName(where, '20261110-120000');
    expect(p.basename(second), 'maprisma-playground-20261110-120000-2.png');
    File(p.join(where, 'maprisma-playground-20261110-120000-2.txt')).writeAsStringSync('note');
    expect(p.basename(freeScreenshotName(where, '20261110-120000')), 'maprisma-playground-20261110-120000-3.png');
    // A link that points nowhere takes its name too.
    Link(p.join(where, 'maprisma-playground-20261110-120000-3.png')).createSync(p.join(where, 'gone'));
    expect(p.basename(freeScreenshotName(where, '20261110-120000')), 'maprisma-playground-20261110-120000-4.png');
  });

  test('the stamp is the local date and time', () {
    expect(screenshotStamp(DateTime(2026, 1, 2, 3, 4, 5)), '20260102-030405');
  });

  test('the note goes next to the picture, none when empty, never over a file', () {
    final picture = p.join(folder.path, 'maprisma-playground-1.png');
    expect(saveScreenshotNote(picture, '   '), isNull);
    expect(File(p.setExtension(picture, '.txt')).existsSync(), isFalse);
    final note = saveScreenshotNote(picture, ' The gear is cut off ')!;
    expect(File(note).readAsStringSync(), 'The gear is cut off\n');
    expect(mode(note), 0x180);
    expect(() => saveScreenshotNote(picture, 'again'), throwsA(isA<FileSystemException>()));
    expect(File(note).readAsStringSync(), 'The gear is cut off\n');
  });

  test('a note is cut at its limit', () {
    final picture = p.join(folder.path, 'long.png');
    final note = saveScreenshotNote(picture, 'x' * (screenshotNoteLimit + 50))!;
    expect(File(note).readAsStringSync().length, screenshotNoteLimit + 1);
  });

  test('writing never goes through a link', () {
    final target = File(p.join(folder.path, 'elsewhere'))..writeAsStringSync('keep');
    final link = p.join(folder.path, 'maprisma-playground-2.png');
    Link(link).createSync(target.path);
    expect(() => writeNewPrivate(link, [1, 2, 3]), throwsA(isA<FileSystemException>()));
    expect(target.readAsStringSync(), 'keep');
  });

  test('a screenshot is a new private file in a private folder', () {
    final where = p.join(folder.path, 'Pictures', 'Maprisma Playground');
    final at = DateTime(2026, 11, 10, 12, 0, 0);
    final first = saveScreenshot(where, [0x89, 0x50, 0x4e, 0x47], at: at);
    expect(p.basename(first), 'maprisma-playground-20261110-120000.png');
    expect(mode(where), 0x1c0);
    expect(mode(first), 0x180);
    expect(File(first).readAsBytesSync(), [0x89, 0x50, 0x4e, 0x47]);
    final second = saveScreenshot(where, [1], at: at);
    expect(p.basename(second), 'maprisma-playground-20261110-120000-2.png');
    expect(File(first).readAsBytesSync(), [0x89, 0x50, 0x4e, 0x47]);
  });

  test('the folder: XDG_PICTURES_DIR from user-dirs.dirs, else ~/Pictures', () {
    final home = folder.path;
    expect(screenshotFolder({'HOME': home}), p.join(home, 'Pictures', 'Maprisma Playground'));
    Directory(p.join(home, '.config')).createSync();
    File(p.join(home, '.config', 'user-dirs.dirs')).writeAsStringSync('XDG_PICTURES_DIR="\$HOME/Bilder"\n');
    expect(screenshotFolder({'HOME': home}), p.join(home, 'Bilder', 'Maprisma Playground'));
    File(p.join(home, '.config', 'user-dirs.dirs')).writeAsStringSync('XDG_PICTURES_DIR="\$HOME/"\n');
    expect(screenshotFolder({'HOME': home}), p.join(home, 'Pictures', 'Maprisma Playground'));
  });

  test('the dialog names the file with ~ for the home folder', () {
    expect(homeShort('/home/u/Pictures/a.png', {'HOME': '/home/u'}), '~/Pictures/a.png');
    expect(homeShort('/home/other/a.png', {'HOME': '/home/u'}), '/home/other/a.png');
  });

  test('the setting is on by default and stays compatible', () {
    final settings = Settings(Places(config: p.join(folder.path, 'c'), data: folder.path, cache: folder.path));
    expect(settings.flag('screenshot_key'), isTrue);
    settings.update({'screenshot_key': false, 'corners': 'slight'});
    expect(settings.flag('screenshot_key'), isFalse);
    expect(settings.text('corners'), 'slight');
    for (final old in ['windows', 'rounded', 'square']) {
      settings.update({'corners': old});
      expect(settings.text('corners'), old);
    }
  });
}
