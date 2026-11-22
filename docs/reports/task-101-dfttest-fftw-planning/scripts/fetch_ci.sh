#!/bin/bash
# Copies a probe-dfttest-fftw.yml run's artifacts into data/ci/<run>/<job>/
# (the temporary workflow is gone from the repository; its runs' JSON is kept
# here). Usage: fetch_ci.sh <run id>...
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
for RUN in "$@"; do
    OUT="$HERE/../data/ci/$RUN"
    mkdir -p "$OUT"
    for A in $(gh api "repos/StuartCameronCode/VapourBox/actions/runs/$RUN/artifacts" -q '.artifacts[].name'); do
        rm -rf "$OUT/${A#probe-}"
        gh run download "$RUN" -R StuartCameronCode/VapourBox -n "$A" -D "$OUT/${A#probe-}"
    done
done
