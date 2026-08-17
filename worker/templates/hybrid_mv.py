"""
hybrid_mv - shared MVTools substrate and small helpers for the vendored
Selur/Hybrid script filters (temporaldegrain2.py, mclean.py).

+++ Provenance +++

Derived from Selur's VapoursynthScriptsInHybrid
(https://github.com/Selur/VapoursynthScriptsInHybrid), which carries **no
LICENSE file and no per-file licence headers**. Nothing here invents one; the
attributions below are exactly what the upstream docstrings carry.

Vendored from, as of the 2026-08-17 master snapshot:

  misc.py    - ``MotionVectors`` / ``MV`` (approx. lines 740-1355),
               ``MinBlur`` (518-566), ``sbr`` (569-604),
               ``median_blur`` (451-516)
  helpers.py - ``cround``/``m4``/``scale`` (74-84), ``Padding`` (206-216),
               ``DitherLumaRebuild`` (218-236), ``BoxFilter`` (238-383),
               ``DFTTest`` (534-557)
  sharpen.py - ``ContraSharpening`` (795-862)
  denoise.py - ``Blur``/``Sharpen`` (815-909)

+++ Deliberate deviations from upstream +++

1. **mvutensils (``core.mvu``) support is dropped.** Upstream's MotionVectors
   translates every call for a second, differently-spelled backend. VapourBox
   does not bundle mvutensils, so every one of those branches is dead code
   naming a namespace that will never exist here. The wrapper keeps the
   *interface* (so the vendored call sites are unchanged) and only ever calls
   ``core.mv`` / ``core.mvsf``.

2. **Every ``std.Expr`` goes through ``_expr()``**, which prefers akarin's LLVM
   JIT. VapourSynth's own Expr JIT is ``#ifdef VS_TARGET_CPU_X86``, so on ARM a
   plain ``std.Expr`` is a scalar interpreter run once per pixel - the dominant
   cost in a motion-compensated graph. Upstream does this inconsistently (some
   sites route to akarin, ``MinBlur`` and ``ContraSharpening``'s first Expr do
   not); here it is uniform.

3. **``MinBlur``'s radius-3 / 16-bit branch is fixed.** Upstream calls
   ``depth(...)`` and ``Dither.NONE``, neither of which is imported anywhere in
   that module, so ``MinBlur(clp, 3)`` on a 16-bit clip raises
   ``NameError: name 'depth' is not defined`` whenever ``core.ctmf`` exists -
   which it does in this bundle. See ``_min_blur_median``.

4. Unreachable backends are removed: ``cranexpr``, ``rgsf``, ``vszip``,
   ``vszipcu``, ``dfttest2``, ``nlm_cuda``, ``vcm`` are not bundled.
"""

import math
from typing import List, Optional, Sequence, Union

import vapoursynth as vs

core = vs.core


# ---------------------------------------------------------------------------
# Expression routing
# ---------------------------------------------------------------------------
# VapourSynth's std.Expr JIT is wrapped in #ifdef VS_TARGET_CPU_X86, so on ARM
# every expression is walked once per pixel by a scalar interpreter. akarin has
# a real LLVM JIT that works on aarch64. Route every expression through this
# helper rather than calling core.std.Expr directly; the fallback below must
# name core.std.Expr explicitly (calling _expr again would recurse forever).
_akarin_expr = getattr(getattr(core, 'akarin', None), 'Expr', None)


def _expr(clips, expr, **kwargs):
    if _akarin_expr is not None:
        return _akarin_expr(clips, expr, **kwargs)
    return core.std.Expr(clips, expr, **kwargs)


# ---------------------------------------------------------------------------
# Small numeric helpers (helpers.py)
# ---------------------------------------------------------------------------

def cround(x: float) -> int:
    return math.floor(x + 0.5) if x > 0 else math.ceil(x - 0.5)


def m4(x: Union[float, int]) -> int:
    return 16 if x < 16 else cround(x / 4) * 4


def scale(value, peak):
    """8-bit level -> the clip's own range (peak == 1 means float)."""
    return cround(value * peak / 255) if peak != 1 else value / 255


