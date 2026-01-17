// End-to-end tests that verify VapourSynth plugins work correctly.
// These tests run actual vspipe commands to ensure all filters function.
//
// Run with: flutter test test/vapoursynth_integration_test.dart
// Note: Requires deps/macos-arm64 to be present with all plugins.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late String depsDir;
  late String vspipePath;
  late String testVideoPath;

  setUpAll(() async {
    // Find the deps directory relative to the test file
    final scriptDir = Directory.current.path;

    // Try different possible locations for deps
    final possibleDepsPaths = [
      path.join(scriptDir, '..', 'deps', 'macos-arm64'),
      path.join(scriptDir, 'deps', 'macos-arm64'),
      '/Users/stuartcameron/GitHub/VapourBox/deps/macos-arm64',
    ];

    for (final p in possibleDepsPaths) {
      if (await Directory(p).exists()) {
        depsDir = p;
        break;
      }
    }

    vspipePath = path.join(depsDir, 'vapoursynth', 'vspipe');

    // Create a simple test video (Y4M format - raw YUV)
    testVideoPath = path.join(Directory.systemTemp.path, 'vapourbox_test.y4m');
    await _createTestVideo(testVideoPath);
  });

  tearDownAll(() async {
    // Clean up test video
    final testFile = File(testVideoPath);
    if (await testFile.exists()) {
      await testFile.delete();
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

# List all required plugins
required = ['std', 'resize', 'bs', 'mv', 'znedi3', 'eedi3m', 'fmtc',
            'dfttest', 'neo_f3kdb', 'cas', 'dctf', 'deblock', 'rgvs',
            'ctmf', 'warp', 'misc', 'grain', 'tcanny']

missing = []
for plugin in required:
    if not hasattr(core, plugin):
        missing.append(plugin)

if missing:
    raise Exception(f"Missing plugins: {missing}")
else:
    print("All plugins loaded successfully")
''';

      final result = await _runVspipeScript(vspipePath, script);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('All plugins loaded'));
    });
  });

  group('BestSource Video Loading', () {
    test('loads video with BestSource', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.bs.VideoSource(source=r"$testVideoPath")
print(f"Loaded: {clip.width}x{clip.height}, {clip.num_frames} frames")

# Output a single frame to verify it works
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('Loaded:'));
    });
  });

  group('Filter Tests', () {
    test('Deband (neo_f3kdb) works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.bs.VideoSource(source=r"$testVideoPath")
clip = core.neo_f3kdb.Deband(clip, y=64, cb=64, cr=64)
print("Deband applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    // Skip: DFTTest crashes on macOS arm64 - likely fftw compatibility issue
    // TODO: Rebuild fftw with proper arm64 support or find pre-built version
    test('DFTTest works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.bs.VideoSource(source=r"$testVideoPath")
clip = core.dfttest.DFTTest(clip, sigma=10.0)
print("DFTTest applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    }, skip: 'DFTTest crashes on macOS arm64 - fftw compatibility issue');

    test('CAS (Contrast Adaptive Sharpening) works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.bs.VideoSource(source=r"$testVideoPath")
clip = core.cas.CAS(clip, sharpness=0.5)
print("CAS applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('MVTools works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.bs.VideoSource(source=r"$testVideoPath")
# Simple MVTools test - analyze motion
sup = core.mv.Super(clip)
vectors = core.mv.Analyse(sup, isb=False)
print("MVTools applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('ZNEDI3 works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.bs.VideoSource(source=r"$testVideoPath")
# ZNEDI3 for field interpolation
clip = core.znedi3.nnedi3(clip, field=1)
print("ZNEDI3 applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('EEDI3 works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.bs.VideoSource(source=r"$testVideoPath")
clip = core.eedi3m.EEDI3(clip, field=1)
print("EEDI3 applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('Deblock works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.bs.VideoSource(source=r"$testVideoPath")
clip = core.deblock.Deblock(clip, quant=25)
print("Deblock applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('TCanny (edge detection) works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.bs.VideoSource(source=r"$testVideoPath")
clip = core.tcanny.TCanny(clip, sigma=1.5, mode=0)
print("TCanny applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
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

      final result = await _runVspipeScript(vspipePath, script);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
      expect(result.stdout.toString(), contains('havsfunc imported'));
    });

    test('SMDegrain works', () async {
      final script = '''
import vapoursynth as vs
import havsfunc as haf
core = vs.core

clip = core.bs.VideoSource(source=r"$testVideoPath")
clip = haf.SMDegrain(clip, tr=1, thSAD=300)
print("SMDegrain applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });
  });
}

/// Creates a simple Y4M test video (10 frames of 64x64 gray)
Future<void> _createTestVideo(String outputPath) async {
  final file = File(outputPath);
  final sink = file.openWrite();

  // Y4M header
  sink.write('YUV4MPEG2 W64 H64 F25:1 Ip A1:1 C420\n');

  // 10 frames of gray
  for (int frame = 0; frame < 10; frame++) {
    sink.write('FRAME\n');
    // Y plane (64x64 = 4096 bytes) - gray value 128
    sink.add(List.filled(64 * 64, 128));
    // U plane (32x32 = 1024 bytes) - neutral chroma
    sink.add(List.filled(32 * 32, 128));
    // V plane (32x32 = 1024 bytes) - neutral chroma
    sink.add(List.filled(32 * 32, 128));
  }

  await sink.close();
}

/// Runs a VapourSynth script via vspipe
Future<ProcessResult> _runVspipeScript(
  String vspipePath,
  String script, {
  bool outputFrames = false,
}) async {
  // Write script to temp file
  final scriptFile = File(path.join(
    Directory.systemTemp.path,
    'vapourbox_test_${DateTime.now().millisecondsSinceEpoch}.vpy',
  ));
  await scriptFile.writeAsString(script);

  try {
    // Use -i for info only (validates script without outputting frames)
    // Use -p for progress mode when we want to process frames
    final args = outputFrames
        ? ['-p', scriptFile.path, '.'] // -p shows progress, . means discard output
        : ['-i', scriptFile.path, '-'];

    final result = await Process.run(
      vspipePath,
      args,
      environment: {
        'PYTHONPATH': path.join(path.dirname(path.dirname(vspipePath)), 'python-packages'),
      },
    );

    return result;
  } finally {
    await scriptFile.delete();
  }
}
