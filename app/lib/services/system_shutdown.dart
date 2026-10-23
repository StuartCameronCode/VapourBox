import 'dart:io';

/// Shutting the computer down after a queue finishes (issue #123).
///
/// The rule throughout is **graceful, never forced**. Every command used here
/// asks the OS for an ordinary shutdown, which other applications may refuse
/// (an unsaved document, an inhibitor lock). That is the right failure for an
/// unattended run: the machine staying on costs some power; a forced shutdown
/// costs someone's unsaved work.
///
/// [check] runs when the user turns the option on, not when the queue ends, for
/// two reasons. It is the only time the user is known to be at the machine —
/// and on macOS the first Apple event raises a permission prompt, which at
/// shutdown time would sit unanswered all night. And it lets the option refuse
/// to arm on a machine that cannot honour it, rather than appearing to work and
/// leaving the computer on.
abstract class SystemShutdown {
  /// Whether this platform has a shutdown path at all. Decides whether the
  /// option is shown.
  bool get isSupported;

  /// Whether a shutdown would actually go through on this machine right now.
  /// Returns null if so, else a sentence saying why not.
  Future<String?> check();

  /// Ask the OS to shut down. Returns null if the request was accepted, else a
  /// sentence saying why not.
  Future<String?> shutDown();
}

/// Signature of [Process.run], so the commands can be asserted in a test.
typedef ProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

class PlatformSystemShutdown implements SystemShutdown {
  PlatformSystemShutdown({ProcessRunner? run, String? operatingSystem})
      : _run = run ?? Process.run,
        _os = operatingSystem ?? Platform.operatingSystem;

  final ProcessRunner _run;
  final String _os;

  @override
  bool get isSupported => _os == 'macos' || _os == 'windows' || _os == 'linux';

  @override
  Future<String?> check() async {
    switch (_os) {
      case 'macos':
        // A harmless event to System Events. The first one raises the
        // Automation prompt; -1743 means the user (now or earlier) said no.
        return _runOrExplain('osascript', [
          '-e',
          'tell application "System Events" to count processes',
        ], deniedHint: _macPermissionHint);
      case 'windows':
        // shutdown.exe ships with every Windows; nothing to ask in advance.
        return null;
      case 'linux':
        // logind answers "yes", "no", "challenge" (needs a password, which
        // nobody will be there to type) or "na".
        final ProcessResult result;
        try {
          result = await _run('busctl', [
            'call',
            'org.freedesktop.login1',
            '/org/freedesktop/login1',
            'org.freedesktop.login1.Manager',
            'CanPowerOff',
          ]);
        } on ProcessException {
          return 'This system has no systemd-logind, which VapourBox uses to '
              'power off.';
        }
        if (result.exitCode != 0) {
          return 'Could not ask systemd-logind whether power-off is allowed: '
              '${_firstLine(result.stderr)}';
        }
        final answer = '${result.stdout}';
        if (answer.contains('"yes"')) return null;
        if (answer.contains('"challenge"')) {
          return 'Powering off needs an administrator password on this '
              'system (for example, because another user is logged in), and '
              'nobody will be there to type it.';
        }
        return 'This system does not allow your account to power off.';
      default:
        return 'Shutting down is not supported on this platform.';
    }
  }

  @override
  Future<String?> shutDown() {
    switch (_os) {
      case 'macos':
        return _runOrExplain('osascript', [
          '-e',
          'tell application "System Events" to shut down',
        ], deniedHint: _macPermissionHint);
      case 'windows':
        // /t 0 is what keeps this unforced: any timeout above zero implies /f.
        return _runOrExplain('shutdown', ['/s', '/t', '0']);
      case 'linux':
        // Never prompt: a polkit dialog would wait all night.
        return _runOrExplain('systemctl', ['poweroff', '--no-ask-password']);
      default:
        return Future.value('Shutting down is not supported on this platform.');
    }
  }

  static const _macPermissionHint =
      'VapourBox is not allowed to control System Events. Allow it in System '
      'Settings → Privacy & Security → Automation, then try again.';

  Future<String?> _runOrExplain(String executable, List<String> args,
      {String? deniedHint}) async {
    try {
      final result = await _run(executable, args);
      if (result.exitCode == 0) return null;
      final stderr = '${result.stderr}';
      if (deniedHint != null && stderr.contains('-1743')) return deniedHint;
      return '$executable failed: ${_firstLine(stderr)}';
    } on ProcessException catch (e) {
      return 'Could not run $executable: ${e.message}';
    }
  }

  static String _firstLine(Object? text) {
    final line = '$text'.trim().split('\n').first.trim();
    return line.isEmpty ? 'no error message' : line;
  }
}
