import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'package:test/test.dart';

class _TranslationCalls extends RecursiveAstVisitor<void> {
  final keys = <String>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (const {'tr', 'trf'}.contains(node.methodName.name) && node.argumentList.arguments.isNotEmpty) {
      final argument = node.argumentList.arguments.first;
      // The parser resolves escapes and adjacent strings, for either quote style.
      if (argument is StringLiteral && argument.stringValue != null) keys.add(argument.stringValue!);
    }
    super.visitMethodInvocation(node);
  }
}

Directory repository() {
  var directory = Directory.current.absolute;
  while (!Directory('${directory.path}/translations/extra').existsSync()) {
    final parent = directory.parent;
    if (parent.path == directory.path) throw StateError('Cannot find repository');
    directory = parent;
  }
  return directory;
}

void main() {
  setUp(() => setLanguage('en'));
  tearDown(() => setLanguage('en'));

  test('all literal translation calls in core and Flutter have seven translations', () {
    final root = repository();
    final missing = <String>[];
    var calls = 0;
    for (final path in ['packages/maprisma_playground_core/lib', 'flutter_app/lib']) {
      for (final file in Directory('${root.path}/$path').listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart') || file.path.endsWith('translations.g.dart')) continue;
        final visitor = _TranslationCalls();
        parseString(content: file.readAsStringSync(), path: file.path).unit.accept(visitor);
        calls += visitor.keys.length;
        for (final key in visitor.keys.toSet()) {
          for (final code in languageCodes.where((c) => c != 'en')) {
            if (!hasTranslation(code, key)) missing.add('${file.path}: $code: ${jsonEncode(key)}');
          }
        }
      }
    }
    expect(calls, greaterThan(500));
    expect(missing, isEmpty, reason: missing.join('\n'));
  });

  test('scanner reads both quote styles, escapes and adjacent strings, ignoring comments', () {
    final visitor = _TranslationCalls();
    parseString(
      content: r'''
      void f() {
        tr('Ask');
        tr("Save " 'game');
        trf('Answer: ' "{0}", ['value']);
        tr('It\'s ready');
        // tr('not a call');
        final data = "tr('also not a call')";
      }
    ''',
    ).unit.accept(visitor);
    expect(visitor.keys, ['Ask', 'Save game', 'Answer: {0}', "It's ready"]);
  });

  test('switching languages changes output and preserves substituted data', () {
    expect(tr('Ask'), 'Ask');
    setLanguage('de');
    expect(tr('Ask'), isNot('Ask'));
    expect(trf('{0} / {1}', ['model-name {1}', 'answer']), 'model-name {1} / answer');
    expect(trf('Download the vision file ({0:.1f} GB)', [1.25]), contains('1.3'));
    setLanguage('fr');
    expect(tr('Ask'), isNot('Ask'));
    setLanguage('en');
    expect(tr('Ask'), 'Ask');
  });

  test('auto follows LANG and locale precedence', () {
    expect(resolveLanguage('auto', {'LANG': 'de_DE.UTF-8'}), 'de');
    expect(resolveLanguage('auto', {'LANG': 'pl_PL.UTF-8'}), 'pl');
    expect(resolveLanguage('auto', {'LC_ALL': 'fr_FR.UTF-8', 'LANG': 'de_DE.UTF-8'}), 'fr');
    expect(resolveLanguage('es', {'LANG': 'de_DE.UTF-8'}), 'es');
    setLanguage(resolveLanguage('auto', {'LANG': 'de_DE.UTF-8'}));
    expect(tr('Ask'), isNot('Ask'));
  });

  test('CoreService resolves language at construction and when settings change', () async {
    final home = Directory.systemTemp.createTempSync('playground-i18n-');
    final environment = {'HOME': home.path, 'LANG': 'de_DE.UTF-8'};
    final core = CoreService(environment);
    addTearDown(() async {
      await core.dispose();
      home.deleteSync(recursive: true);
    });
    expect(currentLanguage, 'de');
    Future<Map> request(String method, Map values) async =>
        jsonDecode(await core.handleAsync(jsonEncode({'protocol': 1, 'id': 1, 'method': method, 'params': values})))
            as Map;
    final german = await request('unknown.method', {});
    await request('settings.set', {
      'values': {'language': 'fr'},
    });
    expect(currentLanguage, 'fr');
    final french = await request('unknown.method', {});
    expect(french['error']['message'], isNot(german['error']['message']));
    await request('settings.set', {
      'values': {'language': 'auto'},
    });
    expect(currentLanguage, 'de');
  });
}
