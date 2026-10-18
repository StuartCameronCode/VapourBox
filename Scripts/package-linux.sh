#!/bin/bash
# Package VapourBox for Linux
# Creates an AppImage (the primary download) and a tarball (the fallback) from
# the same tree: Flutter app + Rust worker + templates.
#
# Prerequisites:
# - Flutter SDK, Rust toolchain
# - Worker and app already built (or use without --skip-build)
# - For the AppImage: zsyncmake (apt install zsync), and a host of the target
#   architecture — appimagetool is fetched automatically, or set $APPIMAGETOOL
#
# Usage: ./Scripts/package-linux.sh --version X.Y.Z [--skip-build] [--arch x64|arm64]
#                                   [--skip-appimage] [--bundle-deps DIR]
#
# --bundle-deps DIR packs the deps zips found in DIR into the AppImage (never
# the tarball), so it runs with no network on first launch. DIR must hold the
# release assets for the version app/assets/deps-version.json names, each with
# its .sha256.json: the platform bundle, and on x64 the v2 delta as well.

set -e

VERSION="1.0.0"
SKIP_BUILD=false
SKIP_APPIMAGE=false
BUNDLE_DEPS=""
ARCH=""

# Pinned, and checksummed below: this binary assembles what users run.
APPIMAGETOOL_VERSION="1.9.1"
GITHUB_REPO="StuartCameronCode/VapourBox"
APP_ID="app.vapourbox.VapourBox"

while [[ $# -gt 0 ]]; do
    case $1 in
        --version) VERSION="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --arch) ARCH="$2"; shift 2 ;;
        --skip-appimage) SKIP_APPIMAGE=true; shift ;;
        --bundle-deps) BUNDLE_DEPS="$(cd "$2" && pwd)"; shift 2 ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --version X.Y.Z [--skip-build] [--arch x64|arm64] [--skip-appimage] [--bundle-deps DIR]"
            exit 1
            ;;
    esac
done

# Detect architecture if not specified
if [ -z "$ARCH" ]; then
    if [ "$(uname -m)" = "aarch64" ]; then
        ARCH="arm64"
    else
        ARCH="x64"
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
PACKAGE_NAME="VapourBox-$VERSION-linux-$ARCH"
PACKAGE_DIR="$DIST_DIR/$PACKAGE_NAME"

echo "=== Packaging VapourBox for Linux ($ARCH) ==="
echo "Version: $VERSION"
echo ""

STEP=1
TOTAL_STEPS=4
if ! $SKIP_BUILD; then
    TOTAL_STEPS=5
fi
if ! $SKIP_APPIMAGE; then
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi

# Build if needed
if ! $SKIP_BUILD; then
    echo "[$STEP/$TOTAL_STEPS] Building Rust worker..."
    cd "$PROJECT_ROOT/worker"
    cargo build --release
    STEP=$((STEP + 1))

    echo "[$STEP/$TOTAL_STEPS] Building Flutter app..."
    cd "$PROJECT_ROOT/app"
    flutter pub get
    dart run build_runner build --delete-conflicting-outputs
    flutter build linux --release
    STEP=$((STEP + 1))
else
    echo "[$STEP/$TOTAL_STEPS] Skipping build (--skip-build)"
    STEP=$((STEP + 1))
fi

# Determine Flutter build output directory
if [ "$ARCH" = "arm64" ]; then
    FLUTTER_BUNDLE="$PROJECT_ROOT/app/build/linux/arm64/release/bundle"
else
    FLUTTER_BUNDLE="$PROJECT_ROOT/app/build/linux/x64/release/bundle"
fi

if [ ! -d "$FLUTTER_BUNDLE" ]; then
    echo "ERROR: Flutter build output not found at $FLUTTER_BUNDLE"
    echo "Build the app first or check architecture."
    exit 1
fi

# Create package structure
echo "[$STEP/$TOTAL_STEPS] Creating package structure..."
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"
mkdir -p "$DIST_DIR"

# Copy Flutter build output (executable, lib/, data/)
cp -r "$FLUTTER_BUNDLE/"* "$PACKAGE_DIR/"

STEP=$((STEP + 1))

# Copy Rust worker
echo "[$STEP/$TOTAL_STEPS] Copying worker and templates..."
WORKER_BIN="$PROJECT_ROOT/worker/target/release/vapourbox-worker"
if [ ! -f "$WORKER_BIN" ]; then
    echo "ERROR: Worker executable not found at $WORKER_BIN"
    exit 1
