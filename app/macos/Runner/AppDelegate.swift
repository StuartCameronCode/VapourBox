import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Ignore SIGPIPE to prevent the app from being killed when a pipe
    // is broken (e.g. Dart VM service, rhttp Rust FFI cleanup).
    // This is a known Flutter macOS issue.
    signal(SIGPIPE, SIG_IGN)
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
