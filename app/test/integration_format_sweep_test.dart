/// The generated format sweep (task #47): every pass × method × depth ×
/// subsampling × field flag × frame size, through the worker's preview.
///
/// The cases come from `support/format_sweep.dart` (enums, schemas, the
/// worker's `NATIVE_FORMATS`); `format_sweep_cases_test.dart` checks them.
/// One script template since task #42 means the preview runs exactly the
/// encode's pass code, so sweeping the preview covers the encode.
///
/// Per row, four checks:
///  1. **runs** — the preview exits 0 with a PNG. A failure is classified
///     (refused / script error / native crash) and fails, unless a
///     [knownFailures] entry names it, with the text it must match.
///  2. **depth** — the PNG keeps the source's depth (8 for an 8-bit source,
///     16 for a deeper one): every job uses Color Format "original",
///     documented as "source format, depth included".
///  3. **parity** (nightly) — each deeper row agrees with the 8-bit row of
///     the same subsampling, field and size, as RGB, *above the passthrough's
///     own difference*: swscale converts 8-bit 4:2:0 to RGB without chroma
///     interpolation and deeper formats with it, so passthrough alone differs
///     by ~4.5 levels on noisy 4:2:0 chroma.
///  4. **acts** — on at least one row the variant differs from the
///     passthrough preview, or the parity check proves nothing.
/// And, for the passes declared in [deltaOnly], an FFV1 encode whose
/// untouched samples must be bit-exact.
///
/// Groups and tags:
///  * `format sweep (push gate)` — untagged: four rotating tiny rows per CPU
///    variant plus one extra native format; checks 1, 2 and 4.
///  * `format sweep (nightly)` — tags `sweep`, `heavy`: the full tiny
///    product, 9/14-bit, every extra native format and three SD rows; all
///    four checks. Plus the add-on variants and the delta-only encodes.
///  * GPU variants — tags `gpu`, `sweep`, `heavy`.
/// Run the nightly part alone with `flutter test --tags sweep --exclude-tags gpu
/// test/integration_format_sweep_test.dart`. Rows run in parallel:
/// VAPOURBOX_SWEEP_JOBS sets how many (default half the cores). Every row's
/// outcome is written to Tests/TestOutput/format_sweep/results-*.json.
library;

// ignore_for_file: avoid_print — the sweep prints its tables to the test log.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:vapourbox/models/gpu_plugin_status.dart';

import 'support/format_sweep.dart';
import 'support/gpu_expectations.dart';
import 'support/worker_harness.dart';

// =============================================================================
// RUNNING ROWS
// =============================================================================

class _Pool {
  _Pool(this.size);
  final int size;
  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= size) {
      // The finishing task hands its slot straight over, so a new caller
      // arriving between the hand-over and the waiter resuming can't take it
      // too and run size + 1 at once.
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    } else {
      _running++;
    }
    try {
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}

final _pool = _Pool(sweepJobs);

/// How a row went.
class _Outcome {
  _Outcome(this.row, {required this.secs, this.png, this.errorClass, this.error});

  final SweepRow row;
  final double secs;
  final Uint8List? png;

  /// `refused`, `script error`, `native crash`, `timeout`.
  final String? errorClass;
  final String? error;
  Uint8List? _rgb;

  bool get ok => png != null;

  /// The PNG's IHDR: width, height, bit depth.
  int get width => ByteData.sublistView(png!, 16, 20).getUint32(0);
  int get height => ByteData.sublistView(png!, 20, 24).getUint32(0);
  int get bitDepth => png![24];

  Future<Uint8List> rgb() async =>
      _rgb ??= await WorkerHarness.imageToRgb24(png!, label: 'sweep');
}

String _classify(String logs, String? error) {
  if (error != null && error.contains('timed out')) return 'timeout';
  if (RegExp(r'Python exception|Traceback|vapoursynth\.Error|Error: Failed to retrieve frame')
      .hasMatch(logs)) {
    return 'script error';
  }
  if (RegExp(r'vspipe exited with|native crash|signal \d|SIG(SEGV|ILL|ABRT)').hasMatch(logs)) {
    return 'native crash';
  }
  return 'refused';
}

