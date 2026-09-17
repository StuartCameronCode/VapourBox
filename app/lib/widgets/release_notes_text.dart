import 'package:flutter/material.dart';

/// Renders a GitHub release body as plain formatted text — headings, bullet
/// and numbered lists, bold, inline code, and horizontal rules — without a
/// markdown package. GitHub release notes are almost always just that
/// handful of block types, so a small line-by-line pass covers what's
/// actually shown; anything it doesn't recognize (tables, images, nested
/// blockquotes) just falls through as a plain paragraph rather than being
/// misrendered.
///
/// Wrapped in a [SelectionArea] so the rendered text stays copyable, the one
/// thing a plain [SelectableText] gave up by going through this instead.
class ReleaseNotesText extends StatelessWidget {
  final String markdown;

  const ReleaseNotesText({super.key, required this.markdown});

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _buildBlocks(context),
      ),
    );
  }

  List<Widget> _buildBlocks(BuildContext context) {
    final theme = Theme.of(context);
    final lines = markdown.replaceAll('\r\n', '\n').split('\n');
    final blocks = <Widget>[];

    final heading = RegExp(r'^(#{1,6})\s+(.*)');
    final bullet = RegExp(r'^[-*]\s+(.*)');
    final numbered = RegExp(r'^\d+\.\s+(.*)');
    final rule = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');

    for (final rawLine in lines) {
      final line = rawLine.trim();

      if (line.isEmpty) {
        blocks.add(const SizedBox(height: 8));
        continue;
      }

      if (rule.hasMatch(line)) {
        blocks.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 1),
        ));
        continue;
      }

      final headingMatch = heading.firstMatch(line);
      if (headingMatch != null) {
        final level = headingMatch.group(1)!.length;
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: _richText(
            headingMatch.group(2)!,
            theme,
            base: (level == 1
                    ? theme.textTheme.titleMedium
                    : level == 2
                        ? theme.textTheme.titleSmall
                        : theme.textTheme.bodyLarge)
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ));
        continue;
      }

      final bulletMatch = bullet.firstMatch(line);
      final numberedMatch = numbered.firstMatch(line);
      if (bulletMatch != null || numberedMatch != null) {
        final marker = bulletMatch != null
            ? '•'
            : '${line.split('.').first}.';
        final text = (bulletMatch ?? numberedMatch)!.group(1)!;
        blocks.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                child: Text(marker, style: theme.textTheme.bodyMedium),
              ),
              Expanded(child: _richText(text, theme)),
            ],
          ),
        ));
        continue;
      }

      blocks.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: _richText(line, theme),
      ));
    }

    return blocks;
  }

  /// Inline `**bold**` and `` `code` `` within one line of text.
  Widget _richText(String text, ThemeData theme, {TextStyle? base}) {
    final baseStyle = base ?? theme.textTheme.bodyMedium?.copyWith(height: 1.4);
    final pattern = RegExp(r'\*\*(.+?)\*\*|`(.+?)`');

    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start)));
      }
      final bold = match.group(1);
      final code = match.group(2);
      if (bold != null) {
        spans.add(TextSpan(
          text: bold,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      } else if (code != null) {
        spans.add(TextSpan(
          text: code,
          style: const TextStyle(fontFamily: 'monospace'),
        ));
      }
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }

    return RichText(text: TextSpan(style: baseStyle, children: spans));
  }
}
