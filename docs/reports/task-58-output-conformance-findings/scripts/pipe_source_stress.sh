#!/usr/bin/env bash
# Finding 4: pipe_source serving a frame it has dropped as another picture.
# A plain pipe clip (no pass at all) of conf_plain.mp4's 100 pictures, run
# RUNS times, PAR at once, each output compared by framemd5 with a direct
# decode. Prints the wrong runs and which source picture each wrong frame
# holds. Usage:
#   pipe_source_stress.sh [git-rev]   # pipe_source.py at that revision
#                                     # (default: the working tree's)
# RUNS (160) and PAR (16) from the environment. macOS/Linux (vspipe wrapper).
set -euo pipefail
source "$(dirname "$0")/common.sh"
RUNS="${RUNS:-160}"; PAR="${PAR:-16}"
src="$SCRATCH/pipe_source_${1:-worktree}"
mkdir -p "$src" "$src/runs"
if [ -n "${1:-}" ]; then
  git -C "$REPO" show "$1:worker/templates/pipe_source.py" > "$src/pipe_source.py"
else
  cp "$REPO/worker/templates/pipe_source.py" "$src/pipe_source.py"
fi
cat > "$src/plain.vpy" <<VPY
import sys
sys.path.insert(0, r"$src")
import pipe_source
pipe_source.create_pipe_clip(160, 120, 100, 25, 1, 'yuv420p', cache_frames=40).set_output()
VPY
"$FFMPEG" -v error -y -i "$RES/conf_plain.mp4" -map 0:v -f framemd5 "$src/ref.md5"
one() {
  "$FFMPEG" -v error -i "$RES/conf_plain.mp4" -map 0:v -f rawvideo -pix_fmt yuv420p - 2>/dev/null \
    | "$VSPIPE" -c y4m "$src/plain.vpy" - 2>"$src/runs/$1.err" \
    | "$FFMPEG" -v error -y -f yuv4mpegpipe -i - -f framemd5 "$src/runs/$1.md5" || true
}
export -f one; export FFMPEG VSPIPE RES src
seq 1 "$RUNS" | xargs -P "$PAR" -I{} bash -c 'one {}'
python3 - "$src" "$RUNS" <<'PY'
import glob, sys
d, runs = sys.argv[1], int(sys.argv[2])
def md5s(p): return [l.split(',')[-1].strip() for l in open(p) if not l.startswith('#')]
ref = md5s(d + '/ref.md5'); bad = 0; raised = 0
for i in range(1, runs + 1):
    out = md5s(f'{d}/runs/{i}.md5') if glob.glob(f'{d}/runs/{i}.md5') else []
    err = open(f'{d}/runs/{i}.err').read()
    if 'left the cache' in err: raised += 1
    wrong = [(k, ref.index(o) if o in ref else None) for k, o in enumerate(out) if k >= len(ref) or o != ref[k]]
    if wrong or len(out) != len(ref):
        bad += 1
        print(f'run {i}: {len(out)} frames; wrong (output frame, source picture it holds): {wrong[:8]}')
print(f'wrong runs: {bad} of {runs}; runs that raised: {raised}')
PY
