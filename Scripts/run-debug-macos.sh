#!/bin/bash
# Build and run VapourBox debug app on macOS.
# Usage: ./Scripts/run-debug-macos.sh [--skip-worker] [--skip-app] [--run-only]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_DIR="$PROJECT_ROOT/app"
WORKER_DIR="$PROJECT_ROOT/worker"
DEBUG_APP="$APP_DIR/build/macos/Build/Products/Debug/vapourbox.app"

SKIP_WORKER=false
SKIP_APP=false
RUN_ONLY=false

for arg in "$@"; do
  case $arg in
    --skip-worker) SKIP_WORKER=true ;;
    --skip-app) SKIP_APP=true ;;
    --run-only) RUN_ONLY=true ;;
    -h|--help)
      echo "Usage: $0 [--skip-worker] [--skip-app] [--run-only]"
      echo ""
      echo "Options:"
      echo "  --skip-worker  Skip building the Rust worker"
      echo "  --skip-app     Skip building the Flutter app"
      echo "  --run-only     Skip all builds, just copy and launch"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done

if $RUN_ONLY; then
  SKIP_WORKER=true
  SKIP_APP=true
fi

# Kill existing instance
pkill -f "vapourbox.app" 2>/dev/null || true

# Build Rust worker (debug)
if ! $SKIP_WORKER; then
  echo "==> Building worker (debug)..."
  (cd "$WORKER_DIR" && cargo build)
  echo "    Worker built."
fi

# Build Flutter app (debug).
#
# This calls `flutter build macos --debug` directly, not a raw `xcodebuild`
# invocation against Runner.xcworkspace — recent Flutter versions resolve
# several plugins (file_picker, package_info_plus, screen_retriever_macos,
# shared_preferences_foundation, url_launcher_macos, as of Flutter 3.47) via
# Swift Package Manager rather than CocoaPods, and only `flutter build`
# drives that resolution. A raw `xcodebuild -scheme Runner` call fails on
# those with "Unable to resolve module dependency", even with Pods-Runner
# built first (the fix for the *different*, older module-resolution issue
# this script used to work around).
if ! $SKIP_APP; then
  echo "==> Building Flutter app (debug)..."
  cd "$APP_DIR"
  flutter pub get --no-example > /dev/null

  # Remove what a previous run of *this script* injected below (worker
  # binary, templates) before rebuilding. Left in place, they confuse
  # Xcode's code-signing pass — "code object is not signed at all" on a
  # leftover .vpy file it never created — which fails the whole build.
  # Removing only these two paths (not the whole bundle) keeps Xcode's own
  # incremental build cache intact.
  rm -f "$DEBUG_APP/Contents/MacOS/vapourbox-worker"
  rm -rf "$DEBUG_APP/Contents/MacOS/templates"

  # No `|| true` and no piping through `grep` here: either of those would
  # swallow a real build failure (this is exactly how a previous version of
  # this script silently fell back to launching a stale, months-old app
  # bundle after `xcodebuild` failed). `set -e` above means a nonzero exit
  # here stops the script immediately, with Flutter's own error output
  # printed in full.
  flutter build macos --debug
  echo "    Flutter app built."
fi

if [ ! -d "$DEBUG_APP" ]; then
  echo "ERROR: $DEBUG_APP does not exist." >&2
  echo "Run without --skip-app / --run-only first to build it." >&2
  exit 1
fi

# Copy worker binary
echo "==> Assembling debug bundle..."
cp "$WORKER_DIR/target/debug/vapourbox-worker" "$DEBUG_APP/Contents/MacOS/"

# Copy templates (includes pipe_source.py used by VapourSynth scripts)
mkdir -p "$DEBUG_APP/Contents/MacOS/templates"
cp "$WORKER_DIR/templates/"*.vpy "$DEBUG_APP/Contents/MacOS/templates/"
cp "$WORKER_DIR/templates/pipe_source.py" "$DEBUG_APP/Contents/MacOS/templates/"
cp "$WORKER_DIR/templates/spotless.py" "$DEBUG_APP/Contents/MacOS/templates/"

# Always strip quarantine from deps. macOS SIGKILLs quarantined binaries
# (ffmpeg/ffprobe/vspipe) on exec, which surfaces as opaque "Failed to run
# ffmpeg" / 0x0 dimensions. xattr -cr is cheap and idempotent, so run it
# unconditionally rather than gating on a single file's current state.
if [ -d "$PROJECT_ROOT/deps/macos-arm64/" ]; then
  echo "    Removing quarantine from deps..."
  xattr -cr "$PROJECT_ROOT/deps/macos-arm64/" 2>/dev/null || true
fi

echo "==> Launching VapourBox (debug)..."
open "$DEBUG_APP"
echo "    Done."
