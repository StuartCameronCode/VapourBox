import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/app_shortcut.dart';
import '../services/timeline_math.dart';
import '../viewmodels/main_viewmodel.dart';
import '../widgets/before_after_comparison.dart';
import 'histogram_scope.dart';

class PreviewPanel extends StatefulWidget {
  const PreviewPanel({super.key});

  @override
  State<PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<PreviewPanel> {
  /// Whether the histogram overlay is shown over the processed preview.
  ///
  /// Deliberately available in simple mode: the scope exists to make the
  /// colour controls usable, so hiding it from the people who need those
  /// controls would defeat it.
  bool _showHistogram = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        return Column(
          children: [
            // Preview comparison area
            Expanded(
              child: _buildPreviewComparison(context, viewModel),
            ),

            // Thumbnail scrubber
            _buildScrubber(context, viewModel),
          ],
        );
      },
    );
  }

  Widget _buildPreviewComparison(BuildContext context, MainViewModel viewModel) {
    // Compute display aspect ratio for SAR correction.
    // DAR = (width / height) * (sarNum / sarDen)
    // Only needed when SAR is non-square (e.g. anamorphic DVD 32:27).
    double? displayAspectRatio;
    final videoInfo = viewModel.videoInfo;
    if (videoInfo != null && videoInfo.sar != null) {
      final parts = videoInfo.sar!.split(':');
      if (parts.length == 2) {
        final sarNum = double.tryParse(parts[0]);
        final sarDen = double.tryParse(parts[1]);
        if (sarNum != null && sarDen != null && sarDen > 0) {
          displayAspectRatio =
              (videoInfo.width / videoInfo.height) * (sarNum / sarDen);
        }
      }
    }

    // The scope reads the processed preview, falling back to the source frame
    // before any pass has rendered — that is what the user is looking at.
    final scopeImage = viewModel.processedPreview ?? viewModel.currentFrame;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Stack(
        children: [
          Positioned.fill(
            child: BeforeAfterComparisonWidget(
              beforeImage: viewModel.currentFrame,
              afterImage: scopeImage,
              isBeforeLoading: viewModel.isAnalyzing,
              isAfterLoading: viewModel.isGeneratingPreview,
              displayAspectRatio: displayAspectRatio,
            ),
          ),

          // Histogram overlay and its toggle, top-right of the preview.
          Positioned(
            top: 8,
            right: 8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!_showHistogram) _buildHistogramToggle(context),
                if (_showHistogram)
                  HistogramScope(
                    imageBytes: scopeImage,
                    onClose: () => setState(() => _showHistogram = false),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistogramToggle(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: 'Show histogram',
      child: Material(
        color: colorScheme.surface.withValues(alpha: 0.85),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: colorScheme.outline.withValues(alpha: 0.4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _showHistogram = true),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              Icons.bar_chart,
              size: 18,
              color: colorScheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Timeline (issue #102)
  //
  // Three rows, each laid out so nothing in it moves as values change: a
  // transport bar (time readout | frame buttons | in/out), the thumbnail strip,
  // and a zoom bar (view start | zoom controls | view end) above the minimap.
  // The middle control of each row sits between two equal Expanded regions,
  // so it stays centred however wide the readouts on either side become, and
  // every control is always present — disabled rather than removed — so
  // zooming in never shifts the buttons you are clicking.
  // ---------------------------------------------------------------------------

  // Widths of the transport-bar groups: buttons + dividers + border. The
  // frame buttons are centred between two equal halves, so the in/out group
  // has to fit in one half for the row to stay centred.
  static const double _frameButtonsWidth = 40 + 48 + 48 + 40 + 3 + 2;
  static const double _inOutLabelledWidth = 96 + 96 + 36 + 2 + 2;
  static const double _inOutIconWidth = 40 + 40 + 36 + 2 + 2;
  static const double _transportGap = 12;

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  /// Last cumulative pinch scale seen in the current trackpad gesture.
  double _lastPinchScale = 1.0;

  Widget _buildScrubber(BuildContext context, MainViewModel viewModel) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTransportBar(context, viewModel),
          const SizedBox(height: 10),
          _buildThumbnailStrip(context, viewModel),
          const SizedBox(height: 8),
          _buildZoomBar(context, viewModel),
          const SizedBox(height: 8),
          _buildMinimap(context, viewModel),
        ],
      ),
    );
  }

  /// Always one row. As the panel narrows the in/out buttons lose their text
  /// and keep only their icons; narrower still, the frame buttons give up
  /// being centred and the controls shrink slightly rather than overflow.
  Widget _buildTransportBar(BuildContext context, MainViewModel viewModel) {
    final readout = _buildTimeReadout(context, viewModel);
    final transport = _buildFrameButtons(context, viewModel);

    return LayoutBuilder(
      builder: (context, constraints) {
        final side = (constraints.maxWidth -
                _frameButtonsWidth -
                2 * _transportGap) /
            2;

        if (side >= _inOutIconWidth) {
          final labelled = side >= _inOutLabelledWidth;
          return Row(
            children: [
              Expanded(
                child: Align(alignment: Alignment.centerLeft, child: readout),
              ),
              const SizedBox(width: _transportGap),
              transport,
              const SizedBox(width: _transportGap),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _buildInOutButtons(context, viewModel,
                      labelled: labelled),
                ),
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: readout),
            const SizedBox(width: 8),
            Flexible(
              flex: 3,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    transport,
                    const SizedBox(width: _transportGap),
                    _buildInOutButtons(context, viewModel, labelled: false),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTimeReadout(BuildContext context, MainViewModel viewModel) {
    final theme = Theme.of(context);
    final current = viewModel.scrubberPosition * viewModel.videoDuration;
    final hasFrames = viewModel.totalFrames > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: _formatTime(current),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: ' / ${_formatTime(viewModel.videoDuration)}',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ]),
          style: theme.textTheme.titleSmall
              ?.copyWith(fontFeatures: _tabular),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          hasFrames
              ? 'Frame ${viewModel.currentFrameIndex} / ${viewModel.totalFrames - 1}'
              : 'Frame —',
          style: theme.textTheme.bodySmall?.copyWith(
            fontFeatures: _tabular,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildFrameButtons(BuildContext context, MainViewModel viewModel) {
    final hasFrames = viewModel.totalFrames > 0;
    final atStart = !hasFrames || viewModel.currentFrameIndex <= 0;
    final atEnd =
        !hasFrames || viewModel.currentFrameIndex >= viewModel.totalFrames - 1;

    return _ButtonGroup(
      children: [
        _GroupButton(
          icon: Icons.skip_previous,
          tooltip: AppShortcut.goToStart.tooltip,
          onPressed: atStart ? null : viewModel.goToStart,
        ),
        _GroupButton(
          icon: Icons.arrow_left,
          iconSize: 30,
          width: 48,
          tooltip: AppShortcut.previousFrame.tooltip,
          onPressed: atStart ? null : () => viewModel.stepFrame(-1),
        ),
        _GroupButton(
          icon: Icons.arrow_right,
          iconSize: 30,
          width: 48,
          tooltip: AppShortcut.nextFrame.tooltip,
          onPressed: atEnd ? null : () => viewModel.stepFrame(1),
        ),
        _GroupButton(
          icon: Icons.skip_next,
          tooltip: AppShortcut.goToEnd.tooltip,
          onPressed: atEnd ? null : viewModel.goToEnd,
        ),
      ],
    );
  }

  /// Set In / Set Out / clear. With [labelled] false the buttons show only
  /// their icons — still coloured when a point is set, with the time moved
  /// into the tooltip.
  Widget _buildInOutButtons(
    BuildContext context,
    MainViewModel viewModel, {
    required bool labelled,
  }) {
    final inPoint = viewModel.inPoint;
    final outPoint = viewModel.outPoint;
    final duration = viewModel.videoDuration;
    final inTime = inPoint != null ? _formatTime(inPoint * duration) : null;
    final outTime = outPoint != null ? _formatTime(outPoint * duration) : null;

    Widget point(IconData icon, String? time, String unset, Color color) {
      if (!labelled) {
        return Icon(
          icon,
          size: 20,
          color: time != null
              ? color
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
        );
      }
      return _pointLabel(
        context,
        icon: icon,
        text: time ?? unset,
        color: time != null ? color : null,
      );
    }

    return _ButtonGroup(
      children: [
        _GroupButton(
          width: labelled ? 96 : 40,
          tooltip: AppShortcut.setInPoint.tooltipFor(inTime != null
              ? 'Set in point — currently $inTime'
              : 'Set in point — start of the export range'),
          onPressed: viewModel.setInPointToCurrent,
          child: point(Icons.first_page, inTime, 'Set In', _inColor),
        ),
        _GroupButton(
          width: labelled ? 96 : 40,
          tooltip: AppShortcut.setOutPoint.tooltipFor(outTime != null
              ? 'Set out point — currently $outTime'
              : 'Set out point — end of the export range'),
          onPressed: viewModel.setOutPointToCurrent,
          child: point(Icons.last_page, outTime, 'Set Out', _outColor),
        ),
        _GroupButton(
          icon: Icons.clear,
          iconSize: 18,
          width: 36,
          tooltip: AppShortcut.clearInOut.tooltip,
          onPressed:
              viewModel.hasInOutRange ? viewModel.clearInOutPoints : null,
        ),
      ],
    );
  }

  static const Color _inColor = Color(0xFF2E9E4F);
  static const Color _outColor = Color(0xFFD64545);

  Widget _pointLabel(
    BuildContext context, {
    required IconData icon,
    required String text,
    Color? color,
  }) {
    final theme = Theme.of(context);
    final foreground =
        color ?? theme.colorScheme.onSurface.withValues(alpha: 0.8);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 4),
            Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: foreground,
                fontWeight: color != null ? FontWeight.bold : FontWeight.w500,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnailStrip(BuildContext context, MainViewModel viewModel) {
    final colorScheme = Theme.of(context).colorScheme;
    final thumbnails = viewModel.thumbnails;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final zoom = viewModel.timelineZoom;
        final viewStart = viewModel.timelineViewStart;

        // Video position <-> x within the strip, through the current view.
        double toX(double position) =>
            TimelineMath.fractionInView(position, viewStart, zoom) * width;
        double toPosition(double x) =>
            (viewStart + (x / width) / zoom).clamp(0.0, 1.0);
        bool onScreen(double position) {
          final x = toX(position);
          return x >= 0 && x <= width;
        }

        final inPoint = viewModel.inPoint;
        final outPoint = viewModel.outPoint;
        final playhead = viewModel.scrubberPosition;

        // The thumbnails cover the span they were generated for, which lags
        // the view by the regeneration debounce; drawing them over that span
        // keeps them under the right part of the timeline while new ones load.
        final thumbsLeft = toX(viewModel.thumbnailRangeStart);
        final thumbsWidth = toX(viewModel.thumbnailRangeEnd) - thumbsLeft;

        return Listener(
          onPointerSignal: (event) =>
              _onStripPointerSignal(event, viewModel, width, toPosition),
          onPointerPanZoomStart: (_) => _lastPinchScale = 1.0,
          onPointerPanZoomUpdate: (event) =>
              _onStripPanZoom(event, viewModel, width, toPosition),
          child: SizedBox(
            height: 60,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(color: colorScheme.surfaceContainerHighest),
                  ),

                  if (thumbnails.isNotEmpty && thumbsWidth > 0)
                    Positioned(
                      left: thumbsLeft,
                      width: thumbsWidth,
                      top: 0,
                      bottom: 0,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final thumb in thumbnails)
                            Expanded(
                              child: Image.memory(
                                thumb,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              ),
                            ),
                        ],
                      ),
                    )
                  else if (thumbnails.isEmpty)
                    Positioned.fill(
                      child: Center(
                        child: Text(
                          viewModel.isAnalyzing ||
                                  viewModel.isLoadingZoomedThumbnails
                              ? 'Generating thumbnails...'
                              : 'No thumbnails',
                          style: TextStyle(
                            color: colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),

                  // Gradient for contrast against the playhead and markers.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.05),
                              Colors.black.withValues(alpha: 0.3),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Shade what falls outside the export range.
                  if (inPoint != null && toX(inPoint) > 0)
                    Positioned(
                      left: 0,
                      width: toX(inPoint).clamp(0.0, width),
                      top: 0,
                      bottom: 0,
                      child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.45)),
                    ),
                  if (outPoint != null && toX(outPoint) < width)
                    Positioned(
                      left: toX(outPoint).clamp(0.0, width),
                      right: 0,
                      top: 0,
                      bottom: 0,
                      child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.45)),
                    ),
                  if (inPoint != null && onScreen(inPoint))
                    _marker(toX(inPoint), _inColor, 2),
                  if (outPoint != null && onScreen(outPoint))
                    _marker(toX(outPoint), _outColor, 2),

                  if (onScreen(playhead))
                    Positioned(
                      left: toX(playhead) - 1.5,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.5),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Small and in the corner: the existing thumbnails are
                  // already in the right place, so there is nothing to hide.
                  if (viewModel.isLoadingZoomedThumbnails &&
                      thumbnails.isNotEmpty)
                    const Positioned(
                      top: 6,
                      right: 6,
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),

                  // Click or drag to scrub. Trackpad scrolls and pinches are
                  // excluded here and handled by the Listener above as pan and
                  // zoom, so a two-finger swipe doesn't scrub.
                  Positioned.fill(
                    child: GestureDetector(
                      supportedDevices: const {
                        PointerDeviceKind.mouse,
                        PointerDeviceKind.touch,
                        PointerDeviceKind.stylus,
                        PointerDeviceKind.invertedStylus,
                        PointerDeviceKind.unknown,
                      },
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) => viewModel.setScrubberPosition(
                          toPosition(details.localPosition.dx)),
                      onHorizontalDragStart: (details) =>
                          viewModel.setScrubberPosition(
                              toPosition(details.localPosition.dx)),
                      onHorizontalDragUpdate: (details) =>
                          viewModel.setScrubberPosition(
                              toPosition(details.localPosition.dx)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _marker(double x, Color color, double width) => Positioned(
        left: x - width / 2,
        width: width,
        top: 0,
        bottom: 0,
        child: ColoredBox(color: color),
      );

  /// Mouse wheel: scroll to zoom about the point under the cursor, Shift+scroll
  /// (or a horizontal wheel) to pan. The zoom is proportional to the scroll
  /// distance, so a high-resolution wheel zooms smoothly rather than in a
  /// fixed jump per event.
  void _onStripPointerSignal(
    PointerSignalEvent event,
    MainViewModel viewModel,
    double width,
    double Function(double x) toPosition,
  ) {
    if (event is! PointerScrollEvent || width <= 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final scroll = event as PointerScrollEvent;
      final dx = scroll.scrollDelta.dx;
      final dy = scroll.scrollDelta.dy;
      final horizontal = dx.abs() > dy.abs();

      if (horizontal || HardwareKeyboard.instance.isShiftPressed) {
        final delta = horizontal ? dx : dy;
        viewModel.panTimeline(delta / width / viewModel.timelineZoom);
      } else if (dy != 0) {
        final x = scroll.localPosition.dx;
        viewModel.zoomTimelineBy(
          math.exp(-dy * 0.003).clamp(0.5, 2.0),
          anchor: toPosition(x),
          anchorFraction: (x / width).clamp(0.0, 1.0),
        );
      }
    });
  }

  /// Trackpad: pinch to zoom about the gesture, two-finger horizontal swipe to
  /// pan. Vertical swipes are left alone, so brushing the trackpad while
  /// scrolling the window past the timeline doesn't zoom it.
  void _onStripPanZoom(
    PointerPanZoomUpdateEvent event,
    MainViewModel viewModel,
    double width,
    double Function(double x) toPosition,
  ) {
    if (width <= 0) return;

    final factor = event.scale / _lastPinchScale;
    _lastPinchScale = event.scale;
    if ((factor - 1.0).abs() > 1e-3) {
      final x = event.localPosition.dx;
      viewModel.zoomTimelineBy(
        factor,
        anchor: toPosition(x),
        anchorFraction: (x / width).clamp(0.0, 1.0),
      );
    }

    final pan = event.panDelta;
    if (pan.dx != 0 && pan.dx.abs() > pan.dy.abs()) {
      viewModel.panTimeline(-pan.dx / width / viewModel.timelineZoom);
    }
  }

  Widget _buildZoomBar(BuildContext context, MainViewModel viewModel) {
    final theme = Theme.of(context);
    final zoom = viewModel.timelineZoom;
    final isZoomed = zoom > TimelineMath.minZoom;
    final dimStyle = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: _tabular,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );

    return Row(
      children: [
        Expanded(
          child: Text(
            _formatTime(viewModel.visibleStartTime),
            style: dimStyle,
          ),
        ),
        _ButtonGroup(
          height: 28,
          children: [
            _GroupButton(
              icon: Icons.remove,
              iconSize: 18,
              width: 32,
              tooltip: AppShortcut.zoomOut.tooltipFor('Zoom timeline out'),
              onPressed: isZoomed ? viewModel.zoomOut : null,
            ),
            SizedBox(
              width: 52,
              child: Center(
                child: Text(
                  '${zoom.toStringAsFixed(1)}×',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: _tabular,
                    fontWeight: FontWeight.bold,
                    color: isZoomed
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
            _GroupButton(
              icon: Icons.add,
              iconSize: 18,
              width: 32,
              tooltip: AppShortcut.zoomIn.tooltipFor('Zoom timeline in'),
              onPressed:
                  zoom < TimelineMath.maxZoom ? viewModel.zoomIn : null,
            ),
            _GroupButton(
              icon: Icons.fit_screen,
              iconSize: 18,
              width: 32,
              tooltip: AppShortcut.zoomToFit
                  .tooltipFor('Show the whole video'),
              onPressed: isZoomed ? viewModel.resetTimelineZoom : null,
            ),
          ],
        ),
        Expanded(
          child: Text(
            _formatTime(viewModel.visibleEndTime),
            style: dimStyle,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  /// The whole video at a glance: the zoomed view, the export range and the
  /// playhead. Clicking or dragging scrubs, and a zoomed view follows the
  /// playhead there.
  Widget _buildMinimap(BuildContext context, MainViewModel viewModel) {
    final colorScheme = Theme.of(context).colorScheme;
    final isZoomed = viewModel.timelineZoom > TimelineMath.minZoom;

    return SizedBox(
      height: 12,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final minimapWidth = constraints.maxWidth;
          final viewStart = viewModel.timelineViewStart;
          final viewEnd = viewModel.timelineViewEnd;
          final playheadX = viewModel.scrubberPosition * minimapWidth;

          return GestureDetector(
            onTapDown: (details) {
              final tapPosition = details.localPosition.dx / minimapWidth;
              viewModel.setScrubberPosition(tapPosition.clamp(0.0, 1.0));
            },
            onHorizontalDragUpdate: (details) {
              final dragPosition = details.localPosition.dx / minimapWidth;
              viewModel.setScrubberPosition(dragPosition.clamp(0.0, 1.0));
            },
            child: Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(2),
              ),
              child: Stack(
                children: [
                  // Visible range highlight (only when zoomed)
                  if (isZoomed)
                    Positioned(
                      left: viewStart * minimapWidth,
                      width: (viewEnd - viewStart) * minimapWidth,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),

                  // Dimmed region before in point
                  if (viewModel.inPoint != null)
                    Positioned(
                      left: 0,
                      width: viewModel.inPoint! * minimapWidth,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.4),
                      ),
                    ),

                  // Dimmed region after out point
                  if (viewModel.outPoint != null)
                    Positioned(
                      left: viewModel.outPoint! * minimapWidth,
                      right: 0,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.4),
                      ),
                    ),

                  if (viewModel.inPoint != null)
                    _marker(viewModel.inPoint! * minimapWidth, _inColor, 2),
                  if (viewModel.outPoint != null)
                    _marker(viewModel.outPoint! * minimapWidth, _outColor, 2),

                  // Playhead indicator
                  Positioned(
                    left: playheadX - 1,
                    width: 2,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _formatTime(double seconds) {
    if (!seconds.isFinite || seconds < 0) return '0:00';

    final totalSecs = seconds.toInt();
    final hours = totalSecs ~/ 3600;
    final minutes = (totalSecs % 3600) ~/ 60;
    final secs = totalSecs % 60;
    final ss = secs.toString().padLeft(2, '0');

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
    }
    return '$minutes:$ss';
  }
}

/// Joined buttons drawn as one control, like a transport bar.
class _ButtonGroup extends StatelessWidget {
  final List<Widget> children;
  final double height;

  const _ButtonGroup({required this.children, this.height = 36});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final divider = colorScheme.outline.withValues(alpha: 0.3);

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.35)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Container(width: 1, color: divider),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One segment of a [_ButtonGroup]: an icon or a custom [child], full height,
/// with a tooltip that stays available while it is disabled so the shortcut
/// can still be discovered.
class _GroupButton extends StatelessWidget {
  final IconData? icon;
  final Widget? child;
  final String tooltip;
  final VoidCallback? onPressed;
  final double width;
  final double iconSize;

  const _GroupButton({
    this.icon,
    this.child,
    required this.tooltip,
    required this.onPressed,
    this.width = 40,
    this.iconSize = 22,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final color = enabled
        ? colorScheme.onSurface
        : colorScheme.onSurface.withValues(alpha: 0.3);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          mouseCursor:
              enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: SizedBox(
            width: width,
            height: double.infinity,
            child: Center(
              child: child != null
                  ? IconTheme.merge(
                      data: IconThemeData(color: color),
                      child: child!,
                    )
                  : Icon(icon, size: iconSize, color: color),
            ),
          ),
        ),
      ),
    );
  }
}
