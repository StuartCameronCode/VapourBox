#!/bin/bash
# Build and run VapourBox debug app on macOS.
# Usage: ./Scripts/run-debug-macos.sh [--skip-worker] [--skip-app] [--run-only]

set -e

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
  cd "$WORKER_DIR"
  cargo build
  echo "    Worker built."
fi

# Build Flutter app (debug) via xcodebuild
if ! $SKIP_APP; then
  echo "==> Building Flutter app (debug)..."
  cd "$APP_DIR"
  flutter pub get --no-example > /dev/null 2>&1

  cd "$APP_DIR/macos"
  xcodebuild -workspace Runner.xcworkspace \
    -scheme Runner \
    -configuration Debug \
    build \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    2>&1 | grep -E '(error:|warning:|BUILD|Compiling)' || true

  echo "    Flutter app built."
fi

# Copy app bundle from DerivedData to Flutter build location
echo "==> Assembling debug bundle..."
DERIVED_APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Runner-*/Build/Products/Debug/vapourbox.app" -maxdepth 5 2>/dev/null | head -1)
if [ -z "$DERIVED_APP" ]; then
  echo "ERROR: Could not find built app in DerivedData. Build the app first."
  exit 1
fi

mkdir -p "$APP_DIR/build/macos/Build/Products/Debug"
rm -rf "$DEBUG_APP"
cp -R "$DERIVED_APP" "$DEBUG_APP"

# Copy worker binary
cp "$WORKER_DIR/target/debug/vapourbox-worker" "$DEBUG_APP/Contents/MacOS/"

# Copy templates
mkdir -p "$DEBUG_APP/Contents/MacOS/templates"
cp "$WORKER_DIR/templates/"*.vpy "$DEBUG_APP/Contents/MacOS/templates/"

# Remove quarantine from deps if present
if xattr "$PROJECT_ROOT/deps/macos-arm64/ffmpeg/ffmpeg" 2>/dev/null | grep -q quarantine; then
  echo "    Removing quarantine from deps..."
  xattr -cr "$PROJECT_ROOT/deps/macos-arm64/" 2>/dev/null || true
fi

echo "==> Launching VapourBox (debug)..."
open "$DEBUG_APP"
echo "    Done."
