import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:rhttp/rhttp.dart';

/// Progress information for add-on downloads.
class AddonDownloadProgress {
  final int bytesReceived;
  final int totalBytes;
  final String status;
  final String? currentFile;

  AddonDownloadProgress({
    required this.bytesReceived,
    required this.totalBytes,
    required this.status,
    this.currentFile,
  });

  double get progress => totalBytes > 0 ? bytesReceived / totalBytes : 0.0;
  String get progressPercent => '${(progress * 100).toStringAsFixed(1)}%';
}

/// General-purpose add-on download manager with HTTP resume support.
class AddonManager {
  final _progressController = StreamController<AddonDownloadProgress>.broadcast();
  bool _isCancelled = false;

  /// Stream of download progress updates.
  Stream<AddonDownloadProgress> get progressStream => _progressController.stream;

  /// Download a file with resume support using HTTP Range headers.
  ///
  /// If a .partial file exists from a previous attempt, resumes from that point.
  /// On cancel/error, the .partial file is preserved for the next attempt.
  Future<void> downloadFile(
    String url,
    File destination, {
    int? expectedSize,
    String? expectedSha256,
    Map<String, String>? extraHeaders,
  }) async {
    _isCancelled = false;
    final partialFile = File('${destination.path}.partial');
    int startByte = 0;

    // Check for existing partial download
    if (await partialFile.exists()) {
      startByte = await partialFile.length();
      _progressController.add(AddonDownloadProgress(
        bytesReceived: startByte,
        totalBytes: expectedSize ?? 0,
        status: 'Resuming download...',
        currentFile: destination.path,
      ));
    } else {
      _progressController.add(AddonDownloadProgress(
        bytesReceived: 0,
        totalBytes: expectedSize ?? 0,
        status: 'Connecting...',
        currentFile: destination.path,
      ));
    }

    try {
      // Build request headers (Range for resume + any extra headers)
      final headerMap = <String, String>{};
      if (extraHeaders != null) {
        headerMap.addAll(extraHeaders);
      }
      if (startByte > 0) {
        headerMap['Range'] = 'bytes=$startByte-';
      }
      final HttpHeaders? headers = headerMap.isNotEmpty
          ? HttpHeaders.rawMap(headerMap)
          : null;

      final response = await Rhttp.getStream(
        url,
        headers: headers,
        onReceiveProgress: (bytesReceived, contentLength) {
          if (_isCancelled) return;
          _progressController.add(AddonDownloadProgress(
            bytesReceived: startByte + bytesReceived,
            totalBytes: expectedSize ?? (startByte + contentLength),
            status: 'Downloading...',
            currentFile: destination.path,
          ));
        },
      );

      // Check status code
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException(
          'Download failed: HTTP ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }

      // Append to partial file
      final sink = partialFile.openWrite(mode: startByte > 0 ? FileMode.append : FileMode.write);

      await for (final chunk in response.body) {
        if (_isCancelled) {
          await sink.close();
          return;
        }
        sink.add(chunk);
      }

      await sink.close();

      if (_isCancelled) return;

      // Verify SHA256 if provided
      if (expectedSha256 != null) {
        final bytes = await partialFile.readAsBytes();
        final digest = sha256.convert(bytes);
        if (digest.toString() != expectedSha256) {
          await partialFile.delete();
          throw StateError(
            'SHA256 mismatch: expected $expectedSha256, got $digest',
          );
        }
      }

      // Rename .partial to final name
      if (await destination.exists()) {
        await destination.delete();
      }
      await partialFile.rename(destination.path);

      _progressController.add(AddonDownloadProgress(
        bytesReceived: expectedSize ?? await destination.length(),
        totalBytes: expectedSize ?? await destination.length(),
        status: 'Complete',
        currentFile: destination.path,
      ));
    } on RhttpException catch (e) {
      if (!_isCancelled) {
        throw HttpException('Download failed: $e', uri: Uri.parse(url));
      }
    }
  }

  /// Cancel the current download (preserves .partial file for resume).
  void cancelDownload() {
    _isCancelled = true;
  }

  /// Whether the download was cancelled.
  bool get isCancelled => _isCancelled;

  void dispose() {
    _progressController.close();
  }
}