/// The most informative line of a failure: the exception, else the tail.
String _errorLine(String logs, String fallback) {
  final lines = logs.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  for (final l in lines.reversed) {
    if (RegExp(r"Error|error|refus|cannot|can't|failed").hasMatch(l) &&
        !l.startsWith('File ') &&
        !l.startsWith('PREVIEW_INFO')) {
      return l.length > 300 ? l.substring(0, 300) : l;
    }
  }
  return lines.isEmpty ? fallback : lines.last;
}

Future<_Outcome> _preview(String label, ProcessingPipelineFor pipelineFor, SweepRow row) =>
    _pool.run(() async {
      final fixture = await sweepFixture(row);
      final job = sweepJob(pipelineFor(row.size.width, row.size.height), row, fixture);
      final sw = Stopwatch()..start();
      final r = await WorkerHarness.runPreview(job.toJson(),
          frame: sweepPreviewFrame,
          label: label,
          timeout: const Duration(minutes: 6));
      final secs = sw.elapsedMilliseconds / 1000;
      if (r.success) return _Outcome(row, secs: secs, png: r.png);
      return _Outcome(row,
          secs: secs,
          errorClass: _classify(r.logs, r.error),
          error: _errorLine(r.logs, r.error ?? 'failed'));
    });

typedef ProcessingPipelineFor = dynamic Function(int width, int height);

final _passthroughs = <SweepRow, Future<_Outcome>>{};
Future<_Outcome> _passthrough(SweepRow row) => _passthroughs[row] ??=
    _preview('passthrough', (w, h) => sweepBasePipeline, row);

final _scheduled = <String, Map<SweepRow, Future<_Outcome>>>{};

Map<SweepRow, Future<_Outcome>> _schedule(SweepVariant v, List<SweepRow> rows) =>
    _scheduled['${v.id}|${rows.length}'] ??= {
      for (final row in rows) row: _preview(v.id.replaceAll('/', '_'), v.pipelineFor, row),
    };

/// Start [list][k]'s rows and the next few variants' (so the pool stays full
/// while one test checks its results), but not the whole list: a run
/// filtered to one test shouldn't render the rest.
Map<SweepRow, Future<_Outcome>> _scheduleAhead(
    List<SweepVariant> list, int k, List<SweepRow> Function(int i) rowsFor) {
  final ahead = (sweepJobs ~/ 3).clamp(1, 8);
  for (var j = k + 1; j < list.length && j <= k + ahead; j++) {
    _schedule(list[j], rowsFor(list[j].index));
  }
  return _schedule(list[k], rowsFor(list[k].index));
}

// =============================================================================
// CHECKS
// =============================================================================

final _results = <Map<String, Object?>>[];

