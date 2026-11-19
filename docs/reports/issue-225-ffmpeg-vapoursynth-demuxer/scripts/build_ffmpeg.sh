#!/bin/bash
# Builds FFmpeg 9.0.2 with the VapourSynth demuxer (and libx264 from Homebrew),
# so both arms of the comparison use one FFmpeg binary.
# Usage: WORK=<scratch dir> build_ffmpeg.sh   -> $WORK/ffvs/bin/ffmpeg
set -euo pipefail
: "${WORK:?set WORK to a scratch directory}"
mkdir -p "$WORK/src" "$WORK/build"
cd "$WORK/src"
[ -d ffmpeg ] || git clone -q --depth 1 --branch n9.0.2 https://github.com/FFmpeg/FFmpeg.git ffmpeg
[ -d vs ] || git clone -q --depth 1 --branch R78 https://github.com/vapoursynth/vapoursynth.git vs
mkdir -p inc/vapoursynth && cp vs/include/*.h inc/vapoursynth/
X264="$(brew --prefix x264)"
cd "$WORK/build"
"$WORK/src/ffmpeg/configure" --prefix="$WORK/ffvs" --disable-doc --disable-network --disable-everything \
  --enable-gpl --enable-libx264 --enable-vapoursynth \
  --enable-demuxer=vapoursynth,yuv4mpegpipe,rawvideo,mov,matroska,avi,mpegts,mpegps \
  --enable-decoder=wrapped_avframe,rawvideo,h264,mpeg2video,huffyuv,ffv1,dvvideo,prores \
  --enable-encoder=libx264,ffv1,rawvideo,wrapped_avframe \
  --enable-muxer=null,matroska,yuv4mpegpipe,rawvideo,framemd5 \
  --enable-protocol=file,pipe,fd --enable-filter=scale,format,null,setpts,fps,trim,setparams \
  --enable-parser=h264,mpegvideo \
  --extra-cflags="-I$WORK/src/inc -I$X264/include" --extra-ldflags="-L$X264/lib"
make -j"$(sysctl -n hw.ncpu)" && make install
