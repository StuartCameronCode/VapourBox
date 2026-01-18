#!/bin/bash
# Check if dependencies have changed since last release
# Compares content hashes of deps directories and download scripts
# Usage: ./Scripts/check-deps-changed.sh [--verbose]
# Exit code: 0 = changed, 1 = unchanged, 2 = error

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VERBOSE=false
if [ "$1" = "--verbose" ]; then
    VERBOSE=true
fi

# Files/directories to check for changes
DEPS_PATHS=(
    "deps/windows-x64/vapoursynth"
    "deps/windows-x64/ffmpeg"
    "deps/macos-arm64"
    "deps/macos-x64"
    "Scripts/download-deps-windows.ps1"
    "Scripts/download-deps-macos.sh"
)

# Get the last deps release tag
GITHUB_REPO=$(grep '"githubRepo"' "$PROJECT_ROOT/app/assets/deps-version.json" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/')
if [ -z "$GITHUB_REPO" ]; then
    GITHUB_REPO="StuartCameron/VapourBox"
fi

LAST_DEPS_TAG=$(gh release list --repo "$GITHUB_REPO" --limit 50 2>/dev/null | grep -E '^deps-v[0-9]' | head -1 | awk '{print $1}')

if [ -z "$LAST_DEPS_TAG" ]; then
    if $VERBOSE; then
        echo "No previous deps release found - deps release needed"
    fi
    echo "CHANGED: No previous release"
    exit 0
fi

if $VERBOSE; then
    echo "Last deps release: $LAST_DEPS_TAG"
    echo "Checking for changes..."
fi

# Get the commit SHA of the last deps release
LAST_RELEASE_SHA=$(gh release view "$LAST_DEPS_TAG" --repo "$GITHUB_REPO" --json targetCommitish -q '.targetCommitish' 2>/dev/null)

if [ -z "$LAST_RELEASE_SHA" ]; then
    if $VERBOSE; then
        echo "Could not find commit for last release"
    fi
    echo "CHANGED: Cannot verify previous release"
    exit 0
fi

if $VERBOSE; then
    echo "Last release commit: $LAST_RELEASE_SHA"
fi

# Check if any deps-related files changed since that commit
cd "$PROJECT_ROOT"

CHANGES_FOUND=false
for path in "${DEPS_PATHS[@]}"; do
    if [ -e "$path" ]; then
        # Check if path has changes since the release commit
        DIFF=$(git diff "$LAST_RELEASE_SHA" --name-only -- "$path" 2>/dev/null || echo "")
        if [ -n "$DIFF" ]; then
            if $VERBOSE; then
                echo "  Changed: $path"
                echo "$DIFF" | head -5 | sed 's/^/    /'
            fi
            CHANGES_FOUND=true
        fi
    fi
done

# Also check for new untracked files in deps
UNTRACKED=$(git ls-files --others --exclude-standard -- deps/ 2>/dev/null | head -5)
if [ -n "$UNTRACKED" ]; then
    if $VERBOSE; then
        echo "  New untracked files in deps/"
        echo "$UNTRACKED" | sed 's/^/    /'
    fi
    CHANGES_FOUND=true
fi

if $CHANGES_FOUND; then
    echo "CHANGED: Dependencies modified since $LAST_DEPS_TAG"
    exit 0
else
    echo "UNCHANGED: No dependency changes since $LAST_DEPS_TAG"
    exit 1
fi
