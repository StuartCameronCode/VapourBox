"""The price of the BT.709 conversion: time per frame, and what the extra
resample does to the picture.

Run with scripts/run_vs.sh. Takes 20 frames of the VHS fixture
(Tests/TestResources/interlaced_test.avi, 720x576 4:2:2, decoded to 4:2:0 as
most HD deliveries are), resizes them to 1350x1080 with Spline36 (what Crop &
Resize's 1920x1080 box does to a 720x576 square-pixel picture), and then

  * times the template's conversion (the COLOR_709 block, copied here) over
    200 frames, against the resize alone;
  * converts 601 -> 709 and straight back 709 -> 601, and compares each plane
    with the unconverted resize. That round trip is TWO conversions, so it
    bounds what one costs from above.
"""
import ctypes
import os
import subprocess
import time

import vapoursynth as vs

core = vs.core
REPO = os.environ['REPO']
FF = os.environ['FFMPEG']
SRC = os.path.join(REPO, 'Tests', 'TestResources', 'interlaced_test.avi')
W, H, N = 720, 576, 20

raw = subprocess.check_output([FF, '-v', 'error', '-i', SRC, '-frames:v', str(N),
                               '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-'])
FRAME = W * H * 3 // 2


def load():
    blank = core.std.BlankClip(width=W, height=H, format=vs.YUV420P8, length=N)

    def fill(n, f):
        fo = f.copy()
        data = raw[n * FRAME:(n + 1) * FRAME]
        offset = 0
        for p in range(3):
            pw, ph = (W, H) if p == 0 else (W // 2, H // 2)
            ptr, stride = fo.get_write_ptr(p).value, fo.get_stride(p)
            for y in range(ph):
                ctypes.memmove(ptr + y * stride, data[offset + y * pw: offset + (y + 1) * pw], pw)
            offset += pw * ph
        return fo
    return core.std.ModifyFrame(blank, blank, fill)


def convert(clip, m_in, m_out):
    # The template's block, with the matrices as arguments.
    clip = core.std.RemoveFrameProps(clip, props=["_Matrix", "_Range", "_ColorRange"])
    return core.resize.Spline36(clip, format=clip.format.id, matrix_in_s=m_in, matrix_s=m_out,
                                range_in_s="limited", range_s="limited", dither_type="error_diffusion")


src = load()
hd = core.resize.Spline36(src, 1350, 1080)
on = convert(hd, '170m', '709')
back = convert(on, '709', '170m')

for p, name in enumerate('YUV'):
    a = core.std.ShufflePlanes(hd, p, vs.GRAY)
    b = core.std.ShufflePlanes(back, p, vs.GRAY)
    diff = core.std.PlaneStats(a, b)
    mae = sum(f.props['PlaneStatsDiff'] for f in diff.frames()) / N * 255
    print(f'round trip 601->709->601, plane {name}: mean abs diff {mae:.3f}/255')

# The 20 resized frames are cached after the first pass, so "resize only"
# measures almost nothing and the second line is the conversion's own cost.
looped = core.std.Loop(hd, 10)
for label, clip in (('resize only', looped), ('resize + conversion', convert(looped, '170m', '709'))):
    start = time.perf_counter()
    for _ in clip.frames():
        pass
    dt = time.perf_counter() - start
    print(f'{label}: {clip.num_frames / dt:.1f} fps ({1000 * dt / clip.num_frames:.2f} ms/frame), {core.num_threads} threads')
