import 'package:maprisma_playground_core/maprisma_playground_core.dart' show tr, trf;

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

String get generatePrompt => tr("A red fox sitting in a snowy forest at dawn, soft light, photograph");
List<(String, String)> get sizeChoices => <(String, String)>[
  ('square', tr("Square · 1024 × 1024")),
  ('landscape', tr("Landscape · 1280 × 768")),
  ('portrait', tr("Portrait · 768 × 1280")),
];

String _gigabytes(num size) => trf("{0} GB", [(size / (1 << 30)).toStringAsFixed(1)]);

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
  String _defaultPrompt = generatePrompt;
  final _prompt = TextEditingController(text: generatePrompt);
  Map<String, dynamic>? _status;
  String _size = 'square';
  final List<_Picture> _pictures = [];
  Job? _job;
  double _fraction = 0;
  int _saving = 0; // Save as… copies still running: Clear waits for them
  String _progress = '';

  @override
  void didUpdateWidget(covariant GeneratePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final translated = generatePrompt;
    if (_prompt.text == _defaultPrompt) _prompt.text = translated;
    _defaultPrompt = translated;
  }

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
        widget.host.toast(
          method == 'generate.setup'
              ? trf("Setting up stopped: {0}", [e.message])
              : trf("No picture: {0}", [e.message]),
        );
      }
      return null;
    } finally {
      _job = null;
      if (mounted) setState(() {});
      _refresh();
    }
  }

  Future<void> _setup() async {
    final r = await _run(tr("Downloading…"), 'generate.setup', const {});
    if (r != null && mounted) widget.host.toast(tr("Generate is set up."));
  }

  Future<void> _generate() async {
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      widget.host.toast(tr("Write what the picture should show first."));
      return;
    }
    final seed = 1 + Random().nextInt((1 << 31) - 2); // a new picture each time
    final r = await _run(tr("Generating…"), 'generate.run', {'prompt': prompt, 'size': _size, 'seed': seed});
    if (r == null || !mounted) return;
    setState(
      () => _pictures.insert(
        0, // the newest first
        _Picture('${r['path']}', prompt, ((r['seconds'] as num?) ?? 0).toDouble(), (r['seed'] as int?) ?? seed),
      ),
    );
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
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG', extensions: ['png']),
      ],
    );
    if (to == null || !mounted) return;
    setState(() => _saving++);
    try {
      await File(p.path).copy(to.path);
      widget.host.toast(trf("Saved: {0}", [to.path.split('/').last]));
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
      if (s['program'] != true) tr("stable-diffusion.cpp (its Vulkan build from GitHub, about 40 MB)"),
      if (s['to_download'] is num && (s['to_download'] as num) > 0)
        trf("the Z-Image-Turbo model with its text encoder ({0} from Hugging Face)", [
          _gigabytes(s['to_download'] as num),
        ]),
    ];
    final folder = '${s['folder'] ?? '~/.local/share/maprisma-playground'}';
    return trf(
      "Needed first: {0}. Every file is checked against its published SHA-256 before it is kept; they go to {1}. A cancelled download goes on where it stopped.",
      [parts.isEmpty ? tr("the program and the model") : parts.join('; '), folder],
    );
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
        TabIntro(
          tr("Generate"),
          tr(
            "A picture from a text, made on this computer's graphics card with stable-diffusion.cpp and the Z-Image-Turbo model: nothing leaves the computer.",
          ),
        ),
        vgap,
        if (_status != null && !_ready) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: card(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnswerText(_status!['error'] is String ? '${_status!['error']}' : _setupText()),
                const SizedBox(height: 8),
                ActionButton(tr("Set up"), onPressed: busy ? null : _setup),
              ],
            ),
          ),
          vgap,
        ],
        PromptField(controller: _prompt, onSubmit: _ready && !busy ? _generate : null),
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
              tr("Clear"),
              onPressed: _pictures.isEmpty || _saving > 0 || busy ? null : _clear,
              tooltip: tr("Remove the pictures"),
            ),
          ],
        ),
        vgap,
        ActionButton(
          tr("Generate"),
          onPressed: _ready && !busy ? _generate : null,
          tooltip: tr("Makes one picture; a new one each time (another seed)"),
        ),
        if (busy) ...[
          vgap,
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_progress, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: look.muted)),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: _fraction > 0 ? _fraction : null, minHeight: 6),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SmallButton(tr("Cancel"), onPressed: () => _job?.cancel()),
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
                    padding: const EdgeInsets.all(12),
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
                        const SizedBox(height: 8),
                        Hint(trf("{0} s · seed {1}", [p.seconds.toStringAsFixed(1), p.seed])),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            SmallButton(tr("Save as…"), onPressed: () => _save(p)),
                            SmallButton(
                              tr("Ask about it"),
                              onPressed: () => _toVision(p),
                              tooltip: tr("Opens it on the Vision tab, for the agents that can see"),
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
