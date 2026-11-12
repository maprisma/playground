import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart'
    show
        Dictation,
        dictationDisplayName,
        dictationNotSetUpTip,
        dictationSetupButton,
        dictationSetupText,
        dictationSetupTitle,
        dictationTip,
        tr,
        trf;

import 'theme.dart';

/// The pieces of the plugin's pages (host.py, theme_css.py): the tab intro, the folding card,
/// small and main buttons, the bordered drop-down, the capability mark and answer text.

const gap = 12.0; // ai_core.GAP

/// One height for the small controls: small buttons, choice boxes, fields (the plugin's 22 px).
const controlHeight = 22.0;

/// .am-section-title: the 11 px bold upper-case heading (the one raw size the layout rules allow).
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

/// .am-hint: 12 px in the muted colour.
class Hint extends StatelessWidget {
  const Hint(this.text, {super.key, this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall!.copyWith(color: error ? look.red : look.muted,
        fontWeight: error ? FontWeight.w700 : FontWeight.w400,
        height: 1.35,
      ),
    );
  }
}

/// host.tab_intro: the tab's name in capitals, then what it does, close together (6 px).
class TabIntro extends StatelessWidget {
  const TabIntro(this.title, this.text, {super.key});
  final String title, text;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [SectionTitle(title), const SizedBox(height: 4), Hint(text)],
  );
}

/// The capability mark at the end of a card's heading (.am-an-mark): ✓ can, ✗ cannot,
/// ! only slowly, ? not stated, … still running, – skipped.
enum Mark { yes, no, slow, unknown, running, skipped }

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
      Mark.skipped => ('–', look.dim),
    };
    return SizedBox(
      width: 28,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w800, color: color, height: 1),
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
                              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: look.dim),
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
                ? Padding(
                    padding: const EdgeInsets.only(top: gap, bottom: 8),
                    child: widget.child,
                  )
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
        // .am-small-btn: the controls' height (22 px) and corners (Settings › Corners, at most 8).
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, controlHeight),
        visualDensity: VisualDensity.standard,
        textStyle: Theme.of(context).textTheme.labelMedium!.copyWith(fontWeight: FontWeight.w700),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 15), if (label.isNotEmpty) const SizedBox(width: 4)],
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(26, controlHeight),
          visualDensity: VisualDensity.standard,
        ),
        child: Icon(icon, size: 15),
      ),
    );
  }
}

/// .am-action-btn.am-primary: the tab's main button (Ask), larger, with the accent border.
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
        minimumSize: const Size(120, 34),
        visualDensity: VisualDensity.standard,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
        textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(fontWeight: FontWeight.w600),
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
    final radius = cornerSizes(context).control;
    final enabled = onChanged != null && items.isNotEmpty;
    final text = value == null ? empty : label(value as T);
    Widget pill = Container(
      constraints: const BoxConstraints(minHeight: controlHeight),
      padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
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
              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: enabled ? look.fg : look.dim),
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.expand_more, size: 16, color: enabled ? look.fg : look.dim),
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
                  SizedBox(
                    width: 22,
                    child: items[i] == value ? Icon(Icons.check, size: 16, color: look.accent) : null,
                  ),
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

/// host.prompt_view: a framed, wrapping text field for a question, 72 px high to start with
/// (three lines of 13 px text), with the microphone in its lower right corner on Omarchy
/// (dictation.with_mic); the text keeps clear of it.
class PromptField extends StatefulWidget {
  const PromptField({super.key, required this.controller, this.minLines = 3, this.hint, this.onSubmit});
  final TextEditingController controller;
  final int minLines;
  final String? hint;
  final VoidCallback? onSubmit;
  @override
  State<PromptField> createState() => _PromptFieldState();
}

