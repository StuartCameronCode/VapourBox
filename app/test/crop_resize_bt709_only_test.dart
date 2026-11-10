// Crop & Resize used only for its BT.601 -> BT.709 conversion (forum #154 /
// #155): "Always" converts with no crop or resize, as long as the pass is on.
// The pass must then count as a pass, or a job with subtitles on is sent as
// subtitle-only and the worker never encodes the picture, so the conversion
// is silently lost.
import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/subtitle_parameters.dart';

void main() {
  ProcessingPipeline pipeline(CropResizeParameters cropResize, {bool subtitles = false}) =>
      ProcessingPipeline(
        deinterlace: const QTGMCParameters(enabled: false),
        cropResize: cropResize,
        subtitles: SubtitleParameters(enabled: subtitles),
      );

  const colourOnly = CropResizeParameters(enabled: true, convertToBt709: Bt709Conversion.on);

  test('an enabled Crop & Resize with no geometry is a pass', () {
    expect(colourOnly.cropEnabled, isFalse);
    expect(colourOnly.resizeEnabled, isFalse);
    final p = pipeline(colourOnly);
    expect(p.enabledPasses, [PassType.cropResize]);
    expect(p.videoPassCount, 1, reason: 'the two counts agree');
    expect(pipeline(const CropResizeParameters(enabled: true, padEnabled: true)).enabledPasses,
        [PassType.cropResize], reason: 'borders only');
    expect(pipeline(const CropResizeParameters(enabled: false, convertToBt709: Bt709Conversion.on))
        .enabledPasses, isEmpty, reason: 'a switched-off pass is not one');
  });

  test('subtitles on: a colour-only Crop & Resize is not subtitle-only', () {
    expect(pipeline(colourOnly, subtitles: true).isSubtitleOnly, isFalse);
    expect(pipeline(const CropResizeParameters(enabled: false), subtitles: true).isSubtitleOnly,
        isTrue, reason: 'control: nothing touches the picture');
    expect(pipeline(colourOnly).isSubtitleOnly, isFalse, reason: 'no subtitles');
  });

  test('the pass row names the conversion when it is all the pass does', () {
    expect(colourOnly.summary, 'BT.709');
    expect(const CropResizeParameters(enabled: true).summary, 'Custom',
        reason: 'Auto with no geometry does nothing on its own');
    expect(const CropResizeParameters(enabled: false, convertToBt709: Bt709Conversion.on).summary,
        'Off');
    expect(
        const CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 1920,
          targetHeight: 1080,
          convertToBt709: Bt709Conversion.on,
        ).summary,
        '1920x1080',
        reason: 'geometry still describes the pass');
  });
}
