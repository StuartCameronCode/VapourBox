// End-to-end tests that verify VapourSynth plugins work correctly.
// These tests run actual vspipe commands to ensure all filters function.
//
// Run with: flutter test test/vapoursynth_integration_test.dart
// Note: Requires platform-specific deps to be present with all plugins.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late String depsDir;
  late String vspipePath;

  setUpAll(() async {
    // Find the deps directory relative to the test file
    final scriptDir = Directory.current.path;

    // Determine platform-specific deps folder
    final String depsPlatform;
    final String vspipeExe;
    if (Platform.isWindows) {
      depsPlatform = 'windows-x64';
      vspipeExe = 'VSPipe.exe';
    } else if (Platform.isMacOS) {
      // Check architecture
      final archResult = await Process.run('uname', ['-m']);
      final arch = archResult.stdout.toString().trim();
      depsPlatform = arch == 'arm64' ? 'macos-arm64' : 'macos-x64';
      vspipeExe = 'vspipe';
    } else {
      throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
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

# List all required plugins (core set that works on both Windows and macOS)
required = ['std', 'resize', 'mv', 'znedi3', 'eedi3m', 'fmtc',
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

  group('Filter Tests', () {
    test('Deband (neo_f3kdb) works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10, fpsnum=25, fpsden=1)
clip = core.neo_f3kdb.Deband(clip, y=64, cb=64, cr=64)
print("Deband applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('DFTTest works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10, fpsnum=25, fpsden=1)
clip = core.dfttest.DFTTest(clip, sigma=10.0)
print("DFTTest applied successfully")
clip = clip[0]
clip.set_output()
''';

      final result = await _runVspipeScript(vspipePath, script, outputFrames: true);
      expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');
    });

    test('CAS (Contrast Adaptive Sharpening) works', () async {
      final script = '''
import vapoursynth as vs
core = vs.core

clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10, fpsnum=25, fpsden=1)
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

clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10, fpsnum=25, fpsden=1)
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

clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10, fpsnum=25, fpsden=1)
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

clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10, fpsnum=25, fpsden=1)
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

clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10, fpsnum=25, fpsden=1)
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

clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10, fpsnum=25, fpsden=1)
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

clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10, fpsnum=25, fpsden=1)
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

    // Build platform-specific environment
    final depsDir = path.dirname(path.dirname(vspipePath));
    final Map<String, String> environment;

    if (Platform.isWindows) {
      final vsDir = path.join(depsDir, 'vapoursynth');
      environment = {
        'PYTHONHOME': vsDir,
        'PYTHONPATH': path.join(vsDir, 'Lib', 'site-packages'),
        'VAPOURSYNTH_PLUGIN_PATH': path.join(vsDir, 'vs-plugins'),
      };
    } else {
      // macOS - the vspipe wrapper script handles most env setup
      environment = {
        'PYTHONPATH': path.join(depsDir, 'python-packages'),
      };
    }

    final result = await Process.run(
      vspipePath,
      args,
      environment: environment,
    );

    return result;
  } finally {
    await scriptFile.delete();
  }
}
