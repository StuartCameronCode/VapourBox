import 'package:flutter/material.dart';

import '../services/field_order_detector.dart';

/// The source's dynamic range ("HDR10", "HLG", "Dolby Vision 8.1") beside the
/// resolution under the preview, with what VapourBox does with it in the
/// tooltip (issue #133).
///
/// Dolby Vision Profile 5 is drawn as a warning, because it is the one case
/// that can't come out right: its picture is in Dolby's own colour space and
/// shows pink and green without a Dolby Vision decoder.
class DynamicRangeBadge extends StatelessWidget {
  const DynamicRangeBadge({super.key, required this.info});

  final VideoInfo info;

  /// Whether there is anything to show (false for SDR).
  static bool shows(VideoInfo info) => info.dynamicRangeLabel != null;

  /// The tooltip, also the Video Info dialog's explanation.
  static String explanation(VideoInfo info) {
    final dv = info.dolbyVision;
    if (dv != null && dv.baseLayerIsUndecodable) {
      return '${dv.label} stores its picture in Dolby\'s own colour space, '
          'which only a Dolby Vision decoder can convert. VapourBox cannot, '
          'so its colours will look pink and green in the preview and in '
          'the output. Other Dolby Vision profiles (7 and 8, used by UHD '
          'Blu-ray and phones) are not affected.';
    }
    final hdr = 'Shown tone-mapped for this screen. The output keeps the '
        'source\'s HDR colour tags; H.265 (x265) also keeps its mastering '
        'display and light-level metadata.';
    if (dv != null) {
      return '$hdr The Dolby Vision dynamic metadata is not carried over, '
          'so the output plays as standard HDR.';
    }
    return hdr;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final warn = info.dolbyVision?.baseLayerIsUndecodable ?? false;
    final color = warn
        ? scheme.error
        : scheme.onSurface.withValues(alpha: 0.6);
    return Tooltip(
      message: explanation(info),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            warn ? Icons.warning_amber_rounded : Icons.hdr_on_outlined,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            warn
                ? '${info.dynamicRangeLabel} — colours unsupported'
                : info.dynamicRangeLabel!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
