#!/bin/bash
# Reproduces every number in ../index.html except the parity figures, which
# come from the heavy test (see the report).
#
#   SCRATCH=/some/scratch/dir [DEPS=deps/macos-arm64] [RUNS=8] ./measure.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
S="${SCRATCH:?set SCRATCH to your scratch directory}"
D="$(cd "${DEPS:-$REPO/deps/macos-arm64}" && pwd)"
RUNS="${RUNS:-8}"
FF="$D/ffmpeg/ffmpeg"
VSPIPE="$D/vapoursynth/vspipe"
[ -x "$VSPIPE" ] || VSPIPE="$D/vapoursynth/Lib/site-packages/vapoursynth/vspipe.exe"
export TEMPLATES="$REPO/worker/templates"
mkdir -p "$S"
q() { "$FF" -hide_banner -loglevel error -y "$@"; }

# The fixtures of integration_high_bit_depth_filters_test.dart: the degraded
# master (testsrc2, seeded grain, starved MPEG-2), and the same with known
# shake (+-2 px horizontally, alternating; +-2 px vertically, in pairs).
q -f lavfi -i testsrc2=size=352x288:rate=25:duration=1 \
  -vf noise=alls=18:allf=t+u:all_seed=20260805,setfield=tff \
  -c:v mpeg2video -b:v 700k -flags +ilme+ildct -g 15 -bf 2 "$S/master.mkv"
SHAKE="crop=w=340:h=276:x='6+2*(2*mod(n\,2)-1)':y='6+2*(2*mod(floor(n/2)\,2)-1)',pad=352:288:6:6,fillborders=left=6:right=6:top=6:bottom=6:mode=smear"
for pf in yuv422p yuv422p10le yuv422p16le; do
  q -i "$S/master.mkv" -f rawvideo -pix_fmt $pf "$S/plain_$pf.yuv"
  q -i "$S/master.mkv" -vf "$SHAKE" -f rawvideo -pix_fmt $pf "$S/shaken_$pf.yuv"
done

# run FIXTURE PF MODE [env...]: frame hashes of one run, hashed again.
run() {
  local fix=$1 pf=$2 mode=$3; shift 3
  env PF=$pf MODE=$mode "$@" "$VSPIPE" -c y4m "$HERE/stab.vpy" - < "$S/${fix}_$pf.yuv" 2>/dev/null \
    | "$FF" -v error -f yuv4mpegpipe -i - -f framemd5 - | grep -v '^#' | awk -F, '{print $NF}' \
    | (md5sum 2>/dev/null || md5) | cut -c1-8
}

echo "== 1. DepanEstimate on a known shift (mean over 12 frame pairs)"
for s in 2:0 0:2 2:2; do
  for pf in yuv422p yuv422p10le yuv422p16le; do
    env PF=$pf MODE=shift DX="${s%:*}" DY="${s#*:}" "$VSPIPE" -c y4m "$HERE/stab.vpy" /dev/null \
      < "$S/plain_$pf.yuv" 2>&1 | awk -v s="$s" -v pf=$pf '/^EST/ {x+=$3; y+=$4; n++}
        END {printf "shift %s  %-12s dx %.3f  dy %.3f\n", s, pf, x/n, y/n}'
  done
done

echo; echo "== 2. Same clip, $RUNS runs: distinct outputs (1 = deterministic)"
for fix in plain shaken; do
  for pf in yuv422p yuv422p10le; do
    for mode in stab weave; do
      for threads in "" 1; do
        n=$(for i in $(seq "$RUNS"); do run $fix $pf $mode THREADS=$threads; done | sort -u | wc -l)
        printf "%-6s %-12s %-5s threads=%-4s %d\n" $fix $pf $mode "${threads:-all}" $n
      done
    done
  done
done

echo; echo "== 3. Size of the run-to-run difference (plain 8-bit, weave): run 1 vs runs 2-3"
for i in 1 2 3; do
  PF=yuv422p MODE=weave "$VSPIPE" -c y4m "$HERE/stab.vpy" - < "$S/plain_yuv422p.yuv" 2>/dev/null > "$S/weave_run$i.y4m"
done
for i in 2 3; do
  for c in "" ",crop=iw-16:ih-16:8:8"; do
    label="run $i, $([ -n "$c" ] && echo 'inside 8 px' || echo 'whole frame')"
    "$FF" -v error -i "$S/weave_run1.y4m" -i "$S/weave_run$i.y4m" \
      -lavfi "[0]format=gray$c[a];[1]format=gray$c[b];[a][b]blend=all_mode=difference,signalstats,metadata=print:file=-" \
      -f null - | awk -F= -v l="$label" '/YMAX/{if($2>m)m=$2} /YAVG/{s+=$2;n++}
        END{printf "%-22s max %3d  mean %.4f levels\n", l, m, s/n}'
  done
done