def scale_value(value: Union[int, float], input_depth: int, output_depth: int) -> float:
    """Rescale a luma level between integer bit depths.

    Trimmed to upstream ``helpers.scale_value``'s defaults - limited range in
    and out, luma - which is the only mode DitherLumaRebuild uses. In that mode
    both peaks are ``219 << (bits - 8)``, so the ratio is a plain power of two.
    Do not "fix" this to a full-range (peak / 255) rescale: it moves the search
    clip's black point and changes the motion vectors found at >8 bits.
    """
    if input_depth == output_depth:
        return value
    return value * (1 << (output_depth - 8)) / (1 << (input_depth - 8))


def Padding(clip: vs.VideoNode, left: int = 0, right: int = 0, top: int = 0, bottom: int = 0) -> vs.VideoNode:
    if not isinstance(clip, vs.VideoNode):
        raise vs.Error('Padding: this is not a clip')
    if left < 0 or right < 0 or top < 0 or bottom < 0:
        raise vs.Error('Padding: border size to pad must not be negative')
    width = clip.width + left + right
    height = clip.height + top + bottom
    return clip.resize.Point(width, height, src_left=-left, src_top=-top,
                             src_width=width, src_height=height)


def DitherLumaRebuild(src: vs.VideoNode, s0: float = 2.0, c: float = 0.0625,
                      chroma: bool = True) -> vs.VideoNode:
    """Converts luma (and chroma) to PC levels, optionally pumping up the darks.

    Only ever used to build the clip fed to motion search.
    """
    if not isinstance(src, vs.VideoNode):
        raise vs.Error('DitherLumaRebuild: this is not a clip')
    if src.format.color_family == vs.RGB:
        raise vs.Error('DitherLumaRebuild: RGB format is not supported')

    is_gray = src.format.color_family == vs.GRAY
    is_integer = src.format.sample_type == vs.INTEGER

    bits = src.format.bits_per_sample
    neutral = 1 << (bits - 1)

    k = (s0 - 1) * c
    if is_integer:
        t = 'x {} - {} / 0 max 1 min'.format(scale_value(16, 8, bits), scale_value(219, 8, bits))
    else:
        t = 'x 0 max 1 min'
    e = '{} {} {} {} {} + / - * {} 1 {} - * + '.format(k, 1 + c, (1 + c) * c, t, c, t, k)
    if is_integer:
        e += '{} *'.format(scale_value(256, 8, bits))

    if is_gray:
        return _expr(src, expr=e)
    chroma_expr = 'x {} - 128 * 112 / {} +'.format(neutral, neutral) if (chroma and is_integer) else ''
    return _expr(src, expr=[e, chroma_expr])


def BoxFilter(input: vs.VideoNode, radius: int = 16, radius_v: Optional[int] = None,
              planes: Optional[Union[int, Sequence[int]]] = None) -> vs.VideoNode:
    """Box filter - averages a (radius*2-1) square around each output pixel.

    Trimmed to the branches reachable in this bundle (upstream's fmtc.resample
    and vszip routes are dropped; std.BoxBlur has existed since R39).
    """
    if not isinstance(input, vs.VideoNode):
        raise TypeError('BoxFilter: "input" must be a clip!')

    if planes is None:
        planes = list(range(input.format.num_planes))
    elif isinstance(planes, int):
        planes = [planes]

    if radius_v is None:
        radius_v = radius
    if radius == radius_v == 1:
        return input

    if radius == radius_v in (2, 3):
        return core.std.Convolution(input, [1] * ((radius * 2 - 1) ** 2), planes=planes, mode='s')

    return core.std.BoxBlur(input, hradius=radius - 1, vradius=radius_v - 1, planes=planes)


