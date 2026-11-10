import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';

void main() {
  test('private directory is born 0700 and empty', () async {
    final dir = createPrivateTempDirectory();
    addTearDown(() => dir.delete(recursive: true));
    expect(dir.statSync().mode & 511, 448);
    expect(dir.listSync(), isEmpty);
  });
  test(
    'bounded no-follow read rejects links, oversize and non-files',
    () async {
      final e = TestEnvironment();
      addTearDown(e.dispose);
      e.file('config', 'hello');
      expect(readRegularNoFollow('${e.home}/config', maxBytes: 5), 'hello');
      expect(readRegularNoFollow('${e.home}/config', maxBytes: 4), '');
      Link('${e.home}/link').createSync('${e.home}/config');
      expect(readRegularNoFollow('${e.home}/link'), '');
      expect(readRegularNoFollow(e.home), '');
      Process.runSync('/usr/bin/mkfifo', ['${e.home}/fifo']);
      expect(readRegularNoFollow('${e.home}/fifo'), '');
    },
  );
}
