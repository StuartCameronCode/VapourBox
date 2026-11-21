/// Task #88: the script's own conversions between YUV and RGB on sources
/// tagged bt2020c, chroma-derived-nc/-c or ictcp.
///
/// zimg refuses those matrices from the matrix alone ("Resize error 3074:
/// invalid colorspace definition"), and the script passed nothing else, so
/// every job with Add Borders (whatever the colour), RIFE, AI upscaling, Face
/// Restoration or Colourisation failed on such a source, encode and preview.
/// `ColorMetadata::zimg_colorspace` now names the whole colour space:
///
/// * read as the nearest NCL matrix (bt2020c; chroma-derived with BT.709 or
///   BT.2020 primaries; ictcp on an SDR transfer): the output equals a twin
///   tagged with that matrix, bit for bit;
/// * exact (chroma-derived-nc with other primaries; ictcp with PQ): the bars
///   equal a closed-form reference within 1 code (H.273's derived
///   coefficients; BT.2100's ICtCp), so this checks zimg against the
///   standard, not against itself.
///
/// Fixtures are testsrc2 retagged with `setparams` (no sample converted),
/// 10-bit 4:2:0 FFV1. See docs/reports/task-88-zimg-colour-tags.
///
/// Heavy (full encodes; the Colourisation / Face Restoration group installs
/// their add-ons). The RIFE / AI upscale group is also tagged `gpu`.
@Tags(['heavy'])
@Timeout(Duration(minutes: 60))
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/colorize_parameters.dart';
import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/face_restore_parameters.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/gpu_expectations.dart';
import 'support/worker_harness.dart';

String get _dir => p.join(WorkerHarness.outputDir, 'zimg_colour_tags');

const _w = 320, _h = 240, _frames = 6;
const _pixFmt = 'yuv420p10le';

/// One tag set: matrix, primaries, transfer.
typedef _Tags = (String matrix, String? primaries, String? transfer);

String _slug(_Tags t) =>
    [t.$1, t.$2 ?? 'np', t.$3 ?? 'nt'].join('_').replaceAll('-', '');

final _fixtures = <String, String>{};

/// testsrc2 retagged without converting a sample.
Future<String> _fixture(_Tags t) async {
  final key = _slug(t);
  if (_fixtures[key] != null) return _fixtures[key]!;
  final out = p.join(_dir, 'src_$key.mkv');
  final params = [
    'colorspace=${t.$1}',
    'range=tv',
    if (t.$2 != null) 'color_primaries=${t.$2}',
    if (t.$3 != null) 'color_trc=${t.$3}',
  ].join(':');
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    [
      '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc2=size=${_w}x$_h:rate=25',
      '-frames:v', '$_frames',
      '-vf', 'format=$_pixFmt,setparams=$params',
      '-c:v', 'ffv1', out,
    ],
    environment: WorkerHarness.ffmpegEnv,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return _fixtures[key] = out;
}

Map<String, dynamic> _job(String name, String input, _Tags t, ProcessingPipeline pipeline) =>
    VideoJob(
      id: const Uuid().v4(),
      inputPath: input,
      outputPath: p.join(_dir, '$name.mkv'),
      processingPipeline: pipeline,
      encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1, container: ContainerFormat.mkv, audioMode: AudioMode.none),
      inputWidth: _w,
      inputHeight: _h,
      inputPixelFormat: _pixFmt,
      inputFrameRate: 25.0,
      totalFrames: _frames,
      inputColorMatrix: t.$1,
      inputColorPrimaries: t.$2,
      inputColorTransfer: t.$3,
      inputColorRange: 'tv',
    ).toJson();

ProcessingPipeline _borders({String? custom}) => ProcessingPipeline(
      deinterlace: const QTGMCParameters(enabled: false),
      cropResize: CropResizeParameters(
        enabled: true,
        cropEnabled: true,
        cropLeft: 8,
        cropRight: 8,
        cropTop: 8,
        cropBottom: 8,
        padEnabled: true,
        padWidth: _w,
        padHeight: _h,
        padColor: custom == null ? BorderColor.black : BorderColor.custom,
        padCustomColor: custom,
      ),
    );

