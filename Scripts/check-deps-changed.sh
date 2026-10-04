#!/bin/bash
# Check if dependencies have changed since last release
# Deps binaries are not committed; the download scripts reproduce them and are
# the source of truth, so this detects changes to those scripts since the release.
# Usage: ./Scripts/check-deps-changed.sh [--verbose]
# Exit code: 0 = changed, 1 = unchanged, 2 = error

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VERBOSE=false
if [ "$1" = "--verbose" ]; then
    VERBOSE=true
fi

# Files to check for changes.
# Deps binaries are no longer committed (reproduced by the download scripts, which
# are the source of truth), so "deps changed" == "a download script changed".
# Everything that changes what goes into a bundle, not just the download
# scripts: a patch (e.g. the MVTools no-AVX2 patch) or a packaging change
# alters the bundle just as surely.
DEPS_PATHS=(
    "Scripts/download-deps-windows.ps1"
    "Scripts/download-deps-macos.sh"
    "Scripts/download-deps-linux.sh"
    "Scripts/patches"
    "Scripts/package-deps-windows.ps1"
    "Scripts/package-deps-macos.sh"
    "Scripts/package-deps-linux.sh"
    "Scripts/deps-expected-plugins.json"
)

# Get the last deps release tag
GITHUB_REPO=$(grep '"githubRepo"' "$PROJECT_ROOT/app/assets/deps-version.json" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/')
if [ -z "$GITHUB_REPO" ]; then
    GITHUB_REPO="StuartCameronCode/VapourBox"
fi

# gh release list format: "TITLE<tab>STATUS<tab>TAG<tab>DATE" - extract the tag
# column (not the title) before matching, same as get-github-version.sh. A
# release's title doesn't have to start with "deps-v" (and usually doesn't -
# e.g. "VapourBox Dependencies 1.9.0"), so matching the raw line only ever hit
# a one-off release literally titled "deps-v1.5.0 (test)".
LAST_DEPS_TAG=$(gh release list --repo "$GITHUB_REPO" --limit 50 2>/dev/null | awk -F'\t' '{print $3}' | grep -E '^deps-v[0-9]' | head -1)

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

if $CHANGES_FOUND; then
    echo "CHANGED: Dependencies modified since $LAST_DEPS_TAG"
    exit 0
else
    echo "UNCHANGED: No dependency changes since $LAST_DEPS_TAG"
    exit 1
fi
