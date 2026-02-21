#!/bin/bash
# Package VapourBox for macOS
# Creates a signed .app bundle inside a DMG with Applications shortcut
#
# Prerequisites:
# - Flutter SDK installed
# - Rust toolchain installed
# - Xcode Command Line Tools
# - For signing: Apple Developer ID certificate in Keychain
# - For notarization: credentials stored via `xcrun notarytool store-credentials`
#
# Usage: ./Scripts/package-macos.sh [OPTIONS]
#
# Options:
#   --version X.Y.Z          Set version number (default: 1.0.0)
#   --arch arm64|x64          Target architecture (default: auto-detect)
#   --skip-build              Skip Flutter and Rust compilation
#   --team-id ID              Apple Developer Team ID (default: PMXZ63S6YG)
#   --notarize                Submit to Apple notary service after signing
#   --keychain-profile NAME   Notarytool keychain profile name (default: VapourBox)
#   --no-sign                 Skip code signing (ad-hoc only, for local testing)

set -e

VERSION="1.0.0"
SKIP_BUILD=false
ARCH=""
TEAM_ID="PMXZ63S6YG"
NOTARIZE=false
KEYCHAIN_PROFILE="VapourBox"
NO_SIGN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --team-id)
            TEAM_ID="$2"
            shift 2
            ;;
        --notarize)
            NOTARIZE=true
            shift
            ;;
        --keychain-profile)
            KEYCHAIN_PROFILE="$2"
            shift 2
            ;;
        --no-sign)
            NO_SIGN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Detect architecture if not specified
if [ -z "$ARCH" ]; then
    if [ "$(uname -m)" = "arm64" ]; then
        ARCH="arm64"
    else
        ARCH="x64"
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="VapourBox"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ENTITLEMENTS="$PROJECT_ROOT/packaging/macos/distribution.entitlements"

# Determine total steps based on options
if $NO_SIGN; then
    TOTAL_STEPS=5
elif $NOTARIZE; then
    TOTAL_STEPS=7
else
    TOTAL_STEPS=6
fi

echo "=== Packaging VapourBox for macOS ($ARCH) ==="
echo ""

