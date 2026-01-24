import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Dialog shown when output files already exist and would be overwritten.
class OverwriteWarningDialog extends StatelessWidget {
  final List<String> existingFiles;

  const OverwriteWarningDialog({
    super.key,
    required this.existingFiles,
  });

  /// Show the dialog and return true if user confirms overwrite.
  static Future<bool> show({
    required BuildContext context,
    required List<String> existingFiles,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => OverwriteWarningDialog(
        existingFiles: existingFiles,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileCount = existingFiles.length;
    final isSingleFile = fileCount == 1;

    return AlertDialog(
      icon: Icon(
        Icons.warning_amber_rounded,
        color: theme.colorScheme.error,
        size: 48,
      ),
      title: Text(
        isSingleFile ? 'File Already Exists' : 'Files Already Exist',
      ),
      content: SizedBox(
        width: 450,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isSingleFile
                  ? 'The following output file already exists and will be overwritten:'
                  : 'The following $fileCount output files already exist and will be overwritten:',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),

            // File list
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: existingFiles.length,
                itemBuilder: (context, index) {
                  final filePath = existingFiles[index];
                  final fileName = p.basename(filePath);
                  final dirPath = p.dirname(filePath);

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.video_file,
                          size: 20,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                fileName,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                dirPath,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          child: Text(isSingleFile ? 'Overwrite' : 'Overwrite All'),
        ),
      ],
    );
  }
}
