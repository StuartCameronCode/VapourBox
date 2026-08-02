/// The dependency install is verified by *running* a binary, not by checking
/// that files exist (issue #50).
///
/// macOS refuses to execute a quarantined binary — it SIGKILLs it — so a
/// complete, correct, version-matched install can still be unusable. The app
/// reported "Dependencies OK" in exactly that state, and the failure surfaced
/// much later as `ffmpeg exited with signal 9 (SIGKILL)`, an error naming
/// neither the cause nor the fix.
///
/// **What is not covered here.** The quarantine kill itself cannot be reproduced
/// on demand: writing `com.apple.quarantine` onto a binary macOS has already
/// assessed does not make it start failing (verified — it still runs), so a test
/// that set the attribute and asserted a kill would be asserting its own `xattr`
/// call rather than the OS. The quarantine branch of the diagnosis was confirmed
/// by hand against a genuinely quarantined install. What is pinned below is the
/// part that is deterministic and the part that actually regressed: a working
/// install passes, and an install whose ffmpeg cannot run is reported rather
/// than waved through.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/services/dependency_manager.dart';

/// A fake deps tree whose `ffmpeg/ffmpeg` behaves as [body] dictates.
Future<Directory> _fakeDeps({required String body, required bool executable}) async {
  final dir = await Directory.systemTemp.createTemp('vb_deps_probe_');
  final ffmpegDir = Directory(p.join(dir.path, 'ffmpeg'));
  await ffmpegDir.create(recursive: true);
  final ffmpeg = File(p.join(ffmpegDir.path, 'ffmpeg'));
  await ffmpeg.writeAsString(body);
  if (executable) await Process.run('chmod', ['+x', ffmpeg.path]);
  addTearDown(() => dir.delete(recursive: true).catchError((_) => dir));
  return dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('executabilityProblem', () {
    test('a binary that cannot be launched at all is reported', () async {
      // No exec bit: Process.run throws rather than returning an exit code.
      final deps = await _fakeDeps(body: 'not a binary', executable: false);

      final problem = await DependencyManager.instance
          .executabilityProblem(depsDirOverride: deps);

      expect(problem, isNotNull,
          reason: 'an unrunnable ffmpeg must not pass as usable');
      expect(problem, contains('could not be launched'));
    });

    test('a binary that runs but fails is reported with its exit code', () async {
      final deps = await _fakeDeps(
          body: '#!/bin/sh\necho "broken" >&2\nexit 3\n', executable: true);

      final problem = await DependencyManager.instance
          .executabilityProblem(depsDirOverride: deps);

      expect(problem, isNotNull);
      expect(problem, contains('exit 3'));
    });

    test('a working binary reports no problem', () async {
      final deps =
          await _fakeDeps(body: '#!/bin/sh\nexit 0\n', executable: true);

      expect(
          await DependencyManager.instance
              .executabilityProblem(depsDirOverride: deps),
          isNull);
    });

    test('a missing ffmpeg is left to the existence checks', () async {
      // Absence is checkDependencies' business — reporting it here as well would
      // give two different errors for one condition.
      final dir = await Directory.systemTemp.createTemp('vb_deps_empty_');
      addTearDown(() => dir.delete(recursive: true).catchError((_) => dir));

      expect(
          await DependencyManager.instance
              .executabilityProblem(depsDirOverride: dir),
          isNull);
    });
  },
      // /bin/sh shebangs and chmod; the production path is exercised on all
      // platforms but this fixture is POSIX-only.
      skip: Platform.isWindows ? 'POSIX fixture' : false);

  group('the real install', () {
    test('is runnable, so startup reports no problem', () async {
      final deps = await DependencyManager.instance.getDepsDirectory();
      if (!await File(p.join(deps.path, 'ffmpeg',
              Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg'))
          .exists()) {
        markTestSkipped('deps not installed here');
        return;
      }

      expect(await DependencyManager.instance.executabilityProblem(), isNull,
          reason: 'deps at ${deps.path} should be runnable — if this fails, '
              'try: xattr -cr "${deps.path}"');
    });
  });
}