class _PromptFieldState extends State<PromptField> {
  final _focus = FocusNode(debugLabel: 'question');
  late final bool _mic = Dictation.instance.supported;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget field = TextField(
      controller: widget.controller,
      focusNode: _focus,
      minLines: widget.minLines,
      maxLines: 12,
      style: Theme.of(context).textTheme.bodyMedium!.copyWith(height: 1.4),
      decoration: InputDecoration(
        hintText: widget.hint,
        contentPadding: _mic ? const EdgeInsets.fromLTRB(8, 8, 40, 8) : null,
      ),
    );
    if (widget.onSubmit != null) {
      field = CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): widget.onSubmit!},
        child: field,
      );
    }
    if (!_mic) return field;
    return Stack(
      children: [
        field,
        Positioned(
          right: 6,
          bottom: 6,
          child: DictateButton(controller: widget.controller, focus: _focus),
        ),
      ],
    );
  }
}

/// dictation.mic_button: the microphone of a question field, a plain button that works like
/// Omarchy's dictation key. A click asks for the dictation program afresh; with one set up it puts
/// the cursor at the end of the field and runs `omarchy-dictation toggle` (which starts dictation,
/// or stops it when it runs; the program shows its own indicator); without one it shows how to set
/// one up and runs nothing. No recording state is kept here.
class DictateButton extends StatefulWidget {
  const DictateButton({super.key, required this.controller, required this.focus});
  final TextEditingController controller;
  final FocusNode focus;
  @override
  State<DictateButton> createState() => _DictateButtonState();
}

class _DictateButtonState extends State<DictateButton> {
  final _dictation = Dictation.instance;
  String? _name;

  /// A click is being answered (the program is asked, or the set-up hint is open).
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _dictation.backend().then((name) {
      if (mounted) setState(() => _name = name);
    });
  }

  String get _tip => _name == null ? tr(dictationNotSetUpTip) : trf(dictationTip, [dictationDisplayName(_name!)]);

  Future<void> _click() async {
    if (_busy) return;
    _busy = true;
    try {
      final name = await _dictation.backend(fresh: true); // set up meanwhile? ask again
      if (!mounted) return;
      setState(() => _name = name);
      if (name == null) {
        await showDictationSetup(context, _dictation);
        return;
      }
      // The words go where the cursor is: at the end of this field.
      widget.controller.selection = TextSelection.collapsed(offset: widget.controller.text.length);
      widget.focus.requestFocus();
      _dictation.toggle();
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    return Tooltip(
      message: _tip,
      child: OutlinedButton(
        key: const ValueKey('dictate'),
        onPressed: _click,
        style: OutlinedButton.styleFrom(
          foregroundColor: look.fg,
          backgroundColor: look.bg,
          side: BorderSide(color: look.fg.withValues(alpha: .35)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
          padding: EdgeInsets.zero,
          minimumSize: const Size(26, controlHeight),
          fixedSize: const Size(26, controlHeight),
          visualDensity: VisualDensity.standard,
        ),
        child: Icon(Icons.mic_none, size: 15, color: look.fg),
      ),
    );
  }
}

/// dictation.setup_dialog: no dictation program yet; Close, or Omarchy's dictation menu.
Future<void> showDictationSetup(BuildContext context, Dictation dictation) async {
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr(dictationSetupTitle), style: Theme.of(context).textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w700)),
      content: SizedBox(width: 440, child: AnswerText(tr(dictationSetupText))),
      actions: [
        SmallButton(tr("Close"), onPressed: () => Navigator.pop(context, false)),
        ActionButton(tr(dictationSetupButton), onPressed: () => Navigator.pop(context, true)),
      ],
    ),
  );
  if (open == true) dictation.openSetup();
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
      style: Theme.of(context).textTheme.bodyMedium!.copyWith(height: 1.4,
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
      borderRadius: BorderRadius.circular(cornerSizes(context).small),
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Padding(
        padding: const EdgeInsets.all(4),
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
              child: Text(label, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: onChanged == null ? look.dim : look.fg)),
            ),
          ],
        ),
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip!, child: row);
  }
}

/// A page's scroller with the plugin's padding (17 px on both sides, as the other pages).
class PageScroll extends StatelessWidget {
  const PageScroll({super.key, required this.children, this.controller});
  final List<Widget> children;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    controller: controller,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );
}

/// Spacing between a page's blocks.
const vgap = SizedBox(height: gap);
