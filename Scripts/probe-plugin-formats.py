#!/usr/bin/env python3
"""Which formats and frame sizes each plugin call the script template makes
accepts, measured against the deps bundle (task #48).

Every pass-level plugin call in worker/templates/ is listed in CALLS below,
with the arguments the template passes (schema defaults where it substitutes
a value). Each one is run on a real picture (the interlaced capture in
Tests/TestResources) converted to every format a pass can be handed:

  * the reachable set: {4:2:0, 4:2:2, 4:4:4} x {8, 10, 12, 16} bits x
    {progressive, BFF, TFF}, at 160x120. pipe_source reads 4:1:1 too, but the
    template converts it to 4:2:2 before the first pass; 9 and 14-bit never
    reach the script (pixel_format.rs decodes them as 10 and 16);
  * documentation rows, recorded but outside that set: 4:1:1 8-bit and
    9/14-bit 4:2:0, which is why those two rules exist;
  * a size axis (full mode only): 64x48, 352x240 (under 402 lines), 718x480
    (width not mod 4), 720x486, 720x576 and 1920x1080, at each subsampling,
    progressive and TFF, 8 and 16-bit.

A cell is "ok" when a frame of the call's output can be requested; otherwise
it records the first line of the error, or "crash: <status>" when the
process died. Every call runs in its own process; after a crash the cells
left are re-run, the crashing one alone. What this cannot see: a plugin that
ACCEPTS a format and reads it wrongly (Depan on 8-bit, task #32), or an
up-conversion that quantises (task #34). Those are the format sweep's.

  probe-plugin-formats.py [--quick] [--calls a,b] [--out table.json]
                          [--check table.json] [--jobs N]

Run it with the bundle's Python and its environment (the report's
reproduce.sh, or WorkerHarness.workerEnv). --out writes the table
(Tests/TestResources/plugin_format_table.json is the committed one);
--check compares every cell measured with that table and exits 1 on any
difference. --quick measures the reachable set for the calls with a
contract or a known limit (plugin_formats.CONTRACTS / HANDLED), plus 4:2:0 at
720x486 for a contract with a frame-size step, one format per depth for every other
call, and QUICK_SIZES (a size a template argument keeps working): the push
gate's subset. A contracted call's cells are also
run through plugin_formats.run_within() (the `within` result, task #57): the
plugin may refuse a size its contract pads. --quick does that only for a
contract with a frame-size step.
"""
import argparse
import concurrent.futures
import json
import os
import platform
import signal
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
TEMPLATES = os.path.join(REPO, 'worker', 'templates')
FIXTURE = os.path.join(REPO, 'Tests', 'TestResources', 'interlaced_test.avi')
FRAMES = 10

BASE = (160, 120)
SIZES = [(64, 48), (352, 240), (718, 480), (720, 486), (720, 576), (1920, 1080)]
SUBSAMPLINGS = ['420', '422', '444']
DEPTHS = [8, 10, 12, 16]
FIELDS = [0, 1, 2]  # _FieldBased: progressive, BFF, TFF


# ---------------------------------------------------------------------------
# The calls. `covers` names every plugin function the entry exercises, as the
# template spells it (core.<ns>.<fn> without "core.", haf.<fn> as
# havsfunc.<fn>); app/test/plugin_format_contracts_test.dart checks every call
# in the template and its modules is covered here or listed in NOT_PROBED.
# Each `run` takes the probe clip and returns the clip whose frame is fetched.
# ---------------------------------------------------------------------------

