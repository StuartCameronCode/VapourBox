"""Fast pan and hard cuts: where interpolators fail hardest."""
import os, sys
from harness import *
a = load("small.yuv", 320, 240, vs.YUV420P8, 40, 30000, 1001)
b = load("small30.yuv", 320, 240, vs.YUV420P8, 40, 30000, 1001)
# fast pan: 8 px/frame across a 2x frame
big = core.resize.Bicubic(a, 640, 480)
pan = core.std.FrameEval(a, lambda n: core.std.CropAbs(big, 320, 240, left=min(n*8, 318), top=120))
cuts = a[0:8] + b[0:8] + a[8:16] + b[8:16] + a[16:24]
for name, src in (("pan", pan), ("cuts", cuts)):
    for m in ("FLOWFPS", "RIFE"):
        for nr, sh in [(0,0),(1,1)]:
            v = dark_metric(run(src, m, nr, sh, 60000, 1001))
            dm = sum(x for x,_,_ in v)/len(v); dx = max(v)
            print(f"{name:4s} {m:7s} nr={nr} sh={sh}: dark mean {100*dm:.3f}% max {100*dx[0]:.3f}% (f{dx[2]})", flush=True)
