/// IVTC / Soft Telecine preview (task #46): the preview shows the frame the
/// encode keeps for the target, not one a fifth of the window radius early.
///
/// The preview used to run VFM without VDecimate while the worker picked the
/// output index as if it had decimated, so it showed source frame
/// `target - ceil(radius / 5)`'s film frame: one early at radius 5, three at
/// 12. A frame rate conversion after IVTC converted the preview's undecimated
/// 29.97 at the wrong ratio as well. The preview now runs VDecimate on a clip
/// arranged as the encode's (docs/reports/issue-46-ivtc-preview).
///
/// Every fixture is testsrc2 at 24000/1001, so each picture is named by the
/// film frame it holds, field by field, against the film regenerated from
/// lavfi — independently of the worker. A preview is right when it is one of
/// the lossless encode's frames (MAD < 1.5) and holds one of the target
/// slot's film frames, or, when VDecimate dropped every one of them from the
/// encode, the kept frame before them (what a frame with no output of its own
/// always shows). After a frame rate conversion it must be the encode's k-th
/// output of the slot's film frame.
///
/// Heavy (full encodes + previews) — nightly, not the push gate.
@Tags(['heavy'])
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/deflicker_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

String get _outDir => '${WorkerHarness.outputDir}/ivtc_preview';

const _tw = 88, _th = 30;
const _fullRgb = 'scale=in_range=tv:out_range=pc,format=rgb24';
const _same = 1.5;

class _Fixture {
  final String file;
  final int width, height, slots, film;
  final String pixFmt;

  /// Filters placing a soft-telecined stream's frames on the 29.97 grid.
  final String slotFilters;
  const _Fixture(this.file, this.width, this.height, this.pixFmt, this.slots,
      this.film, [this.slotFilters = '']);
  String get path =>
      p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', file);
}

const _hard =
    _Fixture('hard_telecine_test.avi', 720, 480, 'yuv420p', 90, 72);
const _prores =
    _Fixture('prores422_10bit_telecine.mov', 720, 480, 'yuv422p10le', 30, 24);
const _dvdMkv = _Fixture('soft_telecine_dvd.mkv', 352, 240, 'yuv420p', 150,
    120, 'setpts=PTS-STARTPTS,fps=30000/1001,');
const _dvdVob = _Fixture('soft_telecine_dvd.vob', 352, 240, 'yuv420p', 150,
    120, 'setpts=PTS-STARTPTS,fps=30000/1001,');

const _ivtc = QTGMCParameters(
    enabled: true, method: DeinterlaceMethod.ivtc, tff: true, ivtcCycle: 5);
const _soft =
    QTGMCParameters(enabled: true, method: DeinterlaceMethod.softTelecine);

