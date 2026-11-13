import 'i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';
import 'helpers_catalog.dart';
import 'private_files.dart';

/// Every agent the Playground can ask, in the order of Maprisma's helpers catalog
/// (helpers_catalog.dart): Claude Code, Codex, Hermes and Pi with their bundled adapters
/// ([adapterData]: their own stricter argv, thinking times, pictures, chess, sign-in check), every
/// other catalog entry with an `ask` as the catalog runs it. Facts only: no user-supplied
/// executable templates.
List<AgentAdapter> get adapters => adaptersFrom(helpersCatalog());

List<AgentAdapter> adaptersFrom(HelpersCatalog catalog) {
  final own = [for (final v in adapterData) AgentAdapter(Map<String, dynamic>.from(v))];
  final out = <AgentAdapter>[];
  for (final e in catalog.helpers) {
    if (out.any((a) => a.command == e.command)) continue;
    out.add(own.where((a) => a.command == e.command).firstOrNull ?? AgentAdapter(catalogAdapterData(e)));
  }
  for (final a in own) {
    if (!out.any((o) => o.command == a.command)) out.add(a);
  }
  return List.unmodifiable(out);
}

/// API key variables a catalog agent may use (for "set up"; it gets the whole environment, as
/// the bundled ones do).
const catalogEnv = <String, List<String>>{
  'gemini': ['GEMINI_API_KEY', 'GOOGLE_API_KEY'],
  'agy': ['GEMINI_API_KEY', 'GOOGLE_API_KEY'],
  'cursor-agent': ['CURSOR_API_KEY'],
  'copilot': ['COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN'],
  'grok': ['XAI_API_KEY', 'GROK_API_KEY'],
};

/// A catalog entry as an adapter: its `ask` argv, no thinking times, games or pictures; its
/// sign-in is not known here (an Ask shows it).
Map<String, dynamic> catalogAdapterData(CatalogHelper e) => {
  'command': e.command,
  'name': e.name,
  'catalog': true,
  'verified': e.verified,
  'ask': {'argv': e.argv, 'stdin': e.stdin, 'games': <String>[], 'effort': <String, List<String>>{}, 'note': ''},
  'access': {'files': <String>[], 'env': catalogEnv[e.id] ?? const <String>[]},
};

class AgentAdapter {
  AgentAdapter(this.data);
  final Map<String, dynamic> data;
  String get command => data['command'];
  String get name => data['name'];
  List<String> get argv => List<String>.from(data['ask']['argv']);
  List<String> get games => List<String>.from(data['ask']['games']);
  List<String> effort(String level) => List<String>.from(data['ask']['effort'][level] ?? []);
  List<String> get files => List<String>.from(data['access']['files'] ?? []);
  List<String> get env => List<String>.from(data['access']['env'] ?? []);
  bool get localOk => data['access']['local_ok'] == true;

  /// From Maprisma's helpers catalog (not one of the four bundled adapters).
  bool get fromCatalog => data['catalog'] == true;

  /// false: the catalog's entry was not tried with the agent yet ("(untested)").
  bool get verified => data['verified'] != false;

  /// The prompt goes on stdin instead of an argument.
  bool get promptOnStdin => data['ask']['stdin'] == true;
}

AgentAdapter? adapter(String command) {
  for (final a in adapters) {
    if (a.command == command) return a;
  }
  return null;
}

const modelFlags = {'claude': '--model', 'codex': '-m', 'pi': '--model'};
final modelName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@+\-]{0,159}$');
bool canAsk(String command) => adapter(command) != null;
bool takesImages(String command) => const ['claude', 'codex', 'pi'].contains(command);
bool readsUntrusted(String command) => const ['claude', 'hermes', 'pi'].contains(command);
bool plays(String command, [String game = 'chess']) => adapter(command)?.games.contains(game) ?? false;
String? executableOnPath(String command, Map<String, String> environment) {
  final home = environment['HOME'] ?? '/';
  final folders = [
    ...(environment['PATH'] ?? '').split(':'),
    for (final folder in [
      '.local/bin',
      '.local/share/mise/shims',
      '.bun/bin',
      '.npm-global/bin',
      '.cargo/bin',
      '.deno/bin',
      '.volta/bin',
      '.asdf/shims',
    ])
      p.join(home, folder),
    '/home/linuxbrew/.linuxbrew/bin',
  ];
  for (final dir in folders) {
    final path = p.join(dir.isEmpty ? '.' : dir, command);
    try {
      final stat = fileIdentity(path, noFollow: false);
      if (stat != null &&
          stat.mode & 0xf000 == 0x8000 &&
          (stat.uid == 0 || stat.uid == fileOwnerUid) &&
          stat.mode & 73 != 0 &&
          executableByUser(path)) {
        return p.absolute(path);
      }
    } on FileSystemException {
      /* absent */
    }
  }
  return null;
}

