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
import 'package:vapourbox/models/anti_alias_parameters.dart';
import 'package:vapourbox/models/deblock_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/deflicker_parameters.dart';
import 'package:vapourbox/models/descale_parameters.dart';
import 'package:vapourbox/models/descratch_parameters.dart';
import 'package:vapourbox/models/edge_repair_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/ghost_removal_parameters.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/spotless_parameters.dart';
import 'package:vapourbox/models/stabilize_parameters.dart';
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

/// The fixture at [pixFmt] with three dark vertical scratches drawn into the
/// master's picture before the format conversion, so every format shares
/// them (and the 4:2:0 and 4:2:2 copies share their luma). The plain fixture
/// has nothing DeScratch removes.
Future<String> _scratchedFixture(String pixFmt) async {
  final path = '$_outDir/scratched_$pixFmt.mkv';
  if (File(path).existsSync()) return path;
  final master = await _master();
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-i', master,
      '-vf', 'drawbox=x=71:y=0:w=2:h=ih:color=black@0.4:t=fill,'
          'drawbox=x=170:y=20:w=1:h=240:color=black@0.5:t=fill,'
          'drawbox=x=277:y=0:w=2:h=ih:color=black@0.35:t=fill,'
          'setfield=tff',
      '-c:v', 'ffv1', '-pix_fmt', pixFmt,
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(result.exitCode, 0,
      reason: 'scratched fixture generation failed for $pixFmt: '
          '${result.stderr}');
  return path;
}

/// The fixture at [pixFmt] with known camera shake: each frame of the master
/// moved 2 px left or right (alternating) and 2 px up or down (in pairs), the
/// edges smeared back to full size. For Stabilize (task #32).
///
/// On the plain master, which holds no global motion, Depan's estimate is a
/// near-tie between ±0.011 px whose winner changes from run to run with
/// VapourSynth's threading, and on some runners the estimate came out exactly
/// zero, so the pass returned the source and the "did it do anything" check
/// failed intermittently on every platform but macOS arm64. With every frame
/// off the window's mean in both axes the estimate is unambiguous, and the
/// output was identical over 12 multithreaded runs (and at 8-bit). This is
/// also the fixture that showed Depan misreading 8-bit samples (8 vs 10-bit
/// 9.66 levels apart with havsfunc's Stab, 0.343 with `stabilize.weave`;
/// docs/reports/2026-11-depan-8-bit).
Future<String> _shakenFixture(String pixFmt) async {
  final path = '$_outDir/shaken_$pixFmt.mkv';
  if (File(path).existsSync()) return path;
  final master = await _master();
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-i', master,
      '-vf', "crop=w=${_width - 12}:h=${_height - 12}"
          ":x='6+2*(2*mod(n\\,2)-1)':y='6+2*(2*mod(floor(n/2)\\,2)-1)',"
          'pad=$_width:$_height:6:6,'
          'fillborders=left=6:right=6:top=6:bottom=6:mode=smear,'
          'setfield=tff',
      '-c:v', 'ffv1', '-pix_fmt', pixFmt,
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(result.exitCode, 0,
      reason: 'shaken fixture generation failed for $pixFmt: ${result.stderr}');
  return path;
}

/// The fixture [pass] runs on, at [pixFmt].
Future<String> _fixtureFor(_Pass pass, String pixFmt) =>
    pass.shaken ? _shakenFixture(pixFmt) : _fixture(pixFmt);

/// Every frame of [path] decoded as raw [pixFmt] (no conversion when it is the
/// file's own format), so planes can be compared byte for byte.
Future<Uint8List> _rawFrames(String path, String pixFmt) async {
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-hide_banner', '-loglevel', 'error', '-i', path,
     '-f', 'rawvideo', '-pix_fmt', pixFmt, '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  expect(result.exitCode, 0, reason: 'raw decode failed: ${result.stderr}');
  return Uint8List.fromList(result.stdout as List<int>);
}

/// The [plane] (0 = Y, 1 = U, 2 = V) of every 8-bit frame in [raw], laid out
/// with chroma planes of [chromaW] x [chromaH], concatenated.
Uint8List _planes(Uint8List raw, int plane, int chromaW, int chromaH,
    {int width = _width, int height = _height}) {
  final luma = width * height;
  final chroma = chromaW * chromaH;
  final frame = luma + 2 * chroma;
  final start = plane == 0 ? 0 : luma + (plane - 1) * chroma;
  final size = plane == 0 ? luma : chroma;
  final out = BytesBuilder();
  for (var f = 0; f + frame <= raw.length; f += frame) {
    out.add(raw.sublist(f + start, f + start + size));
  }
  return out.takeBytes();
}

/// The [plane] of every frame in [raw], a little-endian 16-bit-container
/// format (yuv4xxp10le and deeper), as samples.
Uint16List _planes16(Uint8List raw, int plane, int chromaW, int chromaH,
    {int width = _width, int height = _height}) {
  final bytes = _planes(raw, plane, chromaW * 2, chromaH,
      width: width * 2, height: height);
  return bytes.buffer.asUint16List(bytes.offsetInBytes, bytes.length ~/ 2);
}

