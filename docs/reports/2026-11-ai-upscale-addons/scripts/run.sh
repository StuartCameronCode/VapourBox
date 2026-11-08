#!/bin/bash
# Every number in the report, from the committed fixtures.
#
#   run.sh [parity|psnr|fps|tiles|vhs2hd|crops|all]
#
# Environment:
#   VAPOURBOX_DEPS_DIR  a deps bundle (deps/macos-arm64) with VSNCNN and ffmpeg
#   CONVERT_PY          the conversion venv's python (numpy, onnxruntime)
#   ADDON_FILES         a directory holding the add-on models: the four
#                       upscale-*.onnx from Scripts/models/convert_realesrgan.py
#                       and 2xLiveActionV1_SPAN_490000.onnx (an add-on mirror,
#                       or the installed addons/<id>/ directories' files)
#   SCRATCH             where frames and outputs go (default: a new temp dir)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
: "${VAPOURBOX_DEPS_DIR:?set VAPOURBOX_DEPS_DIR to a deps bundle}"
: "${CONVERT_PY:?set CONVERT_PY to the conversion venv python}"
: "${ADDON_FILES:?set ADDON_FILES to the directory holding the add-on ONNX files}"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"
VS="$VAPOURBOX_DEPS_DIR/vapoursynth/vspipe"
FF="$VAPOURBOX_DEPS_DIR/ffmpeg/ffmpeg"
NC="$VAPOURBOX_DEPS_DIR/vapoursynth/ncnn/models"
RES="$REPO/Tests/TestResources"

# The models by short name (macOS ships bash 3.2: no associative arrays).
model() {
  case $1 in
    general) echo "$ADDON_FILES/upscale-realesr-general-x4v3.onnx" ;;
    wdn) echo "$ADDON_FILES/upscale-realesr-general-wdn-x4v3.onnx" ;;
    span) echo "$ADDON_FILES/2xLiveActionV1_SPAN_490000.onnx" ;;
    x2plus) echo "$ADDON_FILES/upscale-RealESRGAN_x2plus.onnx" ;;
    x4plus) echo "$ADDON_FILES/upscale-RealESRGAN_x4plus.onnx" ;;
    anime2) echo "$NC/RealESRGANv2/RealESRGANv2-animevideo-xsx2.onnx" ;;
    anime4) echo "$NC/RealESRGANv2/RealESRGANv2-animevideo-xsx4.onnx" ;;
    cugan) echo "$NC/cugan/up2x-latest-conservative.onnx" ;;
  esac
}

frames() {
  # small: 320x240 frame of the progressive clip (parity input).
  # dvb: a 720x576 broadcast frame (bwdif-deinterlaced) as ground truth, and
  # its 360x288 bicubic downscale as the input a 2x upscale must restore.
  [ -f "$SCRATCH/small.gbrpf" ] || "$FF" -v error -y -ss 20 -i "$RES/small_clip.mp4" \
    -frames:v 1 -vf format=gbrpf32le -f rawvideo "$SCRATCH/small.gbrpf"
  [ -f "$SCRATCH/dvb.gbrpf" ] || "$FF" -v error -y -ss 1 -i "$RES/pal-dvbt-fieldcoded-25i.ts" \
    -frames:v 1 -vf bwdif=0,format=gbrpf32le -f rawvideo "$SCRATCH/dvb.gbrpf"
  [ -f "$SCRATCH/dvb-half.gbrpf" ] || "$FF" -v error -y -ss 1 -i "$RES/pal-dvbt-fieldcoded-25i.ts" \
    -frames:v 1 -vf bwdif=0,scale=360:288:flags=bicubic,format=gbrpf32le -f rawvideo "$SCRATCH/dvb-half.gbrpf"
}

# vs <out> <vspipe -a args...>: run upscale.vpy, print vspipe's timing line.
vs() {
  local out=$1; shift
  local args=(-a deps="$VAPOURBOX_DEPS_DIR")
  for a in "$@"; do args+=(-a "$a"); done
  "$VS" "${args[@]}" "$HERE/upscale.vpy" "$out" 2>"$SCRATCH/vspipe.log" || {
    grep -v "VK_\|mvk-info" "$SCRATCH/vspipe.log" | tail -5; return 1; }
  grep -E "^Output" "$SCRATCH/vspipe.log" || true
}

parity() {
  echo "== VSNCNN vs ONNX Runtime (CPU fp32), 320x240 frame, 8-bit levels"
  for k in general wdn span x2plus x4plus anime4; do
    for fp16 in 0 1; do
      vs "$SCRATCH/p.raw" infile="$SCRATCH/small.gbrpf" w=320 h=240 model="$(model $k)" fp16=$fp16 >/dev/null
      printf '%-8s fp16=%s  ' "$k" "$fp16"
      "$CONVERT_PY" -I "$HERE/metrics.py" ort "$SCRATCH/small.gbrpf" 320 240 "$(model $k)" "$SCRATCH/p.raw"
    done
  done
}

