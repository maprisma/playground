import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../backend.dart';
import '../contestants.dart';
import '../theme.dart';
import '../widgets.dart';
import 'vision_page.dart';

const generatePrompt = 'A red fox sitting in a snowy forest at dawn, soft light, photograph';
const sizeChoices = <(String, String)>[
  ('square', 'Square · 1024 × 1024'),
  ('landscape', 'Landscape · 1280 × 768'),
  ('portrait', 'Portrait · 768 × 1280'),
];

String _gigabytes(num size) => '${(size / (1 << 30)).toStringAsFixed(1)} GB';

final class _Picture {
  _Picture(this.path, this.prompt, this.seconds, this.seed);
  final String path, prompt;
  final double seconds;
  final int seed;
}

/// GenerateTab: a picture from a text, made on this computer's graphics card with
/// stable-diffusion.cpp and Z-Image-Turbo. Set up downloads both, each checked by its SHA-256.
class GeneratePage extends StatefulWidget {
  const GeneratePage({super.key, required this.host, required this.playground});
  final Host host;
  final Playground playground;
  @override
  State<GeneratePage> createState() => _GeneratePageState();
}

class _GeneratePageState extends State<GeneratePage> {
  final _prompt = TextEditingController(text: generatePrompt);
  Map<String, dynamic>? _status;
  String _size = 'square';
  final List<_Picture> _pictures = [];
  Job? _job;
  double _fraction = 0;
  int _saving = 0; // Save as… copies still running: Clear waits for them
  String _progress = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _job?.cancel();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = await widget.playground.backend.call('generate.status');
      if (mounted) setState(() => _status = s);
    } on CoreFailure catch (e) {
      if (mounted) setState(() => _status = {'ready': false, 'error': e.message});
    }
  }

  bool get _ready => _status?['ready'] == true;

  /// work in the core with progress; Cancel stops it. Returns the reply, or null when it failed.
  Future<Map<String, dynamic>?> _run(String label, String method, Map<String, dynamic> params) async {
    setState(() {
      _fraction = 0;
      _progress = label;
    });
    _job = widget.playground.backend.start(method, params, (event, data) {
      if (event != 'progress' || !mounted) return;
      setState(() {
        _fraction = ((data['fraction'] as num?) ?? 0).clamp(0, 1).toDouble();
        final text = '${data['text'] ?? ''}';
        _progress = text.isEmpty ? label : '$label $text';
      });
    });
    try {
      return await _job!.result;
    } on CoreFailure catch (e) {
      if (!e.cancelled && mounted) {
        widget.host.toast(method == 'generate.setup' ? 'Setting up stopped: ${e.message}' : 'No picture: ${e.message}');
      }
      return null;
    } finally {
      _job = null;
      if (mounted) setState(() {});
      _refresh();
    }
  }

  Future<void> _setup() async {
    final r = await _run('Downloading…', 'generate.setup', const {});
    if (r != null && mounted) widget.host.toast('Generate is set up.');
  }

  Future<void> _generate() async {
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      widget.host.toast('Write what the picture should show first.');
      return;
    }
    final seed = 1 + Random().nextInt((1 << 31) - 2); // a new picture each time
    final r = await _run('Generating…', 'generate.run', {'prompt': prompt, 'size': _size, 'seed': seed});
    if (r == null || !mounted) return;
    setState(() => _pictures.insert(
      0, // the newest first
      _Picture('${r['path']}', prompt, ((r['seconds'] as num?) ?? 0).toDouble(), (r['seed'] as int?) ?? seed),
    ));
  }

  Future<void> _clear() async {
    setState(_pictures.clear);
    try {
      await widget.playground.backend.call('generate.clear');
    } on Object {
      // nothing left to remove
    }
  }

  Future<void> _save(_Picture p) async {
    final to = await getSaveLocation(
      suggestedName: 'picture.png',
      acceptedTypeGroups: const [XTypeGroup(label: 'PNG', extensions: ['png'])],
    );
    if (to == null || !mounted) return;
    setState(() => _saving++);
    try {
      await File(p.path).copy(to.path);
      widget.host.toast('Saved: ${to.path.split('/').last}');
    } on FileSystemException catch (e) {
      widget.host.toast(e.message);
    } finally {
      if (mounted) setState(() => _saving--);
    }
  }

  void _toVision(_Picture p) {
    visionInbox.value = p.path;
    widget.host.show('vision');
  }

  String _setupText() {
    final s = _status ?? const {};
    final parts = <String>[
      if (s['program'] != true) 'stable-diffusion.cpp (its Vulkan build from GitHub, about 40 MB)',
      if (s['to_download'] is num && (s['to_download'] as num) > 0)
        'the Z-Image-Turbo model with its text encoder (${_gigabytes(s['to_download'] as num)} from Hugging Face)',
    ];
    final folder = '${s['folder'] ?? '~/.local/share/maprisma-playground'}';
    return 'Needed first: ${parts.isEmpty ? 'the program and the model' : parts.join('; ')}. Every file is checked '
        'against its published SHA-256 before it is kept; they go to $folder. A cancelled download goes on where it '
        'stopped.';
  }

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final busy = _job != null;
    final radius = corners(context);
    BoxDecoration card() => BoxDecoration(
      color: look.fg.withValues(alpha: .03),
      border: Border.all(color: look.fg.withValues(alpha: .10)),
      borderRadius: BorderRadius.circular(radius),
    );
    return PageScroll(
      children: [
        const TabIntro(
          'Generate',
          "A picture from a text, made on this computer's graphics card with stable-diffusion.cpp and the "
              'Z-Image-Turbo model: nothing leaves the computer.',
        ),
        vgap,
        if (_status != null && !_ready) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: card(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnswerText(_status!['error'] is String ? '${_status!['error']}' : _setupText()),
                const SizedBox(height: 8),
                ActionButton('Set up', onPressed: busy ? null : _setup),
              ],
            ),
          ),
          vgap,
        ],
        PromptField(controller: _prompt, minLines: 2, onSubmit: _ready && !busy ? _generate : null),
        vgap,
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Choice<String>(
              value: _size,
              items: [for (final s in sizeChoices) s.$1],
              label: (k) => sizeChoices.firstWhere((s) => s.$1 == k).$2,
              onChanged: (k) => setState(() => _size = k),
            ),
            SmallButton(
              'Clear',
              onPressed: _pictures.isEmpty || _saving > 0 || busy ? null : _clear,
              tooltip: 'Remove the pictures',
            ),
          ],
        ),
        vgap,
        ActionButton(
          'Generate',
          onPressed: _ready && !busy ? _generate : null,
          tooltip: 'Makes one picture; a new one each time (another seed)',
        ),
        if (busy) ...[
          vgap,
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_progress, style: TextStyle(fontSize: 12, color: look.muted)),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: _fraction > 0 ? _fraction : null, minHeight: 6),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SmallButton('Cancel', onPressed: () => _job?.cancel()),
            ],
          ),
        ],
        vgap,
        LayoutBuilder(
          builder: (context, box) {
            final columns = (box.maxWidth / 330).floor().clamp(1, 3);
            final width = (box.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final p in _pictures)
                  Container(
                    width: width,
                    padding: const EdgeInsets.all(10),
                    decoration: card(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: p.prompt,
                          child: SizedBox(
                            height: 300,
                            width: double.infinity,
                            child: Image.file(File(p.path), fit: BoxFit.contain),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Hint('${p.seconds.toStringAsFixed(1)} s · seed ${p.seed}'),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            SmallButton('Save as…', onPressed: () => _save(p)),
                            SmallButton(
                              'Ask about it',
                              onPressed: () => _toVision(p),
                              tooltip: 'Opens it on the Vision tab, for the agents that can see',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
