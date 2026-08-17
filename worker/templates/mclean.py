"""
mClean - spatio/temporal denoiser with optional sharpening, renoise and warp depth.

+++ Provenance +++

Vendored from Selur's VapoursynthScriptsInHybrid
(https://github.com/Selur/VapoursynthScriptsInHybrid), file ``denoise.py``,
approximately lines 535-735 of the 2026-08-17 master snapshot. That repository
carries **no LICENSE file and no per-file licence headers**; nothing here
invents one. The attribution the upstream docstring itself carries is:

    From: https://forum.doom9.org/showthread.php?t=174804 by burfadel

The MVTools substrate and the helpers this needs (``MV``, ``BoxFilter``,
``Blur``, ``scale``) live in ``hybrid_mv.py``, shared with
``temporaldegrain2.py``; that file documents its own derivation.

+++ Deviations from upstream, all of them load-bearing +++

Each was measured against the plugins VapourBox actually bundles.

1. **Deband is routed to neo_f3kdb and capped at 1.** Upstream calls
   ``filt.f3kdb.Deband(...)``; this bundle ships **neo_f3kdb** under a
   different namespace, so ``deband=1`` raised
   ``AttributeError: no attribute named f3kdb``. Since this is our own copy the
   call is simply repointed. ``deband=2`` additionally reaches
   ``core.vcm.Veed``, which is bundled on no platform and is not guarded
   upstream, so anything above 1 is folded down to 1. neo_f3kdb also renames
   ``range`` to ``range`` (unchanged) but drops the ``preset`` string, so the
   preset is expanded into its ``y``/``cb``/``cr``/``grainy``/``grainc``
   equivalents here.

2. **icalc is pinned True.** ``icalc=False`` selects the float path, which
   needs ``core.mvsf``; that plugin is not bundled, and the failure surfaces
   deep inside the graph.

3. **outbits is pinned to the source depth.** Upstream lets it silently change
   the output pixel format (``outbits=16`` on an 8-bit source returned
   YUV420P16), which the chroma-subsampling block downstream of this filter
   does not expect. The parameter is kept in the signature for call-site
   compatibility and ignored with a note.

4. **The depth-dependent renoise thresholds are scaled from ``clip.format``**
   via upstream's ``i`` multiplier, which is retained. Everything else in the
   function is a ratio.

5. Every ``std.Expr`` goes through ``hybrid_mv._expr`` (akarin's LLVM JIT where
   available). Upstream's ``color.Tweak`` dependency is reduced to the
   contrast-only integer path it actually uses (``_tweak_contrast``), which is
   a ``std.Lut`` and involves no expression at all.

6. The correctly-guarded ``hasattr(core, 'zsmooth')`` around
   ``core.vcm.Median`` is kept as upstream wrote it - zsmooth is bundled, so
   the vcm branch never fires, but the guard is right and costs nothing.

7. **``depth`` is deliberately not exposed.** The template never passes it, so
   it always runs at 0. Above 0 the function takes the difference of two
   ``AWarpSharp2`` warps, and ``thresh`` is hard-capped at 255 by the plugin,
   so it cannot be depth-scaled the way everything else here is: at
   ``depth=2`` the 8-bit and 16-bit results diverge by **3.09/255** mean
   absolute difference, against a ~0.6 rounding floor, because quantisation
   noise flips the warp's edge decisions. That is inherent to the operation
   rather than a scaling bug, so exposing the knob means accepting output that
   changes with the source's bit depth. Don't add it to the schema without
   deciding that is acceptable.
"""

from typing import Optional

import vapoursynth as vs

from hybrid_mv import MV, Blur, BoxFilter, _expr, require_integer

core = vs.core

__all__ = ['mClean']


def _tweak_contrast(clip: vs.VideoNode, cont: float) -> vs.VideoNode:
    """The one thing mClean uses color.Tweak for: luma contrast on an integer clip.

    Reproduces Tweak(cont=...) with coring=True exactly - a per-level LUT over
    the luma plane, clamped to the 16..235 range scaled to the clip's depth.
    """
    bits = clip.format.bits_per_sample
    luma_min = 16 << (bits - 8)
    luma_max = 235 << (bits - 8)
    lut = [min(max(int((i - luma_min) * cont + luma_min + 0.5), luma_min), luma_max)
           for i in range(1 << bits)]
    return clip.std.Lut(planes=0, lut=lut)


