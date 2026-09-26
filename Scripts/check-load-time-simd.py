#!/usr/bin/env python3
"""Fail if an x86_64 Mach-O plugin can run AVX instructions while it loads.

Issue #92: prebuilt MVTools compiles six files with -mavx2, and their static
initializers — run by dyld inside dlopen, before any plugin code can check the
CPU — contain VEX instructions. VapourSynth autoloads every plugin when a core
starts, so on a CPU without AVX every job died with SIGILL whatever it asked
for. Runtime SIMD dispatch in the plugin's filters cannot help: this runs
first.

macOS has no Intel SDE, so the v2 bundle is checked statically here instead
(Linux and Windows are checked by running under SDE; see
.github/workflows/probe-cpu-compat.yml). Initializers are found structurally,
from __init_offsets / __mod_init_func, never by symbol name — LTO and
toolchains rename them freely, and a name-based scan once came back clean on a
binary it simply could not see into. Direct calls and tail calls are followed,
because the VEX can sit in a helper the initializer calls rather than in the
initializer itself.

Usage: check-load-time-simd.py [--depth N] BINARY...
Exit 1 if any binary can reach a VEX instruction from an initializer.
"""

import argparse
import bisect
import re
import shutil
import struct
import subprocess
import sys

LC_SEGMENT_64 = 0x19
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
CPU_TYPE_X86_64 = 0x01000007

# VEX-encoded (AVX and later) mnemonics start with "v" in LLVM's AT&T syntax;
# these few legacy instructions also do and are not VEX.
NOT_VEX = {"verr", "verw"}


def x86_64_slice(data):
    """Return (bytes, offset) of the x86_64 Mach-O image in a thin or fat file."""
    magic = struct.unpack(">I", data[:4])[0]
    if magic == FAT_MAGIC:
        nfat = struct.unpack(">I", data[4:8])[0]
        for i in range(nfat):
            cputype, _, offset, size, _ = struct.unpack(">iiIII", data[8 + i * 20:28 + i * 20])
            if cputype == CPU_TYPE_X86_64:
                return data[offset:offset + size]
        return None
    if struct.unpack("<I", data[:4])[0] == MH_MAGIC_64:
        cputype = struct.unpack("<i", data[4:8])[0]
        return data if cputype == CPU_TYPE_X86_64 else None
    return None


def initializer_addresses(image):
    """Virtual addresses of every static initializer in a Mach-O image."""
    ncmds = struct.unpack("<I", image[16:20])[0]
    off = 32
    text_base = None
    text_range = None
    sections = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", image[off:off + 8])
        if cmd == LC_SEGMENT_64:
            segname = image[off + 8:off + 24].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff = struct.unpack("<QQQ", image[off + 24:off + 48])
            nsects = struct.unpack("<I", image[off + 64:off + 68])[0]
            if segname == "__TEXT":
                text_base, text_range = vmaddr, (vmaddr, vmaddr + vmsize)
            s = off + 72
            for _ in range(nsects):
                sectname = image[s:s + 16].rstrip(b"\0").decode()
                addr, size = struct.unpack("<QQ", image[s + 32:s + 48])
                sect_off = struct.unpack("<I", image[s + 48:s + 52])[0]
                sections.append((sectname, addr, size, sect_off))
                s += 80
        off += cmdsize

    addrs = []
    for name, _, size, sect_off in sections:
        raw = image[sect_off:sect_off + size]
        if name == "__init_offsets":
            # 32-bit offsets from the image base (newer linkers).
            addrs += [text_base + v for (v,) in struct.iter_unpack("<I", raw)]
        elif name == "__mod_init_func":
            # 64-bit pointers: a plain vmaddr with classic rebasing, or a
            # chained-fixup rebase whose target sits in the low 36 bits
            # (as a vmaddr or as an offset from the image base).
            for (v,) in struct.iter_unpack("<Q", raw):
                for cand in (v, v & 0xFFFFFFFFF, text_base + (v & 0xFFFFFFFFF)):
                    if text_range[0] <= cand < text_range[1]:
                        addrs.append(cand)
                        break
                else:
                    raise SystemExit(f"cannot decode initializer pointer {v:#x}")
    return addrs


