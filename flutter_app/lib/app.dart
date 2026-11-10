import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'package:maprisma_playground_core/src/settings.dart';

import 'pages/automaton_page.dart';
import 'pages/info_page.dart';
import 'pages/settings_page.dart';
import 'pages/todo_page.dart';
import 'theme.dart';
import 'window.dart';

/// The tabs, in the plugin's order with the Automaton after Chess (Ctrl+1 … Ctrl+8).
const tabs = <(String, String)>[
  ('analyze', 'Analyze'),
  ('chess', 'Chess'),
  ('automaton', 'Automaton'),
  ('speed', 'Speed and cost'),
  ('duel', 'Head to head'),
  ('vision', 'Vision'),
  ('generate', 'Generate'),
  ('local', 'Local LLMs'),
];
final tabKeys = {for (final t in tabs) t.$1};

/// What every page gets: the settings, a way to show a short message, and to switch pages.
final class Host {
  Host({required this.settings, required this.toast, required this.show});
  final Settings settings;
  final void Function(String text) toast;
  final void Function(String page) show;
}

class PlaygroundApp extends StatefulWidget {
  const PlaygroundApp({super.key, required this.settings, this.args = const []});
  final Settings settings;
  final List<String> args;
  @override
  State<PlaygroundApp> createState() => _PlaygroundAppState();
}

class _PlaygroundAppState extends State<PlaygroundApp> with WidgetsBindingObserver {
  Map<String, dynamic> _look = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readLook();
    AppWindow.instance.focus.stream.listen((on) {
      if (on) _readLook(); // the desktop's colours may have changed meanwhile
    });
  }

  void _readLook() {
    final look = desktopLook();
    if (look.toString() != _look.toString()) setState(() => _look = look);
  }

  @override
  void didChangePlatformBrightness() => _readLook();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = (_look['colors'] as Map?) ?? const {};
    final rounding = _look['rounding'] as int?;
    final radius = cornerRadius(widget.settings.text('corners'), rounding);
    final theme = appTheme(MediaQuery.platformBrightnessOf(context), colors, radius);
    AppWindow.instance.titlebar(theme.brightness == Brightness.dark);
    return MaterialApp(
      title: 'Maprisma Playground',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Shell(
        settings: widget.settings,
        args: widget.args,
        rounding: rounding,
        onLookChanged: () => setState(() {}),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key, required this.settings, required this.args, this.rounding, required this.onLookChanged});
  final Settings settings;
  final List<String> args;
  final int? rounding;
  final VoidCallback onLookChanged;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late String _page;
  late String _lastTab;
  late final Host _host = Host(settings: widget.settings, toast: _toast, show: _show);
  final _subscriptions = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    final saved = widget.settings.text('playground_tab');
    _page = tabKeys.contains(saved) ? saved : 'analyze';
    _lastTab = _page;
    _open(widget.args);
    _subscriptions
      ..add(AppWindow.instance.opened.stream.listen(_open))
      ..add(AppWindow.instance.closing.stream.listen((_) => _remember()));
  }

  void _open(List<String> words) {
    final wanted = parseArgs(words, tabKeys);
    if (wanted.tab.isNotEmpty) _show(wanted.tab);
  }

  void _remember() {
    try {
      widget.settings.update({'playground_tab': _lastTab});
    } on Object {
      // a settings file that cannot be written: the next start opens the default tab
    }
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _remember();
    super.dispose();
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 5)));
  }

  void _show(String page) {
    setState(() {
      _page = page;
      if (tabKeys.contains(page)) _lastTab = page;
    });
    if (tabKeys.contains(page)) _remember();
  }

  bool get _editing {
    final focus = FocusManager.instance.primaryFocus;
    return focus?.context?.widget is EditableText ||
        focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final key = event.logicalKey;
    final digits = [
      LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8,
    ];
    if (ctrl && digits.contains(key)) {
      _show(tabs[digits.indexOf(key)].$1);
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.comma) {
      _show('settings');
      return KeyEventResult.handled;
    }
    // A page with a Back button: Esc and Backspace go back, unless a text field has the keyboard.
    if (!tabKeys.contains(_page) &&
        (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) &&
        !_editing) {
      _show(_lastTab);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _tabPage(String key) => switch (key) {
    'automaton' => AutomatonPage(host: _host, active: _page == 'automaton'),
    _ => TodoPage(title: tabs.firstWhere((t) => t.$1 == key).$2),
  };

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final index = tabs.indexWhere((t) => t.$1 == _page);
    return Scaffold(
      backgroundColor: look.bg,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(page: _page, onShow: _show),
            Expanded(
              child: switch (_page) {
                'settings' => SettingsPage(
                  host: _host,
                  rounding: widget.rounding,
                  onBack: () => _show(_lastTab),
                  onLookChanged: widget.onLookChanged,
                ),
                'info' => InfoPage(onBack: () => _show(_lastTab)),
                // Every tab stays built, so a running game or automaton keeps its state.
                _ => IndexedStack(index: index < 0 ? 0 : index, children: [for (final t in tabs) _tabPage(t.$1)]),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// build_header: the gamepad, the name, a button per tab, then Information and Settings.
class _Header extends StatelessWidget {
  const _Header({required this.page, required this.onShow});
  final String page;
  final ValueChanged<String> onShow;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final radius = corners(context);
    Widget tab(int i) {
      final (key, label) = tabs[i];
      final on = key == page;
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Tooltip(
          message: 'Ctrl+${i + 1}',
          child: TextButton(
            onPressed: () => onShow(key),
            style: TextButton.styleFrom(
              foregroundColor: on ? look.accent : look.fg,
              backgroundColor: on ? look.accent.withValues(alpha: .15) : look.fg.withValues(alpha: .08),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            child: Text(label),
          ),
        ),
      );
    }

    Widget round(IconData icon, String tip, String target) => Tooltip(
      message: tip,
      child: IconButton(
        onPressed: () => onShow(target),
        icon: Icon(icon, size: 19, color: page == target ? look.accent : look.fg),
      ),
    );

    // A narrow (tiled) window keeps every tab in view: the name gives way first, the icon stays.
    final wide = MediaQuery.sizeOf(context).width >= 1300;
    return Padding(
      padding: const EdgeInsets.fromLTRB(17, 8, 12, 8),
      child: Row(
        children: [
          Tooltip(message: 'Maprisma Playground', child: Icon(Icons.sports_esports, size: 20, color: look.fg)),
          if (wide) ...[
            const SizedBox(width: 8),
            Text('Maprisma Playground', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: look.fg)),
          ],
          SizedBox(width: wide ? 16 : 10),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [for (var i = 0; i < tabs.length; i++) tab(i)]),
            ),
          ),
          const SizedBox(width: 8),
          round(Icons.info, 'Information', 'info'),
          round(Icons.settings, 'Settings (Ctrl+,)', 'settings'),
        ],
      ),
    );
  }
}
