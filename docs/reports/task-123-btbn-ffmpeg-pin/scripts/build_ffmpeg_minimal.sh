#!/bin/bash
# build_ffmpeg_minimal.sh <work dir> [commit]
# A minimal FFmpeg at the commit BtbN's n9.0.2-963 was built from (release/9.0,
# 4d831360c9 by default): enough to read the VHS fixture (lagarith/AVI), pipe
# Y4M, scale, crop and pad, and write FFV1/MKV. Prints the binary's path.
# Takes ~3 minutes on an M1. Not BtbN's binary; the nightly re-run is.
set -euo pipefail
W=$1; C=${2:-4d831360c9}
mkdir -p "$W"
if [ ! -d "$W/ff" ]; then
  git clone -q --filter=blob:none --no-checkout --single-branch -b release/9.0 \
    https://github.com/FFmpeg/FFmpeg.git "$W/ff"
fi
cd "$W/ff"
git checkout -q "$C"
./configure --disable-everything --disable-doc --disable-autodetect --disable-network \
  --enable-protocol=file,pipe \
  --enable-demuxer=avi,matroska,rawvideo,yuv4mpegpipe \
  --enable-muxer=matroska,framemd5,rawvideo,null,yuv4mpegpipe,mov \
  --enable-decoder=lagarith,ffv1,rawvideo,wrapped_avframe \
  --enable-encoder=ffv1,rawvideo,wrapped_avframe,prores_ks \
  --enable-filter=setpts,fps,crop,scale,format,null,setparams,settb,trim,pad \
  --enable-ffprobe > /dev/null
make -j"$(getconf _NPROCESSORS_ONLN)" ffmpeg ffprobe > build.log 2>&1
echo "$W/ff/ffmpeg"