/// Run the checks on one variant's rows; returns the failures as lines.
Future<List<String>> _check(SweepVariant v, Map<SweepRow, Future<_Outcome>> scheduled,
    {required bool parity, required String suite}) async {
  final failures = <String>[];
  final outcomes = <SweepRow, _Outcome>{};
  for (final MapEntry(key: row, value: f) in scheduled.entries) {
    outcomes[row] = await f;
  }

  void known(SweepRow row, SweepCheck check, bool failed, String? text, void Function() orElse) {
    final k = knownFailureFor(v.id, row, check);
    if (k == null) {
      if (failed) orElse();
      return;
    }
    if (!failed) {
      if (k.flaky) return;
      failures.add('${row.key}: known failure (#${k.task}, ${k.finding}) now passes '
          '${check.name}; remove its knownFailures entry');
    } else if (!(text ?? '').contains(k.error)) {
      failures.add('${row.key}: fails ${check.name} differently from its known '
          'failure (#${k.task}: "${k.error}"): $text');
    }
  }

  final rowDiffs = <SweepRow, Map<String, Object?>>{};
  for (final o in outcomes.values) {
    final row = o.row;
    final record = <String, Object?>{
      'suite': suite,
      'variant': v.id,
      'row': row.key,
      'ok': o.ok,
      'secs': o.secs,
      if (!o.ok) 'errorClass': o.errorClass,
      if (!o.ok) 'error': o.error,
    };
    rowDiffs[row] = record;
    _results.add(record);

    // 1. runs
    known(row, SweepCheck.runs, !o.ok, o.error,
        () => failures.add('${row.key}: ${o.errorClass}: ${o.error}'));
    if (!o.ok) continue;

    // 2. depth
    final want = row.format.depth == 8 ? 8 : 16;
    record['pngDepth'] = o.bitDepth;
    known(row, SweepCheck.depth, o.bitDepth != want, 'PNG is ${o.bitDepth}-bit',
        () => failures.add('${row.key}: the preview is ${o.bitDepth}-bit, not $want: '
            'Color Format "original" must keep the source\'s depth'));
  }

  // 4. acts
  var acts = false;
  for (final o in outcomes.values.where((o) => o.ok)) {
    final ref = await _passthrough(o.row);
    if (!ref.ok) {
      failures.add('${o.row.key}: the passthrough itself failed: ${ref.error}');
      continue;
    }
    final a = await o.rgb(), b = await ref.rgb();
    final d = a.length == b.length ? WorkerHarness.meanAbsDiff(a, b) : double.infinity;
    rowDiffs[o.row]!['vsPassthrough'] = d.isFinite ? d : 'size ${o.width}x${o.height}';
    if (d > 0.05) acts = true;
  }
  final inert = inertOnFixture[v.id];
  if (outcomes.values.any((o) => o.ok)) {
    if (!acts && inert == null) {
      failures.add('the variant changed nothing on any row, so its other checks prove '
          'nothing: give it an actuation override, or degrade the master so it '
          'finds work');
    } else if (acts && inert != null) {
      // Not a failure: some are borderline (Descale's detail protection
      // keeps nearly every pixel, not all). Said, so the entry can go.
      print('  ${v.id} acts on this fixture although allowlisted as inert ($inert)');
    }
  }

  // 3. parity
  if (parity) {
    final tolerance = parityToleranceFor(v.id);
    for (final o in outcomes.values.where((o) => o.ok && o.row.format.depth > 8)) {
      if (!o.row.format.inProduct) continue;
      final eight = outcomes[o.row.at(SweepFormat.of(o.row.format.subsampling, 8))];
      if (eight == null || !eight.ok) continue;
      final ref8 = await _passthrough(eight.row), refD = await _passthrough(o.row);
      if (!ref8.ok || !refD.ok) continue;
      final a = await o.rgb(), b = await eight.rgb();
      String? failure;
      double? excess;
      if (a.length != b.length) {
        failure = '${o.width}x${o.height} at ${o.row.format.depth}-bit, '
            '${eight.width}x${eight.height} at 8-bit';
      } else {
        final base = WorkerHarness.meanAbsDiff(await ref8.rgb(), await refD.rgb());
        excess = WorkerHarness.meanAbsDiff(a, b) - base;
        rowDiffs[o.row]!['parityExcess'] = excess;
        if (excess >= tolerance) {
          failure = '${excess.toStringAsFixed(2)} levels from 8-bit beyond the '
              'passthrough\'s ${base.toStringAsFixed(2)} (tolerance $tolerance)';
        }
      }
      known(o.row, SweepCheck.parity, failure != null, failure,
          () => failures.add('${o.row.key}: parity: $failure. A parameter in 8-bit '
              'levels is probably reaching the filter unscaled'));
    }
  }
  return failures;
}

void _report(SweepVariant v, List<String> failures, int rows) {
  if (failures.isEmpty) {
    print('  ${v.id}: $rows rows ok');
    return;
  }
  fail('${v.id}: ${failures.length} failure(s) over $rows rows:\n  ${failures.join('\n  ')}');
}

