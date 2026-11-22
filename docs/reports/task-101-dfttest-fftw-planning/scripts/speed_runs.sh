#!/bin/bash
# speed.py `runs` times per bundle, the two bundles alternating so drift
# (thermal, neighbours) hits both. One JSON line per run on stdout.
#   speed_runs.sh <PATIENT deps> <ESTIMATE deps> [runs] [frames]
P="$1"; E="$2"; RUNS="${3:-3}"; FRAMES="${4:-120}"
HERE="$(cd "$(dirname "$0")" && pwd)"
for i in $(seq 1 "$RUNS"); do
    for b in "patient:$P" "estimate:$E"; do
        echo "speed ${b%%:*} $i/$RUNS" >&2
        printf '{"build": "%s", "result": %s}\n' "${b%%:*}" "$("$HERE/run.sh" "${b#*:}" speed.py "$FRAMES")"
    done
done
