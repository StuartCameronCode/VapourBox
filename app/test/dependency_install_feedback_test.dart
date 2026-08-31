import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/dependency_manager.dart';

/// What the install tells the user while it works and when it fails.
///
/// The dialog used to print one fixed line — "Please check your internet
/// connection and try again" — under whatever went wrong, and to say nothing at
/// all between the last extraction tick and "Complete". Both were wrong for the
/// failure in issue #87: the download had finished, and the advice sent the
/// reporter auditing folder permissions on a problem that was neither.
void main() {
  group('remedyFor', () {
    // The reported failure, exactly: errno 5 renaming the staged tree.
    final held = PathAccessException(
      r'D:\VapourBox\deps\windows-x64.new',
      const OSError('Access is denied', 5),
      'Rename failed',
    );

    test('a held file handle is not reported as a network problem', () {
      final remedy = DependencyManager.remedyFor(held);
      expect(remedy, isNot(contains('internet')));
      expect(remedy, isNotEmpty);
    });

    test('a held file handle names what actually holds it', () {
      final remedy = DependencyManager.remedyFor(held).toLowerCase();
      if (Platform.isWindows) {
        expect(remedy, contains('antivirus'));
        // The owner's first guess, and the reporter's — worth saying outright.
        expect(remedy, contains('not a permissions problem'));
      } else {
        expect(remedy, contains('permission'));
      }
    });

    test('a full disk says so rather than blaming the connection', () {
      final full = FileSystemException(
        'Cannot write file',
        r'D:\VapourBox\deps\windows-x64.new',
        OSError('There is not enough space on the disk',
            Platform.isWindows ? 112 : 28),
      );
      expect(DependencyManager.remedyFor(full), contains('disk space'));
    });

    test('an unrecognised failure still gets the connection advice', () {
      expect(
        DependencyManager.remedyFor(const SocketException('No route to host')),
        contains('internet connection'),
      );
    });

    test('an error carrying its own advice is passed through verbatim', () {
      // The macOS quarantine message already contains the xattr command; a
      // second, generic suggestion under it would only muddy that.
      expect(
        DependencyManager.remedyFor(
            DependencyInstallException('quarantined', remedy: '')),
        isEmpty,
      );
      expect(
        DependencyManager.remedyFor(
            DependencyInstallException('nope', remedy: 'do this instead')),
        'do this instead',
      );
    });

    test('the message is what the dialog shows, without an Exception prefix',
        () {
      expect(
        DependencyInstallException('the bundled ffmpeg would not run',
                remedy: '')
            .toString(),
        'the bundled ffmpeg would not run',
      );
    });
  });

  group('retry reporting', () {
    test('every failed attempt is reported, and a success is not', () async {
      final reported = <int>[];
      var calls = 0;

      await DependencyManager.retryTransientFsOperation(
        () async {
          calls++;
          if (calls < 4) {
            throw const PathAccessException(
                'x', OSError('Access is denied.', 5), 'Rename failed');
          }
          return null;
        },
        attempts: 6,
        firstDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 2),
        onRetry: (attempt, _) => reported.add(attempt),
      );

      // Three failures, three notices — the fourth attempt succeeded and must
      // not leave a "still waiting" message as the last thing on screen.
      expect(reported, [1, 2, 3]);
    });

    test('the attempt that exhausts the budget is not reported as a wait',
        () async {
      final reported = <int>[];
      await expectLater(
        DependencyManager.retryTransientFsOperation(
          () async => throw const PathAccessException(
              'x', OSError('Access is denied.', 5), 'Rename failed'),
          attempts: 3,
          firstDelay: const Duration(milliseconds: 1),
          onRetry: (attempt, _) => reported.add(attempt),
        ),
        throwsA(isA<PathAccessException>()),
      );
      // The last failure becomes the error, not another "waiting" message.
      expect(reported, [1, 2]);
    });
  });
}
