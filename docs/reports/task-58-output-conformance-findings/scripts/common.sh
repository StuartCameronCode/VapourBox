# Shared by the task #58 scripts: the repo, the deps bundle, a scratch dir.
# VAPOURBOX_DEPS_DIR (deps/<platform>) as for every heavy test, else the
# repo's own deps/macos-arm64; SCRATCH, else a new temporary directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
DEPS="${VAPOURBOX_DEPS_DIR:-$REPO/deps/macos-arm64}"
FFMPEG="$DEPS/ffmpeg/ffmpeg"
FFPROBE="$DEPS/ffmpeg/ffprobe"
VSPIPE="$DEPS/vapoursynth/vspipe"
RES="$REPO/Tests/TestResources"
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"
