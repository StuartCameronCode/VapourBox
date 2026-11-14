#!/bin/bash
# Generate the source-grid fixtures (issue #16): sources whose stored frames
# do not map one-to-one onto the constant-rate frame numbers the app shows.
#
#   soft_telecine_dvd.vob  MPEG-2 program stream shaped like a DVD's film
#                          content: 120 progressive film frames (testsrc2,
#                          352x240, every frame differs), sequence header at
#                          29.97 fps (frame_rate_code 4), progressive_sequence
#                          0, and the 3:2 cadence of top_field_first /
#                          repeat_first_field flags (1,1),(0,0),(0,1),(1,0).
#                          Decoded at 29.97 it holds 150 slots: 4 film frames
#                          in every 5, the 5th a repeat. ffprobe reports r =
#                          60000/1001 and avg = 30000/1001, so the app sends
#                          29.97 (the field-coded rule of selectFrameRate).
#   soft_telecine_dvd.mkv  the same stream with MakeMKV-like timestamps: one
#                          per film frame at 23.976 spacing, the cadence only in
#                          the bitstream. ffprobe still reports 29.97 (from
#                          the header), so the decode still holds the repeats.
#   null_frames_mid.avi    MPEG-4 Part 2 (all-intra) in AVI, testsrc2 160x120 at 25 fps, with
#                          stored frames 100-104 dropped: the AVI muxer writes
#                          them as null (empty) frames, as a capture tool does
#                          when it drops frames. Slots 100-104 repeat frame 99.
#
# soft_telecine_test.mkv (generate_soft_telecine_test.sh) is the other shape:
# a 23.976 header with frame-repeat flags, which the app sends as 23.976.
#
# Usage: ./generate_source_grid_test.sh [output_dir] [ffmpeg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SCRIPT_DIR}"
FFMPEG="${2:-ffmpeg}"
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || FFPROBE=ffprobe

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$FFMPEG" -y -v error -f lavfi -i "testsrc2=size=352x240:rate=24000/1001:duration=5.005" \
    -frames:v 120 -vf format=yuv420p -c:v mpeg2video -b:v 600k -g 12 -bf 0 -f mpeg2video "$WORK/film.m2v"

python3 - "$WORK/film.m2v" "$WORK/dvd.m2v" <<'PYEOF'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
cadence = [(1, 1), (0, 0), (0, 1), (1, 0)]   # (top_field_first, repeat_first_field)
n = 0
i = 0
while True:
    i = d.find(b'\x00\x00\x01', i)
    if i < 0 or i + 9 >= len(d):
        break
    code = d[i + 3]
    if code == 0xB3:                       # sequence header: frame_rate_code 4
        d[i + 7] = (d[i + 7] & 0xF0) | 4
    elif code == 0xB5:
        ext = d[i + 4] >> 4
        if ext == 1:                       # sequence extension: progressive_sequence 0
            d[i + 5] &= ~0x08
        elif ext == 8:                     # picture coding extension
            tff, rff = cadence[n % 4]
            n += 1
            b = d[i + 7] & ~0x82
            d[i + 7] = b | (0x80 if tff else 0) | (0x02 if rff else 0) | 0x40
            d[i + 8] |= 0x80               # progressive_frame
    i += 3
open(sys.argv[2], 'wb').write(d)
print(f'patched {n} pictures')
PYEOF

"$FFMPEG" -y -v error -fflags +genpts -r 30000/1001 -i "$WORK/dvd.m2v" -c copy -f vob \
    "$OUTPUT_DIR/soft_telecine_dvd.vob"
"$FFMPEG" -y -v error -i "$OUTPUT_DIR/soft_telecine_dvd.vob" -map 0:v -c copy \
    -bsf:v 'setts=ts=N*3754:duration=3754' "$OUTPUT_DIR/soft_telecine_dvd.mkv"

"$FFMPEG" -y -v error -f lavfi -i "testsrc2=size=160x120:rate=25:duration=8" \
    -vf "select='not(between(n,100,104))'" -fps_mode passthrough \
    -c:v mpeg4 -g 1 -q:v 12 -pix_fmt yuv420p "$OUTPUT_DIR/null_frames_mid.avi"

for f in soft_telecine_dvd.vob soft_telecine_dvd.mkv null_frames_mid.avi; do
    echo "== $f: $("$FFPROBE" -v error -select_streams v:0 \
        -show_entries stream=r_frame_rate,avg_frame_rate,nb_frames:format=duration \
        -of csv=p=0 "$OUTPUT_DIR/$f" | tr '\n' ' ')"
done
# 120 film frames in both soft-telecine files, 195 stored in the AVI.
for f in soft_telecine_dvd.vob soft_telecine_dvd.mkv; do
    n=$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUTPUT_DIR/$f" | tr -d ",\n")
    [ "$n" = 120 ] || { echo "$f: $n frames, expected 120" >&2; exit 1; }
done
n=$("$FFPROBE" -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUTPUT_DIR/null_frames_mid.avi" | tr -d ",\n")
[ "$n" = 195 ] || { echo "null_frames_mid.avi: $n stored frames, expected 195" >&2; exit 1; }
ls -l "$OUTPUT_DIR"/soft_telecine_dvd.* "$OUTPUT_DIR/null_frames_mid.avi"
