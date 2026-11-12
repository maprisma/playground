import 'dart:async';
import 'dart:io' show FileSystemException;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';

import 'contestants.dart';
import 'esc_close.dart';
import 'pages/analyze_page.dart';
import 'pages/automaton_page.dart';
import 'pages/chess_page.dart';
import 'pages/duel_page.dart';
import 'pages/games_page.dart';
import 'pages/generate_page.dart';
import 'pages/local_page.dart';
import 'pages/speed_page.dart';
import 'pages/vision_page.dart';
import 'pages/info_page.dart';
import 'pages/settings_page.dart';
import 'pages/todo_page.dart';
import 'theme.dart';
import 'widgets.dart';
import 'window.dart';
import 'window_size.dart';
import 'work.dart';

/// The tabs, in the plugin's order with the Automaton after Chess (Ctrl+1 … Ctrl+7). Analyze is
/// not a tab: it is a header symbol's page, as Information and Settings.
List<(String, String)> get tabs => <(String, String)>[
  ('chess', tr("Chess")),
  ('automaton', tr("Automaton")),
  ('speed', tr("Speed and cost")),
  ('duel', tr("Head to head")),
  ('vision', tr("Vision")),
  ('generate', tr("Generate")),
  ('local', tr("Local LLMs")),
];
final tabKeys = {for (final t in tabs) t.$1};

/// Pages opened from a header symbol (or Games from Chess), with Back: Esc and Backspace go back
/// to the last tab.
const symbolPages = {'analyze', 'settings', 'info', 'games'};

/// What `--test` may open: a tab, or the Analyze page.
Set<String> get testPages => {...tabKeys, 'analyze'};

/// The whole window, dialogs included, for F12's picture (MaterialApp.builder).
final windowShot = GlobalKey(debugLabel: 'window');
Widget windowFrame(BuildContext context, Widget? child) => RepaintBoundary(key: windowShot, child: child);

/// What every page gets: the settings, a way to show a short message, and to switch pages.
final class Host {
  Host({required this.settings, required this.toast, required this.show, this.onLanguage});
  final Settings settings;
  final void Function(String text) toast;
  final void Function(String page) show;

  /// Settings › Language changed ("auto" or a code): the core follows, every page is rebuilt.
  final void Function(String setting)? onLanguage;
}

class PlaygroundApp extends StatefulWidget {
  const PlaygroundApp({super.key, required this.settings, required this.playground, this.args = const [], this.look = const {}});
  final Settings settings;

  /// The desktop's look read before the window opened (desktop_look.dart).
  final Map<String, dynamic> look;
  final Playground playground;
  final List<String> args;
  @override
  State<PlaygroundApp> createState() => _PlaygroundAppState();
}

/// Esc on a tab with nothing open: close as the close button does (what runs is stopped), but
/// while anything runs only hide the window, so Esc never stops a game, generation or download.
void closeOrHide() => switch (escWindow(running: Work.running)) {
  EscWindow.hide => AppWindow.instance.hide(),
  EscWindow.close => AppWindow.instance.close(),
};

class _PlaygroundAppState extends State<PlaygroundApp> with WidgetsBindingObserver {
  late Map<String, dynamic> _look = widget.look;
  StreamSubscription<bool>? _focus;

  /// Esc that no page took (rule 5a): leave a field, Back on a symbol page, then close the window
  /// as its close button does; while something runs, hide it instead (nothing is stopped).
  late final _esc = EscFallback(onClose: closeOrHide);

  /// The window's size, saved half a second after the last resize (rule 5a).
  late final _windowSize = WindowSizeKeeper(
    saved: _savedSize(),
    geometry: AppWindow.instance.geometry,
    save: (w, h) async => widget.settings.update({
      'window_size': [w, h],
    }),
  );

  (int, int)? _savedSize() {
    try {
      return parseWindowSize(widget.settings.get('window_size'));
    } on Object {
      return null;
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _windowSize.resized();
  }
  Timer? _lookTimer;
  DateTime? _lookRead;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _esc.attach();
    final backend = widget.playground.backend;
    Work.watch(backend, () => backend.busy);
    _readLook(force: true);
    // Maprisma Theme can change the desktop's colours at any time: read them again every 5 s
    // and when the window gets the focus back (hyprctl's rounding at most every 30 s).
    _lookTimer = Timer.periodic(const Duration(seconds: 5), (_) => _readLook(force: true));
    _focus = AppWindow.instance.focus.stream.listen((on) {
      if (on) _readLook();
    });
  }