bool _usableProgram(String path) {
  try {
    final stat = fileIdentity(path, noFollow: false);
    return stat != null &&
        stat.mode & 0xf000 == 0x8000 &&
        (stat.uid == 0 || stat.uid == fileOwnerUid) &&
        stat.mode & 73 != 0 &&
        executableByUser(path);
  } on FileSystemException {
    return false;
  }
}

final _miseFound = <String, (DateTime, String?)>{};

/// mise's shims folder (`$MISE_DATA_DIR/shims`, by default `~/.local/share/mise/shims`).
String miseShims(Map<String, String> environment) {
  final data = environment['MISE_DATA_DIR'] ?? '';
  if (data.startsWith('/')) return p.join(data, 'shims');
  final xdg = environment['XDG_DATA_HOME'] ?? '';
  return p.join(xdg.startsWith('/') ? xdg : p.join(environment['HOME'] ?? '/', '.local/share'), 'mise', 'shims');
}

/// An agent's program: [executableOnPath], else where mise has it (`mise which`, asked only for
/// a command mise has a shim for, at most 5 s, remembered for half a minute). Nothing that would
/// install it is ever run.
String? agentExecutable(String command, Map<String, String> environment) {
  final found = executableOnPath(command, environment);
  if (found != null || command == 'mise' || !plainHelperName(command)) return found;
  final shim = p.join(miseShims(environment), command);
  if (FileSystemEntity.typeSync(shim, followLinks: false) == FileSystemEntityType.notFound) return null;
  final mise = executableOnPath('mise', environment);
  if (mise == null) return null;
  final key = '$mise\x00$command\x00${environment['HOME']}\x00${environment['PATH']}';
  final cached = _miseFound[key];
  if (cached != null && DateTime.now().difference(cached.$1) < const Duration(seconds: 30)) return cached.$2;
  String? result;
  final timeout = executableOnPath('timeout', environment) ?? (_usableProgram('/usr/bin/timeout') ? '/usr/bin/timeout' : null);
  if (timeout != null) {
    try {
      final r = Process.runSync(timeout, ['5', mise, 'which', command], environment: environment, includeParentEnvironment: false);
      final out = r.exitCode == 0 ? '${r.stdout}'.split('\n').first.trim() : '';
      if (out.startsWith('/') && _usableProgram(out)) result = out;
    } on ProcessException {
      result = null;
    }
  }
  _miseFound[key] = (DateTime.now(), result);
  return result;
}

String readConfig(String path, {int maxBytes = 512 * 1024}) => readRegularNoFollow(path, maxBytes: maxBytes);
String stripJsonComments(String text) {
  final out = StringBuffer();
  var inString = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inString) {
      out.write(c);
      if (c == r'\' && i + 1 < text.length) {
        out.write(text[++i]);
      } else if (c == '"') {
        inString = false;
      }
    } else if (c == '"') {
      inString = true;
      out.write(c);
    } else if (text.startsWith('//', i)) {
      while (i < text.length && text[i] != '\n') {
        i++;
      }
      out.write('\n');
    } else if (text.startsWith('/*', i)) {
      final end = text.indexOf('*/', i + 2);
      i = end < 0 ? text.length : end + 1;
    } else if (c == ',') {
      var next = i + 1;
      while (next < text.length && text[next].trim().isEmpty) {
        next++;
      }
      if (next >= text.length || !const ['}', ']'].contains(text[next])) {
        out.write(c);
      }
    } else {
      out.write(c);
    }
  }
  return out.toString();
}

Map<String, dynamic> readConfigJson(String path) {
  try {
    final text = readConfig(path);
    final v = jsonDecode(path.endsWith('.jsonc') || text.contains('//') ? stripJsonComments(text) : text);
    if (v is Map) return Map<String, dynamic>.from(v);
  } on Object {
    /* unavailable */
  }
  return {};
}

Map<String, dynamic> readConfigToml(String path) {
  try {
    return TomlDocument.parse(readConfig(path)).toMap();
  } on Object {
    return {};
  }
}

bool localUrl(Object? value) {
  try {
    final uri = value is String ? Uri.tryParse(value) : null;
    if (uri == null) return false;
    // Accessing port also validates it, as urlparse(...).port does upstream.
    final port = uri.port;
    return port >= 0 && const ['localhost', '127.0.0.1', '::1', '0.0.0.0'].contains(uri.host);
  } on Object {
    return false;
  }
}

