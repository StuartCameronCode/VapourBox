#!/bin/bash
# Regenerate every app icon asset from Scripts/generate-app-icon.swift.
#
# The Swift renderer is the source of truth; this script just drives it at the
# sizes each platform wants and packs the Windows .ico. Re-run it after changing
# the design — the PNGs are committed because Xcode's asset catalog and the
# Windows resource compiler need them at build time.
#
#   ./Scripts/generate-app-icons.sh
#
# macOS needs its own inset rounded body (Apple's icon grid); Windows takes the
# artwork full-bleed, because Windows draws no mask of its own.
#
# Requires Swift, which ships with the Xcode command line tools. macOS only —
# CoreGraphics does the drawing.

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER="$PROJECT_ROOT/Scripts/generate-app-icon.swift"
ICONSET="$PROJECT_ROOT/app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
WIN_RES="$PROJECT_ROOT/app/windows/runner/resources"

if ! command -v swift >/dev/null 2>&1; then
    echo "ERROR: swift not found — install the Xcode command line tools." >&2
    exit 1
fi

echo "==> macOS iconset"
# Contents.json references these seven files (16 and 32 are each used at both 1x
# and 2x, which is why the list is not one-per-slot).
for size in 16 32 64 128 256 512 1024; do
    swift "$RENDER" --size "$size" --style macos --out "$ICONSET/app_icon_$size.png"
done

echo "==> Windows .ico"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WIN_SIZES=(16 32 48 64 128 256)
for size in "${WIN_SIZES[@]}"; do
    swift "$RENDER" --size "$size" --style square --out "$TMP/win_$size.png"
done

python3 - "$TMP" "$WIN_RES/app_icon.ico" "${WIN_SIZES[@]}" <<'PY'
import struct, sys, pathlib

tmp, out, *sizes = sys.argv[1:]
sizes = [int(s) for s in sizes]

# ICO container. Each entry holds a whole PNG, which Windows has accepted since
# Vista and which keeps the alpha channel clean — the alternative (BMP entries
# with an AND mask) would mean hand-rolling the mask.
blobs = [pathlib.Path(tmp, f'win_{s}.png').read_bytes() for s in sizes]

header = struct.pack('<HHH', 0, 1, len(sizes))          # reserved, type=icon, count
offset = 6 + 16 * len(sizes)                            # past the directory
directory = b''
for size, blob in zip(sizes, blobs):
    directory += struct.pack(
        '<BBBBHHII',
        0 if size >= 256 else size,   # width  (0 means 256)
        0 if size >= 256 else size,   # height
        0,                            # palette size (0 = not paletted)
        0,                            # reserved
        1,                            # colour planes
        32,                           # bits per pixel
        len(blob),
        offset)
    offset += len(blob)

pathlib.Path(out).write_bytes(header + directory + b''.join(blobs))
print(f'  {out} ({len(sizes)} sizes: {", ".join(map(str, sizes))})')
PY

echo ""
echo "Done. Rebuild the app to see them:"
echo "  ./Scripts/run-debug-macos.sh --skip-worker"
