import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../models/source_model.dart';

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

/// What the worker's `--probe-source` answered (task #85): the [model], or
/// the [error] it gave instead, with the lines it logged on stderr (the
/// probes it retried, and why). The reason is shown on the item and written
/// to its log, never dropped.
class SourceProbe {
  /// The source's model; null when the probe failed.
  final SourceModel? model;

  /// Why there is no model: the worker's `{"error": …}`, or why the worker
  /// could not be run. Null with a model, and for [none].
  final String? error;

  /// The worker's stderr lines, trimmed, the last [maxLogLines] of them.
  final List<String> log;

  const SourceProbe({this.model, this.error, this.log = const []});

  /// No model and no reason: what a test's stand-in answers when the probe
  /// isn't what it is about.
  static const none = SourceProbe();

  bool get ok => model != null;

  /// How many stderr lines are kept.
  static const maxLogLines = 20;

  /// Reads the worker's answer. A model is accepted only on exit 0; else the
  /// last `{"error": …}` line on stdout is the reason, and with none a
  /// fallback says the worker gave no reason. Accepts CRLF and LF.
  factory SourceProbe.fromWorkerOutput(
      int exitCode, String stdout, String stderr) {
    SourceModel? model;
    String? error;
    for (final line in const LineSplitter().convert(stdout)) {
      final t = line.trim();
      if (!t.startsWith('{')) continue;
      try {
        final j = jsonDecode(t);
        if (j is! Map<String, dynamic>) continue;
        final m = SourceModel.fromJson(j);
        if (m != null) {
          model = m;
        } else if (j['error'] is String) {
          error = j['error'] as String;
        }
      } catch (_) {}
    }
    final log = logLines(stderr);
    if (exitCode == 0 && model != null) {
      return SourceProbe(model: model, log: log);
    }
    return SourceProbe(
        error: (error != null && error.trim().isNotEmpty)
            ? error.trim()
            : 'the worker exited with $exitCode and gave no reason',
        log: log);
  }