/// Read provider configuration only; credential file contents are never opened.
bool hasLocalProvider(String command, Map<String, String> environment) {
  final home = environment['HOME'] ?? '/';
  switch (command) {
    case 'claude':
      final env = readConfigJson('$home/.claude/settings.json')['env'];
      return env is Map && localUrl(env['ANTHROPIC_BASE_URL']);
    case 'pi':
      final providers = readConfigJson('$home/.pi/agent/models.json')['providers'];
      return providers is Map && providers.values.take(50).any((v) => v is Map && localUrl(v['baseUrl']));
    case 'codex':
      final providers = readConfigToml('$home/.codex/config.toml')['model_providers'];
      return providers is Map && providers.values.take(50).any((v) => v is Map && localUrl(v['base_url']));
    case 'hermes':
      final text = readConfig('$home/.hermes/config.yaml');
      final modelBlock = RegExp(r'^model:\s*\n((?:[ \t]+.*\n?)+)', multiLine: true).firstMatch(text)?[1] ?? '';
      final values = {
        for (final m in RegExp(
          r'''^[ \t]+(default|provider|base_url):[ \t]*['"]?([^'"\n#]*)''',
          multiLine: true,
        ).allMatches(modelBlock))
          m[1]!: m[2]!.trim(),
      };
      final modelBase = values['base_url'] ?? '';
      if (localUrl(modelBase)) return true;
      final modelProvider = (values['provider'] ?? '').isEmpty ? 'custom' : values['provider']!;
      final providerBlock =
          RegExp(r'^providers:[ \t]*\n((?:[ \t]+.*\n?|\n)+)', multiLine: true).firstMatch(text)?[1] ?? '';
      final entries = providerBlock.split(RegExp(r'^  (?=[A-Za-z0-9_.-]+:)', multiLine: true));
      for (final entry in entries.take(50)) {
        final name = RegExp(r'^([A-Za-z0-9_.-]{1,64}):').firstMatch(entry)?[1];
        final api = RegExp(r'''^    (?:api|base_url):[ \t]*['"]?([^'"\s#]+)''', multiLine: true).firstMatch(entry)?[1];
        if (name == null || api == null || (modelBase.isNotEmpty && name == modelProvider)) {
          continue;
        }
        if (localUrl(api)) return true;
      }
      return false;
  }
  return false;
}

bool agentSetUp(String command, Map<String, String> environment) {
  final a = adapter(command);
  if (a == null) return false;
  if (a.fromCatalog) return true; // only an Ask can tell
  if (a.env.any((k) => (environment[k] ?? '').isNotEmpty)) return true;
  if (a.files.any(
    (f) => FileSystemEntity.typeSync(p.join(environment['HOME'] ?? '/', f)) == FileSystemEntityType.file,
  )) {
    return true;
  }
  return a.localOk && hasLocalProvider(command, environment);
}

