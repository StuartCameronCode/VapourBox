#!/bin/bash
# Build and run VapourBox debug app on Linux.
# Usage: ./Scripts/run-debug-linux.sh [--skip-worker] [--skip-app] [--run-only]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_DIR="$PROJECT_ROOT/app"
WORKER_DIR="$PROJECT_ROOT/worker"

# Detect architecture for bundle path
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    FLUTTER_ARCH="arm64"
else
    FLUTTER_ARCH="x64"
fi
BUNDLE_DIR="$APP_DIR/build/linux/$FLUTTER_ARCH/debug/bundle"

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
pkill -f "vapourbox" 2>/dev/null || true

# Build Rust worker (debug)
if ! $SKIP_WORKER; then
  echo "==> Building worker (debug)..."
  cd "$WORKER_DIR"
  cargo build
  echo "    Worker built."
fi

# Build Flutter app (debug)
if ! $SKIP_APP; then
  echo "==> Building Flutter app (debug)..."
  cd "$APP_DIR"
  flutter pub get --no-example > /dev/null 2>&1
  flutter build linux --debug
  echo "    Flutter app built."
fi

# Assemble debug bundle
echo "==> Assembling debug bundle..."

if [ ! -d "$BUNDLE_DIR" ]; then
  echo "ERROR: Flutter bundle not found at $BUNDLE_DIR"
  echo "Build the app first."
  exit 1
fi

# Copy worker binary
cp "$WORKER_DIR/target/debug/vapourbox-worker" "$BUNDLE_DIR/"

# Copy templates
mkdir -p "$BUNDLE_DIR/templates"
cp "$WORKER_DIR/templates/"*.vpy "$BUNDLE_DIR/templates/"
cp "$WORKER_DIR/templates/pipe_source.py" "$BUNDLE_DIR/templates/"
cp "$WORKER_DIR/templates/spotless.py" "$BUNDLE_DIR/templates/"

echo "==> Launching VapourBox (debug)..."
"$BUNDLE_DIR/vapourbox" &
echo "    Done. PID: $!"
