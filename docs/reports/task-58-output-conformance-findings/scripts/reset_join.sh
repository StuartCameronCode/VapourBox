#!/usr/bin/env bash
# Finding 5: the joined copy of the two reset fixtures, made by ffmpeg's own
# discontinuity correction (the copy before task #58) and by the worker's
# --make-continuous (the picture decides the join). For each: the video
# rate ffprobe reports, the pictures, picture 50's time after picture 0, and
# the sound's irregular steps. WORKER is a vapourbox-worker binary
# (default: worker/target/debug's; a debug worker finds deps/ above it).
set -euo pipefail
source "$(dirname "$0")/common.sh"
WORKER="${WORKER:-$REPO/worker/target/debug/vapourbox-worker}"
for f in conf_reset conf_reset_offgrid; do
  "$FFMPEG" -hide_banner -nostdin -y -v error -i "$RES/$f.mpg" -map 0:v -map '0:a?' -c copy -f vob "$SCRATCH/ffmpeg_$f.mpg"
  "$WORKER" --make-continuous "$RES/$f.mpg" --output "$SCRATCH/worker_$f.mpg" | grep -o '"message":"[^"]*joining[^"]*"' || true
  for kind in ffmpeg worker; do
    python3 - "$SCRATCH/${kind}_$f.mpg" "$FFPROBE" "$kind $f" <<'PY'
import json, subprocess, sys
f, P, name = sys.argv[1:4]
def times(sel):
    j = json.loads(subprocess.run([P, '-v', 'error', '-select_streams', sel, '-show_entries',
        'frame=best_effort_timestamp_time', '-of', 'json', f], capture_output=True, text=True).stdout)
    return [float(x['best_effort_timestamp_time']) for x in j['frames'] if 'best_effort_timestamp_time' in x], len(j['frames'])
rate = subprocess.run([P, '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=r_frame_rate',
    '-of', 'csv=p=0', f], capture_output=True, text=True).stdout.strip().strip(',')
(v, nv), (a, na) = times('v:0'), times('a:0')
steps = sorted(set(round(v[i + 1] - v[i], 4) for i in range(len(v) - 1)))
odd = [(round(a[i] - v[0], 4), round(a[i + 1] - a[i], 4)) for i in range(len(a) - 1) if abs(a[i + 1] - a[i] - 0.024) > 1e-4]
print(f'{name:30s} rate {rate:7s} pictures {nv}, picture steps {steps}, picture 50 at {v[50] - v[0]:.4f} s; '
      f'sound frames {na}, irregular sound steps (at, step) {odd}')
PY
  done
done
