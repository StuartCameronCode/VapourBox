/// Whether an ncnn-on-Vulkan feature runs on this computer, as reported by the
/// worker's `--probe-rife` / `--probe-upscale`.
///
/// The worker owns the decision and the wording (`worker/src/gpu_plugin.rs`):
/// it checks the platform and the bundled files, then runs the plugin once and
/// classifies how it failed — no Vulkan device, a missing system library, an
/// older deps bundle. [GpuPluginStatus.message] is that explanation with its
/// remedy, shown to the user verbatim; the worker fails such a job with the
/// same text.
library;

/// The two features that run a network through ncnn on the GPU.
enum GpuPlugin {
  /// RIFE frame interpolation (Frame Rate pass).
  rife('RIFE', '--probe-rife'),

  /// Real-ESRGAN / Real-CUGAN upscaling (Crop & Resize pass).
  upscale('AI upscaling', '--probe-upscale');

  const GpuPlugin(this.label, this.probeFlag);

  /// The name the worker's messages use.
  final String label;

  /// The worker flag that probes it.
  final String probeFlag;
}

class GpuPluginStatus {
  final bool available;

  /// The worker's reason id (`noVulkan`, `missingLibrary`, …), for logging.
  final String? reason;

  /// What to tell the user, remedy included. Null when [available].
  final String? message;

  const GpuPluginStatus({required this.available, this.reason, this.message});

  /// The status when the probe itself could not be run or read.
  GpuPluginStatus.unknown(GpuPlugin plugin)
      : available = false,
        reason = 'probeFailed',
        message = "VapourBox couldn't check whether ${plugin.label} runs on this "
            'computer. Restart VapourBox to try again.';

  factory GpuPluginStatus.fromJson(GpuPlugin plugin, Map<String, dynamic> json) {
    final available = json['available'] == true;
    final message = json['message'];
    if (!available && message is! String) return GpuPluginStatus.unknown(plugin);
    return GpuPluginStatus(
      available: available,
      reason: json['reason'] as String?,
      message: available ? null : message as String,
    );
  }
}

/// What a settings panel shows about a GPU feature's prerequisites.
enum GpuPluginNotice {
  /// The feature is not selected, or it runs here.
  none,

  /// The feature is selected and the probe has not answered yet.
  checking,

  /// The feature is selected and cannot run here; show the status message.
  unavailable,
}

/// The one decision behind the panels' GPU notices, separate from the widget
/// so it can be tested. Shown whenever the feature is selected, enabled or
/// not: choosing it is the moment the user needs to hear it won't work.
GpuPluginNotice gpuPluginNoticeFor({
  required bool selected,
  required GpuPluginStatus? status,
  required bool checking,
}) {
  if (!selected) return GpuPluginNotice.none;
  if (checking || status == null) return GpuPluginNotice.checking;
  return status.available ? GpuPluginNotice.none : GpuPluginNotice.unavailable;
}

/// Which GPU feature, if any, a panel's current values select.
GpuPlugin? gpuPluginSelectedBy(String filterId, Map<String, dynamic> values) {
  switch (filterId) {
    case 'frame_rate':
      return values['method'] == 'rife' ? GpuPlugin.rife : null;
    case 'crop_resize':
      final method = values['upscaleMethod'];
      return values['useIntegerUpscale'] == true &&
              (method == 'realEsrgan' || method == 'realCugan')
          ? GpuPlugin.upscale
          : null;
  }
  return null;
}
