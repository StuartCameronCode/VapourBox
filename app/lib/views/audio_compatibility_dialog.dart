import 'package:flutter/material.dart';

import '../models/video_job.dart';
import '../services/audio_compatibility_service.dart';

/// User's choice when audio codec is incompatible with container.
enum AudioCompatibilityChoice {
  /// Re-encode audio to a compatible codec.
  reencode,
  /// Switch to a different container format.
  changeContainer,
  /// Cancel the export.
  cancel,
}

/// Result of the audio compatibility dialog.
class AudioCompatibilityDialogResult {
  final AudioCompatibilityChoice choice;
  final ContainerFormat? newContainer;

  const AudioCompatibilityDialogResult({
    required this.choice,
    this.newContainer,
  });

  static const cancelled = AudioCompatibilityDialogResult(
    choice: AudioCompatibilityChoice.cancel,
  );

  static const reencode = AudioCompatibilityDialogResult(
    choice: AudioCompatibilityChoice.reencode,
  );

  static AudioCompatibilityDialogResult switchContainer(ContainerFormat container) {
    return AudioCompatibilityDialogResult(
      choice: AudioCompatibilityChoice.changeContainer,
      newContainer: container,
    );
  }
}

/// Dialog shown when audio codec is incompatible with the selected container.
class AudioCompatibilityDialog extends StatefulWidget {
  final AudioCompatibilityResult compatibility;

  const AudioCompatibilityDialog({
    super.key,
    required this.compatibility,
  });

  /// Show the dialog and return the user's choice.
  static Future<AudioCompatibilityDialogResult?> show({
    required BuildContext context,
    required AudioCompatibilityResult compatibility,
  }) {
    return showDialog<AudioCompatibilityDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AudioCompatibilityDialog(
        compatibility: compatibility,
      ),
    );
  }

  @override
  State<AudioCompatibilityDialog> createState() => _AudioCompatibilityDialogState();
}

class _AudioCompatibilityDialogState extends State<AudioCompatibilityDialog> {
  ContainerFormat? _selectedContainer;

  @override
  void initState() {
    super.initState();
    // Pre-select first compatible container if available
    if (widget.compatibility.compatibleContainers.isNotEmpty) {
      _selectedContainer = widget.compatibility.compatibleContainers.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final audioInfo = widget.compatibility.audioInfo;
    final currentContainer = widget.compatibility.container;

    return AlertDialog(
      icon: Icon(
        Icons.warning_amber_rounded,
        color: theme.colorScheme.error,
        size: 48,
      ),
      title: const Text('Audio Codec Incompatible'),
      content: SizedBox(
        width: 450,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Explanation
            Text(
              widget.compatibility.incompatibilityReason ??
                  'The audio codec is not compatible with the selected container.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),

            // Audio info card
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.audiotrack,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Input Audio',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          audioInfo.description,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      currentContainer.displayName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Options header
            Text(
              'Choose how to proceed:',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 12),

            // Option 1: Re-encode
            _buildOption(
              context,
              icon: Icons.transform,
              title: 'Re-encode audio',
              subtitle: 'Convert to ${widget.compatibility.suggestedCodec.toUpperCase()} '
                  '(compatible with ${currentContainer.displayName})',
              onTap: () => Navigator.of(context).pop(
                AudioCompatibilityDialogResult.reencode,
              ),
            ),
            const SizedBox(height: 8),

            // Option 2: Change container (if compatible containers exist)
            if (widget.compatibility.compatibleContainers.isNotEmpty) ...[
              _buildContainerOption(context),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            AudioCompatibilityDialogResult.cancelled,
          ),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.3),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContainerOption(BuildContext context) {
    final theme = Theme.of(context);
    final containers = widget.compatibility.compatibleContainers;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.folder_open,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Change container format',
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      'Keep original audio, use a compatible container',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: containers.map((container) {
              final isSelected = container == _selectedContainer;
              return ChoiceChip(
                label: Text(container.displayName),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected) {
                    setState(() => _selectedContainer = container);
                    Navigator.of(context).pop(
                      AudioCompatibilityDialogResult.switchContainer(container),
                    );
                  }
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