/// [_scratchedFixture] at 10 bits with genuine sub-8-bit content: each sample
/// is four times the 8-bit fixture's plus a low-bit pattern of 0 or 1, which
/// rounds back down to the 8-bit fixture exactly. A 10-bit file converted from
/// an 8-bit master has zero low bits, and DeScratch was already bit-exact on
/// that while quantising every real 10-bit sample (task #34).
Future<String> _deepScratchedFixture(String pixFmt8) async {
  final pixFmt = '${pixFmt8}10le';
  final path = '$_outDir/scratched_deep_$pixFmt.mkv';
  if (File(path).existsSync()) return path;
  final result = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-i', await _scratchedFixture(pixFmt8),
      '-vf', "format=$pixFmt,"
          "geq=lum='lum(X,Y)+mod(X+Y,2)':cb='cb(X,Y)+mod(X,2)'"
          ":cr='cr(X,Y)+mod(Y,2)',setfield=tff",
      '-c:v', 'ffv1', '-pix_fmt', pixFmt,
      path,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(result.exitCode, 0,
      reason: 'deep fixture generation failed for $pixFmt: ${result.stderr}');
  return path;
}

int _differing(Uint8List a, Uint8List b) {
  expect(a.length, b.length, reason: 'plane sizes differ');
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) n++;
  }
  return n;
}