/// KNLMeansCL's OpenCL device, probed once (null: none here).
Future<String?>? _knlmProbe;
Future<String?> _knlmDevice() => _knlmProbe ??= () async {
      final probe = await Process.run(WorkerHarness.workerPath, ['--probe-opencl'],
          environment: WorkerHarness.workerEnv,
          workingDirectory: File(WorkerHarness.workerPath).parent.path);
      return RegExp(r'"knlmDevice":"([^"]+)"').firstMatch(probe.stdout.toString())?.group(1);
    }();

Future<bool> _skipWithoutKnlm(SweepVariant v) async {
  if (!v.needsKnlmDevice || await _knlmDevice() != null) return false;
  markTestSkipped('${v.id}: no OpenCL device KNLMeansCL can use here');
  return true;
}

// =============================================================================
// DELTA-ONLY: bit-exact outside a pass's changes
// =============================================================================

/// Plane [plane] of frame [n] as rows of samples.
List<List<int>> _plane(List<int> samples, SweepFormat f, int w, int h, int n, int plane) {
  final d = planeDims(f, w, h);
  final frame = d.lw * d.lh + 2 * d.cw * d.ch;
  final pw = plane == 0 ? d.lw : d.cw, ph = plane == 0 ? d.lh : d.ch;
  final start = n * frame + (plane == 0 ? 0 : d.lw * d.lh + (plane - 1) * d.cw * d.ch);
  return [
    for (var y = 0; y < ph; y++) samples.sublist(start + y * pw, start + (y + 1) * pw),
  ];
}

/// An FFV1 encode of [row]: its path, or `encode failed: …`.
Future<String> _encode(String label, ProcessingPipelineFor pipelineFor, SweepRow row) =>
    _pool.run(() async {
      final out = p.join(sweepOutDir, 'delta', '${label}_${row.key.replaceAll('/', '_')}.mkv');
      await Directory(p.dirname(out)).create(recursive: true);
      final job = sweepJob(pipelineFor(row.size.width, row.size.height), row,
          await sweepFixture(row), outputPath: out);
      final r = await WorkerHarness.runJob(job.toJson(), label: label);
      return r.success ? out : 'encode failed: ${r.error}';
    });

