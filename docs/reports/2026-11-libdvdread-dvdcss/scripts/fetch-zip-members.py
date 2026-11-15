#!/usr/bin/env python3
"""Extract the members of a remote zip whose names match a regex, by HTTP range
reads (only the central directory and those members are downloaded).

Usage: fetch-zip-members.py URL REGEX OUTDIR  (members land as OUTDIR/<path with / -> __>)
"""
import sys, struct, zlib, urllib.request, re
url, pattern, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
def rng(a, b):
    req = urllib.request.Request(url, headers={"Range": f"bytes={a}-{b}"})
    return urllib.request.urlopen(req).read()
req = urllib.request.Request(url, method="HEAD"); size = int(urllib.request.urlopen(req).headers["Content-Length"])
tail = rng(max(0, size-65536-22), size-1)
i = tail.rfind(b"PK\x05\x06")
cd_size, cd_off = struct.unpack("<II", tail[i+12:i+20])
if cd_off == 0xFFFFFFFF:
    j = tail.rfind(b"PK\x06\x06"); cd_size, cd_off = struct.unpack("<QQ", tail[j+40:j+56])
cd = rng(cd_off, cd_off+cd_size-1)
p = 0; hits = []
while p < len(cd) and cd[p:p+4] == b"PK\x01\x02":
    meth, = struct.unpack("<H", cd[p+10:p+12]); csz, usz = struct.unpack("<II", cd[p+20:p+28])
    nl, el, cl = struct.unpack("<HHH", cd[p+28:p+34]); lho, = struct.unpack("<I", cd[p+42:p+46])
    name = cd[p+46:p+46+nl].decode(errors="replace")
    extra = cd[p+46+nl:p+46+nl+el]
    q = 0
    while q < len(extra):
        hid, hl = struct.unpack("<HH", extra[q:q+4]); body = extra[q+4:q+4+hl]
        if hid == 1:
            vals = list(struct.unpack("<%dQ" % (hl//8), body)); k = 0
            if usz == 0xFFFFFFFF: usz = vals[k]; k += 1
            if csz == 0xFFFFFFFF: csz = vals[k]; k += 1
            if lho == 0xFFFFFFFF: lho = vals[k]
        q += 4 + hl
    if re.search(pattern, name, re.I): hits.append((name, meth, csz, usz, lho))
    p += 46 + nl + el + cl
for name, meth, csz, usz, lho in hits:
    print(name, usz)
    if name.endswith("/"): continue
    h = rng(lho, lho+29); nl, el = struct.unpack("<HH", h[26:30])
    data = rng(lho+30+nl+el, lho+30+nl+el+csz-1)
    if meth == 8: data = zlib.decompress(data, -15)
    open(outdir + "/" + name.replace("/", "__"), "wb").write(data)
