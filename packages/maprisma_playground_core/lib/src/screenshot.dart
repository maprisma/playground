import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'private_files.dart';

/// F12: a picture of Maprisma Playground's window, for telling what is wrong (AI Playground's
/// screenshot.py). The picture goes to ~/Pictures/Maprisma Playground/
/// `maprisma-playground-<date>-<time>.png` (never over an older one); the window then names the file
/// and takes an optional note, written next to it as a .txt with the picture's name. Settings ›
/// F12 saves a screenshot turns the key off. Nothing is uploaded and no other program is started:
/// the window draws itself into the picture.

/// Characters of a note: a few sentences, not a document.
const screenshotNoteLimit = 4000;

/// The pictures folder (XDG_PICTURES_DIR from user-dirs.dirs, else ~/Pictures) with
/// "Maprisma Playground" in it.
String screenshotFolder([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? '/';
  final config = env['XDG_CONFIG_HOME'] != null && p.isAbsolute(env['XDG_CONFIG_HOME']!)
      ? env['XDG_CONFIG_HOME']!
      : p.join(home, '.config');
  var pictures = p.join(home, 'Pictures');
  try {
    final text = readRegularNoFollow(p.join(config, 'user-dirs.dirs'), maxBytes: 64 * 1024);
    for (final line in const LineSplitter().convert(text)) {
      final match = RegExp(r'^\s*XDG_PICTURES_DIR\s*=\s*"(.*)"\s*$').firstMatch(line);
      if (match == null) continue;
      final value = match[1]!.replaceFirst(RegExp(r'^\$HOME(?=/|$)'), home);
      // "$HOME/" alone means no pictures folder of its own; anything relative is not one either.
      if (p.isAbsolute(value) && p.normalize(value) != p.normalize(home)) pictures = p.normalize(value);
    }
  } on Object {
    // no user-dirs.dirs: ~/Pictures
  }
  return p.join(pictures, 'Maprisma Playground');
}

/// `<date>-<time>` of a screenshot's name: 20261110-120000.
String screenshotStamp(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year.toString().padLeft(4, '0')}${two(at.month)}${two(at.day)}-'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
}

bool _taken(String path) => FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

/// `maprisma-playground-<stamp>.png`, or -2, -3 … when a picture or a note already has that name
/// (also a link that points nowhere).
String freeScreenshotName(String folder, String stamp) {
  var path = p.join(folder, 'maprisma-playground-$stamp.png');
  var n = 2;
  while (_taken(path) || _taken(p.setExtension(path, '.txt'))) {
    path = p.join(folder, 'maprisma-playground-$stamp-$n.png');
    n++;
  }
  return path;
}

/// The PNG into a new file of its own (0600, the folder 0700 when it is made); returns its path.
String saveScreenshot(String folder, List<int> png, {DateTime? at}) {
  makePrivateFolder(folder);
  final path = freeScreenshotName(folder, screenshotStamp(at ?? DateTime.now()));
  writeNewPrivate(path, png);
  return path;
}

/// The note next to the picture (same name, .txt); no text, no file.
String? saveScreenshotNote(String picture, String text) {
  var note = text.trim();
  if (note.isEmpty) return null;
  if (note.length > screenshotNoteLimit) note = note.substring(0, screenshotNoteLimit);
  final path = p.setExtension(picture, '.txt');
  writeNewPrivate(path, utf8.encode('$note\n'));
  return path;
}

/// The path as the dialog says it: the home folder as ~.
String homeShort(String path, [Map<String, String>? environment]) {
  final home = (environment ?? Platform.environment)['HOME'];
  if (home == null || home.isEmpty || home == '/') return path;
  return path == home || path.startsWith('$home/') ? '~${path.substring(home.length)}' : path;
}