  /// The non-empty lines of a worker's stderr, trimmed, the last
  /// [maxLogLines].
  static List<String> logLines(String stderr) {
    final lines = [
      for (final l in const LineSplitter().convert(stderr))
        if (l.trim().isNotEmpty) l.trim(),
    ];
    return lines.length > maxLogLines
        ? lines.sublist(lines.length - maxLogLines)
        : lines;
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

  /// The worker's [SourceModel] of [path] (`--probe-source`, task #50):
  /// every fact about the source, the reset scan included, or the reason
  /// there is none ([SourceProbe.error]) with the worker's stderr.
  ///
  /// With [deferScan], an MPEG-PS/TS's reset scan (a read of every byte,
  /// minutes on a network share) is left out and the model says so
  /// ([SourceModel.continuityDeferred]); [completeSource] runs it (task #55).
  Future<SourceProbe> probeSource(String path, {bool deferScan = false}) async {
    final worker = _worker;
    if (worker == null) {
      return const SourceProbe(error: 'The VapourBox worker could not be found');
    }
    try {
      final r = await Process.run(
          worker, ['--probe-source', path, if (deferScan) '--defer-scan'],
          environment: _env, workingDirectory: File(worker).parent.path);
      return SourceProbe.fromWorkerOutput(
          r.exitCode, r.stdout.toString(), r.stderr.toString());
    } catch (e) {
      return SourceProbe(error: 'the worker could not be run: $e');
    }
  }

  /// Runs a deferred [model]'s reset scan (`--complete-source`, task #55):
  /// [onProgress] gets the fraction of the file read, and the result is the
  /// completed model (null when the worker could not answer, with
  /// [ContinuityScanTask.error] and [ContinuityScanTask.log] saying why).
  /// The scan can be stopped with [ContinuityScanTask.cancel], which
  /// completes it with null.
  ContinuityScanTask completeSource(SourceModel model,
      {void Function(double)? onProgress}) {
    final task = ContinuityScanTask._();
    task._run(() async {
      final worker = _worker;
      if (worker == null) {
        task.error = 'The VapourBox worker could not be found';
        return null;
      }
      final file = File(await TempDirectoryService.instance.filePath(
          'source_model_${DateTime.now().microsecondsSinceEpoch}.json'));
      try {
        await model.writeTo(file);
        if (task.isCancelled) return null;
        final process = await Process.start(
            worker, ['--complete-source', file.path],
            environment: _env, workingDirectory: File(worker).parent.path);
        task._process = process;
        if (task.isCancelled) process.kill();
        final stderr = StringBuffer();
        final err = process.stderr
            .transform(utf8.decoder)
            .listen(stderr.write)
            .asFuture<void>();
        SourceModel? result;
        String? error;
        await for (final line in process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          final t = line.trim();
          if (!t.startsWith('{')) continue;
          try {
            final j = jsonDecode(t) as Map<String, dynamic>;
            if (j['type'] == 'progress') {
              final total = (j['totalFrames'] as num?)?.toDouble() ?? 0;
              final frame = (j['frame'] as num?)?.toDouble() ?? 0;
              if (total > 0) onProgress?.call((frame / total).clamp(0.0, 1.0));
            } else {
              final m = SourceModel.fromJson(j);
              if (m != null) {
                result = m;
              } else if (j['error'] is String) {
                error = j['error'] as String;
              }
            }
          } catch (_) {}
        }
        final code = await process.exitCode;
        await err;
        if (task.isCancelled) return null;
        if (code != 0 || result == null) {
          task.error = (error != null && error.trim().isNotEmpty)
              ? error.trim()
              : 'the worker exited with $code and gave no reason';
          task.log = SourceProbe.logLines(stderr.toString());
          return null;
        }
        return result;
      } catch (e) {
        task.error ??= 'the worker could not be run: $e';
        return null;
      } finally {
        try {
          if (file.existsSync()) file.deleteSync();
        } catch (_) {}
      }
    });
    return task;
  }

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
  ///
  /// Given the source's [model] (with its scan), the worker uses that scan
  /// rather than reading the whole source a second time (task #55).
  Future<String?> join(String source, String output,
      {void Function(double)? onProgress, SourceModel? model}) async {
    final worker = _worker;
    if (worker == null) return 'The VapourBox worker could not be found';
    File? modelFile;
    if (model != null) {
      modelFile = File('$output.source.json');
      try {
        await model.writeTo(modelFile);
      } catch (_) {
        modelFile = null;
      }
    }
    try {
      return await _join(worker, source, output, onProgress, modelFile);
    } finally {
      try {
        if (modelFile != null && modelFile.existsSync()) modelFile.deleteSync();
      } catch (_) {}
    }
  }

  Future<String?> _join(String worker, String source, String output,
      void Function(double)? onProgress, File? modelFile) async {
    final process = await Process.start(
        worker,
        [
          '--make-continuous', source, '--output', output,
          if (modelFile != null) ...['--source', modelFile.path],
        ],
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

  /// Scans [source] (unless [scanned], or the scan in its [model], is
  /// given) and, when its timestamps reset, makes the joined copy (from the
  /// [model]'s scan when there is one, so the worker doesn't read the source
  /// again to find it).
  /// `checked` says whether the scan answered at all; `proxy` is the copy
  /// (null when none was needed or it failed, `error` saying why).
  Future<({bool checked, ContinuityProxy? proxy, ContinuityScan? scan, String? error})>
      prepare(String source, String id,
          {ContinuityScan? scanned,
          SourceModel? model,
          void Function(ContinuityScan)? onJoining,
          void Function(double)? onProgress}) async {
    final s = scanned ?? model?.continuity ?? await scan(source);
    if (s == null) return (checked: false, proxy: null, scan: null, error: null);
    if (!s.needsCopy) return (checked: true, proxy: null, scan: s, error: null);
    onJoining?.call(s);
    final out = await proxyPathFor(source, id);
    final error = await join(source, out, onProgress: onProgress, model: model);
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

/// A running `--complete-source` ([TimestampContinuityService.completeSource]).
class ContinuityScanTask {
  ContinuityScanTask._();

  /// Lets a test stand in for the worker: [result] is what the scan answers.
  @visibleForTesting
  ContinuityScanTask.of(Future<SourceModel?> result,
      {this.error, this.log = const []}) {
    _run(() => result);
  }

  /// Why the scan gave no model (the worker's `{"error": …}`); null on
  /// success and on cancel.
  String? error;

  /// The worker's stderr lines when it failed.
  List<String> log = const [];

  final _done = Completer<SourceModel?>();
  Process? _process;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  /// The completed model, or null when the scan failed or was cancelled.
  Future<SourceModel?> get result => _done.future;

  void _run(Future<SourceModel?> Function() body) {
    body().then((m) {
      if (!_done.isCompleted) _done.complete(_cancelled ? null : m);
    }, onError: (Object _) {
      if (!_done.isCompleted) _done.complete(null);
    });
  }

  /// Stops the scan (the worker is killed, and its ffprobe dies on its next
  /// write); [result] completes with null.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _process?.kill();
    if (!_done.isCompleted) _done.complete(null);
  }
}
