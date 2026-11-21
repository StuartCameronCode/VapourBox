# Shared by the scripts here. DEPS: a deps/<platform> bundle (default: the
# repo's deps/macos-arm64). WORK: a scratch directory (default: a new temp dir).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
DEPS="${DEPS:-$REPO/deps/macos-arm64}"
FF="$DEPS/ffmpeg/ffmpeg"
FP="$DEPS/ffmpeg/ffprobe"
WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
size() { "$FP" -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt -of csv=p=0 "$1"; }
# A testsrc2 picture scaled to W x H in FMT (testsrc2's own s= rounds the size
# down to the chroma grid, so it never makes one).
fixture() { "$FF" -v error -y -f lavfi -i testsrc2=s=128x96:r=25:d=0.4 -vf "scale=$1:$2,format=$3" "${@:5}" -c:v ffv1 "$4"; }