# Resolve signing identity
IDENTITY=""
if ! $NO_SIGN; then
    echo "Resolving Developer ID signing identity for team $TEAM_ID..."
    IDENTITY=$(security find-identity -v -p codesigning | grep "$TEAM_ID" | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    if [ -z "$IDENTITY" ]; then
        echo "ERROR: No Developer ID Application certificate found for team $TEAM_ID"
        echo "Available identities:"
        security find-identity -v -p codesigning
        echo ""
        echo "Use --no-sign to skip signing, or install a Developer ID certificate."
        exit 1
    fi
    echo "    Using identity: $IDENTITY"
    echo ""
fi

# Build Rust worker
STEP=1
if [ "$SKIP_BUILD" = false ]; then
    echo "[$STEP/$TOTAL_STEPS] Building Rust worker..."
    cd "$PROJECT_ROOT/worker"
    if [ "$ARCH" = "arm64" ]; then
        cargo build --release --target aarch64-apple-darwin
        WORKER_BIN="$PROJECT_ROOT/worker/target/aarch64-apple-darwin/release/vapourbox-worker"
    else
        cargo build --release --target x86_64-apple-darwin
        WORKER_BIN="$PROJECT_ROOT/worker/target/x86_64-apple-darwin/release/vapourbox-worker"
    fi
    # Fallback to default target if specific target not found
    if [ ! -f "$WORKER_BIN" ]; then
        cargo build --release
        WORKER_BIN="$PROJECT_ROOT/worker/target/release/vapourbox-worker"
    fi
    echo "    Rust worker built"

    # Build Flutter app (two-step xcodebuild — flutter build macos fails with module dependency errors)
    STEP=$((STEP + 1))
    echo "[$STEP/$TOTAL_STEPS] Building Flutter app..."
    cd "$PROJECT_ROOT/app"
    flutter pub get

    # Clean and reinstall CocoaPods
    echo "    Reinstalling CocoaPods..."
    cd "$PROJECT_ROOT/app/macos"
    rm -rf Pods Podfile.lock
    pod install

    # Step 1: Build Pods-Runner scheme (all CocoaPods dependencies)
    echo "    Building Pods-Runner scheme..."
    xcodebuild -workspace Runner.xcworkspace -scheme Pods-Runner \
        -configuration Release build ONLY_ACTIVE_ARCH=NO \
        -quiet

    # Step 2: Build Runner for arm64 only (must match Podfile ARCHS setting)
    echo "    Building Runner scheme (arm64)..."
    xcodebuild -workspace Runner.xcworkspace -scheme Runner \
        -configuration Release build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
        -quiet

    # Copy to Flutter build location
    DERIVED_APP=$(find ~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/Release/vapourbox.app -maxdepth 0 2>/dev/null | head -1)
    if [ -z "$DERIVED_APP" ]; then
        echo "ERROR: Could not find built app in DerivedData"
        exit 1
    fi
    mkdir -p "$PROJECT_ROOT/app/build/macos/Build/Products/Release"
    rm -rf "$PROJECT_ROOT/app/build/macos/Build/Products/Release/vapourbox.app"
    cp -R "$DERIVED_APP" "$PROJECT_ROOT/app/build/macos/Build/Products/Release/"
    echo "    Flutter app built"
else
    echo "[$STEP/$TOTAL_STEPS] Skipping Rust build (--skip-build)"
    STEP=$((STEP + 1))
    echo "[$STEP/$TOTAL_STEPS] Skipping Flutter build (--skip-build)"
    WORKER_BIN="$PROJECT_ROOT/worker/target/release/vapourbox-worker"
fi

# Create app bundle structure
STEP=$((STEP + 1))
echo "[$STEP/$TOTAL_STEPS] Creating app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$DIST_DIR"

# Copy Flutter app bundle as base
FLUTTER_APP="$PROJECT_ROOT/app/build/macos/Build/Products/Release/vapourbox.app"
if [ ! -d "$FLUTTER_APP" ]; then
    echo "ERROR: Flutter app bundle not found at $FLUTTER_APP"
    exit 1
fi
cp -R "$FLUTTER_APP" "$APP_BUNDLE"

# Create additional directories
CONTENTS="$APP_BUNDLE/Contents"
mkdir -p "$CONTENTS/Resources/templates"
mkdir -p "$CONTENTS/Resources/licenses"

# Copy Rust worker
STEP=$((STEP + 1))
echo "[$STEP/$TOTAL_STEPS] Copying Rust worker and templates..."
if [ ! -f "$WORKER_BIN" ]; then
    echo "ERROR: Worker executable not found at $WORKER_BIN"
    exit 1
fi
cp "$WORKER_BIN" "$CONTENTS/MacOS/vapourbox-worker"
chmod +x "$CONTENTS/MacOS/vapourbox-worker"

# Copy VapourSynth script templates (must be in Resources, not MacOS — macOS requires
# everything in MacOS/ to be signed Mach-O binaries)
cp "$PROJECT_ROOT/worker/templates/pipeline_template.vpy" "$CONTENTS/Resources/templates/"
cp "$PROJECT_ROOT/worker/templates/preview_template.vpy" "$CONTENTS/Resources/templates/"

# Copy licenses
cp -r "$PROJECT_ROOT/licenses/"* "$CONTENTS/Resources/licenses/"
cp "$PROJECT_ROOT/LICENSE" "$CONTENTS/Resources/LICENSE"

# Update Info.plist with version
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist" 2>/dev/null || true

# Sign the app bundle
STEP=$((STEP + 1))
if $NO_SIGN; then
    echo "[$STEP/$TOTAL_STEPS] Ad-hoc signing app bundle (--no-sign)..."
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
else
    echo "[$STEP/$TOTAL_STEPS] Signing app bundle with Developer ID..."
    echo "    Identity: $IDENTITY"

    if [ ! -f "$ENTITLEMENTS" ]; then
        echo "ERROR: Entitlements file not found at $ENTITLEMENTS"
        exit 1
    fi

    # Sign innermost first, never use --deep

    # 1. Sign all dylibs in Frameworks
    echo "    Signing frameworks and libraries..."
    find "$CONTENTS/Frameworks" -name "*.dylib" -type f 2>/dev/null | while read -r lib; do
        codesign --force --sign "$IDENTITY" --options runtime --timestamp "$lib"
    done

    # 2. Sign all framework bundles
    find "$CONTENTS/Frameworks" -name "*.framework" -type d 2>/dev/null | while read -r fw; do
        codesign --force --sign "$IDENTITY" --options runtime --timestamp "$fw"
    done

    # 3. Sign all .so files (Python extensions etc.)
    find "$CONTENTS" -name "*.so" -type f 2>/dev/null | while read -r so; do
        codesign --force --sign "$IDENTITY" --options runtime --timestamp "$so"
    done

    # 4. Sign helper executables
    echo "    Signing helper executables..."
    if [ -f "$CONTENTS/MacOS/vapourbox-worker" ]; then
        codesign --force --sign "$IDENTITY" --options runtime --timestamp "$CONTENTS/MacOS/vapourbox-worker"
    fi

    # 5. Sign the main app bundle with entitlements
    echo "    Signing app bundle..."
    codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

    # 6. Verify
    echo "    Verifying signature..."
    codesign --verify --deep --strict "$APP_BUNDLE"
    echo "    Signature verified OK"
fi

# Calculate app size
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo ""
echo "App bundle: $APP_BUNDLE ($APP_SIZE)"
echo ""

# Create DMG
STEP=$((STEP + 1))
DMG_NAME="$APP_NAME-$VERSION-macos-$ARCH"
DMG_FILE="$DIST_DIR/$DMG_NAME.dmg"
DMG_TEMP="$DIST_DIR/${DMG_NAME}_temp.dmg"
VOLUME_NAME="$APP_NAME $VERSION"

echo "[$STEP/$TOTAL_STEPS] Creating DMG..."

# Clean up any previous DMG files
rm -f "$DMG_FILE" "$DMG_TEMP"

# Calculate size needed (app size in KB + 20MB buffer)
APP_SIZE_KB=$(du -sk "$APP_BUNDLE" | cut -f1)
DMG_SIZE_KB=$((APP_SIZE_KB + 20480))

# Create temporary read-write DMG
hdiutil create -size "${DMG_SIZE_KB}k" -fs HFS+ -volname "$VOLUME_NAME" -type SPARSE "$DMG_TEMP"

# Mount the sparse image
MOUNT_OUTPUT=$(hdiutil attach "${DMG_TEMP}.sparseimage" -readwrite -noverify -noautoopen)
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/' | head -1)

if [ -z "$MOUNT_POINT" ]; then
    echo "ERROR: Failed to mount DMG"
    echo "$MOUNT_OUTPUT"
    exit 1
fi

echo "    Mounted at: $MOUNT_POINT"

# Copy app into DMG
cp -R "$APP_BUNDLE" "$MOUNT_POINT/"

# Create Applications symlink
ln -s /Applications "$MOUNT_POINT/Applications"

# Set Finder view options using AppleScript
echo "    Configuring DMG appearance..."
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 700, 500}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 100
        set position of item "$APP_NAME.app" of container window to {175, 200}
        set position of item "Applications" of container window to {425, 200}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

