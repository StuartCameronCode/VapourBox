import 'dart:async';

import 'package:flutter/material.dart';

import '../services/addon_manager.dart';
import '../services/whisper_addon_manager.dart';

/// Confirmation dialog shown when user first enables subtitles.
class WhisperConfirmDialog extends StatelessWidget {
  final String modelId;
  final int totalSize;

  const WhisperConfirmDialog({
    super.key,
    required this.modelId,
    required this.totalSize,
  });

  /// Show the confirmation dialog. Returns true if user wants to proceed.
  static Future<bool> show(BuildContext context, {String modelId = 'medium'}) async {
    final totalSize = await WhisperAddonManager.instance.getDownloadSize(modelId);
    if (!context.mounted) return false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => WhisperConfirmDialog(
        modelId: modelId,
        totalSize: totalSize,
      ),
    );
    return result ?? false;
  }

  String _formatSize(int bytes) {
    if (bytes >= 1000000000) {
      return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
    } else if (bytes >= 1000000) {
      return '${(bytes / 1000000).toStringAsFixed(0)} MB';
    }
    return '${(bytes / 1000).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Download Whisper AI'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Subtitle generation requires the Whisper AI add-on. '
            'This will download the whisper binary and language model.',
          ),
          const SizedBox(height: 16),
          Text(
            'Total download: ${_formatSize(totalSize)}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Download & Enable'),
        ),
      ],
    );
  }
}

/// Progress dialog for Whisper download.
class WhisperDownloadDialog extends StatefulWidget {
  final String modelId;

  const WhisperDownloadDialog({super.key, required this.modelId});

  /// Show the download dialog. Returns true if download completed successfully.
  static Future<bool> show(BuildContext context, {String modelId = 'medium'}) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => WhisperDownloadDialog(modelId: modelId),
    );
    return result ?? false;
  }

  @override
  State<WhisperDownloadDialog> createState() => _WhisperDownloadDialogState();
}

class _WhisperDownloadDialogState extends State<WhisperDownloadDialog> {
  final _manager = WhisperAddonManager.instance;
  StreamSubscription<AddonDownloadProgress>? _progressSub;

  String _status = 'Preparing...';
  double _progress = 0.0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _startDownload() async {
    setState(() {
      _error = null;
      _status = 'Downloading Whisper binary...';
    });

    _progressSub?.cancel();
    _progressSub = _manager.progressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _progress = progress.progress;
          _status = progress.status;
        });
      }
    });

    try {
      // Phase 1: Download binary
      final isInstalled = await _manager.isInstalled;
      if (!isInstalled) {
        await _manager.downloadBinary();
        if (_manager.isCancelled) {
          if (mounted) Navigator.of(context).pop(false);
          return;
        }
      }

      // Phase 2: Download model
      if (mounted) {
        setState(() {
          _status = 'Downloading language model...';
          _progress = 0.0;
        });
      }

      final modelInstalled = await _manager.isModelInstalled(widget.modelId);
      if (!modelInstalled) {
        await _manager.downloadModel(widget.modelId);
        if (_manager.isCancelled) {
          if (mounted) Navigator.of(context).pop(false);
          return;
        }
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Downloading Whisper AI'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null) ...[
              Icon(
                Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 8),
              Text(
                'Download failed',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ] else ...[
              Text(_status),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 8),
              if (_progress > 0)
                Text(
                  '${(_progress * 100).toStringAsFixed(1)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
      actions: [
        if (_error != null) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _startDownload,
            child: const Text('Retry'),
          ),
        ] else ...[
          TextButton(
            onPressed: () {
              _manager.cancelDownload();
              Navigator.of(context).pop(false);
            },
            child: const Text('Cancel'),
          ),
        ],
      ],
    );
  }
}
