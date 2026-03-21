import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/dvd_info.dart';
import '../models/progress_info.dart';
import 'tool_locator.dart';

/// Service for DVD operations (title enumeration and extraction).
/// Calls the worker binary with --dvd-info and --dvd-extract flags.
class DvdService {
  /// Enumerate titles on a DVD.
  ///
  /// [mountPoint] is the path to the DVD mount point or VIDEO_TS folder.
  /// Returns a [DvdInfo] with all titles found.
  Future<DvdInfo> getTitleInfo(String mountPoint) async {
    final toolLocator = ToolLocator.instance;
    final workerPath = toolLocator.workerPath;
    if (workerPath == null) {
      throw Exception('Worker executable not found');
    }

    final result = await Process.run(
      workerPath,
      ['--dvd-info', mountPoint],
      environment: toolLocator.workerEnvironment,
      workingDirectory: File(workerPath).parent.path,
    );

    if (result.exitCode != 0) {
      // Try to extract error message from JSON output
      final stdout = result.stdout as String;
      if (stdout.isNotEmpty) {
        try {
          final json = jsonDecode(stdout) as Map<String, dynamic>;
          if (json['type'] == 'error') {
            throw Exception(json['message'] as String? ?? 'Unknown error');
          }
        } catch (e) {
          if (e is Exception && e.toString().contains('type')) rethrow;
        }
      }

      final stderr = result.stderr as String;
      throw Exception(
        stderr.isNotEmpty ? stderr.trim() : 'DVD enumeration failed (exit code ${result.exitCode})',
      );
    }

    final stdout = result.stdout as String;
    if (stdout.isEmpty) {
      throw Exception('No output from DVD enumeration');
    }

    final json = jsonDecode(stdout) as Map<String, dynamic>;
    return DvdInfo.fromJson(json);
  }

  /// Extract a DVD title to a temporary MPEG-PS file.
  ///
  /// Returns a stream of [ExtractionProgress] updates including progress,
  /// log messages, and errors. The final update indicates completion.
  Stream<ExtractionProgress> extractTitle({
    required String mountPoint,
    required int titleIndex,
    int? startChapter,
    int? endChapter,
    required String outputPath,
  }) async* {
    final toolLocator = ToolLocator.instance;
    final workerPath = toolLocator.workerPath;
    if (workerPath == null) {
      throw Exception('Worker executable not found');
    }

    final args = [
      '--dvd-extract', mountPoint,
      '--title', titleIndex.toString(),
      '--output', outputPath,
    ];

    if (startChapter != null && endChapter != null) {
      args.addAll(['--chapters', '$startChapter-$endChapter']);
    }

    final process = await Process.start(
      workerPath,
      args,
      environment: toolLocator.workerEnvironment,
      workingDirectory: File(workerPath).parent.path,
    );

    String? lastError;

    // Capture stderr in the background and forward as log messages
    final stderrLines = <String>[];
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isNotEmpty) {
        stderrLines.add(line);
      }
    });

    // Process stdout JSON messages
    await for (final line in process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;

      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final type = json['type'] as String?;

        if (type == 'progress') {
          final progress = ProgressInfo.fromJson(json);
          yield ExtractionProgress(
            progress: progress.progress,
            phase: progress.phase ?? 'extracting',
          );
        } else if (type == 'log') {
          // Forward worker log messages so the UI can display them
          yield ExtractionProgress.log(
            level: json['level'] as String? ?? 'info',
            message: json['message'] as String? ?? '',
          );
        } else if (type == 'error') {
          lastError = json['message'] as String?;
          // Also forward the error as a log so it appears in the log trail
          yield ExtractionProgress.log(
            level: 'error',
            message: lastError ?? 'Unknown error',
          );
        } else if (type == 'complete') {
          final success = json['success'] as bool? ?? false;
          if (success) {
            yield ExtractionProgress(progress: 1.0, phase: 'complete');
          } else {
            yield ExtractionProgress(
              progress: 0.0,
              phase: 'error',
              error: lastError ?? 'Extraction failed',
            );
          }
        }
      } catch (_) {
        // Not JSON — forward as a debug log line
        yield ExtractionProgress.log(level: 'debug', message: line);
      }
    }

    // Wait for stderr to finish and process to exit
    await stderrDone.cancel();
    final exitCode = await process.exitCode;

    // Forward any stderr lines as warning logs
    for (final line in stderrLines) {
      yield ExtractionProgress.log(level: 'warning', message: line);
    }

    if (exitCode != 0 && lastError == null) {
      final stderrSummary = stderrLines.isNotEmpty
          ? stderrLines.join('\n')
          : 'exit code $exitCode';
      yield ExtractionProgress(
        progress: 0.0,
        phase: 'error',
        error: 'Extraction failed ($stderrSummary)',
      );
    }
  }
}

/// Progress update during DVD extraction.
class ExtractionProgress {
  /// Progress fraction (0.0 to 1.0).
  final double progress;

  /// Current phase: "extracting", "complete", "error", or "log".
  final String phase;

  /// Error message (only when phase == "error").
  final String? error;

  /// Log message (only when phase == "log").
  final String? logMessage;

  /// Log level (only when phase == "log"): "debug", "info", "warning", "error".
  final String? logLevel;

  const ExtractionProgress({
    required this.progress,
    required this.phase,
    this.error,
    this.logMessage,
    this.logLevel,
  });

  /// Create a log-only progress event.
  const ExtractionProgress.log({
    required String level,
    required String message,
  })  : progress = -1,
        phase = 'log',
        error = null,
        logMessage = message,
        logLevel = level;

  bool get isComplete => phase == 'complete';
  bool get isError => phase == 'error';
  bool get isLog => phase == 'log';
  int get percentComplete => (progress * 100).round();
}
