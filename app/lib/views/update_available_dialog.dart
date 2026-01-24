import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/update_checker.dart';

/// Dialog shown when a new version is available.
class UpdateAvailableDialog extends StatelessWidget {
  final UpdateInfo updateInfo;

  const UpdateAvailableDialog({
    super.key,
    required this.updateInfo,
  });

  /// Show the dialog if an update is available.
  static Future<void> show(BuildContext context, UpdateInfo updateInfo) {
    return showDialog<void>(
      context: context,
      builder: (context) => UpdateAvailableDialog(updateInfo: updateInfo),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      icon: Icon(
        Icons.system_update,
        color: theme.colorScheme.primary,
        size: 48,
      ),
      title: const Text('Update Available'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A new version of VapourBox is available.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),

            // Version info
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Column(
                    children: [
                      Text(
                        'Current',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        'v${updateInfo.currentVersion}',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Icon(
                      Icons.arrow_forward,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Column(
                    children: [
                      Text(
                        'Latest',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        'v${updateInfo.latestVersion}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        FilledButton.icon(
          onPressed: () {
            _openDownloadPage();
            Navigator.of(context).pop();
          },
          icon: const Icon(Icons.open_in_new),
          label: const Text('Download'),
        ),
      ],
    );
  }

  Future<void> _openDownloadPage() async {
    final uri = Uri.parse(updateInfo.releaseUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
