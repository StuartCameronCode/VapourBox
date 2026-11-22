#!/usr/bin/env bash
# The dispatches behind the report's A/B table (task #103). Not meant to be
# run as one script: each step waits for the runs before it.
set -euo pipefail
BRANCH=stuart/103-linux-deps-zimg-is-cloned-from-unpinned

# 1. Build the Linux deps from the branch (both x64 tiers + arm64). No
#    release_tag: nothing is uploaded.
gh workflow run build-deps-linux.yml --ref "$BRANCH" -f version=1.18.0-rc3 -f arch=both

# 2. Test it, with rc3's macOS (44965644460, 44969457286) and Windows
#    (44965646994) build runs so every platform's job finds a bundle.
#    LINUX_RUN is step 1's run, or 44965649537 for rc3 as published.
LINUX_RUN=${LINUX_RUN:?set to the build-deps-linux run id}
IDS="44965644460,44969457286,44965646994,$LINUX_RUN"
gh workflow run ci-test.yml --ref "$BRANCH" -f deps_run_id="$IDS"
gh workflow run nightly.yml --ref "$BRANCH" -f deps_run_id="$IDS"

# 3. Read them:
#   scripts/linux_failures.sh <ci-test or nightly run>
#   gh run download <nightly run> -n format-sweep-linux-x64 -D sweep-x64
#   python3 scripts/sweep_failures.py sweep-x64/results-*.json