def disassemble(path):
    """Per function: start address, name, VEX instructions, call/jump targets."""
    objdump = shutil.which("llvm-objdump") or subprocess.run(
        ["xcrun", "--find", "llvm-objdump"], capture_output=True, text=True).stdout.strip()
    out = subprocess.run([objdump, "-d", "--no-show-raw-insn", "--arch=x86_64", path],
                         capture_output=True, text=True, check=True).stdout
    funcs = {}
    cur = None
    label = re.compile(r"^([0-9a-f]+) <(.+)>:$")
    insn = re.compile(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$")
    # Direct targets only ("0x1234 <sym>"). An indirect `jmpq *0x..(%rip)`
    # names a GOT slot, not code, and following it links unrelated functions.
    target = re.compile(r"^0x([0-9a-f]+)")
    for line in out.splitlines():
        m = label.match(line)
        if m:
            cur = int(m.group(1), 16)
            funcs[cur] = {"name": m.group(2), "vex": [], "calls": set()}
            continue
        m = insn.match(line)
        if not m or cur is None:
            continue
        addr, mnem, ops = int(m.group(1), 16), m.group(2), m.group(3)
        if mnem.startswith("v") and mnem not in NOT_VEX:
            funcs[cur]["vex"].append(f"{addr:#x}: {mnem} {ops}".strip())
        if mnem.startswith("call") or mnem.startswith("jmp"):
            t = target.match(ops)
            if t:
                funcs[cur]["calls"].add(int(t.group(1), 16))
    # Stub tables are trampolines into OTHER images (libc++, libSystem), which
    # this check cannot see into; never walk through them.
    return {a: f for a, f in funcs.items()
            if f["name"] not in ("__stubs", "__stub_helper", "__auth_stubs")}


def check(path, depth):
    with open(path, "rb") as f:
        image = x86_64_slice(f.read())
    if image is None:
        return f"{path}: no x86_64 image, skipped", []
    roots = initializer_addresses(image)
    if not roots:
        # Nothing runs at load time. Checked before disassembling: some valid
        # images (Zig-linked zsmooth) have a header layout llvm-objdump rejects.
        return f"{path}: 0 initializers", []
    try:
        funcs = disassemble(path)
    except subprocess.CalledProcessError as e:
        # Initializers we cannot inspect are a failure, not a pass.
        return (f"{path}: {len(roots)} initializers", [
            f"could not disassemble: {e.stderr.strip().splitlines()[-1] if e.stderr else e}"])
    starts = sorted(funcs)

    def owner(addr):
        i = bisect.bisect_right(starts, addr) - 1
        return starts[i] if i >= 0 else None

    findings = []
    seen = set()
    frontier = [(owner(r), [owner(r)]) for r in roots if owner(r) is not None]
    for _ in range(depth + 1):
        nxt = []
        for fn, chain in frontier:
            if fn in seen:
                continue
            seen.add(fn)
            info = funcs[fn]
            if info["vex"]:
                names = " -> ".join(funcs[c]["name"] for c in chain)
                findings.append(f"{names}\n      first: {info['vex'][0]} "
                                f"({len(info['vex'])} VEX instructions)")
            for t in info["calls"]:
                o = owner(t)
                if o is not None and o != fn:
                    nxt.append((o, chain + [o]))
        frontier = nxt
    return f"{path}: {len(roots)} initializers, {len(seen)} functions reachable", findings


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("binaries", nargs="+")
    ap.add_argument("--depth", type=int, default=6,
                    help="call depth to follow from each initializer")
    args = ap.parse_args()
    bad = 0
    for b in args.binaries:
        summary, findings = check(b, args.depth)
        print(("FAIL " if findings else "ok   ") + summary)
        for f in findings:
            print("    " + f)
        bad += bool(findings)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
