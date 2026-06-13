#!/bin/bash
# Trigger CI builds for macOS and Windows, download artifacts, upload to draft release.
#
# Prerequisites:
# - gh CLI installed and authenticated
# - A draft release already exists for the version tag
#
# Usage: ./Scripts/ci-build-and-release.sh --version 0.7.0 [OPTIONS]
#
# Options:
#   --version X.Y.Z       App version (required)
#   --deps-tag TAG        Deps release tag (default: from deps-version.json)
#   --arch ARCH           macOS arch: universal, both, arm64, x64 (default: universal)
#   --skip-trigger        Skip triggering workflows (just download + upload)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERSION=""
DEPS_TAG=""
ARCH="universal"
SKIP_TRIGGER=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --version) VERSION="$2"; shift 2 ;;
        --deps-tag) DEPS_TAG="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --skip-trigger) SKIP_TRIGGER=true; shift ;;
        -h|--help)
            echo "Usage: $0 --version X.Y.Z [--deps-tag TAG] [--arch universal|both|arm64|x64] [--skip-trigger]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo -e "${RED}ERROR: --version is required${NC}"
    echo "Usage: $0 --version X.Y.Z"
    exit 1
fi

# Read deps tag from deps-version.json if not provided
if [ -z "$DEPS_TAG" ]; then
    DEPS_TAG=$(grep -o '"releaseTag"[[:space:]]*:[[:space:]]*"[^"]*"' "$PROJECT_ROOT/app/assets/deps-version.json" | head -1 | sed 's/.*"releaseTag"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
    echo -e "${BLUE}Using deps tag from deps-version.json: ${DEPS_TAG}${NC}"
fi

RELEASE_TAG="v${VERSION}"
DOWNLOAD_DIR="$PROJECT_ROOT/dist/ci-artifacts"

echo ""
echo -e "${GREEN}=== CI Build and Release ===${NC}"
echo "  Version:  $VERSION"
echo "  Deps tag: $DEPS_TAG"
echo "  Arch:     $ARCH"
echo "  Release:  $RELEASE_TAG"
echo ""

# Verify draft release exists
echo -e "${BLUE}Checking for draft release ${RELEASE_TAG}...${NC}"
DRAFT_RELEASE=$(gh release view "$RELEASE_TAG" --json isDraft,name 2>/dev/null || true)
if [ -z "$DRAFT_RELEASE" ]; then
    echo -e "${RED}ERROR: No release found for tag ${RELEASE_TAG}${NC}"
    echo "Create a draft release first: gh release create $RELEASE_TAG --draft --title \"VapourBox $VERSION\""
    exit 1
fi
IS_DRAFT=$(echo "$DRAFT_RELEASE" | gh release view "$RELEASE_TAG" --json isDraft --jq '.isDraft' 2>/dev/null || echo "false")
if [ "$IS_DRAFT" != "true" ]; then
    echo -e "${YELLOW}WARNING: Release ${RELEASE_TAG} is not a draft. Continue? (y/N)${NC}"
    read -r CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        exit 1
    fi
fi
RELEASE_NAME=$(gh release view "$RELEASE_TAG" --json name --jq '.name' 2>/dev/null || echo "$RELEASE_TAG")
echo -e "${GREEN}  Found release: ${RELEASE_NAME}${NC}"

if ! $SKIP_TRIGGER; then
    # Trigger both workflows
    echo ""
    echo -e "${BLUE}[1/4] Triggering CI workflows...${NC}"

    echo "  Triggering Build Windows..."
    gh workflow run "Build Windows" \
        -f version="$VERSION" \
        -f deps_tag="$DEPS_TAG"

    echo "  Triggering Build macOS..."
    gh workflow run "Build macOS" \
        -f version="$VERSION" \
        -f deps_tag="$DEPS_TAG" \
        -f arch="$ARCH"

    echo "  Triggering Build Linux..."
    gh workflow run "Build Linux" \
        -f version="$VERSION" \
        -f deps_tag="$DEPS_TAG" \
        -f arch="both"

    # Wait for runs to appear (they take a moment to register)
    echo "  Waiting for runs to register..."
    sleep 10

    # Find the run IDs we just triggered
    echo ""
    echo -e "${BLUE}[2/4] Waiting for builds to complete...${NC}"

    WIN_RUN_ID=$(gh run list --workflow "Build Windows" --limit 1 --json databaseId --jq '.[0].databaseId')
    MAC_RUN_ID=$(gh run list --workflow "Build macOS" --limit 1 --json databaseId --jq '.[0].databaseId')
    LINUX_RUN_ID=$(gh run list --workflow "Build Linux" --limit 1 --json databaseId --jq '.[0].databaseId')

    echo "  Windows run: $WIN_RUN_ID"
    echo "  macOS run:   $MAC_RUN_ID"
    echo "  Linux run:   $LINUX_RUN_ID"
    echo ""

    # Wait for all to complete
    FAILED=false

    echo "  Waiting for Windows build..."
    if gh run watch "$WIN_RUN_ID" --exit-status; then
        echo -e "  ${GREEN}Windows build succeeded${NC}"
    else
        echo -e "  ${RED}Windows build failed${NC}"
        FAILED=true
    fi

    echo "  Waiting for macOS build..."
    if gh run watch "$MAC_RUN_ID" --exit-status; then
        echo -e "  ${GREEN}macOS build succeeded${NC}"
    else
        echo -e "  ${RED}macOS build failed${NC}"
        FAILED=true
    fi

    echo "  Waiting for Linux build..."
    if gh run watch "$LINUX_RUN_ID" --exit-status; then
        echo -e "  ${GREEN}Linux build succeeded${NC}"
    else
        echo -e "  ${RED}Linux build failed${NC}"
        FAILED=true
    fi

    if $FAILED; then
        echo ""
        echo -e "${RED}One or more builds failed. Check the runs:${NC}"
        echo "  Windows: gh run view $WIN_RUN_ID --web"
        echo "  macOS:   gh run view $MAC_RUN_ID --web"
        echo "  Linux:   gh run view $LINUX_RUN_ID --web"
        exit 1
    fi
else
    echo -e "${YELLOW}Skipping workflow trigger (--skip-trigger)${NC}"
    WIN_RUN_ID=$(gh run list --workflow "Build Windows" --limit 1 --json databaseId --jq '.[0].databaseId')
    MAC_RUN_ID=$(gh run list --workflow "Build macOS" --limit 1 --json databaseId --jq '.[0].databaseId')
    LINUX_RUN_ID=$(gh run list --workflow "Build Linux" --limit 1 --json databaseId --jq '.[0].databaseId')
    echo "  Using latest Windows run: $WIN_RUN_ID"
    echo "  Using latest macOS run:   $MAC_RUN_ID"
    echo "  Using latest Linux run:   $LINUX_RUN_ID"
fi

# Download artifacts
echo ""
echo -e "${BLUE}[3/4] Downloading artifacts...${NC}"
rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

echo "  Downloading Windows artifact..."
gh run download "$WIN_RUN_ID" --dir "$DOWNLOAD_DIR"

echo "  Downloading macOS artifact..."
gh run download "$MAC_RUN_ID" --dir "$DOWNLOAD_DIR"

echo "  Downloading Linux artifact..."
gh run download "$LINUX_RUN_ID" --dir "$DOWNLOAD_DIR"

echo "  Downloaded artifacts:"
find "$DOWNLOAD_DIR" -type f \( -name "*.zip" -o -name "*.dmg" -o -name "*.tar.gz" -o -name "*.sha256.json" \) | while read -r f; do
    SIZE=$(du -sh "$f" | cut -f1)
    echo "    $(basename "$f") ($SIZE)"
done

# Upload to draft release
echo ""
echo -e "${BLUE}[4/4] Uploading to release ${RELEASE_TAG}...${NC}"

UPLOAD_COUNT=0
find "$DOWNLOAD_DIR" -type f \( -name "*.zip" -o -name "*.dmg" -o -name "*.tar.gz" -o -name "*.sha256.json" \) | while read -r f; do
    BASENAME=$(basename "$f")
    echo "  Uploading $BASENAME..."
    gh release upload "$RELEASE_TAG" "$f" --clobber
done

echo ""
echo -e "${GREEN}=== Done ===${NC}"
echo ""
echo "Artifacts uploaded to draft release: $RELEASE_TAG"
echo "Review and publish: gh release edit $RELEASE_TAG --draft=false"
echo "Or view in browser: gh release view $RELEASE_TAG --web"
