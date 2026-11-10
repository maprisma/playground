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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: look.fg.withValues(alpha: .03),
        border: Border.all(color: look.fg.withValues(alpha: .10)),
        borderRadius: BorderRadius.circular(corners(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 30, color: look.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: look.fg)),
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
        PageHead(title: 'Information', onBack: onBack),
        Expanded(
          child: PageScroll(
            children: [
              card(Icons.sports_esports, 'Maprisma Playground', const [
                'Try out the AI agents on your computer, a test per tab: see what an agent and its model can do, '
                    'play chess against it (or let two play each other), watch a cellular automaton, compare speed '
                    'and cost, judge two answers blind, test what they see in a picture, make pictures on your own '
                    'graphics card, and ask your local LLMs.',
                'For now it works with four agents: Claude Code, Codex, Hermes and Pi. They are asked once per '
                    'question without tools, in an empty private folder; nothing they answer is run.',
                'A port of AI Playground, the Omarchy plugin, to KDE Plasma and COSMIC.',
              ]),
              vgap,
              const SectionTitle('Made to go with'),
              vgap,
              card(Icons.hub, 'Maprisma', const [
                'Your whole AI setup on one map: coding agents with their plan, limits and usage, local LLMs and '
                    'their models, MCP servers and skills.',
                'Together: the agents you set up there (signed in, or connected to a local LLM) are the ones you '
                    'can test here.',
              ]),
              vgap,
              card(Icons.apps, 'Maprisma Manager', const [
                'Installs, updates and removes the Maprisma apps, and puts their icons in the bar.',
              ]),
            ],
          ),
        ),
      ],
    );
  }
}
