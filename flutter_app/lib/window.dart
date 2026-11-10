import 'dart:async';

import 'package:flutter/services.dart';

/// Something dropped onto the window: image bytes (a picture from a browser)
/// or a text/uri-list (files from the file manager, a link from a browser).
final class Drop {
  Drop(this.type, this.data);
  final String type;
  final Uint8List data;
  bool get isUriList => type == 'text/uri-list';
}

/// The native window (linux/runner/my_application.cc, "maprisma-playground/window").
final class AppWindow {
  AppWindow._() {
    _channel.setMethodCallHandler(_handle);
  }
  static final instance = AppWindow._();
  static const _channel = MethodChannel('maprisma-playground/window');

  final shown = StreamController<void>.broadcast();
  final focus = StreamController<bool>.broadcast();

  /// The app is about to quit (closed, or --toggle while in front): stop what runs, keep the state.
  final closing = StreamController<void>.broadcast();

  /// A second start's words (`--agent <command> --test <tab>`).
  final opened = StreamController<List<String>>.broadcast();

  /// The pointer position while something is dragged over the window, null when it left.
  final dragging = StreamController<Offset?>.broadcast();
  final drops = StreamController<Drop>.broadcast();

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'shown':
        shown.add(null);
      case 'focus':
        focus.add(true);
      case 'blur':
        focus.add(false);
      case 'closing':
        closing.add(null);
      case 'open':
        opened.add([for (final w in call.arguments as List) '$w']);
      case 'dragMotion':
        final a = call.arguments as List;
        dragging.add(Offset((a[0] as int).toDouble(), (a[1] as int).toDouble()));
      case 'dragLeave':
        dragging.add(null);
      case 'drop':
        final m = call.arguments as Map;
        drops.add(Drop(m['type'] as String, m['data'] as Uint8List));
    }
    return null;
  }

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod(method, args);
    } on MissingPluginException {
      // tests
    } on PlatformException {
      // ignore
    }
  }

  Future<void> present() => _call('present');

  /// After `closing` was handled: the native side quits now (it also does after a grace time).
  Future<void> quit() => _call('quit');
  Future<void> titlebar(bool dark) => _call('titlebar', dark);
  Future<void> resize(int width, int height) => _call('size', [width, height]);
}

/// `--agent <command> --test <tab>` (unknown words are ignored: it is a GUI), as the plugin's parse_args.
({String agent, String tab}) parseArgs(List<String> words, Set<String> tabs) {
  var agent = '', tab = '';
  for (var i = 0; i < words.length; i++) {
    for (final key in const ['agent', 'test']) {
      String? value;
      if (words[i] == '--$key' && i + 1 < words.length) value = words[i + 1];
      if (words[i].startsWith('--$key=')) value = words[i].substring(key.length + 3);
      if (value == null) continue;
      if (key == 'agent') agent = value;
      if (key == 'test') tab = value;
    }
  }
  if (!tabs.contains(tab)) tab = '';
  if (agent.length > 64 || !RegExp(r'^[A-Za-z0-9._-]*$').hasMatch(agent)) agent = '';
  return (agent: agent, tab: tab);
}
