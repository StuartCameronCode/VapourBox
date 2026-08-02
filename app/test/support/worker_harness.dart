// Shared cross-platform harness for the integration tests in `app/test/`.
//
// These tests spawn the real `vapourbox-worker` binary (which runs
// `vspipe | ffmpeg`) and inspect the output with `ffprobe`. They run headless
// under `flutter test` on every CI platform — they render no Flutter UI, so
// they live in `test/` (not `integration_test/`, which routes through the
// device launcher).
//
// This harness consolidates everything the tests used to duplicate in a
// per-file `TestConfig`: locating the deps bundle, the worker, and ffmpeg/
// ffprobe; building the per-OS environment; and (new) DOWNLOADING the pinned
// deps release when the bundle is absent, so the tests are self-sufficient.
//
// Deps resolution order (see [ensureReady]):
//   1. $VAPOURBOX_DEPS_DIR  — set by CI, points straight at deps/<platform>.
//   2. <repoRoot>/deps/<platform>  — populated by Scripts/download-deps-*.
//   3. Download the version pinned in app/assets/deps-version.json into
//      <repoRoot>/deps/<platform> (skip with $VAPOURBOX_SKIP_DEPS_DOWNLOAD=1).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

// DepsVersionInfo (URL/filename derivation) and platformId are pure helpers —
// importing this file does NOT initialize the app's rhttp HTTP client, which is
// why the harness does its own dart:io download below (rhttp's native bindings
// don't load under the headless `flutter test` VM).
import 'package:vapourbox/services/dependency_manager.dart'
    show DepsVersionInfo, DependencyManager;

/// Static entry point used by every integration test's `setUpAll`/helpers.
class WorkerHarness {
  WorkerHarness._();

  static bool _ready = false;
  static String? _repoRoot;
  static String? _depsDir;
  static String? _workerPath;

  /// True once [ensureReady] has resolved deps + worker + input successfully.
  static bool get ready => _ready;

  // ---------------------------------------------------------------------------
  // Paths (mirror the old per-file TestConfig surface)
  // ---------------------------------------------------------------------------

  static const _exe = '';

  /// The repo root (directory containing CLAUDE.md), found by walking up from
  /// the current working directory (`app/` under `flutter test`).
  static String get repoRoot => _repoRoot ??= _findRepoRoot();

  /// Resolved platform-specific deps directory, e.g. `deps/macos-arm64`.
  /// Only valid after [ensureReady]; throws otherwise.
  static String get depsDir {
    final d = _depsDir;
    if (d == null) {
      throw StateError('Deps not resolved — call WorkerHarness.ensureReady() in setUpAll');
    }
    return d;
  }

  /// Platform identifier, e.g. `windows-x64`, `macos-arm64`, `linux-x64`.
  static String get platform => DependencyManager.instance.platformId;

  /// Path to the vapourbox-worker binary (debug preferred, then release —
  /// see [_findWorker] for why).
  static String get workerPath {
    final w = _workerPath;
    if (w == null) {
      throw StateError('Worker not resolved — call WorkerHarness.ensureReady() in setUpAll');
    }
    return w;
  }

  static String get _ext => Platform.isWindows ? '.exe' : _exe;

  /// Path to the bundled ffmpeg executable.
  static String get ffmpegPath => p.join(depsDir, 'ffmpeg', 'ffmpeg$_ext');

  /// Path to the bundled ffprobe executable.
  static String get ffprobePath => p.join(depsDir, 'ffmpeg', 'ffprobe$_ext');

  /// The interlaced test fixture used by most filter tests.
  static String get inputFile =>
      p.join(repoRoot, 'Tests', 'TestResources', 'interlaced_test.avi');

  /// Directory test outputs are written to.
  static String get outputDir => p.join(repoRoot, 'Tests', 'TestOutput');

  // ---------------------------------------------------------------------------
  // Whisper add-on (subtitle tests) — optional, provisioned separately
  // ---------------------------------------------------------------------------

