#!/usr/bin/env bash
# Which dither types overrun (task #109): GRAY16 -> GRAY8 at 96x64 with each
# zimg dither type, through a tmp_overrun built by build.sh.
# Usage: dither_check.sh BIN
set -uo pipefail
BIN=$1
printf 'dither\ttmp_size\tstatus\n'
for d in none ordered random error_diffusion; do
    out=$("$BIN" - "dither-$d" gray16:unspec:l 96x64 gray8:unspec:l 96x64 point "$d" p 2>/dev/null | tail -n +2)
    if [ -z "$out" ]; then
        printf '%s\t-\tabort\n' "$d"
    else
        printf '%s\t%s\t%s\n' "$d" "$(cut -f3 <<<"$out")" "$(cut -f7 <<<"$out")"
    fi
done