Future<String> _encode(String name, String input, _Tags t, ProcessingPipeline pipeline,
    {Map<String, String> extraEnv = const {}}) async {
  final r = await WorkerHarness.runJob(_job(name, input, t, pipeline),
      label: name, timeout: const Duration(minutes: 20), extraEnv: extraEnv);
  expect(r.success, isTrue,
      reason: '${r.error}\n${r.logs.reversed.take(25).toList().reversed.join('\n')}');
  return r.outputPath ?? p.join(_dir, '$name.mkv');
}

/// Every frame, 16-bit little-endian samples in the file's format.
Future<Uint8List> _raw(String path) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', _pixFmt, '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return Uint8List.fromList(r.stdout as List<int>);
}

/// Y, Cb, Cr of frame 0 at (0, 0): inside the bar on every plane.
List<int> _corner(Uint8List raw) {
  int at(int i) => raw[i * 2] | (raw[i * 2 + 1] << 8);
  final luma = _w * _h;
  return [at(0), at(luma), at(luma + luma ~/ 4)];
}

// --- closed-form references (10-bit limited) --------------------------------

/// H.273 MatrixCoefficients 12: Kr, Kb derived from the primaries (D65).
(double, double) _derivedKrKb(List<List<double>> prim) {
  final [xr, yr] = prim[0];
  final [xg, yg] = prim[1];
  final [xb, yb] = prim[2];
  const xw = 0.3127, yw = 0.3290;
  final zr = 1 - xr - yr, zg = 1 - xg - yg, zb = 1 - xb - yb, zw = 1 - xw - yw;
  final den = yw * (xr * (yg * zb - yb * zg) + xg * (yb * zr - yr * zb) + xb * (yr * zg - yg * zr));
  final kr = yr * (xw * (yg * zb - yb * zg) + yw * (xb * zg - xg * zb) + zw * (xg * yb - xb * yg)) / den;
  final kb = yb * (xw * (yr * zg - yg * zr) + yw * (xg * zr - xr * zg) + zw * (xr * yg - xg * yr)) / den;
  return (kr, kb);
}

List<int> _ycbcr(List<int> rgb, (double, double) k) {
  final (kr, kb) = k;
  final [r, g, b] = [for (final c in rgb) c / 255];
  final y = kr * r + (1 - kr - kb) * g + kb * b;
  return [
    (64 + 876 * y).round(),
    (512 + 896 * (b - y) / (2 * (1 - kb))).round(),
    (512 + 896 * (r - y) / (2 * (1 - kr))).round(),
  ];
}

/// BT.2100 ICtCp, PQ: R'G'B' (PQ) -> linear -> LMS -> PQ -> ICtCp.
List<int> _ictcpPq(List<int> rgb) {
  const m1 = 2610 / 16384, m2 = 2523 / 4096 * 128;
  const c1 = 3424 / 4096, c2 = 2413 / 4096 * 32, c3 = 2392 / 4096 * 32;
  double eotf(double e) {
    final pe = math.pow(e, 1 / m2).toDouble();
    return math.pow(math.max(pe - c1, 0) / (c2 - c3 * pe), 1 / m1).toDouble();
  }

  double oetf(double y) {
    final py = math.pow(y, m1).toDouble();
    return math.pow((c1 + c2 * py) / (1 + c3 * py), m2).toDouble();
  }

  final [r, g, b] = [for (final c in rgb) eotf(c / 255)];
  final l = oetf((1688 * r + 2146 * g + 262 * b) / 4096);
  final m = oetf((683 * r + 2951 * g + 462 * b) / 4096);
  final s = oetf((99 * r + 309 * g + 3688 * b) / 4096);
  final i = 0.5 * l + 0.5 * m;
  final ct = (6610 * l - 13613 * m + 7003 * s) / 4096;
  final cp = (17933 * l - 17390 * m - 543 * s) / 4096;
  return [(64 + 876 * i).round(), (512 + 896 * ct).round(), (512 + 896 * cp).round()];
}

