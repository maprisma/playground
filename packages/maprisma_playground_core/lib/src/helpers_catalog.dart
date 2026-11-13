/// The AI helpers catalog shared with Maprisma: its `data/helpers.json`, made from its agent
/// adapters (Maprisma's docs/adapter-format.md, "The helpers export"). The Playground offers
/// every entry with an `ask` (one prompt, one answer on stdout, no tools or read-only) whose
/// program is installed, in the catalog's order (its order of preference); Claude Code, Codex,
/// Hermes and Pi keep their own adapters (agents.dart).
///
/// The catalog: Maprisma's installed `/usr/lib/maprisma/data/helpers.json` when it parses and is
/// at least as new (`version`) as the copy shipped here (`data/helpers.json`, built in by
/// tools/gen-helpers.py). The same rules as maprisma-notifier's helpers.rs.
library;

import 'dart:convert';
import 'dart:io';

import 'helpers_shipped.g.dart';

const helperPrompt = '{prompt}';
const systemHelpersPath = '/usr/lib/maprisma/data/helpers.json';
const helpersCatalogMax = 1024 * 1024;

/// The longest prompt one argv element takes (Linux's MAX_ARG_STRLEN, 32 pages, with its NUL).
const argvPromptMax = 128 * 1024 - 1;

/// Where Maprisma's catalog is read from; tests point it elsewhere.
var systemHelpersCatalog = systemHelpersPath;

/// One catalog entry with an `ask`: [argv] starts with [command] and has a `{prompt}` element
/// (unless [stdin]: then the prompt goes on stdin).
typedef CatalogHelper = ({String id, String name, String command, List<String> argv, bool stdin, bool verified});
typedef HelpersCatalog = ({int version, List<CatalogHelper> helpers});

final _plain = RegExp(r'^[A-Za-z0-9_+][A-Za-z0-9._+-]{0,63}$');

/// An id or a command: a plain name (no path, no spaces, not an option).
bool plainHelperName(String text) => _plain.hasMatch(text);

CatalogHelper? _entry(Object? h) {
  if (h is! Map) return null;
  final id = h['id'], command = h['command'], ask = h['ask'];
  if (id is! String || !plainHelperName(id) || command is! String || !plainHelperName(command)) return null;
  if (ask is! Map || ask['argv'] is! List) return null;
  final raw = ask['argv'] as List;
  if (raw.isEmpty || raw.length > 64 || raw.any((a) => a is! String || a.contains('\x00'))) return null;
  final argv = [for (final a in raw) a as String];
  final stdin = ask['stdin'] == true;
  if (argv.first != command) return null;
  if (!stdin && !argv.skip(1).any((a) => a.contains(helperPrompt))) return null;
  final rawName = h['name'];
  var name = rawName is String ? rawName.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim() : '';
  if (name.isEmpty) name = id;
  if (name.length > 64) name = name.substring(0, 64);
  return (id: id, name: name, command: command, argv: List.unmodifiable(argv), stdin: stdin, verified: h['verified'] == true);
}

/// A catalog; null when it isn't one. Entries without an `ask`, or with broken fields, are left
/// out; a repeated id counts once (the first).
HelpersCatalog? parseHelpersCatalog(String text) {
  Object? v;
  try {
    v = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (v is! Map || v['version'] is! int || v['helpers'] is! List) return null;
  final out = <CatalogHelper>[];
  for (final h in v['helpers'] as List) {
    final e = _entry(h);
    if (e != null && !out.any((o) => o.id == e.id)) out.add(e);
  }
  return (version: v['version'] as int, helpers: List.unmodifiable(out));
}

/// Maprisma's catalog when it is at least as new as the shipped one.
HelpersCatalog pickHelpersCatalog(HelpersCatalog? system, HelpersCatalog shipped) =>
    system != null && system.version >= shipped.version ? system : shipped;

HelpersCatalog get shippedHelpersCatalog => parseHelpersCatalog(shippedHelpersJson)!;

(String, DateTime, int, HelpersCatalog?)? _cached;

/// The catalog in use (Maprisma's file read again only when it changed).
HelpersCatalog helpersCatalog() {
  final path = systemHelpersCatalog;
  HelpersCatalog? system;
  try {
    final stat = File(path).statSync();
    final c = _cached;
    if (stat.type != FileSystemEntityType.file || stat.size > helpersCatalogMax) {
      system = null;
    } else if (c != null && c.$1 == path && c.$2 == stat.modified && c.$3 == stat.size) {
      system = c.$4;
    } else {
      system = parseHelpersCatalog(File(path).readAsStringSync());
      _cached = (path, stat.modified, stat.size, system);
    }
  } on FileSystemException {
    system = null;
  }
  return pickHelpersCatalog(system, shippedHelpersCatalog);
}

/// The argv of a catalog helper's Ask: `{prompt}` replaced inside single elements (never
/// through a shell; NULs dropped), `{effort}` (Maprisma's thinking time) left out. A prompt
/// alone in an element never starts with `-`, so it can't be read as an option. With `stdin`
/// the `{prompt}` elements go (the prompt is written to stdin).
List<String> catalogAskArgv(List<String> template, String prompt, {bool stdin = false}) {
  final clean = prompt.replaceAll('\x00', '');
  final lone = clean.startsWith('-') ? ' $clean' : clean;
  return [
    for (final a in template)
      if (a != '{effort}' && !(stdin && a.contains(helperPrompt)))
        a == helperPrompt ? lone : a.replaceAll(helperPrompt, clean),
  ];
}
