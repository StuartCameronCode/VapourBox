#!/usr/bin/env bash
# Run repro.vpy through an installed Linux deps bundle's vspipe: each
# conversion REPEAT times plainly (aborts counted), then once under valgrind
# memcheck (invalid writes counted). (task #109)
#
# Usage: vs_confirm.sh DEPS_DIR LABEL REPEAT OUTDIR
#   DEPS_DIR  an extracted linux-x64 bundle (deps/linux-x64)
# Prints: bundle, conversion, size, runs, aborts, first abort message,
# valgrind invalid writes, first invalid-write frame under real_get_frame.
set -uo pipefail
D=$1 LABEL=$2 REPEAT=$3 OUT=$4
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

export PYTHONHOME=$D/python PYTHONPATH=$D:$D/python-packages PYTHONNOUSERSITE=1
export XDG_CONFIG_HOME=$D/config PATH=$D/python/bin:$D/vapoursynth:$PATH
export LD_LIBRARY_PATH=$D/vapoursynth:$D/python/lib:$D/lib
VSPIPE=$D/vapoursynth/vspipe
REAL=$D/vapoursynth/vspipe-bin
# The wrapper execs vspipe-bin; a copy of it that execs valgrind instead. It
# sits beside the wrapper, which finds Python relative to its own directory.
VG=$D/vapoursynth/vspipe.vg
sed "s|^exec \"\$SCRIPT_DIR/vspipe-bin\" \"\$@\"\$|exec valgrind --error-exitcode=99 --num-callers=20 \"$REAL\" \"\$@\"|" \
    "$VSPIPE" > "$VG"
chmod +x "$VG"
grep -q valgrind "$VG" || { echo "could not make a valgrind vspipe from $VSPIPE" >&2; exit 2; }

# src dst: the error-diffusion conversions that overran in tmp_overrun
# (BM3D's GRAY back to 8 bits, Deband's 4:2:0 back to 8 bits, Colourisation's
# float YUV444 to the source format), and the same with dither none as the
# control.
CONVERSIONS="GRAY16:GRAY8:error_diffusion YUV420P16:YUV420P8:error_diffusion YUV444PS:YUV444P16:error_diffusion YUV444PS:YUV420P8:error_diffusion GRAY16:GRAY8:none YUV420P16:YUV420P8:none"
SIZES="96x64 720x480"

printf 'bundle\tconversion\tsize\truns\taborts\tabort_message\tvg_invalid_writes\tvg_first_frame\n'
for conv in $CONVERSIONS; do
    IFS=: read -r src dst dither <<<"$conv"
    for size in $SIZES; do
        tag="$src-$dst-$dither-$size"
        aborts=0 msg=""
        for i in $(seq "$REPEAT"); do
            rc=0
            "$VSPIPE" -a src="$src" -a dst="$dst" -a dither="$dither" -a size="$size" -a frames=20 \
                "$HERE/repro.vpy" - >/dev/null 2>"$OUT/$tag.err" || rc=$?
            if [ "$rc" -ne 0 ]; then
                aborts=$((aborts + 1))
                [ -z "$msg" ] && msg="exit $rc: $(grep -m1 -E 'free|corrupt|malloc|Assertion|Error' "$OUT/$tag.err" | tr '\t' ' ' | cut -c1-110)"
            fi
        done
        PYTHONMALLOC=malloc timeout 1800 "$VG" -a src="$src" -a dst="$dst" -a dither="$dither" -a size="$size" \
            -a frames=3 -a threads=1 "$HERE/repro.vpy" - >/dev/null 2>"$OUT/$tag.vg"
        writes=$(grep -c 'Invalid write' "$OUT/$tag.vg" || true)
        frame=$(grep -A12 -m1 'Invalid write' "$OUT/$tag.vg" | grep -m1 -oE '(init_context|ErrorDiffusion[A-Za-z0-9_]*|real_get_frame)' || true)
        # The script never ran (it prints 'repro:' when it finishes) and nothing was caught.
        grep -qE '^repro:|Invalid write' "$OUT/$tag.vg" || writes="no-run"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$LABEL" "$src>$dst/$dither" "$size" "$REPEAT" "$aborts" "${msg:--}" "$writes" "${frame:--}"
    done
done
