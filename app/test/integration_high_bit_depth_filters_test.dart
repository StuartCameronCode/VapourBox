/// Every filter, on a >8-bit source — does it run, and does it do the same thing
/// it does at 8-bit?
///
/// Reported symptom: previews not working and "many filters failing" on 10-bit
/// ProRes 422 (`yuv422p10le`). Two distinct failure modes hide behind that, and
/// they need different tests:
///
///  1. **The pass aborts.** A plugin or havsfunc function rejects the depth and
///     vspipe dies, taking the whole preview or encode with it. `vivtc.VFM`
///     (8-bit only) and `havsfunc.LUTDeCrawl` (rejects >10-bit outright, so a
///     12-bit ProRes 4444 XQ source failed) are the two found so far.
///  2. **The pass runs and quietly does the wrong thing.** Every threshold and
///     offset in the UI is expressed in 8-bit levels (0-255). A filter that
///     doesn't rescale them to the clip's depth is silently wrong: `std.Levels`
///     works in the clip's own range, so `max_in=235` on a 10-bit clip mapped
///     everything above 235/1023 to white (measured mean error 93/255 — a blown
///     out picture, not an error message), and `adjust.Tweak`'s `bright` is in
///     raw sample units, making the brightness slider 4x weaker at 10-bit.
///
/// Mode 1 is caught by running each pass and checking it survives. Mode 2 needs
/// a *reference*: the same content and the same settings at 8-bit. Any filter
/// whose parameters are correctly depth-scaled produces the same picture either
/// way, to within rounding — so a divergence is the bug, and no per-filter
/// expected value has to be hand-computed.
///
/// Fixtures are generated at run time with the bundled ffmpeg from one
/// deterministic lavfi source, so the 8-bit and >8-bit clips are the same
/// content. The committed ProRes fixture covers the real-container path; see
/// `integration_high_bit_depth_test.dart`.
///
/// Heavy — runs in the nightly workflow, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/chroma_denoise_parameters.dart';
import 'package:vapourbox/models/chroma_fix_parameters.dart';
import 'package:vapourbox/models/color_correction_parameters.dart';
import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/deband_parameters.dart';
import 'package:vapourbox/models/deblock_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/descratch_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/spotless_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/high_bit_depth_filters';

const _width = 352;
const _height = 288;
const _fps = 25.0;
const _frames = 25;

/// The frame previews are taken at. Far enough in that every temporal filter has
/// real context on both sides.
const _previewFrame = 12;

// =============================================================================
// FIXTURES
// =============================================================================

/// A single degraded 8-bit master every fixture is derived from.
///
/// Two properties matter, and both are deliberate:
///
///  * **It has defects.** A clean synthetic clip gives a denoiser, a deblocker
///    or a dehaloer nothing to do, so they return the frame untouched and a
///    comparison between two depths of that frame proves nothing about how their
///    thresholds were scaled. So the master carries seeded grain (the denoisers'
///    input) and real MPEG-2 blocking and ringing from a deliberately starved
///    bitrate (the deblocker's and dehaloer's input).
///  * **It is ONE file.** Every depth is a lossless conversion *of this master*,
///    not an independent render, so the 8-bit and 10-bit fixtures are guaranteed
///    to hold the same picture (8 -> 10 bit is an exact shift) whatever the local
///    ffmpeg build does with the encode. Generating each depth from lavfi
///    separately would leave the comparison resting on encoder determinism.
Future<String> _master() async {
  final path = '$_outDir/master_degraded.mkv';
  if (File(path).existsSync()) return path;
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi',
      '-i', 'testsrc2=size=${_width}x$_height:rate=${_fps.toInt()}:duration=1',
      // Seeded so the grain is identical on every run and platform. Mark the
      // clip interlaced so the deinterlace passes have something to do and
      // _FieldBased is set the way a real interlaced source would set it.
      '-vf', 'noise=alls=18:allf=t+u:all_seed=20260805,setfield=tff',
      '-c:v', 'mpeg2video', '-b:v', '700k', '-flags', '+ilme+ildct',
      '-g', '15', '-bf', '2',
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(result.exitCode, 0,
      reason: 'master fixture generation failed: ${result.stderr}');
  return path;
}

