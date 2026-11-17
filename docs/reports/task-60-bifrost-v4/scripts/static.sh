#!/bin/bash
# Static checks of the Bifrost 4.0 wheels: hash, architecture, minimum OS,
# linked libraries, AVX instructions and (macOS x64) load-time SIMD.
#
#   static.sh <dir with vapoursynth_bifrost-4.0-*.whl> <scratch dir> <repo>
#
# macOS host (otool, xcrun llvm-objdump). Each wheel is unpacked into its own
# directory under the scratch dir; nothing in it is executed.
set -euo pipefail
W="$(cd "$1" && pwd)"; X="$2"; REPO="$3"
rm -rf "$X"; mkdir -p "$X"
for f in "$W"/vapoursynth_bifrost-4.0-*.whl; do
  n=$(basename "$f" .whl | sed 's/vapoursynth_bifrost-4.0-py3-none-//')
  case "$n" in musllinux*) continue ;; esac
  echo "== $n  sha256 $(shasum -a 256 "$f" | cut -d' ' -f1)"
  mkdir -p "$X/$n"; unzip -q "$f" -d "$X/$n"
  bin=$(ls "$X/$n"/vapoursynth/plugins/bifrost.*)
  file "$bin" | sed 's/^[^:]*: //'
  case "$n" in
    macosx*)
      otool -L "$bin" | tail -n +2
      otool -l "$bin" | grep -A3 LC_BUILD_VERSION | grep minos
      ;;
    manylinux*)
      xcrun llvm-objdump -p "$bin" | grep -E "NEEDED" || true
      for v in GLIBC GLIBCXX; do
        xcrun llvm-objdump -T "$bin" | grep -oE "${v}_[0-9.]+" | sort -uV | tail -1
      done
      ;;
    win*)
      xcrun llvm-objdump -p "$bin" | grep "DLL Name"
      ;;
  esac
  case "$n" in
    *arm64*|*aarch64*) ;;
    *) echo "  ymm/zmm instructions: $(xcrun llvm-objdump -d --no-show-raw-insn "$bin" | grep -cE '%[yz]mm' || true)" ;;
  esac
  case "$n" in
    macosx*x86_64) python3 "$REPO/Scripts/check-load-time-simd.py" "$bin" ;;
  esac
done