def Sharpen(clip: vs.VideoNode, amountH: float = 1.0, amountV: Optional[float] = None,
            planes: Optional[Union[int, Sequence[int]]] = None) -> vs.VideoNode:
    """Avisynth's internal Sharpen(): 3x3 kernel [(1-2^a)/2, 2^a, (1-2^a)/2]."""
    if not isinstance(clip, vs.VideoNode):
        raise TypeError('Sharpen: "clip" is not a clip!')
    if amountH < -1.5849625 or amountH > 1:
        raise ValueError("Sharpen: 'amountH' out of range [-1.58 ~ 1]")
    if amountV is None:
        amountV = amountH
    elif amountV < -1.5849625 or amountV > 1:
        raise ValueError("Sharpen: 'amountV' out of range [-1.58 ~ 1]")

    if planes is None:
        planes = list(range(clip.format.num_planes))

    center_weight_v = math.floor(2 ** (amountV - 1) * 1023 + 0.5)
    outer_weight_v = math.floor((0.25 - 2 ** (amountV - 2)) * 1023 + 0.5)
    center_weight_h = math.floor(2 ** (amountH - 1) * 1023 + 0.5)
    outer_weight_h = math.floor((0.25 - 2 ** (amountH - 2)) * 1023 + 0.5)

    if math.fabs(amountH) >= 0.00002201361136:  # log2(1 + 1/65536)
        clip = core.std.Convolution(clip, [outer_weight_v, center_weight_v, outer_weight_v],
                                    planes=planes, mode='v')
    if math.fabs(amountV) >= 0.00002201361136:
        clip = core.std.Convolution(clip, [outer_weight_h, center_weight_h, outer_weight_h],
                                    planes=planes, mode='h')
    return clip


def Blur(clip: vs.VideoNode, amountH: float = 1.0, amountV: Optional[float] = None,
         planes: Optional[Union[int, Sequence[int]]] = None) -> vs.VideoNode:
    """Avisynth's internal Blur(); Blur(n) is just Sharpen(-n)."""
    if amountH < -1 or amountH > 1.5849625:
        raise ValueError("Blur: 'amountH' out of range [-1 ~ 1.58]")
    if amountV is None:
        amountV = amountH
    elif amountV < -1 or amountV > 1.5849625:
        raise ValueError("Blur: 'amountV' out of range [-1 ~ 1.58]")
    return Sharpen(clip, -amountH, -amountV, planes)


def DFTTest(clip: vs.VideoNode, **kwargs) -> vs.VideoNode:
    """The only DFTTest backend bundled here is the CPU plugin."""
    return core.dfttest.DFTTest(clip, **kwargs)


# ---------------------------------------------------------------------------
# Median / MinBlur / sbr  (misc.py)
# ---------------------------------------------------------------------------
# CTMF's default memsize (1 MiB) is catastrophic at high bit depth: measured
# 0.79 fps against 42 fps at 16-bit radius 3, for bit-identical output.
_CTMF_MEMSIZE = 16 << 20


def median_blur(clip: vs.VideoNode, radius: Union[int, Sequence[int]] = 2,
                planes: Optional[Union[int, Sequence[int]]] = None, **kwargs) -> vs.VideoNode:
    """Median blur, preferring ctmf and falling back to zsmooth.Median."""
    if planes is None:
        planes = list(range(clip.format.num_planes))
    elif isinstance(planes, int):
        planes = [planes]

    if hasattr(core, 'ctmf'):
        kwargs.setdefault('memsize', _CTMF_MEMSIZE)
        return core.ctmf.CTMF(clip, radius=radius, planes=planes, **kwargs)
    if hasattr(core, 'zsmooth'):
        return core.zsmooth.Median(clip, radius=radius, planes=planes)
    raise RuntimeError("median_blur: neither 'ctmf' nor 'zsmooth' is installed.")