fi
cp "$WORKER_BIN" "$PACKAGE_DIR/"
chmod +x "$PACKAGE_DIR/vapourbox-worker"

# Copy VapourSynth templates
mkdir -p "$PACKAGE_DIR/templates"
cp "$PROJECT_ROOT/worker/templates/"*.vpy "$PACKAGE_DIR/templates/"
# Glob, not a list of names — see the note in package-macos.sh.
cp "$PROJECT_ROOT/worker/templates/"*.py "$PACKAGE_DIR/templates/"
cp "$PROJECT_ROOT/worker/templates/spotless.py" "$PACKAGE_DIR/templates/"

# Copy licenses
mkdir -p "$PACKAGE_DIR/licenses"
cp -r "$PROJECT_ROOT/licenses/"* "$PACKAGE_DIR/licenses/" 2>/dev/null || true
[ -f "$PROJECT_ROOT/LICENSE" ] && cp "$PROJECT_ROOT/LICENSE" "$PACKAGE_DIR/"

STEP=$((STEP + 1))

# Create AppImage
#
# The AppImage holds exactly the tree the tarball does, under usr/lib/vapourbox,
# so the two cannot drift — plus, with --bundle-deps, the deps zips. Nothing
# inside it is written to at runtime: deps and add-ons install under
# $XDG_DATA_HOME, and a bundled zip is only ever read, by DependencyManager,
# which extracts it there instead of downloading it. The zips are bundled as
# published, not unpacked: the app verifies each against its sidecar and
# installs it through the same path as a download, and an older CPU gets the
# v2 delta extracted over the same bundle (see "CPU tiers" in CLAUDE.md).
APPIMAGE_FILE=""
if ! $SKIP_APPIMAGE; then
    echo "[$STEP/$TOTAL_STEPS] Creating AppImage..."

    if [ "$(uname -s)" != "Linux" ]; then
        echo "ERROR: an AppImage can only be built on Linux (or pass --skip-appimage)."
        exit 1
    fi

    case "$ARCH" in
        x64)
            AI_ARCH="x86_64"
            AI_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
            ;;
        arm64)
            AI_ARCH="aarch64"
            AI_SHA256="f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158"
            ;;
        *)
            echo "ERROR: no AppImage architecture for --arch $ARCH"
            exit 1
            ;;
    esac

    if [ "$(uname -m)" != "$AI_ARCH" ]; then
        echo "ERROR: building a $AI_ARCH AppImage needs a $AI_ARCH host (this is $(uname -m))."
        echo "       appimagetool is a native binary. Pass --skip-appimage for the tarball alone."
        exit 1
    fi

    # Without zsyncmake appimagetool still succeeds, and still embeds update
    # information — pointing at a .zsync that was never made. That is an
    # updater that fails for every user, so it is an error here, not a warning.
    if ! command -v zsyncmake >/dev/null 2>&1; then
        echo "ERROR: zsyncmake not found (apt install zsync)."
        echo "       It generates the .zsync file the AppImage's update information points at."
        exit 1
    fi

    if [ -z "$APPIMAGETOOL" ]; then
        TOOLS_DIR="$DIST_DIR/.tools"
        APPIMAGETOOL="$TOOLS_DIR/appimagetool-$APPIMAGETOOL_VERSION-$AI_ARCH.AppImage"
        if [ ! -f "$APPIMAGETOOL" ]; then
            mkdir -p "$TOOLS_DIR"
            curl -fsSL -o "$APPIMAGETOOL.part" \
                "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-$AI_ARCH.AppImage"
            if ! echo "$AI_SHA256  $APPIMAGETOOL.part" | sha256sum -c - >/dev/null; then
                echo "ERROR: appimagetool $APPIMAGETOOL_VERSION ($AI_ARCH) failed its checksum."
                rm -f "$APPIMAGETOOL.part"
                exit 1
            fi
            mv "$APPIMAGETOOL.part" "$APPIMAGETOOL"
        fi
        chmod +x "$APPIMAGETOOL"
    fi

    LINUX_PACKAGING="$PROJECT_ROOT/packaging/linux"
    APPDIR="$DIST_DIR/$PACKAGE_NAME.AppDir"
    rm -rf "$APPDIR"
    mkdir -p "$APPDIR/usr/lib" \
             "$APPDIR/usr/share/applications" \
             "$APPDIR/usr/share/metainfo" \
             "$APPDIR/usr/share/icons/hicolor/256x256/apps"
    cp -r "$PACKAGE_DIR" "$APPDIR/usr/lib/vapourbox"

    # Bundled deps. The app looks for exactly the file names its own
    # deps-version.json derives, so a zip of any other version would be ~240 MB
    # of dead weight that nothing reports; require the right ones, and check
    # each against its sidecar now rather than have every user's first launch
    # discover a bad copy and fall back to downloading.
    if [ -n "$BUNDLE_DEPS" ]; then
        DEPS_VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' \
            "$PROJECT_ROOT/app/assets/deps-version.json" | head -1)
        BUNDLED_ZIPS=("VapourBox-deps-$DEPS_VERSION-linux-$ARCH.zip")
        if [ "$ARCH" = "x64" ]; then
            BUNDLED_ZIPS+=("VapourBox-deps-$DEPS_VERSION-linux-$ARCH-v2-delta.zip")
        fi
        mkdir -p "$APPDIR/usr/lib/vapourbox/bundled-deps"
        for ZIP in "${BUNDLED_ZIPS[@]}"; do
            if [ ! -f "$BUNDLE_DEPS/$ZIP" ] || [ ! -f "$BUNDLE_DEPS/$ZIP.sha256.json" ]; then
                echo "ERROR: --bundle-deps: $BUNDLE_DEPS has no $ZIP (and its .sha256.json)."
                echo "       The app expects deps $DEPS_VERSION (app/assets/deps-version.json)."
                exit 1
            fi
            WANT=$(sed -n 's/.*"sha256": *"\([^"]*\)".*/\1/p' "$BUNDLE_DEPS/$ZIP.sha256.json")
            if ! echo "$WANT  $BUNDLE_DEPS/$ZIP" | sha256sum -c - >/dev/null; then
                echo "ERROR: --bundle-deps: $ZIP does not match its .sha256.json."
                exit 1
            fi
            cp "$BUNDLE_DEPS/$ZIP" "$BUNDLE_DEPS/$ZIP.sha256.json" \
                "$APPDIR/usr/lib/vapourbox/bundled-deps/"
            echo "    Bundled $ZIP"
        done
    else
        echo "    No --bundle-deps: this AppImage will download its deps on first launch."
    fi

    install -m 755 "$LINUX_PACKAGING/AppRun" "$APPDIR/AppRun"
    # appimagetool wants the desktop file and its icon at the root; the copies
    # under usr/share are what desktop-integration tools install from.
    cp "$LINUX_PACKAGING/$APP_ID.desktop" "$APPDIR/"
    cp "$LINUX_PACKAGING/$APP_ID.desktop" "$APPDIR/usr/share/applications/"
    cp "$LINUX_PACKAGING/$APP_ID.png" "$APPDIR/"
    cp "$LINUX_PACKAGING/$APP_ID.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/"
    ln -s "$APP_ID.png" "$APPDIR/.DirIcon"

    # AppStream metadata, with this release stamped in.
    sed -e "s/@VERSION@/$VERSION/g" -e "s/@DATE@/$(date -u +%Y-%m-%d)/g" \
        "$LINUX_PACKAGING/$APP_ID.appdata.xml" \
        > "$APPDIR/usr/share/metainfo/$APP_ID.appdata.xml"
    # Validated here, offline, when the tools are present (CI installs them):
    # appimagetool's own check goes to the network for the screenshot, whose
    # URL is this release's tag and does not exist until the release does.
    if command -v desktop-file-validate >/dev/null 2>&1; then
        desktop-file-validate "$APPDIR/$APP_ID.desktop"
    fi
    if command -v appstreamcli >/dev/null 2>&1; then
        appstreamcli validate --no-net "$APPDIR/usr/share/metainfo/$APP_ID.appdata.xml"
    fi

    # Named the way AppImages are: App-version-arch, with the machine's own
    # architecture name and no "linux" (every AppImage is for Linux; the
    # AppImage catalog flags it). The tarball keeps linux-$ARCH.
    #
    # "latest" follows GitHub's Latest release, which is why a deps or whisper
    # release must never be marked Latest (see CLAUDE.md). The wildcard stands
    # in for the version; the arch stays literal so x64 never updates to arm64.
    APPIMAGE_FILE="VapourBox-$VERSION-$AI_ARCH.AppImage"
    UPDATE_INFO="gh-releases-zsync|${GITHUB_REPO%%/*}|${GITHUB_REPO##*/}|latest|VapourBox-*-$AI_ARCH.AppImage.zsync"
    # 1.2.0, the only release under the old name, embedded the pattern
    # VapourBox-*-linux-<arch>.AppImage.zsync. Publishing this release's .zsync
    # under that name as well lets a 1.2.0 AppImage find it: the file's URL
    # header is relative and names the new AppImage, which then carries the new
    # pattern. Drop this once 1.2.0 is no longer worth updating from.
    LEGACY_ZSYNC="VapourBox-$VERSION-linux-$ARCH.AppImage.zsync"

    # appimagetool writes the .zsync into the working directory. It is itself
    # an AppImage; extract-and-run spares the build host from needing FUSE.
    cd "$DIST_DIR"
    rm -f "$APPIMAGE_FILE" "$APPIMAGE_FILE.zsync" "$LEGACY_ZSYNC"
    ARCH="$AI_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 VERSION="$VERSION" \
        "$APPIMAGETOOL" --no-appstream --updateinformation "$UPDATE_INFO" \
        "$APPDIR" "$APPIMAGE_FILE"

    if [ ! -s "$APPIMAGE_FILE" ] || [ ! -s "$APPIMAGE_FILE.zsync" ]; then
        echo "ERROR: appimagetool did not produce both $APPIMAGE_FILE and $APPIMAGE_FILE.zsync"
        exit 1
    fi
    chmod +x "$APPIMAGE_FILE"
    # The bridge only works if the .zsync points at the AppImage by a relative
    # name; an absolute or differently named URL would send 1.2.0 nowhere.
    if ! grep -a -q "^URL: $APPIMAGE_FILE\$" "$APPIMAGE_FILE.zsync"; then
        echo "ERROR: $APPIMAGE_FILE.zsync does not name $APPIMAGE_FILE as its URL;"
        echo "       the copy published as $LEGACY_ZSYNC would not update 1.2.0."
        exit 1
    fi
    cp "$APPIMAGE_FILE.zsync" "$LEGACY_ZSYNC"
    rm -rf "$APPDIR"

    STEP=$((STEP + 1))
