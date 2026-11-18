#!/usr/bin/env bash
# Finding 2: Audio Restoration's render of conf_late_video.ts's MP2 from a
# seek, against a decode of the whole stream, with FFmpeg's default MP2
# decoder (fixed-point `mp2`) and with `mp2float`. 1 LSB16 = 2^-15.
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$SCRATCH"
TS="$RES/conf_late_video.ts"
"$FFMPEG" -v error -y -c:a mp2 -i "$TS" -map 0:a:0 -f f32le full_fixed.f32
"$FFMPEG" -v error -y -c:a mp2float -i "$TS" -map 0:a:0 -f f32le full_float.f32
CHAIN="aresample=first_pts=0,apad=whole_len=96000,atrim=end_sample=96000"
render() {  # name, seek, decoder option(s), -af chain
  "$FFMPEG" -v error -y $3 -ss "$2" -t 2.6 -i "$TS" -map 0:a:0 ${4:+-af "$4"} -c:a pcm_f32le -f f32le "$1.f32"
}
render default_near 1.090022 "" "$CHAIN"
render default_near_noaf 1.090022 "" ""
render float_near 1.090022 "-c:a mp2float" "$CHAIN"
render float_mid 2.610022 "-c:a mp2float" "$CHAIN"
python3 - <<'PY'
import struct
def load(p):
    b = open(p, 'rb').read(); return struct.unpack('<%df' % (len(b) // 4), b)
def cmp(name, ref, near):
    a, r = load(name + '.f32')[:96000], load(ref)
    best = None
    for off in range(near - 3, near + 4):
        d = [abs(a[k] - r[k + off]) for k in range(min(len(a), len(r) - off))]
        cand = (max(d), sum(x > 1e-9 for x in d), off, len(d))
        best = cand if best is None or cand[0] < best[0] else best
    mx, nz, off, n = best
    print(f'{name:20s} vs {ref:16s} offset {off}: {nz} of {n} samples differ, max {mx * 32768:.3f} LSB16')
cmp('default_near', 'full_fixed.f32', 52321)
cmp('default_near_noaf', 'full_fixed.f32', 52321)
cmp('default_near', 'full_float.f32', 52321)
cmp('float_near', 'full_float.f32', 52321)
cmp('float_mid', 'full_float.f32', 125281)
PY
"$FFMPEG" -v debug -ss 1.09 -t 0.1 -i "$TS" -map 0:a:0 -f null - 2>&1 | grep -m1 'samplefmt' | sed 's/^.*\(samplefmt:[a-z0-9]*\).*$/default decoder output: \1 (s16p: the fixed-point mp2)/'
