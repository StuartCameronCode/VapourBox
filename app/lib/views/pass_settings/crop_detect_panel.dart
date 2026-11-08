import 'package:flutter/material.dart';

import '../../models/crop_detect_report.dart';
import '../../services/whats_new_service.dart';
import '../../viewmodels/main_viewmodel.dart';
import '../../widgets/warning_banner.dart';

/// Crop & Resize's Detect (app 1.7.0): measures the selected video's black
/// borders, blanking and head-switching band and offers what it found. Like
/// Descale's Detect it is advisory: the controls change only when the user
/// clicks one of the Apply buttons, and a letterbox bar is offered separately
/// because cropping the picture's own framing is the user's choice.
class CropDetectPanel extends StatelessWidget {
  final MainViewModel viewModel;

  const CropDetectPanel({super.key, required this.viewModel});

  /// The release Detect shipped in, for its NEW badge.
  static const sinceAppVersion = '1.7.0';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = viewModel.cropReport;
    final running = viewModel.detectingCrop;
    final canRun = viewModel.selectedItem != null && !running;
    final scheme = theme.colorScheme;
    final children = <Widget>[
      Row(
        children: [
          Badge(
            isLabelVisible: WhatsNewService.instance.isNew(sinceAppVersion),
            backgroundColor: scheme.tertiaryContainer,
            textColor: scheme.onTertiaryContainer,
            textStyle: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.4),
            offset: const Offset(10, -8),
            label: const Text('NEW'),
            child: OutlinedButton.icon(
              onPressed: canRun ? viewModel.detectCrop : null,
              icon: running
                  ? const SizedBox.square(
                      dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.crop_free, size: 16),
              label: Text(running ? 'Detecting…' : 'Detect borders'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              running
                  ? 'Measuring the edges of frames from across this video.'
                  : viewModel.selectedItem == null
                      ? 'Select a video to analyse.'
                      : 'Finds black borders, tape blanking and head-switching noise.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    ];
    if (!running && report != null) {
      children.add(_result(context, report));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  Widget _result(BuildContext context, CropDetectReport report) {
    final theme = Theme.of(context);
    if (report.error != null) {
      return WarningBanner(message: 'Detection failed: ${report.error}');
    }
    if (!report.found) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          report.message ?? 'Nothing to crop at the edges.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    final c = report.crop;
    final lines = <Widget>[
      for (final (side, what) in report.findings)
        Text('$side: $what', style: theme.textTheme.bodySmall),
      const SizedBox(height: 4),
      SelectableText(
        c.isZero
            ? 'Nothing to crop apart from the bars.'
            : 'Crop left ${c.left}, right ${c.right}, top ${c.top}, bottom ${c.bottom}.',
      ),
    ];
    if (report.isLowConfidence) {
      lines.add(WarningBanner(
        message: 'Hard to judge: in only ${(report.confidence * 100).round()}% of the '
            'sampled frames does the picture reach an edge that was found; in the '
            'rest it is dark there too. Check the preview before applying.',
      ));
    }
    final buttons = <Widget>[
      if (!c.isZero)
        FilledButton(
          onPressed: () => viewModel.applyCropDetection(CropApply.crop),
          child: const Text('Apply crop'),
        ),
      if (report.cropWithBars != null)
        OutlinedButton(
          onPressed: () => viewModel.applyCropDetection(CropApply.cropWithBars),
          child: const Text('Crop the bars too'),
        ),
      if (report.edgeRepair != null)
        OutlinedButton(
          onPressed: () => viewModel.applyCropDetection(CropApply.repairBand),
          child: const Text('Repair the band instead'),
        ),
    ];
    if (report.cropWithBars != null) {
      lines.add(Text(
        'The bars are part of the picture\'s framing (a widescreen film in a '
        '4:3 frame, or 4:3 in HD): they are only cropped if you choose to.',
        style: theme.textTheme.bodySmall,
      ));
    }
    if (report.edgeRepair != null) {
      lines.add(Text(
        'Repairing the head-switching band with Edge Repair keeps the frame '
        'height (for DVD authoring, say) instead of cropping it.',
        style: theme.textTheme.bodySmall,
      ));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...lines,
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: buttons),
        ],
      ),
    );
  }
}