def _min_blur_median(clp: vs.VideoNode, radius: int, planes) -> vs.VideoNode:
    """MinBlur's median leg.

    Upstream's radius-3 branch reads

        if clp.format.bits_per_sample == 16 and hasattr(core, 'ctmf'):
            from mvsfunc import LimitFilter
            RG4 = depth(clp, 12, dither_type=Dither.NONE).ctmf.CTMF(radius=3, ...)
            RG4 = LimitFilter(s16, depth(RG4, 16), thr=0.0625, elast=2, ...)

    ``depth`` and ``Dither`` are never imported in that module, so on a 16-bit
    clip - and only on a 16-bit clip - this is a NameError. Since this bundle
    always has ctmf, that branch is always the one taken, which is why
    ``extraSharp=True`` died at exactly 16-bit. mvsfunc ships in
    ``python-packages`` here, so the intended ``Depth``/``LimitFilter`` pair is
    used; if that import ever goes away we drop to a plain radius-3 median
    rather than raising.
    """
    if radius < 3 or clp.format.bits_per_sample != 16 or not hasattr(core, 'ctmf'):
        return median_blur(clp, radius=radius, planes=planes)

    try:
        from mvsfunc import Depth, LimitFilter
    except ImportError:
        return median_blur(clp, radius=3, planes=planes)

    s16 = clp
    rg4 = median_blur(Depth(clp, 12, dither='none'), radius=3, planes=planes)
    return LimitFilter(s16, Depth(rg4, 16), thr=0.0625, elast=2, planes=planes)


def MinBlur(clp: vs.VideoNode, r: int = 1,
            planes: Optional[Union[int, Sequence[int]]] = None) -> vs.VideoNode:
    """Nifty Gauss/Median combination."""
    if not isinstance(clp, vs.VideoNode):
        raise vs.Error('MinBlur: this is not a clip')

    plane_range = range(clp.format.num_planes)
    if planes is None:
        planes = list(plane_range)
    elif isinstance(planes, int):
        planes = [planes]

    matrix1 = [1, 2, 1, 2, 4, 2, 1, 2, 1]
    matrix2 = [1, 1, 1, 1, 1, 1, 1, 1, 1]

    if r <= 0:
        RG11 = sbr(clp, planes=planes)
        RG4 = clp.std.Median(planes=planes)
    elif r == 1:
        RG11 = clp.std.Convolution(matrix=matrix1, planes=planes)
        RG4 = clp.std.Median(planes=planes)
    elif r == 2:
        RG11 = clp.std.Convolution(matrix=matrix1, planes=planes) \
                  .std.Convolution(matrix=matrix2, planes=planes)
        RG4 = _min_blur_median(clp, 2, planes)
    else:
        RG11 = clp.std.Convolution(matrix=matrix1, planes=planes) \
                  .std.Convolution(matrix=matrix2, planes=planes) \
                  .std.Convolution(matrix=matrix2, planes=planes)
        RG4 = _min_blur_median(clp, 3, planes)

    return _expr(
        [clp, RG11, RG4],
        expr=['x y - x z - * 0 < x x y - abs x z - abs < y z ? ?' if i in planes else ''
              for i in plane_range],
    )


def sbr(c: vs.VideoNode, r: int = 1,
        planes: Optional[Union[int, Sequence[int]]] = None) -> vs.VideoNode:
    """Make a highpass on a blur's difference (well, kind of that)."""
    if not isinstance(c, vs.VideoNode):
        raise vs.Error('sbr: this is not a clip')

    neutral = 1 << (c.format.bits_per_sample - 1) if c.format.sample_type == vs.INTEGER else 0.0
    plane_range = range(c.format.num_planes)
    if planes is None:
        planes = list(plane_range)
    elif isinstance(planes, int):
        planes = [planes]

    matrix1 = [1, 2, 1, 2, 4, 2, 1, 2, 1]
    matrix2 = [1, 1, 1, 1, 1, 1, 1, 1, 1]

    RG11 = c.std.Convolution(matrix=matrix1, planes=planes)
    if r >= 2:
        RG11 = RG11.std.Convolution(matrix=matrix2, planes=planes)
    if r >= 3:
        RG11 = RG11.std.Convolution(matrix=matrix2, planes=planes)

    RG11D = core.std.MakeDiff(c, RG11, planes=planes)
    RG11DS = RG11D.std.Convolution(matrix=matrix1, planes=planes)
    if r >= 2:
        RG11DS = RG11DS.std.Convolution(matrix=matrix2, planes=planes)
    if r >= 3:
        RG11DS = RG11DS.std.Convolution(matrix=matrix2, planes=planes)

    RG11DD = _expr(
        [RG11D, RG11DS],
        expr=['x y - x {n} - * 0 < {n} x y - abs x {n} - abs < x y - {n} + x ? ?'.format(n=neutral)
              if i in planes else '' for i in plane_range],
    )
    return core.std.MakeDiff(c, RG11DD, planes=planes)


