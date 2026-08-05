#!/bin/bash
# Update version across all files
# Usage: ./Scripts/update-version.sh --app 0.2.0 [--deps 1.0.0 --deps-tag deps-v1.0.0]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

APP_VERSION=""
DEPS_VERSION=""
DEPS_TAG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --app)
            APP_VERSION="$2"
            shift 2
            ;;
        --deps)
            DEPS_VERSION="$2"
            shift 2
            ;;
        --deps-tag)
            DEPS_TAG="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Update app version if specified
if [ -n "$APP_VERSION" ]; then
    echo "Updating app version to $APP_VERSION..."

    # Update pubspec.yaml
    PUBSPEC="$PROJECT_ROOT/app/pubspec.yaml"
    if [ -f "$PUBSPEC" ]; then
        # Extract current build number or default to 1
        CURRENT_BUILD=$(grep '^version:' "$PUBSPEC" | sed 's/.*+\([0-9]*\).*/\1/')
        if [ -z "$CURRENT_BUILD" ] || [ "$CURRENT_BUILD" = "$(grep '^version:' "$PUBSPEC")" ]; then
            CURRENT_BUILD=1
        else
            CURRENT_BUILD=$((CURRENT_BUILD + 1))
        fi

        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/^version: .*/version: ${APP_VERSION}+${CURRENT_BUILD}/" "$PUBSPEC"
        else
            sed -i "s/^version: .*/version: ${APP_VERSION}+${CURRENT_BUILD}/" "$PUBSPEC"
        fi
        echo "  Updated pubspec.yaml: ${APP_VERSION}+${CURRENT_BUILD}"
    fi

    # Update Windows runner (for executable metadata)
    WIN_RUNNER="$PROJECT_ROOT/app/windows/runner/Runner.rc"
    if [ -f "$WIN_RUNNER" ]; then
        # Parse version components
        MAJOR=$(echo "$APP_VERSION" | cut -d. -f1)
        MINOR=$(echo "$APP_VERSION" | cut -d. -f2)
        PATCH=$(echo "$APP_VERSION" | cut -d. -f3)

        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/FILEVERSION .*/FILEVERSION ${MAJOR},${MINOR},${PATCH},0/" "$WIN_RUNNER"
            sed -i '' "s/PRODUCTVERSION .*/PRODUCTVERSION ${MAJOR},${MINOR},${PATCH},0/" "$WIN_RUNNER"
            sed -i '' "s/\"FileVersion\", \".*\"/\"FileVersion\", \"${APP_VERSION}.0\"/" "$WIN_RUNNER"
            sed -i '' "s/\"ProductVersion\", \".*\"/\"ProductVersion\", \"${APP_VERSION}.0\"/" "$WIN_RUNNER"
        else
            sed -i "s/FILEVERSION .*/FILEVERSION ${MAJOR},${MINOR},${PATCH},0/" "$WIN_RUNNER"
            sed -i "s/PRODUCTVERSION .*/PRODUCTVERSION ${MAJOR},${MINOR},${PATCH},0/" "$WIN_RUNNER"
            sed -i "s/\"FileVersion\", \".*\"/\"FileVersion\", \"${APP_VERSION}.0\"/" "$WIN_RUNNER"
            sed -i "s/\"ProductVersion\", \".*\"/\"ProductVersion\", \"${APP_VERSION}.0\"/" "$WIN_RUNNER"
        fi
        echo "  Updated Windows Runner.rc"
    fi

    # Update macOS Info.plist.
    #
    # PlistBuddy exists only on macOS, and this used to be the ONLY path — so
    # running this script from Windows or Linux skipped the plist without a word,
    # and the macOS DMG built by CI came out labelled with the previous version
    # while every other file said the new one. The plist is XML, so sed can do it
    # anywhere; PlistBuddy stays the preferred tool where it exists.
    MAC_PLIST="$PROJECT_ROOT/app/macos/Runner/Info.plist"
    if [ -f "$MAC_PLIST" ]; then
        if command -v /usr/libexec/PlistBuddy &> /dev/null; then
            /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$MAC_PLIST"
            /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$MAC_PLIST"
            echo "  Updated macOS Info.plist (PlistBuddy)"
        else
            # Replace the <string> on the line following each version key.
            for KEY in CFBundleShortVersionString CFBundleVersion; do
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    sed -i '' "/<key>${KEY}<\/key>/{n;s|<string>.*</string>|<string>${APP_VERSION}</string>|;}" "$MAC_PLIST"
                else
                    sed -i "/<key>${KEY}<\/key>/{n;s|<string>.*</string>|<string>${APP_VERSION}</string>|;}" "$MAC_PLIST"
                fi
            done
            echo "  Updated macOS Info.plist (sed)"
        fi

        # Never leave the plist behind again: fail loudly instead.
        if ! grep -q "<string>${APP_VERSION}</string>" "$MAC_PLIST"; then
            echo "ERROR: failed to set the version in $MAC_PLIST" >&2
            exit 1
        fi
    fi

    # Update Cargo.toml
    CARGO_TOML="$PROJECT_ROOT/worker/Cargo.toml"
    if [ -f "$CARGO_TOML" ]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/^version = \".*\"/version = \"${APP_VERSION}\"/" "$CARGO_TOML"
        else
            sed -i "s/^version = \".*\"/version = \"${APP_VERSION}\"/" "$CARGO_TOML"
        fi
        echo "  Updated worker/Cargo.toml"
    fi
fi

# Update deps version if specified
if [ -n "$DEPS_VERSION" ] || [ -n "$DEPS_TAG" ]; then
    echo "Updating deps version..."

    DEPS_JSON="$PROJECT_ROOT/app/assets/deps-version.json"
    if [ -f "$DEPS_JSON" ]; then
        if [ -n "$DEPS_VERSION" ]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"${DEPS_VERSION}\"/" "$DEPS_JSON"
                # Update filenames
                sed -i '' "s/VapourBox-deps-[0-9.]*-/VapourBox-deps-${DEPS_VERSION}-/g" "$DEPS_JSON"
            else
                sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"${DEPS_VERSION}\"/" "$DEPS_JSON"
                sed -i "s/VapourBox-deps-[0-9.]*-/VapourBox-deps-${DEPS_VERSION}-/g" "$DEPS_JSON"
            fi
            echo "  Updated deps version to $DEPS_VERSION"
        fi

        if [ -n "$DEPS_TAG" ]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s/\"releaseTag\": \"[^\"]*\"/\"releaseTag\": \"${DEPS_TAG}\"/" "$DEPS_JSON"
            else
                sed -i "s/\"releaseTag\": \"[^\"]*\"/\"releaseTag\": \"${DEPS_TAG}\"/" "$DEPS_JSON"
            fi
            echo "  Updated deps releaseTag to $DEPS_TAG"
        fi

        # Update release date
        TODAY=$(date +%Y-%m-%d)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/\"releaseDate\": \"[^\"]*\"/\"releaseDate\": \"${TODAY}\"/" "$DEPS_JSON"
        else
            sed -i "s/\"releaseDate\": \"[^\"]*\"/\"releaseDate\": \"${TODAY}\"/" "$DEPS_JSON"
        fi
    fi
fi

echo "Version update complete."
