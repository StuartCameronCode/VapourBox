import 'package:json_annotation/json_annotation.dart';

part 'progress_info.g.dart';

/// Progress information reported by the worker process.
@JsonSerializable()
class ProgressInfo {
  final int frame;
  final int totalFrames;
  final double fps;
  final double eta;

  const ProgressInfo({
    required this.frame,
    required this.totalFrames,
    required this.fps,
    required this.eta,
  });

  factory ProgressInfo.fromJson(Map<String, dynamic> json) =>
      _$ProgressInfoFromJson(json);
  Map<String, dynamic> toJson() => _$ProgressInfoToJson(this);

  /// Progress as a fraction (0.0 to 1.0).
  double get progress => totalFrames > 0 ? frame / totalFrames : 0.0;

  /// Progress as a percentage (0 to 100).
  int get percentComplete => (progress * 100).toInt();

  /// Formatted ETA string (e.g., "1h 23m 45s").
  String get etaFormatted {
    if (eta <= 0 || !eta.isFinite) return '--';

    final totalSecs = eta.toInt();
    final hours = totalSecs ~/ 3600;
    final minutes = (totalSecs % 3600) ~/ 60;
    final seconds = totalSecs % 60;

    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    } else {
      return '${seconds}s';
    }
  }

  /// Formatted FPS string.
  String get fpsFormatted {
    if (fps <= 0 || !fps.isFinite) return '-- fps';
    return '${fps.toStringAsFixed(1)} fps';
  }
}

/// Messages sent from worker to main app via stdout.
@JsonSerializable()
class WorkerMessage {
  final String type;
  final int? frame;
  final int? totalFrames;
  final double? fps;
  final double? eta;
  final String? level;
  final String? message;
  final bool? success;
  final String? outputPath;

  const WorkerMessage({
    required this.type,
    this.frame,
    this.totalFrames,
    this.fps,
    this.eta,
    this.level,
    this.message,
    this.success,
    this.outputPath,
  });

  factory WorkerMessage.fromJson(Map<String, dynamic> json) =>
      _$WorkerMessageFromJson(json);
  Map<String, dynamic> toJson() => _$WorkerMessageToJson(this);

  bool get isProgress => type == 'progress';
  bool get isLog => type == 'log';
  bool get isError => type == 'error';
  bool get isComplete => type == 'complete';

  ProgressInfo? toProgressInfo() {
    if (!isProgress) return null;
    return ProgressInfo(
      frame: frame ?? 0,
      totalFrames: totalFrames ?? 0,
      fps: fps ?? 0.0,
      eta: eta ?? 0.0,
    );
  }
}

/// Log levels.
enum LogLevel {
  debug,
  info,
  warning,
  error;

  static LogLevel fromString(String value) {
    return LogLevel.values.firstWhere(
      (e) => e.name == value.toLowerCase(),
      orElse: () => LogLevel.info,
    );
  }
}

/// Processing state machine.
enum ProcessingState {
  idle,
  preparingJob,
  processing,
  cancelling,
  completed,
  failed;

  bool get isActive =>
      this == ProcessingState.preparingJob ||
      this == ProcessingState.processing ||
      this == ProcessingState.cancelling;

  bool get canCancel =>
      this == ProcessingState.preparingJob ||
      this == ProcessingState.processing;
}
