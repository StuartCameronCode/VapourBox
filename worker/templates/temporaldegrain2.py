"""
TemporalDegrain2 - motion-compensated temporal degrainer.

+++ Provenance +++

Vendored from Selur's VapoursynthScriptsInHybrid
(https://github.com/Selur/VapoursynthScriptsInHybrid), file ``degrain.py``,
approximately lines 402-736 of the 2026-08-17 master snapshot. That repository
carries **no LICENSE file and no per-file licence headers**; nothing here
invents one. The attribution the upstream docstring itself carries is:

    Temporal Degrain Updated by ErazorTT
    Based on function by Sagekilla, idea + original script created by Didee

The shared MVTools substrate and the helpers it needs (``m4``,
``DitherLumaRebuild``, ``MinBlur``, ``ContraSharpening``, ``Padding``,
``DFTTest``) live in ``hybrid_mv.py``, which documents its own derivation.
``color.LimitFilter`` is imported at module scope upstream and never called, so
it is not vendored.

+++ Deviations from upstream, all of them load-bearing +++

Each was measured against the plugins VapourBox actually bundles.

1. **postFFT is clamped to 0-3.** ``postFFT=5`` does not raise, it *aborts the
   process*: ``postBlkSize = [0,48,32,12,0,0][postFFT]`` yields 0, FFT3DFilter
   is handed a 0x0 block, and the run ends in "dimensions are negative (0x1)"
   followed by ``libc++abi: terminating``. ``postFFT=4`` needs KNLMeansCL and a
   working OpenCL device, which is not something this bundle can rely on. Both
   are folded down rather than allowed to reach the plugin.

2. **grainLevel is clamped to -2..3.** Every autotune table is length 6 and the
   value is shifted by +2 before indexing, so anything outside that window is a
   bare ``IndexError`` from inside the function.

3. **extraSharp works at 16-bit.** ``extraSharp=True`` sets ``MinBlur``'s
   radius to 3, whose 16-bit branch upstream calls ``depth(...)`` and
   ``Dither.NONE`` without importing either - a ``NameError`` at exactly
   16 bits, and only when ``core.ctmf`` exists, which here it always does.
   Fixed in ``hybrid_mv._min_blur_median``.

4. **The depth-dependent limits are scaled from ``clip.format``.** This is the
   one that decides whether the filter is usable at all above 8 bits:

   * ``limitSigma`` (and the derived sigma2/3/4) feeds FFT3DFilter, whose sigma
     is in the clip's own sample range. Measured on identical 8- and 16-bit
     content, an unscaled sigma diverges by **2.85/255**; scaled by
     ``1 << (bits - 8)`` it is **0.45**.
   * mvtools' ``limit`` is likewise in the clip's own range, and the wrapper's
     "off" value of 255 means "clamp every pixel to 255/65535" at 16-bit.
     Measured against the same degrain at 8-bit: ``limit=255`` diverges by
     **0.77/255** and discards roughly half the degraining; at the format peak
     it is **0.22**. That is what made ``outputStage=0`` a complete no-op at
     >=12-bit.

   ``postSigma`` is scaled the same way for ``postFFT`` 1 and 2 (FFT3DFilter);
   it is deliberately **not** scaled for ``postFFT=3``, because dfttest's sigma
   was measured to be bit-depth independent (8-vs-16-bit divergence 0.0017).

5. **Float input is rejected up front.** It fails at ``Super`` because
   ``core.mvsf`` is not bundled; the native error names a clip several layers
   down and reads like a corrupt graph.

6. Every ``std.Expr`` goes through ``hybrid_mv._expr`` (akarin's LLVM JIT where
   available). Unreachable backends - ``neo_fft3d``, ``cranexpr``, ``rgsf``,
   ``mvsf``, ``nlm_cuda``, ``knlm`` via KNLMeansCL - are removed rather than
   left behind ``hasattr`` guards that can never fire. bm3d is never reached by
   this function (the only upstream mention is a TODO comment), so it needs no
   deps addition.
"""

from typing import Optional

import vapoursynth as vs

from hybrid_mv import (
    MV,
    ContraSharpening,
    DFTTest,
    DitherLumaRebuild,
    _expr,
    m4,
    require_integer,
)

core = vs.core

__all__ = ['TemporalDegrain2']


