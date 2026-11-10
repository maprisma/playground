import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// The pieces of the plugin's pages (host.py, theme_css.py): the tab intro, the folding card,
/// small and main buttons, the bordered drop-down, the capability mark and answer text.

const gap = 12.0; // ai_core.GAP

/// .am-section-title: 11 px, bold, letter-spaced, in capitals.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: color ?? Look.of(context).fg),
  );
}

/// .am-hint: 13 px in the muted colour.
class Hint extends StatelessWidget {
  const Hint(this.text, {super.key, this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: error ? look.red : look.muted,
        fontWeight: error ? FontWeight.w700 : FontWeight.w400,
        height: 1.35,
      ),
    );
  }
}

/// host.tab_intro: the tab's name in capitals, then what it does.
class TabIntro extends StatelessWidget {
  const TabIntro(this.title, this.text, {super.key});
  final String title, text;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [SectionTitle(title), const SizedBox(height: 14), Hint(text)],
  );
}

/// The capability mark at the end of a card's heading (.am-an-mark): ✓ can, ✗ cannot,
/// ! only slowly, ? not stated, … still running.
enum Mark { yes, no, slow, unknown, running }

class MarkText extends StatelessWidget {
  const MarkText(this.mark, {super.key});
  final Mark mark;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final (text, color) = switch (mark) {
      Mark.yes => ('✓', look.green),
      Mark.no => ('✗', look.red),
      Mark.slow => ('!', look.yellow),
      Mark.unknown => ('?', look.dim),
      Mark.running => ('…', look.dim),
    };
    return SizedBox(
      width: 28,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color, height: 1),
      ),
    );
  }
}

/// host.group_card: a card that folds (.am-help-card.am-group-card). Its heading opens and closes
/// it; the summary shows while it is folded; `action` sits at the right of the heading.
class FoldCard extends StatefulWidget {
  const FoldCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.summary = '',
    this.action,
    this.initiallyOpen = false,
    this.open,
    this.onToggle,
  });
  final String title, summary;
  final IconData? icon;
  final Widget child;
  final Widget? action;
  final bool initiallyOpen;

  /// Controlled from outside when set (with onToggle).
  final bool? open;
  final ValueChanged<bool>? onToggle;
  @override
  State<FoldCard> createState() => _FoldCardState();
}

