"""The report's two figures: where two runs of the unpatched FFT3DFilter
differ, on a flat picture and on the fixture (frame 4, luma), with the
difference amplified (x48, capped at 255) and drawn white on black. The same pair
through the patched build is all black. Writes img/*.png via ffmpeg.

  run.sh <deps> figures.py <build.sh output dir> <img dir>
"""
import os, subprocess, sys
import vapoursynth as vs
from common import clip, FFMPEG
core = vs.core
B, OUT = sys.argv[1], sys.argv[2]
EXT = '.dylib' if sys.platform == 'darwin' else '.so'
core.std.LoadPlugin(B + '/orig/libfft3d_orig' + EXT)
core.std.LoadPlugin(B + '/fixed/libfft3d_fixed' + EXT)
core.num_threads = 8

flat = core.std.BlankClip(width=720, height=480, format=vs.YUV420P8, length=10, color=[100, 128, 128])
real = clip('420', 8, 0, 720, 480, frames=10)


def diff_png(ns, src, kw, name, frame=4):
    fn = getattr(core, ns).FFT3DFilter
    worst = None
    # Two fresh graphs, frames in reverse then forward order, so each
    # transform instance's previous frame differs between them.
    a = fn(src, **kw); b = fn(src, **kw)
    for n in reversed(range(src.num_frames)): a.get_frame(n)
    fa, fb = a.get_frame(frame), b.get_frame(frame)
    A, Bv = fa[0].tolist(), fb[0].tolist()
    w, h = len(A[0]), len(A)
    buf = bytearray()
    mx = 0
    for ra, rb in zip(A, Bv):
        for u, v in zip(ra, rb):
            d = abs(u - v); mx = max(mx, d)
            buf.append(min(255, d * 48))
    path = os.path.join(OUT, name)
    # The left 64 columns of the top 128 rows, each sample drawn 4x4.
    subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'gray',
                    '-s', '%dx%d' % (w, h), '-i', '-', '-frames:v', '1',
                    '-vf', 'crop=64:128:0:0,scale=256:512:flags=neighbor', path], input=bytes(buf), check=True)
    cols = sorted({x for ra, rb in zip(A, Bv) for x, (u, v) in enumerate(zip(ra, rb)) if u != v})
    print(name, 'max diff', mx, 'differing columns', (cols[0], cols[-1], len(cols)) if cols else None)


os.makedirs(OUT, exist_ok=True)
diff_png('fft3dorig', flat, dict(sigma=16, bt=1), '01-flat-unpatched.png')
diff_png('fft3dfixed', flat, dict(sigma=16, bt=1), '02-flat-patched.png')
diff_png('fft3dorig', real, dict(sigma=16, bt=1), '03-fixture-unpatched.png')
diff_png('fft3dfixed', real, dict(sigma=16, bt=1), '04-fixture-patched.png')
