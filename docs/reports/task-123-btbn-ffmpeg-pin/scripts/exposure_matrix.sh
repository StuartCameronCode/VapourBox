#!/bin/bash
# exposure_matrix.sh <ffmpeg> <dir holding new_yuv420p.mkv and new_yuv422p.mkv from fixture.sh>
# Every way the worker lets FFmpeg convert a still-interlaced picture, at
# 720x486: a Y4M pipe (as vspipe writes it, "Ip") with -top 1 / -top 0 on the
# input (field_order_args) and -flags +ildct, through each format an encoder is
# pinned to (forced_pix_fmt, AMF nv12, HEVC p010, ProRes / v210 422p10 / 444p10,
# rgb), the preview's scale, and a pad / format / crop chain. The control
# (scale=interl=-1, which keeps the frame's interlaced flag) is the only shape
# that reaches swscale's field check. Prints OK / FAIL per row.
set -uo pipefail
F=$1; D=$2
row() { local name=$1 cmd=$2 out
  if out=$(bash -c "$cmd" 2>&1); then echo "OK   $name"
  else echo "FAIL $name: $(echo "$out" | grep -m1 -iE 'field|error|invalid')"; fi; }
for src in 420:yuv420p 422:yuv422p 422:yuv422p10le 420:yuv420p10le; do
  s=${src%%:*}; pf=${src#*:}
  Y="'$F' -v error -i '$D/new_yuv${s}p.mkv' -f yuv4mpegpipe -strict -1 -pix_fmt $pf pipe:"
  for top in 1 0; do
    E="'$F' -v error -y -top $top -f yuv4mpegpipe -i pipe:"
    for out in yuv420p nv12 p010le yuv422p10le yuv444p10le rgb24; do
      row "src=$pf top=$top -pix_fmt $out +ildct" "$Y | $E -pix_fmt $out -flags +ildct -f null pipe:"
    done
    row "src=$pf top=$top preview scale to rgb48be" \
      "$Y | $E -vf scale=out_range=pc:flags=accurate_rnd+full_chroma_int,format=rgb48be -f null pipe:"
    row "src=$pf top=$top pad, format, crop" "$Y | $E -vf pad=720:488,format=yuv420p,crop=720:486 -f null pipe:"
    row "src=$pf top=$top CONTROL scale=interl=-1 to yuv422p" "$Y | $E -vf scale=interl=-1,format=yuv422p -f null pipe:"
  done
done
