"""Read, and optionally patch, each audio stream's header in an AVI.

    python3 riff_block_align.py show  out.avi [...]
    python3 riff_block_align.py patch out.avi [...]   # the worker's fix, in Python

`show` prints one JSON line per audio stream: wFormatTag, channels,
nBlockAlign, the stream's dwSampleSize and dwSuggestedBufferSize (avienc's
trailer writes the largest chunk there), and the byte offset of nBlockAlign.

`patch` applies the same rule as worker/src/avi_header.rs: for an AAC stream
(wFormatTag 0x00FF) stored as VBR (dwSampleSize 0) whose largest chunk is over
its nBlockAlign, set nBlockAlign to the largest chunk. Nothing else changes.
Walks the RIFF structure; it never searches the bytes.
"""
import json
import struct
import sys


def chunks(data, start, end):
    i = start
    while i + 8 <= end:
        fourcc = data[i:i + 4]
        size = struct.unpack_from('<I', data, i + 4)[0]
        yield fourcc, i + 8, min(size, end - i - 8)
        i += 8 + size + (size & 1)


def audio_streams(path):
    with open(path, 'rb') as f:
        data = f.read(1 << 20)
    if data[:4] != b'RIFF' or data[8:12] != b'AVI ':
        raise SystemExit(f'{path}: not an AVI')
    out = []
    index = 0
    for c, o, s in chunks(data, 12, len(data)):
        if c != b'LIST' or data[o:o + 4] != b'hdrl':
            continue
        for c2, o2, s2 in chunks(data, o + 4, o + s):
            if c2 != b'LIST' or data[o2:o2 + 4] != b'strl':
                continue
            strh = strf = None
            for c3, o3, s3 in chunks(data, o2 + 4, o2 + s2):
                if c3 == b'strh':
                    strh = (o3, s3)
                elif c3 == b'strf':
                    strf = (o3, s3)
            if strh and strh[1] >= 48 and data[strh[0]:strh[0] + 4] == b'auds' and strf and strf[1] >= 14:
                h = strh[0]
                sugg, _, ssize = struct.unpack_from('<IiI', data, h + 36)
                tag, ch, rate, avg, blk = struct.unpack_from('<HHIIH', data, strf[0])
                out.append({'stream': index, 'wFormatTag': f'0x{tag:04X}', 'channels': ch, 'rate': rate,
                            'nBlockAlign': blk, 'dwSampleSize': ssize, 'dwSuggestedBufferSize': sugg,
                            'blockAlignOffset': strf[0] + 12})
            index += 1
    return out


def patch(path):
    fixes = []
    for a in audio_streams(path):
        if (a['wFormatTag'] == '0x00FF' and a['dwSampleSize'] == 0
                and a['nBlockAlign'] < a['dwSuggestedBufferSize'] <= 0xFFFF):
            fixes.append(a)
    if fixes:
        with open(path, 'r+b') as f:
            for a in fixes:
                f.seek(a['blockAlignOffset'])
                f.write(struct.pack('<H', a['dwSuggestedBufferSize']))
    return [{'stream': a['stream'], 'from': a['nBlockAlign'], 'to': a['dwSuggestedBufferSize']} for a in fixes]


if __name__ == '__main__':
    mode, paths = sys.argv[1], sys.argv[2:]
    for p in paths:
        if mode == 'show':
            for a in audio_streams(p):
                print(json.dumps({'file': p, **a}))
        elif mode == 'patch':
            print(json.dumps({'file': p, 'fixes': patch(p)}))
        else:
            raise SystemExit('usage: riff_block_align.py show|patch file.avi ...')
