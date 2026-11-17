"""RestoreMotionBlocks leaks each instance it frees (task #57).

  removedirt_leak.py <mode>   peak RSS (MB) every 1000 frames, 720x480, 4000 frames
    loop      a RestoreMotionBlocks made, used for one frame and dropped, 4000 times, 1 thread
    loopcrop  the same with std.Crop (control)
    fe        a new RestoreMotionBlocks per frame through FrameEval, 8 threads
    fecrop    the same with AddBorders + Crop (control)
"""
import json
import resource
import sys

import vapoursynth as vs

core = vs.core
mode = sys.argv[1]
core.num_threads = 1 if mode.startswith('loop') else 8
c = core.std.BlankClip(width=720, height=480, format=vs.YUV420P8, length=4000, color=[100, 128, 128])
c = core.akarin.Expr([c], ['X N + Y * 37 % 3 * 60 +', '', ''])
rep = core.zsmooth.Repair(core.zsmooth.Clense(c), c, mode=[16])


def rss():
    return round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6, 1)


out = {}
if mode in ('loop', 'loopcrop'):
    for n in range(4000):
        x = core.removedirt.RestoreMotionBlocks(rep, c) if mode == 'loop' else core.std.Crop(rep, 2, 2, 2, 2)
        x.get_frame(n)
        del x
        if n % 1000 == 999:
            out[n + 1] = rss()
else:
    if mode == 'fe':
        node = core.std.FrameEval(rep, lambda n: core.removedirt.RestoreMotionBlocks(rep, c))
    else:
        node = core.std.FrameEval(rep, lambda n: core.std.Crop(core.std.AddBorders(rep, 2, 2, 2, 2), 2, 2, 2, 2))
    for i, _f in enumerate(node.frames(prefetch=16)):
        if i % 1000 == 999:
            out[i + 1] = rss()
print(json.dumps({'mode': mode, 'peak_rss_mb_by_frame': out}))
