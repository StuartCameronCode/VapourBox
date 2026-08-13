import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/disc_detector.dart';
import '../viewmodels/main_viewmodel.dart';
import 'dropped_paths.dart';

class DropZone extends StatefulWidget {
  const DropZone({super.key});

  @override
  State<DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<DropZone> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DropTarget(
      onDragEntered: (details) {
        setState(() => _isDragging = true);
      },
      onDragExited: (details) {
        setState(() => _isDragging = false);
      },
      onDragDone: (details) {
        setState(() => _isDragging = false);
        if (details.files.isNotEmpty) {
          handleDroppedPaths(
            context,
            details.files.map((f) => f.path).toList(),
          );
        }
      },
      child: GestureDetector(
        onTap: () => _pickFile(context),
        child: Container(
          margin: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: _isDragging
                ? colorScheme.primary.withValues(alpha: 0.1)
                : colorScheme.surface,
            border: Border.all(
              color: _isDragging
                  ? colorScheme.primary
                  : colorScheme.outline.withValues(alpha: 0.3),
              width: _isDragging ? 3 : 2,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isDragging ? Icons.file_download : Icons.video_file,
                  size: 64,
                  color: _isDragging
                      ? colorScheme.primary
                      : colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  _isDragging
                      ? 'Drop to add videos'
                      : 'Drop video files or folders here',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: _isDragging
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'or click to browse',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Browse Files'),
                      onPressed: () => _pickFile(context),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.folder),
                      label: const Text('Open Folder'),
                      onPressed: () => _pickFolder(context),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.album),
                      label: const Text('Open DVD'),
                      onPressed: () => _openDvd(context),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: Text(
                    'Supported: Video files, folders of videos, DVD discs, and ripped DVD folders',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickFile(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'avi', 'mov', 'mp4', 'mkv', 'mxf', 'm2v', 'mpg', 'mpeg',
        'ts', 'vob', 'dv', 'mts', 'm2ts', 'wmv', 'webm', 'flv'
      ],
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      final paths = result.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();
      if (paths.isNotEmpty && context.mounted) {
        context.read<MainViewModel>().addMultipleToQueue(paths);
      }
    }
  }

  Future<void> _pickFolder(BuildContext context) async {
    final folderPath = await FilePicker.platform.getDirectoryPath();
    if (folderPath == null || !context.mounted) return;

    final viewModel = context.read<MainViewModel>();
    try {
      await viewModel.addFolder(folderPath);
    } on DvdFolderDetected catch (e) {
      if (context.mounted) {
        await showDvdPicker(context, e.mountPoint);
      }
    } catch (e) {
      if (context.mounted) {
        showDropError(context, 'Failed to open folder: $e');
      }
    }
  }

  Future<void> _openDvd(BuildContext context) async {
    final viewModel = context.read<MainViewModel>();

    // Detect available discs
    final discs = await viewModel.detectDiscs();

    if (!context.mounted) return;

    if (discs.isEmpty) {
      showDropError(context, 'No DVD discs detected');
      return;
    }

    if (discs.length == 1) {
      // Single disc — go directly to title picker
      await showDvdPicker(context, discs.first.mountPoint);
    } else {
      // Multiple discs — let user choose
      final disc = await showDialog<DvdDisc>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select DVD'),
          content: SizedBox(
            width: 300,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: discs.length,
              itemBuilder: (context, index) {
                final disc = discs[index];
                return ListTile(
                  leading: const Icon(Icons.album),
                  title: Text(disc.volumeLabel),
                  subtitle: Text(disc.mountPoint),
                  onTap: () => Navigator.pop(context, disc),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

      if (disc != null && context.mounted) {
        await showDvdPicker(context, disc.mountPoint);
      }
    }
  }
}
