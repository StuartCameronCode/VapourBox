import 'package:flutter/material.dart';

import '../../models/restoration_pipeline.dart';

/// A single item in the pass list showing a restoration pass.
class PassListItem extends StatelessWidget {
  final PassType passType;
  final String title;
  final String subtitle;
  final bool isEnabled;
  final bool isSelected;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  const PassListItem({
    super.key,
    required this.passType,
    required this.title,
    required this.subtitle,
    required this.isEnabled,
    required this.isSelected,
    required this.onToggle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: isSelected
            ? colorScheme.primaryContainer.withValues(alpha: 0.5)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
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
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: isEnabled
                                  ? colorScheme.onSurface
                                  : colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                      ),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isEnabled
                                  ? colorScheme.onSurface.withValues(alpha: 0.7)
                                  : colorScheme.onSurface.withValues(alpha: 0.4),
                            ),
                      ),
                    ],
                  ),
                ),

                // Arrow indicator if selected
                if (isSelected)
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: colorScheme.primary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _getIconForPass(PassType pass) {
    switch (pass) {
      case PassType.deinterlace:
        return Icons.view_stream;
      case PassType.noiseReduction:
        return Icons.grain;
      case PassType.colorCorrection:
        return Icons.palette;
      case PassType.chromaFixes:
        return Icons.tune;
      case PassType.cropResize:
        return Icons.crop;
    }
  }
}