# Ensure changes are flushed
sync

# Unmount
hdiutil detach "$MOUNT_POINT" -quiet

# Convert to compressed read-only DMG
hdiutil convert "${DMG_TEMP}.sparseimage" -format UDZO -imagekey zlib-level=9 -o "$DMG_FILE"

# Clean up temp files
rm -f "${DMG_TEMP}.sparseimage"

DMG_SIZE=$(du -sh "$DMG_FILE" | cut -f1)
echo "    DMG created: $DMG_FILE ($DMG_SIZE)"

# Sign the DMG itself
if ! $NO_SIGN; then
    echo "    Signing DMG..."
    codesign --force --sign "$IDENTITY" --timestamp "$DMG_FILE"
    echo "    DMG signed OK"
fi

# Notarize
if $NOTARIZE && ! $NO_SIGN; then
    STEP=$((STEP + 1))
    echo ""
    echo "[$STEP/$TOTAL_STEPS] Notarizing with Apple..."
    echo "    Submitting to notary service (this may take several minutes)..."

    xcrun notarytool submit "$DMG_FILE" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    echo "    Stapling notarization ticket..."
    xcrun stapler staple "$DMG_FILE"
    echo "    Notarization complete"
fi

echo ""
echo "=== Packaging Complete ==="
echo ""
echo "  App bundle: $APP_BUNDLE ($APP_SIZE)"
echo "  DMG:        $DMG_FILE ($DMG_SIZE)"
echo ""
echo "Note: Dependencies (~94 MB) will be downloaded on first run."
echo ""
echo "To install:"
echo "  Open $DMG_FILE and drag VapourBox to Applications"
echo ""
echo "To distribute, share the DMG:"
echo "  $DMG_FILE"

if ! $NO_SIGN && ! $NOTARIZE; then
    echo ""
    echo "Note: App is signed but NOT notarized."
    echo "Run with --notarize to submit to Apple for Gatekeeper approval."
    echo ""
    echo "One-time setup for notarization:"
    echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
    echo "      --apple-id \"your-email@example.com\" \\"
    echo "      --team-id \"$TEAM_ID\" \\"
    echo "      --password \"app-specific-password-from-appleid.apple.com\""
fi
