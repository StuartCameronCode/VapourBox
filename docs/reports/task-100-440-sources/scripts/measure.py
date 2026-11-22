#!/usr/bin/env python3
"""Task #100: what a 4:2:2 pipe and a 4:4:4 pipe keep of a 4:4:0 source.

    python3 -I measure.py <path to the bundle's ffmpeg>

Scratch files go in $VAPOURBOX_REPORT_SCRATCH, else a fresh temporary
directory. Plain Python (no NumPy). Each fixture is one 128x96 FFV1 frame,
decoded the way the worker's decoder does it (`-pix_fmt <pipe>`, ffmpeg's
default scaler), then compared with the source. Chroma only: luma was
identical in every row.

A. Against the source rendered at 4:4:4 by the same scaler in one step,
   which is what a 4:4:4 pipe delivers.
B. 1-pixel red/blue columns (no vertical detail), read back by nearest
   neighbour, so the vertical upsampling method doesn't matter.
C. Against the source's own chroma samples with rows duplicated by nearest
   neighbour. The 4:4:4 pipe is not 0 here: its vertical upsampling
   interpolates rows rather than repeating them, which is resampling, not
   loss.
"""
import os
import subprocess
import sys
import tempfile

FF = sys.argv[1]
W, H = 128, 96
N = W * H
SCRATCH = os.environ.get('VAPOURBOX_REPORT_SCRATCH') or tempfile.mkdtemp(prefix='task100-')
os.makedirs(SCRATCH, exist_ok=True)


def path(name):
    return os.path.join(SCRATCH, name)


def run(*args):
    subprocess.run([FF, '-v', 'error', '-y', *args], check=True)


def raw(src, fmt, vf=()):
    return subprocess.run(
        [FF, '-v', 'error', '-i', src, *vf, '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', fmt, '-'],
        check=True, capture_output=True).stdout


def samples(buf, ten_bit):
    if not ten_bit:
        return list(buf)
    return [(buf[i] | buf[i + 1] << 8) / 4 for i in range(0, len(buf), 2)]


def chroma_diff(a, b, ten_bit=False):
    a, b = samples(a, ten_bit), samples(b, ten_bit)
    d = [abs(x - y) for x, y in zip(a[N:], b[N:])]
    return sum(d) / len(d), max(d)


def pipe_decode(src, pipe, name):
    out = path(f'{name}_{pipe}.nut')
    run('-i', src, '-frames:v', '1', '-pix_fmt', pipe, '-c:v', 'rawvideo', out)
    return out


print('A. against the source rendered at 4:4:4 in one step (8-bit levels)')
for fmt, extra in (('yuv440p', ()), ('yuv440p_pc', ('-color_range', 'pc'))):
    src = path(f'a_{fmt}.mkv')
    rng = 'pc' if extra else 'tv'
    run('-f', 'lavfi', '-i', f'testsrc2=s={W}x{H}', '-frames:v', '1',
        '-vf', f'scale=out_range={rng},format=yuv440p', *extra, '-c:v', 'ffv1', src)
    ref = raw(src, 'yuv444p')
    for pipe in ('yuv422p', 'yuv444p'):
        back = raw(pipe_decode(src, pipe, f'a_{fmt}'), 'yuv444p')
        m, x = chroma_diff(ref, back)
        print(f'  {fmt:12} via {pipe}: mean {m:.2f} max {x}')

print('B. 1-pixel colour columns, read back by nearest neighbour')
src = path('b_cols.mkv')
run('-f', 'lavfi', '-i',
    f"color=s={W}x{H}:c=black,format=gbrp,geq=r='if(mod(X,2),255,0)':g='0':b='if(mod(X,2),0,255)'",
    '-frames:v', '1', '-vf', 'format=yuv440p', '-c:v', 'ffv1', src)
nb = ('-vf', 'scale=flags=neighbor')
ref = raw(src, 'yuv444p', nb)
for pipe in ('yuv422p', 'yuv444p'):
    back = raw(pipe_decode(src, pipe, 'b_cols'), 'yuv444p', nb)
    m, x = chroma_diff(ref, back)
    print(f'  columns      via {pipe}: mean {m:.2f} max {x}')

print('C. against the source chroma, rows repeated by nearest neighbour')
for fmt, ten in (('yuv440p', False), ('yuv440p10le', True)):
    src = path(f'c_{fmt}.mkv')
    run('-f', 'lavfi', '-i', f'testsrc2=s={W}x{H}', '-frames:v', '1',
        '-pix_fmt', fmt, '-c:v', 'ffv1', src)
    out = 'yuv444p10le' if ten else 'yuv444p'
    ref = raw(src, out, nb)
    for pipe in (('yuv422p10le', 'yuv444p10le') if ten else ('yuv422p', 'yuv444p')):
        back = raw(pipe_decode(src, pipe, f'c_{fmt}'), out, nb)
        m, x = chroma_diff(ref, back, ten)
        print(f'  {fmt:12} via {pipe}: mean {m:.2f} max {x:g}')
