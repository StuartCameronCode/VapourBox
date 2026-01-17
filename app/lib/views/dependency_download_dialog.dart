import 'dart:async';

import 'package:flutter/material.dart';

import '../services/dependency_manager.dart';

/// Dialog that shows dependency download progress.
///
/// This dialog is modal and prevents the user from interacting
/// with the app until dependencies are installed.
class DependencyDownloadDialog extends StatefulWidget {
  final DependencyStatus status;

  const DependencyDownloadDialog({
    super.key,
    required this.status,
  });

  /// Show the dialog and wait for dependencies to be installed.
  ///
  /// Returns true if installation was successful, false if user cancelled.
  static Future<bool> show(BuildContext context, DependencyStatus status) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => DependencyDownloadDialog(status: status),
    );
    return result ?? false;
  }

  @override
  State<DependencyDownloadDialog> createState() => _DependencyDownloadDialogState();
}

class _DependencyDownloadDialogState extends State<DependencyDownloadDialog> {
  final _manager = DependencyManager.instance;
  StreamSubscription<DownloadProgress>? _progressSubscription;

  bool _isDownloading = false;
  bool _hasError = false;
  String _errorMessage = '';
  DownloadProgress? _progress;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    super.dispose();
  }

  void _startDownload() {
    setState(() {
      _isDownloading = true;
      _hasError = false;
      _errorMessage = '';
    });

    _progressSubscription = _manager.progressStream.listen(
      (progress) {
        setState(() {
          _progress = progress;
        });
      },
    );

    _manager.downloadAndInstall().then((_) {
      _progressSubscription?.cancel();
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    }).catchError((error) {
      _progressSubscription?.cancel();
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _hasError = true;
          _errorMessage = error.toString();
        });
      }
    });
  }

  String _getStatusMessage() {
    switch (widget.status) {
      case DependencyStatus.missing:
        return 'VapourBox requires additional components to process videos.\n\n'
            'These will be downloaded automatically.';
      case DependencyStatus.outdated:
        return 'A new version of the processing components is available.\n\n'
            'Updating to ensure compatibility.';
      case DependencyStatus.corrupted:
        return 'Some processing components are damaged or incomplete.\n\n'
            'Re-downloading to fix the issue.';
      default:
        return 'Preparing dependencies...';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            _hasError ? Icons.error_outline : Icons.download,
            color: _hasError ? Colors.red : Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Text(_hasError ? 'Download Failed' : 'Installing Components'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_hasError) ...[
              Text(
                'Failed to download dependencies:',
                style: TextStyle(color: Colors.red[700]),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _errorMessage,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Please check your internet connection and try again.',
              ),
            ] else if (_isDownloading) ...[
              Text(_getStatusMessage()),
              const SizedBox(height: 24),
              if (_progress != null) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_progress!.status),
                    Text(_progress!.progressPercent),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _progress!.progress,
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_formatBytes(_progress!.bytesReceived)} / ${_formatBytes(_progress!.totalBytes)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ] else ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  'Connecting...',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        if (_hasError) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: _startDownload,
            child: const Text('Retry'),
          ),
        ] else ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
        ],
      ],
    );
  }
}

/// A simple splash screen shown while checking dependencies.
class DependencyCheckScreen extends StatelessWidget {
  const DependencyCheckScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/icon.png',
                width: 128,
                height: 128,
                errorBuilder: (context, error, stackTrace) {
                  return Icon(
                    Icons.video_settings,
                    size: 64,
                    color: Theme.of(context).colorScheme.primary,
                  );
                },
              ),
              const SizedBox(height: 24),
              Text(
                'VapourBox',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 48),
              const SizedBox(
                width: 200,
                child: LinearProgressIndicator(),
              ),
              const SizedBox(height: 16),
              Text(
                'Checking dependencies...',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