  /// Directory the whisper add-on lives in, if resolvable.
  static String? get _addonsDir {
    final override = Platform.environment['VAPOURBOX_ADDONS_DIR'];
    if (override != null && override.isNotEmpty && Directory(override).existsSync()) {
      return override;
    }
    final repoAddons = p.join(repoRoot, 'addons');
    if (Directory(repoAddons).existsSync()) return repoAddons;
    return null;
  }

  /// Whether the whisper add-on (whisper-cli) is available. Subtitle tests that
  /// run the full pipeline must skip when this is false (local dev w/o add-on).
  static bool get whisperAvailable {
    final dir = _addonsDir;
    if (dir == null) return false;
    final cli = p.join(dir, 'whisper', 'whisper-cli$_ext');
    return File(cli).existsSync() ||
        File(p.join(dir, 'whisper', 'whisper-cli')).existsSync();
  }

  // ---------------------------------------------------------------------------
  // Environments
  // ---------------------------------------------------------------------------

  /// Fresh environment map for spawning the worker (PYTHON*, VAPOURSYNTH_*,
  /// PATH, and DYLD/LD_LIBRARY_PATH). Mirrors `ToolLocator._buildWorkerEnvironment`.
  static Map<String, String> get workerEnv {
    final env = Map<String, String>.from(Platform.environment);
    final d = depsDir;

    if (Platform.isWindows) {
      env['PYTHONHOME'] = p.join(d, 'vapoursynth');
      env['PYTHONPATH'] = p.join(d, 'vapoursynth', 'Lib', 'site-packages');
      env['VAPOURSYNTH_PLUGIN_PATH'] = p.join(d, 'vapoursynth', 'vs-plugins');
      final paths = [p.join(d, 'vapoursynth'), p.join(d, 'ffmpeg')];
      env['PATH'] = '${paths.join(';')};${env['PATH'] ?? ''}';
    } else {
      final bundledPython = Directory(p.join(d, 'python'));
      if (bundledPython.existsSync()) {
        env['PYTHONHOME'] = p.join(d, 'python');
      }
      env['PYTHONPATH'] = p.join(d, 'python-packages');
      env['PYTHONNOUSERSITE'] = '1';
      env['VAPOURSYNTH_PLUGIN_PATH'] = p.join(d, 'vapoursynth', 'plugins');

      final paths = <String>[];
      if (bundledPython.existsSync()) paths.add(p.join(d, 'python', 'bin'));
      paths.add(p.join(d, 'vapoursynth'));
      paths.add(p.join(d, 'ffmpeg'));
      env['PATH'] = '${paths.join(':')}:${env['PATH'] ?? ''}';

      final libVar = Platform.isMacOS ? 'DYLD_LIBRARY_PATH' : 'LD_LIBRARY_PATH';
      final libPaths = [
        p.join(d, 'vapoursynth'),
        p.join(d, 'python', 'lib'),
        if (Platform.isLinux) p.join(d, 'lib'),
      ];
      final existing = env[libVar] ?? '';
      env[libVar] =
          existing.isEmpty ? libPaths.join(':') : '${libPaths.join(':')}:$existing';
    }
    return env;
  }

  /// Fresh environment map for invoking ffmpeg/ffprobe directly (just needs the
  /// ffmpeg dir on PATH for any sibling libs).
  static Map<String, String> get ffmpegEnv {
    final env = Map<String, String>.from(Platform.environment);
    final sep = Platform.isWindows ? ';' : ':';
    env['PATH'] = '${p.join(depsDir, 'ffmpeg')}$sep${env['PATH'] ?? ''}';
    return env;
  }

  // ---------------------------------------------------------------------------
  // Readiness — call from setUpAll
  // ---------------------------------------------------------------------------

