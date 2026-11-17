"""RemoveDirt run to run (task #57): how many different results N fresh
graphs give, per stage of the chain and thread count; the template's
remove_dirt() (one RestoreMotionBlocks per frame) against the bare chain; and
the wrapper's speed and memory.

  removedirt.py repeat    -> {graph: {threads: distinct results in RUNS runs}}
  removedirt.py order     -> distinct results with frames requested in shuffled order, 1 thread
  removedirt.py speed     -> fps at 720x480 x 600 frames, bare chain vs remove_dirt, 8 threads
  removedirt.py rss <bare|wrapped> <frames> -> peak RSS (MB) after that many frames at 720x480
                            (a per-frame instance leaked: it grew with the length)
"""
import hashlib
import json
import random
import resource
import sys
import time

import vapoursynth as vs

from common import clip
import removedirt

core = vs.core
RUNS = 20
GATE = dict(gmthreshold=70, noise=50, noisy=12, dist=1, tolerance=12, dmode=2, pthreshold=4, cthreshold=4)


def graph(name, c):
    cl = core.zsmooth.Clense(c)
    if name == 'clense':
        return cl
    sel = core.removedirt.SCSelect(c, core.zsmooth.ForwardClense(c), core.zsmooth.BackwardClense(c), cl)
    if name == 'scselect':
        return sel
    if name == 'restore_motion_blocks':
        return core.removedirt.RestoreMotionBlocks(core.zsmooth.Repair(cl, c, mode=[16]), c, **GATE)
    if name == 'bare_chain':
        return core.removedirt.RestoreMotionBlocks(core.zsmooth.Repair(sel, c, mode=[16]), c, **GATE)
    if name == 'remove_dirt':
        return removedirt.remove_dirt(c)
    raise ValueError(name)


def digest(c, order=None):
    m = hashlib.md5()
    frames = [c.get_frame(n) for n in order] if order else list(c.frames(prefetch=16))
    if order:
        frames = [f for _, f in sorted(zip(order, frames))]
    for f in frames:
        for p in range(f.format.num_planes):
            m.update(bytes(f[p]))
    return m.hexdigest()


def src(w=352, h=240, frames=24):
    """The capture (79 frames), repeated end to end for a longer clip."""
    base = clip('420', 8, 0, w, h, frames=min(frames, 79))
    return (base * -(-frames // base.num_frames))[:frames]


mode = sys.argv[1]
if mode == 'repeat':
    out = {}
    single = {}
    for name in ('clense', 'scselect', 'restore_motion_blocks', 'bare_chain', 'remove_dirt'):
        for threads in (8, 2, 1):
            core.num_threads = threads
            hs = [digest(graph(name, src())) for _ in range(RUNS)]
            out.setdefault(name, {})[threads] = len(set(hs))
            if threads == 1:
                single[name] = hs[0]
            print(name, threads, len(set(hs)), flush=True)
    core.num_threads = 8
    out['remove_dirt equals the bare chain at 1 thread'] = single['remove_dirt'] == single['bare_chain']
    print(json.dumps({'runs': RUNS, 'frames': 24, 'distinct': out}))
elif mode == 'order':
    core.num_threads = 1
    out = {}
    for name in ('scselect', 'restore_motion_blocks', 'bare_chain'):
        hs = set()
        for r in range(12):
            order = list(range(24))
            random.Random(r).shuffle(order)
            hs.add(digest(graph(name, src()), order if r else None))
        out[name] = len(hs)
    print(json.dumps(out))
elif mode == 'speed':
    core.num_threads = 8
    out = {}
    for name in ('bare_chain', 'remove_dirt'):
        fps = []
        for _ in range(3):
            c = graph(name, src(720, 480, 600))
            t = time.time()
            for _f in c.frames(prefetch=16):
                pass
            fps.append(round(600 / (time.time() - t), 1))
        out[name] = fps
        print(name, fps, flush=True)
    print(json.dumps(out))
elif mode == 'rss':
    core.num_threads = 8
    c = graph('bare_chain' if sys.argv[2] == 'bare' else 'remove_dirt', src(720, 480, int(sys.argv[3])))
    for _f in c.frames(prefetch=16):
        pass
    print(json.dumps({'graph': sys.argv[2], 'frames': int(sys.argv[3]), 'peak_rss_mb': round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6, 1)}))
