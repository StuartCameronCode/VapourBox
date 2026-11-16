#!/bin/bash
# Download the two macOS x64 FFmpeg builds this report compares, into DIR:
#   DIR/evermeet/{ffmpeg,ffprobe}   evermeet.cx 9.0.1 (deps <= 1.17.0-rc1)
#   DIR/mr/{ffmpeg,ffprobe}         martin-riedl.de 9.0.2, build 1789931006
#                                   (deps 1.17.0-rc2 on), checked by SHA-256
# Usage: fetch.sh DIR
set -euo pipefail
DIR="${1:?usage: fetch.sh DIR}"
mkdir -p "$DIR/evermeet" "$DIR/mr"

for f in ffmpeg ffprobe; do
    curl -fsSL "https://evermeet.cx/ffmpeg/$f-9.0.1.zip" -o "$DIR/evermeet/$f.zip"
    unzip -q -o "$DIR/evermeet/$f.zip" -d "$DIR/evermeet"
done

BASE="https://ffmpeg.martin-riedl.de/download/macos/amd64/1789931006_9.0.2"
curl -fsSL "$BASE/ffmpeg.zip" -o "$DIR/mr/ffmpeg.zip"
curl -fsSL "$BASE/ffprobe.zip" -o "$DIR/mr/ffprobe.zip"
( cd "$DIR/mr" && shasum -a 256 -c - <<'EOF'
7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4  ffmpeg.zip
2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd  ffprobe.zip
EOF
)
unzip -q -o "$DIR/mr/ffmpeg.zip" -d "$DIR/mr"
unzip -q -o "$DIR/mr/ffprobe.zip" -d "$DIR/mr"
echo "fetched into $DIR"
