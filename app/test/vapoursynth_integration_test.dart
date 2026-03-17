// End-to-end tests that verify VapourSynth plugins work correctly.
// These tests run actual vspipe commands to ensure all filters function.
// Uses FFmpeg to generate a test video, piped through pipe_source.py.
//
// Run with: flutter test test/vapoursynth_integration_test.dart
// Note: Requires platform-specific deps to be present with all plugins.

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
      vspipeExe = 'VSPipe.exe';
      ffmpegExe = 'ffmpeg.exe';
    } else if (Platform.isMacOS) {
      // Check architecture
      final archResult = await Process.run('uname', ['-m']);
      final arch = archResult.stdout.toString().trim();
      depsPlatform = arch == 'arm64' ? 'macos-arm64' : 'macos-x64';
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
        'VAPOURSYNTH_PLUGIN_PATH': path.join(vsDir, 'vs-plugins'),
      };
    } else {
      // macOS - the vspipe wrapper script handles most env setup
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

      // Feed the raw file to stdin
      final rawBytes = await rawFile.readAsBytes();
      process.stdin.add(rawBytes);
      await process.stdin.close();

      // Collect output
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      await Future.wait([
        process.stdout.transform(const SystemEncoding().decoder).forEach(stdout.write),
        process.stderr.transform(const SystemEncoding().decoder).forEach(stderr.write),
      ]);
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
