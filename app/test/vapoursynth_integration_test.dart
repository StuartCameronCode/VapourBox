// End-to-end tests that verify VapourSynth plugins work correctly.
// These tests run actual vspipe commands to ensure all filters function.
// Uses FFmpeg to generate a test video, piped through pipe_source.py.
//
// Run with: flutter test test/vapoursynth_integration_test.dart
// Note: Requires platform-specific deps to be present with all plugins.

import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late String depsDir;
  late String vspipePath;
  late String ffmpegPath;
  late String pipeSourceDir;
  late String testRawPath;

  setUpAll(() async {
    // Find the deps directory relative to the test file
    final scriptDir = Directory.current.path;

    // Determine platform-specific deps folder
    final String depsPlatform;
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

    // Try different possible locations for deps
    final possibleDepsPaths = [
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

    test('all required plugins load', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

# Every namespace the templates call directly, plus the ones havsfunc reaches
# for on the paths the app exposes. A plugin missing here is a FILTER that fails
# at job time with "No attribute with the name <ns> exists" — which is what an
# incomplete or stale deps install looks like from the user's side. `zsmooth`
# (Chroma Denoise / CCD) was added to the bundle after this list was written and
# went uncovered, so a bundle without it passed the suite and failed the filter.
required = ['std', 'resize', 'mv', 'znedi3', 'eedi3m', 'fmtc',
            'dfttest', 'neo_f3kdb', 'cas', 'dctf', 'deblock', 'rgvs',
            'ctmf', 'warp', 'misc', 'grain', 'tcanny',
            'zsmooth', 'descratch', 'vivtc', 'ttmpsm', 'tmedian',
            'fft3dfilter', 'flux', 'bifrost', 'retinex']

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

if missing:
    raise Exception(f"Missing plugins: {missing}")
else:
    print("All plugins loaded successfully")
''';

      final result = await _runVspipeScript(vspipePath, script, depsDir: depsDir);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('All plugins loaded'));
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