  /// Resolve (and if necessary download) the deps bundle, locate the worker and
  /// the input fixture, and create the output dir. Throws with an actionable
  /// message if anything required cannot be obtained.
  static Future<void> ensureReady() async {
    if (_ready) return;

    _depsDir = await _resolveDepsDir();
    if (_depsDir == null) {
      throw StateError(
        'VapourSynth deps unavailable for platform "$platform".\n'
        'Provision them with one of:\n'
        '  - Scripts/download-deps-${_scriptSuffix()}\n'
        '  - set VAPOURBOX_DEPS_DIR to an existing deps/<platform> directory\n'
        '  - allow the harness to download (unset VAPOURBOX_SKIP_DEPS_DOWNLOAD; needs network).',
      );
    }

    _workerPath = _resolveWorker();
    if (_workerPath == null) {
      throw StateError(
        'vapourbox-worker not found under worker/target/{release,debug}.\n'
        'Build it first: (cd worker && cargo build)',
      );
    }

    if (!File(inputFile).existsSync()) {
      throw StateError('Test input not found at $inputFile');
    }

    final out = Directory(outputDir);
    if (!out.existsSync()) out.createSync(recursive: true);

    // ignore: avoid_print
    print('WorkerHarness: platform=$platform\n'
        '  deps=$_depsDir\n  worker=$_workerPath\n  input=$inputFile');
    _ready = true;
  }

  // ---------------------------------------------------------------------------
  // Worker invocation
  // ---------------------------------------------------------------------------

