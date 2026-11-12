import 'package:maprisma_playground_core/maprisma_playground_core.dart' show tr;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../backend.dart';
import '../contestants.dart';
import '../theme.dart';
import '../widgets.dart';

String get visionPrompt => tr("Describe what you see in two or three sentences.");
String get videoPrompt =>
    tr("These are frames of one video, in order. Describe what happens in two or three sentences.");

/// A picture handed over by another tab (Generate's Ask about it): the Vision tab takes it.
final visionInbox = ValueNotifier<String?>(null);

/// VisionTab: a picture, a screenshot or frames of a video, for the agents that see and run
/// without tools. The core checks, scales and re-saves every picture first (no metadata goes out).
class VisionPage extends StatefulWidget {
  const VisionPage({super.key, required this.host, required this.playground});
  final Host host;
  final Playground playground;
  @override
  State<VisionPage> createState() => _VisionPageState();
}

class _VisionPageState extends State<VisionPage> {
  String _defaultPrompt = visionPrompt;
  final _prompt = TextEditingController(text: visionPrompt);
  final Set<String> _ticked = {};
  bool _tickedSet = false;
  List<String> _images = []; // prepared copies in the core's private folder
  List<Run> _runs = const [];
  int _run = 0;
  bool _busy = false;
  Timer? _clock;
  bool _asking = false;
  int _load = 0; // the newest load; an older one that ends later is dropped

  /// A picture may come from the web and carry planted words: only agents without tools see it
  /// (Codex can read files, so not Codex).
  List<Contestant> get _agents => [
    for (final a in widget.playground.ready)
      if (a.takesImages && a.readsUntrusted) Contestant.agent(a),
  ];

  @override
  void didUpdateWidget(covariant VisionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final translated = visionPrompt;
    if (_prompt.text == _defaultPrompt) _prompt.text = translated;
    _defaultPrompt = translated;
  }

  @override
  void initState() {
    super.initState();
    widget.playground.addListener(_changed);
    visionInbox.addListener(_inbox);
    _inbox();
  }

  void _changed() => setState(() {});

  void _inbox() {
    final path = visionInbox.value;
    if (path == null) return;
    visionInbox.value = null;
    _loadPictures(
      () async => [
        await _prepare({'path': path}),
      ],
      tr("That picture cannot be read."),
      visionPrompt,
    );
  }

  @override
  void dispose() {
    widget.playground.removeListener(_changed);
    visionInbox.removeListener(_inbox);
    _clock?.cancel();
    for (final r in _runs) {
      r.job?.cancel();
    }
    _prompt.dispose();
    super.dispose();
  }

  Future<String?> _prepare(Map<String, dynamic> params) async {
    try {
      final r = await widget.playground.backend.call('pictures.prepare', params);
      return r['path'] as String?;
    } on CoreFailure {
      return null;
    }
  }

  Future<void> _clear() async {
    _load++;
    if (!mounted) return;
    final mine = _images; // only this tab's pictures: a chess import keeps its frames
    setState(() => _images = []);
    if (mine.isEmpty) return;
    try {
      await widget.playground.backend.call('pictures.clear', {'paths': mine});
    } on Object {
      // nothing to remove
    }
  }

  /// Prepared pictures replace the ones shown; `failed` is shown when none could be read.
  Future<void> _loadPictures(Future<List<String?>> Function() work, String failed, String prompt) async {
    await _clear();
    if (!mounted) return;
    final mine = _load;
    setState(() => _busy = true);
    List<String> paths;
    try {
      paths = (await work()).whereType<String>().toList();
    } on CoreFailure catch (e) {
      paths = [];
      failed = e.message.isEmpty ? failed : e.message;
    }
    if (!mounted || mine != _load) return;
    setState(() {
      _busy = false;
      _images = paths;
      if ([visionPrompt, videoPrompt, ''].contains(_prompt.text.trim())) _prompt.text = prompt;
    });
    if (paths.isEmpty) widget.host.toast(failed);
  }

