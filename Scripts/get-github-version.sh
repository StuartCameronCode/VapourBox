#!/bin/bash
# Get the latest release version from GitHub
# Usage: ./Scripts/get-github-version.sh [--app|--deps]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Read GitHub repo from deps-version.json
GITHUB_REPO=$(grep '"githubRepo"' "$PROJECT_ROOT/app/assets/deps-version.json" | sed 's/.*: *"\([^"]*\)".*/\1/')
if [ -z "$GITHUB_REPO" ]; then
    GITHUB_REPO="StuartCameron/VapourBox"
fi

TYPE="${1:---app}"

case "$TYPE" in
    --app)
        # Get latest app release (tags starting with 'v')
        VERSION=$(gh release list --repo "$GITHUB_REPO" --limit 50 2>/dev/null | grep -E '^v[0-9]' | head -1 | awk '{print $1}' | sed 's/^v//')
        if [ -z "$VERSION" ]; then
            VERSION="0.0.0"
        fi
        echo "$VERSION"
        ;;
    --deps)
        # Get latest deps release (tags starting with 'deps-v')
        VERSION=$(gh release list --repo "$GITHUB_REPO" --limit 50 2>/dev/null | grep -E '^deps-v[0-9]' | head -1 | awk '{print $1}' | sed 's/^deps-v//')
        if [ -z "$VERSION" ]; then
            VERSION="0.0.0"
        fi
        echo "$VERSION"
        ;;
    --next-app)
        # Get next app version (increment minor)
        CURRENT=$(gh release list --repo "$GITHUB_REPO" --limit 50 2>/dev/null | grep -E '^v[0-9]' | head -1 | awk '{print $1}' | sed 's/^v//')
        if [ -z "$CURRENT" ]; then
            echo "0.1.0"
        else
            # Parse version and increment minor
            MAJOR=$(echo "$CURRENT" | cut -d. -f1)
            MINOR=$(echo "$CURRENT" | cut -d. -f2)
            PATCH=$(echo "$CURRENT" | cut -d. -f3)
            NEW_MINOR=$((MINOR + 1))
            echo "${MAJOR}.${NEW_MINOR}.0"
        fi
        ;;
    --next-deps)
        # Get next deps version (increment minor)
        CURRENT=$(gh release list --repo "$GITHUB_REPO" --limit 50 2>/dev/null | grep -E '^deps-v[0-9]' | head -1 | awk '{print $1}' | sed 's/^deps-v//')
        if [ -z "$CURRENT" ]; then
            echo "1.0.0"
        else
            MAJOR=$(echo "$CURRENT" | cut -d. -f1)
            MINOR=$(echo "$CURRENT" | cut -d. -f2)
            PATCH=$(echo "$CURRENT" | cut -d. -f3)
            NEW_MINOR=$((MINOR + 1))
            echo "${MAJOR}.${NEW_MINOR}.0"
        fi
        ;;
    *)
        echo "Usage: $0 [--app|--deps|--next-app|--next-deps]" >&2
        exit 1
        ;;
esac
