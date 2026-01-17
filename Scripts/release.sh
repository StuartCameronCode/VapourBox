#!/bin/bash
# VapourBox Release Script
# Main orchestrator for creating releases
#
# This script:
# 1. Prompts for version (defaults to 0.1 above current GitHub release)
# 2. Checks if dependencies changed since last deps release
# 3. Packages and releases deps if needed
# 4. Updates version across all project files
# 5. Builds the macOS app locally
# 6. Triggers GitHub Actions for Windows build
# 7. Creates draft GitHub release
#
# Prerequisites:
# - gh CLI installed and authenticated
# - Flutter SDK
# - Rust toolchain
# - Dependencies downloaded (deps/ directories populated)
#
# Usage: ./Scripts/release.sh [--skip-deps-check] [--skip-build] [--dry-run]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Options
SKIP_DEPS_CHECK=false
SKIP_BUILD=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-deps-check)
            SKIP_DEPS_CHECK=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-deps-check  Skip dependency change detection"
            echo "  --skip-build       Skip building (use existing builds)"
            echo "  --dry-run          Show what would be done without executing"
            echo "  -h, --help         Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Read GitHub repo from deps-version.json
GITHUB_REPO=$(grep '"githubRepo"' "$PROJECT_ROOT/app/assets/deps-version.json" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/')
if [ -z "$GITHUB_REPO" ]; then
    GITHUB_REPO="StuartCameron/VapourBox"
fi

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              VapourBox Release Script                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "GitHub Repository: ${GREEN}$GITHUB_REPO${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v gh &> /dev/null; then
    echo -e "${RED}ERROR: gh CLI not found. Install from https://cli.github.com/${NC}"
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo -e "${RED}ERROR: gh CLI not authenticated. Run 'gh auth login'${NC}"
    exit 1
fi

if ! command -v flutter &> /dev/null; then
    echo -e "${RED}ERROR: Flutter not found in PATH${NC}"
    exit 1
fi

if ! command -v cargo &> /dev/null; then
    echo -e "${RED}ERROR: Rust/Cargo not found in PATH${NC}"
    exit 1
fi

echo -e "${GREEN}Prerequisites OK${NC}"
echo ""

# Get current versions from GitHub
echo -e "${YELLOW}Fetching current versions from GitHub...${NC}"

CURRENT_APP_VERSION=$("$SCRIPT_DIR/get-github-version.sh" --app)
CURRENT_DEPS_VERSION=$("$SCRIPT_DIR/get-github-version.sh" --deps)
NEXT_APP_VERSION=$("$SCRIPT_DIR/get-github-version.sh" --next-app)

echo "Current app version:  v$CURRENT_APP_VERSION"
echo "Current deps version: deps-v$CURRENT_DEPS_VERSION"
echo "Suggested next app:   v$NEXT_APP_VERSION"
echo ""

# Prompt for app version
read -p "Enter app version [$NEXT_APP_VERSION]: " INPUT_APP_VERSION
APP_VERSION="${INPUT_APP_VERSION:-$NEXT_APP_VERSION}"

# Validate version format
if ! [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}ERROR: Invalid version format. Use X.Y.Z (e.g., 0.2.0)${NC}"
    exit 1
fi

echo ""
echo -e "App version: ${GREEN}v$APP_VERSION${NC}"
echo ""

# Check if deps changed
DEPS_CHANGED=false
DEPS_VERSION="$CURRENT_DEPS_VERSION"

if $SKIP_DEPS_CHECK; then
    echo -e "${YELLOW}Skipping dependency change check${NC}"
else
    echo -e "${YELLOW}Checking if dependencies have changed...${NC}"

    if "$SCRIPT_DIR/check-deps-changed.sh"; then
        DEPS_CHANGED=true
        # Calculate next deps version
        DEPS_MAJOR=$(echo "$CURRENT_DEPS_VERSION" | cut -d. -f1)
        DEPS_MINOR=$(echo "$CURRENT_DEPS_VERSION" | cut -d. -f2)
        NEW_DEPS_MINOR=$((DEPS_MINOR + 1))
        SUGGESTED_DEPS_VERSION="${DEPS_MAJOR}.${NEW_DEPS_MINOR}.0"

        echo ""
        echo -e "${YELLOW}Dependencies have changed since deps-v$CURRENT_DEPS_VERSION${NC}"
        read -p "Enter new deps version [$SUGGESTED_DEPS_VERSION]: " INPUT_DEPS_VERSION
        DEPS_VERSION="${INPUT_DEPS_VERSION:-$SUGGESTED_DEPS_VERSION}"
    else
        echo -e "${GREEN}Dependencies unchanged - will use existing deps-v$DEPS_VERSION${NC}"
    fi
fi

DEPS_TAG="deps-v$DEPS_VERSION"

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                      Release Summary                          ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  App Version:  ${GREEN}v$APP_VERSION${NC}"
echo -e "  Deps Version: ${GREEN}$DEPS_TAG${NC}"
echo -e "  Deps Changed: $([ "$DEPS_CHANGED" = true ] && echo -e "${YELLOW}Yes - will create new deps release${NC}" || echo -e "${GREEN}No${NC}")"
echo ""

if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN - showing what would be done:${NC}"
    echo ""
    if $DEPS_CHANGED; then
        echo "  1. Package dependencies for macOS (arm64 + x64)"
        echo "  2. Create GitHub release: $DEPS_TAG"
        echo "  3. Upload deps zip files to release"
    fi
    echo "  4. Update version to $APP_VERSION in all project files"
    echo "  5. Update deps-version.json to reference $DEPS_TAG"
    echo "  6. Build macOS app"
    echo "  7. Trigger GitHub Actions for Windows build"
    echo "  8. Create draft GitHub release: v$APP_VERSION"
    echo ""
    echo -e "${YELLOW}Exiting dry run${NC}"
    exit 0
fi

read -p "Proceed with release? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Release cancelled"
    exit 0
fi

echo ""

# Step 1: Package and release dependencies if changed
if $DEPS_CHANGED; then
    echo -e "${BLUE}[1/6] Packaging dependencies...${NC}"

    # Package macOS deps
    if [ -d "$PROJECT_ROOT/deps/macos-arm64" ] || [ -d "$PROJECT_ROOT/deps/macos-x64" ]; then
        "$SCRIPT_DIR/package-deps-macos.sh" --version "$DEPS_VERSION" --arch both || true
    fi

    # Package Windows deps (if on Windows or deps exist)
    if [ -d "$PROJECT_ROOT/deps/windows-x64" ]; then
        echo -e "${YELLOW}Windows deps found. Package manually on Windows or copy existing.${NC}"
        # On macOS we can still create the zip if deps directory exists
        WINDOWS_PACKAGE_DIR="$PROJECT_ROOT/dist/VapourBox-deps-$DEPS_VERSION-windows-x64"
        rm -rf "$WINDOWS_PACKAGE_DIR"
        mkdir -p "$WINDOWS_PACKAGE_DIR"
        cp -r "$PROJECT_ROOT/deps/windows-x64/"* "$WINDOWS_PACKAGE_DIR/"

        # Create version file
        cat > "$WINDOWS_PACKAGE_DIR/version.json" << EOF
{
  "version": "$DEPS_VERSION",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

        # Create zip
        cd "$PROJECT_ROOT/dist"
        zip -r -q "VapourBox-deps-$DEPS_VERSION-windows-x64.zip" "VapourBox-deps-$DEPS_VERSION-windows-x64"
        rm -rf "$WINDOWS_PACKAGE_DIR"
        echo "Created: dist/VapourBox-deps-$DEPS_VERSION-windows-x64.zip"
    fi

    echo ""
    echo -e "${BLUE}[2/6] Creating deps release on GitHub...${NC}"

    # Create deps release
    DEPS_NOTES="## VapourBox Dependencies $DEPS_VERSION

This release contains pre-built dependencies for VapourBox.

### Contents
- VapourSynth portable with plugins
- FFmpeg
- Python packages (havsfunc, mvsfunc, etc.)

### Downloads
- \`VapourBox-deps-$DEPS_VERSION-windows-x64.zip\` - Windows x64
- \`VapourBox-deps-$DEPS_VERSION-macos-arm64.zip\` - macOS Apple Silicon
- \`VapourBox-deps-$DEPS_VERSION-macos-x64.zip\` - macOS Intel

These dependencies are automatically downloaded by the app on first launch."

    gh release create "$DEPS_TAG" \
        --repo "$GITHUB_REPO" \
        --title "Dependencies $DEPS_VERSION" \
        --notes "$DEPS_NOTES" \
        "$PROJECT_ROOT/dist/VapourBox-deps-$DEPS_VERSION-"*.zip 2>/dev/null || {
            echo -e "${YELLOW}Uploading assets to existing release...${NC}"
            for f in "$PROJECT_ROOT/dist/VapourBox-deps-$DEPS_VERSION-"*.zip; do
                [ -f "$f" ] && gh release upload "$DEPS_TAG" "$f" --repo "$GITHUB_REPO" --clobber
            done
        }

    echo -e "${GREEN}Deps release created: $DEPS_TAG${NC}"
else
    echo -e "${BLUE}[1/6] Skipping deps packaging (unchanged)${NC}"
    echo -e "${BLUE}[2/6] Skipping deps release (unchanged)${NC}"
fi

echo ""
echo -e "${BLUE}[3/6] Updating version numbers...${NC}"

# Update version across project
"$SCRIPT_DIR/update-version.sh" --app "$APP_VERSION" --deps "$DEPS_VERSION" --deps-tag "$DEPS_TAG"

echo ""
echo -e "${BLUE}[4/6] Building macOS app...${NC}"

if $SKIP_BUILD; then
    echo "Skipping build (--skip-build)"
else
    # Build Rust worker
    echo "Building Rust worker..."
    cd "$PROJECT_ROOT/worker"
    cargo build --release

    # Build Flutter app
    echo "Building Flutter app..."
    cd "$PROJECT_ROOT/app"
    flutter pub get
    flutter build macos --release

    # Package macOS app
    echo "Packaging macOS app..."
    "$SCRIPT_DIR/package-macos.sh" --version "$APP_VERSION" --skip-build
fi

echo ""
echo -e "${BLUE}[5/6] Triggering Windows build...${NC}"

# Check if GitHub Actions workflow exists
if [ -f "$PROJECT_ROOT/.github/workflows/build-windows.yml" ]; then
    echo "Triggering GitHub Actions workflow for Windows build..."
    gh workflow run build-windows.yml \
        --repo "$GITHUB_REPO" \
        --ref "main" \
        -f version="$APP_VERSION" \
        -f deps_tag="$DEPS_TAG" || {
            echo -e "${YELLOW}Could not trigger workflow. You may need to build Windows manually.${NC}"
        }
else
    echo -e "${YELLOW}No Windows build workflow found at .github/workflows/build-windows.yml${NC}"
    echo -e "${YELLOW}Build Windows manually using: ./Scripts/package-windows.ps1 -Version $APP_VERSION${NC}"
fi

echo ""
echo -e "${BLUE}[6/6] Creating app release draft...${NC}"

# Gather release assets
RELEASE_ASSETS=()
for f in "$PROJECT_ROOT/dist/VapourBox-$APP_VERSION-macos-"*.zip; do
    [ -f "$f" ] && RELEASE_ASSETS+=("$f")
done

# Create release notes
RELEASE_NOTES="## VapourBox $APP_VERSION

### What's New
- TODO: Add release notes

### Downloads
- **Windows**: \`VapourBox-$APP_VERSION-windows-x64.zip\`
- **macOS (Apple Silicon)**: \`VapourBox-$APP_VERSION-macos-arm64.zip\`
- **macOS (Intel)**: \`VapourBox-$APP_VERSION-macos-x64.zip\`

### Dependencies
Dependencies are automatically downloaded on first launch (~185 MB).
Using dependency version: $DEPS_TAG

### Requirements
- Windows 10/11 x64
- macOS 12+ (Monterey or later)"

if [ ${#RELEASE_ASSETS[@]} -gt 0 ]; then
    gh release create "v$APP_VERSION" \
        --repo "$GITHUB_REPO" \
        --title "VapourBox $APP_VERSION" \
        --notes "$RELEASE_NOTES" \
        --draft \
        "${RELEASE_ASSETS[@]}" || echo -e "${YELLOW}Release creation skipped or failed${NC}"
else
    gh release create "v$APP_VERSION" \
        --repo "$GITHUB_REPO" \
        --title "VapourBox $APP_VERSION" \
        --notes "$RELEASE_NOTES" \
        --draft || echo -e "${YELLOW}Release creation skipped or failed${NC}"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Release Complete!                       ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo "  1. Wait for Windows build to complete (if using GitHub Actions)"
echo "  2. Upload Windows zip to the draft release"
echo "  3. Test the release builds"
echo "  4. Edit release notes"
echo "  5. Publish the release"
echo ""
echo "Release URL: https://github.com/$GITHUB_REPO/releases/tag/v$APP_VERSION"
echo ""