# ---------------------------------------------------------------------------
# ContraSharpening (sharpen.py)
# ---------------------------------------------------------------------------

def ContraSharpening(denoised: vs.VideoNode, original: vs.VideoNode,
                     radius: Optional[int] = None, rep: int = 1,
                     planes: Optional[Union[int, Sequence[int]]] = None) -> vs.VideoNode:
    """Sharpen the denoised clip, but never add back more than was removed."""
    if not (isinstance(denoised, vs.VideoNode) and isinstance(original, vs.VideoNode)):
        raise vs.Error('ContraSharpening: this is not a clip')
    if denoised.format.id != original.format.id:
        raise vs.Error('ContraSharpening: clips must have the same format')

    if radius is None:
        radius = 1

    neutral = 1 << (denoised.format.bits_per_sample - 1)
    plane_range = range(denoised.format.num_planes)
    if planes is None:
        planes = [0] if denoised.format.color_family != vs.RGB else [0, 1, 2]
    elif isinstance(planes, int):
        planes = [planes]

    pad = 2 if radius < 3 else 4
    denoised = Padding(denoised, pad, pad, pad, pad)
    original = Padding(original, pad, pad, pad, pad)

    matrix1 = [1, 2, 1, 2, 4, 2, 1, 2, 1]
    matrix2 = [1, 1, 1, 1, 1, 1, 1, 1, 1]

    # damp down remaining spots of the denoised clip
    s = MinBlur(denoised, radius, planes)
    # the difference achieved by the denoising
    allD = core.std.MakeDiff(original, denoised, planes=planes)

    RG11 = s.std.Convolution(matrix=matrix1, planes=planes)
    if radius >= 2:
        RG11 = RG11.std.Convolution(matrix=matrix2, planes=planes)
    if radius >= 3:
        RG11 = RG11.std.Convolution(matrix=matrix2, planes=planes)

    # the difference of a simple kernel blur
    ssD = core.std.MakeDiff(s, RG11, planes=planes)
    # limit the difference to the max of what the denoising removed locally
    repair = core.zsmooth.Repair if hasattr(core, 'zsmooth') else core.rgvs.Repair
    ssDD = repair(ssD, allD, mode=[rep if i in planes else 0 for i in plane_range])
    # abs(diff) after limiting may not be bigger than before
    ssDD = _expr([ssDD, ssD],
                 expr=['x {n} - abs y {n} - abs < x y ?'.format(n=neutral) if i in planes else ''
                       for i in plane_range])
    # apply the limited difference (sharpening is just inverse blurring)
    last = core.std.MergeDiff(denoised, ssDD, planes=planes)
    return last.std.Crop(pad, pad, pad, pad)


# ---------------------------------------------------------------------------
# MVTools wrapper (misc.py MotionVectors)
# ---------------------------------------------------------------------------