VideoJob _losslessJob({
  required String fixture,
  required String pixFmt,
  required ProcessingPipeline pipeline,
  required String outputName,
  int width = _width,
  int height = _height,
  int frames = _frames,
  double fps = _fps,
}) {
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: fixture,
    outputPath: '$_outDir/$outputName.mkv',
    qtgmcParameters: pipeline.deinterlace,
    processingPipeline: pipeline,
    encodingSettings: const EncodingSettings(
      codec: VideoCodec.ffv1,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none,
      chromaSubsampling: ChromaSubsampling.original,
    ),
    detectedFieldOrder: FieldOrder.topFieldFirst,
    totalFrames: frames,
    inputFrameRate: fps,
    inputWidth: width,
    inputHeight: height,
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
      {this.tolerance = 2.0,
      this.changesPicture = true,
      this.needsKnlmDevice = false,
      this.shaken = false});

  final String name;
  final ProcessingPipeline pipeline;

  /// Run on [_shakenFixture] rather than the plain master: a stabiliser has
  /// nothing to do on a picture with no global motion.
  final bool shaken;

  /// Whether the pass needs a working KNLMeansCL OpenCL device. Without one the
  /// worker refuses the job by design, so the pass is skipped (with a printed
  /// line) rather than failed — which means the hosted runners, which have no
  /// OpenCL, never run it. Run this file on a machine with a GPU after touching
  /// KNLMeansCL.
  final bool needsKnlmDevice;

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
  DeflickerParameters deflicker = const DeflickerParameters(),
  EdgeRepairParameters edgeRepair = const EdgeRepairParameters(),
  GhostRemovalParameters ghostRemoval = const GhostRemovalParameters(),
  FrameRateParameters frameRate = const FrameRateParameters(),
  DescaleParameters descale = const DescaleParameters(),
  AntiAliasParameters antiAlias = const AntiAliasParameters(),
  StabilizeParameters stabilize = const StabilizeParameters(),
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
    deflicker: deflicker,
    edgeRepair: edgeRepair,
    ghostRemoval: ghostRemoval,
    frameRate: frameRate,
    descale: descale,
    antiAlias: antiAlias,
    stabilize: stabilize,
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

      // DeScratch is 8-bit only: the pass analyses an 8-bit copy and applies
      // only its change at full depth (task #34), so the >8-bit result is
      // expected to match the 8-bit one closely.
      _Pass('descratch', _only(descratch: const DeScratchParameters(enabled: true))),

      _Pass('spotless', _only(spotless: const SpotLessParameters(enabled: true))),

      // Stabilize (weave + pitch correction, issue #150): Depan and the pitch
      // search must see the same picture at any depth, and the black edge fill
      // is computed from the format rather than written as 8-bit constants.
      _Pass(
        'stabilize',
        _only(
          stabilize: const StabilizeParameters(enabled: true, pitchMode: PitchMode.auto),
        ),
        shaken: true,
      ),
      _Pass(
        'stabilize_black_edges',
        _only(
          stabilize: const StabilizeParameters(
              enabled: true, pitchMode: PitchMode.auto, pitchEdgeFill: EdgeFill.black),
        ),
        shaken: true,
      ),

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

      // The two vendored denoisers. Both live in worker/templates as Python
      // modules rather than coming from havsfunc, so they carry their own depth
      // handling and nothing upstream is scaling their thresholds for them.
      _Pass(
        'noise_mclean',
        _only(
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.mClean,
            preset: NoiseReductionPreset.moderate,
          ),
        ),
      ),
      _Pass(
        'noise_temporaldegrain2',
        _only(
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.temporalDegrain2,
            preset: NoiseReductionPreset.moderate,
          ),
        ),
      ),

      // Descale works in float on luma; a correct block gives the same picture
      // at 10-bit as at 8-bit (the float conversion normalises every depth to
      // 0-1). Protection is off: this fixture was never upscaled, so with it on
      // the mask rightly keeps almost every pixel and the pass changes nothing.
      _Pass(
        'descale',
        _only(descale: const DescaleParameters(
            enabled: true, nativeHeight: 216, protectDetail: false)),
      ),

      // BM3D works in 16-bit and its sigma is in 8-bit units at every depth,
      // so a correct block gives the same picture at 10-bit as at 8-bit.
      _Pass(
        'noise_bm3d',
        _only(
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.bm3d,
            bm3dChromaSigma: 2.0,
          ),
        ),
      ),

      // KNLMeansCL (issue #144). Windows shipped the 2018 v1.1.1 release, which
      // refused every 9-15-bit clip except packed YUV444P10, so this pass failed
      // outright on any 10-bit 4:2:0/4:2:2 source. h is raised from the default
      // 1.2 so the pass visibly changes this fixture: with the default, weights
      // fall under KNLMeansCL's epsilon floor on grain this heavy and the
      // output is (correctly) almost the input.
      _Pass(
        'noise_knlmeans',
        _only(
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.knlMeans,
            knlmH: 3.0,
          ),
        ),
        needsKnlmDevice: true,
      ),

      // NLMeans on the CPU (vszip, deps 1.16.0): KNLMeansCL's arguments, every
      // depth natively, h depth-independent. Same h as the KNLMeans case above
      // so the two read alike; unlike it, this one runs on every runner.
      _Pass(
        'noise_nlmeans_cpu',
        _only(
          noiseReduction: const NoiseReductionParameters(
            enabled: true,
            method: NoiseReductionMethod.nlMeans,
            knlmH: 3.0,
          ),
        ),
      ),

      // SangNom AA: `aa` is in 8-bit units and the plugin scales it itself
      // (measured: an 8-bit and a 10-bit run agree to 0.05 levels); the 2x
      // Spline36 round trip adds the rest.
      _Pass(
        'anti_alias_sangnom',
        _only(
          antiAlias: const AntiAliasParameters(
            enabled: true,
            method: AntiAliasMethod.sangnom,
          ),
        ),
      ),

      // santiag (havsfunc) goes back to the clip's depth through haf.Resize,
      // i.e. fmtc.bitdepth, which has no 14-bit output: it failed on every
      // 14-bit source until those were decoded as 16 (task #23).
      _Pass(
        'anti_alias_santiag',
        _only(
          antiAlias: const AntiAliasParameters(
            enabled: true,
            method: AntiAliasMethod.santiag,
          ),
        ),
      ),

      // The IVTC fade fix works in float, so a correct block is depth-blind.
      // This fixture holds no fade, and on a frame that is not fading the fix
      // changes ~0.1 levels by design — so it cannot be required to change
      // the picture; the parity check is what this case is for (the fix's
      // effect is integration_classical_filters_test's).
      _Pass(
        'ivtc_fix_fades',
        _only(
          deinterlace: const QTGMCParameters(
            enabled: true,
            method: DeinterlaceMethod.ivtc,
            tff: true,
            ivtcFixFades: true,
          ),
        ),
        changesPicture: false,
      ),

      // Deflicker measures frame brightness against a windowed average, so its
      // correction is a ratio and should be depth-independent by construction.
      _Pass(
        'deflicker',
        _only(
          deflicker: const DeflickerParameters(
            enabled: true,
            strength: 1.0,
            window: 5,
          ),
        ),
      ),

      // LGhost rejects mode 0 and intensity 0 — with either, the pass is inert
      // and would pass the parity check trivially while failing changesPicture.
      _Pass(
        'ghost_removal',
        _only(
          ghostRemoval: const GhostRemovalParameters(
            enabled: true,
            ghosts: [GhostSpec(mode: 2, shift: 6, intensity: 60)],
          ),
        ),
      ),

      // Widths are always even (see EdgeRepairParameters.even) — FillBorders v2
      // leaves subsampled chroma unrepaired at odd ones.
      _Pass(
        'edge_repair',
        _only(
          edgeRepair: const EdgeRepairParameters(
            enabled: true,
            left: 4,
            right: 4,
            top: 2,
            bottom: 2,
          ),
        ),
      ),

      // The fixture is 25 fps, so 23.976 actually retimes. The source rate has
      // to be supplied — the pipeline can't see the job, and without it the
      // FrameMap ratio is unknown and the pass does nothing.
      _Pass(
        'frame_rate',
        _only(
          frameRate: const FrameRateParameters(
            enabled: true,
            target: FrameRateTarget.film23976,
            sourceFpsNum: 25,
            sourceFpsDen: 1,
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
      // FixChromaBleedingMod diverges more than the rest between depths, and it
      // is the filter itself, not an unscaled parameter: it derives neutral/peak
      // from the clip and puts every constant through havsfunc's scale(). What
      // it also does is call its internal Levels() with input_low == input_high,
      // which makes `divisor` 1 in NATIVE CODE UNITS — so the mask transition
      // spans exactly one code value at any depth, i.e. a quarter of the
      // relative width at 10-bit that it has at 8-bit. That mask is then
      // Inflate()d and drives a MaskedMerge, so a 1-LSB difference flips whole
      // regions. Both results are "right"; they binarize in slightly different
      // places.
      //
      // Hence the platform spread — everything it touches is core std.* plus
      // adjust.Tweak (std.Expr/std.Lut), and Expr's SIMD path rounds differently
      // in the from-source macOS x64 core than in the prebuilt Windows one.
      // Measured: Windows 0.77, Linux/macOS arm64 ~0.8, macOS x64 2.64.
      //
      // 4.0 clears that with headroom while staying far below what this test
      // exists to catch: an unscaled 8-bit parameter moved Levels by 93/255.
      _Pass(
        'chroma_bleeding_fix',
        _only(
          chromaFixes: const ChromaFixParameters(
            enabled: true,
            applyChromaBleedingFix: true,
          ),
        ),
        tolerance: 4.0,
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
      // vszip.CLAHE's limit is a count per histogram bin, so it must scale with
      // the depth the CONTENT uses (here 8-bit content in a 10-bit clip, which
      // fills every 256th bin of a 16-bit histogram), not the container's. With
      // the container's it was 9-27 levels off. CLAHE's clipping is not exactly
      // depth-invariant, so this one gets more headroom than a plain curve.
      _Pass(
        'color_local_contrast',
        _only(
          colorCorrection: const ColorCorrectionParameters(
            enabled: true,
            applyLocalContrast: true,
            // Full strength: the unblended CLAHE result is the depth-sensitive part.
            localContrastStrength: 1.0,
          ),
        ),
        tolerance: 3.0,
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

/// The unfiltered 10-bit frame, rendered once per fixture and reused as the
/// reference every pass is checked against for "did this actually do
/// anything". Keyed by [_Pass.shaken].
final _passthroughCache = <bool, Uint8List>{};

Future<Uint8List> _passthroughRgb10({bool shaken = false}) async {
  final cached = _passthroughCache[shaken];
  if (cached != null) return cached;
  final fixture =
      await (shaken ? _shakenFixture('yuv422p10le') : _fixture('yuv422p10le'));
  final result = await WorkerHarness.runPreview(
    _job(fixture: fixture, pixFmt: 'yuv422p10le', pipeline: _only()).toJson(),
    frame: _previewFrame,
    label: 'passthrough_reference',
  );
  expect(result.success, isTrue,
      reason: 'the passthrough reference frame must render: $result');
  return _passthroughCache[shaken] =
      await WorkerHarness.imageToRgb24(result.png!, label: 'ref10');
}

/// The worker's KNLMeansCL device probe, run once. Null when no OpenCL device
/// can run KNLMeansCL here.
Future<String?>? _knlmDeviceProbe;
Future<String?> _knlmDevice() => _knlmDeviceProbe ??= () async {
      final probe = await Process.run(
        WorkerHarness.workerPath,
        ['--probe-opencl'],
        environment: WorkerHarness.workerEnv,
        workingDirectory: File(WorkerHarness.workerPath).parent.path,
      );
      final match = RegExp(r'"knlmDevice":"([^"]+)"')
          .firstMatch(probe.stdout.toString());
      return match?.group(1);
    }();

/// True (after printing why) when [pass] cannot run on this machine.
Future<bool> _skipWithoutDevice(_Pass pass) async {
  if (!pass.needsKnlmDevice || await _knlmDevice() != null) return false;
  print('  SKIPPED ${pass.name}: no OpenCL device KNLMeansCL can use here');
  return true;
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
        if (await _skipWithoutDevice(pass)) return;
        final fixture = await _fixtureFor(pass, 'yuv422p10le');
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
  // 2. Do the deeper formats work too? 9-bit is some H.264 High 4:4:4 and
  //    FFV1 files (decoded as 10-bit, task #31: Dehalo's YAHR failed on it
  //    before, as CTMF has no 9-bit format); 12-bit is ProRes 4444 XQ;
  //    14-bit is FFV1 film scans (decoded as 16-bit, task #23: QTGMC,
  //    santiag and Deblock QED all failed on it before); 16-bit is what the
  //    high-precision paths convert to internally, so a pass that rejects it
  //    is a latent failure even for a 10-bit source. yuv420p14le gives every
  //    pass a field-flagged 4:2:0 source (DeScratch failed on it, task #29).
  // ===========================================================================
  group('preview runs on deeper formats', () {
    for (final pixFmt in [
      'yuv422p9le',
      'yuv444p12le',
      'yuv420p14le',
      'yuv422p14le',
      'yuv422p16le',
    ]) {
      for (final pass in _passes()) {
        test('${pass.name} on $pixFmt', () async {
          if (await _skipWithoutDevice(pass)) return;
          final fixture = await _fixtureFor(pass, pixFmt);
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
        if (await _skipWithoutDevice(pass)) return;
        final src8 = await _fixtureFor(pass, 'yuv422p');
        final src10 = await _fixtureFor(pass, 'yuv422p10le');

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
          final reference = await _passthroughRgb10(shaken: pass.shaken);
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
  // 3a. 14-bit sources (task #23). fmtconv's bitdepth has no 14-bit output and
  //     havsfunc returns to the clip's depth through it (Bob, Resize,
  //     Deblock_QED), so the worker decodes 14-bit as 16-bit. The decoder's
  //     14 -> 16 conversion is an exact shift, so a 14-bit source must give
  //     the 16-bit fixture's picture.
  // ===========================================================================
  group('14-bit sources (task #23)', () {
    const qtgmcDefault = QTGMCParameters(enabled: true, tff: true);

    // The two fixtures are separate conversions of the master, and ffmpeg
    // upsamples its 4:2:0 chroma separately at each depth, so measure what
    // they differ by before any filter and allow a pass only its own
    // rounding on top.
    double? baseline;
    Future<double> diff14vs16(ProcessingPipeline pipeline, String label) async {
      final src14 = await _fixture('yuv422p14le');
      final src16 = await _fixture('yuv422p16le');
      final r14 = await WorkerHarness.runPreview(
        _job(fixture: src14, pixFmt: 'yuv422p14le', pipeline: pipeline).toJson(),
        frame: _previewFrame,
        label: '${label}_14',
      );
      final r16 = await WorkerHarness.runPreview(
        _job(fixture: src16, pixFmt: 'yuv422p16le', pipeline: pipeline).toJson(),
        frame: _previewFrame,
        label: '${label}_16',
      );
      expect(r14.success, isTrue, reason: '$label failed on 14-bit: $r14');
      expect(r16.success, isTrue, reason: '$label failed on 16-bit: $r16');
      return WorkerHarness.meanAbsDiff(
          await WorkerHarness.imageToRgb24(r14.png!, label: '${label}_r14'),
          await WorkerHarness.imageToRgb24(r16.png!, label: '${label}_r16'));
    }

    final cases = <String, ProcessingPipeline>{
      'passthrough': _only(),
      'deinterlace_default': _only(deinterlace: qtgmcDefault),
      'anti_alias_santiag': _only(
          antiAlias: const AntiAliasParameters(
              enabled: true, method: AntiAliasMethod.santiag)),
      'deblock_qed': _only(
          deblock: const DeblockParameters(
              enabled: true, method: DeblockMethod.deblockQed)),
    };
    for (final entry in cases.entries) {
      test('${entry.key}: 14-bit gives the 16-bit picture', () async {
        baseline ??= await diff14vs16(_only(), 'p14_passthrough');
        final diff = entry.key == 'passthrough'
            ? baseline!
            : await diff14vs16(entry.value, 'p14_${entry.key}');
        print('  ${entry.key}: 14 vs 16-bit mean abs diff '
            '${diff.toStringAsFixed(3)} (fixtures alone: '
            '${baseline!.toStringAsFixed(3)})');
        expect(diff, lessThan(baseline! + 0.25));
      }, timeout: const Timeout(Duration(minutes: 6)));
    }

    test('default pipeline encodes a 14-bit 4:2:0 source to FFV1', () async {
      final fixture = await _fixture('yuv420p14le');
      final pipeline = _only(deinterlace: qtgmcDefault);
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: fixture,
        outputPath: '$_outDir/p14_encode.mkv',
        qtgmcParameters: pipeline.deinterlace,
        processingPipeline: pipeline,
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.none,
          chromaSubsampling: ChromaSubsampling.original,
        ),
        detectedFieldOrder: FieldOrder.topFieldFirst,
        totalFrames: _frames,
        inputFrameRate: _fps,
        inputWidth: _width,
        inputHeight: _height,
        inputPixelFormat: 'yuv420p14le',
      );
      final result = await WorkerHarness.runJob(job.toJson(), label: 'p14_encode');
      expect(result.success, isTrue, reason: result.error);
      final out = await WorkerHarness.firstStream(result.outputPath!,
          selector: 'v:0',
          entries: ['pix_fmt', 'nb_read_frames'],
          countFrames: true);
      expect(out, isNotNull);
      print('  14-bit encode -> ${out!['pix_fmt']}, '
          '${out['nb_read_frames']} frames');
      // Documented: "match source" delivers a 14-bit source as 16-bit, the
      // depth the pipeline worked in.
      expect(out['pix_fmt'], 'yuv420p16le');
      // QTGMC at double rate.
      expect(int.parse('${out['nb_read_frames']}'), _frames * 2);
    }, timeout: const Timeout(Duration(minutes: 8)));

    for (final pixFmt in ['gray14le', 'gbrp14le']) {
      test('$pixFmt previews through QTGMC', () async {
        final fixture = await _fixture(pixFmt);
        final result = await WorkerHarness.runPreview(
          _job(
                  fixture: fixture,
                  pixFmt: pixFmt,
                  pipeline: _only(deinterlace: qtgmcDefault))
              .toJson(),
          frame: _previewFrame,
          label: 'p14_$pixFmt',
        );
        expect(result.success, isTrue, reason: '$pixFmt failed: $result');
      }, timeout: const Timeout(Duration(minutes: 4)));
    }
  });

  // ===========================================================================
  // 3c. DeScratch on 4:2:0 (task #29). The plugin blurs with an internal
  //     resize that zimg runs per field on a field-flagged clip, and 4:2:0
  //     fields need a multiple of 4 rows: 288 lines at the default blurlen
  //     failed, as did 480 and 1080i. The template runs the luma on a 4:2:2
  //     carrier with blank chroma, so its luma must be exactly the 4:2:2
  //     call's. The fixtures carry drawn scratches so the pass has work.
  // ===========================================================================
  group('DeScratch on 4:2:0 (task #29)', () {
    const descratch = DeScratchParameters(enabled: true);
    const withChroma = DeScratchParameters(enabled: true, modeU: 3, modeV: 3);

    for (final pixFmt in ['yuv420p', 'yuv420p10le']) {
      for (final (name, params) in [
        ('default', descratch),
        ('chroma modes on', withChroma),
      ]) {
        test('$name: preview and encode run on $pixFmt', () async {
          final fixture = await _scratchedFixture(pixFmt);
          final pipeline = _only(descratch: params);
          final tag = '${pixFmt}_${name.replaceAll(' ', '_')}';
          final preview = await WorkerHarness.runPreview(
            _job(fixture: fixture, pixFmt: pixFmt, pipeline: pipeline).toJson(),
            frame: _previewFrame,
            label: 'ds_$tag',
          );
          expect(preview.success, isTrue,
              reason: 'DeScratch preview failed on $pixFmt: $preview');
          final result = await WorkerHarness.runJob(
              _losslessJob(
                      fixture: fixture,
                      pixFmt: pixFmt,
                      pipeline: pipeline,
                      outputName: 'ds_$tag')
                  .toJson(),
              label: 'ds_$tag');
          expect(result.success, isTrue,
              reason: 'DeScratch encode failed on $pixFmt: ${result.error}');
          final out = await WorkerHarness.firstStream(result.outputPath!,
              selector: 'v:0',
              entries: ['pix_fmt', 'nb_read_frames'],
              countFrames: true);
          expect(out!['pix_fmt'], pixFmt);
          expect(int.parse('${out['nb_read_frames']}'), _frames);
        }, timeout: const Timeout(Duration(minutes: 4)));
      }
    }

    test('4:2:0 luma equals the 4:2:2 result; chroma is the source\'s',
        () async {
      final src420 = await _scratchedFixture('yuv420p');
      final src422 = await _scratchedFixture('yuv422p');
      const cw = _width ~/ 2;
      final in420 = await _rawFrames(src420, 'yuv420p');
      final in422 = await _rawFrames(src422, 'yuv422p');
      // Both fixtures are lossless conversions of one master, so they share
      // its luma; without that the comparison below would mean nothing.
      expect(_differing(_planes(in420, 0, cw, _height ~/ 2),
              _planes(in422, 0, cw, _height)), 0,
          reason: 'the 4:2:0 and 4:2:2 fixtures must share their luma');

      Future<Uint8List> encode(String fixture, String pixFmt) async {
        final result = await WorkerHarness.runJob(
            _losslessJob(
                    fixture: fixture,
                    pixFmt: pixFmt,
                    pipeline: _only(descratch: descratch),
                    outputName: 'ds_ref_$pixFmt')
                .toJson(),
            label: 'ds_ref_$pixFmt');
        expect(result.success, isTrue, reason: result.error);
        return _rawFrames(result.outputPath!, pixFmt);
      }

      final out420 = await encode(src420, 'yuv420p');
      final out422 = await encode(src422, 'yuv422p');
      final y420 = _planes(out420, 0, cw, _height ~/ 2);
      final y422 = _planes(out422, 0, cw, _height);
      final changed = _differing(y420, _planes(in420, 0, cw, _height ~/ 2));
      print('  DeScratch changed $changed luma samples of ${y420.length}');
      expect(changed, greaterThan(0),
          reason: 'DeScratch changed nothing, so the comparison proves nothing');
      expect(_differing(y420, y422), 0,
          reason: 'the carrier\'s luma must equal the 4:2:2 call\'s');
      for (final plane in [1, 2]) {
        expect(
            _differing(_planes(out420, plane, cw, _height ~/ 2),
                _planes(in420, plane, cw, _height ~/ 2)),
            0,
            reason: 'plane $plane must be the source\'s with chroma modes off');
      }
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('Soft Telecine + DeScratch encodes an NTSC film DVD', () async {
      // VDecimate alone keeps _FieldBased, and 240 lines at the default
      // blurlen is a failing height: the most common film-DVD job.
      final fixture =
          '${WorkerHarness.repoRoot}/Tests/TestResources/soft_telecine_dvd.mkv';
      final pipeline = _only(
        deinterlace: const QTGMCParameters(
            enabled: true, method: DeinterlaceMethod.softTelecine, tff: true),
        descratch: descratch,
      );
      final result = await WorkerHarness.runJob(
          _losslessJob(
            fixture: fixture,
            pixFmt: 'yuv420p',
            pipeline: pipeline,
            outputName: 'ds_soft_telecine',
            width: 352,
            height: 240,
            frames: 120,
            fps: 30000 / 1001,
          ).toJson(),
          label: 'ds_soft_telecine');
      expect(result.success, isTrue, reason: result.error);
      final out = await WorkerHarness.firstStream(result.outputPath!,
          selector: 'v:0', entries: ['pix_fmt', 'height']);
      expect(out!['pix_fmt'], 'yuv420p');
      expect('${out['height']}', '240');
    }, timeout: const Timeout(Duration(minutes: 4)));
  });

  // ===========================================================================
  // 3a'. 9-bit sources (task #31). CTMF has no 9-bit format and havsfunc
  //     reaches it through MinBlur(r>=2) (YAHR; HQDeringmod, ContraSharpening
  //     and SMDegrain's contrasharp at HD), so the worker decodes 9-bit as
  //     10-bit. The decoder's 9 -> 10 conversion is an exact shift in
  //     limited range, so a 9-bit source must give the 10-bit fixture's
  //     picture.
  // ===========================================================================
  group('9-bit sources (task #31)', () {
    const qtgmcDefault = QTGMCParameters(enabled: true, tff: true);

    // As for 14 vs 16 above: the fixtures are separate conversions of the
    // master, so measure their own difference first.
    double? baseline;
    Future<double> diff9vs10(ProcessingPipeline pipeline, String label) async {
      final src9 = await _fixture('yuv422p9le');
      final src10 = await _fixture('yuv422p10le');
      final r9 = await WorkerHarness.runPreview(
        _job(fixture: src9, pixFmt: 'yuv422p9le', pipeline: pipeline).toJson(),
        frame: _previewFrame,
        label: '${label}_9',
      );
      final r10 = await WorkerHarness.runPreview(
        _job(fixture: src10, pixFmt: 'yuv422p10le', pipeline: pipeline).toJson(),
        frame: _previewFrame,
        label: '${label}_10',
      );
      expect(r9.success, isTrue, reason: '$label failed on 9-bit: $r9');
      expect(r10.success, isTrue, reason: '$label failed on 10-bit: $r10');
      return WorkerHarness.meanAbsDiff(
          await WorkerHarness.imageToRgb24(r9.png!, label: '${label}_r9'),
          await WorkerHarness.imageToRgb24(r10.png!, label: '${label}_r10'));
    }

    final cases = <String, ProcessingPipeline>{
      'passthrough': _only(),
      'dehalo_yahr': _only(
          dehalo: const DehaloParameters(
              enabled: true, method: DehaloMethod.yahr)),
      'noise_ctmf': _only(
          noiseReduction: const NoiseReductionParameters(
              enabled: true, method: NoiseReductionMethod.ctmf, ctmfRadius: 3)),
    };
    for (final entry in cases.entries) {
      test('${entry.key}: 9-bit gives the 10-bit picture', () async {
        baseline ??= await diff9vs10(_only(), 'p9_passthrough');
        final diff = entry.key == 'passthrough'
            ? baseline!
            : await diff9vs10(entry.value, 'p9_${entry.key}');
        print('  ${entry.key}: 9 vs 10-bit mean abs diff '
            '${diff.toStringAsFixed(3)} (fixtures alone: '
            '${baseline!.toStringAsFixed(3)})');
        expect(diff, lessThan(baseline! + 0.25));
      }, timeout: const Timeout(Duration(minutes: 6)));
    }

    test('default pipeline encodes a 9-bit 4:2:0 source to FFV1', () async {
      final fixture = await _fixture('yuv420p9le');
      final pipeline = _only(deinterlace: qtgmcDefault);
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: fixture,
        outputPath: '$_outDir/p9_encode.mkv',
        qtgmcParameters: pipeline.deinterlace,
        processingPipeline: pipeline,
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.none,
          chromaSubsampling: ChromaSubsampling.original,
        ),
        detectedFieldOrder: FieldOrder.topFieldFirst,
        totalFrames: _frames,
        inputFrameRate: _fps,
        inputWidth: _width,
        inputHeight: _height,
        inputPixelFormat: 'yuv420p9le',
      );
      final result = await WorkerHarness.runJob(job.toJson(), label: 'p9_encode');
      expect(result.success, isTrue, reason: result.error);
      final out = await WorkerHarness.firstStream(result.outputPath!,
          selector: 'v:0',
          entries: ['pix_fmt', 'nb_read_frames'],
          countFrames: true);
      expect(out, isNotNull);
      print('  9-bit encode -> ${out!['pix_fmt']}, '
          '${out['nb_read_frames']} frames');
      // Documented: "match source" delivers a 9-bit source as 10-bit, the
      // depth the pipeline worked in.
      expect(out['pix_fmt'], 'yuv420p10le');
      expect(int.parse('${out['nb_read_frames']}'), _frames * 2);
    }, timeout: const Timeout(Duration(minutes: 8)));
  });

  // ===========================================================================
  // 3d. DeScratch keeps >8-bit precision (task #34). The plugin is 8-bit only;
  //     the block used to up-convert its whole 8-bit result, quantising every
  //     sample of a deeper source. It now adds only the plugin's change to the
  //     source, so the output must be the source wherever the 8-bit run left a
  //     sample alone, the 8-bit repair (to its rounding) where it changed one,
  //     and keep the source's low bits everywhere.
  //     docs/reports/issue-34-descratch-high-bit-depth
  // ===========================================================================
  group('DeScratch keeps >8-bit precision (task #34)', () {
    const descratch = DeScratchParameters(enabled: true);

    Future<Uint8List> encode(String fixture, String pixFmt, String name) async {
      final result = await WorkerHarness.runJob(
          _losslessJob(
                  fixture: fixture,
                  pixFmt: pixFmt,
                  pipeline: _only(descratch: descratch),
                  outputName: name)
              .toJson(),
          label: name);
      expect(result.success, isTrue, reason: result.error);
      return _rawFrames(result.outputPath!, pixFmt);
    }

    for (final pixFmt8 in ['yuv422p', 'yuv420p']) {
      final pixFmt = '${pixFmt8}10le';
      test('$pixFmt: untouched samples bit-exact, repairs match the 8-bit run',
          () async {
        const cw = _width ~/ 2;
        final ch = pixFmt8 == 'yuv420p' ? _height ~/ 2 : _height;
        final src8 = await _scratchedFixture(pixFmt8);
        final src10 = await _deepScratchedFixture(pixFmt8);
        final in8 = await _rawFrames(src8, pixFmt8);
        final in10 = await _rawFrames(src10, pixFmt);

        // The plugin must see the same 8-bit picture in both runs, or the
        // comparison with the 8-bit run means nothing.
        var lowBits = 0, notFourTimes = 0;
        for (final plane in [0, 1, 2]) {
          final a = _planes(in8, plane, cw, ch);
          final b = _planes16(in10, plane, cw, ch);
          expect(b.length, a.length);
          for (var i = 0; i < a.length; i++) {
            if (b[i] >> 2 != a[i] || b[i] & 3 > 1) notFourTimes++;
            if (b[i] & 3 != 0) lowBits++;
          }
        }
        expect(notFourTimes, 0,
            reason: 'the 10-bit fixture must be the 8-bit one times four plus '
                '0 or 1 (ffmpeg\'s 8 to 10-bit conversion changed?)');
        expect(lowBits, greaterThan(0),
            reason: 'the 10-bit fixture has no sub-8-bit content');

        final out8 = await encode(src8, pixFmt8, 'ds_deep_ref_$pixFmt8');
        final out10 = await encode(src10, pixFmt, 'ds_deep_$pixFmt');

        for (final plane in [1, 2]) {
          final a = _planes16(in10, plane, cw, ch);
          final b = _planes16(out10, plane, cw, ch);
          var differ = 0;
          for (var i = 0; i < a.length; i++) {
            if (a[i] != b[i]) differ++;
          }
          expect(differ, 0,
              reason: 'plane $plane must be the source\'s, bit for bit');
        }

        final yIn8 = _planes(in8, 0, cw, ch);
        final yOut8 = _planes(out8, 0, cw, ch);
        final yIn10 = _planes16(in10, 0, cw, ch);
        final yOut10 = _planes16(out10, 0, cw, ch);
        var changed = 0, untouchedWrong = 0, setMismatch = 0;
        var farFromRepair = 0, lowBitsLost = 0;
        for (var i = 0; i < yIn10.length; i++) {
          final changed8 = yOut8[i] != yIn8[i];
          final changed10 = yOut10[i] != yIn10[i];
          if (changed10) changed++;
          if (changed8 != changed10) setMismatch++;
          if (!changed8 && changed10) untouchedWrong++;
          if ((yOut10[i] - 4 * yOut8[i]).abs() > 2) farFromRepair++;
          if (yOut10[i] & 3 != yIn10[i] & 3) lowBitsLost++;
        }
        print('  $pixFmt: DeScratch changed $changed of ${yIn10.length} luma '
            'samples');
        expect(changed, greaterThan(0),
            reason: 'DeScratch changed nothing, so the test proves nothing');
        expect(untouchedWrong, 0,
            reason: 'samples the 8-bit run left alone must be bit-exact');
        expect(setMismatch, 0,
            reason: 'the 10-bit run must change exactly the samples the 8-bit '
                'run changes');
        expect(farFromRepair, 0,
            reason: 'every sample must be within half an 8-bit level of the '
                '8-bit result');
        expect(lowBitsLost, 0,
            reason: 'the source\'s low bits must survive everywhere, repairs '
                'included (no 8-bit banding)');
      }, timeout: const Timeout(Duration(minutes: 6)));
    }

    test('preview matches the encode on yuv422p10le', () async {
      final src10 = await _deepScratchedFixture('yuv422p');
      final pipeline = _only(descratch: descratch);
      final preview = await WorkerHarness.runPreview(
        _losslessJob(
                fixture: src10,
                pixFmt: 'yuv422p10le',
                pipeline: pipeline,
                outputName: 'ds_deep_pv')
            .toJson(),
        frame: _previewFrame,
        label: 'ds_deep_pv',
      );
      expect(preview.success, isTrue, reason: '$preview');
      final result = await WorkerHarness.runJob(
          _losslessJob(
                  fixture: src10,
                  pixFmt: 'yuv422p10le',
                  pipeline: pipeline,
                  outputName: 'ds_deep_pv_encode')
              .toJson(),
          label: 'ds_deep_pv_encode');
      expect(result.success, isTrue, reason: result.error);
      final diff = WorkerHarness.meanAbsDiff(
          await WorkerHarness.imageToRgb24(preview.png!, label: 'dsp'),
          await WorkerHarness.frameRgb24(result.outputPath!, _previewFrame,
              label: 'dse'));
      print('  preview vs encode: mean abs diff ${diff.toStringAsFixed(3)}');
      expect(diff, lessThan(0.5));
    }, timeout: const Timeout(Duration(minutes: 6)));
  });

  // ===========================================================================
  // 3b. KNLMeans on 10-bit 4:2:0, the format issue #144 was reported on, in
  //     both paths. The groups above use 4:2:2 and 4:4:4 fixtures.
  // ===========================================================================
  group('KNLMeans on a 10-bit 4:2:0 source (issue #144)', () {
    final pass = _passes().firstWhere((p) => p.name == 'noise_knlmeans');

    test('preview matches the 8-bit 4:2:0 result', () async {
      if (await _skipWithoutDevice(pass)) return;
      final src8 = await _fixture('yuv420p');
      final src10 = await _fixture('yuv420p10le');
      final eight = await WorkerHarness.runPreview(
        _job(fixture: src8, pixFmt: 'yuv420p', pipeline: pass.pipeline).toJson(),
        frame: _previewFrame,
        label: 'knlm420_8',
      );
      final ten = await WorkerHarness.runPreview(
        _job(fixture: src10, pixFmt: 'yuv420p10le', pipeline: pass.pipeline)
            .toJson(),
        frame: _previewFrame,
        label: 'knlm420_10',
      );
      expect(eight.success, isTrue, reason: '8-bit 4:2:0 run failed: $eight');
      expect(ten.success, isTrue, reason: '10-bit 4:2:0 run failed: $ten');
      final diff = WorkerHarness.meanAbsDiff(
          await WorkerHarness.imageToRgb24(eight.png!, label: 'k8'),
          await WorkerHarness.imageToRgb24(ten.png!, label: 'k10'));
      // The 4:2:0 fixtures differ by more than rounding before any filter runs
      // (ffmpeg subsamples the chroma separately at each depth), so measure
      // that baseline and allow the filter only its own rounding on top.
      final plain = _only();
      final base8 = await WorkerHarness.runPreview(
        _job(fixture: src8, pixFmt: 'yuv420p', pipeline: plain).toJson(),
        frame: _previewFrame,
        label: 'plain420_8',
      );
      final base10 = await WorkerHarness.runPreview(
        _job(fixture: src10, pixFmt: 'yuv420p10le', pipeline: plain).toJson(),
        frame: _previewFrame,
        label: 'plain420_10',
      );
      final baseline = WorkerHarness.meanAbsDiff(
          await WorkerHarness.imageToRgb24(base8.png!, label: 'b8'),
          await WorkerHarness.imageToRgb24(base10.png!, label: 'b10'));
      print('  knlmeans 4:2:0: mean abs diff ${diff.toStringAsFixed(3)} '
          '(fixtures alone: ${baseline.toStringAsFixed(3)})');
      expect(diff, lessThan(baseline + 1.0));
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('full encode succeeds', () async {
      if (await _skipWithoutDevice(pass)) return;
      final src10 = await _fixture('yuv420p10le');
      final job = _job(
          fixture: src10,
          pixFmt: 'yuv420p10le',
          pipeline: pass.pipeline,
          outputName: 'knlm420_10');
      final result =
          await WorkerHarness.runJob(job.toJson(), label: 'knlm420_10_encode');
      expect(result.success, isTrue, reason: 'encode failed: $result');
    }, timeout: const Timeout(Duration(minutes: 6)));
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

    test('4:2:0 10-bit keeps the precision and drops only the chroma', () async {
      // The option added for issue #74: NVENC, QSV and AMF can all encode
      // 10-bit 4:2:0 and none of them can encode 4:2:2 on most hardware, so
      // this is how a 10-bit source keeps its grading through a GPU encoder.
      // High 10 rather than High, and 4:2:0 rather than 4:2:2 — getting either
      // half wrong would defeat the purpose.
      final out = await encodeWith(ChromaSubsampling.yuv420p10, 'yuv420p10');
      expect(out['pix_fmt'], 'yuv420p10le');
      expect(out['profile'], 'High 10');
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
