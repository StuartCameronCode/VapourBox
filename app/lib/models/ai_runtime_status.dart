/// Whether the AI runtime add-on (ONNX Runtime) runs on this computer, and on
/// which execution provider, as reported by the worker's `--probe-ai-runtime`.
///
/// The worker owns the decision and the wording (`worker/src/ai_runtime.rs`):
/// it checks the add-on is installed, imports ONNX Runtime the way a job does
/// (`worker/templates/ai_runtime.py`) and runs a tiny test model, directly and
/// through a VapourSynth frame. [message] is its explanation with a remedy,
/// shown verbatim.
library;

class AiRuntimeStatus {
  final bool available;

  /// The worker's reason id (`notInstalled`, `importFailed`, …), for logging.
  final String? reason;

  /// What to tell the user, remedy included. Null when [available].
  final String? message;

  /// onnxruntime's version, when it loaded.
  final String? version;

  /// Every execution provider the installed onnxruntime offers
  /// (`CoreMLExecutionProvider`, `DmlExecutionProvider`, `CPUExecutionProvider`…).
  final List<String> providers;

  /// The provider the test model ran on.
  final String? provider;

  /// Why the preferred GPU provider was not used, if it fell back to the CPU.
  final String? fallback;

  const AiRuntimeStatus({
    required this.available,
    this.reason,
    this.message,
    this.version,
    this.providers = const [],
    this.provider,
    this.fallback,
  });

  /// The status when the probe itself could not be run or read.
  const AiRuntimeStatus.unknown()
      : available = false,
        reason = 'probeFailed',
        message = "VapourBox couldn't check whether the AI runtime add-on runs on "
            'this computer. Restart VapourBox to try again.',
        version = null,
        providers = const [],
        provider = null,
        fallback = null;

  factory AiRuntimeStatus.fromJson(Map<String, dynamic> json) {
    final available = json['available'] == true;
    final message = json['message'];
    if (!available && message is! String) return const AiRuntimeStatus.unknown();
    return AiRuntimeStatus(
      available: available,
      reason: json['reason'] as String?,
      message: available ? null : message as String,
      version: json['version'] as String?,
      providers: (json['providers'] as List<dynamic>? ?? const []).cast<String>(),
      provider: json['provider'] as String?,
      fallback: json['fallback'] as String?,
    );
  }

  /// Whether the test model ran on a GPU (or Neural Engine) provider rather
  /// than the CPU.
  bool get onGpu => available && provider != null && provider != 'CPUExecutionProvider';

  /// The provider in words, for the UI ("Core ML", "DirectML", "CPU").
  static String providerLabel(String provider) => switch (provider) {
        'CoreMLExecutionProvider' => 'Core ML',
        'DmlExecutionProvider' => 'DirectML',
        'CUDAExecutionProvider' => 'CUDA',
        'TensorrtExecutionProvider' => 'TensorRT',
        'CPUExecutionProvider' => 'CPU',
        _ => provider.replaceAll('ExecutionProvider', ''),
      };
}
