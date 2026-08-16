#!/usr/bin/env bash
#
# Fetch one platform's dependency bundle for a CI run and print the path of the
# downloaded .zip on stdout. Everything else goes to stderr, so the caller can
# do:
#
#     ZIP=$(bash .github/scripts/fetch-deps-bundle.sh macos-arm64 deps-v1.9.0 1.9.0)
#
# Two sources, chosen by whether $DEPS_RUN_ID is set:
#
#   (default) the published release named by app/assets/deps-version.json. This
#             is the real thing — the same tag, asset name and URL a shipped app
#             downloads at runtime — so the normal gate exercises the normal
#             path.
#
#   $DEPS_RUN_ID  the workflow-run artifact from a build-deps-* run. Lets a deps
#             change be tested BEFORE anything is published, which is otherwise
#             a chicken-and-egg problem: ci-test.yml and nightly.yml can only
#             download published assets, so a new bundle had to be released to
#             find out whether it worked. Artifacts are private to the repo,
#             need no tag, and expire on their own, so there is nothing to clean
#             up and nothing a user could stumble into. Pass it via
#             workflow_dispatch:
#
#               gh workflow run ci-test.yml --ref <branch> -f deps_run_id=<id>
#
#             Requires `actions: read` on the workflow token; the callers
#             declare it.
#
# The artifact path deliberately does NOT check the version in the artifact
# name against deps-version.json. The whole point is testing a bundle that has
# not been released yet, and it may well be a throwaway version string.
set -euo pipefail

PLATFORM="${1:?usage: fetch-deps-bundle.sh <platform> <release-tag> <version>}"
TAG="${2:?missing release tag}"
VER="${3:?missing version}"

if [ -n "${DEPS_RUN_ID:-}" ]; then
  echo "deps source: artifact from workflow run $DEPS_RUN_ID (NOT a release)" >&2
  rm -rf .deps-artifact
  gh run download "$DEPS_RUN_ID" \
    --pattern "VapourBox-deps-*-${PLATFORM}" --dir .deps-artifact >&2

  # gh nests each artifact in a directory named after it, so glob rather than
  # assuming a layout.
  ZIP=$(find .deps-artifact -name "VapourBox-deps-*-${PLATFORM}.zip" | head -1)
  if [ -z "$ZIP" ]; then
    echo "::error::run $DEPS_RUN_ID has no deps artifact for $PLATFORM" >&2
    echo "artifacts present:" >&2
    find .deps-artifact -name '*.zip' >&2 || true
    exit 1
  fi
  echo "::warning::Testing an UNPUBLISHED deps bundle from run $DEPS_RUN_ID, not ${TAG}." >&2
else
  echo "deps source: release $TAG" >&2
  ZIP="VapourBox-deps-${VER}-${PLATFORM}.zip"
  gh release download "$TAG" --pattern "$ZIP" --dir . --clobber >&2
fi

echo "$ZIP"