class _FoldCardState extends State<FoldCard> {
  late bool _open = widget.initiallyOpen;
  bool get open => widget.open ?? _open;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final radius = corners(context);
    return Container(
      decoration: BoxDecoration(
        color: look.fg.withValues(alpha: .03),
        border: Border.all(color: look.fg.withValues(alpha: .10)),
        borderRadius: BorderRadius.circular(radius),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                final now = !open;
                if (widget.open == null) setState(() => _open = now);
                widget.onToggle?.call(now);
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 34),
                child: Row(
                  children: [
                    Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18, color: look.fg),
                    const SizedBox(width: 8),
                    if (widget.icon != null) ...[Icon(widget.icon, size: 18, color: look.fg), const SizedBox(width: 8)],
                    SectionTitle(widget.title),
                    const SizedBox(width: 8),
                    Expanded(
                      child: open || widget.summary.isEmpty
                          ? const SizedBox()
                          : Text(
                              widget.summary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: look.dim),
                            ),
                    ),
                    ?widget.action,
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: open
                ? Padding(padding: const EdgeInsets.only(top: gap, bottom: 6), child: widget.child)
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// .am-small-btn: a small bordered button.
class SmallButton extends StatelessWidget {
  const SmallButton(this.label, {super.key, this.onPressed, this.tooltip, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final button = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: look.fg,
        side: BorderSide(color: look.fg.withValues(alpha: .35)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(corners(context))),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        minimumSize: const Size(0, 30),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 16), if (label.isNotEmpty) const SizedBox(width: 6)],
          if (label.isNotEmpty) Text(label),
        ],
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// .am-small-btn with a symbol only: what it does in its tooltip.
class IconSmallButton extends StatelessWidget {
  const IconSmallButton(this.icon, {super.key, required this.tooltip, this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    return Tooltip(
      message: tooltip,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: look.fg,
          side: BorderSide(color: look.fg.withValues(alpha: .35)),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          minimumSize: const Size(38, 26),
        ),
        child: Icon(icon, size: 16),
      ),
    );
  }
}

/// .am-action-btn.am-primary: the tab's main button (Ask), large, in the accent colour.
class ActionButton extends StatelessWidget {
  const ActionButton(this.label, {super.key, this.onPressed, this.tooltip});
  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final button = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: look.fg,
        backgroundColor: look.accent.withValues(alpha: .25),
        disabledBackgroundColor: look.fg.withValues(alpha: .05),
        side: BorderSide(color: onPressed == null ? look.fg.withValues(alpha: .2) : look.accent),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(corners(context))),
        minimumSize: const Size(140, 36),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// A Gtk.DropDown as the plugin draws it: a bordered pill with the choice and a chevron.
class Choice<T> extends StatelessWidget {
  const Choice({
    super.key,
    required this.value,
    required this.items,
    required this.label,
    this.onChanged,
    this.tooltip,
    this.empty = '',
  });
  final T? value;
  final List<T> items;
  final String Function(T) label;
  final ValueChanged<T>? onChanged;
  final String? tooltip;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final radius = corners(context);
    final enabled = onChanged != null && items.isNotEmpty;
    final text = value == null ? empty : label(value as T);
    Widget pill = Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 10, 4),
      decoration: BoxDecoration(
        border: Border.all(color: look.fg.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: enabled ? look.fg : look.dim),
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.expand_more, size: 18, color: enabled ? look.fg : look.dim),
        ],
      ),
    );
    if (enabled) {
      pill = PopupMenuButton<int>(
        tooltip: tooltip ?? '',
        position: PopupMenuPosition.under,
        onSelected: (i) => onChanged!(items[i]),
        itemBuilder: (_) => [
          for (var i = 0; i < items.length; i++)
            PopupMenuItem<int>(
              value: i,
              height: 32,
              child: Row(
                children: [
                  SizedBox(width: 22, child: items[i] == value ? Icon(Icons.check, size: 16, color: look.accent) : null),
                  Flexible(child: Text(label(items[i]), overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
        ],
        child: MouseRegion(cursor: SystemMouseCursors.click, child: pill),
      );
    }
    return pill;
  }
}

/// host.prompt_view: a framed, wrapping text field for a question.
class PromptField extends StatelessWidget {
  const PromptField({super.key, required this.controller, this.minLines = 4, this.hint, this.onSubmit});
  final TextEditingController controller;
  final int minLines;
  final String? hint;
  final VoidCallback? onSubmit;
  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      minLines: minLines,
      maxLines: 12,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(hintText: hint),
    );
    if (onSubmit == null) return field;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): onSubmit!},
      child: field,
    );
  }
}

/// host.answer_label (.am-chess-said): selectable, wrapping.
class AnswerText extends StatelessWidget {
  const AnswerText(this.text, {super.key, this.error = false, this.mono = false});
  final String text;
  final bool error, mono;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    return SelectableText(
      text,
      style: TextStyle(
        fontSize: 13,
        height: 1.4,
        color: error ? look.red : look.fg,
        fontFamily: mono ? 'monospace' : null,
      ),
    );
  }
}

/// A check box with its label, as the plugin's agent checks (Gtk.CheckButton).
class CheckLabel extends StatelessWidget {
  const CheckLabel({super.key, required this.label, required this.value, this.onChanged, this.tooltip});
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final row = InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: value,
                onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
                activeColor: look.accent,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label, style: TextStyle(fontSize: 13, color: onChanged == null ? look.dim : look.fg)),
            ),
          ],
        ),
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip!, child: row);
  }
}

/// A page's scroller with the plugin's padding (17 px, room for the scroll bar).
class PageScroll extends StatelessWidget {
  const PageScroll({super.key, required this.children, this.controller});
  final List<Widget> children;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    controller: controller,
    padding: const EdgeInsets.fromLTRB(17, 6, 31, 17),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );
}

/// Spacing between a page's blocks.
const vgap = SizedBox(height: gap);