Future<List<String>> _deltaCheck(SweepVariant v, DeltaOnly decl, SweepRow row) async {
  final w = row.size.width, h = row.size.height;
  final f = row.format;
  final outPath = await _encode(v.id.replaceAll('/', '_'), v.pipelineFor, row);
  if (outPath.startsWith('encode failed')) return ['${row.key}: $outPath'];
  final probe = await WorkerHarness.firstStream(outPath,
      selector: 'v:0', entries: ['pix_fmt', 'width', 'height']);
  final outFmt = probe?['pix_fmt'] as String?;
  final ow = probe?['width'] as int? ?? 0, oh = probe?['height'] as int? ?? 0;
  if (outFmt != f.pipedName) {
    if (decl is ExactGeometry && decl.kind == GeometryKind.rotation) {
      print('  ${v.id} ${row.key}: output is $outFmt, not ${f.pipedName}; '
          'a quarter turn of 4:2:2 is a conversion, not a permutation');
      return [];
    }
    return ['${row.key}: the encode is $outFmt, not the source\'s ${f.pipedName}'];
  }
  final src = (await decodeRaw(await sweepFixture(row), f.pipedName));
  final srcS = samplesOf(src, f.bytesPerSample);
  final outS = samplesOf(await decodeRaw(outPath, f.pipedName), f.bytesPerSample);
  final dims = planeDims(f, w, h);
  final frames = srcS.length ~/ (dims.lw * dims.lh + 2 * dims.cw * dims.ch);
  final odims = planeDims(f, ow, oh);
  final oframes = outS.length ~/ (odims.lw * odims.lh + 2 * odims.cw * odims.ch);
  if (oframes != frames) return ['${row.key}: $oframes frames out of $frames'];
  final failures = <String>[];
  final (sx, sy) = f.chromaShift;

  void compare(String what, int Function(int n, int plane, int x, int y)? srcAt,
      {bool Function(int plane, int x, int y)? only}) {
    var bad = 0, total = 0;
    for (var n = 0; n < frames; n++) {
      for (var plane = 0; plane < 3; plane++) {
        final o = _plane(outS, f, ow, oh, n, plane);
        for (var y = 0; y < o.length; y++) {
          for (var x = 0; x < o[y].length; x++) {
            if (only != null && !only(plane, x, y)) continue;
            total++;
            if (o[y][x] != srcAt!(n, plane, x, y)) bad++;
          }
        }
      }
    }
    if (bad > 0) failures.add('${row.key}: $what: $bad of $total samples differ');
  }

  final srcPlanes = {
    for (var n = 0; n < frames; n++)
      for (var plane = 0; plane < 3; plane++) n * 3 + plane: _plane(srcS, f, w, h, n, plane),
  };
  int srcAt(int n, int plane, int x, int y) => srcPlanes[n * 3 + plane]![y][x];

  switch (decl) {
    case UntouchedPlanes(:final planes):
      if (ow != w || oh != h) return ['${row.key}: ${ow}x$oh out of ${w}x$h'];
      compare('planes $planes not bit-exact', srcAt, only: (plane, x, y) => planes.contains(plane));
    case WorkDepth(:final workDepth):
      if (f.pipedDepth <= workDepth) return []; // the plugin runs natively
      final low = row.at(SweepFormat.of(f.subsampling, workDepth));
      final lowOut = await _encode('${v.id.replaceAll('/', '_')}_w$workDepth', v.pipelineFor, low);
      if (lowOut.startsWith('encode failed')) return ['${low.key}: $lowOut'];
      final lf = low.format;
      final lowSrc = samplesOf(await decodeRaw(await sweepFixture(low), lf.pipedName), lf.bytesPerSample);
      final lowRes = samplesOf(await decodeRaw(lowOut, lf.pipedName), lf.bytesPerSample);
      final shift = f.pipedDepth - workDepth, half = 1 << (shift - 1);
      final maxV = (1 << f.pipedDepth) - 1;
      var untouched = 0, changedSet = 0, far = 0, changed = 0;
      for (var i = 0; i < srcS.length; i++) {
        final changedLow = lowRes[i] != lowSrc[i];
        final changedDeep = outS[i] != srcS[i];
        if (changedLow) changed++;
        final clipped = outS[i] == 0 || outS[i] == maxV;
        if (!changedLow && changedDeep) untouched++;
        if (changedLow != changedDeep && !clipped) changedSet++;
        if (!clipped && (outS[i] - (lowRes[i] << shift)).abs() > half) far++;
      }
      if (changed == 0) failures.add('${row.key}: the filter changed nothing at $workDepth-bit');
      if (untouched > 0) {
        failures.add('${row.key}: $untouched samples the $workDepth-bit run left alone '
            'changed at ${f.pipedDepth}-bit (whole-result up-conversion?)');
      }
      if (changedSet > 0) {
        failures.add('${row.key}: the changed set differs from the $workDepth-bit run\'s in $changedSet samples');
      }
      if (far > 0) {
        failures.add('${row.key}: $far samples further than half a $workDepth-bit level '
            'from the $workDepth-bit result');
      }
    case ExactGeometry(:final kind):
      switch (kind) {
        case GeometryKind.rotation:
          final rot = v.values['rotation'];
          // A quarter turn of 4:2:2 (or 4:1:1) chroma is a conversion, not a
          // permutation: check its luma only.
          final lumaOnly = rot != 'rotate180' && sx != sy;
          int at(int n, int plane, int x, int y) {
            final s = srcPlanes[n * 3 + plane]!;
            final sh = s.length, swd = s[0].length;
            return switch (rot) {
              'cw90' => s[sh - 1 - x][y],
              'ccw90' => s[x][swd - 1 - y],
              _ => s[sh - 1 - y][swd - 1 - x],
            };
          }
          compare('not an exact $rot of the source', at,
              only: lumaOnly ? (plane, x, y) => plane == 0 : null);
        case GeometryKind.crop:
          final o = actuationOverrides['crop_resize/cropEnabled=true']!.values(w, h);
          final l = o['cropLeft'] as int, t = o['cropTop'] as int;
          compare('not an exact crop', (n, plane, x, y) => plane == 0
              ? srcAt(n, 0, x + l, y + t)
              : srcAt(n, plane, x + l ~/ sx, y + t ~/ sy));
        case GeometryKind.edgeRepairInterior:
          final o = actuationOverrides['edge_repair']!.values(w, h);
          final l = o['left'] as int, r = o['right'] as int;
          final t = o['top'] as int, b = o['bottom'] as int;
          bool inside(int plane, int x, int y) {
            final dx = plane == 0 ? 1 : sx, dy = plane == 0 ? 1 : sy;
            final pw = plane == 0 ? w : dims.cw, ph = plane == 0 ? h : dims.ch;
            return x >= (l + dx - 1) ~/ dx &&
                x < pw - (r + dx - 1) ~/ dx &&
                y >= (t + dy - 1) ~/ dy &&
                y < ph - (b + dy - 1) ~/ dy;
          }
          compare('the interior changed', srcAt, only: inside);
        case GeometryKind.bordersInside:
          // Find where the picture sits (centred, snapped to the chroma and
          // field grids), then check every sample of it.
          final y0 = _plane(outS, f, ow, oh, 0, 0), s0 = srcPlanes[0]!;
          (int, int)? at;
          search:
          for (var oy = 0; oy <= oh - h; oy++) {
            for (var ox = 0; ox <= ow - w; ox++) {
              var match = true;
              for (var y = 0; y < h && match; y += 3) {
                for (var x = 0; x < w; x += 3) {
                  if (y0[y + oy][x + ox] != s0[y][x]) {
                    match = false;
                    break;
                  }
                }
              }
              if (match) {
                at = (ox, oy);
                break search;
              }
            }
          }
          if (at == null) return ['${row.key}: the picture is nowhere inside the bars unchanged'];
          final (ox, oy) = at;
          compare('the picture inside the bars changed', (n, plane, x, y) => plane == 0
              ? srcAt(n, 0, x - ox, y - oy)
              : srcAt(n, plane, x - ox ~/ sx, y - oy ~/ sy),
              only: (plane, x, y) => plane == 0
                  ? x >= ox && x < ox + w && y >= oy && y < oy + h
                  : x >= ox ~/ sx && x < (ox + w) ~/ sx && y >= oy ~/ sy && y < (oy + h) ~/ sy);
      }
  }
  return failures;
}