  Future<void> _pickPicture() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: tr("A picture"), mimeTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif']),
      ],
    );
    if (file == null || !mounted) return;
    await _loadPictures(
      () async => [
        await _prepare({'path': file.path}),
      ],
      tr("That picture cannot be read."),
      visionPrompt,
    );
  }

  Future<void> _screenshot() async {
    await _clear();
    if (!mounted) return;
    final mine = _load;
    widget.host.toast(tr("The screenshot is taken in 3 seconds."));
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted || mine != _load) return; // the page went away, or something else was loaded
    await _loadPictures(
      () async {
        final r = await widget.playground.backend.call('pictures.screenshot');
        return [r['path'] as String?];
      },
      tr("The screenshot did not work."),
      visionPrompt,
    );
  }

  Future<void> _pickVideo() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: tr("A video"), mimeTypes: ['video/*']),
      ],
    );
    if (file == null || !mounted) return;
    widget.host.toast(tr("Taking frames from the video…"));
    await _loadPictures(
      () async {
        final r = await widget.playground.backend.call('pictures.video_frames', {'path': file.path});
        return [for (final p in (r['paths'] as List? ?? const [])) '$p'];
      },
      tr("No frames could be taken from that video."),
      videoPrompt,
    );
  }

  Set<String> get _chosenIds {
    if (!_tickedSet) {
      final saved = widget.host.settings.texts('playground_agents');
      return {
        for (final c in _agents)
          if (saved.isEmpty || saved.contains(c.id)) c.id,
      };
    }
    return _ticked;
  }

  Future<void> _ask() async {
    if (_images.isEmpty) {
      widget.host.toast(tr("Pick a picture, a screenshot or a video first."));
      return;
    }
    final prompt = _prompt.text.trim();
    final ids = _chosenIds;
    final chosen = _agents.where((c) => ids.contains(c.id)).toList();
    if (prompt.isEmpty || chosen.isEmpty) return;
    final oneByOne = await widget.playground.gpuGuard(context, chosen);
    if (oneByOne == null || !mounted) return;
    for (final r in _runs) {
      r.job?.cancel();
    }
    final run = ++_run;
    setState(() {
      _runs = [for (final c in chosen) Run(c)];
      _asking = true;
    });
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(milliseconds: 500), (_) => mounted ? setState(() {}) : null);
    await askAll(
      widget.playground.backend,
      _runs,
      prompt,
      images: List.of(_images),
      untrusted: true,
      oneByOne: oneByOne,
      current: () => mounted && run == _run,
      update: () => setState(() {}),
    );
    if (run == _run) {
      _clock?.cancel();
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final agents = _agents;
    final chosen = _chosenIds;
    return PageScroll(
      children: [
        TabIntro(
          tr("Vision"),
          tr(
            "A picture, a screenshot or frames of a video for the agents that can see and run without tools (Claude Code, Pi): text in a picture cannot make them read your files. Pictures are scaled down and saved again first, so no photo metadata goes out.",
          ),
        ),
        vgap,
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SmallButton(tr("Picture…"), onPressed: _busy || _asking ? null : _pickPicture),
            SmallButton(
              tr("Screenshot in 3 s"),
              onPressed: _busy || _asking ? null : _screenshot,
              tooltip: tr("The whole screen, three seconds after the click"),
            ),
            SmallButton(
              tr("Video…"),
              onPressed: _busy || _asking ? null : _pickVideo,
              tooltip: tr("Four frames spread over the video"),
            ),
            SmallButton(
              tr("Clear"),
              onPressed: _images.isEmpty || _asking ? null : _clear,
              tooltip: tr("Remove the pictures (the answers stay)"),
            ),
          ],
        ),
        if (_busy) ...[const SizedBox(height: 8), const LinearProgressIndicator(minHeight: 2)],
        if (_images.isNotEmpty) ...[
          vgap,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _images)
                ClipRRect(
                  borderRadius: BorderRadius.circular(cornerSizes(context).control),
                  child: Container(
                    width: 160,
                    height: 100,
                    color: look.fg.withValues(alpha: .04),
                    child: Image.file(File(p), fit: BoxFit.contain),
                  ),
                ),
            ],
          ),
        ],
        vgap,
        PromptField(controller: _prompt, onSubmit: _ask),
        vgap,
        if (agents.isEmpty)
          Hint(tr("No agent that can see and runs without tools is set up (Claude Code or Pi)."))
        else
          Wrap(
            spacing: 24,
            runSpacing: 4,
            children: [
              for (final c in agents)
                CheckLabel(
                  label: c.name,
                  value: chosen.contains(c.id),
                  onChanged: (v) => setState(() {
                    if (!_tickedSet) {
                      _ticked.addAll(chosen);
                      _tickedSet = true;
                    }
                    v ? _ticked.add(c.id) : _ticked.remove(c.id);
                  }),
                ),
            ],
          ),
        vgap,
        ActionButton(
          tr("Ask"),
          onPressed: agents.isEmpty ? null : _ask,
          tooltip: tr("Every ticked agent gets the pictures and the question"),
        ),
        vgap,
        for (final r in _runs) RunCard(r),
      ],
    );
  }
}
