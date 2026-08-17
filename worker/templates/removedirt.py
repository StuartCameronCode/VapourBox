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
or 4:4:4 with bit depths 8-16!". Both 9-bit and 4:1:1 are reachable here —
``pixel_format.rs`` rounds odd depths up through 9, and 4:1:1 is NTSC DV — so
both are guarded below.

Its ``noise``/``noisy`` thresholds are normalised internally: the same values at
8/10/12/16-bit produced bit-identical output (mean |diff| 0.0000), so unlike
most of this codebase they must NOT be depth-scaled.
"""

import vapoursynth as vs

core = vs.core


def _restore_format(clip, target_id):
    return clip if clip.format.id == target_id else core.resize.Bicubic(
        clip, format=target_id
    )


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

    src_id = clip.format.id
    bits = clip.format.bits_per_sample

    # 9-bit and 4:1:1 are both reachable and both rejected by the plugin.
    needs_depth_fix = bits == 9
    needs_subsampling_fix = (
        clip.format.color_family == vs.YUV and clip.format.subsampling_w == 2
    )
    if needs_depth_fix or needs_subsampling_fix:
        target_bits = 10 if needs_depth_fix else bits
        if clip.format.color_family == vs.GRAY:
            work_format = core.get_video_format(vs.GRAY8).replace(
                bits_per_sample=target_bits,
                sample_type=vs.INTEGER,
            )
        else:
            work_format = core.get_video_format(vs.YUV422P8).replace(
                bits_per_sample=target_bits,
                sample_type=vs.INTEGER,
            )
        clip = core.resize.Bicubic(clip, format=work_format.id)

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
    out = core.removedirt.RestoreMotionBlocks(
        repaired, clip,
        gmthreshold=gmthreshold,
        noise=noise,
        noisy=noisy,
        dist=dist,
        tolerance=tolerance,
        dmode=dmode,
        pthreshold=pthreshold,
        cthreshold=cthreshold,
    )

    if post_denoise:
        out = core.zsmooth.RemoveGrain(out, mode=[17])

    return _restore_format(out, src_id)
