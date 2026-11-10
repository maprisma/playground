import 'package:flutter/material.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';
import 'page_head.dart';

/// build_settings_page: General (Corners, Text in choice boxes), then how it works, in cards that
/// fold. No Language and no Look: Maprisma Playground speaks English and follows the desktop.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.host, required this.onBack, required this.onLookChanged, this.rounding});
  final Host host;
  final VoidCallback onBack, onLookChanged;
  final int? rounding;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  void _save(String key, String value) {
    try {
      widget.host.settings.update({key: value});
    } on Object catch (e) {
      widget.host.toast('The setting could not be saved: $e');
    }
    setState(() {});
    widget.onLookChanged();
  }

  Widget _row(String title, String hint, Widget choice) {
    final look = Look.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 14, color: look.fg)),
                const SizedBox(height: 2),
                Text(hint, style: TextStyle(fontSize: 12, color: look.muted)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          choice,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final s = widget.host.settings;
    final like = widget.rounding == null ? 'Like windows' : 'Like windows (${widget.rounding} px)';
    const cornerValues = ['windows', 'rounded', 'square'];
    final cornerLabels = [like, 'Rounded', 'Square'];
    final group = Container(
      decoration: BoxDecoration(
        color: look.fg.withValues(alpha: .03),
        border: Border.all(color: look.fg.withValues(alpha: .10)),
        borderRadius: BorderRadius.circular(corners(context)),
      ),
      child: Column(
        children: [
          _row(
            'Corners',
            "The corners of cards and buttons: like the desktop's windows, rounded or square.",
            Choice<String>(
              value: s.text('corners'),
              items: cornerValues,
              label: (v) => cornerLabels[cornerValues.indexOf(v)],
              onChanged: (v) => _save('corners', v),
            ),
          ),
          Divider(color: look.fg.withValues(alpha: .08)),
          _row(
            'Text in choice boxes',
            "The chosen value in drop-down boxes: bright (the theme's text colour) or dimmed.",
            Choice<String>(
              value: s.text('choice_text'),
              items: const ['bright', 'dim'],
              label: (v) => v == 'dim' ? 'Dimmed' : 'Bright',
              onChanged: (v) => _save('choice_text', v),
            ),
          ),
        ],
      ),
    );
    List<Widget> lines(List<String> texts) => [
      for (final t in texts) Padding(padding: const EdgeInsets.only(bottom: 6), child: AnswerText(t)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHead(title: 'Settings', onBack: widget.onBack),
        Expanded(
          child: PageScroll(
            children: [
              const SectionTitle('General'),
              vgap,
              group,
              vgap,
              FoldCard(
                title: 'One agent or none',
                initiallyOpen: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: lines(const [
                    'Most tests compare, but one agent is enough:',
                    'Chess: play against it, or let it play itself (Agent against agent), each side with its own '
                        'strength, for example Master against Beginner.',
                    'Speed and cost, Head to head: the models of the local LLM servers running here (see Local LLMs) '
                        'take part next to the agents, so your agent can meet a local model, or two local models each '
                        'other. The same one twice in Head to head keeps no score.',
                    'Vision: only agents that take pictures and run without tools (Claude Code, Pi). Local LLMs and '
                        'the Automaton: no agent needed.',
                    'No agent offered: install one and sign in, or connect it to a local LLM (Maprisma does both). An '
                        'agent that is installed but not signed in is not offered, since it could not answer.',
                  ]),
                ),
              ),
              vgap,
              FoldCard(
                title: 'Several local models at once',
                initiallyOpen: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: lines(const [
                    'When a test would use two or more different local models at the same time (two models on the '
                        'Local LLMs tab, local models or agents that use a local LLM in Speed and cost or Head to head, '
                        'such agents in Vision or agent against agent chess), Maprisma Playground first checks whether '
                        'they fit in the GPU memory.',
                    'Free GPU memory: what the graphics card reports (AMD through the kernel, NVIDIA through '
                        'nvidia-smi). A model that is loaded already needs nothing more. Any other model needs about its '
                        'file size plus a tenth, and half a GB for its context. The size comes from Ollama, or from the '
                        '.gguf file in the usual model folders.',
                    'Which local model an agent uses comes from its own settings, as Maprisma Playground reads them.',
                    'When they fit, the test simply starts. When they do not, or when a size could not be found, you '
                        'choose: One after the other (the next model is asked only when the one before has answered; '
                        'Ollama is asked to unload it first), Both at once, or Cancel. In chess the agents answer in '
                        'turn anyway: there you choose Play anyway or Cancel.',
                    'Without GPU figures (no AMD or NVIDIA card found) nothing is checked.',
                  ]),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
