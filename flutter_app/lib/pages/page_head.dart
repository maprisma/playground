import 'package:maprisma_playground_core/maprisma_playground_core.dart' show tr;
import 'package:flutter/material.dart';

import '../widgets.dart';

/// page_head: a bordered Back button and the page's name (Settings, Information, Games).
class PageHead extends StatelessWidget {
  const PageHead({super.key, required this.title, required this.onBack, this.trailing});
  final String title;
  final VoidCallback onBack;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Row(
      children: [
        IconSmallButton(Icons.arrow_back, tooltip: tr("Back (Esc)"), onPressed: onBack),
        const SizedBox(width: 12),
        SectionTitle(title),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}
