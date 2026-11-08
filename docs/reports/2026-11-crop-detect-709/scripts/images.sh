#!/bin/bash
# Renders the report's images into ../img from the outputs of the two heavy
# tests (run them first: crop_detect.sh, and
# `flutter test test/integration_bt709_conversion_test.dart`).
#
# Detected crops are drawn as a 1-px box: red = the recommended crop, yellow =
# with the letterbox / pillarbox bars. Zooms are 4x nearest-neighbour, so
# every pixel shown is a real one.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
export DEPS="${DEPS:-$ROOT/deps/macos-arm64}"
FF="$DEPS/ffmpeg/ffmpeg -v error -y"
IMG="$HERE/../img"
OUT="$ROOT/Tests/TestOutput"
mkdir -p "$IMG"

# box FILE FIELD -> "drawbox filters" for the detected crop
box() {
  python3 - "$1" "$2" <<'EOF'
import json, subprocess, sys, os
here = os.environ['HERE']
r = json.loads(subprocess.check_output([sys.executable, os.path.join(here, 'detect.py'), sys.argv[1], sys.argv[2], '--json']))
w, h = r['width'], r['height']
def rect(c, colour):
    return (f"drawbox=x={c['left']}:y={c['top']}:w={w - c['left'] - c['right']}:"
            f"h={h - c['top'] - c['bottom']}:color={colour}:t=1")
parts = [rect(r['crop'], 'red')]
if r.get('cropWithBars'):
    parts.insert(0, rect(r['cropWithBars'], 'yellow'))
print(','.join(parts))
EOF
}
export HERE

# frame FILE FIELD N OUT [ZOOM_CROP]   (ZOOM_CROP = w:h:x:y, shown 4x)
frame() {
  local B; B=$(box "$1" "$2")
  local Z=""
  [ -n "$5" ] && Z=",crop=$5,scale=iw*4:ih*4:flags=neighbor"
  $FF -i "$1" -vf "select=eq(n\,$3),format=yuv444p,$B$Z" -frames:v 1 "$4"
}

C="$OUT/crop_detect"
frame "$C/vhs.mkv" progressive 15 "$IMG/02-vhs-fixture-detected.png"
frame "$C/vhs.mkv" progressive 15 "$IMG/03-vhs-fixture-bottom-left-x4.png" "128:40:0:536"
frame "$C/letterbox.mkv" progressive 15 "$IMG/04-letterbox-detected.png"
frame "$C/subtitles.mkv" progressive 13 "$IMG/05-subtitles-detected.png"
frame "$ROOT/Tests/TestResources/interlaced_test.avi" tff 40 "$IMG/06-real-vhs-detected.png"
frame "$ROOT/Tests/TestResources/interlaced_test.avi" tff 40 "$IMG/07-real-vhs-left-x4.png" "48:96:0:240"
frame "$ROOT/Tests/TestResources/pal-dvbt-fieldcoded-25i.ts" tff 60 "$IMG/08-dvbt-detected.png"
frame "$ROOT/Tests/TestResources/pal-dvbt-fieldcoded-25i.ts" tff 60 "$IMG/09-dvbt-bottom-left-x4.png" "64:24:0:552"

# BT.601 -> 709: the same eight patches three ways, each decoded explicitly.
B="$OUT/bt709_conversion"
D="flags=accurate_rnd+full_chroma_int,format=rgb24,scale=450:360:flags=neighbor"
$FF -i "$B/sd601_patches.mkv" -i "$B/off_1080.mkv" -i "$B/on_1080.mkv" -filter_complex \
  "[0:v]select=eq(n\,2),scale=in_color_matrix=bt601:in_range=tv:out_range=pc:$D[a];\
   [1:v]select=eq(n\,2),scale=in_color_matrix=bt709:in_range=tv:out_range=pc:$D[b];\
   [2:v]select=eq(n\,2),scale=in_color_matrix=bt709:in_range=tv:out_range=pc:$D[c];\
   [a][b][c]hstack=3" -frames:v 1 "$IMG/01-bt709-patches.png"
ls -la "$IMG"