const _custom = '#C8285A';
const _customRgb = [200, 40, 90];
const _black = [64, 512, 512];

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_dir).create(recursive: true);
  });

  group('Add Borders on tags zimg needs more than a matrix for (task #88)', () {
    // Read as the nearest NCL matrix: equal to a twin tagged with it.
    const twins = <(_Tags, _Tags)>[
      (('bt2020c', 'bt2020', 'bt709'), ('bt2020nc', 'bt2020', 'bt709')),
      (('chroma-derived-nc', 'bt709', 'bt709'), ('bt709', 'bt709', 'bt709')),
      (('chroma-derived-c', 'bt2020', 'bt709'), ('bt2020nc', 'bt2020', 'bt709')),
      (('ictcp', 'bt2020', 'bt709'), ('bt2020nc', 'bt2020', 'bt709')),
    ];
    for (final (tagged, twin) in twins) {
      test('${_slug(tagged)} reads as ${twin.$1}: encode and preview run, = the twin', () async {
        final src = await _fixture(tagged);
        final twinSrc = await _fixture(twin);
        for (final custom in [null, _custom]) {
          final label = custom == null ? 'black' : 'custom';
          final out = await _encode('${_slug(tagged)}_$label', src, tagged, _borders(custom: custom));
          final ref = await _encode('${_slug(tagged)}_${label}_twin', twinSrc, twin, _borders(custom: custom));
          final a = await _raw(out), b = await _raw(ref);
          expect(a.length, b.length);
          expect(a, equals(b), reason: '$label bars and picture must equal the ${twin.$1} twin');
          if (custom == null) expect(_corner(a), _black);
        }
        final preview = await WorkerHarness.runPreview(
            _job('${_slug(tagged)}_preview', src, tagged, _borders(custom: _custom)),
            frame: 2);
        expect(preview.success, isTrue, reason: preview.toString());
      });
    }

    // Exact: the bar against the standard's own arithmetic.
    final exact = <(_Tags, List<int>)>[
      (
        ('chroma-derived-nc', 'bt470bg', null),
        _ycbcr(_customRgb, _derivedKrKb([[0.64, 0.33], [0.29, 0.60], [0.15, 0.06]])),
      ),
      (
        ('chroma-derived-nc', 'smpte170m', 'smpte170m'),
        _ycbcr(_customRgb, _derivedKrKb([[0.630, 0.340], [0.310, 0.595], [0.155, 0.070]])),
      ),
      (('ictcp', 'bt2020', 'smpte2084'), _ictcpPq(_customRgb)),
    ];
    for (final (tags, want) in exact) {
      test('${_slug(tags)}: the bars match the closed form within 1 code', () async {
        final src = await _fixture(tags);
        final plain = await _raw(await _encode('${_slug(tags)}_none', src, tags,
            const ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false))));
        for (final (custom, expected) in [(null, _black), (_custom, want)]) {
          final label = custom == null ? 'black' : 'custom';
          final out = await _raw(await _encode('${_slug(tags)}_$label', src, tags, _borders(custom: custom)));
          final got = _corner(out);
          for (var c = 0; c < 3; c++) {
            expect((got[c] - expected[c]).abs(), lessThanOrEqualTo(1),
                reason: '$label bar plane $c: got $got, the standard gives $expected');
          }
          // The picture inside the bars is the source's, untouched: row 120,
          // columns 8..311 of frame 0 equal the unbordered encode's.
          int at(Uint8List r, int i) => r[i * 2] | (r[i * 2 + 1] << 8);
          for (var x = 8; x < _w - 8; x++) {
            expect(at(out, 120 * _w + x), at(plain, 120 * _w + x), reason: '$label picture at x=$x');
          }
        }
        final preview = await WorkerHarness.runPreview(
            _job('${_slug(tags)}_preview', src, tags, _borders(custom: _custom)), frame: 2);
        expect(preview.success, isTrue, reason: preview.toString());
      });
    }

    test('ictcp with HLG runs, with black bars', () async {
      const tags = ('ictcp', 'bt2020', 'arib-std-b67');
      final src = await _fixture(tags);
      final out = await _raw(await _encode('${_slug(tags)}_black', src, tags, _borders()));
      expect(_corner(out), _black);
      await _encode('${_slug(tags)}_custom', src, tags, _borders(custom: _custom));
    });
  });

  group('Colourisation and Face Restoration on these tags (task #88)', () {
    setUpAll(() async {
      await WorkerHarness.ensureAddon('colorize-ddcolor');
      await WorkerHarness.ensureAddon('face-restoration');
    });
    const env = {'VAPOURBOX_STALL_TIMEOUT_SECS': '1200'};
    for (final tags in const <_Tags>[('bt2020c', 'bt2020', 'bt709'), ('ictcp', 'bt2020', 'smpte2084')]) {
      test('${_slug(tags)}: both run; luma (Colourisation) and every sample (Face Restoration, no faces) kept',
          () async {
        final src = await _fixture(tags);
        const off = ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false));
        final plain = await _raw(await _encode('${_slug(tags)}_plain', src, tags, off));
        final cz = await _raw(await _encode('${_slug(tags)}_colorize', src, tags,
            const ProcessingPipeline(
                deinterlace: QTGMCParameters(enabled: false),
                colorize: ColorizeParameters(enabled: true)),
            extraEnv: env));
        final luma = _w * _h * 2, frame = luma * 3 ~/ 2;
        for (var f = 0; f < _frames; f++) {
          expect(cz.sublist(f * frame, f * frame + luma), plain.sublist(f * frame, f * frame + luma),
              reason: 'Colourisation must keep frame $f\'s luma bit-exact');
        }
        // testsrc2 has no faces: the pass converts every frame to RGB to look
        // for one, and must hand back the input untouched.
        final fr = await _raw(await _encode('${_slug(tags)}_face', src, tags,
            const ProcessingPipeline(
                deinterlace: QTGMCParameters(enabled: false),
                faceRestore: FaceRestoreParameters(enabled: true)),
            extraEnv: env));
        expect(fr, equals(plain));
      });
    }
  });

  group('RIFE and AI upscaling on these tags (task #88)', () {
    for (final tags in const <_Tags>[('bt2020c', 'bt2020', 'bt709'), ('ictcp', 'bt2020', 'smpte2084')]) {
      test('${_slug(tags)}: RIFE runs and keeps the real frames', () async {
        if (!await requireGpuPlugin('--probe-rife')) return;
        await WorkerHarness.ensureAddon('frame-rate-rife');
        final src = await _fixture(tags);
        const off = ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false));
        final plain = await _raw(await _encode('${_slug(tags)}_rife_plain', src, tags, off));
        final out = await _raw(await _encode('${_slug(tags)}_rife', src, tags,
            const ProcessingPipeline(
              deinterlace: QTGMCParameters(enabled: false),
              frameRate: FrameRateParameters(
                  enabled: true, target: FrameRateTarget.pal50, method: FrameRateMethod.rife),
            )));
        final frame = _w * _h * 3;
        expect(out.length, plain.length * 2, reason: '25 -> 50 fps');
        for (var f = 0; f < _frames; f++) {
          expect(out.sublist(2 * f * frame, (2 * f + 1) * frame), plain.sublist(f * frame, (f + 1) * frame),
              reason: 'real frame $f must come through bit-exact');
        }
      }, tags: ['gpu']);

      test('${_slug(tags)}: AI upscale runs', () async {
        if (!await requireGpuPlugin('--probe-upscale')) return;
        await WorkerHarness.ensureAddon('upscale-anime');
        final src = await _fixture(tags);
        final out = await _encode('${_slug(tags)}_ai', src, tags,
            const ProcessingPipeline(
              deinterlace: QTGMCParameters(enabled: false),
              cropResize: CropResizeParameters(
                  enabled: true, useIntegerUpscale: true, upscaleMethod: UpscaleMethod.realEsrgan, upscaleFactor: 2),
            ));
        final s = await WorkerHarness.firstStream(out, selector: 'v:0', entries: ['width', 'height']);
        expect((s!['width'].toString(), s['height'].toString()), ('${_w * 2}', '${_h * 2}'));
      }, tags: ['gpu']);
    }
  });
}