Map<String, Object?> agentInfo(AgentAdapter a, Map<String, String> environment) => {
  'command': a.command,
  'name': a.name,
  'installed': agentExecutable(a.command, environment) != null,
  'set_up': agentSetUp(a.command, environment),
  'can_ask': canAsk(a.command),
  'plays_chess': plays(a.command),
  'takes_images': takesImages(a.command),
  'reads_untrusted': readsUntrusted(a.command),
  'model_flag': modelFlags[a.command] ?? '',
  'verified': a.verified,
};
List<Map<String, dynamic>> get adapterData => [
  {
    "command": "claude",
    "name": "Claude Code",
    "ask": {
      "argv": ["claude", "-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence", "{prompt}"],
      "games": ["chess"],
      "effort": {
        "quick": ["--effort", "low"],
        "normal": ["--effort", "medium"],
        "deep": ["--effort", "high"],
        "max": ["--effort", "max"],
      },
      "note": tr("no tools, no MCP servers, no session kept"),
    },
    "access": {
      "how": tr("A Claude Pro or Max subscription (claude.ai), or an API key from console.anthropic.com"),
      "login": "claude auth login",
      "files": [".claude/.credentials.json"],
      "env": ["ANTHROPIC_API_KEY"],
      "logins": [
        {
          "label": tr("Claude subscription"),
          "argv": ["claude", "auth", "login", "--claudeai"],
        },
        {
          "label": tr("API billing (Anthropic Console)"),
          "argv": ["claude", "auth", "login", "--console"],
        },
      ],
    },
  },
  {
    "command": "codex",
    "name": "Codex",
    "ask": {
      "argv": [
        "codex",
        "exec",
        "--sandbox",
        "read-only",
        "--skip-git-repo-check",
        "--ephemeral",
        "--color",
        "never",
        "{prompt}",
      ],
      "games": ["chess"],
      "effort": {
        "quick": ["-c", "model_reasoning_effort=low"],
        "normal": ["-c", "model_reasoning_effort=medium"],
        "deep": ["-c", "model_reasoning_effort=high"],
        "max": ["-c", "model_reasoning_effort=high"],
      },
      "note": tr("read-only sandbox, no session kept"),
    },
    "access": {
      "how": tr("A ChatGPT plan (Plus, Pro, Business), or an API key from platform.openai.com"),
      "login": "codex login",
      "files": [".codex/auth.json"],
      "env": ["OPENAI_API_KEY"],
      "local_ok": true,
      "logins": [
        {
          "label": tr("ChatGPT plan"),
          "argv": ["codex", "login"],
        },
      ],
      "key": {
        "var": "OPENAI_API_KEY",
        "url": "https://platform.openai.com/api-keys",
        "stdin": ["codex", "login", "--with-api-key"],
      },
    },
  },
  {
    "command": "hermes",
    "name": "Hermes",
    "ask": {
      "argv": ["hermes", "{effort}", "-t", "todo", "--ignore-rules", "-z", "{prompt}"],
      "games": ["chess"],
      "effort": {
        "quick": ["--reasoning", "low"],
        "normal": ["--reasoning", "medium"],
        "deep": ["--reasoning", "high"],
        "max": ["--reasoning", "max"],
      },
      "note": tr("only its in-memory task list (no files, terminal, web or MCP), no project rules or memory"),
    },
    "access": {
      "how": tr("A provider key (hermes setup), or a local LLM from the map"),
      "login": "hermes setup",
      "files": [".hermes/auth.json", ".hermes/.env"],
      "local_ok": true,
      "logins": [
        {
          "label": tr("Setup wizard (account or key)"),
          "argv": ["hermes", "setup"],
        },
      ],
    },
  },
  {
    "command": "pi",
    "name": "Pi",
    "ask": {
      "argv": [
        "pi",
        "-p",
        "--no-tools",
        "--no-approve",
        "--no-mcp",
        "--no-skills",
        "--no-context-files",
        "--no-prompt-templates",
        "{prompt}",
      ],
      "games": ["chess"],
      "effort": {
        "quick": ["--thinking", "low"],
        "normal": ["--thinking", "medium"],
        "deep": ["--thinking", "high"],
        "max": ["--thinking", "max"],
      },
      "note": tr("no tools, no MCP servers, skills or context files, project files ignored"),
    },
    "access": {
      "how": tr("Sign in inside Pi (/login: Claude, ChatGPT, Copilot …), an API key, or a local LLM from the map"),
      "login": "pi  \u2192  /login",
      "files": [".pi/agent/auth.json"],
      "env": ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"],
      "local_ok": true,
      "logins": [
        {
          "label": tr("Inside Pi"),
          "argv": ["pi"],
          "note": tr("Type /login in it."),
        },
      ],
    },
  },
];

/// The selected local model, for the GPU guard (provider ids from upstream).
(String, String)? localAgentModel(String command, Map<String, String> environment) {
  const keys = {
    'llama-local': 'llamacpp',
    'ollama-local': 'ollama',
    'lmstudio-local': 'lmstudio',
    'vllm-local': 'vllm',
    'jan-local': 'jan',
    'koboldcpp-local': 'koboldcpp',
  };
  final home = environment['HOME'] ?? '/';
  String model = '', provider = '';
  if (command == 'pi') {
    final config = readConfigJson('$home/.pi/agent/settings.json');
    model = config['defaultModel'] is String ? config['defaultModel'] : '';
    provider = config['defaultProvider'] is String ? config['defaultProvider'] : '';
  } else if (command == 'codex') {
    final config = readConfigToml('$home/.codex/config.toml');
    model = config['model'] is String ? config['model'] : '';
    provider = config['model_provider'] is String ? config['model_provider'] : '';
  } else if (command == 'hermes') {
    final config = readConfig('$home/.hermes/config.yaml');
    final block = RegExp(r'^model:\s*\n((?:[ \t]+.*\n?)+)', multiLine: true).firstMatch(config)?[1] ?? '';
    model = RegExp(r'''^\s+default:\s*["']?([^"'\n#]+)''', multiLine: true).firstMatch(block)?[1]?.trim() ?? '';
    provider = RegExp(r'''^\s+provider:\s*["']?([^"'\n#]+)''', multiLine: true).firstMatch(block)?[1]?.trim() ?? '';
  }
  return model.isNotEmpty && keys.containsKey(provider) ? (keys[provider]!, model) : null;
}

/// Ready to be offered as a chess opponent. Capability itself is independent of readiness.
bool canPlay(String command, Map<String, String> environment) =>
    plays(command) && agentExecutable(command, environment) != null && agentSetUp(command, environment);
