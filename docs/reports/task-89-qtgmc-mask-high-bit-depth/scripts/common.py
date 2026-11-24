"""Shared by the task #89 scripts: the fixture, decoded by the bundle's
ffmpeg, as three clips, and the difference measure.

Tests/TestResources/pal-sd-25.mov is an 8-bit master in a 10-bit 4:2:2
container (its low two bits are 0.002 levels from zero), so the "real"
10-bit clip gets sub-8-bit content from a light blur at 10 bits:
  src10r  the blurred 10-bit picture (0.47 levels of real low bits)
  src8    src10r rounded to 8 bits (resize.Point, undithered)
  src10x  src8 back at 10 bits, an exact x4: the same picture at two depths
Run with the bundle's Python (reproduce.sh sets it up).
"""
import ctypes
import os
import subprocess
import sys

import vapoursynth as vs

core = vs.core
core.max_cache_size = 4096

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'worker', 'templates'))

W, H, N = 720, 576, 40
FIRST, LAST = 6, 30   # frames measured (QTGMC's temporal edges left out)


def _decode():
    ffmpeg = os.environ.get('VAPOURBOX_FFMPEG', 'ffmpeg')
    src = os.path.join(REPO, 'Tests', 'TestResources', 'pal-sd-25.mov')
    return subprocess.run(
        [ffmpeg, '-v', 'error', '-i', src, '-frames:v', str(N), '-f', 'rawvideo',
         '-pix_fmt', 'yuv422p10le', '-'], check=True, stdout=subprocess.PIPE).stdout


def sources():
    data = _decode()
    fsize = W * H * 2 * 2
    blank = core.std.BlankClip(width=W, height=H, format=vs.YUV422P10, length=N, fpsnum=25, fpsden=1)

    def read(n, f):
        fo = f.copy()
        off = n * fsize
        for p, (pw, ph) in enumerate([(W, H), (W // 2, H), (W // 2, H)]):
            stride = fo.get_stride(p)
            ptr = ctypes.cast(fo.get_write_ptr(p), ctypes.c_void_p).value
            row = pw * 2
            for y in range(ph):
                ctypes.memmove(ptr + y * stride, data[off + y * row: off + (y + 1) * row], row)
            off += row * ph
        return fo

    src10r = core.std.ModifyFrame(blank, blank, read)
    src10r = core.std.SetFrameProps(src10r, _Matrix=6, _FieldBased=0)
    src10r = core.std.Convolution(src10r, [1, 2, 1, 2, 12, 2, 1, 2, 1])
    src8 = core.resize.Point(src10r, format=vs.YUV422P8)
    src10x = core.resize.Point(src8, format=vs.YUV422P10)
    return src10r, src8, src10x


def low_bits(src10r, src10x):
    """Mean |real 10-bit - rounded 8-bit x4| of luma, in 10-bit levels."""
    st = core.std.PlaneStats(src10r, src10x, plane=0)
    return st.get_frame(10).props['PlaneStatsDiff'] * 1023


def stats(a, b):
    """(mean, max) |a - b| of luma over the measured frames, in b's levels;
    a is brought to b's depth by a plain division first."""
    shift = a.format.bits_per_sample - b.format.bits_per_sample
    if shift:
        a = core.std.Expr(a, 'x %d /' % (1 << shift), format=a.format.replace(bits_per_sample=b.format.bits_per_sample).id)
    if a.format.id != b.format.id:
        a = core.resize.Point(a, format=b.format.id)
    d = core.std.PlaneStats(a, b, plane=0)
    e = core.std.PlaneStats(core.std.Expr([a, b], 'x y - abs'), plane=0)
    tot, mx = 0.0, 0
    for n in range(FIRST, LAST):
        tot += d.get_frame(n).props['PlaneStatsDiff']
        mx = max(mx, e.get_frame(n).props['PlaneStatsMax'])
    return round(tot / (LAST - FIRST) * ((1 << b.format.bits_per_sample) - 1), 3), int(mx)
