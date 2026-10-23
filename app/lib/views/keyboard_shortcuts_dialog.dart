import 'package:flutter/material.dart';

import '../models/app_shortcut.dart';

/// Lists every main-window shortcut, grouped, plus the mouse gestures on the
/// timeline — the one place they are all written down in the app.
class KeyboardShortcutsDialog extends StatelessWidget {
  const KeyboardShortcutsDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const KeyboardShortcutsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Keyboard Shortcuts'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final group in AppShortcutGroup.values) ...[
                _heading(theme, group.label),
                for (final shortcut in AppShortcut.values)
                  if (shortcut.group == group)
                    _row(theme, shortcut.label, shortcut.keyLabel),
                const SizedBox(height: 12),
              ],
              _heading(theme, 'Mouse and trackpad'),
              _row(theme, 'Zoom the preview', 'Scroll / pinch'),
              _row(theme, 'Reset the preview zoom', 'Double-click'),
              _row(theme, 'Zoom the timeline', 'Scroll / pinch'),
              _row(theme, 'Pan a zoomed timeline', 'Shift+scroll / swipe'),
              _row(theme, 'Scrub', 'Drag the timeline'),
              const SizedBox(height: 8),
              Text(
                'Shortcuts without Cmd/Ctrl are ignored while you are typing '
                'in a text box.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _heading(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
      );

  Widget _row(ThemeData theme, String label, String keys) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                keys,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
}
