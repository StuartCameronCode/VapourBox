"""Which VapourSynth API each plugin in a deps bundle implements (task #68).

    python3 scan_plugin_api.py <deps-dir> [--json]

VapourSynth R80 dropped API 3: its plugin loader looks up
`VapourSynthPluginInit2` (API 4) and refuses a library that only has
`VapourSynthPluginInit` (API 3) with "uses API 3, which is no longer
supported" (src/core/vscore.cpp, R82). This lists every shared library under
the bundle that exports either entry point, by searching the file for the
exported names as NUL-terminated strings (an export table stores them so in
Mach-O, ELF and PE alike; Mach-O adds a leading underscore). Reading the
bytes rather than running nm/objdump makes it work on any platform's bundle
from any host.

Limits: a name in a string table is evidence of the export, not proof, and a
library that implements both is reported as both. Cross-checked on macOS
arm64 against `nm -gU`, which agreed for all 39 plugins.
"""
import json
import os
import sys

API4 = b"VapourSynthPluginInit2\0"
API3 = b"VapourSynthPluginInit\0"
EXTS = (".dylib", ".so", ".dll")
# The core looks both names up, so its own library holds both strings.
CORE = ("libvapoursynth.", "vapoursynth.dll", "libvapoursynth-")


def scan(root):
    rows = []
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith(EXTS) and ".so." not in name:
                continue
            if name.startswith(CORE):
                continue
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            has4 = API4 in data
            has3 = API3 in data
            if has4 or has3:
                api = "4+3" if has4 and has3 else ("4" if has4 else "3")
                rows.append((os.path.relpath(path, root).replace(os.sep, "/"), api))
    return sorted(rows)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rows = scan(sys.argv[1])
    if "--json" in sys.argv:
        print(json.dumps([{"file": f, "api": a} for f, a in rows], indent=1))
        return
    for f, a in rows:
        print(f"API {a:<3}  {f}")
    only3 = [f for f, a in rows if a == "3"]
    print(f"\n{len(rows)} plugins, {len(only3)} API 3 only (refused by R80+)")


if __name__ == "__main__":
    main()
