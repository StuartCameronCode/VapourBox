"""Read an AVI's own header: avih.dwTotalFrames and each stream's strh fields.

Backs up ffprobe's nb_frames (which is the same field) without ffmpeg in the
loop. Null frames (zero-length 00dc chunks) are counted by both.

    python3 riff.py out.avi [...]
"""
import json, struct, sys


def chunks(data, start, end):
    i = start
    while i + 8 <= end:
        fourcc = data[i:i + 4].decode('latin-1')
        size = struct.unpack('<I', data[i + 4:i + 8])[0]
        yield fourcc, i + 8, size
        i += 8 + size + (size & 1)


def header(path):
    with open(path, 'rb') as f:
        data = f.read(1 << 20)  # the hdrl list is at the start
    assert data[:4] == b'RIFF' and data[8:12] == b'AVI ', 'not an AVI'
    out = {'streams': []}
    for fourcc, off, size in chunks(data, 12, len(data)):
        if fourcc != 'LIST' or data[off:off + 4] != b'hdrl':
            continue
        for c, o, s in chunks(data, off + 4, off + size):
            if c == 'avih':
                out['avih_total_frames'] = struct.unpack('<I', data[o + 16:o + 20])[0]
                out['avih_us_per_frame'] = struct.unpack('<I', data[o:o + 4])[0]
            elif c == 'LIST' and data[o:o + 4] == b'strl':
                for c2, o2, _ in chunks(data, o + 4, o + s):
                    if c2 == 'strh':
                        kind = data[o2:o2 + 4].decode('latin-1')
                        scale, rate, start, length = struct.unpack('<IIII', data[o2 + 20:o2 + 36])
                        sample_size = struct.unpack('<I', data[o2 + 44:o2 + 48])[0]
                        out['streams'].append(dict(type=kind, scale=scale, rate=rate, start=start, length=length,
                                                   sample_size=sample_size))
        break
    return out


if __name__ == '__main__':
    for p in sys.argv[1:]:
        print(json.dumps(dict(file=p.rsplit('/', 1)[-1], **header(p))))
