#!/usr/bin/env bash
#
# Fetch a platform's dependency bundle and extract it into a directory:
#
#     bash .github/scripts/install-deps-bundle.sh linux-x64-v2 deps-v1.13.0 1.13.0 deps/linux-x64
#
# The first argument names the bundle the way the test matrix does: a platform
# (`linux-x64`, `macos-arm64`), optionally suffixed `-v2` for the older-CPU tier
# of an x64 platform (issue #92).
#
# A v2 tier is not one download. From deps 1.13.0 (`"tierFormat": "delta"` in
# app/assets/deps-version.json) it is the platform's full bundle plus a small
# delta extracted over it — exactly what DependencyManager does on a user's
# machine, so CI installs it the same way rather than from some full v2 zip no
# user ever receives. This script is the one place in CI that knows that.
#
# Sources and $DEPS_RUN_ID are as documented in fetch-deps-bundle.sh.
set -euo pipefail

BUNDLE="${1:?usage: install-deps-bundle.sh <platform>[-v2] <release-tag> <version> <dest-dir>}"
TAG="${2:?missing release tag}"
VER="${3:?missing version}"
DEST="${4:?missing destination directory}"
HERE="$(cd "$(dirname "$0")" && pwd)"
POINTER="$HERE/../../app/assets/deps-version.json"

ASSETS=("$BUNDLE")
if [[ "$BUNDLE" == *-v2 ]] && grep -q '"tierFormat": *"delta"' "$POINTER"; then
  ASSETS=("${BUNDLE%-v2}" "$BUNDLE-delta")
fi

mkdir -p "$DEST"
for ASSET in "${ASSETS[@]}"; do
  ZIP=$(bash "$HERE/fetch-deps-bundle.sh" "$ASSET" "$TAG" "$VER")
  [ -f "$ZIP" ] || { echo "::error::no zip for $ASSET" >&2; exit 1; }
  echo "extracting $ZIP into $DEST" >&2
  if [ "${RUNNER_OS:-}" = Windows ]; then
    # The Windows bundle uses backslash separators; 7-Zip copes, info-zip
    # `unzip` warns and exits non-zero.
    7z x "$ZIP" -o"$DEST" -y >/dev/null
  else
    unzip -q -o "$ZIP" -d "$DEST"
  fi
  rm -f "$ZIP"
done
rm -rf .deps-artifact

# The delta carries the version.json that marks the tree as the v2 tier; if it
# did not land last, the tests would silently run the v3 bundle.
if [[ "$BUNDLE" == *-v2 ]] && ! grep -q '"tier": *"v2"' "$DEST/version.json"; then
  echo "::error::$DEST/version.json does not say tier v2 after installing $BUNDLE" >&2
  exit 1
fi