/// The master at [pixFmt], losslessly (FFV1). Same picture at every depth.
Future<String> _fixture(String pixFmt) async {
  final path = '$_outDir/src_$pixFmt.mkv';
  if (File(path).existsSync()) return path;
  final master = await _master();
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-i', master,
      '-vf', 'setfield=tff',
      '-c:v', 'ffv1', '-pix_fmt', pixFmt,
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(result.exitCode, 0,
      reason: 'fixture generation failed for $pixFmt: ${result.stderr}');
  return path;
}

/// A 10-bit 4:2:2 clip whose luma is a smooth horizontal ramp and constant down
/// every column, written sample by sample.
///
/// It has to be built by hand: ffmpeg's synthetic sources are 8-bit internally,
/// so a "gradient" from lavfi converted to 10-bit holds only 256 levels and a
/// dither has nothing to preserve. This ramp spans 40 *10-bit* code values across
/// the width — 10 values at 8-bit — so reducing it to 8 bits either rounds into
/// flat vertical bands or diffuses the error, and the two are trivially
/// distinguishable: see the dither test below.
Future<String> _rampFixture() async {
  final path = '$_outDir/ramp_10bit.mkv';
  if (File(path).existsSync()) return path;

  final lumaRow = Uint8List(_width * 2);
  for (var x = 0; x < _width; x++) {
    // 64 is 10-bit black; 40 code values is 10 at 8-bit.
    final v = 64 + (x * 40) ~/ _width;
    lumaRow[x * 2] = v & 0xFF;
    lumaRow[x * 2 + 1] = (v >> 8) & 0xFF;
  }
  final chromaRow = Uint8List(_width ~/ 2 * 2);
  for (var x = 0; x < _width ~/ 2; x++) {
    chromaRow[x * 2] = 512 & 0xFF; // neutral chroma at 10-bit
    chromaRow[x * 2 + 1] = 512 >> 8;
  }

  final frame = BytesBuilder();
  for (var y = 0; y < _height; y++) {
    frame.add(lumaRow);
  }
  for (var plane = 0; plane < 2; plane++) {
    for (var y = 0; y < _height; y++) {
      frame.add(chromaRow);
    }
  }
  final oneFrame = frame.takeBytes();
  final raw = File('$_outDir/ramp_10bit.raw');
  final sink = raw.openWrite();
  for (var i = 0; i < 6; i++) {
    sink.add(oneFrame);
  }
  await sink.close();

  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'rawvideo', '-pix_fmt', 'yuv422p10le',
      '-s', '${_width}x$_height', '-r', '${_fps.toInt()}',
      '-i', raw.path,
      '-c:v', 'ffv1', '-pix_fmt', 'yuv422p10le',
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(result.exitCode, 0,
      reason: 'ramp fixture generation failed: ${result.stderr}');
  await raw.delete().catchError((_) => raw);
  return path;
}

VideoJob _job({
  required String fixture,
  required String pixFmt,
  required ProcessingPipeline pipeline,
  String outputName = 'unused',
}) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: fixture,
    outputPath: '$_outDir/$outputName.mkv',
    qtgmcParameters: pipeline.deinterlace,
    processingPipeline: pipeline,
    encodingSettings: const EncodingSettings(
      codec: VideoCodec.h264,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none,
    ),
    detectedFieldOrder: FieldOrder.topFieldFirst,
    totalFrames: _frames,
    inputFrameRate: _fps,
    inputWidth: _width,
    inputHeight: _height,
    inputPixelFormat: pixFmt,
  );
}

// =============================================================================
// THE PASS MATRIX
// =============================================================================

/// A single pass, enabled with values far enough from the defaults that the
/// filter visibly does something (an inert filter would pass a parity check
/// trivially).
class _Pass {
  const _Pass(this.name, this.pipeline,
      {this.tolerance = 2.0, this.changesPicture = true});

  final String name;
  final ProcessingPipeline pipeline;

