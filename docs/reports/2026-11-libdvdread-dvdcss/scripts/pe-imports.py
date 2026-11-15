#!/usr/bin/env python3
"""Print the DLLs a PE file imports (import directory only). Usage: pe-imports.py FILE.dll"""
import struct, sys
d = open(sys.argv[1], "rb").read()
pe, = struct.unpack_from("<I", d, 0x3C)
nsec, = struct.unpack_from("<H", d, pe + 6)
optsz, = struct.unpack_from("<H", d, pe + 20)
opt = pe + 24
magic, = struct.unpack_from("<H", d, opt)
dirs = opt + (96 if magic == 0x10B else 112)
imp_rva, = struct.unpack_from("<I", d, dirs + 8)
secs = [struct.unpack_from("<8sIIII", d, opt + optsz + 40 * i) for i in range(nsec)]
def off(rva):
    for _n, vsize, va, rsize, raw in secs:
        if va <= rva < va + max(vsize, rsize):
            return rva - va + raw
    raise ValueError(hex(rva))
p = off(imp_rva)
while True:
    name_rva, = struct.unpack_from("<I", d, p + 12)
    if name_rva == 0:
        break
    o = off(name_rva)
    print(d[o:d.index(b"\0", o)].decode())
    p += 20
