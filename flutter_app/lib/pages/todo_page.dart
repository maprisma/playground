import 'package:maprisma_playground_core/maprisma_playground_core.dart' show tr;
import 'package:flutter/material.dart';

import '../widgets.dart';

/// A tab whose port is still to come.
class TodoPage extends StatelessWidget {
  const TodoPage({super.key, required this.title});
  final String title;
  @override
  Widget build(BuildContext context) =>
      PageScroll(children: [TabIntro(title, tr("This tab is being ported from AI Playground."))]);
}