fi

# Create tarball
echo "[$STEP/$TOTAL_STEPS] Creating tarball..."
cd "$DIST_DIR"
TAR_FILE="$PACKAGE_NAME.tar.gz"
tar -czf "$TAR_FILE" "$PACKAGE_NAME"

file_size_mb() {
    local bytes
    bytes=$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null)
    echo "scale=1; $bytes / 1048576" | bc
}
file_sha256() {
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1
}

# Cleanup unpacked directory
rm -rf "$PACKAGE_DIR"

echo ""
echo "=== Packaging Complete ==="
echo ""
if [ -n "$APPIMAGE_FILE" ]; then
    echo "  AppImage: $DIST_DIR/$APPIMAGE_FILE"
    echo "  Size:     $(file_size_mb "$APPIMAGE_FILE") MB"
    echo "  SHA256:   $(file_sha256 "$APPIMAGE_FILE")"
    echo "  Update:   $DIST_DIR/$APPIMAGE_FILE.zsync (upload it beside the AppImage)"
    echo "  Bridge:   $DIST_DIR/$LEGACY_ZSYNC (upload it too; updates 1.2.0)"
    echo ""
fi
echo "  Tarball:  $DIST_DIR/$TAR_FILE"
echo "  Size:     $(file_size_mb "$TAR_FILE") MB"
echo "  SHA256:   $(file_sha256 "$TAR_FILE")"
echo ""
echo "To run:"
if [ -n "$APPIMAGE_FILE" ]; then
    echo "  chmod +x $APPIMAGE_FILE && ./$APPIMAGE_FILE"
    echo "or:"
fi
echo "  tar -xzf $TAR_FILE"
echo "  cd $PACKAGE_NAME"
echo "  ./vapourbox"
echo ""
if [ -n "$APPIMAGE_FILE" ] && [ -n "$BUNDLE_DEPS" ]; then
    echo "Note: the AppImage carries its dependencies; the tarball downloads them on first launch."
else
    echo "Note: Dependencies will be downloaded on first launch."
fi