def mClean(
    clip: vs.VideoNode,
    thSAD: int = 400,
    chroma: bool = True,
    sharp: float = 10,
    rn: float = 14,
    deband: int = 0,
    depth: int = 0,
    strength: int = 20,
    outbits: Optional[int] = None,
    icalc: bool = True,
    rgmode: int = 18,
) -> vs.VideoNode:
    """Spatio/temporal denoiser that keeps detail, with optional enhancement.

    Typical spatial filters remove small-scale variation, which loses noise but
    also sharpness and temporal stability. mClean works primarily in the
    temporal domain with only light spatial limiting, and treats chroma
    differently from luma.

      thSAD (400)    MDegrain SAD threshold - the main denoising strength knob.
      chroma (True)  Denoise chroma as well as luma.
      sharp (10)     0-24 modified unsharp mask on edges and detected detail.
                     21-24 are "overboost", only sane on clean HD sources.
                     The actual amount is scaled by resolution.
      rn (14)        0-20 ReNoise: adds back a spatially and temporally
                     modified version of the removed luma noise, which
                     compresses far better than the original and avoids the
                     flatness effective denoising leaves behind.
      deband (0)     0 = off, 1 = deband (neo_f3kdb). Values above 1 are
                     clamped - see the module docstring.
      depth (0)      0-5 modified warp sharpening; distorts the image, but 1-2
                     can help line art.
      strength (20)  0-20. Below 20 the result is blended back toward the
                     source: 0 keeps 20% of the denoising, 20 keeps all of it.
      rgmode (18)    RemoveGrain mode for the spatial luma pass.

    ``outbits`` and ``icalc`` are accepted for call-site compatibility and
    pinned; see the module docstring.
    """
    if not isinstance(clip, vs.VideoNode) or clip.format.color_family != vs.YUV:
        raise vs.Error('mClean: this is not a YUV clip!')

    # Deviation 2: the float path needs core.mvsf, which is not bundled.
    require_integer(clip, 'mClean')
    icalc = True

    defH = max(clip.height, clip.width // 4 * 3)  # for the auto blksize settings
    sharp = min(max(sharp, 0), 24)
    rn = min(max(rn, 0), 20)
    # Deviation 1: deband 2..5 reach core.vcm.Veed, which is bundled nowhere.
    deband = min(max(int(deband), 0), 1)
    depth = min(max(int(depth), 0), 5)
    strength = min(max(strength, 0), 20)

    bd = clip.format.bits_per_sample
    zsmooth = hasattr(core, 'zsmooth')

    S = MV.Super
    A = MV.Analyse
    R = MV.Recalculate

    # Deviation 3: the output format must track the source.
    outbits = bd

    if zsmooth:
        RE = core.zsmooth.Repair
        RG = core.zsmooth.RemoveGrain
    else:
        RE = core.rgvs.Repair
        RG = core.rgvs.RemoveGrain

    sc = 8 if defH > 2880 else 4 if defH > 1440 else 2 if defH > 720 else 1
    i = 1 << (outbits - 8)          # 8-bit level -> this clip's range
    peak = (1 << outbits) - 1
    bs = 16 if defH / sc > 360 else 8
    ov = 6 if bs > 12 else 2
    pel = 1 if defH > 720 else 2
    truemotion = False if defH > 720 else True
    lampa = 777 * (bs ** 2) // 64
    depth2 = -depth * 3
    depth = depth * 2

    if sharp > 20:
        sharp += 30
    elif defH <= 2500:
        sharp = 15 + defH * sharp * 0.0007
    else:
        sharp = 50

    # ------------------------------------------------------------- preparation
    if chroma:
        c = core.zsmooth.Median(clip, radius=2, planes=[1, 2]) if zsmooth \
            else core.vcm.Median(clip, plane=[0, 1, 1])
    else:
        c = clip

    cy = core.std.ShufflePlanes(c, [0], vs.GRAY)

    super1 = S(c if chroma else cy, hpad=bs, vpad=bs, pel=pel, rfilter=4, sharp=1,
               blksize=bs, overlap=ov)
    super2 = S(c if chroma else cy, hpad=bs, vpad=bs, pel=pel, rfilter=1, levels=1,
               blksize=bs, overlap=ov)
    analyse_args = dict(blksize=bs, overlap=ov, search=5, truemotion=truemotion)
    recalculate_args = dict(blksize=bs, overlap=ov, search=5, truemotion=truemotion,
                            thsad=180, lambda_=lampa)

    # ---------------------------------------------------------------- analysis
    bvec3 = R(super1, A(super1, isb=True, delta=3, **analyse_args), **recalculate_args)
    bvec2 = R(super1, A(super1, isb=True, delta=2, badsad=1100, lsad=1120, **analyse_args),
              **recalculate_args)
    bvec1 = R(super1, A(super1, isb=True, delta=1, badsad=1500, lsad=980, badrange=27,
                        **analyse_args), **recalculate_args)
    fvec1 = R(super1, A(super1, isb=False, delta=1, badsad=1500, lsad=980, badrange=27,
                        **analyse_args), **recalculate_args)
    fvec2 = R(super1, A(super1, isb=False, delta=2, badsad=1100, lsad=1120, **analyse_args),
              **recalculate_args)
    fvec3 = R(super1, A(super1, isb=False, delta=3, **analyse_args), **recalculate_args)

    # mvtools' `limit` is expressed in the clip's own range and defaults to 255,
    # which is a hard clamp at anything above 8-bit; "off" is the format peak.
    clean = MV.Degrain3(c if chroma else cy, super2, bvec1, fvec1, bvec2, fvec2, bvec3, fvec3,
                        thsad=thSAD, limit=peak)

    TM = core.zsmooth.TemporalMedian if zsmooth else core.tmedian.TemporalMedian
    uv = core.std.MergeDiff(clean, TM(core.std.MakeDiff(c, clean, [1, 2]), 1, [1, 2]), [1, 2]) \
        if chroma else c
    clean = core.std.ShufflePlanes(clean, [0], vs.GRAY) if clean.format.num_planes != 1 else clean

    # ------------------------------------------------- post clean / pre deband
    filt = core.std.ShufflePlanes([clean, uv], [0, 1, 2], vs.YUV)

    if deband:
        # Deviation 1: neo_f3kdb has no `preset`, so upstream's "high"/"luma" is
        # expanded. "high" = y/cb/cr 48; "luma" = y 48, chroma off.
        filt = core.neo_f3kdb.Deband(filt, range=16,
                                     y=48, cb=48 if chroma else 0, cr=48 if chroma else 0,
                                     grainy=int(defH / 15), grainc=int(defH / 16) if chroma else 0,
                                     output_depth=outbits)
        clean = core.std.ShufflePlanes(filt, [0], vs.GRAY)

    # ------------------------------------------------------ spatial luma denoise
    clean2 = RG(clean, rgmode)

    # Unsharp filter for spatial detail enhancement
    clsharp = None
    if sharp:
        if sharp <= 50:
            clsharp = core.std.MakeDiff(clean, Blur(clean2, amountH=0.08 + 0.03 * sharp))
        elif hasattr(core, 'tcanny'):
            clsharp = core.std.MakeDiff(clean, clean2.tcanny.TCanny(sigma=(sharp - 46) / 4, mode=-1))
        else:
            radius = max(1, round(((sharp - 46) / 4) * 1.5))
            blur = clean2
            for _ in range(3):
                blur = BoxFilter(blur, radius=radius, radius_v=radius)
            clsharp = core.std.MakeDiff(clean, blur)
        clsharp = core.std.MergeDiff(clean2, RE(TM(clsharp), clsharp, 12))

    # ------------------------------------------------------------------ renoise
    noise_diff = core.std.MakeDiff(clean2, cy)
    if rn:
        # Thresholds are 8-bit levels; `i` takes them to the clip's own range.
        expr = 'x {a} < 0 x {b} > {p} 0 x {c} - {p} {a} {d} - / * - ? ?'.format(
            a=32 * i, b=45 * i, c=35 * i, d=65 * i, p=peak)
        clean1 = core.std.Merge(
            clean2,
            core.std.MergeDiff(clean2, _tweak_contrast(TM(noise_diff), 1.008 + 0.00016 * rn)),
            0.3 + rn * 0.035)
        clean2 = core.std.MaskedMerge(
            clean2, clean1,
            _expr([_expr([clean, clean.std.Invert()], 'x y min')], [expr]))

    # Combine spatial detail enhancement with spatial noise reduction
    noise_diff = noise_diff.std.Binarize().std.Invert()
    clean2 = core.std.MaskedMerge(clean2, clsharp if sharp else clean,
                                  _expr([noise_diff, clean.std.Sobel()], 'x y max'))

    # ------------------------------------------------- recombine luma and chroma
    output = core.std.ShufflePlanes([clean2, filt], [0, 1, 2], vs.YUV)
    if strength < 20:
        output = core.std.Merge(c, output, 0.2 + 0.04 * strength)

    if depth:
        # warp.AWarpSharp2's `chroma` is 0 or 1 in the VapourSynth port (the
        # Avisynth filter's 0-6 vocabulary is rejected at script evaluation).
        s1 = output.warp.AWarpSharp2(thresh=128, blur=3, type=1, depth=depth2, chroma=1)
        s2 = output.warp.AWarpSharp2(thresh=128, blur=2, type=1, depth=depth, chroma=1)
        return core.std.MergeDiff(output, core.std.MakeDiff(s1, s2))
    return output