def TemporalDegrain2(
    clip: vs.VideoNode,
    degrainTR: int = 1,
    degrainPlane: int = 4,
    grainLevel: int = 2,
    grainLevelSetup: bool = False,
    meAlg: int = 4,
    meAlgPar: Optional[int] = None,
    meSubpel: Optional[int] = None,
    meBlksz: Optional[int] = None,
    meTM: bool = False,
    limitSigma: Optional[float] = None,
    limitBlksz: Optional[int] = None,
    fftThreads: Optional[int] = None,
    postFFT: int = 0,
    postTR: int = 1,
    postSigma: float = 1,
    postMix: int = 0,
    postBlkSize: Optional[int] = None,
    ppSAD1: Optional[float] = None,
    ppSAD2: Optional[float] = None,
    ppSCD1: Optional[float] = None,
    thSCD2: int = 128,
    DCT: int = 0,
    SubPelInterp: int = 2,
    SrchClipPP: Optional[int] = None,
    GlobalMotion: bool = True,
    ChromaMotion: bool = True,
    rec: bool = False,
    extraSharp: bool = False,
    outputStage: int = 2,
) -> vs.VideoNode:
    """Remove most or all grain and noise, including dancing grain.

    The knobs worth exposing, in the order they matter:

      degrainTR (1)     Temporal radius of the degrain. Useful range 1 .. fps/8.
                        Higher cleans more but mis-identified motion vectors
                        start washing regions out.
      grainLevel (2)    -2 .. 3. How noisy the source is. Drop to 0/1 for clean
                        material, raise to 3 for very heavy grain. Drives every
                        autotuned SAD/scene-change threshold.
      postFFT (0)       Extra spatial pass over the degrained clip.
                        0 = RemoveGrain(1), 1/2 = FFT3DFilter, 3 = DFTTest
                        (slower, best on banding). 4 and 5 are folded to 3 -
                        see the module docstring.
      postSigma (1)     Strength of that pass. Raising it too far bands.
      postTR (1)        Temporal radius of the post pass.
      postMix (0)       0-100. Blends the original back in when the result is
                        too clean.
      degrainPlane (4)  0=Y 1=U 2=V 3=UV 4=YUV.
      ChromaMotion      Use chroma in the motion search.
      rec (False)       Refine vectors with Recalculate: better motion, slower.
      outputStage (2)   0 = first (limited) degrain, 1 = second, 2 = + post
                        pass and contra-sharpening. Lower means less filtering.
      extraSharp        Wider radius in the contra-sharpening step.
    """
    if not isinstance(clip, vs.VideoNode) or clip.format.color_family not in (vs.GRAY, vs.YUV):
        raise vs.Error('TemporalDegrain2: this is not a GRAY or YUV clip!')

    # Guard 5: float needs core.mvsf, which is not bundled.
    require_integer(clip, 'TemporalDegrain2')

    # --- Guard 1: postFFT 4 (KNLMeansCL/OpenCL) and 5 (0-sized FFT blocks, which
    # abort the process rather than raising) are folded onto the DFTTest path.
    postFFT = int(postFFT)
    if postFFT > 3:
        postFFT = 3
    elif postFFT < 0:
        postFFT = 0

    # --- Guard 2: the autotune tables are length 6 and indexed by grainLevel + 2.
    grainLevel = max(-2, min(3, int(grainLevel)))

    outputStage = max(0, min(2, int(outputStage)))
    degrainTR = max(0, int(degrainTR))
    postTR = max(0, int(postTR))
    postMix = max(0, min(100, int(postMix)))

    w = clip.width
    h = clip.height
    bd = clip.format.bits_per_sample
    isGRAY = clip.format.color_family == vs.GRAY

    # 8-bit level -> this clip's range. Upstream calls this `i`.
    bitDepthMultiplier = 1 << (bd - 8)
    mid = 1 << (bd - 1)
    peak = (1 << bd) - 1

    S = MV.Super
    C = MV.Compensate

    RG = core.zsmooth.RemoveGrain if hasattr(core, 'zsmooth') else core.rgvs.RemoveGrain

    if meAlgPar is None:
        # Dogway's SMDegrain values; the AVS table was based on a misreading of
        # the MVTools search algorithm.
        meAlgPar = 5 if rec and meTM else 2

    longlat = max(w, h)
    shortlat = min(w, h)
    # Scale grainLevel from -2..3 -> 0..5 for table lookup.
    grainLevel = grainLevel + 2

    if longlat <= 1050 and shortlat <= 576:
        autoTune = 0
    elif longlat <= 1280 and shortlat <= 720:
        autoTune = 1
    elif longlat <= 2048 and shortlat <= 1152:
        autoTune = 2
    else:
        autoTune = 3

    if meSubpel is None:
        meSubpel = [4, 2, 2, 1][autoTune]
    if meBlksz is None:
        meBlksz = [8, 8, 16, 32][autoTune]

    limitAT = [-1, -1, 0, 0, 0, 1][grainLevel] + autoTune + 1

    if limitSigma is None:
        limitSigma = [6, 8, 12, 16, 32, 48][limitAT]
    if limitBlksz is None:
        limitBlksz = [12, 16, 24, 32, 64, 96][limitAT]
    if SrchClipPP is None:
        SrchClipPP = [0, 0, 0, 3, 3, 3][grainLevel]

    if isGRAY:
        ChromaMotion = False
        degrainPlane = 0

    if degrainPlane == 0:
        fPlane = [0]
    elif degrainPlane == 1:
        fPlane = [1]
    elif degrainPlane == 2:
        fPlane = [2]
    elif degrainPlane == 3:
        fPlane = [1, 2]
    else:
        fPlane = [0, 1, 2]

    if postFFT <= 0:
        postTR = 0
    if postFFT == 3:
        postTR = min(postTR, 7)
    if postFFT in (1, 2):
        postTR = min(postTR, 2)

    if postBlkSize is None:
        postBlkSize = [0, 48, 32, 12][postFFT]

    if grainLevelSetup:
        outputStage = 0
        degrainTR = 3

    rad = 3 if extraSharp else None
    mat = [1, 2, 1, 2, 4, 2, 1, 2, 1]
    hpad = meBlksz
    vpad = meBlksz
    postTD = postTR * 2 + 1
    maxTR = max(degrainTR, postTR)
    Overlap = int(meBlksz // 2)
    Lambda = (1000 if meTM else 100) * (meBlksz ** 2) // 64
    PNew = 50 if meTM else 25

    ppSAD1 = ppSAD1 if ppSAD1 is not None else [3, 5, 7, 9, 11, 13][grainLevel]
    ppSAD2 = ppSAD2 if ppSAD2 is not None else [2, 4, 5, 6, 7, 8][grainLevel]
    ppSCD1 = ppSCD1 if ppSCD1 is not None else [3, 3, 3, 4, 5, 6][grainLevel]

    if DCT == 5:
        # Rescale the thresholds to match SAD values when using SATD. ppSCD1 is
        # deliberately left alone: scene change detection is always SAD-based.
        ppSAD1 *= 1.7
        ppSAD2 *= 1.7

    # Per-pixel measures -> the per-8x8-block (64 px) measure MVTools uses.
    thSAD1 = int(ppSAD1 * 64)
    thSAD2 = int(ppSAD2 * 64)
    thSCD1 = int(ppSCD1 * 64)
    CMplanes = [0, 1, 2] if ChromaMotion else [0]

    if maxTR > 3:
        # Upstream allows up to 6 for float clips via mvsf, which is not bundled.
        raise vs.Error('TemporalDegrain2: degrainTR/postTR above 3 needs the mvsf plugin, '
                       'which is not bundled.')

    # --- Guard 4a: FFT3DFilter's sigma is in the clip's own range.
    sigmaScale = float(bitDepthMultiplier)
    # --- Guard 4b: so is mvtools' `limit`; the wrapper's "off" value of 255 is
    # a hard clamp at anything above 8-bit, so express "off" as the format peak.
    degrainLimit = peak

    # ---------------------------------------------------------------- search clip
    if SrchClipPP == 1:
        spatialBlur = core.resize.Bilinear(clip, m4(w / 2), m4(h / 2)) \
            .std.Convolution(matrix=mat, planes=CMplanes) \
            .resize.Bilinear(w, h)
    elif SrchClipPP > 1:
        if hasattr(core, 'tcanny'):
            spatialBlur = core.tcanny.TCanny(clip, sigma=2, mode=-1, planes=CMplanes)
        else:
            spatialBlur = core.std.BoxBlur(clip, planes=CMplanes, hradius=2, hpasses=3,
                                           vradius=2, vpasses=3)
        spatialBlur = core.std.Merge(spatialBlur, clip,
                                     [0.1] if (ChromaMotion or isGRAY) else [0.1, 0])
    else:
        spatialBlur = clip

    if SrchClipPP < 3:
        srchClip = spatialBlur
    else:
        expr = 'x {a} + y < x {b} + x {a} - y > x {b} - x y + 2 / ? ?'.format(
            a=7 * bitDepthMultiplier, b=2 * bitDepthMultiplier)
        srchClip = _expr([spatialBlur, clip],
                         [expr] if (ChromaMotion or isGRAY) else [expr, ''])

    super_args = dict(pel=meSubpel, hpad=hpad, vpad=vpad, sharp=SubPelInterp,
                      chroma=ChromaMotion, blksize=meBlksz, overlap=Overlap)
    analyse_args = dict(blksize=meBlksz, overlap=Overlap, search=meAlg, searchparam=meAlgPar,
                        pelsearch=meSubpel, truemotion=meTM, lambda_=Lambda, pnew=PNew,
                        global_=GlobalMotion, dct=DCT, chroma=ChromaMotion)
    recalculate_args = dict(thsad=thSAD1 // 2, blksize=max(meBlksz // 2, 4),
                            overlap=max(Overlap // 2, 2), search=meAlg, searchparam=meAlgPar,
                            truemotion=meTM, lambda_=Lambda // 4, pnew=PNew, dct=DCT,
                            chroma=ChromaMotion)

    lumaRebuild = DitherLumaRebuild(srchClip, s0=1, chroma=ChromaMotion)

    srchSuper = S(lumaRebuild, rfilter=4, **super_args)
    recSuper = S(lumaRebuild, levels=1, **super_args)

    # One shared vector list [bv1, fv1, bv2, fv2, ...] covers both the degrain
    # stages (first degrainTR pairs) and the post-filter compensation window.
    degrainVecs = []
    postVecs = []
    if maxTR > 0:
        vecs = MV.AnalyseMany(srchSuper, radius=maxTR, **analyse_args)
        if rec:
            vecs = MV.Recalculate(recSuper, vecs, **recalculate_args)
        degrainVecs = vecs[:2 * degrainTR]
        postVecs = vecs[:2 * postTR]

    # ------------------------------------------------------------------- degrain
    # "spat" is a prefiltered clip used to limit the effect of the 1st MV stage.
    if degrainTR > 0:
        s1 = limitSigma * sigmaScale
        s2 = s1 * 0.625
        s3 = s1 * 0.375
        s4 = s1 * 0.250
        ovNum = [4, 4, 4, 3, 2, 2][grainLevel]
        ov = 2 * round(limitBlksz / ovNum * 0.5)

        spat = core.fft3dfilter.FFT3DFilter(
            clip, planes=fPlane, sigma=s1, sigma2=s2, sigma3=s3, sigma4=s4, bt=3,
            bw=limitBlksz, bh=limitBlksz, ow=ov, oh=ov, ncpu=fftThreads)
        spatD = core.std.MakeDiff(clip, spat)

    # Every other Super only needs the finest level.
    super_args = dict(super_args)
    super_args['levels'] = 1

    # First MV-denoising stage.
    if degrainTR > 0:
        supero = S(clip, **super_args)
        NR1 = MV.Degrain(clip, supero, *degrainVecs, plane=degrainPlane, thsad=thSAD1,
                         limit=degrainLimit, thscd1=thSCD1, thscd2=thSCD2)

        # Limit NR1 to not do more than what "spat" would do.
        NR1D = core.std.MakeDiff(clip, NR1)
        expr = 'x {m} - abs y {m} - abs < x y ?'.format(m=mid)
        DD = _expr([spatD, NR1D], [expr])
        NR1x = core.std.MakeDiff(clip, DD, [0])
    else:
        NR1x = clip

    # Second MV-denoising stage.
    if degrainTR > 0:
        NR1x_super = S(NR1x, **super_args)
        NR2 = MV.Degrain(NR1x, NR1x_super, *degrainVecs, plane=degrainPlane, thsad=thSAD2,
                         limit=degrainLimit, thscd1=thSCD1, thscd2=thSCD2)
    else:
        NR2 = clip

    if outputStage == 0:
        return NR1x
    if outputStage == 1:
        return NR2

    # ------------------------------------------------------------------ post FFT
    if postTR > 0:
        fullSuper = S(NR2, **super_args)
        # postVecs is [bv1, fv1, ...]; interleave farthest-forward .. NR2 ..
        # nearest .. farthest-backward.
        fwdComp = [C(NR2, fullSuper, postVecs[2 * (d - 1) + 1], thsad=thSAD2,
                     thscd1=thSCD1, thscd2=thSCD2) for d in range(postTR, 0, -1)]
        bwdComp = [C(NR2, fullSuper, postVecs[2 * (d - 1)], thsad=thSAD2,
                     thscd1=thSCD1, thscd2=thSCD2) for d in range(1, postTR + 1)]
        noiseWindow = core.std.Interleave(fwdComp + [NR2] + bwdComp)
    else:
        noiseWindow = NR2

    if postFFT == 3:
        # dfttest's sigma is bit-depth independent (measured), so it is NOT scaled.
        dnWindow = DFTTest(noiseWindow, sigma=postSigma * 4, tbsize=postTD, planes=fPlane,
                           sbsize=postBlkSize, sosize=int(postBlkSize * 9 / 12))
    elif postFFT > 0:
        dnWindow = core.fft3dfilter.FFT3DFilter(
            noiseWindow, sigma=postSigma * sigmaScale, planes=fPlane, bt=postTD,
            ncpu=fftThreads, bw=postBlkSize, bh=postBlkSize)
    else:
        dnWindow = RG(noiseWindow, mode=1)

    if postTR > 0:
        dnWindow = dnWindow[postTR::postTD]

    sharpened = ContraSharpening(dnWindow, clip, rad)

    if postMix > 0:
        sharpened = _expr([clip, sharpened],
                          'x {} * y {} * + 100 /'.format(postMix, 100 - postMix))

    return sharpened