def _calls():
    import vapoursynth as vs
    core = vs.core
    sys.path.insert(0, TEMPLATES)
    import havsfunc as haf

    def nnedi3(c, **kw):
        # The template's _nnedi3(): nnedi3 on ARM where it is bundled.
        if platform.machine().lower() in ('arm64', 'aarch64') and hasattr(core, 'nnedi3'):
            return core.nnedi3.nnedi3(c, **kw)
        return core.znedi3.nnedi3(c, **kw)

    def luma(c):
        return core.std.ShufflePlanes(c, 0, vs.GRAY)

    def mv_flow(c, fn):
        # fn gets opt= as the template passes it: on x86 with AVX2, MVTools'
        # vector upsizer writes before its buffer with fewer than 8 block
        # columns (64x48 here), which crashed every 64x48 cell on Linux x64;
        # plugin_formats.mvtools_flow_opt() selects the C upsizer there
        # (task #69). QUICK_SIZES keeps those cells in the push gate.
        import plugin_formats
        sup = core.mv.Super(c, pel=2)
        bw = core.mv.Analyse(sup, isb=True, blksize=16, overlap=8)
        fw = core.mv.Analyse(sup, isb=False, blksize=16, overlap=8)
        return fn(c, sup, bw, fw, plugin_formats.mvtools_flow_opt(c.width, 16, 8))

    def mcds(c, frames):
        sup_s = core.mv.Super(c, pel=2, sharp=1)
        sup_r = core.mv.Super(c, pel=2, sharp=1, levels=1)

        def vec(delta, isb):
            return core.mv.Analyse(sup_s, isb=isb, delta=delta, blksize=16, overlap=8)
        kw = dict(clip=c, super=sup_r, thsad=400, plane=4)
        for d in range(1, frames + 1):
            kw['mvbw' if d == 1 else 'mvbw%d' % d] = vec(d, True)
            kw['mvfw' if d == 1 else 'mvfw%d' % d] = vec(d, False)
        return getattr(core.mv, 'Degrain%d' % frames)(**kw)

    def bm3d(c):
        # The Noise Reduction block: each plane as its own 16-bit GRAY clip.
        p = core.resize.Point(luma(c), format=vs.GRAY16)
        ref = core.bm3d.VAggregate(core.bm3d.VBasic(p, sigma=3.0, radius=1, profile='np'), radius=1)
        ref = core.bm3d.VAggregate(core.bm3d.VFinal(p, ref, sigma=3.0, radius=1, profile='np'), radius=1)
        b = core.bm3d.Basic(p, sigma=3.0, profile='np')
        return core.std.Splice([ref, core.bm3d.Final(p, b, sigma=3.0, profile='np')])

    def descratch(c):
        # Exactly the template's call, Blur Radius clamp included (#35); the
        # pass's 4:2:2 carrier for 4:2:0 (#29) is not: this is the plugin.
        return core.descratch.DeScratch(
            c, mindif=5, asym=10, maxgap=3, maxwidth=3, minwidth=1, minlen=100,
            maxlen=2048, maxangle=5, blurlen=max(0, min(15, c.height // 2 - 1)),
            keep=100, border=2, modey=1, modeu=0, modev=0)

    def descratch_pass(c):
        # The pass as the template runs it at 8-bit: luma of 4:2:0 on a 4:2:2
        # carrier with blank chroma.
        if c.format.subsampling_h == 0:
            return descratch(c)
        blank = core.std.BlankClip(c, width=c.width // 2, format=vs.GRAY8, color=128, keep=True)
        y = descratch(core.std.ShufflePlanes([c, blank, blank], [0, 0, 0], vs.YUV))
        return core.std.ShufflePlanes([y, c], [0, 1, 2], vs.YUV)

    def sangnom(c):
        aa = core.resize.Spline36(c, c.width * 2, c.height * 2)
        aa = core.sangnom.SangNom(aa, order=1, aa=48)
        aa = core.std.Transpose(core.sangnom.SangNom(core.std.Transpose(aa), order=1, aa=48))
        return core.resize.Spline36(aa, c.width, c.height)

    def vine(c):
        # The Dehalo vine block's three NLMeans calls, on luma.
        y = luma(c)
        ss = core.resize.Bicubic(y, y.width * 2, y.height * 2)
        ss = core.vszip.NLMeans(ss, d=0, a=2, s=0, h=10.0)
        sm = core.vszip.NLMeans(y, d=0, a=2, s=0, h=10.0)
        hi = core.std.MakeDiff(y, sm)
        return core.std.Splice([core.resize.Bicubic(ss, y.width, y.height),
                                core.vszip.NLMeans(core.std.MakeDiff(y, hi), d=0, a=2, s=4, h=1.0, rclip=hi)])

    def mpeg2stinx(c):
        field = 3 if c.get_frame(0).props.get('_FieldBased', 0) == 2 else 2
        return core.bwdif.Bwdif(c, field=field, edeint=nnedi3(c, field=field))

    def clahe(c):
        return core.vszip.CLAHE(luma(c), limit=3, tiles=[3])

    def eedi3(c):
        sclip = nnedi3(c, field=1, dh=True)
        return core.eedi3m.EEDI3(c, field=1, dh=True, sclip=sclip, alpha=0.2, beta=0.25,
                                 gamma=20.0, nrad=2, mdis=20)

    def module(name, fn, *args, **kw):
        mod = __import__(name)
        return getattr(mod, fn)(*args, **kw)

    C = {}

    def call(key, covers, run):
        C[key] = {'covers': covers, 'run': run}

    # Deinterlace, IVTC
    call('havsfunc.QTGMC', ['havsfunc.QTGMC'], lambda c: haf.QTGMC(c, Preset='Fast', TFF=True))
    # Super Fast halves the frame for its motion search (SrchClipPP 1), which
    # Fast doesn't: the only presets that refuse a 4:2:x width 2 mod 4 (task
    # #56 F2). The template picks this contract for SrchClipPP 1.
    call('havsfunc.QTGMC[SrchClipPP=1]', ['havsfunc.QTGMC'], lambda c: haf.QTGMC(c, Preset='Super Fast', TFF=True))
    call('bwdif.Bwdif', ['bwdif.Bwdif'], lambda c: core.bwdif.Bwdif(c, field=3, edeint=nnedi3(c, field=3)))
    call('nnedi3.nnedi3', ['nnedi3.nnedi3', 'znedi3.nnedi3'], lambda c: nnedi3(c, field=1))
    call('vivtc.VFM', ['vivtc.VFM'], lambda c: core.vivtc.VFM(c, order=1, mode=1, cthresh=9, mi=80, blockx=16, blocky=16))
    call('vivtc.VDecimate', ['vivtc.VDecimate'], lambda c: core.vivtc.VDecimate(c, cycle=5, dupthresh=1.1, scthresh=15.0))
    call('srestore.unblend', ['havsfunc.AverageFrames'],
         lambda c: module('srestore', 'unblend', c, 24000, 1001))
    # Edge repair, ghosts, deflicker, scratches, spots
    call('fb.FillBorders', ['fb.FillBorders'], lambda c: core.fb.FillBorders(c, left=2, right=2, top=2, bottom=2, mode='fillmargins', interlaced=-1))
    call('lghost.LGhost', ['lghost.LGhost'], lambda c: core.lghost.LGhost(c, mode=[1], shift=[4], intensity=[30]))
    call('deflicker.global_deflicker', [], lambda c: module('deflicker', 'global_deflicker', c, strength=1.0, window=5))
    call('deflicker.reduce_flicker', [], lambda c: module('deflicker', 'reduce_flicker', c, strength=2))
    call('descratch.DeScratch', ['descratch.DeScratch'], descratch)
    call('pass.DeScratch', [], descratch_pass)
    call('spotless.SpotLess', ['mv.Super', 'mv.Analyse', 'mv.Compensate', 'mv.Recalculate'],
         lambda c: module('spotless', 'SpotLess', c))
    call('removedirt.remove_dirt',
         ['zsmooth.Clense', 'zsmooth.ForwardClense', 'zsmooth.BackwardClense', 'removedirt.SCSelect',
          'zsmooth.Repair', 'removedirt.RestoreMotionBlocks', 'zsmooth.RemoveGrain'],
         lambda c: module('removedirt', 'remove_dirt', c, post_denoise=True))
    # Noise reduction
    call('havsfunc.SMDegrain', ['havsfunc.SMDegrain'], lambda c: haf.SMDegrain(c, tr=2, thSAD=300, thSADC=150, RefineMotion=True, prefilter=2, contrasharp=False))
    call('havsfunc.MCTemporalDenoise', ['havsfunc.MCTemporalDenoise'], lambda c: haf.MCTemporalDenoise(c, settings='medium', sigma=4.0, radius=2))
    call('dfttest.DFTTest', ['dfttest.DFTTest'], lambda c: core.dfttest.DFTTest(c, sigma=8.0, tbsize=3, sbsize=16))
    call('fft3dfilter.FFT3DFilter', ['fft3dfilter.FFT3DFilter'], lambda c: core.fft3dfilter.FFT3DFilter(c, sigma=2.0, bt=3, sharpen=0.0, measure=0))
    call('ttmpsm.TTempSmooth', ['ttmpsm.TTempSmooth'], lambda c: core.ttmpsm.TTempSmooth(c, maxr=3, thresh=[4], mdiff=[2], strength=2))
    call('flux.SmoothT', ['flux.SmoothT'], lambda c: core.flux.SmoothT(c, temporal_threshold=7))
    call('flux.SmoothST', ['flux.SmoothST'], lambda c: core.flux.SmoothST(c, temporal_threshold=7, spatial_threshold=7))
    call('havsfunc.STPresso', ['havsfunc.STPresso'], lambda c: haf.STPresso(c, limit=3, bias=24, tthr=12))
    call('ctmf.CTMF', ['ctmf.CTMF'], lambda c: core.ctmf.CTMF(c, radius=2, planes=[0, 1, 2], memsize=16777216, opt=2))
    call('mv.Degrain1', ['mv.Super', 'mv.Analyse', 'mv.Degrain1'], lambda c: mcds(c, 1))
    call('mv.Degrain2', ['mv.Degrain2'], lambda c: mcds(c, 2))
    call('mv.Degrain3', ['mv.Degrain3'], lambda c: mcds(c, 3))
    call('bm3d', ['bm3d.Basic', 'bm3d.Final', 'bm3d.VBasic', 'bm3d.VFinal', 'bm3d.VAggregate'], bm3d)
    call('vszip.NLMeans', ['vszip.NLMeans'], lambda c: core.vszip.NLMeans(c, d=1, a=2, s=4, h=1.2))
    call('mclean.mClean', ['vcm.Median', 'zsmooth.Median', 'zsmooth.TemporalMedian', 'neo_f3kdb.Deband'],
         lambda c: module('mclean', 'mClean', c, thSAD=400, chroma=True, sharp=10, rn=14, strength=20))
    call('temporaldegrain2.TemporalDegrain2', [],
         lambda c: module('temporaldegrain2', 'TemporalDegrain2', c, degrainTR=1, grainLevel=2, postFFT=1, postSigma=1.0))
    call('havsfunc.ContraSharpening', ['havsfunc.ContraSharpening'],
         lambda c: haf.ContraSharpening(core.std.BoxBlur(c), c, rep=13))
    # Chroma denoise
    call('zsmooth.CCD', ['zsmooth.CCD'], lambda c: core.zsmooth.CCD(c, threshold=4.0, temporal_radius=0, points=[True, True, False], scale=1.0))
    call('zsmooth.Cnr4', ['zsmooth.Cnr4', 'misc.SCDetect'],
         lambda c: core.zsmooth.Cnr4(core.misc.SCDetect(c), sense=[35, 47, 47], str=[192, 255, 255], radius=2, tmode=0, wmode=0))
    # Dehalo
    call('havsfunc.DeHalo_alpha', ['havsfunc.DeHalo_alpha'], lambda c: haf.DeHalo_alpha(c, rx=2.0, ry=2.0, darkstr=1.0, brightstr=1.0, lowsens=50, highsens=50, ss=1.5))
    call('havsfunc.FineDehalo', ['havsfunc.FineDehalo'], lambda c: haf.FineDehalo(c, rx=2.0, ry=2.0, darkstr=1.0, brightstr=1.0))
    call('havsfunc.FineDehalo2', ['havsfunc.FineDehalo2'], lambda c: haf.FineDehalo2(c))
    call('havsfunc.YAHR', ['havsfunc.YAHR'], lambda c: haf.YAHR(c, blur=2, depth=32))
    call('havsfunc.EdgeCleaner', ['havsfunc.EdgeCleaner'], lambda c: haf.EdgeCleaner(c, strength=10, rep=True, rmode=17, smode=0, hot=False))
    call('havsfunc.HQDeringmod', ['havsfunc.HQDeringmod'], lambda c: haf.HQDeringmod(c, mrad=1, msmooth=1, mthr=60, thr=12.0, darkthr=None))
    call('vine', [], vine)
    # Deblock
    call('havsfunc.Deblock_QED', ['havsfunc.Deblock_QED'], lambda c: haf.Deblock_QED(c, quant1=24, quant2=26, aOff1=1, aOff2=1))
    call('deblock.Deblock', ['deblock.Deblock'], lambda c: core.deblock.Deblock(c, quant=24))
    call('dctf.DCTFilter', ['dctf.DCTFilter'], lambda c: core.dctf.DCTFilter(c, factors=[1, 1, 1, 1, 0.5, 0.5, 0.5, 0.5], planes=[0]))
    call('mpeg2stinx', [], mpeg2stinx)
    # Deband, anti-aliasing
    call('neo_f3kdb.Deband', ['neo_f3kdb.Deband'], lambda c: core.neo_f3kdb.Deband(c, range=15, y=64, cb=64, cr=64, grainy=0, grainc=0, dynamic_grain=False, output_depth=c.format.bits_per_sample))
    call('havsfunc.daa', ['havsfunc.daa'], lambda c: haf.daa(c))
    call('havsfunc.santiag', ['havsfunc.santiag'], lambda c: haf.santiag(c, strh=1, strv=1, type='nnedi3'))
    call('sangnom.SangNom', ['sangnom.SangNom'], sangnom)
    # Chroma fixes
    call('autochromafix.auto_chroma_fix', [], lambda c: module('autochromafix', 'auto_chroma_fix', c))
    call('dedot.Dedot', ['dedot.Dedot'], lambda c: core.dedot.Dedot(c, luma_2d=20, luma_t=20, chroma_t1=15, chroma_t2=5))
    call('havsfunc.FixChromaBleedingMod', ['havsfunc.FixChromaBleedingMod'], lambda c: haf.FixChromaBleedingMod(c, cx=4, cy=4, thr=4.0, strength=0.8))
    call('havsfunc.LUTDeCrawl', ['havsfunc.LUTDeCrawl'], lambda c: haf.LUTDeCrawl(c, ythresh=10, cthresh=10, maxdiff=50))
    call('havsfunc.LUTDeRainbow', ['havsfunc.LUTDeRainbow'], lambda c: haf.LUTDeRainbow(c, cthresh=10, ythresh=10, y=True, linkUV=True))
    call('bifrost.Bifrost', ['bifrost.Bifrost'], lambda c: core.bifrost.Bifrost(c, luma_thresh=10.0, variation=5, interlaced=True))
    call('havsfunc.Vinverse', ['havsfunc.Vinverse'], lambda c: haf.Vinverse(c, sstr=2.7, amnt=255))
    # Colour
    call('havsfunc.SmoothLevels', ['havsfunc.SmoothLevels'], lambda c: haf.SmoothLevels(c, input_low=16, input_high=235, output_low=16, output_high=235, gamma=1.0, useDB=False))
    call('retinex.MSRCP', ['retinex.MSRCP'], lambda c: core.retinex.MSRCP(luma(c), sigma=[25], lower_thr=0.001, upper_thr=0.001))
    call('vszip.CLAHE', ['vszip.CLAHE'], clahe)
    # Stabilize
    call('stabilize.weave', ['mv.DepanEstimate', 'mv.DepanCompensate', 'rgvs.Repair', 'havsfunc.AverageFrames'],
         lambda c: module('stabilize', 'weave', c))
    call('stabilize.correct_pitch', [], lambda c: module('stabilize', 'correct_pitch', c, mode='auto'))
    # Resize, sharpen, grain
    call('eedi3m.EEDI3', ['eedi3m.EEDI3'], eedi3)
    call('havsfunc.LSFmod', ['havsfunc.LSFmod'], lambda c: haf.LSFmod(c, strength=100, overshoot=1, undershoot=1, soft=0))
    call('cas.CAS', ['cas.CAS'], lambda c: core.cas.CAS(c, sharpness=0.5))
    call('warp.AWarpSharp2', ['warp.AWarpSharp2'], lambda c: core.warp.AWarpSharp2(c, thresh=128, blur=2, type=0, depth=[16]))
    call('grain.Add', ['grain.Add'], lambda c: core.grain.Add(c, var=1.0, uvar=0.0, hcorr=0.0, vcorr=0.0, constant=False))
    call('havsfunc.GrainFactory3', ['havsfunc.GrainFactory3'], lambda c: haf.GrainFactory3(c, g1str=7.0, g2str=5.0, g3str=3.0, temp_avg=0))
    # Frame rate
    call('mv.FlowFPS', ['mv.Super', 'mv.Analyse', 'mv.FlowFPS'],
         lambda c: mv_flow(c, lambda c, s, b, f, opt: core.mv.FlowFPS(c, s, b, f, num=60000, den=1001, opt=opt)))
    call('mv.FlowInter', ['mv.FlowInter'],
         lambda c: mv_flow(c, lambda c, s, b, f, opt: core.mv.FlowInter(c, s, b, f, time=50.0, opt=opt)))
    call('havsfunc.ChangeFPS', ['havsfunc.ChangeFPS'], lambda c: haf.ChangeFPS(c, 60000, 1001))
    return C


# Plugin calls in the template that are not probed, and why. The push-gate
# test fails on a call that is neither probed nor listed here.
NOT_PROBED = {
    'knlm.KNLMeansCL': 'OpenCL: no runner has a device (its own probe, --probe-opencl, gates it)',
    'rife.RIFE': 'Vulkan, loaded only for a job that asked for it (--probe-rife gates it); fed RGBS',
    'ncnn.Model': 'Vulkan, loaded only for a job that asked for it (--probe-upscale gates it); fed RGBS',
    'mvsf.Analyse': 'not bundled; reached only by a float clip, which no pass delivers',
    'mvsf.Compensate': 'not bundled; reached only by a float clip, which no pass delivers',
    'mvsf.Super': 'not bundled; reached only by a float clip, which no pass delivers',
    'mvsf.Recalculate': 'not bundled; reached only by a float clip, which no pass delivers',
    'tcanny.TCanny': 'not called: gauss_blur.py names it only to say why it is not (task #52)',
    'vcm.Veed': 'bundled nowhere; mclean.py folds the deband mode that reaches it down to 1',
    'rgvs.RemoveGrain': 'mclean.py\'s fallback where zsmooth is missing; zsmooth is in every bundle',
    'tmedian.TemporalMedian': 'mclean.py\'s fallback where zsmooth is missing; zsmooth is in every bundle',
}


# ---------------------------------------------------------------------------
# Cells
# ---------------------------------------------------------------------------

def cell(ss, bits, field, w, h, reachable=True):
    return {'ss': ss, 'bits': bits, 'field': field, 'w': w, 'h': h, 'reachable': reachable}


def cell_key(c):
    return '%sp%d/f%d/%dx%d' % (c['ss'], c['bits'], c['field'], c['w'], c['h'])


def base_grid():
    return [cell(ss, b, f, *BASE) for ss in SUBSAMPLINGS for b in DEPTHS for f in FIELDS]


def doc_grid():
    return ([cell('411', 8, f, *BASE, reachable=False) for f in (0, 2)]
            + [cell('420', b, 0, *BASE, reachable=False) for b in (9, 14)])


def size_grid():
    return [cell(ss, b, f, w, h) for (w, h) in SIZES for ss in SUBSAMPLINGS
            for b in (8, 16) for f in (0, 2)]


# Extra sizes --quick measures for a call, beyond its usual grid: sizes where
# the template's own arguments avoid a crash the plugin has there, so the push
# gate fails if that guard is lost (MVTools' Flow upsizer at 64x48, task #69).
QUICK_SIZES = {
    'mv.FlowFPS': [(64, 48)],
    'mv.FlowInter': [(64, 48)],
}


def quick_grid(limited, padded=False, key=None):
    if limited:
        grid = base_grid()
        if padded:
            # A contract with a frame-size step: the size it pads (task #57).
            grid += [cell('420', 8, f, 720, 486) for f in (0, 2)]
    else:
        grid = [cell('420', b, 0, *BASE) for b in DEPTHS]
    return grid + [cell('420', b, 0, w, h) for (w, h) in QUICK_SIZES.get(key, []) for b in (8, 16)]


# ---------------------------------------------------------------------------
# Child: run one call's cells, one JSON line per cell as it finishes
# ---------------------------------------------------------------------------

def child(key, cells, fixtures, within=True):
    import ctypes
    import vapoursynth as vs
    core = vs.core
    calls = _calls()
    run = calls[key]['run']
    cache = {}

    def source(w, h):
        if (w, h) in cache:
            return cache[(w, h)]
        path = fixtures['%dx%d' % (w, h)]
        blank = core.std.BlankClip(width=w, height=h, format=vs.YUV444P16, length=FRAMES,
                                   fpsnum=30000, fpsden=1001)
        fsize = w * h * 2 * 3

        def fill(n, f):
            o = f.copy()
            with open(path, 'rb') as fh:
                fh.seek(n * fsize)
                data = fh.read(fsize)
            off = 0
            for p in range(3):
                base = ctypes.cast(o.get_write_ptr(p), ctypes.c_void_p).value
                st = o.get_stride(p)
                for y in range(h):
                    ctypes.memmove(base + y * st, data[off:off + w * 2], w * 2)
                    off += w * 2
            return o
        c = core.std.ModifyFrame(blank, blank, fill)
        cache[(w, h)] = c
        return c

    fmts = {'420': (1, 1), '422': (1, 0), '444': (0, 0), '411': (2, 0)}
    sys.path.insert(0, TEMPLATES)
    import plugin_formats
    contracted = within and key in plugin_formats.CONTRACTS
    for cl in cells:
        try:
            sw, sh = fmts[cl['ss']]
            fmt = core.query_video_format(vs.YUV, vs.INTEGER, cl['bits'], sw, sh)
            c = core.resize.Bicubic(source(cl['w'], cl['h']), format=fmt.id, dither_type='none')
            c = core.std.SetFrameProps(c, _Matrix=6, _Primaries=6, _Transfer=6, _Range=0,
                                       _ChromaLocation=0)
            c = core.std.SetFieldBased(c, cl['field'])
            out = run(c)
            out.get_frame(min(FRAMES // 2, out.num_frames - 1))
            res = {'ok': True}
        except Exception as e:  # noqa: BLE001 -- the error is the measurement
            res = {'ok': False, 'error': _first_line(e)}
        if contracted and cl['reachable']:
            # The call as the template makes it: through run_within(), which
            # converts and pads to the contract (task #57). delta_only=False:
            # only whether it runs is measured, and some calls retime.
            try:
                c = core.resize.Bicubic(source(cl['w'], cl['h']), format=fmt.id, dither_type='none')
                c = core.std.SetFieldBased(core.std.SetFrameProps(
                    c, _Matrix=6, _Primaries=6, _Transfer=6, _Range=0, _ChromaLocation=0), cl['field'])
                out = plugin_formats.run_within(c, key, run, delta_only=False)
                out.get_frame(min(FRAMES // 2, out.num_frames - 1))
                if (out.width, out.height) != (cl['w'], cl['h']):
                    raise RuntimeError('run_within returned %dx%d' % (out.width, out.height))
                res['within'] = 'ok'
            except Exception as e:  # noqa: BLE001
                res['within'] = _first_line(e)
        sys.stdout.write(json.dumps({'key': cell_key(cl), **res}) + '\n')
        sys.stdout.flush()


def _first_line(e):
    return ((str(e).strip().splitlines() or [type(e).__name__])[0])[:300]


# ---------------------------------------------------------------------------
# Parent
# ---------------------------------------------------------------------------

def exit_status(code):
    if code < 0:
        names = {4: 'SIGILL', 6: 'SIGABRT', 8: 'SIGFPE', 9: 'SIGKILL', 10: 'SIGBUS', 11: 'SIGSEGV'}
        return 'signal %d (%s)' % (-code, names.get(-code, 'unknown'))
    if code > 0x7FFFFFFF or code in (0xC0000005, 0xC000001D, 0xC0000409):
        return 'exit code 0x%08X' % (code & 0xFFFFFFFF)
    return 'exit code %d' % code


def run_cells(key, cells, fixtures, within=True):
    """{cell key: {'ok', 'error'?}} for every cell, through as many child
    processes as crashes need. within=False skips the run_within() pass."""
    results = {}
    todo = list(cells)
    while todo:
        p = subprocess.run(
            [sys.executable, os.path.abspath(__file__), '--child', key],
            input=json.dumps({'cells': todo, 'fixtures': fixtures, 'within': within}),
            capture_output=True, text=True, timeout=3600)
        for line in p.stdout.splitlines():
            if line.startswith('{'):
                r = json.loads(line)
                results[r.pop('key')] = r
        todo = [c for c in todo if cell_key(c) not in results]
        if todo and p.returncode == 0:
            raise RuntimeError('%s: child exited cleanly without %d cells:\n%s'
                               % (key, len(todo), p.stderr[-2000:]))
        if todo:
            # The first cell not reported crashed it: re-run that one alone.
            first = todo.pop(0)
            q = subprocess.run(
                [sys.executable, os.path.abspath(__file__), '--child', key],
                input=json.dumps({'cells': [first], 'fixtures': fixtures, 'within': within}),
                capture_output=True, text=True, timeout=3600)
            got = [json.loads(l) for l in q.stdout.splitlines() if l.startswith('{')]
            if got:
                r = got[0]
                results[r.pop('key')] = r
            else:
                results[cell_key(first)] = {'ok': False, 'error': 'crash: ' + exit_status(q.returncode)}
    return results


def make_fixtures(tmp, sizes, ffmpeg):
    out = {}
    for (w, h) in sizes:
        path = os.path.join(tmp, 'src_%dx%d.yuv' % (w, h))
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', FIXTURE,
                        '-frames:v', str(FRAMES), '-vf', 'scale=%d:%d:flags=bicubic' % (w, h),
                        '-pix_fmt', 'yuv444p16le', '-f', 'rawvideo', path], check=True)
        out['%dx%d' % (w, h)] = path
    return out


def summarise(cells, results):
    """The call's limits within the reachable set, from its cells."""
    base = [c for c in cells if c['reachable'] and (c['w'], c['h']) == BASE]
    ok = lambda c: results[cell_key(c)]['ok']  # noqa: E731
    s = {}
    if base and not any(ok(c) for c in base):
        s['broken'] = sorted({results[cell_key(c)]['error'] for c in base})[:3]
        return s
    depths = sorted({c['bits'] for c in base if ok(c)})
    subs = sorted({c['ss'] for c in base if ok(c)})
    fields = sorted({c['field'] for c in base if ok(c)})
    s['depths'] = depths
    s['subsampling'] = subs
    s['field_based'] = fields == FIELDS
    inside = lambda c: c['bits'] in depths and c['ss'] in subs and c['field'] in fields  # noqa: E731
    irregular = [cell_key(c) for c in base if inside(c) and not ok(c)]
    if irregular:
        s['irregular'] = irregular
    sized = [c for c in cells if c['reachable'] and (c['w'], c['h']) != BASE and inside(c)]
    refused = [cell_key(c) for c in sized if not ok(c)]
    if sized:
        s['sizes_refused'] = refused
    within = [cell_key(c) for c in cells if c['reachable'] and results[cell_key(c)].get('within', 'ok') != 'ok']
    if any('within' in results[cell_key(c)] for c in cells):
        s['within_refused'] = within
    crashes = sorted(cell_key(c) for c in cells if results[cell_key(c)].get('error', '').startswith('crash'))
    if crashes:
        s['crashes'] = crashes
    return s


def limited_calls():
    sys.path.insert(0, TEMPLATES)
    import plugin_formats
    return set(plugin_formats.CONTRACTS) | set(plugin_formats.HANDLED)


def padded_calls():
    sys.path.insert(0, TEMPLATES)
    import plugin_formats
    return {k for k, c in plugin_formats.CONTRACTS.items() if (c.width_step, c.height_step) != (1, 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--child')
    ap.add_argument('--quick', action='store_true')
    ap.add_argument('--calls')
    ap.add_argument('--out')
    ap.add_argument('--check')
    ap.add_argument('--list', action='store_true', help='print the probe list as JSON and exit')
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) // 2))
    ap.add_argument('--ffmpeg', default=os.environ.get('VAPOURBOX_FFMPEG', 'ffmpeg'))
    a = ap.parse_args()
    if a.quick and a.out:
        ap.error('--quick measures a subset and writes no summaries; write the table from a full run')

    if a.child:
        req = json.loads(sys.stdin.read())
        child(a.child, req['cells'], req['fixtures'], req.get('within', True))
        return 0

    calls = _calls()
    if a.list:
        print(json.dumps({'calls': {k: v['covers'] for k, v in calls.items()},
                          'not_probed': NOT_PROBED}, indent=1))
        return 0

    keys = a.calls.split(',') if a.calls else list(calls)
    limited = limited_calls() if a.quick else set()
    padded = padded_calls() if a.quick else set()
    grids = {}
    for k in keys:
        if a.quick:
            grids[k] = quick_grid(k in limited, k in padded, k)
        else:
            grids[k] = base_grid() + doc_grid() + size_grid()
    sizes = sorted({(c['w'], c['h']) for g in grids.values() for c in g})

    table = {}
    with tempfile.TemporaryDirectory() as tmp:
        fixtures = make_fixtures(tmp, sizes, a.ffmpeg)
        with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
            # --quick runs the run_within() pass only for a contract with a
            # frame-size step, the one thing it adds over the plugin's own
            # cells: a depth-only contract's conversion is checked on real
            # frames by plugin_format_contracts_test, and running every
            # LUTDeCrawl/LUTDeRainbow cell again at 10-bit doubled their cost
            # (task #56: macOS x64 passed the push gate's 30 minutes).
            futs = {k: ex.submit(run_cells, k, grids[k], fixtures, not a.quick or k in padded)
                    for k in keys}
            for k in keys:
                res = futs[k].result()
                cells = grids[k]
                entry = {'cells': {cell_key(c): res[cell_key(c)] for c in cells}}
                if not a.quick:
                    entry['summary'] = summarise(cells, res)
                table[k] = entry
                bad = sum(1 for r in res.values() if not r['ok'])
                sys.stderr.write('%-40s %4d cells, %4d refused\n' % (k, len(cells), bad))

    status = 0
    if a.check:
        with open(a.check) as fh:
            committed = json.load(fh)
        plat = os.environ.get('VAPOURBOX_PLATFORM', '')
        diffs = []
        for k, entry in table.items():
            want = committed['calls'].get(k)
            if want is None:
                diffs.append('%s: not in the committed table' % k)
                continue
            override = committed.get('platforms', {}).get(plat, {}).get(k, {})
            for ck, got in entry['cells'].items():
                exp = override.get(ck, want['cells'].get(ck))
                if exp is None:
                    diffs.append('%s %s: not in the committed table' % (k, ck))
                elif 'within' in got and exp.get('within') != got['within'] and \
                        (exp.get('within') == 'ok') != (got['within'] == 'ok'):
                    diffs.append('%s %s: table says run_within %s, the bundle says %s' % (
                        k, ck, exp.get('within'), got['within']))
                elif exp['ok'] != got['ok']:
                    diffs.append('%s %s: table says %s, the bundle says %s' % (
                        k, ck, 'ok' if exp['ok'] else 'refused (%s)' % exp.get('error'),
                        'ok' if got['ok'] else 'refused (%s)' % got.get('error')))
        for d in diffs:
            print(d)
        status = 1 if diffs else 0

    if a.out:
        doc = {
            '_about': 'Written by Scripts/probe-plugin-formats.py (task #48). Cells: '
                      '<subsampling>p<bits>/f<_FieldBased>/<WxH>. The reachable set is '
                      '{420,422,444} x {8,10,12,16} x f{0,1,2}; 411 and 9/14-bit rows are '
                      'documentation (the template and pixel_format.rs keep them out). '
                      'summary: the call\'s limits within the reachable set. platforms: '
                      'cells that differ on another bundle, by platform id.',
            'platform': os.environ.get('VAPOURBOX_PLATFORM', ''),
            'calls': table,
            'platforms': {},
        }
        if os.path.exists(a.out):
            with open(a.out) as fh:
                old = json.load(fh)
            doc['platforms'] = old.get('platforms', {})
            if a.calls:
                # A partial run replaces only the calls it measured.
                doc['calls'] = {**old.get('calls', {}), **table}
        with open(a.out, 'w') as fh:
            json.dump(doc, fh, indent=1, sort_keys=True)
            fh.write('\n')
    return status


if __name__ == '__main__':
    sys.exit(main())
