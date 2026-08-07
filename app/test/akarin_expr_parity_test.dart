// akarin.Expr must be a drop-in replacement for std.Expr.
//
// VapourSynth's own Expr JIT is wrapped in `#ifdef VS_TARGET_CPU_X86`, so on ARM
// the whole bytecode program is walked once per pixel by ExprInterpreter::eval().
// Measured on an M1, Expr costs 550-640 CPU-seconds in a QTGMC Slow graph against
// the interpolator's 30 — it dominates everything else, which is why havsfunc's
// patch 7 and the templates' `_expr()` helper route through akarin's LLVM JIT.
//
// That routing is only safe while the two agree pixel-for-pixel, and "it ran" is
// not evidence of that: a wrong Expr still produces a picture. So this test
// collects the expressions havsfunc *actually generates* at runtime — across
// every QTGMC preset and a spread of other entry points — and compares both
// implementations over inputs covering the full 0-255 range.
//
// Collecting at runtime rather than checking in a fixed list matters: the corpus
// is mostly f-strings with computed thresholds, so a static scan finds only 11 of
// the 46 real expressions.
//
// Skipped on macos-x64, which deliberately ships no akarin (its only wheel is
// macosx_14_0 and that bundle targets 12.0, issue #39).
@Tags(['heavy'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'support/worker_harness.dart';

/// Collects every distinct Expr call havsfunc makes, then runs each one through
/// both implementations and reports the worst per-expression difference.
const String _parityScript = r'''
import json, sys
import vapoursynth as vs
core = vs.core

if not hasattr(core, 'akarin'):
    print("AKARIN_ABSENT", file=sys.stderr)
    core.std.BlankClip(width=16, height=16, length=1).set_output()
    raise SystemExit(0)

import havsfunc as haf

# --- 1. collect the real corpus -------------------------------------------
seen = []


class _Rec:
    def __init__(self, real):
        self._r = real

    def __getattr__(self, n):
        if n != 'Expr':
            return getattr(self._r, n)

        def rec(clips, expr, *a, **k):
            cl = clips[0] if isinstance(clips, (list, tuple)) else clips
            seen.append({
                'expr': list(expr) if isinstance(expr, (list, tuple)) else [expr],
                'fmt': cl.format.name,
                'n': len(clips) if isinstance(clips, (list, tuple)) else 1,
            })
            return self._r.Expr(clips, expr, *a, **k)

        return rec


class _RecCore:
    def __init__(self, c):
        self._c = c

    def __getattr__(self, n):
        return _Rec(self._c.std) if n == 'std' else getattr(self._c, n)


# havsfunc may already be wrapped by patch 7; record against the real std either way.
_real = getattr(haf.core, '_core', haf.core)
haf.core = _RecCore(_real)

src = core.std.SetFieldBased(
    core.std.BlankClip(width=720, height=576, format=vs.YUV420P8, length=4,
                       color=[110, 120, 140]), 2)

for preset in ['Placebo', 'Very Slow', 'Slower', 'Slow', 'Medium', 'Fast',
               'Faster', 'Very Fast', 'Super Fast', 'Ultra Fast', 'Draft']:
    try:
        haf.QTGMC(src, Preset=preset, TFF=True)
    except Exception:
        pass
for kw in [dict(SourceMatch=3), dict(NoiseProcess=1), dict(NoiseProcess=2),
           dict(NoiseProcess=2, NoiseRestore=0.7), dict(Sharpness=1.0, SMode=2),
           dict(Lossless=2)]:
    try:
        haf.QTGMC(src, Preset='Slow', TFF=True, **kw)
    except Exception:
        pass
for fn in ['daa', 'santiag', 'LSFmod', 'DeHalo_alpha', 'FineDehalo', 'SMDegrain',
           'Deblock_QED', 'EdgeCleaner', 'YAHR']:
    try:
        getattr(haf, fn)(src)
    except Exception:
        pass

uniq = {}
for s in seen:
    uniq[(tuple(s['expr']), s['fmt'], s['n'])] = s
corpus = list(uniq.values())

# --- 2. compare both implementations --------------------------------------
FMT = {'YUV420P8': vs.YUV420P8, 'Gray8': vs.GRAY8}


def grid(fmt, seed):
    # 16x16 tiles of 16x16 px, so every luma value 0..255 is present.
    rows = []
    for r in range(16):
        cells = []
        for c in range(16):
            v = (r * 16 + c + seed * 37) % 256
            col = [v] if fmt == vs.GRAY8 else [v, (v * 5 + seed * 11) % 256,
                                               (v * 3 + seed * 29) % 256]
            cells.append(core.std.BlankClip(width=16, height=16, format=fmt,
                                            length=1, color=col))
        rows.append(core.std.StackHorizontal(cells))
    return core.std.StackVertical(rows)


cache, worst, differing, errors = {}, 0.0, [], []
for item in corpus:
    f = FMT.get(item['fmt'])
    if f is None:
        continue
    key = (item['fmt'], item['n'])
    if key not in cache:
        cache[key] = [grid(f, s) for s in range(item['n'])]
    clips = cache[key]
    arg = clips if len(clips) > 1 else clips[0]
    try:
        a = core.std.Expr(arg, item['expr'])
        b = core.akarin.Expr(arg, item['expr'])
        d = core.std.Expr([a, b], ['x y - abs'] * a.format.num_planes)
        mx = 0.0
        for p in range(a.format.num_planes):
            fr = core.std.PlaneStats(d, plane=p).get_frame(0)
            mx = max(mx, float(fr.props['PlaneStatsMax']))
        worst = max(worst, mx)
        if mx > 0:
            differing.append({'max': mx, 'expr': item['expr']})
    except Exception as e:
        errors.append({'err': f"{type(e).__name__}: {e}", 'expr': item['expr']})

print("PARITY_JSON:" + json.dumps({
    'corpus': len(corpus),
    'worst': worst,
    'differing': differing,
    'errors': errors,
}), file=sys.stderr)

core.std.BlankClip(width=16, height=16, length=1).set_output()
''';

void main() {
  group('akarin.Expr parity with std.Expr', () {
    late String vspipePath;
    late String depsDir;

    setUpAll(() async {
      await WorkerHarness.ensureReady();
      depsDir = WorkerHarness.depsDir;
      vspipePath = path.join(
        depsDir,
        'vapoursynth',
        Platform.isWindows
            ? path.join('Lib', 'site-packages', 'vapoursynth', 'vspipe.exe')
            : 'vspipe',
      );
    });

    test('matches over every expression havsfunc generates', () async {
      final scriptFile = File(
        path.join(Directory.systemTemp.path, 'akarin_parity.vpy'),
      );
      await scriptFile.writeAsString(_parityScript);
      addTearDown(() async {
        if (await scriptFile.exists()) await scriptFile.delete();
      });

      final env = Platform.isWindows
          ? {
              'PYTHONHOME': path.join(depsDir, 'vapoursynth'),
              'PYTHONPATH':
                  path.join(depsDir, 'vapoursynth', 'Lib', 'site-packages'),
              'VAPOURSYNTH_EXTRA_PLUGIN_PATH':
                  path.join(depsDir, 'vapoursynth', 'vs-plugins'),
            }
          : {'PYTHONPATH': path.join(depsDir, 'python-packages')};

      final result = await Process.run(
        vspipePath,
        ['-o', '0', scriptFile.path, Platform.isWindows ? 'NUL' : '/dev/null'],
        environment: env,
      );
      final stderr = result.stderr.toString();

      if (stderr.contains('AKARIN_ABSENT')) {
        // macos-x64 ships no akarin by design; std.Expr is used there unchanged.
        markTestSkipped('akarin not in this bundle (expected on macos-x64)');
        return;
      }

      expect(result.exitCode, 0, reason: 'vspipe failed:\n$stderr');
      final line = LineSplitter.split(stderr)
          .firstWhere((l) => l.startsWith('PARITY_JSON:'), orElse: () => '');
      expect(line, isNotEmpty, reason: 'no parity result produced:\n$stderr');

      final r =
          jsonDecode(line.substring('PARITY_JSON:'.length)) as Map<String, dynamic>;
      final corpus = r['corpus'] as int;
      final worst = (r['worst'] as num).toDouble();
      final differing = r['differing'] as List<dynamic>;
      final errors = r['errors'] as List<dynamic>;

      // A regex over havsfunc finds only 11 expressions; the rest are f-strings
      // built at call time. If this collapses, the test has stopped covering the
      // corpus and would pass vacuously.
      expect(corpus, greaterThanOrEqualTo(40),
          reason: 'collected only $corpus expressions — the collector broke');

      expect(errors, isEmpty,
          reason: 'akarin rejected expressions std.Expr accepts: $errors');

      // One known difference: the DeHalo_alpha/FineDehalo edge-MASK scale
      // 'x {thmi} - {i} / 255 *' puts a single input value on an exact .5 tie,
      // where std.Expr rounds half-to-even and akarin rounds down. That is one
      // level in a mask. Anything larger is a real behavioural divergence, and
      // anything *additional* means akarin changed its rounding somewhere else.
      expect(worst, lessThanOrEqualTo(1.0),
          reason: 'akarin differs from std.Expr by $worst levels: $differing');
      expect(differing.length, lessThanOrEqualTo(1),
          reason: 'more expressions differ than the one known .5 tie: $differing');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
