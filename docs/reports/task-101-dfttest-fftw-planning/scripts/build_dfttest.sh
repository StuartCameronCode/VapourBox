#!/bin/bash
# Builds DFTTest INTO a copy of a macOS deps bundle with the build code of
# Scripts/download-deps-macos.sh itself (its pins, markers and
# build_task98_plugin, extracted and run here), so what is measured is what
# the deps build ships: the thread-safety patch (task #98) and the
# FFTW_ESTIMATE patch (task #101), on arm64 yuygfgg's fork, on x86_64 upstream.
# Usage: build_dfttest.sh <copy of deps/macos-*> <work dir> [x86_64]
#   x86_64 builds the Intel variant on Apple Silicon through a c++ shim
#   (-arch x86_64, minos 12.0); the copy must then be an x64 bundle.
# Needs git, Xcode's clang and Homebrew fftw (headers).
set -euo pipefail
DEPS="$(cd "$1" && pwd)"; WORK="$2"; ARCH_WANTED="${3:-arm64}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
MAC="$REPO/Scripts/download-deps-macos.sh"
mkdir -p "$WORK/vsinc" "$WORK/build"
WORK="$(cd "$WORK" && pwd)"
for h in VapourSynth.h VSHelper.h; do
    [ -f "$WORK/vsinc/$h" ] || curl -sfL -o "$WORK/vsinc/$h" \
        "https://raw.githubusercontent.com/vapoursynth/vapoursynth/R78/include/$h"
done
if [ "$ARCH_WANTED" = x86_64 ]; then
    mkdir -p "$WORK/shim"
    printf '#!/bin/bash\nexec /usr/bin/c++ -arch x86_64 -mmacosx-version-min=12.0 "$@"\n' > "$WORK/shim/c++"
    chmod +x "$WORK/shim/c++"
    export PATH="$WORK/shim:$PATH"
fi
{
    echo 'set -euo pipefail'
    echo "ARCH=$ARCH_WANTED; FORCE=true; BUILD_DIR='$WORK/build'"
    echo "LIB_DIR='$DEPS/lib'; PLUGINS_DIR='$DEPS/vapoursynth/plugins'"
    echo "VS_INC_DIR='$WORK/vsinc'; SCRIPT_DIR='$REPO/Scripts'"
    echo 'BUILT_PLUGINS=(); FAILED_PLUGINS=()'
    sed -n '/^TASK98_MARKER=/,/^DFTTEST_ARM64_COMMIT=/p' "$MAC"
    # The function and the DFTTest call only (not LGhost, CTMF, TCanny).
    awk '/^FFTW_INC="\$\(brew --prefix fftw\)\/include"$/{p=1} /^build_task98_plugin LGhost/{p=0} p' "$MAC"
    echo 'echo "built: ${BUILT_PLUGINS[*]}"'
} > "$WORK/build_block.sh"
bash "$WORK/build_block.sh"
