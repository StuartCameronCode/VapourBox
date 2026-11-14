#!/usr/bin/env python3
"""Print the MOV/MP4 `fiel` atom of the first video sample entry, as hex.

Walks the box tree (moov/trak/mdia/minf/stbl/stsd/<entry>/fiel) instead of
searching the file for the bytes "fiel": x265 writes its options into the
stream as text, and its "field=0" contains them, so a byte search reads
garbage from an HEVC file.

    fiel.py FILE   ->  0209 | 020e | 0100 | absent
"""
import struct
import sys

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl"}
VISUAL_ENTRY_FIELDS = 78  # after the 8-byte box header


def find(data, off, end, sample_entries=False):
    while off + 8 <= end:
        size, typ = struct.unpack(">I4s", data[off:off + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[off + 8:off + 16])[0]
            header = 16
        elif size == 0:
            size = end - off
        if size < header:
            return None
        hit = None
        if sample_entries:
            hit = find(data, off + header + VISUAL_ENTRY_FIELDS, off + size)
        elif typ in CONTAINERS:
            hit = find(data, off + header, off + size)
        elif typ == b"stsd":
            # Full box (version/flags) + entry count, then the sample entries.
            hit = find(data, off + header + 8, off + size, sample_entries=True)
        elif typ == b"fiel":
            hit = data[off + header:off + header + 2].hex()
        if hit:
            return hit
        off += size
    return None


if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    print(find(data, 0, len(data)) or "absent")
