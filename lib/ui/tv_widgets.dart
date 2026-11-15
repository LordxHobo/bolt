import 'package:flutter/material.dart';

import '../core/tv.dart';

/// On a TV, a white outline (and a slight lift) on whatever inside it has
/// the remote's focus. Does nothing on a phone.
class TvFocusRing extends StatefulWidget {
  const TvFocusRing({super.key, required this.child, this.radius = 12});

  final Widget child;
  final double radius;

  @override
  State<TvFocusRing> createState() => _TvFocusRingState();
}

class _TvFocusRingState extends State<TvFocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    if (!TvMode.isTv) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (mounted && f != _focused) setState(() => _focused = f);
      },
      child: AnimatedScale(
        scale: _focused ? 1.04 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius + 3),
            border: Border.all(color: _focused ? Colors.white : Colors.transparent, width: 3),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// A button for the remote: turns white when it has focus, so it's easy to
/// see from the sofa.
class TvButton extends StatefulWidget {
  const TvButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
    this.selected = false,
    this.expand = false,
    this.focusNode,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  /// Shown as the current choice (e.g. the list in view).
  final bool selected;

  /// Fill the width (menu rows) instead of fitting the label.
  final bool expand;
  final FocusNode? focusNode;

  @override
  State<TvButton> createState() => _TvButtonState();
}

class _TvButtonState extends State<TvButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = _focused ? Colors.black : (widget.selected ? theme.colorScheme.primary : Colors.white);
    final bg = _focused
        ? Colors.white
        : widget.selected
            ? theme.colorScheme.primary.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.08);
    final row = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Icon(widget.icon, color: fg, size: 22),
        const SizedBox(width: 10),
        Flexible(
          child: Text(widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(color: fg, fontWeight: FontWeight.w600)),
        ),
      ],
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onTap: widget.onPressed,
        onFocusChange: (f) => setState(() => _focused = f),
        borderRadius: BorderRadius.circular(24),
        focusColor: Colors.transparent,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(24)),
          child: row,
        ),
      ),
    );
  }
}