  /// Whether this pass is expected to visibly change the frame.
  ///
  /// The parity check compares a pass against the same pass at another depth, so
  /// a pass that does nothing at all passes it trivially — which is exactly what
  /// happened when a case set `enabled` but not `resizeEnabled`, and again when
  /// the fixture was clean enough that the denoisers found nothing to remove. So
  /// each pass is also compared against the passthrough frame and must differ;
  /// only the passthrough case itself is exempt. If a new pass needs this set to
  /// false, that is a sign the fixture lacks the defect it looks for — prefer
  /// degrading the master over exempting the pass.
  final bool changesPicture;

  /// Allowed mean absolute difference (0-255) between the 8-bit and >8-bit
  /// results. The passthrough baseline is ~0.6 — pure 10->8-bit rounding in the
  /// preview's PNG conversion — so 2.0 leaves headroom for a filter's own
  /// rounding while still catching an unscaled threshold, which moved the
  /// picture by 93/255 (Levels) and 2.8/255 (Tweak brightness).
  final double tolerance;
}

const _deinterlaceOff = QTGMCParameters(enabled: false);

ProcessingPipeline _only({
  QTGMCParameters deinterlace = _deinterlaceOff,
  DeScratchParameters descratch = const DeScratchParameters(),
  SpotLessParameters spotless = const SpotLessParameters(),
  NoiseReductionParameters noiseReduction = const NoiseReductionParameters(),
  ChromaDenoiseParameters chromaDenoise = const ChromaDenoiseParameters(),
  DehaloParameters dehalo = const DehaloParameters(),
  DeblockParameters deblock = const DeblockParameters(),
  DebandParameters deband = const DebandParameters(),
  SharpenParameters sharpen = const SharpenParameters(),
  ColorCorrectionParameters colorCorrection = const ColorCorrectionParameters(),
  ChromaFixParameters chromaFixes = const ChromaFixParameters(),
  CropResizeParameters cropResize = const CropResizeParameters(),
}) {
  return ProcessingPipeline(
    deinterlace: deinterlace,
    descratch: descratch,
    spotless: spotless,
    noiseReduction: noiseReduction,
    chromaDenoise: chromaDenoise,
    dehalo: dehalo,
    deblock: deblock,
    deband: deband,
    sharpen: sharpen,
    colorCorrection: colorCorrection,
    chromaFixes: chromaFixes,
    cropResize: cropResize,
  );
}