  /// The look again; rebuilt only when it changed. Focus and brightness reads count against
  /// the timer's: the files at most every 2 s.
  Future<void> _readLook({bool force = false}) async {
    final last = _lookRead;
    if (!mounted || _reading) return;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(seconds: 2)) return;
    _reading = true;
    _lookRead = DateTime.now();
    try {
      final look = await readDesktopLook();
      if (mounted && look.toString() != _look.toString()) setState(() => _look = look);
    } on Object {
      // the old look stays
    } finally {
      _reading = false;
    }
  }

  @override
  void didChangePlatformBrightness() => _readLook(force: true);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _readLook();
  }

  @override
  void dispose() {
    _lookTimer?.cancel();
    _focus?.cancel();
    _esc.detach();
    Work.unwatch(widget.playground.backend);
    _windowSize.dispose();
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
      builder: (context, child) => windowFrame(context, _esc.wrap(child!)),
      navigatorObservers: [_esc],
      home: Shell(
        esc: _esc,
        settings: widget.settings,
        playground: widget.playground,
        args: widget.args,
        rounding: rounding,
        onLookChanged: () => setState(() {}),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.settings,
    required this.playground,
    required this.args,
    this.rounding,
    required this.onLookChanged,
    this.screenshots,
    this.esc,
  });
  final Settings settings;
  final Playground playground;
  final List<String> args;

  /// The app's Esc fallback: the symbol pages (Settings, Information, Analyze, Games) are its
  /// side pages.
  final EscFallback? esc;
  final int? rounding;
  final VoidCallback onLookChanged;

  /// Where F12 saves its pictures (tests); null: ~/Pictures/Maprisma Playground.
  final String? screenshots;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late String _page;
  late String _lastTab;
  late final Host _host = Host(settings: widget.settings, toast: _toast, show: _show, onLanguage: _language);

  void _language(String setting) {
    widget.playground.backend.call('settings.set', {
      'values': {'language': setting},
    }).ignore();
    widget.onLookChanged(); // the whole app is built again in the new language
  }

  final _subscriptions = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    final saved = widget.settings.text('playground_tab');
    _page = tabKeys.contains(saved) ? saved : tabs.first.$1; // a saved "analyze" is no tab any more
    _lastTab = _page;
    _open(widget.args);
    HardwareKeyboard.instance.addHandler(_f12);
    widget.esc
      ?..sidePage = (() => symbolPages.contains(_page))
      ..onBack = (() => _show(_lastTab));
    _subscriptions
      ..add(AppWindow.instance.opened.stream.listen(_open))
      ..add(AppWindow.instance.closing.stream.listen((_) => _close()));
  }

  /// The window asked to close (or --toggle, or SIGTERM): the state is kept, then the core ends
  /// every agent, download and held model it started, and only then the app quits.
  Future<void> _close() async {
    _remember();
    ChessSession.disposeAll();
    await widget.playground.backend.shutdown();
    await AppWindow.instance.quit();
  }

  void _open(List<String> words) {
    final wanted = parseArgs(words, testPages);
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
    HardwareKeyboard.instance.removeHandler(_f12);
    if (widget.esc case final esc?) {
      esc
        ..sidePage = null
        ..onBack = null;
    }
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

  // --- F12: a picture of the window ------------------------------------------------------------

  bool _shooting = false;

  bool get _screenshotOn {
    try {
      return widget.settings.flag('screenshot_key');
    } on Object {
      return true;
    }
  }

  /// F12 without Ctrl, Shift, Alt or Super, wherever the keyboard is (also in a dialog).
  bool _f12(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.f12) return false;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isShiftPressed || keys.isAltPressed || keys.isMetaPressed) return false;
    if (!_screenshotOn) return false;
    takeScreenshot();
    return true;
  }

  static String _why(Object error) => switch (error) {
    FileSystemException(:final osError?) => osError.message,
    FileSystemException(:final message) => message,
    _ => '$error',
  };

  /// The window as it is now into a PNG (it draws itself: no screenshot program), then the
  /// dialog for a note.
  Future<void> takeScreenshot() async {
    if (_shooting) return;
    _shooting = true;
    String path;
    try {
      final boundary = windowShot.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary || !boundary.hasSize || boundary.size.isEmpty) {
        throw _NoPicture();
      }
      final image = await boundary.toImage(pixelRatio: View.of(context).devicePixelRatio);
      final ByteData? png;
      try {
        png = await image.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        image.dispose();
      }
      if (png == null) throw _NoPicture();
      path = saveScreenshot(widget.screenshots ?? screenshotFolder(), png.buffer.asUint8List());
    } on Object catch (e) {
      _shooting = false;
      if (mounted) _toast(trf("The screenshot could not be saved: {0}", [_why(e)]));
      return;
    }
    try {
      // F12 again while the note is asked for takes no second picture and opens no second dialog.
      if (mounted) await _screenshotNote(path);
    } finally {
      _shooting = false;
    }
  }

  /// "Screenshot saved": where, and an optional note about what is wrong, saved next to it as a
  /// .txt when the dialog closes (Done, Enter, Esc).
  Future<void> _screenshotNote(String path) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => ScreenshotNoteDialog(path: path),
    );
    try {
      saveScreenshotNote(path, note ?? '');
    } on Object catch (e) {
      if (mounted) _toast(trf("The note could not be saved: {0}", [_why(e)]));
    }
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
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
    ].take(tabs.length).toList();
    if (ctrl && digits.contains(key)) {
      _show(tabs[digits.indexOf(key)].$1);
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyV && _page == 'chess') {
      ChessPage.paste(); // a YouTube link from the clipboard: a video import
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.comma) {
      _show('settings');
      return KeyEventResult.handled;
    }
    // A page with a Back button: Esc and Backspace go back, unless a text field has the keyboard.
    if (symbolPages.contains(_page) &&
        (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) &&
        !_editing) {
      _show(_lastTab);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _tabPage(String key) => switch (key) {
    'automaton' => AutomatonPage(host: _host, active: _page == 'automaton'),
    'chess' => ChessPage(host: _host, playground: widget.playground, active: _page == 'chess'),
    'speed' => SpeedPage(host: _host, playground: widget.playground),
    'vision' => VisionPage(host: _host, playground: widget.playground),
    'generate' => GeneratePage(host: _host, playground: widget.playground),
    'duel' => DuelPage(host: _host, playground: widget.playground),
    'local' => LocalPage(host: _host, playground: widget.playground),
    _ => TodoPage(title: tabs.firstWhere((t) => t.$1 == key).$2),
  };

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    // Analyze stays built after the tabs (a running analysis keeps going under Settings).
    final index = _page == 'analyze' ? tabs.length : tabs.indexWhere((t) => t.$1 == _page);
    return Scaffold(
      backgroundColor: look.bg,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppHeader(page: _page, onShow: _show),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Every tab stays built, also under Settings, Information and Games, so answers,
                  // a running game or the automaton keep their state.
                  Offstage(
                    offstage: index < 0,
                    child: TickerMode(
                      enabled: index >= 0,
                      child: IndexedStack(
                        index: index < 0 ? tabs.indexWhere((t) => t.$1 == _lastTab) : index,
                        children: [
                          for (final t in tabs) _tabPage(t.$1),
                          AnalyzePage(host: _host, playground: widget.playground, onBack: () => _show(_lastTab)),
                        ],
                      ),
                    ),
                  ),
                  if (index < 0)
                    ColoredBox(
                      color: look.bg,
                      child: switch (_page) {
                        'settings' => SettingsPage(
                          host: _host,
                          rounding: widget.rounding,
                          onBack: () => _show(_lastTab),
                          onLookChanged: widget.onLookChanged,
                        ),
                        'games' => GamesPage(
                          host: _host,
                          session: ChessSession.of(widget.playground, widget.settings),
                          onBack: () => _show('chess'),
                        ),
                        _ => InfoPage(onBack: () => _show(_lastTab)),
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// build_header: the gamepad, the name, the tabs (wrapping onto more lines in a narrow window and
/// filling the header's width), then Analyze, Information and Settings, always in view.
class AppHeader extends StatelessWidget {
  const AppHeader({super.key, required this.page, required this.onShow});
  final String page;
  final ValueChanged<String> onShow;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    // A narrow (tiled) window keeps the tabs and symbols in view: the name gives way first.
    final wide = MediaQuery.sizeOf(context).width >= 1300;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(
        children: [
          Tooltip(
            message: 'Maprisma Playground',
            child: Icon(Icons.sports_esports, size: 20, color: look.fg),
          ),
          if (wide) ...[
            const SizedBox(width: 8),
            Text(
              'Maprisma Playground',
              style: Theme.of(context).textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w700, color: look.fg),
            ),
          ],
          SizedBox(width: wide ? 16 : 10),
          Expanded(
            child: HeaderTabs(page: page, onShow: onShow),
          ),
          const SizedBox(width: 8),
          // Symbols that open a page with Back; lit while it is open.
          for (final (key, icon, tip) in [
            ('analyze', Icons.science_outlined, tr("Analyze")),
            ('info', Icons.info_outline, tr("Information")),
            ('settings', Icons.settings, tr("Settings (Ctrl+,)")),
          ]) ...[
            if (key != 'analyze') const SizedBox(width: 4),
            HeaderSymbol(
              key: ValueKey('symbol-$key'),
              icon: icon,
              tooltip: tip,
              active: page == key,
              onPressed: () => onShow(key),
            ),
          ],
        ],
      ),
    );
  }
}

/// A header symbol (Analyze, Information, Settings): a small square bordered button, in the
/// accent colour while its page is open.
class HeaderSymbol extends StatelessWidget {
  const HeaderSymbol({super.key, required this.icon, required this.tooltip, required this.active, this.onPressed});
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback? onPressed;

  static const side = 26.0;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final color = active ? look.accent : look.fg;
    return Tooltip(
      message: tooltip,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          backgroundColor: active ? look.accent.withValues(alpha: .14) : Colors.transparent,
          side: BorderSide(color: active ? look.accent : look.fg.withValues(alpha: .35)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
          padding: EdgeInsets.zero,
          minimumSize: const Size.square(side),
          fixedSize: const Size.square(side),
          visualDensity: VisualDensity.standard,
        ),
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}

/// fit_tabs: the tabs' lines for this width. They wrap where they no longer fit; all on one line,
/// that line fills the width; wrapped, the full lines fill it and the last line keeps the tabs'
/// own widths. Each entry is (tab index, width).
List<List<(int, double)>> fitTabs(List<double> natural, double width, {double spacing = 4}) {
  final lines = <List<int>>[];
  var line = <int>[];
  var used = 0.0;
  for (var i = 0; i < natural.length; i++) {
    final need = (line.isEmpty ? 0 : spacing) + natural[i];
    if (line.isNotEmpty && used + need > width + .01) {
      lines.add(line);
      line = [i];
      used = natural[i];
    } else {
      line.add(i);
      used += need;
    }
  }
  if (line.isNotEmpty) lines.add(line);
  return [
    for (var k = 0; k < lines.length; k++)
      () {
        final ids = lines[k];
        final fill = lines.length == 1 || k < lines.length - 1;
        final total = ids.fold(0.0, (sum, i) => sum + natural[i]) + spacing * (ids.length - 1);
        final extra = fill ? (width - total).clamp(0.0, double.infinity) / ids.length : 0.0;
        return [for (final i in ids) (i, (natural[i] + extra).clamp(0.0, width).toDouble())];
      }(),
  ];
}

/// The tab buttons in lines that fill the header (fitTabs).
class HeaderTabs extends StatelessWidget {
  const HeaderTabs({super.key, required this.page, required this.onShow});
  final String page;
  final ValueChanged<String> onShow;

  static const spacing = 4.0, padding = 12.0;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final style = Theme.of(context).textTheme.labelLarge!.copyWith(fontWeight: FontWeight.w700);
    final radius = cornerSizes(context).control;
    final scaler = MediaQuery.textScalerOf(context);
    final natural = [
      for (final (_, label) in tabs)
        (TextPainter(
              text: TextSpan(text: label, style: style),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
              maxLines: 1,
            )..layout()).width.ceilToDouble() +
            2 * padding +
            2,
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final lines = fitTabs(natural, box.maxWidth, spacing: spacing);
        Widget tab(int i, double width) {
          final (key, label) = tabs[i];
          final on = key == page;
          return SizedBox(
            width: width,
            child: Tooltip(
              message: trf('Ctrl+{0}', [i + 1]),
              child: TextButton(
                key: ValueKey('tab-$key'),
                onPressed: () => onShow(key),
                style: TextButton.styleFrom(
                  foregroundColor: on ? look.accent : look.fg,
                  backgroundColor: on ? look.accent.withValues(alpha: .15) : look.fg.withValues(alpha: .08),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
                  padding: const EdgeInsets.symmetric(horizontal: padding, vertical: 8),
                  textStyle: style,
                ),
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var k = 0; k < lines.length; k++) ...[
              if (k > 0) const SizedBox(height: spacing),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var j = 0; j < lines[k].length; j++) ...[
                    if (j > 0) const SizedBox(width: spacing),
                    tab(lines[k][j].$1, lines[k][j].$2),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// "Screenshot saved": where, and a field for what is wrong. Done, Enter, Esc and a click beside it
/// all close it with the text typed (the field's controller lives and goes with the dialog).
class ScreenshotNoteDialog extends StatefulWidget {
  const ScreenshotNoteDialog({super.key, required this.path});
  final String path;
  @override
  State<ScreenshotNoteDialog> createState() => _ScreenshotNoteDialogState();
}

class _ScreenshotNoteDialogState extends State<ScreenshotNoteDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(context, _note.text);

  @override
  Widget build(BuildContext context) => PopScope<String>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _done(); // Esc or a click beside it: the note is kept too
    },
    child: AlertDialog(
      title: Text(tr("Screenshot saved"), style: Theme.of(context).textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w700)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnswerText(trf("Saved as {0}", [homeShort(widget.path)])),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('screenshot-note'),
              controller: _note,
              autofocus: true,
              maxLength: screenshotNoteLimit,
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(hintText: tr("What is wrong? (optional)"), counterText: ''),
              onSubmitted: (_) => _done(),
            ),
          ],
        ),
      ),
      actions: [ActionButton(tr("Done"), onPressed: _done)],
    ),
  );
}

final class _NoPicture implements Exception {
  @override
  String toString() => tr("The window drew nothing.");
}
