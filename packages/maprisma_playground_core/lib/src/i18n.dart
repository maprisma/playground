import 'dart:convert';
import 'dart:io';

import 'translations.g.dart';

/// Interface translations, as AI Playground has them (gettext style: the English text is the key).
/// `tr('Ask')`, and for text with values `trf('Opens {0}', [name])`. Anything without a
/// translation stays English. The language follows the system (LC_ALL, LC_MESSAGES, LANG) unless
/// one is picked in Settings (`language`: "auto" or a code). The catalogs are AI Playground's
/// (translations/<code>.json) plus Maprisma Playground's own texts (translations/extra/<code>.json),
/// built into translations.g.dart by tools/gen-translations.py.

const languages = <(String, String)>[
  ('en', 'English'),
  ('de', 'Deutsch'),
  ('fr', 'Français'),
  ('es', 'Español'),
  ('it', 'Italiano'),
  ('pt', 'Português'),
  ('nl', 'Nederlands'),
  ('pl', 'Polski'),
];
final languageCodes = {for (final l in languages) l.$1};

/// The language of the system's locale variables, "en" when it is none of ours.
String systemLanguage([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  for (final name in const ['LC_ALL', 'LC_MESSAGES', 'LANG']) {
    final value = (env[name] ?? '').toLowerCase();
    final code = value.replaceAll('-', '_').split('_').first.split('.').first.split('@').first;
    if (code.isEmpty || code == 'c' || code == 'posix') continue;
    return languageCodes.contains(code) ? code : 'en';
  }
  return 'en';
}

/// The language in use: the setting ("auto" or a code) resolved against the system.
String resolveLanguage(String setting, [Map<String, String>? environment]) =>
    languageCodes.contains(setting) ? setting : systemLanguage(environment);

String languageName(String code) => languages.firstWhere((l) => l.$1 == code, orElse: () => languages.first).$2;

var _code = 'en';
Map<String, String> _catalog = const {};
final _cache = <String, Map<String, String>>{};

/// The language now in use.
String get currentLanguage => _code;

/// Switch the language (a code from [languages]; anything else is English).
void setLanguage(String code) {
  _code = languageCodes.contains(code) ? code : 'en';
  _catalog = _code == 'en'
      ? const {}
      : _cache.putIfAbsent(_code, () {
          final json = translationCatalogs[_code];
          return json == null ? const {} : (jsonDecode(json) as Map).cast<String, String>();
        });
}

/// The text in the language in use (English when there is no translation).
String tr(String english) => _catalog[english] ?? english;

/// [tr] with values: `{0}`, `{1}` … are replaced after translating.
String trf(String english, List<Object?> values) {
  return tr(english).replaceAllMapped(RegExp(r'\{(\d+)(?::\.(\d+)f)?\}'), (match) {
    final index = int.parse(match[1]!);
    if (index >= values.length) return match[0]!;
    final value = values[index];
    if (value is num && match[2] != null) return value.toStringAsFixed(int.parse(match[2]!));
    return '$value';
  });
}

/// Whether a text has a translation in [code] (tests: every text the app shows is translated).
bool hasTranslation(String code, String english) {
  final json = translationCatalogs[code];
  if (json == null) return false;
  return _cache.putIfAbsent(code, () => (jsonDecode(json) as Map).cast<String, String>()).containsKey(english);
}