List<_Pass> _passes() => [
      // The reference: no filters at all. Establishes the rounding floor every
      // other tolerance is judged against, and proves the >8-bit pipe format
      // round-trips before any filter is blamed for breaking it.
      _Pass('passthrough', _only(), changesPicture: false),

      _Pass(
        'deinterlace_qtgmc',
        _only(
          deinterlace: const QTGMCParameters(
            enabled: true,
            preset: QTGMCPreset.fast,
            tff: true,
          ),
        ),
        // QTGMC interpolates: a half-level difference in the source shifts an
        // edge decision, so local differences are expected where the mean is not.
        tolerance: 3.0,
      ),
      _Pass(
        'deinterlace_qtgmc_high_precision',
        _only(
          deinterlace: const QTGMCParameters(
            enabled: true,
            preset: QTGMCPreset.fast,
            tff: true,
            highPrecision: true,
          ),
        ),
        tolerance: 3.0,
      ),
      _Pass(
        'deinterlace_qtgmc_chroma_upsample',
        _only(
          deinterlace: const QTGMCParameters(
            enabled: true,
            preset: QTGMCPreset.fast,
            tff: true,
            chromaUpsampleFix: true,
          ),
        ),
        tolerance: 3.0,
      ),
      // vivtc.VFM is 8-bit only and runs on a downconverted metrics clip, taking
      // its pixels from the full-depth clip via clip2 (issue: 10-bit ProRes IVTC).
      _Pass(
        'deinterlace_ivtc',
        _only(
          deinterlace: const QTGMCParameters(
            enabled: true,
            method: DeinterlaceMethod.ivtc,
            tff: true,
          ),
        ),
        tolerance: 3.0,
      ),

      // DeScratch is 8-bit only: the pass converts down and back, so the >8-bit
      // result is expected to match the 8-bit one closely.
      _Pass('descratch', _only(descratch: const DeScratchParameters(enabled: true))),

      _Pass('spotless', _only(spotless: const SpotLessParameters(enabled: true))),

      _Pass(
        'noise_smdegrain',
        _only(
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.smDegrain,
            preset: NoiseReductionPreset.moderate,
          ),
        ),
      ),
      _Pass(
        'noise_mctemporaldenoise',
        _only(
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.mcTemporalDenoise,
            preset: NoiseReductionPreset.moderate,
          ),
        ),
      ),
      _Pass(
        'noise_mcdegrainsharp',
        _only(
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.mcDegrainSharp,
            preset: NoiseReductionPreset.moderate,
          ),
        ),
      ),

      // CCD rejects a scale below 1.0 and is the newest plugin in the bundle
      // (zsmooth), so this doubles as a check that it is actually installed.
      _Pass(
        'chroma_denoise_ccd',
        _only(
          chromaDenoise: const ChromaDenoiseParameters(enabled: true, threshold: 8.0),
        ),
      ),

      for (final method in DehaloMethod.values)
        _Pass(
          'dehalo_${method.value}',
          _only(dehalo: DehaloParameters(enabled: true, method: method)),
        ),

      for (final method in DeblockMethod.values)
        _Pass(
          'deblock_${method.value}',
          _only(deblock: DeblockParameters(enabled: true, method: method)),
        ),

      // f3kdb's thresholds are 8-bit-scaled by the plugin itself; dithering makes
      // its output differ slightly run to run in the low bits.
      _Pass('deband', _only(deband: const DebandParameters(enabled: true))),

      for (final method in SharpenMethod.values)
        _Pass(
          'sharpen_${method.value}',
          _only(sharpen: SharpenParameters(enabled: true, method: method)),
        ),

      _Pass(
        'chroma_shift',
        _only(
          chromaFixes: const ChromaFixParameters(
            enabled: true,
            applyChromaShift: true,
            chromaShiftH: 2.0,
            chromaShiftV: -1.0,
          ),
        ),
      ),
      _Pass(
        'chroma_bleeding_fix',
        _only(
          chromaFixes: const ChromaFixParameters(
            enabled: true,
            applyChromaBleedingFix: true,
          ),
        ),
      ),
      // LUTDeCrawl scales its own thresholds but refuses >10-bit input; the pass
      // runs it at 10-bit and restores the source format.
      _Pass(
        'chroma_decrawl',
        _only(
          chromaFixes: const ChromaFixParameters(enabled: true, applyDeCrawl: true),
        ),
      ),
      _Pass(
        'chroma_vinverse',
        _only(
          chromaFixes: const ChromaFixParameters(enabled: true, applyVinverse: true),
        ),
      ),

      // adjust.Tweak: `bright` is added in raw sample units, so it must be scaled
      // to the working depth or the slider is 4x weaker at 10-bit.
      _Pass(
        'color_tweak',
        _only(
          colorCorrection: const ColorCorrectionParameters(
            enabled: true,
            brightness: 10.0,
            contrast: 1.2,
            saturation: 1.3,
            hue: 8.0,
          ),
        ),
      ),
      // std.Levels works in the clip's own sample range: the single worst
      // offender before the fix (mean error 93/255 at 10-bit).
      _Pass(
        'color_levels',
        _only(
          colorCorrection: const ColorCorrectionParameters(
            enabled: true,
            applyLevels: true,
            inputLow: 16,
            inputHigh: 235,
            outputLow: 0,
            outputHigh: 255,
          ),
        ),
      ),
      _Pass(
        'color_levels_gamma',
        _only(
          colorCorrection: const ColorCorrectionParameters(
            enabled: true,
            applyLevels: true,
            inputLow: 10,
            inputHigh: 240,
            gamma: 0.8,
          ),
        ),
      ),
      _Pass(
        'white_balance',
        _only(
          colorCorrection: const ColorCorrectionParameters(
            enabled: true,
            temperature: 40.0,
            tint: -20.0,
          ),
        ),
      ),

      // `enabled` turns the PASS on; `resizeEnabled`/`cropEnabled` turn the two
      // halves of it on. Setting only the former leaves the pass inert — which is
      // why the parity check below insists every case actually changes the frame.
      _Pass(
        'resize',
        _only(
          cropResize: const CropResizeParameters(
            enabled: true,
            resizeEnabled: true,
            targetWidth: 640,
          ),
        ),
      ),
      _Pass(
        'crop',
        _only(
          cropResize: const CropResizeParameters(
            enabled: true,
            cropEnabled: true,
            cropLeft: 8,
            cropRight: 8,
            cropTop: 4,
            cropBottom: 4,
          ),
        ),
      ),
      _Pass(
        'upscale_2x_nnedi3',
        _only(
          cropResize: const CropResizeParameters(
            enabled: true,
            useIntegerUpscale: true,
            upscaleFactor: 2,
          ),
        ),
        tolerance: 3.0,
      ),
    ];

