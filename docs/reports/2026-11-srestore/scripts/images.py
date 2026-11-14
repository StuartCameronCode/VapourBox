"""The report's comparison images (img/), from the deinterlaced fixtures.

For each fixture, the output frame where plain decimation is furthest from
any original: [plain decimation | Unblend | the original frame], each scaled
2x with nearest-neighbour so the pixels are real.
"""
import os
import subprocess

import probelib as P
from probelib import core, vs

IMG = os.path.join(P.HERE, '..', 'img')
os.makedirs(IMG, exist_ok=True)


def png(clip, n, path):
    rgb = core.resize.Point(clip[n], format=vs.RGB24, matrix_in_s='170m')
    f = rgb.get_frame(0)
    import ctypes
    raw = b''.join(
        b''.join(ctypes.string_at(f.get_read_ptr(p).value + y * f.get_stride(p), f.width)
                 for y in range(f.height))
        for p in range(3))
    # Planar RGB -> ffmpeg gbrp order is G, B, R.
    planes = [raw[i * f.width * f.height:(i + 1) * f.width * f.height] for i in range(3)]
    subprocess.run([P.FFMPEG, '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'gbrp',
                    '-s', f'{f.width}x{f.height}', '-i', '-', '-frames:v', '1', path],
                   input=planes[1] + planes[2] + planes[0], check=True)


for i, fx in enumerate(('film', 'pal'), start=1):
    clip = P.bobbed(fx)
    gt = P.truth(P.TRUTH_COUNT[fx], 'yuv420p')
    num, den = P.TARGETS[fx]
    frfac, numr, denm = P.srestore.ratio(clip.fps_num, clip.fps_den, num, den)
    dec = P.render(clip, [(0, False)] * len(clip), num, den)
    unb = P.srestore.unblend(clip, num, den)
    if clip.format.bits_per_sample != 8:
        dec = core.resize.Point(dec, format=vs.YUV420P8)
        unb = core.resize.Point(unb, format=vs.YUV420P8)
    picks_dec = P.nearest_truth(dec, gt, 1.0)
    picks_unb = P.nearest_truth(unb, gt, 1.0)
    m = max(range(len(picks_dec)), key=lambda k: picks_dec[k][1])
    truth_idx = picks_unb[m][0]
    row = core.std.StackHorizontal([dec[m], unb[m], gt[truth_idx]])
    row = core.resize.Point(row, row.width * 2, row.height * 2)
    out = os.path.join(IMG, f'{i}-{fx}-worst-decimated-frame.png')
    png(row, 0, out)
    print(fx, 'output', m, 'decimation MAD', round(picks_dec[m][1], 2),
          'unblend MAD', round(picks_unb[m][1], 2), 'original', truth_idx, '->', out)
