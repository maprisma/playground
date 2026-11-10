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
      ['omarchy-default-dictation'],
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

  test('start and stop are argv, only known actions', () {
    final spawned = <List<String>>[];
    final d = make(spawned: spawned);
    d.act('start');
    d.act('rm -rf');
    d.act('stop');
    expect(spawned, [
      ['omarchy-dictation', 'start'],
      ['omarchy-dictation', 'stop'],
    ]);
  });

  test('recording from Superwhisper\'s status; other backends unknown', () async {
    expect(await make(answer: (0, '{"phase": "recording"}')).recording('superwhisper'), isTrue);
    expect(await make(answer: (0, '{"phase": "idle"}')).recording('superwhisper'), isFalse);
    expect(await make(answer: (0, 'not json')).recording('superwhisper'), isNull);
    expect(await make().recording('voxtype'), isNull);
  });

  test('open setup summons Omarchy\'s dictation menu', () {
    final spawned = <List<String>>[];
    make(spawned: spawned).openSetup();
    expect(spawned, [
      ['omarchy-menu', 'summon', 'setup.default.dictation'],
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
}