/// A pipeline with several passes stacked, as a real job would have. Filters
/// interact through the clip format — one pass converting depth and not
/// restoring it breaks the next — which a one-pass-at-a-time matrix can't see.
ProcessingPipeline _stackedPipeline() => _only(
      deinterlace: const QTGMCParameters(
        enabled: true,
        preset: QTGMCPreset.fast,
        tff: true,
      ),
      chromaDenoise: const ChromaDenoiseParameters(enabled: true, threshold: 6.0),
      dehalo: const DehaloParameters(enabled: true, method: DehaloMethod.fineDehalo),
      sharpen: const SharpenParameters(enabled: true, method: SharpenMethod.cas),
      chromaFixes: const ChromaFixParameters(
        enabled: true,
        applyDeCrawl: true,
        applyChromaShift: true,
        chromaShiftH: 1.0,
      ),
      colorCorrection: const ColorCorrectionParameters(
        enabled: true,
        brightness: 6.0,
        applyLevels: true,
        inputLow: 16,
        inputHigh: 235,
      ),
      cropResize: const CropResizeParameters(
        enabled: true,
        resizeEnabled: true,
        targetWidth: 640,
      ),
    );

/// The unfiltered 10-bit frame, rendered once and reused as the reference every
/// pass is checked against for "did this actually do anything".
Uint8List? _passthroughCache;

