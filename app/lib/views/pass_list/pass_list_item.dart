import 'package:flutter/material.dart';

import '../../models/pass_relevance.dart';
import '../../models/processing_pipeline.dart';

/// A single item in the pass list showing a processing pass.
///
/// Tapping the row expands it in place: [expandedChild] (the pass's settings)
/// renders directly underneath the row rather than in a separate panel, so the
/// options stay visually attached to the filter they belong to.
class PassListItem extends StatelessWidget {
  final PassType passType;
  final String title;
  final String subtitle;
  final bool isEnabled;
  final bool isExpanded;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  /// How much this pass has to do with the loaded file. Drives a badge or a
  /// muted note only — it never reorders the row or disables the control, since
  /// detection is a hint and is sometimes wrong.
  final PassRelevanceResult relevance;

  /// Settings shown inline while expanded. Only built for the expanded item.
  final Widget? expandedChild;

  const PassListItem({
    super.key,
    required this.passType,
    required this.title,
    required this.subtitle,
    required this.isEnabled,
    required this.isExpanded,
    required this.onToggle,
    required this.onTap,
    this.relevance = PassRelevanceResult.neutral,
    this.expandedChild,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: isExpanded ? 6 : 2),
      child: Material(
        color: isExpanded
            ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isExpanded
                  ? colorScheme.primary.withValues(alpha: 0.4)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildRow(context, colorScheme),

              // Inline settings — animates open/closed.
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: isExpanded && expandedChild != null
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Divider(
                              height: 12,
                              color: colorScheme.outline.withValues(alpha: 0.2),
                            ),
                            expandedChild!,
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, ColorScheme colorScheme) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            // Checkbox for enable/disable
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: isEnabled,
                onChanged: (value) => onToggle(value ?? false),
                visualDensity: VisualDensity.compact,
              ),
            ),

            const SizedBox(width: 8),

            // Pass icon
            Icon(
              _getIconForPass(passType),
              size: 20,
              color: isEnabled
                  ? colorScheme.primary
                  : colorScheme.onSurface.withValues(alpha: 0.4),
            ),

            const SizedBox(width: 12),

            // Title and subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: isEnabled
                                    ? colorScheme.onSurface
                                    : colorScheme.onSurface.withValues(alpha: 0.5),
                              ),
                        ),
                      ),
                      if (relevance.isRecommended) ...[
                        const SizedBox(width: 8),
                        _buildSuggestedBadge(context, colorScheme),
                      ],
                    ],
                  ),
                  Text(
                    // The reason a pass is suggested, or can't apply, is more
                    // use than a generic settings summary — but only while the
                    // pass is off. Once the user has turned it on they have
                    // made the call, and the settings matter again.
                    (!isEnabled && relevance.reason != null)
                        ? relevance.reason!
                        : subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontStyle: (!isEnabled && relevance.reason != null)
                              ? FontStyle.italic
                              : FontStyle.normal,
                          color: isEnabled
                              ? colorScheme.onSurface.withValues(alpha: 0.7)
                              : colorScheme.onSurface.withValues(
                                  alpha: relevance.isNotApplicable ? 0.3 : 0.4,
                                ),
                        ),
                  ),
                ],
              ),
            ),

            // Expand/collapse affordance
            AnimatedRotation(
              turns: isExpanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(
                Icons.expand_more,
                size: 20,
                color: isExpanded
                    ? colorScheme.primary
                    : colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "Suggested" rather than "Recommended": it is a hint from metadata, and
  /// overstating it would be misleading on the sources where detection is
  /// wrong.
  Widget _buildSuggestedBadge(BuildContext context, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Suggested',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.w600,
              fontSize: 10,
            ),
      ),
    );
  }

  IconData _getIconForPass(PassType pass) {
    switch (pass) {
      case PassType.deinterlace:
        return Icons.view_stream;
      case PassType.descratch:
        return Icons.healing;
      case PassType.spotless:
        return Icons.auto_fix_high;
      case PassType.noiseReduction:
        return Icons.grain;
      case PassType.chromaDenoise:
        return Icons.palette;
      case PassType.dehalo:
        return Icons.flare;
      case PassType.deblock:
        return Icons.grid_off;
      case PassType.deband:
        return Icons.gradient;
      case PassType.sharpen:
        return Icons.center_focus_strong;
      case PassType.antiAlias:
        return Icons.gesture;
      case PassType.stabilize:
        return Icons.stay_current_landscape;
      case PassType.colorCorrection:
        return Icons.palette;
      case PassType.chromaFixes:
        return Icons.tune;
      case PassType.cropResize:
        return Icons.crop;
      case PassType.subtitles:
        return Icons.subtitles;
    }
  }
}
