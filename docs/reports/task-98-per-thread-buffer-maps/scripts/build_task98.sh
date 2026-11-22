#!/bin/bash
# Builds the task #98 plugins INTO a copy of a macOS deps bundle, with the
# build code of Scripts/download-deps-macos.sh itself (its pins and its
# build_task98_plugin function, extracted and run here), so what is measured
# is what the deps build ships.
# Usage: build_task98.sh <copy of deps/macos-*> <work dir> [x86_64]
#   x86_64 builds the Intel variant on Apple Silicon through a c++ shim
#   (-arch x86_64, minos 12.0); the copy must then be an x64 bundle.
# Needs git, Xcode's clang, Homebrew fftw (headers), meson + ninja (EEDI3m).
set -euo pipefail
DEPS="$(cd "$1" && pwd)"; WORK="$2"; ARCH_WANTED="${3:-arm64}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
MAC="$REPO/Scripts/download-deps-macos.sh"
mkdir -p "$WORK/vsinc" "$WORK/build"
WORK="$(cd "$WORK" && pwd)"
for h in VapourSynth.h VSHelper.h VapourSynth4.h VSHelper4.h VSConstants4.h; do
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
    sed -n '/^TASK98_MARKER=/,/^EEDI3_TAG=/p' "$MAC"
    awk '/^FFTW_INC="\$\(brew --prefix fftw\)\/include"$/{p=1} /^# The three plugins below sit outside/{p=0} p' "$MAC"
    echo 'echo "built: ${BUILT_PLUGINS[*]}"'
} > "$WORK/build_block.sh"
bash "$WORK/build_block.sh"
# EEDI3m r10 + patch (arm64 only: x86_64 ships r8). The deps script builds it
# with meson through build_plugin; here meson is pointed at $WORK/vsinc.
if [ "$ARCH_WANTED" = arm64 ]; then
    TAG=$(sed -n 's/^EEDI3_TAG="\([^"]*\)".*/\1/p' "$MAC")
    rm -rf "$WORK/build/eedi3m"
    git clone -q --depth 1 --branch "$TAG" \
        https://github.com/HomeOfVapourSynthEvolution/VapourSynth-EEDI3.git "$WORK/build/eedi3m"
    cd "$WORK/build/eedi3m"
    git apply "$REPO/Scripts/patches/eedi3m-r10-thread-safety.patch"
    python3 - "$WORK/vsinc" <<'PY'
import re, sys
s = open('meson.build').read()
s = re.sub(r"run_command\(py, '-c', 'import vapoursynth as vs; print\(vs.get_include\(\)\)', check: true\)\.stdout\(\)\.strip\(\)",
           repr(sys.argv[1]), s)
open('meson.build', 'w').write(s)
PY
    meson setup build --buildtype=release >/dev/null && ninja -C build >/dev/null
    cp build/eedi3m.dylib "$DEPS/vapoursynth/plugins/libeedi3m.dylib"
    install_name_tool -id @loader_path/libeedi3m.dylib "$DEPS/vapoursynth/plugins/libeedi3m.dylib"
    codesign -s - -f "$DEPS/vapoursynth/plugins/libeedi3m.dylib" 2>/dev/null || true
    echo "built: eedi3m ($TAG, patched)"
fi
