/// Whether RIFE frame interpolation runs on this computer, as reported by
/// `vapourbox-worker --probe-rife`.
///
/// The worker owns the decision and the wording (`worker/src/rife.rs`): it
/// checks the platform and the bundled files, then runs the plugin once and
/// classifies how it failed — no Vulkan device, a missing system library, an
/// older deps bundle. [message] is that explanation with its remedy, shown to
/// the user verbatim; the worker fails a RIFE job with the same text.
class RifeStatus {
  final bool available;

  /// The worker's reason id (`noVulkan`, `missingLibrary`, …), for logging.
  final String? reason;

  /// What to tell the user, remedy included. Null when [available].
  final String? message;

  const RifeStatus({required this.available, this.reason, this.message});

  /// The status when the probe itself could not be run or read.
  const RifeStatus.unknown()
      : available = false,
        reason = 'probeFailed',
        message = "VapourBox couldn't check whether RIFE runs on this "
            'computer. Restart VapourBox to try again.';

  factory RifeStatus.fromJson(Map<String, dynamic> json) {
    final available = json['available'] == true;
    final message = json['message'];
    if (!available && message is! String) return const RifeStatus.unknown();
    return RifeStatus(
      available: available,
      reason: json['reason'] as String?,
      message: available ? null : message as String,
    );
  }
}

/// What the Frame Rate panel shows about RIFE's prerequisites.
enum RifeNotice {
  /// RIFE is not selected, or it runs here.
  none,

  /// RIFE is selected and the probe has not answered yet.
  checking,

  /// RIFE is selected and cannot run here; show [RifeStatus.message].
  unavailable,
}

/// The one decision behind the panel's RIFE notice, separate from the widget
/// so it can be tested. Shown whenever RIFE is the selected method, enabled or
/// not: choosing it is the moment the user needs to hear it won't work.
RifeNotice rifeNoticeFor({
  required Object? method,
  required RifeStatus? status,
  required bool checking,
}) {
  if (method != 'rife') return RifeNotice.none;
  if (checking || status == null) return RifeNotice.checking;
  return status.available ? RifeNotice.none : RifeNotice.unavailable;
}
