"""Frames per second of TCanny(mode=-1) and gauss_blur at 1080p 4:2:0 8-bit."""
import sys
import time

sys.path.insert(0, sys.argv[1])
import vapoursynth as vs
from gauss_blur import gaussian_blur

core = vs.core
c = core.grain.Add(core.std.BlankClip(width=1920, height=1080, format=vs.YUV420P8, length=200), var=50)
for name, make in (('TCanny sigma 2, all planes', lambda: core.tcanny.TCanny(c, sigma=2, mode=-1)),
                   ('gaussian_blur sigma 2, all planes', lambda: gaussian_blur(c, 2)),
                   ('TCanny sigma 0.849, luma', lambda: core.tcanny.TCanny(c, sigma=0.849, mode=-1, planes=[0])),
                   ('gaussian_blur sigma 0.849, luma', lambda: gaussian_blur(c, 0.849, [0]))):
    out = make()
    t = time.time()
    for _ in out.frames():
        pass
    print(f'{name:36s} {200 / (time.time() - t):.0f} fps')
