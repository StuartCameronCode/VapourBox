import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'temp_directory_service.dart';
import 'tool_locator.dart';

/// One timestamp reset, as the worker's `--scan-timestamps` reports it.
class TimestampReset {
  final int stream;
  final String codecType;
  final int packet;
  final double from;
  final double to;

  const TimestampReset({
    required this.stream,
    required this.codecType,
    required this.packet,
    required this.from,
    required this.to,
  });

  factory TimestampReset.fromJson(Map<String, dynamic> j) => TimestampReset(
        stream: (j['stream'] as num?)?.toInt() ?? 0,
        codecType: j['codecType'] as String? ?? '',
        packet: (j['packet'] as num?)?.toInt() ?? 0,
        from: (j['from'] as num?)?.toDouble() ?? 0,
        to: (j['to'] as num?)?.toDouble() ?? 0,
      );
}

/// What `--scan-timestamps` found in a source (task #21). The worker's
/// `source_continuity` decides what a reset is; the app only reads it.
class ContinuityScan {
  final String format;
  final bool applies;
  final List<TimestampReset> resets;

  const ContinuityScan({
    required this.format,
    required this.applies,
    this.resets = const [],
  });

  factory ContinuityScan.fromJson(Map<String, dynamic> j) => ContinuityScan(
        format: j['format'] as String? ?? '',
        applies: j['applies'] as bool? ?? false,
        resets: [
          for (final r in (j['resets'] as List? ?? const []))
            TimestampReset.fromJson(r as Map<String, dynamic>),
        ],
      );

  /// Whether the source must be decoded from a continuous copy.
  bool get needsCopy => applies && resets.isNotEmpty;

  /// The pictures (decode order) the video's clock resets at.
  List<int> get videoResetPictures => [
        for (final r in resets)
          if (r.codecType == 'video') r.packet,
      ];

  /// How many times the clock resets (the video's count, else the sound's).
  int get resetCount {
    final v = videoResetPictures.length;
    return v > 0 ? v : resets.length;
  }
}

/// A source decoded from a joined copy because its timestamps reset.
class ContinuityProxy {
  /// The continuous copy, in the temp directory: what every probe and decode
  /// reads.
  final String path;

  /// How many times the source's clock reset.
  final int resetCount;

  /// The copy's size in bytes, for the note in Video Info.
  final int sizeBytes;

  const ContinuityProxy({
    required this.path,
    required this.resetCount,
    required this.sizeBytes,
  });

  /// One line for Video Info and the log.
  String get note {
    final gb = sizeBytes / (1024 * 1024 * 1024);
    final size = gb >= 1
        ? '${gb.toStringAsFixed(1)} GB'
        : '${(sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    final times = resetCount == 1 ? 'once' : '$resetCount times';
    return 'Timestamps reset $times; decoded from a joined copy '
        '($size in the temp folder)';
  }

  /// Deletes the copy. Errors are ignored: it is a temp file.
  void delete() {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

/// Runs the worker's `--scan-timestamps` and `--make-continuous` (see
/// `worker/src/source_continuity.rs`). A TS/PS whose clock resets mid-file is
/// decoded from a same-container copy with continuous timestamps, so frame N
/// counts straight through every segment; nothing else changes.
class TimestampContinuityService {
  /// The worker and its environment; from [ToolLocator] unless given (the
  /// tests pass the harness's).
  final String? workerPath;
  final Map<String, String>? environment;

  const TimestampContinuityService({this.workerPath, this.environment});

  String? get _worker => workerPath ?? ToolLocator.instance.workerPath;
  Map<String, String>? get _env =>
      environment ?? ToolLocator.instance.workerEnvironment;

  /// Scans [path]. Null when the worker could not answer (the source is then
  /// used as it is, exactly as before this existed).
  Future<ContinuityScan?> scan(String path) async {
    final worker = _worker;
    if (worker == null) return null;
    try {
      final r = await Process.run(worker, ['--scan-timestamps', path],
          environment: _env, workingDirectory: File(worker).parent.path);
      if (r.exitCode != 0) return null;
      for (final line in const LineSplitter().convert(r.stdout.toString())) {
        final t = line.trim();
        if (!t.startsWith('{')) continue;
        return ContinuityScan.fromJson(jsonDecode(t) as Map<String, dynamic>);
      }
    } catch (_) {}
    return null;
  }

  /// Where a source's joined copy goes: the temp directory, named after the
  /// source with its own extension (the container is kept).
  static Future<String> proxyPathFor(String source, String id) async {
    final ext = p.extension(source).isEmpty ? '.mpg' : p.extension(source);
    final stem = p.basenameWithoutExtension(source);
    return TempDirectoryService.instance
        .filePath('continuous_${id.substring(0, 8)}_$stem$ext');
  }

  /// Writes the continuous copy of [source] to [output]. Returns the error
  /// when the worker refused or the copy failed its check (it then leaves no
  /// file), else null. [onProgress] gets 0..1.
  Future<String?> join(String source, String output,
      {void Function(double)? onProgress}) async {
    final worker = _worker;
    if (worker == null) return 'The VapourBox worker could not be found';
    final process = await Process.start(
        worker, ['--make-continuous', source, '--output', output],
        environment: _env, workingDirectory: File(worker).parent.path);
    final stderr = StringBuffer();
    final err = process.stderr.transform(utf8.decoder).listen(stderr.write);
    String? error;
    var success = false;
    await for (final line in process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final t = line.trim();
      if (!t.startsWith('{')) continue;
      try {
        final j = jsonDecode(t) as Map<String, dynamic>;
        switch (j['type']) {
          case 'progress':
            final total = (j['totalFrames'] as num?)?.toDouble() ?? 0;
            final frame = (j['frame'] as num?)?.toDouble() ?? 0;
            if (total > 0) onProgress?.call((frame / total).clamp(0.0, 1.0));
          case 'error':
            error = j['message'] as String?;
          case 'complete':
            success = j['success'] as bool? ?? false;
        }
      } catch (_) {}
    }
    final code = await process.exitCode;
    await err.cancel();
    if (success && code == 0 && await File(output).exists()) return null;
    return error ?? (stderr.isEmpty ? 'exit code $code' : stderr.toString().trim());
  }

  /// Scans [source] and, when its timestamps reset, makes the joined copy.
  /// `checked` says whether the scan answered at all; `proxy` is the copy
  /// (null when none was needed or it failed, `error` saying why).
  Future<({bool checked, ContinuityProxy? proxy, ContinuityScan? scan, String? error})>
      prepare(String source, String id,
          {void Function(ContinuityScan)? onJoining,
          void Function(double)? onProgress}) async {
    final s = await scan(source);
    if (s == null) return (checked: false, proxy: null, scan: null, error: null);
    if (!s.needsCopy) return (checked: true, proxy: null, scan: s, error: null);
    onJoining?.call(s);
    final out = await proxyPathFor(source, id);
    final error = await join(source, out, onProgress: onProgress);
    if (error != null) {
      return (checked: false, proxy: null, scan: s, error: error);
    }
    final size = await File(out).length();
    return (
      checked: true,
      proxy: ContinuityProxy(path: out, resetCount: s.resetCount, sizeBytes: size),
      scan: s,
      error: null,
    );
  }
}
