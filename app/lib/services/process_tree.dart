import 'dart:io';

/// Terminating a worker without leaving its pipeline behind.
///
/// Signalling the worker's pid alone does not stop `vspipe` and `ffmpeg`. They
/// usually die shortly afterwards, but only incidentally — their pipes close
/// with the worker and they take EPIPE the next time they write. A child blocked
/// on slow input (a source on a network share is the reported case) writes
/// nothing for minutes, never notices, and is left running at full CPU on work
/// nobody is waiting for. Preview seeking makes this worse than it sounds: every
/// scrub cancels an in-flight preview, so the strays accumulate.
///
/// The worker puts itself in its own process group at startup (`setpgid` in
/// `worker/src/main.rs`), so its whole tree can be signalled at once by sending
/// to the negated pid. That is a deliberate teardown rather than a hopeful one.
class ProcessTree {
  /// Signal [process] and everything it spawned.
  ///
  /// Falls back to signalling the process alone when the group cannot be
  /// reached — an older worker that predates the `setpgid` call, or a platform
  /// without process groups. That fallback is exactly the previous behaviour, so
  /// this is never worse than what it replaced.
  ///
  /// Returns true if the group signal landed.
  static bool killTree(Process process, [ProcessSignal signal = ProcessSignal.sigterm]) {
    if (Platform.isWindows) {
      // No process groups; taskkill /T walks the tree instead. Callers on
      // Windows use that directly.
      return process.kill(signal);
    }
    // A negative pid addresses the process group. Dart forwards this to kill(2)
    // unchanged, and kill(2) defines negative pids as group targets.
    try {
      if (Process.killPid(-process.pid, signal)) return true;
    } on Object {
      // Fall through — some platforms reject a negative pid outright.
    }
    process.kill(signal);
    return false;
  }

  /// Wait for [process] to exit, escalating to SIGKILL if it outstays [grace].
  ///
  /// Returns true if it exited without needing to be forced.
  static Future<bool> waitForExit(
    Process process, {
    Duration grace = const Duration(seconds: 5),
    Duration forceGrace = const Duration(seconds: 3),
  }) async {
    try {
      await process.exitCode.timeout(grace);
      return true;
    } on Object {
      // Still alive. Forcing it here can orphan the children, which is the very
      // thing this class exists to avoid — so force the whole group, not just
      // the leader.
      killTree(process, ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(forceGrace);
      } on Object {
        // Nothing further we can do from here.
      }
      return false;
    }
  }
}
