import 'dart:io';

import 'package:path/path.dart' as path;

import 'worker_manager.dart';

/// Leaves a failed video's log on disk before an unattended shutdown
/// (issue #123).
///
/// Shutting down takes the in-app log with it, and the user who left a queue
/// running overnight finds only a missing output file in the morning. So each
/// failed video gets a `<output name>.error.log` where its output would have
/// been — the one place they will look.
class FailureLogWriter {
  /// Lines kept per video. Plenty for a worker's run; a runaway one cannot
  /// grow without bound across a long queue.
  static const maxLines = 5000;

  /// Where the log for a video whose output was meant to be [outputPath] goes.
  static String logPathFor(String outputPath) =>
      '${path.withoutExtension(outputPath)}.error.log';

  /// Write the log for one failed video. Tries next to the intended output,
  /// then next to the source (the output directory being unwritable may be
  /// exactly why it failed). Returns the path written, or null if neither
  /// could be.
  static Future<String?> write({
    required String inputPath,
    required String outputPath,
    required String? errorMessage,
    required List<LogMessage> messages,
    DateTime? now,
  }) async {
    final text = format(
      inputPath: inputPath,
      outputPath: outputPath,
      errorMessage: errorMessage,
      messages: messages,
      now: now ?? DateTime.now(),
    );
    final candidates = [
      logPathFor(outputPath),
      path.join(path.dirname(inputPath),
          path.basename(logPathFor(outputPath))),
    ];
    for (final candidate in candidates.toSet()) {
      try {
        await File(candidate).writeAsString(text, flush: true);
        return candidate;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  static String format({
    required String inputPath,
    required String outputPath,
    required String? errorMessage,
    required List<LogMessage> messages,
    required DateTime now,
  }) {
    final buffer = StringBuffer()
      ..writeln('VapourBox: processing failed')
      ..writeln('Time:   ${now.toIso8601String()}')
      ..writeln('Source: $inputPath')
      ..writeln('Output: $outputPath')
      ..writeln('Error:  ${errorMessage ?? 'unknown'}')
      ..writeln()
      ..writeln('Written because the computer was set to shut down when the '
          'queue finished.')
      ..writeln()
      ..writeln('--- Log ---');
    for (final m in messages) {
      buffer.writeln('${m.timestamp.toIso8601String()} '
          '[${m.level.name.toUpperCase()}] ${m.message}');
    }
    return buffer.toString();
  }
}