Future<Uint8List> _passthroughRgb10() async {
  final cached = _passthroughCache;
  if (cached != null) return cached;
  final fixture = await _fixture('yuv422p10le');
  final result = await WorkerHarness.runPreview(
    _job(fixture: fixture, pixFmt: 'yuv422p10le', pipeline: _only()).toJson(),
    frame: _previewFrame,
    label: 'passthrough_reference',
  );
  expect(result.success, isTrue,
      reason: 'the passthrough reference frame must render: $result');
  return _passthroughCache =
      await WorkerHarness.imageToRgb24(result.png!, label: 'ref10');
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  // ===========================================================================
  // 1. Does every pass survive a >8-bit source at all?
  // ===========================================================================
  group('preview runs on a 10-bit 4:2:2 source', () {
    for (final pass in _passes()) {
      test(pass.name, () async {
        final fixture = await _fixture('yuv422p10le');
        final result = await WorkerHarness.runPreview(
          _job(
                  fixture: fixture,
                  pixFmt: 'yuv422p10le',
                  pipeline: pass.pipeline)
              .toJson(),
          frame: _previewFrame,
          label: '${pass.name}_10bit',
        );
        expect(result.success, isTrue,
            reason: '${pass.name} failed on yuv422p10le: $result');
        print('  ${pass.name}: ${result.png!.length} byte PNG');
      }, timeout: const Timeout(Duration(minutes: 4)));
    }
  });

  // ===========================================================================
  // 2. Do the deeper formats work too? 12-bit is ProRes 4444 XQ; 16-bit is what
  //    the high-precision paths convert to internally, so a pass that rejects it
  //    is a latent failure even for a 10-bit source.
  // ===========================================================================
  group('preview runs on deeper formats', () {
    for (final pixFmt in ['yuv444p12le', 'yuv422p16le']) {
      for (final pass in _passes()) {
        test('${pass.name} on $pixFmt', () async {
          final fixture = await _fixture(pixFmt);
          final result = await WorkerHarness.runPreview(
            _job(fixture: fixture, pixFmt: pixFmt, pipeline: pass.pipeline)
                .toJson(),
            frame: _previewFrame,
            label: '${pass.name}_$pixFmt',
          );
          expect(result.success, isTrue,
              reason: '${pass.name} failed on $pixFmt: $result');
        }, timeout: const Timeout(Duration(minutes: 4)));
      }
    }
  });

  // ===========================================================================
  // 3. Does each pass do the SAME thing at 10-bit that it does at 8-bit?
  //    This is the one that catches a filter silently misbehaving rather than
  //    failing — the Levels and Tweak-brightness class of bug.
  // ===========================================================================
  group('8-bit vs 10-bit result parity', () {
    for (final pass in _passes()) {
      test(pass.name, () async {
        final src8 = await _fixture('yuv422p');
        final src10 = await _fixture('yuv422p10le');

        final eight = await WorkerHarness.runPreview(
          _job(fixture: src8, pixFmt: 'yuv422p', pipeline: pass.pipeline).toJson(),
          frame: _previewFrame,
          label: '${pass.name}_8',
        );
        final ten = await WorkerHarness.runPreview(
          _job(fixture: src10, pixFmt: 'yuv422p10le', pipeline: pass.pipeline)
              .toJson(),
          frame: _previewFrame,
          label: '${pass.name}_10',
        );
        expect(eight.success, isTrue, reason: '8-bit run failed: $eight');
        expect(ten.success, isTrue, reason: '10-bit run failed: $ten');

        final rgb8 = await WorkerHarness.imageToRgb24(eight.png!, label: 'p8');
        final rgb10 = await WorkerHarness.imageToRgb24(ten.png!, label: 'p10');

        // Same geometry: a size difference here means the depth changed the
        // frame size, which no filter should do.
        expect(rgb10.length, rgb8.length,
            reason: '${pass.name}: 8-bit and 10-bit frames differ in size');

        // A pass that changes nothing would sail through the comparison below
        // while testing nothing, so prove it is doing work first.
        if (pass.changesPicture) {
          final reference = await _passthroughRgb10();
          final changed = rgb10.length != reference.length ||
              WorkerHarness.meanAbsDiff(rgb10, reference) > 0.05;
          expect(changed, isTrue,
              reason: '${pass.name} produced the same frame as a passthrough, so '
                  'the parity comparison proves nothing. The pass is probably not '
                  'actually switched on (several take a second flag, e.g. '
                  'resizeEnabled/cropEnabled beside enabled), or its parameters '
                  'are still at their defaults.');
        }

        final diff = WorkerHarness.meanAbsDiff(rgb8, rgb10);
        print('  ${pass.name}: mean abs diff ${diff.toStringAsFixed(3)} '
            '(tolerance ${pass.tolerance})');
        expect(diff, lessThan(pass.tolerance),
            reason: '${pass.name} produces a different picture at 10-bit than at '
                '8-bit (mean abs diff ${diff.toStringAsFixed(2)}/255). A parameter '
                'expressed in 8-bit levels is most likely reaching the filter '
                'unscaled — see the Levels and Tweak blocks in the templates.');
      }, timeout: const Timeout(Duration(minutes: 6)));
    }
  });

  // ===========================================================================
  // 4. The stacked pipeline, both paths. Preview and encode are separate scripts
  //    and separate ffmpeg invocations, so each needs its own assertion.
  // ===========================================================================
  group('stacked pipeline on a 10-bit source', () {
    test('preview renders', () async {
      final fixture = await _fixture('yuv422p10le');
      final result = await WorkerHarness.runPreview(
        _job(
          fixture: fixture,
          pixFmt: 'yuv422p10le',
          pipeline: _stackedPipeline(),
        ).toJson(),
        frame: _previewFrame,
        label: 'stacked_preview',
      );
      expect(result.success, isTrue, reason: 'stacked preview failed: $result');
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('full encode produces a valid video', () async {
      final fixture = await _fixture('yuv422p10le');
      final job = _job(
        fixture: fixture,
        pixFmt: 'yuv422p10le',
        pipeline: _stackedPipeline(),
        outputName: 'stacked_10bit',
      );
      final result = await WorkerHarness.runJob(job.toJson(), label: 'stacked_10bit');
      expect(result.success, isTrue, reason: result.error);

      final out = await WorkerHarness.firstStream(result.outputPath!,
          selector: 'v:0', entries: ['codec_name', 'width', 'height']);
      expect(out, isNotNull, reason: 'output should contain a video stream');
      // The resize pass asked for 640 wide; if the pipeline had silently fallen
      // back to a passthrough on a >8-bit source this would still be 352.
      expect(out!['width'], 640);
      print('  stacked encode: ${out['codec_name']} '
          '${out['width']}x${out['height']}');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  // ===========================================================================
  // 5. The output colour format selector, on a >8-bit source.
  //
  // Settings → Colour format defaults to matching the input, so a 10-bit 4:2:2
  // source encodes to 10-bit 4:2:2 — which for H.264 means the High 4:2:2
  // profile, and for HEVC the Rext profile: correct, but not what a consumer
  // player, browser or phone will open. Choosing 4:2:0 is the remedy, so what
  // matters is that it really lands on 8-bit 4:2:0 rather than 10-bit 4:2:0
  // (which is High 10, still refused by a lot of players). The existing
  // integration_chroma_subsampling_test only ever runs on an 8-bit source, so
  // none of this was covered.
  // ===========================================================================
  group('output colour format selector on a 10-bit source', () {
    Future<Map<String, dynamic>> encodeWith(
        ChromaSubsampling subsampling, String label) async {
      final fixture = await _fixture('yuv422p10le');
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: fixture,
        outputPath: '$_outDir/chroma_$label.mkv',
        processingPipeline: _only(),
        encodingSettings: EncodingSettings(
          codec: VideoCodec.h264,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.none,
          chromaSubsampling: subsampling,
        ),
        detectedFieldOrder: FieldOrder.topFieldFirst,
        totalFrames: _frames,
        inputFrameRate: _fps,
        inputWidth: _width,
        inputHeight: _height,
        inputPixelFormat: 'yuv422p10le',
      );
      final result = await WorkerHarness.runJob(job.toJson(), label: label);
      expect(result.success, isTrue, reason: result.error);
      final out = await WorkerHarness.firstStream(result.outputPath!,
          selector: 'v:0', entries: ['pix_fmt', 'profile']);
      expect(out, isNotNull);
      print('  $label -> ${out!['pix_fmt']} (${out['profile']})');
      return out;
    }

    test('4:2:0 gives an 8-bit 4:2:0 file', () async {
      final out = await encodeWith(ChromaSubsampling.yuv420, 'yuv420');
      // 8-bit specifically: a 10-bit 4:2:0 output would be High 10 and would
      // still fail to open in the players this setting exists to satisfy.
      expect(out['pix_fmt'], 'yuv420p');
      expect(out['profile'], 'High');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('4:2:2 gives an 8-bit 4:2:2 file', () async {
      final out = await encodeWith(ChromaSubsampling.yuv422, 'yuv422');
      expect(out['pix_fmt'], 'yuv422p');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('4:2:2 10-bit keeps the source precision', () async {
      // The option that normalizes chroma without throwing away the 10 bits —
      // the reason it exists is that the other two conversions are 8-bit only.
      final out = await encodeWith(ChromaSubsampling.yuv422p10, 'yuv422p10');
      expect(out['pix_fmt'], 'yuv422p10le');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('matching the input keeps the source format', () async {
      // Deliberate: "match input" means no conversion, and for a 10-bit source
      // that is a 10-bit 4:2:2 output. Pinned so a future change to the default
      // is a decision someone makes on purpose rather than a silent one.
      final out = await encodeWith(ChromaSubsampling.original, 'original');
      expect(out['pix_fmt'], 'yuv422p10le');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('reducing 10-bit to 8-bit dithers instead of banding', () async {
      // The conversion is the one place a deep source is reduced to 8 bits, and
      // resize defaults to plain rounding. On a ramp that is constant down every
      // column, rounding leaves every column single-valued (flat bands); error
      // diffusion spreads the residual vertically, so columns vary.
      //
      // Encoded losslessly: x264 at the default CRF would smooth the dither away
      // and the measurement would say nothing about the pipeline.
      final fixture = await _rampFixture();
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: fixture,
        outputPath: '$_outDir/ramp_to_8bit.mkv',
        processingPipeline: _only(),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.none,
          chromaSubsampling: ChromaSubsampling.yuv420,
        ),
        detectedFieldOrder: FieldOrder.topFieldFirst,
        totalFrames: 6,
        inputFrameRate: _fps,
        inputWidth: _width,
        inputHeight: _height,
        inputPixelFormat: 'yuv422p10le',
      );
      final result = await WorkerHarness.runJob(job.toJson(), label: 'ramp_8bit');
      expect(result.success, isTrue, reason: result.error);

      final out = await WorkerHarness.firstStream(result.outputPath!,
          selector: 'v:0', entries: ['pix_fmt']);
      expect(out!['pix_fmt'], 'yuv420p');

      // Pull one frame's luma plane at its own depth — no rescaling to muddy it.
      final gray = await Process.run(
        WorkerHarness.ffmpegPath,
        [
          '-v', 'error', '-y', '-i', result.outputPath!,
          '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'gray',
          '$_outDir/ramp_out.gray',
        ],
        environment: WorkerHarness.ffmpegEnv,
      );
      expect(gray.exitCode, 0, reason: '${gray.stderr}');
      final luma = await File('$_outDir/ramp_out.gray').readAsBytes();
      expect(luma.length, _width * _height);

      var varyingColumns = 0;
      for (var x = 0; x < _width; x++) {
        final first = luma[x];
        for (var y = 1; y < _height; y++) {
          if (luma[y * _width + x] != first) {
            varyingColumns++;
            break;
          }
        }
      }
      final fraction = varyingColumns / _width;
      print('  columns varying down the frame: '
          '$varyingColumns/$_width (${(fraction * 100).toStringAsFixed(1)}%)');

      // Plain rounding gives exactly 0%: the source is constant down every
      // column, so without dithering the output is too.
      expect(fraction, greaterThan(0.25),
          reason: 'the 10->8-bit reduction looks undithered — a ramp that is '
              'flat down every column came out flat, i.e. banded. Check '
              'dither_type on the output format conversion in both templates.');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  // ===========================================================================
  // 6. The preview PNG has to be displayable by the app.
  // ===========================================================================
  group('preview PNG is usable by the UI', () {
    test('a >8-bit source yields a PNG Flutter can decode', () async {
      // vspipe emits 10-bit Y4M, so the preview ffmpeg writes a 16-bit-per-
      // channel PNG (rgb48be) rather than the rgb24 an 8-bit source produces.
      // PreviewPanel hands those bytes straight to Image.memory, so if the
      // engine could not decode rgb48be the preview would silently show nothing
      // for exactly the sources reported as broken.
      final fixture = await _fixture('yuv422p10le');
      final result = await WorkerHarness.runPreview(
        _job(fixture: fixture, pixFmt: 'yuv422p10le', pipeline: _only()).toJson(),
        frame: _previewFrame,
        label: 'png_decode',
      );
      expect(result.success, isTrue, reason: 'preview failed: $result');

      final png = Uint8List.fromList(result.png!);
      expect(png.sublist(1, 4), equals('PNG'.codeUnits),
          reason: 'preview output should be a PNG');

      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, _width);
      expect(frame.image.height, _height);
      print('  decoded ${frame.image.width}x${frame.image.height} '
          'from ${png.length} bytes');
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}
