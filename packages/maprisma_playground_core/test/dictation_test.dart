import 'dart:io';

import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'package:test/test.dart';

/// The microphone in the question fields (AI Playground's tests/test_dictation.py): shown only on
/// Omarchy, a backend only when it and its program are installed, argv only, no shell.
void main() {
  String? all(String name) => '/usr/bin/$name';
  String? none(String name) => null;

  Dictation make({
    String? Function(String)? which,
    (int, String) answer = (0, 'superwhisper\n'),
    List<List<String>>? ran,
    List<List<String>>? spawned,
    DateTime Function()? clock,
  }) => Dictation(
    which: which ?? all,
    run: (argv) async {
      ran?.add(argv);
      return answer;
    },
    spawn: (argv) => spawned?.add(argv),
    clock: clock,
  );

  test('the configured backend is found', () async {
    final ran = <List<String>>[];
    expect(await make(ran: ran).backend(), 'superwhisper');
    expect(ran, [
      ['/usr/bin/omarchy-default-dictation'],
    ]);
  });

  test('no backend configured', () async {
    expect(await make(answer: (1, '')).backend(), isNull);
  });

  test('not Omarchy: no backend, no button', () async {
    final ran = <List<String>>[];
    final d = make(which: none, ran: ran);
    expect(d.supported, isFalse);
    expect(await d.backend(), isNull);
    expect(ran, isEmpty);
  });

  test('an odd backend name is refused', () async {
    expect(await make(answer: (0, '../evil; rm\n')).backend(), isNull);
    expect(await make(answer: (0, 'Superwhisper\n')).backend(), isNull);
  });

  test('a backend without its own program counts as not set up', () async {
    expect(await make(which: (n) => n == 'superwhisper' ? null : '/usr/bin/$n').backend(fresh: true), isNull);
    expect(
      await make(
        which: (n) => n == 'omarchy-dictation-voxtype' ? null : '/usr/bin/$n',
        answer: (0, 'voxtype'),
      ).backend(fresh: true),
      isNull,
    );
  });

  test('asked at most every 30 s, fresh on request', () async {
    var now = DateTime(2026, 11, 10, 12);
    final ran = <List<String>>[];
    final d = make(ran: ran, clock: () => now);
    await d.backend();
    await d.backend();
    expect(ran, hasLength(1));
    await d.backend(fresh: true);
    expect(ran, hasLength(2));
    now = now.add(const Duration(seconds: 31));
    await d.backend();
    expect(ran, hasLength(3));
  });

  test('open setup summons Omarchy\'s dictation menu', () {
    final spawned = <List<String>>[];
    make(spawned: spawned).openSetup();
    expect(spawned, [
      ['/usr/bin/omarchy-menu', 'summon', 'setup.default.dictation'],
    ]);
    final nothing = <List<String>>[];
    make(which: none, spawned: nothing).openSetup();
    expect(nothing, isEmpty);
  });

  test('names as shown', () {
    expect(dictationDisplayName('superwhisper'), 'Superwhisper');
    expect(dictationDisplayName('voxtype'), 'Voxtype');
    expect(dictationDisplayName('other'), 'other');
  });

  test('onPath finds only executable files in absolute PATH folders', () {
    final dir = Directory.systemTemp.createTempSync('dictation-path-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/tool').writeAsStringSync('#!/bin/sh\n');
    expect(onPath('tool', {'PATH': dir.path}), isNull); // not executable
    Process.runSync('/bin/chmod', ['755', '${dir.path}/tool']);
    expect(onPath('tool', {'PATH': 'relative:${dir.path}'}), '${dir.path}/tool');
    expect(onPath('missing', {'PATH': dir.path}), isNull);
  });

  test('its texts are in all 8 languages', () {
    for (final text in [
      dictationTip,
      dictationNotSetUpTip,
      dictationSetupTitle,
      dictationSetupText,
      dictationSetupButton,
    ]) {
      for (final code in languageCodes.where((c) => c != 'en')) {
        expect(hasTranslation(code, text), isTrue, reason: '$code: $text');
      }
    }
  });

  group('helper output is read bounded', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('dictation-helper-'));
    tearDown(() => dir.deleteSync(recursive: true));

    String script(String body) {
      final file = File('${dir.path}/helper-${body.hashCode.abs()}')..writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('/bin/chmod', ['755', file.path]);
      return file.path;
    }

    test('a normal answer', () async {
      expect(await readOutput([script('echo superwhisper')]), (0, 'superwhisper\n'));
    });

    test('too much output is cut off and the helper ended', () async {
      final watch = Stopwatch()..start();
      expect(await readOutput([script('while :; do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done')]), isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a helper that takes too long is ended at the deadline', () async {
      final watch = Stopwatch()..start();
      expect(await readOutput([script('exec sleep 30')], timeout: const Duration(milliseconds: 300)), isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a helper that closes its output but keeps running counts as too slow', () async {
      expect(
        await readOutput([script('exec >/dev/null; sleep 30')], timeout: const Duration(milliseconds: 300)),
        isNull,
      );
    });

    test('undecodable bytes are replaced, never thrown', () async {
      final answer = await readOutput([script(r"printf 'super\377\376whisper'")]);
      expect(answer!.$1, 0);
      expect(answer.$2, contains('�'));
    });

    test('a program that cannot start gives nothing', () async {
      expect(await readOutput(['${dir.path}/missing']), isNull);
    });
  });

  test('a broken PATH lookup means no microphone, not an error', () {
    expect(make(which: (_) => throw const FileSystemException('broken')).supported, isFalse);
  });

  test('toggle runs exactly omarchy-dictation toggle (argv, the path found) once; nothing away from Omarchy', () {
    final spawned = <List<String>>[];
    make(which: (n) => '/opt/omarchy/bin/$n', spawned: spawned).toggle();
    expect(spawned, [
      ['/opt/omarchy/bin/omarchy-dictation', 'toggle'],
    ]);
    final nothing = <List<String>>[];
    // omarchy-menu is there, omarchy-dictation is not: not Omarchy's dictation.
    final away = make(which: (n) => n.startsWith('omarchy-dictation') ? null : '/usr/bin/$n', spawned: nothing);
    away.toggle();
    away.openSetup();
    expect(nothing, isEmpty);
  });

  test('the backend is asked by the path found', () async {
    final ran = <List<String>>[];
    await make(which: (n) => '/opt/omarchy/bin/$n', ran: ran).backend();
    expect(ran, [
      ['/opt/omarchy/bin/omarchy-default-dictation'],
    ]);
  });
}
