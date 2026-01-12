import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/main_viewmodel.dart';

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
          final path = details.files.first.path;
          if (_isVideoFile(path)) {
            context.read<MainViewModel>().setInputFile(path);
          } else {
            _showError(context, 'Please drop a video file');
          }
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
                      ? 'Drop to load video'
                      : 'Drop video file here',
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
                FilledButton.icon(
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Browse Files'),
                  onPressed: () => _pickFile(context),
                ),
                const SizedBox(height: 32),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: Text(
                    'Supported formats: AVI, MOV, MP4, MKV, MXF, and other common video formats',
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
    );

    if (result != null && result.files.isNotEmpty) {
      final path = result.files.first.path;
      if (path != null && context.mounted) {
        context.read<MainViewModel>().setInputFile(path);
      }
    }
  }

  bool _isVideoFile(String path) {
    final extensions = [
      '.avi', '.mov', '.mp4', '.mkv', '.mxf', '.m2v', '.mpg', '.mpeg',
      '.ts', '.vob', '.dv', '.mts', '.m2ts', '.wmv', '.webm', '.flv'
    ];
    final lowerPath = path.toLowerCase();
    return extensions.any((ext) => lowerPath.endsWith(ext));
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}