/// Install an add-on the way the app does: AnimeJaNai keeps its own
/// installer, every other one is a manifest add-on.
Future<void> _ensureAddon(String id) =>
    id == 'animejanai' ? WorkerHarness.ensureAnimeJanai() : WorkerHarness.ensureAddon(id);

// =============================================================================

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(sweepOutDir).create(recursive: true);
    print('format sweep: ${sweepVariants.length} variants, $sweepJobs rows at once');
  });

  tearDownAll(() async {
    if (_results.isEmpty) return;
    final file = File(p.join(sweepOutDir,
        'results-${DateTime.now().toIso8601String().replaceAll(':', '-')}.json'));
    await file.writeAsString(const JsonEncoder.withIndent(' ').convert(_results));
    final failed = _results.where((r) => r['ok'] != true).length;
    final secs = _results.fold<double>(0, (s, r) => s + (r['secs'] as double));
    print('format sweep: ${_results.length} rows, $failed failed, '
        '${secs.toStringAsFixed(0)} s of previews -> ${file.path}');
  });

  final cpu = sweepVariants.where((v) => v.runsAnywhere).toList();

  group('format sweep (push gate)', () {
    for (var k = 0; k < cpu.length; k++) {
      final v = cpu[k];
      test(v.id, () async {
        if (await _skipWithoutKnlm(v)) return;
        final rows = gateRows(v.index);
        final failures = await _check(v, _scheduleAhead(cpu, k, gateRows),
            parity: false, suite: 'gate');
        _report(v, failures, rows.length);
      }, timeout: const Timeout(Duration(minutes: 30)));
    }
  });

  group('format sweep (nightly)', () {
    for (var k = 0; k < cpu.length; k++) {
      final v = cpu[k];
      test(v.id, () async {
        if (await _skipWithoutKnlm(v)) return;
        final rows = nightlyRows(v.index);
        final failures = await _check(v, _scheduleAhead(cpu, k, nightlyRows),
            parity: true, suite: 'nightly');
        _report(v, failures, rows.length);
      }, tags: ['sweep', 'heavy'], timeout: const Timeout(Duration(minutes: 60)));
    }
  });

  group('format sweep: add-on variants (nightly)', () {
    for (final v in sweepVariants.where((v) => v.gpu == null && v.addons.isNotEmpty)) {
      test(v.id, () async {
        for (final id in v.addons) {
          await _ensureAddon(id);
        }
        final rows = gateRows(v.index);
        final failures =
            await _check(v, _schedule(v, rows), parity: false, suite: 'addon');
        _report(v, failures, rows.length);
      }, tags: ['sweep', 'heavy'], timeout: const Timeout(Duration(minutes: 60)));
    }
  });

  group('format sweep: GPU variants', () {
    for (final v in sweepVariants.where((v) => v.gpu != null)) {
      test(v.id, () async {
        final flag = v.gpu == GpuPlugin.rife ? '--probe-rife' : '--probe-upscale';
        if (!await requireGpuPlugin(flag)) return;
        for (final id in v.addons) {
          await _ensureAddon(id);
        }
        final rows = gateRows(v.index);
        final failures = await _check(v, _schedule(v, rows), parity: false, suite: 'gpu');
        _report(v, failures, rows.length);
      }, tags: ['gpu', 'sweep', 'heavy'], timeout: const Timeout(Duration(minutes: 60)));
    }
  });

  group('format sweep: bit-exact outside a delta-only pass (nightly)', () {
    for (final MapEntry(key: id, value: decl) in deltaOnly.entries) {
      final v = sweepVariants.firstWhere((v) => v.id == id);
      test('$id (${decl.reason})', () async {
        if (v.gpu != null) {
          markTestSkipped('${v.id} needs a GPU; the GPU group covers it');
          return;
        }
        for (final a in v.addons) {
          await _ensureAddon(a);
        }
        final rows = gateRows(v.index).where((r) => r.format.inProduct).toList();
        final failures = <String>[];
        for (final batch in await Future.wait([
          for (final row in rows)
            _deltaCheck(v, decl, row).then((f) {
              // A row that fails to run at all is the preview sweep's
              // finding; it is filed there, not again here.
              if (knownFailureFor(v.id, row, SweepCheck.runs) != null) return <String>[];
              final k = knownFailureFor(v.id, row, SweepCheck.bitExact);
              if (k == null) return f;
              if (f.isEmpty) {
                return k.flaky
                    ? <String>[]
                    : ['${row.key}: known failure (#${k.task}, ${k.finding}) now '
                        'passes; remove its knownFailures entry'];
              }
              return f.every((l) => l.contains(k.error))
                  ? <String>[]
                  : ['${row.key}: fails differently from its known failure '
                      '(#${k.task}): ${f.join('; ')}'];
            }),
        ])) {
          failures.addAll(batch);
        }
        _report(v, failures, rows.length);
      }, tags: ['sweep', 'heavy'], timeout: const Timeout(Duration(minutes: 60)));
    }
  });
}