psnr() {
  echo "== 360x288 -> 720x576 against the original frame (PSNR rewards softness)"
  one() { local label=$1; shift
    vs "$SCRATCH/q.raw" infile="$SCRATCH/dvb-half.gbrpf" w=360 h=288 tw=720 th=576 "$@" >/dev/null
    printf '%-34s ' "$label"
    "$CONVERT_PY" -I "$HERE/metrics.py" psnr "$SCRATCH/dvb.gbrpf" 720 576 "$SCRATCH/q.raw"; }
  one "Spline36" model=
  for k in Spline36 Lanczos Bicubic Bilinear; do one "General 4x, then $k to 2x" model="$(model general)" down=$k; done
  one "General denoise 4x, Spline36 to 2x" model="$(model wdn)"
  one "Live Action SPAN 2x" model="$(model span)"
  one "x2plus 2x" model="$(model x2plus)"
  one "x4plus 4x, Spline36 to 2x" model="$(model x4plus)"
  one "(bundled) Real-ESRGAN anime 2x" model="$(model anime2)"
  one "(bundled) Real-CUGAN conservative 2x" model="$(model cugan)"
}

fps() {
  echo "== 720x576 -> 2x / 4x, 10 frames, fp16, num_streams=2 (the template's settings)"
  one() { local label=$1; shift; printf '%-28s ' "$label"
    vs /dev/null infile="$SCRATCH/dvb.gbrpf" w=720 h=576 n=10 "$@"; }
  one "(bundled) anime 2x" model="$(model anime2)"
  one "(bundled) CUGAN 2x" model="$(model cugan)"
  one "General 2x (4x + resample)" model="$(model general)" tw=1440 th=1152
  one "General 4x" model="$(model general)"
  one "SPAN 2x" model="$(model span)"
  one "SPAN 4x (twice)" model="$(model span),$(model span)"
  one "x2plus 2x" model="$(model x2plus)"
  one "x4plus 4x (384 tiles)" model="$(model x4plus)" tile=384
}

tiles() {
  echo "== x4plus at 720x576: tile size and streams (4 frames each)"
  for t in "0 2" "512 2" "512 1" "384 2" "384 1" "256 2" "256 1" "192 2" "128 2"; do
    set -- $t
    printf 'tile=%-4s streams=%s  ' "$1" "$2"
    vs /dev/null infile="$SCRATCH/dvb.gbrpf" w=720 h=576 n=4 model="$(model x4plus)" tile=$1 streams=$2 \
      || echo "(failed)"
  done
  echo "== x2plus at 720x576"
  for t in "0 2" "0 1" "512 2" "256 2"; do
    set -- $t
    printf 'tile=%-4s streams=%s  ' "$1" "$2"
    vs /dev/null infile="$SCRATCH/dvb.gbrpf" w=720 h=576 n=4 model="$(model x2plus)" tile=$1 streams=$2 \
      || echo "(failed)"
  done
  echo "== a tile larger than the frame (General on 360x288)"
  printf 'tile=384 as given    '
  vs /dev/null infile="$SCRATCH/dvb-half.gbrpf" w=360 h=288 model="$(model general)" tile=384 clamp=0 \
    || echo "(failed)"
  printf 'tile=384 clamped     '
  vs /dev/null infile="$SCRATCH/dvb-half.gbrpf" w=360 h=288 model="$(model general)" tile=384 \
    || echo "(failed)"
}

vhs2hd() {
  echo "== 2xVHS2HD-RealPLKSR through VSNCNN"
  local f="$SCRATCH/2xVHS2HD-RealPLKSR.onnx"
  [ -f "$f" ] || curl -sSfL -o "$f" \
    https://github.com/starinspace/StarinspaceUpscale/releases/download/Models/2xVHS2HD-RealPLKSR.onnx
  shasum -a 256 "$f"
  vs /dev/null infile="$SCRATCH/small.gbrpf" w=320 h=240 model="$f" || true
  echo "-- ncnn's import messages, counted:"
  grep -E "not supported|not exists|load param" "$SCRATCH/vspipe.log" | sort | uniq -c | sort -rn
}

crops() {
  # Zoomed, nearest-neighbour crops of the 2x restorations for the report.
  local out="$HERE/../img"
  crop() { local name=$1; shift
    vs "$SCRATCH/c.raw" infile="$SCRATCH/dvb-half.gbrpf" w=360 h=288 tw=720 th=576 "$@" >/dev/null
    "$FF" -v error -y -f rawvideo -pix_fmt gbrpf32le -s 720x576 -i "$SCRATCH/c.raw" \
      -vf "crop=240:200:360:180,scale=480:400:flags=neighbor,format=rgb24" -frames:v 1 "$out/$name.png"; }
  "$FF" -v error -y -f rawvideo -pix_fmt gbrpf32le -s 720x576 -i "$SCRATCH/dvb.gbrpf" \
    -vf "crop=240:200:360:180,scale=480:400:flags=neighbor,format=rgb24" -frames:v 1 "$out/01-original.png"
  crop 02-spline36 model=
  crop 03-general model="$(model general)"
  crop 04-general-denoise model="$(model wdn)"
  crop 05-live-action-span model="$(model span)"
  crop 06-x2plus model="$(model x2plus)"
  crop 07-anime-esrgan model="$(model anime2)"
}

frames
case "${1:-all}" in
  parity) parity ;; psnr) psnr ;; fps) fps ;; tiles) tiles ;; vhs2hd) vhs2hd ;; crops) crops ;;
  all) parity; psnr; fps; tiles; vhs2hd; crops ;;
  *) echo "unknown section $1"; exit 1 ;;
esac
