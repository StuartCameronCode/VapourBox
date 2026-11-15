#!/bin/bash
# Does avienc's dwSuggestedBufferSize cover an OpenDML (> 1 GiB) file's
# second RIFF (AVIX)? 82 s of 720x576 rawvideo (~1.2 GB) with a quiet tone
# for 70 s, then the harsh sound (harsh_audio.py), so every AAC packet over
# 768 bytes lies past the first RIFF. Prints where the largest packet is, what
# the header records, and the timestamp gaps before and after the fix.
#
#   ./odml_check.sh <ffmpeg dir> <work dir>    (needs ~1.2 GB free)
set -euo pipefail
FF="$1"; W="$2"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$W"
python3 -I "$here/harsh_audio.py" "$FF/ffmpeg" "$W/harsh_stereo.wav" "$W/harsh_mono.wav"
"$FF/ffmpeg" -v error -y -f lavfi -i "testsrc2=s=720x576:r=25:d=82" -f lavfi -i "sine=f=200:r=48000:d=70" \
    -i "$W/harsh_mono.wav" -filter_complex "[1]volume=0.05[t];[t][2]concat=n=2:v=0:a=1[a]" \
    -map 0:v -map "[a]" -c:v rawvideo -pix_fmt yuv420p -c:a aac -b:a 256k "$W/big.avi"
first_riff=$(python3 -c "import struct,sys; d=open(sys.argv[1],'rb').read(8); print(8+struct.unpack('<I',d[4:])[0])" "$W/big.avi")
"$FF/ffprobe" -v error -select_streams a:0 -show_entries packet=pts,size,pos -of csv=p=0 "$W/big.avi" > "$W/big_packets.csv"
awk -F, -v r="$first_riff" '{if($2>m){m=$2;p=$3}; if($2>768){c++; if($3<r)e++}} END{print "largest packet", m, "at byte", p, "(first RIFF ends at", r "); packets over 768:", c, "of which in the first RIFF:", e+0}' "$W/big_packets.csv"
python3 -I "$here/riff_block_align.py" show "$W/big.avi"
gaps() { "$FF/ffprobe" -v error -select_streams a:0 -show_entries packet=pts -of csv=p=0 "$W/big.avi" | awk 'NR>1 && $1!=p+1{g++} {p=$1} END{print g+0}'; }
echo "timestamp gaps before: $(gaps)"
python3 -I "$here/riff_block_align.py" patch "$W/big.avi"
echo "timestamp gaps after: $(gaps)"
rm -f "$W/big.avi"
