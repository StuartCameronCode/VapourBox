import 'package:flutter/material.dart';

/// A small "NEW" pill for a filter or parameter [WhatsNewService.isNew]
/// considers new for this session.
///
/// Uses the tertiary color role rather than primary so it reads as a
/// distinct signal from the pass list's primary-colored "Suggested" badge —
/// two different things can be true of the same row.
class NewBadge extends StatelessWidget {
  const NewBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'NEW',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onTertiaryContainer,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 0.4,
            ),
      ),
    );
  }
}

/// A "NEW" label overlaid on [child]'s top-right corner, for a control with no
/// room for a [NewBadge] pill beside it (a tab label, a button, the preview's
/// view-mode pill). Draws [child] alone when [visible] is false.
class NewCornerBadge extends StatelessWidget {
  final bool visible;
  final Widget child;

  const NewCornerBadge({super.key, required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Badge(
      isLabelVisible: visible,
      backgroundColor: scheme.tertiaryContainer,
      textColor: scheme.onTertiaryContainer,
      textStyle: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.4),
      offset: const Offset(10, -8),
      label: const Text('NEW'),
      child: child,
    );
  }
}