  /// Run a full encode job through the worker. Pass the job as JSON
  /// (`job.toJson()`) so the harness stays independent of the app's models.
  static Future<JobResult> runJob(
    Map<String, dynamic> jobJson, {
    String label = 'job',
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final id = jobJson['id']?.toString() ?? 'job';
    final stopwatch = Stopwatch()..start();
    final logs = <String>[];
    final configFile = File(p.join(Directory.systemTemp.path, 'vb_$id.json'));
    await configFile.writeAsString(jsonEncode(jobJson));

    try {
      final process = await Process.start(
        workerPath,
        ['--config', configFile.path],
        environment: workerEnv,
        workingDirectory: File(workerPath).parent.path,
      );

      String? outputPath;
      bool? jobSuccess;
      String? errorMessage;

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.trim().isEmpty) return;
        logs.add(line);
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          switch (json['type'] as String?) {
            case 'complete':
              jobSuccess = json['success'] as bool?;
              outputPath = json['outputPath'] as String?;
            case 'error':
              errorMessage = json['message'] as String?;
          }
        } catch (_) {/* non-JSON log line */}
      });
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => logs.add('[stderr] $line'));

      final exitCode = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process.kill();
          throw TimeoutException('$label timed out after ${timeout.inSeconds}s');
        },
      );
      stopwatch.stop();

      if (exitCode == 0 && jobSuccess == true) {
        return JobResult(
          success: true,
          outputPath: outputPath,
          duration: stopwatch.elapsed,
          logs: logs,
          exitCode: exitCode,
        );
      }
      return JobResult(
        success: false,
        error: errorMessage ?? 'Worker exited with code $exitCode',
        duration: stopwatch.elapsed,
        logs: logs,
        exitCode: exitCode,
      );
    } catch (e) {
      stopwatch.stop();
      return JobResult(
        success: false,
        error: e.toString(),
        duration: stopwatch.elapsed,
        logs: logs,
      );
    } finally {
      await configFile.delete().catchError((_) => configFile);
    }
  }

  /// Run the worker just far enough to emit the generated `.vpy`, then kill it
  /// and return the script contents. The worker writes the script before vspipe
  /// starts, so we poll for it.
  static Future<String> generateScript(
    Map<String, dynamic> jobJson, {
    Duration pollFor = const Duration(seconds: 30),
  }) async {
    final id = jobJson['id']?.toString() ?? 'job';
    final configFile = File(p.join(Directory.systemTemp.path, 'vb_script_$id.json'));
    await configFile.writeAsString(jsonEncode(jobJson));
    final scriptPath = p.join(Directory.systemTemp.path, '$id.vpy');

    final process = await Process.start(
      workerPath,
      ['--config', configFile.path],
      environment: workerEnv,
      workingDirectory: File(workerPath).parent.path,
    );

    final logLines = <String>[];
    process.stdout.transform(utf8.decoder).listen((data) {
      for (final line in data.split('\n').where((l) => l.trim().isNotEmpty)) {
        logLines.add(line);
      }
    });
    process.stderr.transform(utf8.decoder).listen((_) {});

    String? scriptContent;
    final attempts = (pollFor.inMilliseconds / 500).ceil();
    for (var i = 0; i < attempts; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final f = File(scriptPath);
      if (await f.exists()) {
        scriptContent = await f.readAsString();
        break;
      }
      // If the worker already exited without writing the script, stop early.
      if (logLines.any((l) => l.contains('"type":"error"'))) break;
    }

    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      Process.killPid(process.pid, ProcessSignal.sigkill);
      return -1;
    });
    await configFile.delete().catchError((_) => configFile);
    final sf = File(scriptPath);
    if (await sf.exists()) await sf.delete().catchError((_) => sf);

    if (scriptContent == null) {
      throw StateError('Script not generated at $scriptPath\n'
          'Worker output:\n${logLines.join('\n')}');
    }
    return scriptContent;
  }

  // ---------------------------------------------------------------------------
  // ffprobe / ffmpeg verification helpers
  // ---------------------------------------------------------------------------

  /// Run ffprobe and return decoded JSON.
  static Future<Map<String, dynamic>> ffprobeJson(List<String> args) async {
    final result = await Process.run(ffprobePath, args, environment: ffmpegEnv);
    if (result.exitCode != 0) {
      throw Exception('ffprobe failed: ${result.stderr}');
    }
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  }

  /// First stream of [selector] (e.g. `a:0`, `v:0`) as a map, or null.
  static Future<Map<String, dynamic>?> firstStream(
    String videoPath, {
    required String selector,
    required List<String> entries,
    bool countFrames = false,
  }) async {
    final json = await ffprobeJson([
      '-v', 'error',
      '-select_streams', selector,
      if (countFrames) '-count_frames',
      '-show_entries', 'stream=${entries.join(',')}',
      '-of', 'json',
      videoPath,
    ]);
    final streams = json['streams'] as List?;
    if (streams == null || streams.isEmpty) return null;
    return streams.first as Map<String, dynamic>;
  }

  /// Mean luma and chroma of one frame, via ffmpeg's `signalstats`.
  ///
  /// The only way to check a colour operation actually moved colour in the
  /// direction it claims — a valid-output assertion would pass just as happily
  /// with the sign inverted.
  ///
  /// The file is fed through `-i`, which takes it as a plain argument and needs
  /// no escaping. Reading it with a `movie=` filtergraph source instead would
  /// require escaping the path for the graph parser, and no amount of escaping
  /// survives a Windows drive letter — the colon splits the graph and ffmpeg
  /// reports `Failed to avformat_open_input 'D'`.
  static Future<({double y, double u, double v})> frameAverages(
    String videoPath, {
    int frame = 2,
  }) async {
    final result = await Process.run(
      ffmpegPath,
      [
        '-v', 'error',
        '-i', videoPath,
        '-frames:v', '${frame + 1}',
        // `file=-` puts the metadata on stdout; the default writes it to the
        // log, which `-v error` would swallow.
        '-vf', 'signalstats,metadata=print:file=-',
        '-f', 'null', '-',
      ],
      environment: ffmpegEnv,
    );
    if (result.exitCode != 0) {
      throw Exception('signalstats probe failed: ${result.stderr}');
    }

    // One block per frame, each headed by `frame:N`. Take the last, so the
    // requested frame is the one measured rather than the first decoded.
    final blocks = (result.stdout as String).split(RegExp(r'^frame:', multiLine: true));
    final last = blocks.lastWhere((b) => b.contains('lavfi.signalstats.YAVG'),
        orElse: () => throw Exception(
            'signalstats produced no YAVG for $videoPath:\n${result.stdout}'));

    double tag(String name) {
      final m = RegExp('lavfi\\.signalstats\\.$name=([-0-9.]+)').firstMatch(last);
      if (m == null) {
        throw Exception('signalstats missing $name for $videoPath');
      }
      return double.parse(m.group(1)!);
    }

    return (y: tag('YAVG'), u: tag('UAVG'), v: tag('VAVG'));
  }

  /// Extract one frame as PNG and return its md5 hash.
  static Future<String> frameHash(String videoPath, {int frame = 5}) async {
    final framePath = p.join(Directory.systemTemp.path,
        'vb_frame_${DateTime.now().microsecondsSinceEpoch}_$frame.png');
    try {
      final result = await Process.run(
        ffmpegPath,
        ['-i', videoPath, '-vf', 'select=eq(n\\,$frame)', '-vframes', '1', '-y', framePath],
        environment: ffmpegEnv,
      );
      if (result.exitCode != 0) {
        throw Exception('frame extract failed: ${result.stderr}');
      }
      final bytes = await File(framePath).readAsBytes();
      return md5.convert(bytes).toString();
    } finally {
      final f = File(framePath);
      if (await f.exists()) await f.delete().catchError((_) => f);
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static String _findRepoRoot() {
    var dir = Directory.current;
    while (!File(p.join(dir.path, 'CLAUDE.md')).existsSync()) {
      final parent = dir.parent;
      if (parent.path == dir.path) {
        throw StateError('Could not find repo root (looking for CLAUDE.md)');
      }
      dir = parent;
    }
    return dir.path;
  }

  static String _scriptSuffix() {
    if (Platform.isWindows) return 'windows.ps1';
    if (Platform.isMacOS) return 'macos.sh';
    return 'linux.sh';
  }

  /// Critical files that must exist for a deps dir to count as usable.
  static List<String> _criticalFiles() {
    if (Platform.isWindows) {
      return ['vapoursynth/VSPipe.exe', 'vapoursynth/vs-plugins', 'ffmpeg/ffmpeg.exe'];
    }
    return ['vapoursynth/vspipe', 'vapoursynth/plugins', 'ffmpeg/ffmpeg'];
  }

  static bool _depsValid(String dir) {
    if (!Directory(dir).existsSync()) return false;
    for (final f in _criticalFiles()) {
      final fp = p.join(dir, f.replaceAll('/', p.separator));
      if (!File(fp).existsSync() && !Directory(fp).existsSync()) return false;
    }
    return true;
  }

  static Future<String?> _resolveDepsDir() async {
    // 1. Explicit override (CI).
    final override = Platform.environment['VAPOURBOX_DEPS_DIR'];
    if (override != null && override.isNotEmpty && _depsValid(override)) {
      return override;
    }

    // 2. Repo-local deps/<platform>.
    final local = p.join(repoRoot, 'deps', platform);
    if (_depsValid(local)) return local;

    // 3. Download the pinned release into deps/<platform>.
    if (Platform.environment['VAPOURBOX_SKIP_DEPS_DOWNLOAD'] == '1') return null;
    // ignore: avoid_print
    print('WorkerHarness: deps missing — downloading pinned release for $platform…');
    try {
      await _downloadDeps(local);
    } catch (e) {
      // ignore: avoid_print
      print('WorkerHarness: deps download failed: $e');
      return null;
    }
    return _depsValid(local) ? local : null;
  }

  static String? _resolveWorker() {
    final name = 'vapourbox-worker$_ext';
    // Prefer debug: it's the dev/CI canonical build (`cargo test`/`cargo build`
    // produce it), and preferring release would let a stale release binary
    // shadow a freshly-built debug one.
    for (final build in ['debug', 'release']) {
      final candidate = p.join(repoRoot, 'worker', 'target', build, name);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static DepsVersionInfo _loadDepsVersion() {
    final file = File(p.join(repoRoot, 'app', 'assets', 'deps-version.json'));
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return DepsVersionInfo.fromJson(json);
  }

  /// Download + extract the pinned deps zip into [destDir].
  static Future<void> _downloadDeps(String destDir) async {
    final info = _loadDepsVersion();
    final url = info.getDownloadUrl(platform);
    final expectedSha = await _fetchSidecarSha(info.getManifestUrl(platform));

    final tmp = await Directory.systemTemp.createTemp('vb_deps_');
    final zip = File(p.join(tmp.path, info.filenameFor(platform)));
    try {
      // ignore: avoid_print
      print('WorkerHarness: downloading $url');
      final bytes = await _httpGetBytes(url);
      if (expectedSha != null) {
        final actual = sha256.convert(bytes).toString();
        if (actual != expectedSha) {
          throw StateError('deps sha256 mismatch (expected $expectedSha, got $actual)');
        }
      }
      await zip.writeAsBytes(bytes);

      final dest = Directory(destDir);
      if (dest.existsSync()) dest.deleteSync(recursive: true);
      dest.createSync(recursive: true);

      final archive = ZipDecoder().decodeBytes(bytes);
      for (final f in archive) {
        final outPath = p.join(destDir, f.name);
        if (f.isFile) {
          final outFile = File(outPath);
          outFile.parent.createSync(recursive: true);
          outFile.writeAsBytesSync(f.content as List<int>);
          if (!Platform.isWindows && _isExecutable(f.name)) {
            await Process.run('chmod', ['+x', outPath]);
          }
        } else {
          Directory(outPath).createSync(recursive: true);
        }
      }

      if (Platform.isMacOS) {
        await Process.run('xattr', ['-cr', destDir]);
        // Ad-hoc re-sign dylibs/.so + known executables (Gatekeeper on Sequoia+).
        await Process.run('/bin/sh', [
          '-c',
          'find "\$1" -type f \\( -name "*.dylib" -o -name "*.so" \\) '
              '-exec codesign --force --sign - {} \\; 2>/dev/null',
          '--',
          destDir,
        ]);
        for (final exe in ['ffmpeg/ffmpeg', 'ffmpeg/ffprobe', 'vapoursynth/vspipe-bin']) {
          final f = p.join(destDir, exe);
          if (File(f).existsSync()) {
            await Process.run('codesign', ['--force', '--sign', '-', f]);
          }
        }
      }

      // Stamp installed version so a normal app run treats it as up-to-date.
      File(p.join(destDir, 'version.json')).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'version': info.versionFor(platform),
          'installedAt': DateTime.now().toIso8601String(),
        }),
      );
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  static bool _isExecutable(String fileName) {
    final name = p.basename(fileName).toLowerCase();
    return name == 'ffmpeg' ||
        name == 'ffprobe' ||
        name == 'vspipe' ||
        name == 'vspipe-bin' ||
        name.endsWith('.sh') ||
        !name.contains('.');
  }

  static Future<String?> _fetchSidecarSha(String url) async {
    try {
      final bytes = await _httpGetBytes(url);
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final sha = json['sha256'] as String?;
      return (sha != null && sha.isNotEmpty) ? sha : null;
    } catch (_) {
      return null; // best-effort: install without hash check (HTTPS-trusted)
    }
  }

  /// GET [url] following redirects manually so a GitHub auth token is only sent
  /// to github.com hosts (and stripped on the redirect to the CDN). Works for
  /// public release assets anonymously; honors $GH_TOKEN / $GITHUB_TOKEN for
  /// private repos.
  static Future<List<int>> _httpGetBytes(String url) async {
    final token =
        Platform.environment['GH_TOKEN'] ?? Platform.environment['GITHUB_TOKEN'];
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      var current = Uri.parse(url);
      for (var redirects = 0; redirects < 6; redirects++) {
        final request = await client.getUrl(current);
        request.followRedirects = false;
        final isGitHub = current.host.endsWith('github.com');
        if (token != null && isGitHub) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
        final response = await request.close();

        if (response.isRedirect) {
          final loc = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (loc == null) throw StateError('redirect without Location ($current)');
          current = current.resolve(loc);
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw HttpException('HTTP ${response.statusCode} for $current');
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          builder.add(chunk);
        }
        return builder.takeBytes();
      }
      throw StateError('too many redirects for $url');
    } finally {
      client.close(force: true);
    }
  }
}

/// Result of a full encode [WorkerHarness.runJob].
class JobResult {
  final bool success;
  final String? outputPath;
  final String? error;
  final Duration duration;
  final List<String> logs;
  final int? exitCode;

  JobResult({
    required this.success,
    this.outputPath,
    this.error,
    required this.duration,
    required this.logs,
    this.exitCode,
  });

  @override
  String toString() => success
      ? 'SUCCESS in ${duration.inSeconds}s -> $outputPath'
      : 'FAILED: $error (exit code: $exitCode)';
}
