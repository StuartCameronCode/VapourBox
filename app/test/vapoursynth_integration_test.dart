// End-to-end tests that verify VapourSynth plugins work correctly.
// These tests run actual vspipe commands to ensure all filters function.
// Uses FFmpeg to generate a test video, piped through pipe_source.py.
//
// Run with: flutter test test/vapoursynth_integration_test.dart
// Note: Requires platform-specific deps to be present with all plugins.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;


void main() {
  late String depsDir;
  late String depsPlatform;
  late String vspipePath;
  late String ffmpegPath;
  late String pipeSourceDir;
  late String testRawPath;

  setUpAll(() async {
    // Find the deps directory relative to the test file
    final scriptDir = Directory.current.path;

    // Determine platform-specific deps folder
    final String vspipeExe;
    final String ffmpegExe;
    if (Platform.isWindows) {
      depsPlatform = 'windows-x64';
      vspipeExe = r'Lib\site-packages\vapoursynth\vspipe.exe';
      ffmpegExe = 'ffmpeg.exe';
    } else if (Platform.isMacOS) {
      // Check architecture
      final archResult = await Process.run('uname', ['-m']);
      final arch = archResult.stdout.toString().trim();
      depsPlatform = arch == 'arm64' ? 'macos-arm64' : 'macos-x64';
      vspipeExe = 'vspipe';
      ffmpegExe = 'ffmpeg';
    } else if (Platform.isLinux) {
      final archResult = await Process.run('uname', ['-m']);
      final arch = archResult.stdout.toString().trim();
      depsPlatform = arch == 'aarch64' ? 'linux-arm64' : 'linux-x64';
      vspipeExe = 'vspipe';
      ffmpegExe = 'ffmpeg';
    } else {
      throw UnsupportedError(
          'Unsupported platform: ${Platform.operatingSystem}');
    }

    // $VAPOURBOX_DEPS_DIR first, as the worker harness and the app honour it —
    // without that, a run pointed at an unreleased bundle silently tested
    // whatever happened to be in the repo's deps/ instead.
    final override = Platform.environment['VAPOURBOX_DEPS_DIR'];
    final possibleDepsPaths = [
      if (override != null && override.isNotEmpty) override,
      path.join(scriptDir, '..', 'deps', depsPlatform),
      path.join(scriptDir, 'deps', depsPlatform),
    ];

    for (final p in possibleDepsPaths) {
      if (await Directory(p).exists()) {
        depsDir = p;
        break;
      }
    }

    vspipePath = path.join(depsDir, 'vapoursynth', vspipeExe);
    ffmpegPath = path.join(depsDir, 'ffmpeg', ffmpegExe);

    // Find pipe_source.py in worker/templates
    final possibleTemplatePaths = [
      path.join(scriptDir, '..', 'worker', 'templates'),
      path.join(scriptDir, 'worker', 'templates'),
    ];
    for (final p in possibleTemplatePaths) {
      if (await File(path.join(p, 'pipe_source.py')).exists()) {
        pipeSourceDir = p;
        break;
      }
    }

    // Generate a small test video as raw YUV420P using FFmpeg's testsrc2
    testRawPath = path.join(
      Directory.systemTemp.path,
      'vapourbox_test_video.raw',
    );
    final genResult = await Process.run(ffmpegPath, [
      '-f', 'lavfi',
      '-i', 'testsrc2=duration=0.4:size=64x64:rate=25',
      '-f', 'rawvideo',
      '-pix_fmt', 'yuv420p',
      '-y', testRawPath,
    ]);
    expect(genResult.exitCode, 0,
        reason: 'Failed to generate test video: ${genResult.stderr}');
  });

  tearDownAll(() async {
    // Clean up the test raw file
    final rawFile = File(testRawPath);
    if (await rawFile.exists()) {
      await rawFile.delete();
    }
  });

  group('VapourSynth Plugin Loading', () {
    test('vspipe executes successfully', () async {
      final result = await Process.run(vspipePath, ['--version']);
      expect(result.exitCode, 0);
      expect(result.stdout.toString(), contains('VapourSynth'));
    });

    // Task #68: R78's vspipe counts a frame done before it writes it, so its
    // main thread could free the script under the last frame's callback
    // (SIGSEGV after the last frame, intermittently; tasks #65 and #66).
    // Every download-deps-* script builds vspipe with
    // patches/vapoursynth-r78-vspipe-frame-done-count.patch, upstream's fix
    // (4ff3f8a0, R80), whose --version line says so. The race itself is too
    // rare to test for on every push; this checks the bundle has the fix.
    // docs/reports/task-68-vspipe-teardown-backport.
    test('vspipe carries the frame-done count fix (task #68)', () async {
      if (_depsVersionAtMost(depsDir, [1, 17])) {
        markTestSkipped("deps <= 1.17.x ship R78's unpatched vspipe "
            '(task #68); enforced from deps 1.18.0');
        return;
      }
      final result = await Process.run(vspipePath, ['--version']);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(),
          contains('VapourBox patch: vspipe frame-done count (task #68)'));
    });

    test('all required plugins load', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

# Every namespace the templates call directly, plus the ones havsfunc reaches
# for on the paths the app exposes. A plugin missing here is a FILTER that fails
# at job time with "No attribute with the name <ns> exists" — which is what an
# incomplete or stale deps install looks like from the user's side. `zsmooth`
# (Chroma Denoise / CCD) was once missed here, so a bundle without it passed the
# suite and failed the filter. Since the x86 bundles split by CPU tier (#92)
# each ships exactly one zsmooth build, autoloaded like the rest.
required = ['std', 'resize', 'mv', 'znedi3', 'eedi3m', 'fmtc',
            'dfttest', 'neo_f3kdb', 'cas', 'dctf', 'deblock', 'rgvs',
            'ctmf', 'warp', 'misc', 'grain', 'tcanny',
            'descratch', 'vivtc', 'ttmpsm', 'tmedian',
            'fft3dfilter', 'flux', 'bifrost', 'retinex',
            'bwdif', 'fb', 'removedirt', 'dedot', 'lghost', 'zsmooth',
            'vszip', 'bm3d', 'descale', 'sangnom']

# A namespace is not a version: vszip 22.1.0 (deps <= 1.15.0) has CLAHE but no
# NLMeans, which Noise Reduction's NLMeans method and the vine dehalo need. A
# stale bundle would pass the namespace check and fail those jobs.
required_functions = [('vszip', 'NLMeans'), ('vszip', 'CLAHE')]

# On ARM, `nnedi3` is load-bearing and `znedi3` is only the fallback: znedi3's
# SIMD is x86-only, so the ARM bundles build it scalar and both the templates'
# _nnedi3() helper and havsfunc's patched _nnedi3_impl() pick nnedi3 instead
# (6.3x faster, same network and weights). A bundle that dropped nnedi3 would
# still deinterlace correctly — it would just silently be slow again, which is
# exactly the kind of regression a "does it run" check never catches.
# x86 bundles deliberately do NOT ship plain nnedi3 (Windows and macOS-x64 have
# only znedi3 + nnedi3cl), so this requirement is arch-conditional, not global.
import platform
if platform.machine().lower() in ('arm64', 'aarch64'):
    required.append('nnedi3')

# `akarin` supplies the LLVM JIT for std.Expr. VapourSynth's own Expr JIT is
# x86-only (#ifdef VS_TARGET_CPU_X86), so on ARM every expression is otherwise
# walked once per pixel — measured 550-640 CPU-seconds against the interpolator's
# 30 in a QTGMC Slow graph, i.e. the dominant arm64 cost. havsfunc's patch 7 and
# the templates' _expr() helper both fall back to std.Expr when it is absent, so
# a bundle missing it still renders correctly and just runs several times slower:
# the same silent class of regression as nnedi3 above.
# macos-x64 is the deliberate exception — the only wheel is macosx_14_0 and that
# bundle targets 12.0 (issue #39), so requiring it there would fail CI for a
# platform that intentionally does not ship it (and already has an x86 JIT).
import sys
if not (sys.platform == 'darwin' and platform.machine().lower() in ('x86_64', 'amd64')):
    required.append('akarin')
# nnedi3cl and knlm are deliberately NOT required: both are OpenCL and the app
# degrades to a CPU path when the driver is absent.

missing = []
for plugin in required:
    if not hasattr(core, plugin):
        missing.append(plugin)
for ns, fn in required_functions:
    if hasattr(core, ns) and not hasattr(getattr(core, ns), fn):
        missing.append(f'{ns}.{fn}')

if missing:
    raise Exception(f"Missing plugins: {missing}")
else:
    print("All plugins loaded successfully")
''';

      final result = await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('All plugins loaded'));
    });

    test('the bundled Bifrost is v4.0 or later: it runs at 10-bit', () async {
      // A namespace is not a version (the vszip.NLMeans note above). Bifrost
      // v3.0 (deps <= 1.17.0-rc2) refuses anything but 8-bit, and from task
      // #60 the template hands it the source's own depth, so a stale bundle
      // would pass the namespace check and fail every deeper Bifrost job. It
      // also left chroma past the last whole 4x4 block uninitialised.
      final script = '''
import vapoursynth as vs
core = vs.core
clip = core.std.BlankClip(width=98, height=64, format=vs.YUV420P10, length=5)
v = core.bifrost.version
assert (v.major, v.minor) >= (4, 0), 'bifrost %d.%d, need 4.0' % (v.major, v.minor)
core.bifrost.Bifrost(clip, interlaced=True).get_frame(2)
print("bifrost OK")
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('bifrost OK'));
    });

    test('the bundled zsmooth build runs on this CPU', () async {
      // zsmooth has no runtime dispatch: a build above this CPU's baseline
      // loads fine and then dies with an illegal instruction the instant a
      // filter runs (issue #82). Each x86 bundle tier ships the one build its
      // CPUs can run, so the autoloaded namespace must render here.
      // Constructing the node is not enough — the fault is in the kernel, so a
      // frame has to be rendered.
      final script = '''
import vapoursynth as vs
core = vs.core
clip = core.std.BlankClip(width=160, height=120, format=vs.YUV420P8, length=2)
clip = core.zsmooth.CCD(clip, threshold=4, scale=1)
clip.get_frame(0)
print("zsmooth OK")
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('zsmooth OK'));
    });
  });

  group('pipe_source Tests', () {
    test('pipe_source reads raw video from stdin', () async {
      final script = _pipeSourceScript(pipeSourceDir, '''
print(f"Clip: {clip.width}x{clip.height}, {clip.num_frames} frames")
print("pipe_source loaded successfully")
clip = clip[0]
clip.set_output()
''');

      final result = await _runVspipeScript(
        vspipePath, script,
        depsDir: depsDir,
        stdinFile: testRawPath,
        outputFrames: true,
      );
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });
  });

  group('Filter Tests', () {
    test('Deband (neo_f3kdb) works', () async {
      final script = _pipeSourceScript(pipeSourceDir, '''
clip = core.neo_f3kdb.Deband(clip, y=64, cb=64, cr=64)
print("Deband applied successfully")
clip = clip[0]
clip.set_output()
''');

      final result = await _runVspipeScript(
        vspipePath, script,
        depsDir: depsDir,
        stdinFile: testRawPath,
        outputFrames: true,
      );
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('DFTTest works', () async {
      final script = _pipeSourceScript(pipeSourceDir, '''
clip = core.dfttest.DFTTest(clip, sigma=10.0)
print("DFTTest applied successfully")
clip = clip[0]
clip.set_output()
''');

      final result = await _runVspipeScript(
        vspipePath, script,
        depsDir: depsDir,
        stdinFile: testRawPath,
        outputFrames: true,
      );
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('CAS (Contrast Adaptive Sharpening) works', () async {
      final script = _pipeSourceScript(pipeSourceDir, '''
clip = core.cas.CAS(clip, sharpness=0.5)
print("CAS applied successfully")
clip = clip[0]
clip.set_output()
''');

      final result = await _runVspipeScript(
        vspipePath, script,
        depsDir: depsDir,
        stdinFile: testRawPath,
        outputFrames: true,
      );
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('MVTools works', () async {
      final script = _pipeSourceScript(pipeSourceDir, '''
sup = core.mv.Super(clip)
vectors = core.mv.Analyse(sup, isb=False)
print("MVTools applied successfully")
clip = clip[0]
clip.set_output()
''');

      final result = await _runVspipeScript(
        vspipePath, script,
        depsDir: depsDir,
        stdinFile: testRawPath,
        outputFrames: true,
      );
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('ZNEDI3 works', () async {
      final script = _pipeSourceScript(pipeSourceDir, '''
clip = core.znedi3.nnedi3(clip, field=1)
print("ZNEDI3 applied successfully")
clip = clip[0]
clip.set_output()
''');

      final result = await _runVspipeScript(
        vspipePath, script,
        depsDir: depsDir,
        stdinFile: testRawPath,
        outputFrames: true,
      );
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('EEDI3 works', () async {
      final script = _pipeSourceScript(pipeSourceDir, '''
clip = core.eedi3m.EEDI3(clip, field=1)
print("EEDI3 applied successfully")
clip = clip[0]
clip.set_output()
''');

      final result = await _runVspipeScript(
        vspipePath, script,
        depsDir: depsDir,
        stdinFile: testRawPath,
        outputFrames: true,
      );
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('Deblock works', () async {
      final script = _pipeSourceScript(pipeSourceDir, '''
clip = core.deblock.Deblock(clip, quant=25)
print("Deblock applied successfully")
clip = clip[0]
clip.set_output()
''');

      final result = await _runVspipeScript(
        vspipePath, script,
        depsDir: depsDir,
        stdinFile: testRawPath,
        outputFrames: true,
      );
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('TCanny (edge detection) works', () async {
      final script = _pipeSourceScript(pipeSourceDir, '''
clip = core.tcanny.TCanny(clip, sigma=1.5, mode=0)
print("TCanny applied successfully")
clip = clip[0]
clip.set_output()
''');

      final result = await _runVspipeScript(
        vspipePath, script,
        depsDir: depsDir,
        stdinFile: testRawPath,
        outputFrames: true,
      );
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });
  });

  group('havsfunc Tests', () {
    test('havsfunc imports successfully', () async {
      final script = '''
import vapoursynth as vs
import havsfunc as haf
core = vs.core

print(f"havsfunc version: {haf.__version__ if hasattr(haf, '__version__') else 'unknown'}")
print("havsfunc imported successfully")
''';

      final result = await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('havsfunc imported'));
    });

    test('SMDegrain works', () async {
      final script = _pipeSourceScript(pipeSourceDir, '''
import havsfunc as haf
clip = haf.SMDegrain(clip, tr=1, thSAD=300)
print("SMDegrain applied successfully")
clip = clip[0]
clip.set_output()
''');

      final result = await _runVspipeScript(
        vspipePath, script,
        depsDir: depsDir,
        stdinFile: testRawPath,
        outputFrames: true,
      );
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });
  });

  // Regression guards for the QTGMC "Very Slow / Placebo brighten the picture on
  // Apple Silicon" bug (and its worse sibling, a near-black Draft preset).
  //
  // Root cause was in fmtconv: Scaler::process_plane_int_cpp applied the
  // SSE2/AVX2 paths' sign-conversion constants while using unsigned C++ proxies,
  // so the accumulator went negative and write_clip clamped it to 0. Any resample
  // whose kernel ran with a source bitdepth below 16 returned a black plane, on
  // builds without the x86 SIMD path (macos-arm64, linux-arm64): 8-bit on the
  // vertical axis, and 10/12-bit on BOTH axes — 8-bit horizontal escaped only
  // because that route converts to 16-bit before the scaler. It broke havsfunc's
  // Bob(), which feeds QTGMC's noise pass (Placebo/Very Slow default
  // NoiseProcess=2) and the Draft preset's interpolation.
  //
  // Two layers now guard it, and these tests cover both:
  //   1. Scripts/patches/fmtconv-r31-arm-int-scaler.patch, applied when the deps
  //      scripts build fmtconv from source (macOS/Linux) — the actual fix.
  //   2. havsfunc "Patch 5" in download-deps-*, which makes Bob() resample at
  //      16-bit — belt and braces, and it also covers the prebuilt Windows DLL.
  //
  // All three assert observable pixel behaviour rather than patch text, so they
  // stay valid however the fix is delivered — including if fmtconv fixes this
  // upstream and both patches are eventually dropped.
  group('fmtconv vertical resample / havsfunc Bob', () {
    test('fmtc.resample scales vertically at sub-16-bit depths', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

# Flat mid-grey must survive a 2x vertical resample. Before the fix this came
# back as a pure black plane for every depth below 16. Note fmtconv converts
# depth by a power-of-two shift, so 8-bit 120 becomes 120 * 256 = 30720, which
# reads back as 119.53 in 8-bit terms rather than 120.0.
for bits, fmt in ((8, vs.GRAY8), (10, vs.GRAY10), (12, vs.GRAY12), (16, vs.GRAY16)):
    peak = (1 << bits) - 1
    val = round(120 / 255 * peak)
    src = core.std.BlankClip(format=fmt, width=160, height=120, length=2, color=[val])
    expected = val / peak * 255
    for label, kw in (("scalev=2", dict(scalev=2)), ("scalev=0.5", dict(scalev=0.5))):
        out = core.fmtc.resample(src, **kw)
        avg = core.std.PlaneStats(out).get_frame(0).props['PlaneStatsAverage'] * 255
        print(f"CHECK bits={bits} {label} avg={avg:.3f} expected={expected:.3f}")
        if abs(avg - expected) > 1.0:
            raise Exception(f"fmtc.resample {label} broken at {bits}-bit: "
                            f"got {avg:.3f}, expected ~{expected:.3f}")
print("fmtc vertical resample OK")
''';

      final result =
          await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('fmtc vertical resample OK'));
    });

    test('havsfunc Bob preserves average luma', () async {
      final script = '''
import vapoursynth as vs
import havsfunc as haf
core = vs.core

# Bob() doubles the frame rate by interpolating each field to a full frame, so
# average luma must be preserved. Before the fix it collapsed towards black.
src = core.std.BlankClip(format=vs.YUV420P8, width=160, height=120,
                         length=4, color=[120, 128, 128])
src = core.std.SetFieldBased(src, 2)  # TFF
bobbed = haf.Bob(src, 0, 1, True)

s = core.std.PlaneStats(bobbed, plane=0)
avgs = [s.get_frame(i).props['PlaneStatsAverage'] * 255 for i in range(len(bobbed))]
worst = max(abs(a - 120) for a in avgs)
print(f"CHECK frames={len(bobbed)} worst_deviation={worst:.3f}")
if len(bobbed) != 2 * len(src):
    raise Exception(f"Bob should double the frame count, got {len(bobbed)}")
if worst > 1.0:
    raise Exception(f"Bob() shifted luma by {worst:.3f}; expected ~0 "
                    f"(fmtconv vertical resample regression?)")
print("havsfunc Bob OK")
''';

      final result =
          await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('havsfunc Bob OK'));
    });

    test('QTGMC Very Slow and Draft do not shift luma', () async {
      // Very Slow is the cheapest preset that defaults NoiseProcess=2 (Placebo
      // is the same code path but far slower); Draft exercises EdiMode='bob'.
      final script = '''
import vapoursynth as vs
import havsfunc as haf
core = vs.core

src = core.std.BlankClip(format=vs.YUV420P8, width=160, height=120,
                         length=6, color=[120, 128, 128])
# Give the denoiser some detail to chew on, otherwise a flat clip can mask a
# bias that only shows up once MakeDiff has something to clip.
src = core.grain.Add(src, var=8, seed=1)
src = core.std.SetFieldBased(src, 2)  # TFF

base = sum(core.std.PlaneStats(src, plane=0).get_frame(i)
           .props['PlaneStatsAverage'] for i in range(len(src))) / len(src) * 255

for preset in ('Fast', 'Very Slow', 'Draft'):
    out = haf.QTGMC(src, Preset=preset, TFF=True, FPSDivisor=1)
    st = core.std.PlaneStats(out, plane=0)
    avg = sum(st.get_frame(i).props['PlaneStatsAverage']
              for i in range(len(out))) / len(out) * 255
    print(f"CHECK preset={preset} luma={avg:.3f} base={base:.3f} delta={avg - base:+.3f}")
    if abs(avg - base) > 2.0:
        raise Exception(f"QTGMC Preset={preset} shifted luma by {avg - base:+.3f} "
                        f"(expected ~0)")
print("QTGMC preset luma OK")
''';

      final result =
          await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('QTGMC preset luma OK'));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  // fmtconv is pinned to r31 on every platform (download-deps-{macos,linux}.sh
  // FMTCONV_TAG, the Windows zip URL). r31's "resample: fixed chroma placement"
  // moved DV placement's vertical offset from V to U, so an older build gives a
  // different picture for the same job, and nothing else would notice: through
  // deps 1.16.0 the macOS x64 bundle shipped Stefan-Olt's git-18a9cecb (between
  // r30 and r31) for exactly that reason. See
  // docs/reports/2026-11-fmtconv-macos-x64-r31.
  //
  // The fingerprint: U and V are the same vertical ramp, so any U-V difference
  // after a field-aware vertical resample comes from chroma placement alone.
  // With cplace="dv", r31 gives U-V = -606 (16-bit levels) on both fields and
  // older builds +606; mpeg2 gives 0 on both. The sign does not depend on the
  // SIMD path, so it needs no reference image.
  group('fmtconv version pin', () {
    test('fmtc.resample has r31 chroma placement (DV on interlaced 4:2:0)',
        () async {
      if (depsPlatform == 'macos-x64' && _depsVersionAtMost(depsDir, [1, 16, 0])) {
        markTestSkipped('macos-x64 deps <= 1.16.0 ship fmtconv git-18a9cecb '
            '(pre-r31); enforced from the next deps release');
        return;
      }
      final script = '''
import vapoursynth as vs
core = vs.core

rows = [core.std.BlankClip(format=vs.GRAY8, width=32, height=1, length=2,
                           color=[40 + 5 * i]) for i in range(32)]
ramp = core.std.StackVertical(rows)
y = core.std.BlankClip(format=vs.GRAY8, width=64, height=64, length=2, color=[128])
clip = core.std.ShufflePlanes([y, ramp, ramp], [0, 0, 0], vs.YUV)
assert clip.format.id == vs.YUV420P8, clip.format.name
fields = core.std.SeparateFields(core.std.SetFieldBased(clip, 2), tff=True)

def u_minus_v(cplace, n):
    out = core.fmtc.resample(fields, scalev=2, interlaced=1, interlacedd=0,
                             cplace=cplace)
    u = core.std.PlaneStats(out, plane=1).get_frame(n).props['PlaneStatsAverage']
    v = core.std.PlaneStats(out, plane=2).get_frame(n).props['PlaneStatsAverage']
    return (u - v) * 65535

for n in range(2):
    dv = u_minus_v("dv", n)
    mpeg2 = u_minus_v("mpeg2", n)
    print(f"CHECK field={n} dv_U-V={dv:+.2f} mpeg2_U-V={mpeg2:+.2f}")
    if abs(mpeg2) > 1.0:
        raise Exception(f"mpeg2 placement should treat U and V alike, got {mpeg2:+.2f}")
    if dv > -300:
        raise Exception(f"cplace='dv' gave U-V={dv:+.2f}; r31 gives about -606 "
                        f"and pre-r31 fmtconv +606. Is this bundle's fmtconv r31?")
print("fmtconv r31 chroma placement OK")
''';

      final result =
          await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(),
          contains('fmtconv r31 chroma placement OK'));
    });
  });

  // Task #62: every published FFT3DFilter build gave a different output on
  // every run (the left border mirrored from stale memory; a per-frame sigma
  // in a shared member of a parallel filter), so the Noise Reduction FFT3D
  // method, TemporalDegrain2 and QTGMC's fft3dfilter denoiser never previewed
  // what they encoded. download-deps-* build R2 with
  // patches/fft3dfilter-r2-determinism.patch. This holds every bundle to it:
  // six fresh graphs per argument set at 8 threads must agree, a second
  // process must agree with the first (FFTW plans are chosen per process),
  // and a flat picture must come out flat at the left edge.
  // docs/reports/task-62-fft3dfilter-determinism.
  //
  // Task #80: with measure=1 (FFTW_MEASURE) FFTW times its plans once per
  // process, so the second process sometimes chose another plan (Windows CI).
  // The templates pass measure=0 (FFTW_ESTIMATE), and from deps 1.18.0-rc2
  // the patch makes it the plugin's default, for havsfunc's calls (QTGMC),
  // which pass none. Those two classes run only on such a bundle.
  // docs/reports/task-80-fft3dfilter-fftw-estimate.
  group('fft3dfilter determinism', () {
    test('fft3dfilter is deterministic (task #62)', () async {
      if (_depsVersionAtMost(depsDir, [1, 17])) {
        markTestSkipped('deps <= 1.17.x ship an unpatched FFT3DFilter '
            '(task #62); enforced from deps 1.18.0');
        return;
      }
      // The plugin's default is measure=0 from deps 1.18.0-rc2 (task #80).
      final estimateDefault = !_depsVersionBefore(depsDir, '1.18.0-rc2');
      final script = r'''
import ctypes
import hashlib
import random
import vapoursynth as vs
core = vs.core
core.num_threads = 8
ESTIMATE_DEFAULT = False  # replaced from Dart: the bundle's default is measure=0

# A textured, moving picture: seeded noise (a new pattern every frame) half
# blurred, so every block has detail and every frame differs, on any platform.
blank = core.std.BlankClip(format=vs.YUV420P8, width=352, height=288, length=12)

def fill(n, f):
    out = f.copy()
    rnd = random.Random(1000 + n)
    for p in range(3):
        w, h = out.width >> (1 if p else 0), out.height >> (1 if p else 0)
        base = ctypes.cast(out.get_write_ptr(p), ctypes.c_void_p).value
        stride = out.get_stride(p)
        for y in range(h):
            ctypes.memmove(base + y * stride, rnd.randbytes(w), w)
    return out

noise = core.std.ModifyFrame(blank, blank, fill)
clip8 = core.std.Merge(noise, core.std.BoxBlur(noise, hradius=3, vradius=3), 0.6)
assert clip8.format.id == vs.YUV420P8, clip8.format.name
clip16 = core.resize.Point(clip8, format=vs.YUV420P16)

# Every call passes measure=0, as the templates do (task #80).
ARGS = {
    # TemporalDegrain2's spatial pass: a sigma pattern, bt=3.
    'td2_spat': dict(planes=[0, 1, 2], sigma=16, sigma2=10, sigma3=6, sigma4=4,
                     bt=3, bw=32, bh=32, ow=8, oh=8, measure=0),
    # TD2's post pass: one sigma, bt=3, 48 px blocks (where FFTW_ESTIMATE and
    # FFTW_MEASURE choose different plans on macOS arm64).
    'td2_post': dict(planes=[0, 1, 2], sigma=1.0, bt=3, bw=48, bh=48, measure=0),
    # Noise Reduction's FFT3DFilter method: one sigma, bt>1.
    'single_sigma_bt3': dict(sigma=2.0, bt=3, measure=0),
    'single_sigma_bt5': dict(sigma=4.0, bt=5, measure=0),
    'bt1': dict(sigma=16, bt=1, measure=0),
}
CALLS = {name: (lambda c, kw=kw: core.fft3dfilter.FFT3DFilter(c, **kw))
         for name, kw in ARGS.items()}
if ESTIMATE_DEFAULT:
    import havsfunc as haf
    # havsfunc's calls pass no measure: the plugin's default must be ESTIMATE.
    CALLS['default'] = lambda c: core.fft3dfilter.FFT3DFilter(
        c, planes=[0, 1, 2], sigma=1.0, bt=3, bw=48, bh=48)
    CALLS['qtgmc'] = lambda c: haf.QTGMC(
        c, Preset='Fast', TFF=True, NoiseProcess=1, Denoiser='fft3dfilter', NoiseTR=1)

def digest(c):
    m = hashlib.md5()
    for f in c.frames(prefetch=16):
        for p in range(f.format.num_planes):
            m.update(bytes(f[p]))
    return m.hexdigest()

bad = []
for depth, src in (('8', clip8), ('16', clip16)):
    for name, call in CALLS.items():
        hashes = {digest(call(src)) for _ in range(6)}
        print(f'HASH {depth}-bit {name} {len(hashes)} {sorted(hashes)[0]}')
        if len(hashes) != 1:
            bad.append(f'{depth}-bit {name}: {len(hashes)} different outputs in 6 runs')

# The left-border oracle: on a flat picture every column must come out equal,
# per row. The unpatched mirror read stale memory into the left 10 luma / 6
# chroma columns (x = 0 read 90 against 100).
flat = core.std.BlankClip(format=vs.YUV420P8, width=352, height=288, length=6,
                          color=[100, 128, 128])
# The patched plugin rounds a flat picture to within 1 level everywhere, at
# the edge as in the interior; the stale mirror was 4-33 levels off.
worst = 0
for f in core.fft3dfilter.FFT3DFilter(flat, sigma=2.0, bt=3, measure=0).frames():
    for p in range(3):
        for row in f[p].tolist():
            ref = row[32 if p == 0 else 16]
            worst = max(worst, max(abs(v - ref) for v in row[:16]))
print(f'LEFT_EDGE_MAX_DIFF {worst}')
if worst > 1:
    bad.append(f'flat picture: the left 16 columns differ from the interior by up to {worst} levels')

if bad:
    raise Exception('FFT3DFilter is not deterministic (task #62): ' + '; '.join(bad))
print('fft3dfilter deterministic OK')
flat.set_output()'''
          .replaceFirst('ESTIMATE_DEFAULT = False',
              'ESTIMATE_DEFAULT = ${estimateDefault ? 'True' : 'False'}');

      Map<String, String> hashes(ProcessResult r) => {
            for (final m in RegExp(r'^HASH (\S+ \S+) \d+ ([0-9a-f]{32})',
                    multiLine: true)
                .allMatches(r.stdout.toString()))
              m.group(1)!: m.group(2)!,
          };

      final first = await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(first.exitCode, 0,
          reason: 'stdout: ${first.stdout}\nstderr: ${first.stderr}');
      expect(first.stdout.toString(), contains('fft3dfilter deterministic OK'));
      final second =
          await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(second.exitCode, 0,
          reason: 'stdout: ${second.stdout}\nstderr: ${second.stderr}');
      expect(hashes(first), hasLength(estimateDefault ? 14 : 10));
      expect(hashes(second), equals(hashes(first)),
          reason: 'a second process filtered differently. Every call here '
              'plans with FFTW_ESTIMATE (task #80), which is one plan per '
              'machine; check docs/reports/task-80-fft3dfilter-fftw-estimate');
      if (estimateDefault) {
        // The default and an explicit measure=0 are the same plan.
        final h = hashes(first);
        for (final depth in ['8-bit', '16-bit']) {
          expect(h['$depth default'], equals(h['$depth td2_post']),
              reason: 'FFT3DFilter\'s default is not measure=0 (task #80)');
        }
      }
      // Two processes, each six graphs per class at two depths, QTGMC among
      // them from 1.18.0-rc2: over the 30 s default on a 4-core Linux runner
      // running other tests alongside.
    }, timeout: const Timeout(Duration(minutes: 5)));

    // Task #80: the patch is what makes measure=0 the default for havsfunc's
    // calls; no runtime property shows the default, so read the patch.
    test('the fft3dfilter patch makes measure=0 the default (task #80)', () {
      final patch = File(path.join(Directory.current.path, '..', 'Scripts',
              'patches', 'fft3dfilter-r2-determinism.patch'))
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      expect(patch, contains('\n-        set_option_int(&measure, 1, "measure", in, vsapi);\n'));
      expect(patch, contains('\n+        set_option_int(&measure, 0, "measure", in, vsapi);'));
    });
  });

  // Task #96: DCTFilter up to r2.1 (the Windows release, Stefan-Olt's macOS
  // x64 build) kept a scratch buffer per worker thread in an unordered_map it
  // filled from getFrame with no lock. Two threads starting together lost an
  // insert, .at() threw inside noexcept code and vspipe aborted (0xC0000409 on
  // Windows): the Deblock pass's DCTFilter and QED methods, about one run in a
  // hundred. download-deps-* build r3.2 with
  // patches/dctfilter-r3.2-thread-safety.patch (upstream's c924a7a) on every
  // platform. docs/reports/task-96-dctfilter-thread-race.
  group('dctfilter thread safety', () {
    // Version 3.2 is API 4: r2/r2.1 report no usable version (-1).
    const versionCheck = r'''
import vapoursynth as vs
core = vs.core
v = core.dctf.version
print(f'DCTF_VERSION {v.major}.{v.minor}')
if (v.major, v.minor) < (3, 2):
    raise Exception(f'DCTFilter {v.major}.{v.minor} is older than r3.2 (task #96): '
                    'r2/r2.1 abort under threads')
print('dctfilter version OK')
core.std.BlankClip().set_output()''';

    test('the bundle has DCTFilter r3.2 or later (task #96)', () async {
      if (_depsVersionBefore(depsDir, '1.18.0-rc3')) {
        markTestSkipped('deps <= 1.18.0-rc2 ship DCTFilter r2/r2.1 on Windows '
            'and macOS x64 (task #96); enforced from deps 1.18.0-rc3');
        return;
      }
      final r = await _runVspipeScript(vspipePath, versionCheck, depsDir: depsDir);
      expect(r.exitCode, 0, reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}');
      expect(r.stdout.toString(), contains('dctfilter version OK'));
    });

    // The patch is upstream's c924a7a: no buffer map left, a buffer per call.
    // No runtime property tells r3.2 from r3.2 + the patch, so read it.
    test('the dctfilter patch drops the per-thread buffer map (task #96)', () {
      final patch = File(path.join(Directory.current.path, '..', 'Scripts',
              'patches', 'dctfilter-r3.2-thread-safety.patch'))
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      expect(patch, contains('\n-    std::unordered_map<std::thread::id, '));
      expect(patch, contains(
          '\n+        float *buffer = vsh::vsh_aligned_malloc<float>(64 * sizeof(float), 64);'));
      for (final script in ['download-deps-macos.sh', 'download-deps-linux.sh',
          'download-deps-windows.ps1']) {
        final text = File(path.join(Directory.current.path, '..', 'Scripts', script))
            .readAsStringSync();
        expect(text, contains('dctfilter-r3.2-thread-safety.patch'),
            reason: '$script does not apply the DCTFilter patch');
        expect(text, isNot(contains('DctFilter-r2')),
            reason: '$script still fetches DCTFilter r2');
        expect(text, isNot(contains('com.holywu.dctfilter/r2')),
            reason: '$script still fetches a prebuilt DCTFilter r2.x');
      }
    });

    // Each filter instance has its own map, so the race fires on an instance's
    // first frames: one graph of 1000 instances spliced end to end starts many
    // of them under contention. With r2, 14 of 20 such runs aborted on an M1
    // (the macOS x64 r2.1 under Rosetta 11 of 20), so ten all miss it with a
    // probability under 0.1%; with the patched build none of 20 did. Deblock_QED, which calls DCTFilter itself, runs
    // the same way at the sweep row's size (96x64 4:2:2 12-bit, fields).
    test('DCTFilter and Deblock_QED survive many instances starting together '
        '(task #96)', () async {
      if (_depsVersionBefore(depsDir, '1.18.0-rc3')) {
        markTestSkipped('deps <= 1.18.0-rc2 ship DCTFilter r2/r2.1 on Windows '
            'and macOS x64 (task #96); enforced from deps 1.18.0-rc3');
        return;
      }
      String stress(String call, int instances, int length) => '''
import vapoursynth as vs
import havsfunc as haf
core = vs.core
core.num_threads = 8
src = core.std.BlankClip(width=96, height=64, format=vs.YUV422P12, length=$length,
                         color=[2048, 1500, 2500])
src = core.std.SeparateFields(core.std.SetFieldBased(src, 2), tff=True)
core.std.Splice([$call for _ in range($instances)]).set_output()''';
      final runs = [
        for (var i = 0; i < 10; i++)
          ('DCTFilter', stress('core.dctf.DCTFilter(src, factors=[1, 1, 0, 0, 0, 0, 0, 0])', 1000, 20)),
        for (var i = 0; i < 3; i++)
          ('Deblock_QED', stress('haf.Deblock_QED(src)', 300, 8)),
      ];
      for (final (name, script) in runs) {
        final r = await _runVspipeScript(vspipePath, script,
            depsDir: depsDir, outputFrames: true);
        expect(r.exitCode, 0,
            reason: '$name aborted (exit ${r.exitCode}): an unlocked per-thread '
                'buffer map, task #96?\nstderr: ${r.stderr}');
      }
    }, tags: ['heavy'], timeout: const Timeout(Duration(minutes: 5)));
  });

  // Task #82: havsfunc patch 8 (download-deps-*) turns LUTDeCrawl's and
  // LUTDeRainbow's eight Lut2(function=lambda x, y: x & y) mask ANDs into
  // Expr 'x y min'. At 10 bits each of those tables was a million Python calls:
  // 7.9 s of script evaluation per filter on an M1, paid by every preview. min
  // is only exact because one operand of every call is a strict 0/peak mask, so
  // this compares both filters (output, and the mask itself) with the same call
  // made through upstream's own table, at 8 and 10 bits and every subsampling,
  // on a picture whose masks are partly set. The reference uses Lut2's lut=
  // list, which is the function's table byte for byte (task #75) at a fraction
  // of its cost. docs/reports/task-82-havsfunc-mask-and.
  group('havsfunc mask AND (patch 8)', () {
    test('LUTDeCrawl and LUTDeRainbow give upstream\'s picture, without '
        'Python tables (task #82)', () async {
      final havsfunc = Platform.isWindows
          ? path.join(depsDir, 'vapoursynth', 'Lib', 'site-packages', 'havsfunc.py')
          : path.join(depsDir, 'python-packages', 'havsfunc.py');
      final hasPatch =
          File(havsfunc).readAsStringSync().contains('def _mask_and(');
      if (!hasPatch && _depsVersionAtMost(depsDir, [1, 18, 0])) {
        markTestSkipped('deps <= 1.18.0-rc2 ship havsfunc without patch 8 '
            '(task #82)');
        return;
      }
      const script = r'''
import time
import vapoursynth as vs
import havsfunc as haf
core = vs.core

src = open(haf.__file__).read()
assert 'std.Lut2(' not in src, 'havsfunc still calls std.Lut2 (patch 8 not applied)'
patched = haf._mask_and

def upstream(clipa, clipb):
    ba, bb = clipa.format.bits_per_sample, clipb.format.bits_per_sample
    lut = [x & y for y in range(1 << bb) for x in range(1 << ba)]
    return core.std.Lut2(clipa, clipb, lut=lut)

def fixture(fmt):
    # Mid grey with temporally varying grain: neighbouring frames are within
    # the thresholds in some places and not in others, so every mask is
    # partly set. A static band keeps part of each mask fully set.
    f = core.get_video_format(fmt)
    mid = 1 << (f.bits_per_sample - 1)
    c = core.std.BlankClip(width=160, height=120, format=fmt, length=6, color=[mid] * 3)
    g = core.grain.Add(c, var=40, uvar=40, constant=False, seed=3)
    return core.std.StackVertical([g.std.Crop(bottom=40), c.std.Crop(top=80)])

def same(a, b):
    if a.format.id != b.format.id or (a.width, a.height, a.num_frames) != (b.width, b.height, b.num_frames):
        return False
    for p in range(a.format.num_planes):
        st = core.std.PlaneStats(a, b, plane=p)
        for n in range(a.num_frames):
            if st.get_frame(n).props['PlaneStatsDiff'] != 0:
                return False
    return True

CALLS = {
    'LUTDeCrawl': lambda c, m: haf.LUTDeCrawl(c, ythresh=10, cthresh=10, maxdiff=50, mask=m),
    'LUTDeRainbow': lambda c, m: haf.LUTDeRainbow(c, cthresh=10, ythresh=10, y=True, linkUV=True, mask=m),
    'LUTDeRainbow unlinked': lambda c, m: haf.LUTDeRainbow(c, cthresh=10, ythresh=10, y=True, linkUV=False, mask=m),
}
bad = []
slowest = 0.0
for fmt in (vs.YUV420P8, vs.YUV422P8, vs.YUV444P8, vs.YUV420P10, vs.YUV422P10, vs.YUV444P10):
    clip = fixture(fmt)
    name = core.get_video_format(fmt).name
    for label, call in CALLS.items():
        # The 10-bit reference costs ~0.3 s a table, so its masks are compared
        # at 4:2:0 only; the outputs at every subsampling.
        for mask in ((False, True) if fmt in (vs.YUV420P8, vs.YUV420P10, vs.YUV422P8, vs.YUV444P8) else (False,)):
            haf._mask_and = patched
            t = time.perf_counter()
            got = call(clip, mask)
            slowest = max(slowest, time.perf_counter() - t)
            haf._mask_and = upstream
            want = call(clip, mask)
            haf._mask_and = patched
            what = '%s %s %s' % (name, label, 'mask' if mask else 'output')
            if mask:
                avg = core.std.PlaneStats(got).get_frame(2).props['PlaneStatsAverage']
                if not 0.02 < avg < 0.98:
                    bad.append('%s: mask average %.3f, the fixture no longer exercises both states' % (what, avg))
            if not same(got, want):
                bad.append('%s differs from upstream\'s table' % what)
print('SLOWEST_EVAL %.3f' % slowest)
# Upstream's 10-bit tables took 7.9 s per call on an M1; the Expr takes
# milliseconds. Generous, so only a return to Python tables fails it.
if slowest > 2.0:
    bad.append('a call took %.2f s to build (Python tables again?)' % slowest)
if bad:
    raise Exception('havsfunc patch 8 (task #82): ' + '; '.join(bad))
print('havsfunc mask AND OK')
core.std.BlankClip().set_output()''';
      final r = await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      // ignore: avoid_print
      print('  ${RegExp(r'SLOWEST_EVAL \S+').stringMatch(r.stdout.toString())}');
      expect(r.exitCode, 0, reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}');
      expect(r.stdout.toString(), contains('havsfunc mask AND OK'));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  // Task #40: AV1 output needs SVT-AV1 in the bundled FFmpeg. BtbN's builds
  // (Windows, Linux) and martin-riedl's (macOS arm64 and, from deps
  // 1.17.0-rc2, x64; task #45) carry it. This proves every bundle has it, on
  // every CI runner. Before rc2 the macOS x64 bundle shipped evermeet's FFmpeg,
  // which has none, and this test made an exception for it.
  group('FFmpeg encoders', () {
    test('libsvtav1 is compiled in', () async {
      final result = await Process.run(ffmpegPath, ['-hide_banner', '-encoders']);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      final hasSvt = RegExp(r'^\s*V\S*\s+libsvtav1\s', multiLine: true)
          .hasMatch(result.stdout.toString());
      expect(hasSvt, isTrue,
          reason: '$depsPlatform FFmpeg lacks libsvtav1; AV1 output would be '
              'unavailable');
    });
  });
}

/// Whether the deps bundle at [depsDir] says (in its version.json) it is at
/// most [max]. A missing or unreadable file counts as newer, so the check it
/// guards still runs.
bool _depsVersionAtMost(String depsDir, List<int> max) {
  try {
    final json = jsonDecode(
            File(path.join(depsDir, 'version.json')).readAsStringSync())
        as Map<String, dynamic>;
    final parts = (json['version'] as String)
        .split('-')
        .first
        .split('.')
        .map(int.parse)
        .toList();
    for (var i = 0; i < max.length; i++) {
      final v = i < parts.length ? parts[i] : 0;
      if (v != max[i]) return v < max[i];
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Whether the deps bundle at [depsDir] is older than [version], pre-releases
/// included (`1.18.0-rc1` < `1.18.0-rc2` < `1.18.0`). A missing or unreadable
/// file counts as newer, so the check it guards still runs.
bool _depsVersionBefore(String depsDir, String version) {
  (List<int>, int) parse(String v) {
    final dash = v.indexOf('-');
    final core = (dash < 0 ? v : v.substring(0, dash)).split('.').map(int.parse).toList();
    final rc = dash < 0
        ? 1 << 30 // a release sorts after all its candidates
        : int.parse(RegExp(r'(\d+)$').firstMatch(v.substring(dash))!.group(1)!);
    return (core, rc);
  }

  try {
    final json = jsonDecode(
            File(path.join(depsDir, 'version.json')).readAsStringSync())
        as Map<String, dynamic>;
    final (have, haveRc) = parse(json['version'] as String);
    final (want, wantRc) = parse(version);
    for (var i = 0; i < want.length; i++) {
      final v = i < have.length ? have[i] : 0;
      if (v != want[i]) return v < want[i];
    }
    return haveRc < wantRc;
  } catch (_) {
    return false;
  }
}

/// Builds a VapourSynth script that uses pipe_source to read raw video from stdin.
/// The [filterCode] receives a `clip` variable and `core` already set up.
String _pipeSourceScript(String pipeSourceDir, String filterCode) {
  // Use forward slashes and raw string for Windows path compatibility
  final escapedDir = pipeSourceDir.replaceAll(r'\', '/');
  return '''
import sys
sys.path.insert(0, r"$escapedDir")

import vapoursynth as vs
from pipe_source import create_pipe_clip
core = vs.core

clip = create_pipe_clip(
    width=64, height=64,
    num_frames=10, fps_num=25, fps_den=1,
    pix_fmt="yuv420p",
)

$filterCode
''';
}

/// Runs a VapourSynth script via vspipe.
/// If [stdinFile] is provided, pipes that file's contents to vspipe's stdin.
Future<ProcessResult> _runVspipeScript(
  String vspipePath,
  String script, {
  required String depsDir,
  String? stdinFile,
  bool outputFrames = false,
}) async {
  // Write script to temp file
  final scriptFile = File(path.join(
    Directory.systemTemp.path,
    'vapourbox_test_${DateTime.now().millisecondsSinceEpoch}.vpy',
  ));
  await scriptFile.writeAsString(script);

  try {
    // Use -p for progress mode when we want to process frames
    // Use -i for info only (validates script without outputting frames)
    final args = outputFrames
        ? ['-p', scriptFile.path, '.'] // -p shows progress, . means discard output
        : ['-i', scriptFile.path, '-'];

    // Build platform-specific environment
    final Map<String, String> environment;

    if (Platform.isWindows) {
      final vsDir = path.join(depsDir, 'vapoursynth');
      environment = {
        'PYTHONHOME': vsDir,
        'PYTHONPATH': path.join(vsDir, 'Lib', 'site-packages'),
        // R74 replaced VAPOURSYNTH_PLUGIN_PATH with this; under the old name the
        // bundled plugins are simply not autoloaded and every filter fails with
        // "No attribute with the name <ns> exists". Matches
        // DependencyLocator::build_environment in the worker.
        'VAPOURSYNTH_EXTRA_PLUGIN_PATH': path.join(vsDir, 'vs-plugins'),
      };
    } else {
      // macOS/Linux - the vspipe wrapper script handles most env setup
      environment = {
        'PYTHONPATH': path.join(depsDir, 'python-packages'),
      };
    }

    if (stdinFile != null) {
      // Pipe raw file to vspipe's stdin
      final rawFile = File(stdinFile);
      final process = await Process.start(
        vspipePath,
        args,
        environment: environment,
      );

      final rawBytes = await rawFile.readAsBytes();

      // Start draining BEFORE writing stdin, and never await the write.
      //
      // These scripts ask for a single frame, so vspipe reads a fraction of the
      // raw file and exits; the rest of the write has nowhere to go. Awaiting
      // `stdin.close()` first then deadlocks — the write blocks on a pipe nobody
      // is reading, so the drain that would let vspipe finish never starts.
      //
      // R73 hid this: it spent ~1.4s evaluating the script, long enough for the
      // whole 60 KB to land in the OS pipe buffer before vspipe exited. R78
      // evaluates in ~0.01s and loses the race every time. It was always a race,
      // not a version difference, so don't "fix" it by reordering back.
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final drained = Future.wait([
        process.stdout.transform(const SystemEncoding().decoder).forEach(stdout.write),
        process.stderr.transform(const SystemEncoding().decoder).forEach(stderr.write),
      ]);

      unawaited(() async {
        try {
          process.stdin.add(rawBytes);
          await process.stdin.close();
        } catch (_) {
          // Broken pipe: vspipe got the frames it needed and exited.
        }
      }());

      await drained;
      final exitCode = await process.exitCode;

      return ProcessResult(process.pid, exitCode, stdout.toString(), stderr.toString());
    } else {
      final result = await Process.run(
        vspipePath,
        args,
        environment: environment,
      );
      return result;
    }
  } finally {
    await scriptFile.delete();
  }
}