class MotionVectors:
    """mvtools-shaped facade over core.mv (core.mvsf for float clips).

    Upstream also translates every call for mvutensils (``core.mvu``). That
    plugin is not bundled by VapourBox, so those branches are removed; what is
    kept is the method/argument vocabulary, so the vendored call sites read the
    same as upstream.
    """

    @staticmethod
    def _ns(clip: vs.VideoNode):
        if clip.format.sample_type == vs.FLOAT and hasattr(core, 'mvsf'):
            return core.mvsf
        return core.mv

    @staticmethod
    def _analyse_func(ns):
        # Some mvsf builds expose "Analyze", mv always uses "Analyse".
        return getattr(ns, 'Analyse', None) or getattr(ns, 'Analyze')

    # -- Super ---------------------------------------------------------------

    def Super(self, clip: vs.VideoNode, hpad: int = 8, vpad: int = 8, pel: int = 2,
              levels: int = 0, chroma: bool = True, sharp: int = 2, rfilter: int = 2,
              pelclip: Optional[vs.VideoNode] = None, *,
              blksize: Optional[int] = None, blksizev: Optional[int] = None,
              overlap: Optional[int] = None, overlapv: Optional[int] = None) -> vs.VideoNode:
        # blksize/overlap exist only so mvutensils call sites keep working;
        # core.mv derives the padding itself and ignores them.
        del blksize, blksizev, overlap, overlapv
        return self._ns(clip).Super(clip, hpad=hpad, vpad=vpad, pel=pel, levels=levels,
                                    chroma=chroma, sharp=sharp, rfilter=rfilter, pelclip=pelclip)

    # -- Analyse -------------------------------------------------------------

    def _analyse(self, super: vs.VideoNode, blksize: int = 8, blksizev: Optional[int] = None,
                 levels: int = 0, search: int = 4, searchparam: int = 2, pelsearch: int = 0,
                 isb: bool = False, lambda_: Optional[int] = None, chroma: bool = True,
                 delta: int = 1, truemotion: bool = True, lsad: Optional[int] = None,
                 plevel: Optional[int] = None, global_: Optional[bool] = None,
                 pnew: Optional[int] = None, pzero: Optional[int] = None, pglobal: int = 0,
                 overlap: int = 0, overlapv: Optional[int] = None, divide: int = 0,
                 badsad: int = 10000, badrange: int = 24, meander: bool = True,
                 trymany: bool = False, fields: bool = False, tff: Optional[bool] = None,
                 search_coarse: int = 3, dct: int = 0) -> vs.VideoNode:
        ns = self._ns(super)
        return self._analyse_func(ns)(
            super, blksize=blksize, blksizev=blksizev, levels=levels, search=search,
            searchparam=searchparam, pelsearch=pelsearch, isb=isb, lambda_=lambda_, chroma=chroma,
            delta=delta, truemotion=truemotion, lsad=lsad, plevel=plevel, global_=global_,
            pnew=pnew, pzero=pzero, pglobal=pglobal, overlap=overlap, overlapv=overlapv,
            divide=divide, badsad=badsad, badrange=badrange, meander=meander, trymany=trymany,
            fields=fields, tff=tff, search_coarse=search_coarse, dct=dct)

    def Analyse(self, *args, **kwargs) -> vs.VideoNode:
        return self._analyse(*args, **kwargs)

    def Analyze(self, *args, **kwargs) -> vs.VideoNode:
        return self._analyse(*args, **kwargs)

    def AnalyseMany(self, super: vs.VideoNode, radius: int = 1, delta: int = 1,
                    **kwargs) -> List[vs.VideoNode]:
        """Flat [bv1, fv1, bv2, fv2, ... bv<radius>, fv<radius>] - the order
        Degrain()/Compensate() expect. core.mv has no batch call, so this is a
        plain loop."""
        vectors = []
        for step in range(delta, delta * radius + 1, delta):
            for isb in (True, False):
                vectors.append(self._analyse(super, isb=isb, delta=step, **kwargs))
        return vectors

    # -- Recalculate ---------------------------------------------------------

    def Recalculate(self, super: vs.VideoNode, vectors, thsad: float = 200.0, smooth: int = 1,
                    blksize: int = 8, blksizev: Optional[int] = None, search: int = 4,
                    searchparam: int = 2, lambda_: Optional[int] = None, chroma: bool = True,
                    truemotion: bool = True, pnew: Optional[int] = None, overlap: int = 0,
                    overlapv: Optional[int] = None, divide: int = 0, meander: bool = True,
                    fields: bool = False, tff: Optional[bool] = None, dct: int = 0):
        if isinstance(vectors, (list, tuple)):
            return [self.Recalculate(super, v, thsad=thsad, smooth=smooth, blksize=blksize,
                                     blksizev=blksizev, search=search, searchparam=searchparam,
                                     lambda_=lambda_, chroma=chroma, truemotion=truemotion,
                                     pnew=pnew, overlap=overlap, overlapv=overlapv, divide=divide,
                                     meander=meander, fields=fields, tff=tff, dct=dct)
                    for v in vectors]
        return self._ns(super).Recalculate(
            super, vectors, thsad=thsad, smooth=smooth, blksize=blksize, blksizev=blksizev,
            search=search, searchparam=searchparam, lambda_=lambda_, chroma=chroma,
            truemotion=truemotion, pnew=pnew, overlap=overlap, overlapv=overlapv, divide=divide,
            meander=meander, fields=fields, tff=tff, dct=dct)

    # -- Compensate ----------------------------------------------------------

    def Compensate(self, clip: vs.VideoNode, super: vs.VideoNode, vectors,
                   scbehavior: int = 1, thsad: float = 10000.0, fields: bool = False,
                   time: float = 100.0, thscd1: float = 400.0, thscd2: float = 130.0,
                   tff: Optional[bool] = None) -> vs.VideoNode:
        return self._ns(clip).Compensate(clip, super, vectors, scbehavior=scbehavior, thsad=thsad,
                                         fields=fields, time=time, thscd1=thscd1, thscd2=thscd2,
                                         tff=tff)

    # -- Degrain / Degrain1..N -----------------------------------------------

    def _degrain(self, clip: vs.VideoNode, super: vs.VideoNode, *vectors,
                 thsad: float = 400.0, thsadc: Optional[float] = None, plane: int = 4,
                 limit: float = 255.0, limitc: Optional[float] = None,
                 thscd1: float = 400.0, thscd2: float = 130.0, opt: bool = True) -> vs.VideoNode:
        vec_list = [v for v in vectors]
        if not vec_list or len(vec_list) % 2 != 0 or any(v is None for v in vec_list):
            raise vs.Error('MV.Degrain: expected an even, gapless list of vector clips '
                           '(bw1, fw1, bw2, fw2, ...)')
        ns = self._ns(clip)
        func = getattr(ns, 'Degrain{}'.format(len(vec_list) // 2))
        return func(clip, super, *vec_list, thsad=thsad,
                    thsadc=thsadc if thsadc is not None else thsad, plane=plane, limit=limit,
                    limitc=limitc if limitc is not None else limit, thscd1=thscd1, thscd2=thscd2,
                    opt=opt)

    def Degrain(self, clip, super, *vectors, **kwargs):
        return self._degrain(clip, super, *vectors, **kwargs)

    def __getattr__(self, name: str):
        # Handles Degrain1..DegrainN without hand-writing each one.
        suffix = name[len('Degrain'):] if name.startswith('Degrain') else None
        if suffix is not None and (suffix == '' or suffix.isdigit()):
            return lambda clip, super, *vectors, **kwargs: self._degrain(
                clip, super, *vectors, **kwargs)
        raise AttributeError('MotionVectors has no attribute {!r}'.format(name))


# Ready-made singleton, matching upstream's `from misc import MV`.
MV = MotionVectors()


# ---------------------------------------------------------------------------
# Depth scaling
# ---------------------------------------------------------------------------

def depth_scale(clip: vs.VideoNode) -> float:
    """Multiplier taking an 8-bit level to the clip's own range.

    Every threshold and offset exposed by these filters is written in 8-bit
    units (0-255), which is also how VapourBox's UI presents them. Anything
    handed to a plugin that works in the clip's *own* range is therefore wrong
    by 4x at 10-bit and 256x at 16-bit unless it goes through here.
    """
    if clip.format.sample_type == vs.FLOAT:
        return 1.0 / 255.0
    return float(1 << (clip.format.bits_per_sample - 8))


def require_integer(clip: vs.VideoNode, func: str) -> None:
    """Float clips need core.mvsf, which this bundle does not ship.

    Without this the failure is a bare 'Super: input clip must be integer' from
    deep inside the graph, several frames of Python away from the cause.
    """
    if clip.format.sample_type == vs.FLOAT and not hasattr(core, 'mvsf'):
        raise vs.Error(
            '{}: float (32-bit) input needs the mvsf plugin for motion search, which is not '
            'bundled. Convert to an integer format (8-16 bit) first.'.format(func))
