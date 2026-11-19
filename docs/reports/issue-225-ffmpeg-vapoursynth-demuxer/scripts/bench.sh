#!/bin/bash
# vspipe | ffmpeg  vs  ffmpeg -f vapoursynth, on the same scripts and the same
# FFmpeg binary. Each arm reads the source through a decoder ffmpeg piping raw
# frames into the script's stdin, as VapourBox does.
#
# Usage: bench.sh <deps dir> <ffmpeg with --enable-vapoursynth> <vpy dir> <media dir> <reps> <out.csv>
#   [filters] [sources] [encoders]
set -euo pipefail
DEPS="$1"; FF="$2"; VPY="$3"; MEDIA="$4"; REPS="$5"; OUT="$6"
FILTERS="${7:-passthrough light qtgmc}"; SOURCES="${8:-sd hd}"; ENCODERS="${9:-null x264}"
VS="$DEPS/vapoursynth"
SHIM="$(mktemp -d)"
# The demuxer dlopens "libvapoursynth-script.dylib"; R78's package names it libvsscript.
ln -s "$VS/libvsscript.dylib" "$SHIM/libvapoursynth-script.dylib"
ENV="export PYTHONHOME='$DEPS/python' PYTHONPATH='$DEPS:$DEPS/python-packages' \
 XDG_CONFIG_HOME='$DEPS/config' PATH='$DEPS/python/bin:$PATH' \
 DYLD_LIBRARY_PATH='$SHIM:$VS:$DEPS/python/lib'"
TMP="$(mktemp -d)"
RT="$(cd "$(dirname "$0")" && pwd)/rtime.py"
echo "filter,source,encoder,arm,rep,frames,wall_s,cpu_s,fps,maxrss_mb,dec_cpu_s,vs_cpu_s,enc_cpu_s" > "$OUT"

enc_args() {
  case "$1" in
    null) echo "-c:v rawvideo -f null -" ;;
    x264) echo "-c:v libx264 -preset medium -crf 18 -f null -" ;;
  esac
}
# rusage fields from /usr/bin/time -l output
cpu_of() { awk '{print $2+$3}' "$1"; }
rss_of() { awk '{print $4}' "$1"; }

for f in $FILTERS; do for s in $SOURCES; do for e in $ENCODERS; do
  script="$VPY/${f}_${s}.vpy"; src="$MEDIA/$s.mkv"; ea="$(enc_args $e)"
  dec="'$FF' -v error -nostdin -i '$src' -f rawvideo -pix_fmt yuv420p -"
  for r in $(seq 1 "$REPS"); do
    for arm in vspipe demuxer; do
      if [ $arm = vspipe ]; then
        cmd="$ENV; python3 "$RT" $TMP/d $dec | python3 "$RT" $TMP/v '$VS/vspipe' -c y4m '$script' - 2>/dev/null \
          | python3 "$RT" $TMP/e '$FF' -v error -nostdin -f yuv4mpegpipe -i - $ea"
      else
        cmd="$ENV; python3 "$RT" $TMP/d $dec | python3 "$RT" $TMP/e '$FF' -v error -nostdin -f vapoursynth -i '$script' $ea"
        : > $TMP/v
      fi
      start=$(python3 -c 'import time;print(time.time())')
      bash -c "$cmd"
      end=$(python3 -c 'import time;print(time.time())')
      wall=$(python3 -c "print(round($end-$start,3))")
      dc=$(cpu_of $TMP/d); ec=$(cpu_of $TMP/e); vc=$( [ -s $TMP/v ] && cpu_of $TMP/v || echo 0 )
      cpu=$(python3 -c "print(round($dc+$ec+$vc,2))")
      rss=$(python3 -c "print(round(max([$(rss_of $TMP/e),$( [ -s $TMP/v ] && rss_of $TMP/v || echo 0)])/1048576))")
      if [ $s = sd ]; then n=500; else n=200; fi
      [ $f = qtgmc ] && n=$((n*2))
      fps=$(python3 -c "print(round($n/$wall,2))")
      echo "$f,$s,$e,$arm,$r,$n,$wall,$cpu,$fps,$rss,$dc,$vc,$ec" | tee -a "$OUT"
    done
  done
done; done; done
rm -rf "$SHIM" "$TMP"
