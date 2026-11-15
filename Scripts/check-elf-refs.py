#!/usr/bin/env python3
"""Fail if any ELF file in a Linux deps bundle needs something outside it.

The Linux counterpart of check-macho-refs.py (task #36, where the macOS arm64
libdvdread linked Homebrew's libdvdcss by absolute path). ELF dependencies
are leaf names resolved through the search path, so the ways a Linux bundle
can reach outside itself are:

  * a DT_NEEDED entry holding a path ("/usr/local/lib/libfoo.so.1", or a
    relative one, which resolves against the working directory) other than
    one under $ORIGIN (python-build-standalone's python links
    $ORIGIN/../lib/libpython3.12.so.1.0, which glibc expands);
  * a DT_RPATH / DT_RUNPATH entry that is not under $ORIGIN — an absolute
    directory can only be the build machine's (the bundle is relocatable),
    and a bare relative one resolves against the working directory.

A NEEDED system library by leaf name (libc.so.6, libstdc++.so.6) is fine:
that is how the bundle states its glibc floor.

Parsed in plain Python (no readelf), so it runs on any host, including a
macOS checkout inspecting a downloaded Linux bundle.

Usage: check-elf-refs.py ROOT   exit 1 on a problem
"""

import os
import struct
import sys

DT_NULL, DT_NEEDED, DT_STRTAB, DT_RPATH, DT_RUNPATH = 0, 1, 5, 15, 29
PT_LOAD, PT_DYNAMIC = 1, 2
ORIGIN = ("$ORIGIN", "${ORIGIN}")


def dynamic_entries(path):
    """Return [(tag, string)] for NEEDED/RPATH/RUNPATH, or None if not ELF."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or len(data) < 64:
        return None
    is64 = data[4] == 2
    end = "<" if data[5] == 1 else ">"
    if is64:
        e_phoff, = struct.unpack_from(end + "Q", data, 0x20)
        e_phentsize, e_phnum = struct.unpack_from(end + "HH", data, 0x36)
    else:
        e_phoff, = struct.unpack_from(end + "I", data, 0x1C)
        e_phentsize, e_phnum = struct.unpack_from(end + "HH", data, 0x2A)

    loads, dyn = [], None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if is64:
            p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz = struct.unpack_from(end + "IIQQQQ", data, off)
        else:
            p_type, p_offset, p_vaddr, _paddr, p_filesz = struct.unpack_from(end + "IIIII", data, off)
        if p_type == PT_LOAD:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == PT_DYNAMIC:
            dyn = (p_offset, p_filesz)
    if dyn is None:
        return []  # static executable or object without a dynamic section

    def vaddr_to_offset(addr):
        for vaddr, offset, size in loads:
            if vaddr <= addr < vaddr + size:
                return addr - vaddr + offset
        return None

    fmt, size = (end + "qQ", 16) if is64 else (end + "iI", 8)
    raw, strtab = [], None
    for off in range(dyn[0], dyn[0] + dyn[1], size):
        tag, val = struct.unpack_from(fmt, data, off)
        if tag == DT_NULL:
            break
        if tag == DT_STRTAB:
            strtab = vaddr_to_offset(val)
        elif tag in (DT_NEEDED, DT_RPATH, DT_RUNPATH):
            raw.append((tag, val))
    if strtab is None:
        return []

    def string_at(offset):
        stop = data.index(b"\0", strtab + offset)
        return data[strtab + offset:stop].decode("utf-8", "replace")

    return [(tag, string_at(val)) for tag, val in raw]


def problems_in(path):
    found = []
    for tag, value in dynamic_entries(path) or []:
        if tag == DT_NEEDED:
            if "/" in value and not value.startswith(ORIGIN):
                found.append(f"NEEDED {value}")
        else:
            name = "RPATH" if tag == DT_RPATH else "RUNPATH"
            for entry in value.split(":"):
                if entry and not entry.startswith(ORIGIN):
                    found.append(f"{name} {entry}")
    return found


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit(__doc__.strip().splitlines()[-1])
    root = os.path.abspath(sys.argv[1])
    checked, bad = 0, 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            try:
                with open(path, "rb") as f:
                    if f.read(4) != b"\x7fELF":
                        continue
            except OSError:
                continue
            checked += 1
            for problem in problems_in(path):
                print(f"  ✗ {os.path.relpath(path, root)}: {problem}")
                bad += 1
    if bad:
        print(f"ERROR: {bad} dynamic entr(y/ies) above reach outside the bundle "
              "(task #36).", file=sys.stderr)
        return 1
    print(f"  ✓ {checked} ELF files depend only on the bundle and system libraries by name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
