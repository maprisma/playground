import 'dart:io';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

class TestEnvironment {
  TestEnvironment() {
    Directory('$home/bin').createSync();
    env = {
      'HOME': home,
      'PATH': '$home/bin',
      'XDG_CONFIG_HOME': '$home/config',
      'XDG_DATA_HOME': '$home/data',
      'XDG_CACHE_HOME': '$home/cache',
    };
    runner = ProcessRunner(environment: env);
  }
  final directory = Directory.systemTemp.createTempSync('maprisma-test-');
  String get home => directory.path;
  late final Map<String, String> env;
  late final ProcessRunner runner;
  String script(
    String name,
    String body, {
    String interpreter = '/usr/bin/python3',
  }) {
    final file = File('$home/bin/$name')
      ..writeAsStringSync('#!$interpreter\n$body\n');
    Process.runSync('/bin/chmod', ['700', file.path]);
    return file.path;
  }

  void file(String relative, String body) {
    final file = File('$home/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
  }

  Future<void> dispose() async {
    await runner.dispose();
    await directory.delete(recursive: true);
  }
}
