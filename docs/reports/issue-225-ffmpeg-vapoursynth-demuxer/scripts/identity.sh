#!/bin/bash
# identity.sh <deps> <ffmpeg with demuxer> <script.vpy> <source>: frame MD5s of
# vspipe | ffmpeg against ffmpeg -f vapoursynth; prints IDENTICAL or the diff.
set -euo pipefail
DEPS="$1"; FF="$2"; VPY="$3"; SRC="$4"; T="$(mktemp -d)"
ln -s "$DEPS/vapoursynth/libvsscript.dylib" "$T/libvapoursynth-script.dylib"
export PYTHONHOME="$DEPS/python" PYTHONPATH="$DEPS:$DEPS/python-packages" XDG_CONFIG_HOME="$DEPS/config" \
  PATH="$DEPS/python/bin:$PATH" DYLD_LIBRARY_PATH="$T:$DEPS/vapoursynth:$DEPS/python/lib"
DEC=("$FF" -v error -nostdin -i "$SRC" -f rawvideo -pix_fmt yuv420p -)
"${DEC[@]}" | "$DEPS/vapoursynth/vspipe" -c y4m "$VPY" - 2>/dev/null \
  | "$FF" -v error -nostdin -f yuv4mpegpipe -i - -f framemd5 - | grep -v '^#' | cut -d, -f6 > "$T/v"
"${DEC[@]}" | "$FF" -v error -nostdin -f vapoursynth -i "$VPY" -f framemd5 - | grep -v '^#' | cut -d, -f6 > "$T/d"
echo "$(wc -l < "$T/v") frames"; cmp "$T/v" "$T/d" && echo IDENTICAL
rm -rf "$T"
