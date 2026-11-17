"""
RemoveDirt — fast dirt and dropout removal.

+++ Why this exists alongside SpotLess +++

Not because it is better. Measured against the shipped ``spotless.py`` on 80
frames of real 640x360 luma with 15 synthetic single-frame spots per frame:

    filter              spot MAE    clean MAE    fps
    SpotLess                9.21        0.222    143
    RemoveDirt (this)      16.9         0.278    908
    RemoveDirtMC            9.99        0.222    202

So the MC variant is *not additive* — it lands on the same point as SpotLess and
runs slower — and is deliberately not offered. The plain form is the whole case:
**6.3x the throughput for about 60% of the removal**, which is what makes it
worth having on a long capture where SpotLess would take hours.

+++ Provenance +++

The plugin is ``pinterf/RemoveDirt`` v1.1 (GPL-2.0, "By Rainer Wittmann
<gorw@gmx.de> / Additional work by Ferenc Pinter"). This wrapper reproduces the
canonical RemoveDirt chain — the Clense family, SCSelect, Repair and
RestoreMotionBlocks — and is written for VapourBox rather than copied.

+++ Two deviations, both measured +++

1. **No trailing ``RemoveGrain(mode=17)``.** The canonical script ends with one,
   and it is the single largest source of collateral damage in the chain: on its
   own it takes clean-pixel MAE from 0.19 to 0.70 and touches 29% of pixels.
   Dropping it is worth **3.2x less damage** (0.199 vs 0.630) at identical spot
   removal and 36% more speed. It is exposed as an off-by-default option rather
   than baked in.

2. **The Clense family comes from ``zsmooth``, not ``rgvs``.** ``rgvs.Clense``
   raises "only 8 and 16 bit integer input supported" at 9-14 bit and float;
   zsmooth's equivalents are fine at every depth this app can produce. Same
   filter, wider input range.

+++ Format limits +++

``RestoreMotionBlocks`` accepts 8-16 bit YUV 4:2:0/4:2:2/4:4:4 and GRAY. It
rejects 9-bit, 4:1:1, float and RGB with "Video must be grey, YUV 4:2:0, 4:2:2,
or 4:4:4 with bit depths 8-16!". Neither reaches a pass: ``pixel_format.rs``
decodes 9-bit as 10 (task #31), and the script template converts 4:1:1 to
4:2:2 before the first pass, so this module carries no guard of its own
(task #48; Tests/TestResources/plugin_format_table.json has the cells).

+++ Thread safety (task #57) +++

``RestoreMotionBlocks`` (v1.1) registers itself ``fmParallel``, but all the
frames of one instance go through a single ``RemoveDirt`` object whose block
buffers (``MotionDetection::blockproperties``) and counters each frame writes.
Frames processed at the same time overwrite each other's, so the output
changed from run to run: 28 different results in 30 runs of 24 frames at 8
threads, one at 1 thread, and the same single result with the frames requested
in any order. That is upstream's issue pinterf/RemoveDirt#5 (fix:
``fmParallelRequests``). Until the bundle carries a fixed release, each frame
has an instance to itself while it is processed (``_ExclusiveInstances``): a
frame takes a free instance from a pool, and the instance goes back when its
frame is done, so no two frames share one at the same time and the output is
the single-threaded one, bit for bit. The pool only grows to the number of
frames in flight. **Never make a new instance per frame**: the plugin leaks
each instance it frees (about 0.6 MB at 720x480), so memory grew with the
length of the job (2.5 GB by frame 4000). SCSelect (``fmUnordered``) is not
affected. Remove the pool with the fixed release; its output is the same, so
that is only a speed change
(docs/reports/task-57-height-2-mod-4-and-removedirt).

Its ``noise``/``noisy`` thresholds are normalised internally: the same values at
8/10/12/16-bit produced bit-identical output (mean |diff| 0.0000), so unlike
most of this codebase they must NOT be depth-scaled.
"""

import functools
import threading

import vapoursynth as vs

core = vs.core


class _ExclusiveInstances:
    """A pool of one filter's instances, each used by one frame at a time.

    ``take`` is a FrameEval callback: it hands frame n a free instance (making
    one when none is free) wrapped in a ModifyFrame that returns it to the pool
    once the instance has produced its frame. The wrappers are not cached, so
    every request runs the hand-back."""

    def __init__(self, make):
        self._make = make
        self._lock = threading.Lock()
        self._free = []
        self._nodes = []

    def take(self, n):
        with self._lock:
            if self._free:
                return self._nodes[self._free.pop()]
            i = len(self._nodes)
            node = self._make()
            node = core.std.ModifyFrame(node, node, functools.partial(self._give_back, i))
            core.std.SetVideoCache(node, mode=0)
            self._nodes.append(node)
            return node

    def _give_back(self, i, n, f):
        with self._lock:
            self._free.append(i)
        return f


def remove_dirt(clip, limit=16, gmthreshold=70, noise=50, noisy=12, dist=1,
                dmode=2, tolerance=12, pthreshold=4, cthreshold=4,
                post_denoise=False):
    """Remove dirt, spots and dropouts.

    ``limit`` is a Repair *mode enumeration* (1-24), not a strength — the
    upstream docstring calls it "higher values = more aggressive" and that is
    simply wrong. It is not exposed as a slider anywhere in the UI.

    ``post_denoise`` re-enables the canonical trailing RemoveGrain(17). Off by
    default; see the module docstring for why.
    """
    if clip.format is None or clip.format.color_family not in (vs.YUV, vs.GRAY):
        raise vs.Error('RemoveDirt: only YUV and GRAY clips are supported')

    # The Clense family, from zsmooth so 9-16 bit all work.
    clensed = core.zsmooth.Clense(clip)
    forward = core.zsmooth.ForwardClense(clip)
    backward = core.zsmooth.BackwardClense(clip)

    # SCSelect picks between the three depending on whether this frame sits at
    # a scene boundary — a temporal median across a cut is what produces the
    # smearing these filters are notorious for.
    selected = core.removedirt.SCSelect(clip, forward, backward, clensed)

    # Bound how far any pixel may move from the source before the motion gate
    # even looks at it.
    repaired = core.zsmooth.Repair(selected, clip, mode=[limit])

    # The gate: restore only blocks that look like damage rather than motion.
    #
    # Each frame has a RestoreMotionBlocks to itself (see "Thread safety"
    # above): the plugin is fmParallel but every frame of one instance writes
    # the same block buffers, so frames processed together corrupt each other.
    gate = dict(
        gmthreshold=gmthreshold,
        noise=noise,
        noisy=noisy,
        dist=dist,
        tolerance=tolerance,
        dmode=dmode,
        pthreshold=pthreshold,
        cthreshold=cthreshold,
    )

    pool = _ExclusiveInstances(lambda: core.removedirt.RestoreMotionBlocks(repaired, clip, **gate))
    out = core.std.FrameEval(repaired, pool.take)

    if post_denoise:
        out = core.zsmooth.RemoveGrain(out, mode=[17])

    return out