/// One field of every picture of [input], as a mean/std-normalised luma
/// thumbnail. `[(top, bottom), ...]`.
Future<List<List<Float64List>>> _fieldThumbs(List<String> input,
    {String head = '', int? count}) async {
  final fields = <List<Float64List>>[];
  for (final parity in ['top', 'bottom']) {
    final r = await Process.run(
      WorkerHarness.ffmpegPath,
      [
        '-v', 'error', ...input,
        '-vf', '$head$_fullRgb,field=$parity,scale=$_tw:$_th:flags=area,format=gray',
        if (count != null) ...['-frames:v', '$count'],
        '-f', 'rawvideo', '-',
      ],
      environment: WorkerHarness.ffmpegEnv,
      stdoutEncoding: null,
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final raw = r.stdout as List<int>;
    const size = _tw * _th;
    fields.add([
      for (var i = 0; i + size <= raw.length; i += size)
        _norm(raw.sublist(i, i + size)),
    ]);
  }
  return [
    for (var i = 0; i < math.min(fields[0].length, fields[1].length); i++)
      [fields[0][i], fields[1][i]],
  ];
}

Float64List _norm(List<int> b) {
  final mean = b.reduce((a, c) => a + c) / b.length;
  var v = 0.0;
  for (final x in b) {
    v += (x - mean) * (x - mean);
  }
  final sd = math.sqrt(v / b.length);
  return Float64List.fromList([for (final x in b) (x - mean) / (sd == 0 ? 1 : sd)]);
}

double _dist(Float64List a, Float64List b) {
  var d = 0.0;
  for (var i = 0; i < a.length; i++) {
    d += (a[i] - b[i]).abs();
  }
  return d;
}

/// The film frame each field holds.
List<int> _name(List<Float64List> fields, List<List<Float64List>> film) => [
      for (var f = 0; f < 2; f++)
        List.generate(film.length, (i) => i).reduce(
            (a, b) => _dist(fields[f], film[a][f]) <= _dist(fields[f], film[b][f]) ? a : b),
    ];

/// Every frame of [path] as rgb24, converted as the preview converts its
/// picture (task #67): the default conversion alone put the ProRes fixture's
/// frames 0.9 levels from their previews.
Future<List<Uint8List>> _rgbFrames(String path, int w, int h) async {
  final scale = await WorkerHarness.previewScaleFilterFor(path);
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-v', 'error', '-i', path, '-map', '0:v:0', '-vf', '$scale,format=rgb24', '-f', 'rawvideo', '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  final raw = Uint8List.fromList(r.stdout as List<int>);
  final size = w * h * 3;
  return [for (var i = 0; i + size <= raw.length; i += size) raw.sublist(i, i + size)];
}

Future<void> _check(
  String name,
  _Fixture fx,
  ProcessingPipeline pipeline,
  List<int> targets, {
  int? start,
  int? end,
  bool retime = false,
}) async {
  final film = await _fieldThumbs(
      ['-f', 'lavfi', '-i', 'testsrc2=size=${fx.width}x${fx.height}:rate=24000/1001,format=yuv420p'],
      count: fx.film + 2);
  final slots = [
    for (final s in await _fieldThumbs(['-i', fx.path], head: fx.slotFilters)) _name(s, film),
  ];

  final job = VideoJob(
    id: const Uuid().v4(),
    inputPath: fx.path,
    outputPath: '$_outDir/$name.mkv',
    processingPipeline: pipeline,
    qtgmcParameters: pipeline.deinterlace,
    encodingSettings: const EncodingSettings(
        codec: VideoCodec.ffv1, container: ContainerFormat.mkv, audioMode: AudioMode.none),
    detectedFieldOrder: pipeline.deinterlace.method == DeinterlaceMethod.ivtc
        ? FieldOrder.topFieldFirst
        : FieldOrder.progressive,
    inputWidth: fx.width,
    inputHeight: fx.height,
    inputPixelFormat: fx.pixFmt,
    inputFrameRate: 30000 / 1001,
    totalFrames: start == null ? fx.slots : end! - start + 1,
    startFrame: start,
    endFrame: end,
  );
  final r = await WorkerHarness.runJob(job.toJson(), label: name);
  expect(r.success, isTrue, reason: r.error);
  final encodeThumbs = await _fieldThumbs(['-i', r.outputPath!]);
  final encodeFilm = [for (final e in encodeThumbs) _name(e, film)];
  final encodeRgb = await _rgbFrames(r.outputPath!, fx.width, fx.height);
  final tops = [for (final e in encodeFilm) e[0]];

  final wrong = <String>[];
  for (final t in targets) {
    var subFrames = 1;
    for (var k = 0; k < subFrames; k++) {
      final pv = await WorkerHarness.runPreview(job.toJson(),
          frame: t, subFrame: k, label: '${name}_$t');
      expect(pv.success, isTrue, reason: pv.toString());
      if (retime) {
        subFrames = int.parse(
            RegExp(r'sub_frames=(\d+)').firstMatch(pv.logs)!.group(1)!);
      }
      final png = File(p.join(Directory.systemTemp.path,
          'vb_ivtc_${name}_${t}_$k.png'));
      await png.writeAsBytes(pv.png!);
      final pvThumb = (await _fieldThumbs(['-i', png.path]))[0];
      final pvRgb = await WorkerHarness.imageToRgb24(pv.png!, label: '${name}_$t');
      await png.delete();
      final pvFilm = _name(pvThumb, film);

      // The encode frame it is: nearest thumbnail, then measured.
      final order = List.generate(encodeThumbs.length, (j) => j)
        ..sort((a, b) => (_dist(pvThumb[0], encodeThumbs[a][0]) +
                _dist(pvThumb[1], encodeThumbs[a][1]))
            .compareTo(_dist(pvThumb[0], encodeThumbs[b][0]) +
                _dist(pvThumb[1], encodeThumbs[b][1])));
      final j = order.first;
      final mad = WorkerHarness.meanAbsDiff(pvRgb, encodeRgb[j]);

      final slot = slots[t].toSet();
      bool right;
      String want;
      if (retime) {
        // 23.976 -> 59.94 is x5/2: film frame f's outputs start at ceil(5f/2).
        final wanted = {for (final f in slot) (5 * f + 1) ~/ 2 + k};
        right = wanted.contains(j) && mad < _same;
        want = 'encode $wanted';
      } else if (slot.contains(pvFilm[0])) {
        right = mad < _same;
        want = 'film $slot';
      } else if (slot.any(tops.contains)) {
        right = false;
        want = 'film $slot';
      } else {
        // The encode kept none of the slot's film frames: the one before.
        final before = tops.where((f) => f < slot.reduce(math.min));
        final shown = before.isEmpty ? tops.reduce(math.min) : before.reduce(math.max);
        right = pvFilm[0] == shown && mad < _same;
        want = 'film $shown (the slot\'s was dropped)';
      }
      print('  ${right ? 'ok ' : 'BAD'} $name source $t'
          '${retime ? ' output $k/$subFrames' : ''}: preview film $pvFilm = '
          'encode $j (MAD ${mad.toStringAsFixed(2)}), want $want');
      if (!right) wrong.add('$t/$k');
    }
  }
  expect(wrong, isEmpty,
      reason: '$name: these previews are not the frame the encode shows '
          'for their source frame');
}

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(_outDir).create(recursive: true);
  });

  group('IVTC / Soft Telecine preview shows the frame the encode keeps (task #46)', () {
    test('IVTC at the minimum radius: start, every cycle phase, end', () async {
      await _check('ivtc_r5', _hard, const ProcessingPipeline(deinterlace: _ivtc),
          [0, 1, 2, 3, 4, 5, 6, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 85, 86, 87, 88, 89]);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('IVTC with a temporal pass widening the window to 12', () async {
      // The old preview was three film frames early here.
      await _check(
          'ivtc_r12',
          _hard,
          const ProcessingPipeline(
            deinterlace: _ivtc,
            deflicker: DeflickerParameters(enabled: true, method: DeflickerMethod.global, window: 12),
          ),
          [40, 41, 42, 43, 44]);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('IVTC trimmed: after the in-point and in the short last cycle', () async {
      // 23..70 is 48 frames: the encode's last cycle holds 3, and drops one.
      await _check('ivtc_trim', _hard, const ProcessingPipeline(deinterlace: _ivtc),
          [23, 24, 25, 26, 27, 66, 67, 68, 69, 70],
          start: 23, end: 70);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('IVTC on 10-bit ProRes (VFM metrics from an 8-bit copy)', () async {
      await _check('ivtc_prores10', _prores, const ProcessingPipeline(deinterlace: _ivtc),
          [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 25, 26, 27, 28, 29]);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('Soft Telecine at 29.97: DVD program stream and its MKV remux', () async {
      await _check('soft_vob', _dvdVob, const ProcessingPipeline(deinterlace: _soft),
          [0, 1, 2, 3, 4, 60, 61, 62, 63, 64]);
      // The VOB's last picture has no timestamp, so the tail is the MKV's.
      await _check('soft_mkv', _dvdMkv, const ProcessingPipeline(deinterlace: _soft),
          [143, 144, 145, 146, 147, 148, 149]);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('IVTC then 59.94: every output frame is the encode\'s', () async {
      // The preview used to convert its undecimated 29.97 at about x2.
      await _check(
          'ivtc_fps5994',
          _hard,
          const ProcessingPipeline(
            deinterlace: _ivtc,
            frameRate: FrameRateParameters(
                enabled: true, target: FrameRateTarget.ntsc5994, method: FrameRateMethod.flowFps),
          ),
          [40, 41, 42, 43, 44],
          retime: true);
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  // Task #65: in the 2026-11-16 nightly, decimating IVTC previews exited 1
  // on x86: vspipe R78 segfaulted in teardown, under its own frame callback,
  // because the preview read VDecimate's drop with get_frame() during script
  // evaluation and its one frame came back at once (2-3% of previews with
  // four running under CPU load; 0 run one at a time). It is read in the
  // graph now (test_259 keeps it there).
  //
  // Task #93: this test then failed 3-4 times in 36 on x86 with "The
  // VapourSynth script failed: see the traceback below" and no traceback.
  // The three previews here share one job (one job id, on purpose), and the
  // worker named a preview's script and decoded frames by the job id alone:
  // one preview deleted another's script before vspipe read it (vsscript's
  // "File reading exception", whose text the job error dropped), rewrote it
  // mid-read, or replaced its frames, which exited 0 with the wrong picture
  // (299 of the 442 that exited 0, under load on an M1). Each preview has its own scratch
  // directory now. So every concurrent preview must equal the same frame
  // previewed alone, exactly (previews are deterministic), and a failure
  // prints the worker's whole error.
  test('IVTC preview exits cleanly, run after run (tasks #65, #93)', () async {
    final job = VideoJob(
      id: const Uuid().v4(),
      inputPath: _prores.path,
      outputPath: '$_outDir/repeat.mkv',
      processingPipeline: const ProcessingPipeline(deinterlace: _ivtc),
      qtgmcParameters: _ivtc,
      encodingSettings: const EncodingSettings(
          codec: VideoCodec.ffv1, container: ContainerFormat.mkv, audioMode: AudioMode.none),
      detectedFieldOrder: FieldOrder.topFieldFirst,
      inputWidth: _prores.width,
      inputHeight: _prores.height,
      inputPixelFormat: _prores.pixFmt,
      inputFrameRate: 30000 / 1001,
      totalFrames: _prores.slots,
    ).toJson();
    final failures = <String>[];
    void fail(String what) {
      print('  FAILED $what');
      failures.add(what);
    }

    final frames = [for (var i = 0; i < 36; i++) (i * 7) % _prores.slots];

    // Each frame previewed alone: the picture every concurrent run must match.
    final reference = <int, Uint8List>{};
    for (final f in frames.toSet()) {
      final pv = await WorkerHarness.runPreview(job, frame: f, label: 'repeat_ref_$f');
      if (!pv.success) {
        fail('frame $f (alone): ${pv.error}\n${pv.workerError}');
        continue;
      }
      reference[f] = await WorkerHarness.imageToRgb24(pv.png!, label: 'repeat_ref_$f');
    }

    for (var i = 0; i < frames.length; i += 3) {
      final runs = await Future.wait([
        for (final f in frames.skip(i).take(3))
          WorkerHarness.runPreview(job, frame: f, label: 'repeat_$f')
              .then((pv) => (f, pv)),
      ]);
      for (final (f, pv) in runs) {
        if (!pv.success) {
          fail('frame $f: ${pv.error}\n${pv.workerError}');
          continue;
        }
        if (!pv.logs.contains('decimation dropped a frame at or before the target: ')) {
          fail('frame $f: no decimation report');
        }
        final ref = reference[f];
        if (ref == null) continue;
        final rgb = await WorkerHarness.imageToRgb24(pv.png!, label: 'repeat_$f');
        final mad = WorkerHarness.meanAbsDiff(rgb, ref);
        if (mad != 0) {
          fail('frame $f: not the picture it previews alone (MAD ${mad.toStringAsFixed(3)})');
        }
      }
    }
    expect(failures, isEmpty,
        reason: '${failures.length} of ${frames.length} previews:\n${failures.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
