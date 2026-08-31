import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/dependency_manager.dart';

/// Guards the install swap's tolerance of a transient filesystem failure
/// (issue #87).
///
/// The reported symptom was `PathAccessException: Rename failed … (OS Error:
/// Access is denied, errno = 5)` on `deps\windows-x64.new`, after a complete
/// download and extraction — the very last step of the install. It reads like a
/// permissions problem and is not one: on Windows a directory rename is refused
/// while anything holds a handle on a descendant, which straight after writing
/// a ~200 MB bundle is routine and momentary.
void main() {
  group('retryTransientFsOperation', () {
    test('retries a transient failure and returns the eventual result',
        () async {
      var calls = 0;
      final result = await DependencyManager.retryTransientFsOperation(
        () async {
          calls++;
          if (calls < 3) {
            throw const PathAccessException(
                'x', OSError('Access is denied.', 5), 'Rename failed');
          }
          return 'swapped';
        },
        attempts: 5,
        firstDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 2),
      );

      expect(result, 'swapped');
      expect(calls, 3);
    });

    test('gives up after the attempt budget and rethrows the last error',
        () async {
      var calls = 0;
      await expectLater(
        DependencyManager.retryTransientFsOperation(
          () async {
            calls++;
            throw const PathAccessException(
                'x', OSError('Access is denied.', 5), 'Rename failed');
          },
          attempts: 4,
          firstDelay: const Duration(milliseconds: 1),
          maxDelay: const Duration(milliseconds: 2),
        ),
        throwsA(isA<PathAccessException>()),
      );
      expect(calls, 4);
    });

    // errno 183 rather than 5: the destination is already there and waiting
    // will not change that. Retrying it would spend the whole budget before
    // reporting a fault the user can act on.
    test('does not retry a destination that already exists', () async {
      var calls = 0;
      await expectLater(
        DependencyManager.retryTransientFsOperation(
          () async {
            calls++;
            throw const PathExistsException('x',
                OSError('Cannot create a file when that file already exists.', 183));
          },
          attempts: 6,
          firstDelay: const Duration(milliseconds: 1),
        ),
        throwsA(isA<PathExistsException>()),
      );
      expect(calls, 1);
    });

    test('does not retry a missing source', () async {
      var calls = 0;
      await expectLater(
        DependencyManager.retryTransientFsOperation(
          () async {
            calls++;
            throw const PathNotFoundException(
                'x', OSError('The system cannot find the file specified.', 2));
          },
          attempts: 6,
          firstDelay: const Duration(milliseconds: 1),
        ),
        throwsA(isA<PathNotFoundException>()),
      );
      expect(calls, 1);
    });

    test('passes a non-filesystem error straight through', () async {
      var calls = 0;
      await expectLater(
        DependencyManager.retryTransientFsOperation(
          () async {
            calls++;
            throw StateError('not a filesystem problem');
          },
          attempts: 6,
          firstDelay: const Duration(milliseconds: 1),
        ),
        throwsA(isA<StateError>()),
      );
      expect(calls, 1);
    });
  });

  // The real thing, on the platform that actually behaves this way. Skipped
  // elsewhere: POSIX renames a directory happily with its files open, so there
  // is nothing to reproduce.
  group('Windows directory rename with an open descendant', () {
    late Directory tmp;
    late Directory staging;
    late File held;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('vb_swap_test_');
      staging = Directory('${tmp.path}/deps.new');
      await Directory('${staging.path}/ffmpeg').create(recursive: true);
      held = File('${staging.path}/ffmpeg/ffmpeg.exe');
      await held.writeAsString('not really an executable');
    });

    tearDown(() async {
      await tmp.delete(recursive: true).catchError((_) => tmp);
    });

    test('a single attempt fails with access denied, not a permissions fault',
        () async {
      final handle = await held.open();
      try {
        await expectLater(
          staging.rename('${tmp.path}/deps'),
          throwsA(isA<PathAccessException>()
              .having((e) => e.osError?.errorCode, 'errno', 5)),
        );
      } finally {
        await handle.close();
      }
    });

    test('the retry rides out a handle that is released a moment later',
        () async {
      final handle = await held.open();
      // Whatever holds the handle — scanner, indexer, Explorer — lets go on its
      // own schedule, not ours.
      unawaited(Future<void>.delayed(const Duration(milliseconds: 250))
          .then((_) => handle.close()));

      final moved = await DependencyManager.retryTransientFsOperation(
        () => staging.rename('${tmp.path}/deps'),
        what: 'move the new install into place',
      );

      expect(await moved.exists(), isTrue);
      expect(await staging.exists(), isFalse);
      expect(
          await File('${tmp.path}/deps/ffmpeg/ffmpeg.exe').exists(), isTrue);
    });
  }, skip: !Platform.isWindows);
}
