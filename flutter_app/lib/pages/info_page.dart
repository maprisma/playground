import 'package:maprisma_playground_core/maprisma_playground_core.dart' show tr;
import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets.dart';
import 'page_head.dart';

/// build_info_page: what Maprisma Playground is, where it comes from, and its companions.
class InfoPage extends StatelessWidget {
  const InfoPage({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    Widget card(IconData icon, String name, List<String> lines) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: look.fg.withValues(alpha: .03),
        border: Border.all(color: look.fg.withValues(alpha: .10)),
        borderRadius: BorderRadius.circular(corners(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 30, color: look.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: Theme.of(context).textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w700, color: look.fg),
                ),
                for (final l in lines) Padding(padding: const EdgeInsets.only(top: 4), child: AnswerText(l)),
              ],
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHead(title: tr("Information"), onBack: onBack),
        Expanded(
          child: PageScroll(
            children: [
              card(Icons.sports_esports, 'Maprisma Playground', [
                tr(
                  "Try out the AI agents on your computer, a test per tab: see what an agent and its model can do, play chess against it (or let two play each other), watch a cellular automaton, compare speed and cost, judge two answers blind, test what they see in a picture, make pictures on your own graphics card, and ask your local LLMs.",
                ),
                tr(
                  "For now it works with four agents: Claude Code, Codex, Hermes and Pi. Each is asked once per question in an empty private folder, Claude Code, Hermes and Pi without any tools, Codex in its read-only sandbox; nothing they answer is run.",
                ),
                tr(
                  "What comes from outside (pictures, a video's captions and frames) goes only to the agents without tools: Codex can still read files, so it never gets it.",
                ),
                tr("A port of AI Playground, the Omarchy plugin, to KDE Plasma and COSMIC."),
              ]),
              vgap,
              SectionTitle(tr("Made to go with")),
              vgap,
              card(Icons.hub, 'Maprisma', [
                tr(
                  "Your whole AI setup on one map: coding agents with their plan, limits and usage, local LLMs and their models, MCP servers and skills.",
                ),
                tr(
                  "Together: the agents you set up there (signed in, or connected to a local LLM) are the ones you can test here.",
                ),
              ]),
              vgap,
              card(Icons.apps, 'Maprisma Manager', [
                tr("Installs, updates and removes the Maprisma apps, and puts their icons in the bar."),
              ]),
              vgap,
              card(Icons.rocket_launch_outlined, 'Maprisma Launcher', [
                tr("Apps, shortcuts and updates, with AI package advice"),
              ]),
            ],
          ),
        ),
      ],
    );
  }
}
