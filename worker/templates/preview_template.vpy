"""
VapourBox Preview Template
Reads raw frames piped from FFmpeg for fast preview generation.
Uses the same filter pipeline as the main template.
"""

import functools
import vapoursynth as vs
import sys
import os

core = vs.core

# Configure cache size for optimal performance with temporal filters
core.max_cache_size = 1024

# Load raw frames piped from FFmpeg via stdin
sys.path.insert(0, r"{{PIPE_SOURCE_DIR}}")
from pipe_source import create_pipe_clip

clip = create_pipe_clip(
    width={{INPUT_WIDTH}}, height={{INPUT_HEIGHT}},
    num_frames={{TOTAL_FRAMES}}, fps_num={{FPS_NUM}},
    fps_den={{FPS_DEN}}, pix_fmt="{{INPUT_PIX_FMT}}",
)

# Convert unusual chroma formats (e.g., 4:1:1 from NTSC DV) to 4:2:2 for filter compatibility
# 4:1:1 (YUV411P) has subsampling_w=2, subsampling_h=0
# Most filters expect 4:2:0 or 4:2:2; 4:2:2 is lossless when upconverting from 4:1:1
if clip.format.subsampling_w > 1:  # 4:1:1 or more extreme horizontal subsampling
    clip = core.resize.Bicubic(clip, format=vs.YUV422P8 if clip.format.bits_per_sample == 8 else vs.YUV422P16)

# Mark field order for interlaced content (pipe source loses container metadata)
{{#SET_FIELD_BASED}}
clip = core.std.SetFieldBased(clip, {{FIELD_BASED}})
{{/SET_FIELD_BASED}}

# Report frame info
total_frames = clip.num_frames
print(f"INPUT_INFO:frames={total_frames},fps_num={{FPS_NUM}},fps_den={{FPS_DEN}}", file=sys.stderr, flush=True)

# Import havsfunc for various filters (QTGMC, SMDegrain, chroma fixes)
import havsfunc as haf

# znedi3 carries x86-only SIMD, so on ARM it is built with X86=0 and runs fully
# scalar — measured 6.3x slower than the bundled nnedi3, which ships real NEON
# kernels. Both implement the same network from the same weights file and their
# signatures are identical for every argument used here, so preferring nnedi3 on
# ARM is a drop-in swap (measured mean difference 0.045/255). Route every
# interpolator call through this helper rather than naming a plugin directly.
# havsfunc's own three call sites get the same treatment via its patch 6.
import platform as _platform

_IS_ARM = _platform.machine().lower() in ('arm64', 'aarch64')


def _nnedi3(clip, **kwargs):
    if _IS_ARM and hasattr(core, 'nnedi3'):
        return core.nnedi3.nnedi3(clip, **kwargs)
    return core.znedi3.nnedi3(clip, **kwargs)


# VapourSynth's std.Expr JIT is wrapped in #ifdef VS_TARGET_CPU_X86, so on ARM
# every expression is walked once per pixel by a scalar interpreter -- by far the
# dominant cost in an arm64 filter graph. akarin has a real LLVM JIT that works
# on aarch64 and is bit-identical to std.Expr for every expression used here.
# Falls back to std.Expr wherever akarin is absent (notably macos-x64, whose
# only wheel would raise the Intel floor to macOS 14). havsfunc's own 116 call
# sites get the same treatment via its patch 7. Route every expression through
# this helper rather than calling core.std.Expr directly.
_akarin_expr = getattr(getattr(core, 'akarin', None), 'Expr', None)


def _expr(clips, expr, **kwargs):
    if _akarin_expr is not None:
        return _akarin_expr(clips, expr, **kwargs)
    return core.std.Expr(clips, expr, **kwargs)

# ============================================================================
# PASS 1: PRE-CROP (before deinterlacing to reduce processing area)
# ============================================================================
{{#PRE_CROP}}
clip = core.std.Crop(clip, left={{CROP_LEFT}}, right={{CROP_RIGHT}}, top={{CROP_TOP}}, bottom={{CROP_BOTTOM}})
{{/PRE_CROP}}

# ============================================================================
# PASS 2: DEINTERLACING
# ============================================================================
{{#DEINTERLACE}}
{{#DEINT_QTGMC}}
{{#DEINT_WORKING_FORMAT}}
# Working format for the deinterlace pass (issue #49) — see pipeline_template.vpy.
# The preview must apply the same conversion as the encode or it won't match.
_deint_src_format = clip.format
if clip.format.color_family == vs.YUV:
    _deint_ss_h = clip.format.subsampling_h
    _deint_bits = clip.format.bits_per_sample
{{#DEINT_WF_CHROMA}}
    _deint_ss_h = 0
{{/DEINT_WF_CHROMA}}
{{#DEINT_WF_BITS}}
    _deint_bits = max(_deint_bits, 16)
{{/DEINT_WF_BITS}}
    if _deint_ss_h != clip.format.subsampling_h or _deint_bits != clip.format.bits_per_sample:
        clip = core.resize.Bicubic(clip, format=clip.format.replace(
            subsampling_h=_deint_ss_h, bits_per_sample=_deint_bits).id)
{{/DEINT_WORKING_FORMAT}}
clip = haf.QTGMC(
    clip,
    Preset="{{PRESET}}",
{{#TFF}}
    TFF={{TFF}},
{{/TFF}}
{{#INPUT_TYPE}}
    InputType={{INPUT_TYPE}},
{{/INPUT_TYPE}}
{{#FPS_DIVISOR}}
    FPSDivisor={{FPS_DIVISOR}},
{{/FPS_DIVISOR}}
{{#TR0}}
    TR0={{TR0}},
{{/TR0}}
{{#TR1}}
    TR1={{TR1}},
{{/TR1}}
{{#TR2}}
    TR2={{TR2}},
{{/TR2}}
{{#REP0}}
    Rep0={{REP0}},
{{/REP0}}
{{#REP1}}
    Rep1={{REP1}},
{{/REP1}}
{{#REP2}}
    Rep2={{REP2}},
{{/REP2}}
{{#REP_CHROMA}}
    RepChroma={{REP_CHROMA}},
{{/REP_CHROMA}}
{{#EDI_MODE}}
    EdiMode="{{EDI_MODE}}",
{{/EDI_MODE}}
{{#NN_SIZE}}
    NNSize={{NN_SIZE}},
{{/NN_SIZE}}
{{#NN_NEURONS}}
    NNeurons={{NN_NEURONS}},
{{/NN_NEURONS}}
{{#EDI_QUAL}}
    EdiQual={{EDI_QUAL}},
{{/EDI_QUAL}}
{{#EDI_MAX_D}}
    EdiMaxD={{EDI_MAX_D}},
{{/EDI_MAX_D}}
{{#CHROMA_EDI}}
    ChromaEdi="{{CHROMA_EDI}}",
{{/CHROMA_EDI}}
{{#BLOCK_SIZE}}
    Blocksize={{BLOCK_SIZE}},
{{/BLOCK_SIZE}}
{{#OVERLAP}}
    Overlap={{OVERLAP}},
{{/OVERLAP}}
{{#SEARCH}}
    Search={{SEARCH}},
{{/SEARCH}}
{{#SEARCH_PARAM}}
    SearchParam={{SEARCH_PARAM}},
{{/SEARCH_PARAM}}
{{#PEL_SEARCH}}
    PelSearch={{PEL_SEARCH}},
{{/PEL_SEARCH}}
{{#CHROMA_MOTION}}
    ChromaMotion={{CHROMA_MOTION}},
{{/CHROMA_MOTION}}
{{#TRUE_MOTION}}
    TrueMotion={{TRUE_MOTION}},
{{/TRUE_MOTION}}
{{#LAMBDA}}
    Lambda={{LAMBDA}},
{{/LAMBDA}}
{{#LSAD}}
    LSAD={{LSAD}},
{{/LSAD}}
{{#P_NEW}}
    PNew={{P_NEW}},
{{/P_NEW}}
{{#P_LEVEL}}
    PLevel={{P_LEVEL}},
{{/P_LEVEL}}
{{#GLOBAL_MOTION}}
    GlobalMotion={{GLOBAL_MOTION}},
{{/GLOBAL_MOTION}}
{{#DCT}}
    DCT={{DCT}},
{{/DCT}}
{{#SUB_PEL}}
    SubPel={{SUB_PEL}},
{{/SUB_PEL}}
{{#SUB_PEL_INTERP}}
    SubPelInterp={{SUB_PEL_INTERP}},
{{/SUB_PEL_INTERP}}
{{#TH_SAD1}}
    ThSAD1={{TH_SAD1}},
{{/TH_SAD1}}
{{#TH_SAD2}}
    ThSAD2={{TH_SAD2}},
{{/TH_SAD2}}
{{#TH_SCD1}}
    ThSCD1={{TH_SCD1}},
{{/TH_SCD1}}
{{#TH_SCD2}}
    ThSCD2={{TH_SCD2}},
{{/TH_SCD2}}
{{#SHARPNESS}}
    Sharpness={{SHARPNESS}},
{{/SHARPNESS}}
{{#S_MODE}}
    SMode={{S_MODE}},
{{/S_MODE}}
{{#SL_MODE}}
    SLMode={{SL_MODE}},
{{/SL_MODE}}
{{#SL_RAD}}
    SLRad={{SL_RAD}},
{{/SL_RAD}}
{{#S_OVS}}
    SOvs={{S_OVS}},
{{/S_OVS}}
{{#SV_THIN}}
    SVThin={{SV_THIN}},
{{/SV_THIN}}
{{#SBB}}
    Sbb={{SBB}},
{{/SBB}}
{{#SRCH_CLIP_PP}}
    SrchClipPP={{SRCH_CLIP_PP}},
{{/SRCH_CLIP_PP}}
{{#NOISE_PROCESS}}
    NoiseProcess={{NOISE_PROCESS}},
{{/NOISE_PROCESS}}
{{#EZ_DENOISE}}
    EZDenoise={{EZ_DENOISE}},
{{/EZ_DENOISE}}
{{#EZ_KEEP_GRAIN}}
    EZKeepGrain={{EZ_KEEP_GRAIN}},
{{/EZ_KEEP_GRAIN}}
{{#NOISE_PRESET}}
    NoisePreset="{{NOISE_PRESET}}",
{{/NOISE_PRESET}}
{{#DENOISER}}
    Denoiser="{{DENOISER}}",
{{/DENOISER}}
{{#FFT_THREADS}}
    FftThreads={{FFT_THREADS}},
{{/FFT_THREADS}}
{{#DENOISE_MC}}
    DenoiseMC={{DENOISE_MC}},
{{/DENOISE_MC}}
{{#NOISE_TR}}
    NoiseTR={{NOISE_TR}},
{{/NOISE_TR}}
{{#SIGMA}}
    Sigma={{SIGMA}},
{{/SIGMA}}
{{#CHROMA_NOISE}}
    ChromaNoise={{CHROMA_NOISE}},
{{/CHROMA_NOISE}}
{{#SHOW_NOISE}}
    ShowNoise={{SHOW_NOISE}},
{{/SHOW_NOISE}}
{{#GRAIN_RESTORE}}
    GrainRestore={{GRAIN_RESTORE}},
{{/GRAIN_RESTORE}}
{{#NOISE_RESTORE}}
    NoiseRestore={{NOISE_RESTORE}},
{{/NOISE_RESTORE}}
{{#NOISE_DEINT}}
    NoiseDeint="{{NOISE_DEINT}}",
{{/NOISE_DEINT}}
{{#STABILIZE_NOISE}}
    StabilizeNoise={{STABILIZE_NOISE}},
{{/STABILIZE_NOISE}}
{{#SOURCE_MATCH}}
    SourceMatch={{SOURCE_MATCH}},
{{/SOURCE_MATCH}}
{{#MATCH_PRESET}}
    MatchPreset="{{MATCH_PRESET}}",
{{/MATCH_PRESET}}
{{#MATCH_EDI}}
    MatchEdi="{{MATCH_EDI}}",
{{/MATCH_EDI}}
{{#MATCH_PRESET2}}
    MatchPreset2="{{MATCH_PRESET2}}",
{{/MATCH_PRESET2}}
{{#MATCH_EDI2}}
    MatchEdi2="{{MATCH_EDI2}}",
{{/MATCH_EDI2}}
{{#MATCH_TR2}}
    MatchTR2={{MATCH_TR2}},
{{/MATCH_TR2}}
{{#MATCH_ENHANCE}}
    MatchEnhance={{MATCH_ENHANCE}},
{{/MATCH_ENHANCE}}
{{#LOSSLESS}}
    Lossless={{LOSSLESS}},
{{/LOSSLESS}}
{{#BORDER}}
    Border={{BORDER}},
{{/BORDER}}
{{#PRECISE}}
    Precise={{PRECISE}},
{{/PRECISE}}
{{#FORCE_TR}}
    ForceTR={{FORCE_TR}},
{{/FORCE_TR}}
{{#OPENCL}}
    opencl={{OPENCL}},
{{/OPENCL}}
{{#DEVICE}}
    device={{DEVICE}},
{{/DEVICE}}
)
{{#DEINT_RESTORE_FORMAT}}
if clip.format.id != _deint_src_format.id:
    clip = core.resize.Bicubic(clip, format=_deint_src_format.id,
                               dither_type="error_diffusion")
{{/DEINT_RESTORE_FORMAT}}
{{/DEINT_QTGMC}}
{{#DEINT_BWDIF}}
# Bwdif — the fast tier. Roughly 4-5x QTGMC Fast on the same clip, for long
# captures where QTGMC's hours are not justified.
#
# Two things measured against the bundled plugin, both negative results and both
# the point:
#   * No format limits at all — 8/9/10/12/16-bit, 4:2:0/4:2:2/4:4:4, GRAY, RGB
#     and even 4:1:1 all pass. Unique among recent additions; no guard needed.
#   * No _FieldBased sensitivity. field=1 and field=3 both work with the
#     property absent, 0, 1 or 2, so it does NOT repeat the znedi3 trap that
#     cost two nightly cycles.
#
# `field` is required, not optional: 0/1 keep the bottom/top field (single
# rate), 2/3 double the rate. The parity half comes from the same field-order
# derivation QTGMC uses, so the two methods cannot disagree about it.
{{#DEINT_BWDIF_EDEINT}}
# An external interpolator. Bwdif accepts one directly, which is why Yadifmod
# is not a separate method: measured, Bwdif+nnedi3 (0.524) beats Yadifmod+nnedi3
# (0.532) at the same cost. EEDI3 here is 11x slower for no gain.
_bwdif_edi = _nnedi3(clip, field={{BWDIF_FIELD}}, dh=False)
clip = core.bwdif.Bwdif(clip, field={{BWDIF_FIELD}}, edeint=_bwdif_edi)
{{/DEINT_BWDIF_EDEINT}}
{{#DEINT_BWDIF_PLAIN}}
clip = core.bwdif.Bwdif(clip, field={{BWDIF_FIELD}})
{{/DEINT_BWDIF_PLAIN}}
{{/DEINT_BWDIF}}
{{#DEINT_IVTC}}
# IVTC Preview: VFM field matching only (no VDecimate for single-frame preview)
# VFM only accepts 8-bit YUV/GRAY. For higher bit-depth sources (e.g. 10-bit
# ProRes 422, yuv422p10le) run the field matching on an 8-bit copy but take the
# output pixels from the full-depth clip via clip2, so no precision is lost.
_ivtc_src = clip
_ivtc_metrics = clip if clip.format.bits_per_sample == 8 else core.resize.Bilinear(clip, format=clip.format.replace(bits_per_sample=8, sample_type=vs.INTEGER))
clip = core.vivtc.VFM(_ivtc_metrics, order={{IVTC_ORDER}},
{{#IVTC_MODE}}
    mode={{IVTC_MODE}},
{{/IVTC_MODE}}
{{#IVTC_CTHRESH}}
    cthresh={{IVTC_CTHRESH}},
{{/IVTC_CTHRESH}}
{{#IVTC_MI}}
    mi={{IVTC_MI}},
{{/IVTC_MI}}
{{#IVTC_BLOCK_X}}
    blockx={{IVTC_BLOCK_X}},
{{/IVTC_BLOCK_X}}
{{#IVTC_BLOCK_Y}}
    blocky={{IVTC_BLOCK_Y}},
{{/IVTC_BLOCK_Y}}
    clip2=_ivtc_src)
{{/DEINT_IVTC}}
{{/DEINTERLACE}}

# ============================================================================
# PASS 3: DESCRATCH (scratch removal)
# ============================================================================
# PASS 1c: EDGE REPAIR / GHOST REMOVAL
# ============================================================================
{{#EDGE_REPAIR}}
# Rebuild the dirty rows and columns tape captures leave at the frame border.
# Must precede every spatial filter, or denoising and sharpening smear the bad
# rows inward, and must precede the resize, or resampling spreads them.
#
# Widths are always even. The bundle pins FillBorders v2 (the newest tag with
# published binaries), and v2 is bit-identical to v4 at even widths — they
# differ only at odd widths, where v2 leaves subsampled chroma unrepaired.
#
# interlaced=-1 reads _FieldBased, so a clip whose field order this pipeline
# knows is handled per-field without a second control.
clip = core.fb.FillBorders(
    clip,
    left={{ER_LEFT}}, right={{ER_RIGHT}}, top={{ER_TOP}}, bottom={{ER_BOTTOM}},
    mode="{{ER_MODE}}",
    interlaced=-1,
)
{{/EDGE_REPAIR}}
{{#GHOST_REMOVAL}}
# Cancel the displaced echo RF and cable distribution leave behind. Each ghost
# is a (mode, shift, intensity) triple and the three arrays must be the same
# length — the worker drops any entry the plugin would reject rather than
# letting it fail at script evaluation.
#
# No format limits were found for this plugin at any depth or subsampling, so
# there is no guard. `opt` is deliberately not passed: on arm64 every value
# produces byte-identical output, so it is inert here and a footgun on x86.
clip = core.lghost.LGhost(
    clip,
    mode={{LG_MODE}},
    shift={{LG_SHIFT}},
    intensity={{LG_INTENSITY}},
)
{{/GHOST_REMOVAL}}

# ============================================================================
# PASS 1b: DEFLICKER
# ============================================================================
{{#DEFLICKER}}
# Even out brightness pulsing. Runs after deinterlacing — field-doubled frames
# break every temporal comparison this makes — and before the dirt and denoise
# passes, which all assume a stable exposure.
import sys as _dfl_sys
_dfl_sys.path.insert(0, r"{{PIPE_SOURCE_DIR}}")
import deflicker as _deflicker
{{#DEFLICKER_GLOBAL}}
# Whole-frame exposure correction: fits a gain AND an offset per frame against a
# windowed neighbourhood average. Measured 83.5% of injected flicker removed.
# Both terms are fitted because neither alone works on every fault: gain-only
# manages 46% on additive flicker, offset-only 46% on multiplicative.
clip = _deflicker.global_deflicker(clip, strength={{DEFLICKER_STRENGTH}}, window={{DEFLICKER_WINDOW}})
{{/DEFLICKER_GLOBAL}}
{{#DEFLICKER_LOCAL}}
# Local oscillation damper, for flicker that varies across the frame — which a
# whole-frame statistic cannot represent. Transcribed from the ReduceFlicker
# algorithm rather than using the plugin: its non-SIMD path reads the wrong
# neighbour frame and aarch64 has no other path, so the ARM bundles would
# render differently from x86.
clip = _deflicker.reduce_flicker(clip, strength={{DEFLICKER_LOCAL_STRENGTH}}, aggressive={{DEFLICKER_AGGRESSIVE}})
{{/DEFLICKER_LOCAL}}
{{/DEFLICKER}}

# ============================================================================
{{#DESCRATCH}}
# DeScratch - remove vertical scratches from film
# DeScratch only supports 8-bit YUV (YV12/YV16/YV24) - convert if needed
_descratch_orig_format = clip.format
if clip.format.bits_per_sample != 8:
    clip = core.resize.Bilinear(clip, format=clip.format.replace(bits_per_sample=8, sample_type=vs.INTEGER))
clip = core.descratch.DeScratch(
    clip,
{{#DESCRATCH_MINDIF}}
    mindif={{DESCRATCH_MINDIF}},
{{/DESCRATCH_MINDIF}}
{{#DESCRATCH_ASYM}}
    asym={{DESCRATCH_ASYM}},
{{/DESCRATCH_ASYM}}
{{#DESCRATCH_MAXGAP}}
    maxgap={{DESCRATCH_MAXGAP}},
{{/DESCRATCH_MAXGAP}}
{{#DESCRATCH_MAXWIDTH}}
    maxwidth={{DESCRATCH_MAXWIDTH}},
{{/DESCRATCH_MAXWIDTH}}
{{#DESCRATCH_MINWIDTH}}
    minwidth={{DESCRATCH_MINWIDTH}},
{{/DESCRATCH_MINWIDTH}}
{{#DESCRATCH_MINLEN}}
    minlen={{DESCRATCH_MINLEN}},
{{/DESCRATCH_MINLEN}}
{{#DESCRATCH_MAXLEN}}
    maxlen={{DESCRATCH_MAXLEN}},
{{/DESCRATCH_MAXLEN}}
{{#DESCRATCH_MAXANGLE}}
    maxangle={{DESCRATCH_MAXANGLE}},
{{/DESCRATCH_MAXANGLE}}
{{#DESCRATCH_BLURLEN}}
    blurlen={{DESCRATCH_BLURLEN}},
{{/DESCRATCH_BLURLEN}}
{{#DESCRATCH_KEEP}}
    keep={{DESCRATCH_KEEP}},
{{/DESCRATCH_KEEP}}
{{#DESCRATCH_BORDER}}
    border={{DESCRATCH_BORDER}},
{{/DESCRATCH_BORDER}}
{{#DESCRATCH_MODEY}}
    modey={{DESCRATCH_MODEY}},
{{/DESCRATCH_MODEY}}
{{#DESCRATCH_MODEU}}
    modeu={{DESCRATCH_MODEU}},
{{/DESCRATCH_MODEU}}
{{#DESCRATCH_MODEV}}
    modev={{DESCRATCH_MODEV}},
{{/DESCRATCH_MODEV}}
{{#DESCRATCH_MINDIFUV}}
    mindifuv={{DESCRATCH_MINDIFUV}},
{{/DESCRATCH_MINDIFUV}}
)
# Restore original bit depth if we converted down
if _descratch_orig_format.bits_per_sample != 8:
    clip = core.resize.Bilinear(clip, format=_descratch_orig_format)
{{/DESCRATCH}}

# ============================================================================
# PASS 4: SPOTLESS (temporal spot/dirt removal)
# ============================================================================
{{#SPOTLESS}}
{{#SPOTLESS_CLASSIC}}
import sys as _spotless_sys
_spotless_sys.path.insert(0, r"{{PIPE_SOURCE_DIR}}")
from spotless import SpotLess as _SpotLess
clip = _SpotLess(
    clip,
{{#SPOTLESS_CHROMA}}
    chroma={{SPOTLESS_CHROMA}},
{{/SPOTLESS_CHROMA}}
{{#SPOTLESS_REC}}
    rec={{SPOTLESS_REC}},
{{/SPOTLESS_REC}}
{{#SPOTLESS_BLKSIZE}}
    blksize={{SPOTLESS_BLKSIZE}},
{{/SPOTLESS_BLKSIZE}}
{{#SPOTLESS_OVERLAP}}
    overlap={{SPOTLESS_OVERLAP}},
{{/SPOTLESS_OVERLAP}}
{{#SPOTLESS_PEL}}
    pel={{SPOTLESS_PEL}},
{{/SPOTLESS_PEL}}
)
{{/SPOTLESS_CLASSIC}}
{{#SPOTLESS_REMOVEDIRT}}
# RemoveDirt — the fast alternative to SpotLess. Measured 908 fps against
# SpotLess's 143 for about 60% of the spot removal, which is the entire reason
# it is here: on a long capture SpotLess takes hours. The motion-compensated
# variant is deliberately NOT offered — measured, it lands on the same quality
# point as SpotLess and runs slower, so it adds nothing.
import sys as _rd_sys
_rd_sys.path.insert(0, r"{{PIPE_SOURCE_DIR}}")
from removedirt import remove_dirt as _remove_dirt
clip = _remove_dirt(
    clip,
    gmthreshold={{RD_GMTHRESHOLD}},
    noise={{RD_NOISE}},
    noisy={{RD_NOISY}},
    dist={{RD_DIST}},
    post_denoise={{RD_POST_DENOISE}},
)
{{/SPOTLESS_REMOVEDIRT}}
{{/SPOTLESS}}

# ============================================================================
# PASS 5: NOISE REDUCTION
# ============================================================================
{{#NOISE_REDUCTION}}
{{#NR_POST_CONTRASHARP}}
# ContraSharpening needs BOTH the pre- and post-denoise clip, so it cannot sit
# in the linear pass chain like a Sharpen method — it has to bracket the
# denoise. Capture the input here.
_nr_presharp_src = clip
{{/NR_POST_CONTRASHARP}}
import mvsfunc as mvf

{{#NR_SMDEGRAIN}}
# SMDegrain noise reduction
clip = haf.SMDegrain(
    clip,
{{#NR_TR}}
    tr={{NR_TR}},
{{/NR_TR}}
{{#NR_TH_SAD}}
    thSAD={{NR_TH_SAD}},
{{/NR_TH_SAD}}
{{#NR_TH_SADC}}
    thSADC={{NR_TH_SADC}},
{{/NR_TH_SADC}}
{{#NR_REFINE_MOTION}}
    RefineMotion={{NR_REFINE_MOTION}},
{{/NR_REFINE_MOTION}}
{{#NR_PREFILTER}}
    prefilter={{NR_PREFILTER}},
{{/NR_PREFILTER}}
{{#NR_CONTRASHARP}}
    contrasharp={{NR_CONTRASHARP}},
{{/NR_CONTRASHARP}}
)
{{/NR_SMDEGRAIN}}

{{#NR_MCTD}}
# MCTemporalDenoise noise reduction
clip = haf.MCTemporalDenoise(
    clip,
{{#NR_SIGMA}}
    sigma={{NR_SIGMA}},
{{/NR_SIGMA}}
{{#NR_RADIUS}}
    radius={{NR_RADIUS}},
{{/NR_RADIUS}}
)
{{/NR_MCTD}}

{{#NR_DFTTEST}}
# DFTTest — frequency-domain denoiser. See pipeline_template.vpy; the two must
# stay in step or the preview shows a different picture from the render.
clip = core.dfttest.DFTTest(
    clip,
    sigma={{NR_DFTTEST_SIGMA}},
    tbsize={{NR_DFTTEST_TBSIZE}},
    sbsize={{NR_DFTTEST_SBSIZE}},
)
{{/NR_DFTTEST}}

{{#NR_FFT3D}}
# FFT3DFilter — classic 3D FFT spatio-temporal denoiser.
clip = core.fft3dfilter.FFT3DFilter(
    clip,
    sigma={{NR_FFT3D_SIGMA}},
    bt={{NR_FFT3D_BT}},
{{#NR_FFT3D_SHARPEN}}
    sharpen={{NR_FFT3D_SHARPEN}},
{{/NR_FFT3D_SHARPEN}}
)
{{/NR_FFT3D}}

{{#NR_TTEMPSMOOTH}}
# TTempSmooth — motion-adaptive temporal smoother. `mdiff` is held below
# `thresh` by the worker.
clip = core.ttmpsm.TTempSmooth(
    clip,
    maxr={{NR_TTEMP_MAXR}},
    thresh={{NR_TTEMP_THRESH}},
    mdiff={{NR_TTEMP_MDIFF}},
    strength={{NR_TTEMP_STRENGTH}},
)
{{/NR_TTEMPSMOOTH}}

{{#NR_FLUXSMOOTH_T}}
# FluxSmoothT - averages each pixel with its temporal neighbours, but ONLY where
# they bracket it in value (one above, one below). Motion is therefore left
# alone almost for free, which is why it is a common first pass on tape.
clip = core.flux.SmoothT(
    clip,
    temporal_threshold={{NR_FLUX_TEMPORAL}},
)
{{/NR_FLUXSMOOTH_T}}

{{#NR_FLUXSMOOTH_ST}}
# FluxSmoothST - as SmoothT plus the eight spatial neighbours. Stronger, and a
# little more willing to soften detail.
clip = core.flux.SmoothST(
    clip,
    temporal_threshold={{NR_FLUX_TEMPORAL}},
    spatial_threshold={{NR_FLUX_SPATIAL}},
)
{{/NR_FLUXSMOOTH_ST}}

{{#NR_STPRESSO}}
# STPresso (havsfunc) - limits how far any pixel may move from its original
# value, so detail survives almost intact. Calls core.flux.SmoothT internally,
# which is why the fluxsmooth plugin is a hard requirement for this method.
clip = haf.STPresso(
    clip,
    limit={{NR_STPRESSO_LIMIT}},
    bias={{NR_STPRESSO_BIAS}},
    tthr={{NR_STPRESSO_TTHR}},
)
{{/NR_STPRESSO}}

{{#NR_CTMF}}
# CTMF - constant-time median filter. A large-radius median for blotches and
# impulse noise, at a cost that barely moves with radius (measured: radius 1 to
# 127 is about 20% apart).
#
# Two guards, both measured against the bundle rather than assumed:
#
#  - 9-BIT IS REJECTED outright ("only constant format 8, 10, 12, 14, 16 bit
#    integer ... supported"), and 9-bit is reachable here: pixel_format.rs rounds
#    an odd source depth up through [8, 9, 10, 12, 14, 16] and pipe_source maps
#    yuv420p9le. So a 9-bit clip is lifted to 10-bit and restored after.
#  - memsize is pinned to 16 MiB. At the plugin's 1 MiB default, 16-bit radius 3
#    runs at 0.79 fps against 42 fps with this value — a 40x cliff — for
#    BIT-IDENTICAL output.
_ctmf_src_format = clip.format
if clip.format.bits_per_sample == 9:
    clip = core.resize.Point(clip, format=clip.format.replace(
        bits_per_sample=10, sample_type=vs.INTEGER).id)
clip = core.ctmf.CTMF(
    clip,
    radius={{NR_CTMF_RADIUS}},
    planes={{NR_CTMF_PLANES}},
    memsize=16777216,
)
if _ctmf_src_format.bits_per_sample == 9:
    clip = core.resize.Point(clip, format=_ctmf_src_format.id)
{{/NR_CTMF}}

{{#NR_MCDEGRAINSHARP}}
# MCDegrainSharp (Didée) — motion-compensated degrain that sharpens where the
# motion match is good and blurs where it is poor.
#
# Three clips do the work: a blurred one is what gets averaged (so badly-matched
# areas end up soft rather than smeared with wrong pixels), a sharpened one
# supplies the pixels the averaging draws from (so well-matched areas come back
# sharper than the source), and the motion search runs on the blurred clip when
# asked, which finds steadier vectors on a noisy source.
_mcds_planes = {{NR_MCDS_PLANES}}
_mcds_blurred = core.tcanny.TCanny(clip, sigma={{NR_MCDS_BLUR_SIGMA}}, mode=-1, planes=_mcds_planes)
# Unsharp mask: original plus the difference between it and its own blur.
_mcds_sharpened = _expr(
    [clip, core.tcanny.TCanny(clip, sigma={{NR_MCDS_SHARP_SIGMA}}, mode=-1, planes=_mcds_planes)],
    ['x x + y -'],
)
# Larger blocks for HD; 8 is the classic SD value.
_mcds_blksize = 16 if clip.width > 960 else 8
_mcds_super_search = core.mv.Super({{NR_MCDS_SEARCH_CLIP}}, pel=2, sharp=1)
_mcds_super_render = core.mv.Super(_mcds_sharpened, pel=2, sharp=1, levels=1)


def _mcds_vectors(delta, backward):
    return core.mv.Analyse(
        _mcds_super_search,
        isb=backward,
        delta=delta,
        blksize=_mcds_blksize,
        overlap=_mcds_blksize // 2,
    )

{{#NR_MCDS_DEGRAIN1}}
clip = core.mv.Degrain1(
    clip=_mcds_blurred,
    super=_mcds_super_render,
    mvbw=_mcds_vectors(1, True),
    mvfw=_mcds_vectors(1, False),
    thsad={{NR_MCDS_TH_SAD}},
    plane={{NR_MCDS_PLANE}},
)
{{/NR_MCDS_DEGRAIN1}}
{{#NR_MCDS_DEGRAIN2}}
clip = core.mv.Degrain2(
    clip=_mcds_blurred,
    super=_mcds_super_render,
    mvbw=_mcds_vectors(1, True),
    mvfw=_mcds_vectors(1, False),
    mvbw2=_mcds_vectors(2, True),
    mvfw2=_mcds_vectors(2, False),
    thsad={{NR_MCDS_TH_SAD}},
    plane={{NR_MCDS_PLANE}},
)
{{/NR_MCDS_DEGRAIN2}}
{{#NR_MCDS_DEGRAIN3}}
clip = core.mv.Degrain3(
    clip=_mcds_blurred,
    super=_mcds_super_render,
    mvbw=_mcds_vectors(1, True),
    mvfw=_mcds_vectors(1, False),
    mvbw2=_mcds_vectors(2, True),
    mvfw2=_mcds_vectors(2, False),
    mvbw3=_mcds_vectors(3, True),
    mvfw3=_mcds_vectors(3, False),
    thsad={{NR_MCDS_TH_SAD}},
    plane={{NR_MCDS_PLANE}},
)
{{/NR_MCDS_DEGRAIN3}}
{{/NR_MCDEGRAINSHARP}}

{{#NR_BM3D}}
# BM3D noise reduction
clip = mvf.BM3D(
    clip,
{{#NR_BM3D_SIGMA}}
    sigma={{NR_BM3D_SIGMA}},
{{/NR_BM3D_SIGMA}}
{{#NR_BM3D_RADIUS}}
    radius={{NR_BM3D_RADIUS}},
{{/NR_BM3D_RADIUS}}
)
{{/NR_BM3D}}
{{#NR_POST_CONTRASHARP}}
# Give back the fine detail the denoiser removed, by adding back only the
# high-frequency difference that survives a Repair against the original. This
# is the standard companion to a strong denoise, and unlike a plain sharpener it
# cannot introduce detail that was not there before.
#
# No depth scaling needed: its only constant is derived from clip.format.
clip = haf.ContraSharpening(clip, _nr_presharp_src, rep={{NR_POST_CONTRASHARP_REP}})
{{/NR_POST_CONTRASHARP}}
{{/NOISE_REDUCTION}}

# ============================================================================
# PASS 5b: CHROMA DENOISE (CCD - Camcorder Colour Denoise)
# ============================================================================
{{#CHROMA_DENOISE}}
{{#CHROMA_DENOISE_CCD}}
# CCD averages chroma over neighbours whose RGB distance is within `threshold`,
# leaving luma untouched — the standard fix for the blotchy colour noise on VHS
# captures and old camcorder footage.
#
# `scale` is a sampling-radius multiplier that CCD derives from the frame height,
# because the original filter was written for 240p. The plugin REJECTS a scale
# below 1.0, so on anything shorter than its reference height the automatic value
# fails the job with "CCD: scale must be greater than or equal to 1.0" (measured:
# 352x288 and 320x240 both fail, 640x480 and up are fine). Deriving it here with
# a floor keeps small and cropped sources working, and matches what the plugin
# would have picked otherwise.
{{#CCD_SCALE_AUTO}}
_ccd_scale = max(1.0, clip.height / {{CCD_REFERENCE_HEIGHT}}.0)
{{/CCD_SCALE_AUTO}}
{{#CCD_SCALE_EXPLICIT}}
_ccd_scale = {{CCD_SCALE}}
{{/CCD_SCALE_EXPLICIT}}
clip = core.zsmooth.CCD(
    clip,
    threshold={{CCD_THRESHOLD}},
    temporal_radius={{CCD_TEMPORAL_RADIUS}},
    points={{CCD_POINTS}},
    scale=_ccd_scale,
)
{{/CHROMA_DENOISE_CCD}}
{{#CHROMA_DENOISE_CNR4}}
# Cnr4 — temporal chroma denoise, gated on luma motion. A different failure mode
# from CCD: it targets chroma that swims or shimmers frame to frame rather than
# blotches that sit still, so the two are complementary rather than alternatives.
#
# TWO TRAPS, both measured against the bundled plugin:
#
# 1. `scenechange` defaults to True and REQUIRES the _SceneChangePrev/Next frame
#    properties, which this pipeline never sets. A bare Cnr4(clip) therefore
#    fails 100% of jobs on every platform with "Scene change handling enabled,
#    but input frame is missing scene change properties". misc.SCDetect supplies
#    them, and is the better answer than scenechange=False because it is what
#    stops the filter smearing chroma across a cut.
#
# 2. It rejects 4:1:1 outright ("must be integer YUV420, YUV422, YUV440, or
#    YUV444"), and 4:1:1 is NTSC DV, which pipe_source maps natively. Convert
#    up to 4:2:2 and restore afterwards, as DeScratch does for bit depth.
_cnr4_src_format = clip.format.id
if clip.format.subsampling_w == 2:
    clip = core.resize.Bicubic(clip, format=vs.YUV422P8 if clip.format.bits_per_sample == 8 else vs.YUV422P16)
clip = core.misc.SCDetect(clip)
clip = core.zsmooth.Cnr4(
    clip,
    sense={{CNR4_SENSE}},
    str={{CNR4_STRENGTH}},
    radius={{CNR4_RADIUS}},
    tmode={{CNR4_TMODE}},
    wmode={{CNR4_WMODE}},
)
if clip.format.id != _cnr4_src_format:
    clip = core.resize.Bicubic(clip, format=_cnr4_src_format)
{{/CHROMA_DENOISE_CNR4}}
{{/CHROMA_DENOISE}}

# ============================================================================
# PASS 4: DEHALO
# ============================================================================
{{#DEHALO}}

{{#DEHALO_DEHALO_ALPHA}}
# DeHalo_alpha - general purpose halo removal
clip = haf.DeHalo_alpha(
    clip,
{{#DEHALO_RX}}
    rx={{DEHALO_RX}},
{{/DEHALO_RX}}
{{#DEHALO_RY}}
    ry={{DEHALO_RY}},
{{/DEHALO_RY}}
{{#DEHALO_DARKSTR}}
    darkstr={{DEHALO_DARKSTR}},
{{/DEHALO_DARKSTR}}
{{#DEHALO_BRIGHTSTR}}
    brightstr={{DEHALO_BRIGHTSTR}},
{{/DEHALO_BRIGHTSTR}}
{{#DEHALO_LOWSENS}}
    lowsens={{DEHALO_LOWSENS}},
{{/DEHALO_LOWSENS}}
{{#DEHALO_HIGHSENS}}
    highsens={{DEHALO_HIGHSENS}},
{{/DEHALO_HIGHSENS}}
{{#DEHALO_SS}}
    ss={{DEHALO_SS}},
{{/DEHALO_SS}}
)
{{/DEHALO_DEHALO_ALPHA}}

{{#DEHALO_FINE_DEHALO}}
# FineDehalo - more precise halo removal with edge preservation
clip = haf.FineDehalo(
    clip,
{{#DEHALO_RX}}
    rx={{DEHALO_RX}},
{{/DEHALO_RX}}
{{#DEHALO_RY}}
    ry={{DEHALO_RY}},
{{/DEHALO_RY}}
{{#DEHALO_DARKSTR}}
    darkstr={{DEHALO_DARKSTR}},
{{/DEHALO_DARKSTR}}
{{#DEHALO_BRIGHTSTR}}
    brightstr={{DEHALO_BRIGHTSTR}},
{{/DEHALO_BRIGHTSTR}}
{{#DEHALO_LOW_THRESHOLD}}
    thmi={{DEHALO_LOW_THRESHOLD}},
{{/DEHALO_LOW_THRESHOLD}}
{{#DEHALO_HIGH_THRESHOLD}}
    thma={{DEHALO_HIGH_THRESHOLD}},
{{/DEHALO_HIGH_THRESHOLD}}
{{#DEHALO_THLIMI}}
    thlimi={{DEHALO_THLIMI}},
{{/DEHALO_THLIMI}}
{{#DEHALO_THLIMA}}
    thlima={{DEHALO_THLIMA}},
{{/DEHALO_THLIMA}}
{{#DEHALO_CONTRA}}
    contra={{DEHALO_CONTRA}},
{{/DEHALO_CONTRA}}
{{#DEHALO_EXCL}}
    excl={{DEHALO_EXCL}},
{{/DEHALO_EXCL}}
{{#DEHALO_EDGEPROC}}
    edgeproc={{DEHALO_EDGEPROC}},
{{/DEHALO_EDGEPROC}}
)
{{/DEHALO_FINE_DEHALO}}

{{#DEHALO_FINE_DEHALO2}}
# FineDehalo2 - removes the ringing FineDehalo leaves on sharp edges.
# Takes only convolution kernels beyond the defaults, so it has no parameters.
clip = haf.FineDehalo2(clip)
{{/DEHALO_FINE_DEHALO2}}

{{#DEHALO_YAHR}}
# YAHR - Yet Another Halo Remover
clip = haf.YAHR(
    clip,
{{#DEHALO_YAHR_BLUR}}
    blur={{DEHALO_YAHR_BLUR}},
{{/DEHALO_YAHR_BLUR}}
{{#DEHALO_YAHR_DEPTH}}
    depth={{DEHALO_YAHR_DEPTH}},
{{/DEHALO_YAHR_DEPTH}}
)
{{/DEHALO_YAHR}}

{{#DEHALO_EDGE_CLEANER}}
# EdgeCleaner - edge denoising and weak dehaloing (aWarpSharp2)
clip = haf.EdgeCleaner(
    clip,
{{#DEHALO_EDGE_STRENGTH}}
    strength={{DEHALO_EDGE_STRENGTH}},
{{/DEHALO_EDGE_STRENGTH}}
{{#DEHALO_EDGE_REPAIR}}
    rep={{DEHALO_EDGE_REPAIR}},
{{/DEHALO_EDGE_REPAIR}}
{{#DEHALO_EDGE_RMODE}}
    rmode={{DEHALO_EDGE_RMODE}},
{{/DEHALO_EDGE_RMODE}}
{{#DEHALO_EDGE_SMODE}}
    smode={{DEHALO_EDGE_SMODE}},
{{/DEHALO_EDGE_SMODE}}
{{#DEHALO_EDGE_HOT}}
    hot={{DEHALO_EDGE_HOT}},
{{/DEHALO_EDGE_HOT}}
)
{{/DEHALO_EDGE_CLEANER}}

{{#DEHALO_VINVERSE}}
# Vinverse - removes vertical comb/ghost residue left by deinterlacing.
# It blurs vertically, so run it on progressive (already deinterlaced) frames.
clip = haf.{{DEHALO_VINVERSE_FN}}(
    clip,
{{#DEHALO_VINVERSE_SSTR}}
    sstr={{DEHALO_VINVERSE_SSTR}},
{{/DEHALO_VINVERSE_SSTR}}
{{#DEHALO_VINVERSE_AMNT}}
    amnt={{DEHALO_VINVERSE_AMNT}},
{{/DEHALO_VINVERSE_AMNT}}
{{#DEHALO_VINVERSE_CHROMA}}
    chroma={{DEHALO_VINVERSE_CHROMA}},
{{/DEHALO_VINVERSE_CHROMA}}
)
{{/DEHALO_VINVERSE}}
{{#DEHALO_HQDERING}}
# HQDeringmod - masked ring removal. Targets the overshoot immediately beside an
# edge while a mask protects the edge itself, which is a narrower target than
# dehalo's wider bright band. Every argument is optional so havsfunc's own
# defaults apply where the user hasn't chosen.
clip = haf.HQDeringmod(
    clip,
{{#DEHALO_DERING_MRAD}}
    mrad={{DEHALO_DERING_MRAD}},
{{/DEHALO_DERING_MRAD}}
{{#DEHALO_DERING_MSMOOTH}}
    msmooth={{DEHALO_DERING_MSMOOTH}},
{{/DEHALO_DERING_MSMOOTH}}
{{#DEHALO_DERING_MTHR}}
    mthr={{DEHALO_DERING_MTHR}},
{{/DEHALO_DERING_MTHR}}
{{#DEHALO_DERING_THR}}
    thr={{DEHALO_DERING_THR}},
{{/DEHALO_DERING_THR}}
{{#DEHALO_DERING_DARKTHR}}
    darkthr={{DEHALO_DERING_DARKTHR}},
{{/DEHALO_DERING_DARKTHR}}
)
{{/DEHALO_HQDERING}}
{{/DEHALO}}

# ============================================================================
# PASS 5: DEBLOCK
# ============================================================================
{{#DEBLOCK}}

{{#DEBLOCK_QED}}
# Deblock_QED - Quality Enhanced Deblocking
clip = haf.Deblock_QED(
    clip,
{{#DEBLOCK_QUANT1}}
    quant1={{DEBLOCK_QUANT1}},
{{/DEBLOCK_QUANT1}}
{{#DEBLOCK_QUANT2}}
    quant2={{DEBLOCK_QUANT2}},
{{/DEBLOCK_QUANT2}}
{{#DEBLOCK_AOFFSET1}}
    aOff1={{DEBLOCK_AOFFSET1}},
{{/DEBLOCK_AOFFSET1}}
{{#DEBLOCK_AOFFSET2}}
    aOff2={{DEBLOCK_AOFFSET2}},
{{/DEBLOCK_AOFFSET2}}
)
{{/DEBLOCK_QED}}

{{#DEBLOCK_SIMPLE}}
# Simple deblocking using Deblock plugin
clip = core.deblock.Deblock(
    clip,
{{#DEBLOCK_QUANT1}}
    quant={{DEBLOCK_QUANT1}},
{{/DEBLOCK_QUANT1}}
)
{{/DEBLOCK_SIMPLE}}
{{#DEBLOCK_DCTFILTER}}
# DCTFilter - attenuates chosen DCT frequency bands directly. A scalpel for
# ringing and mosquito noise, which the two block-edge deblockers do not touch.
#
# The eight factors are applied SEPARABLY: coefficient (u, v) is scaled by
# factors[u] * factors[v] — measured against the bundle, not the max(u, v) the
# Avisynth filter of the same name uses. So a band affects a whole row and
# column. The worker builds the curve from a cutoff and a strength rather than
# exposing eight raw sliders, and guarantees every value is finite: DCTFilter's
# own range check lets NaN through and a NaN factor silently blackens the frame.
clip = core.dctf.DCTFilter(
    clip,
    factors={{DEBLOCK_DCT_FACTORS}},
    planes={{DEBLOCK_DCT_PLANES}},
)
{{/DEBLOCK_DCTFILTER}}
{{/DEBLOCK}}

# ============================================================================
# PASS 6: DEBAND (f3kdb)
# ============================================================================
{{#DEBAND}}
# neo_f3kdb - remove banding artifacts
clip = core.neo_f3kdb.Deband(
    clip,
{{#DEBAND_RANGE}}
    range={{DEBAND_RANGE}},
{{/DEBAND_RANGE}}
{{#DEBAND_Y}}
    y={{DEBAND_Y}},
{{/DEBAND_Y}}
{{#DEBAND_CB}}
    cb={{DEBAND_CB}},
{{/DEBAND_CB}}
{{#DEBAND_CR}}
    cr={{DEBAND_CR}},
{{/DEBAND_CR}}
{{#DEBAND_GRAINY}}
    grainy={{DEBAND_GRAINY}},
{{/DEBAND_GRAINY}}
{{#DEBAND_GRAINC}}
    grainc={{DEBAND_GRAINC}},
{{/DEBAND_GRAINC}}
{{#DEBAND_DYNAMIC_GRAIN}}
    dynamic_grain={{DEBAND_DYNAMIC_GRAIN}},
{{/DEBAND_DYNAMIC_GRAIN}}
{{#DEBAND_OUTPUT_DEPTH}}
    output_depth={{DEBAND_OUTPUT_DEPTH}},
{{/DEBAND_OUTPUT_DEPTH}}
)
{{/DEBAND}}

# ============================================================================
# PASS: ANTI-ALIASING
# ============================================================================
{{#ANTI_ALIAS}}
# znedi3's double-rate mode requires the _FieldBased frame property and fails
# with "znedi3: _FieldBased" when it is absent, which is what havsfunc's daa
# uses (field=3). See pipeline_template.vpy for the measurements; must stay in
# step with it, or a preview fails where the encode succeeds.
clip = core.std.SetFieldBased(clip, {{AA_FIELD_BASED_VALUE}})
{{#AA_DAA}}
# daa - double-rate anti-aliasing. Interpolates both fields with nnedi3 and
# averages them, so a stair-stepped diagonal is rebuilt rather than blurred.
# The gentler of the two methods and the usual choice.
clip = haf.daa(clip)
{{/AA_DAA}}

{{#AA_SANTIAG}}
# santiag - stronger anti-aliasing with independent horizontal and vertical
# strength, so it can be aimed at one axis. `type` is pinned to nnedi3: havsfunc
# also accepts eedi2 and sangnom, neither of which is in the deps bundle, and
# naming an absent one fails at script evaluation with a bare "no attribute".
clip = haf.santiag(
    clip,
    strh={{AA_STRH}},
    strv={{AA_STRV}},
    type="{{AA_TYPE}}",
)
{{/AA_SANTIAG}}
{{/ANTI_ALIAS}}

# ============================================================================
# PASS 7: SHARPEN
# ============================================================================
{{#SHARPEN}}

{{#SHARPEN_LSFMOD}}
# LSFmod - Limited Sharpening with overshoot control
clip = haf.LSFmod(
    clip,
{{#SHARPEN_STRENGTH}}
    strength={{SHARPEN_STRENGTH}},
{{/SHARPEN_STRENGTH}}
{{#SHARPEN_OVERSHOOT}}
    overshoot={{SHARPEN_OVERSHOOT}},
{{/SHARPEN_OVERSHOOT}}
{{#SHARPEN_UNDERSHOOT}}
    undershoot={{SHARPEN_UNDERSHOOT}},
{{/SHARPEN_UNDERSHOOT}}
{{#SHARPEN_SOFT_EDGE}}
    soft={{SHARPEN_SOFT_EDGE}},
{{/SHARPEN_SOFT_EDGE}}
)
{{/SHARPEN_LSFMOD}}

{{#SHARPEN_CAS}}
# CAS - Contrast Adaptive Sharpening
clip = core.cas.CAS(
    clip,
{{#SHARPEN_CAS_SHARPNESS}}
    sharpness={{SHARPEN_CAS_SHARPNESS}},
{{/SHARPEN_CAS_SHARPNESS}}
)
{{/SHARPEN_CAS}}
{{#SHARPEN_AWARPSHARP2}}
# aWarpSharp2 - sharpens by warping pixels toward edges rather than raising
# local contrast, so it produces no halos.
#
# `chroma` and `planes` are deliberately not passed. This VapourSynth port takes
# chroma as 0 or 1 (NOT Avisynth's 0-6, where 4 means "warp chroma with the luma
# mask") and rejects anything else outright, and by default it processes luma
# only — the conventional use as a sharpener. Passing a guessed value here is how
# this block first shipped broken; expose it deliberately, with a test, or leave
# the plugin's own default alone.
clip = core.warp.AWarpSharp2(
    clip,
    thresh={{SHARPEN_WARP_THRESH}},
    blur={{SHARPEN_WARP_BLUR}},
    type={{SHARPEN_WARP_TYPE}},
    depth={{SHARPEN_WARP_DEPTH}},
)
{{/SHARPEN_AWARPSHARP2}}
{{/SHARPEN}}

# ============================================================================
# PASS 8: CHROMA FIXES
# ============================================================================
{{#CHROMA_FIXES}}

def _dedot_8bit_format(c):
    """The clip's own layout at 8 bits — DeDot is 8-bit only."""
    return core.get_video_format(c.format.id).replace(bits_per_sample=8).id

{{#CF_DEDOT}}
# DeDot — temporal dot crawl and rainbow removal, working on BOTH planes and
# skipping moving objects. Complementary to LUTDeCrawl rather than a
# replacement: measured on a line-alternating crawl pattern, LUTDeCrawl reached
# 0.00 residual where DeDot left 11.69, while on a phase-inverting checkerboard
# DeDot reached 0.24/0.00 (luma/chroma) where LUTDeCrawl left chroma untouched.
# Different geometries, so both are worth having.
#
# 8-bit only: "the input clip must be 8 bit YUV or Gray with constant format and
# dimensions", measured failing at 10/12/16-bit on both 4:2:0 and 4:2:2. Same
# convert-down-and-restore guard as DeScratch and BiFrost.
_dedot_src_format = clip.format.id
if clip.format.bits_per_sample != 8:
    clip = core.resize.Bicubic(clip, format=_dedot_8bit_format(clip))
clip = core.dedot.Dedot(
    clip,
    luma_2d={{DEDOT_LUMA_2D}},
    luma_t={{DEDOT_LUMA_T}},
    chroma_t1={{DEDOT_CHROMA_T1}},
    chroma_t2={{DEDOT_CHROMA_T2}},
)
if clip.format.id != _dedot_src_format:
    clip = core.resize.Bicubic(clip, format=_dedot_src_format, dither_type="error_diffusion")
{{/CF_DEDOT}}

{{#CHROMA_SHIFT}}
# Chroma Shift (Y/C Delay) - shift chroma planes to correct timing misalignment
_shift_h = {{CHROMA_SHIFT_H}}
_shift_v = {{CHROMA_SHIFT_V}}
_sub_w = clip.format.subsampling_w
_sub_h = clip.format.subsampling_h
_chroma_h = _shift_h / (1 << _sub_w) if _sub_w > 0 else _shift_h
_chroma_v = _shift_v / (1 << _sub_h) if _sub_h > 0 else _shift_v
_y = core.std.ShufflePlanes(clip, 0, vs.GRAY)
_u = core.std.ShufflePlanes(clip, 1, vs.GRAY)
_v = core.std.ShufflePlanes(clip, 2, vs.GRAY)
_u = core.resize.Spline36(_u, src_left=_chroma_h, src_top=_chroma_v)
_v = core.resize.Spline36(_v, src_left=_chroma_h, src_top=_chroma_v)
clip = core.std.ShufflePlanes([_y, _u, _v], [0, 0, 0], vs.YUV)
{{/CHROMA_SHIFT}}

{{#CHROMA_FIX_BLEEDING}}
# FixChromaBleedingMod - fix color bleeding from analog sources
clip = haf.FixChromaBleedingMod(
    clip,
{{#CHROMA_CX}}
    cx={{CHROMA_CX}},
{{/CHROMA_CX}}
{{#CHROMA_CY}}
    cy={{CHROMA_CY}},
{{/CHROMA_CY}}
{{#CHROMA_THR}}
    thr={{CHROMA_THR}},
{{/CHROMA_THR}}
{{#CHROMA_STRENGTH}}
    strength={{CHROMA_STRENGTH}},
{{/CHROMA_STRENGTH}}
)
{{/CHROMA_FIX_BLEEDING}}

{{#CHROMA_DECRAWL}}
# LUTDeCrawl - remove dot crawl artifacts.
# havsfunc REJECTS anything above 10-bit outright ("LUTDeCrawl: This is not an
# 8-10 bit YUV clip"), which failed the whole job on a 12-bit source such as
# ProRes 4444 XQ. Run the pass at 10-bit and restore the source format after —
# dot crawl is an analog artifact, so 10-bit is ample for the decision, and the
# 8/10-bit path stays byte-for-byte what it was.
_decrawl_orig_format = clip.format
if clip.format.bits_per_sample > 10:
    clip = core.resize.Bilinear(clip, format=clip.format.replace(
        bits_per_sample=10, sample_type=vs.INTEGER).id)
clip = haf.LUTDeCrawl(
    clip,
{{#DECRAWL_YTHRESH}}
    ythresh={{DECRAWL_YTHRESH}},
{{/DECRAWL_YTHRESH}}
{{#DECRAWL_CTHRESH}}
    cthresh={{DECRAWL_CTHRESH}},
{{/DECRAWL_CTHRESH}}
{{#DECRAWL_MAXDIFF}}
    maxdiff={{DECRAWL_MAXDIFF}},
{{/DECRAWL_MAXDIFF}}
)
if _decrawl_orig_format.bits_per_sample > 10:
    clip = core.resize.Bilinear(clip, format=_decrawl_orig_format.id,
                               dither_type="error_diffusion")
{{/CHROMA_DECRAWL}}

{{#CHROMA_DERAINBOW}}
# LUTDeRainbow - remove rainbowing (cross-luminance): the shimmering colour
# bands composite video puts over fine detail. The companion to LUTDeCrawl,
# which targets the dots along colour edges instead.
#
# Same 8-10 bit limit as LUTDeCrawl and the same treatment: havsfunc rejects
# anything above 10-bit outright ("LUTDeRainbow: This is not an 8-10 bit YUV or
# YCoCg clip"), verified against the bundle, so run at 10-bit and restore the
# source format after. Rainbowing is an analog artifact; 10-bit is ample for the
# decision and the 8/10-bit path is byte-for-byte unchanged.
_derainbow_orig_format = clip.format
if clip.format.bits_per_sample > 10:
    clip = core.resize.Bilinear(clip, format=clip.format.replace(
        bits_per_sample=10, sample_type=vs.INTEGER).id)
clip = haf.LUTDeRainbow(
    clip,
{{#DERAINBOW_CTHRESH}}
    cthresh={{DERAINBOW_CTHRESH}},
{{/DERAINBOW_CTHRESH}}
{{#DERAINBOW_YTHRESH}}
    ythresh={{DERAINBOW_YTHRESH}},
{{/DERAINBOW_YTHRESH}}
{{#DERAINBOW_Y}}
    y={{DERAINBOW_Y}},
{{/DERAINBOW_Y}}
{{#DERAINBOW_LINKUV}}
    linkUV={{DERAINBOW_LINKUV}},
{{/DERAINBOW_LINKUV}}
)
if _derainbow_orig_format.bits_per_sample > 10:
    clip = core.resize.Bilinear(clip, format=_derainbow_orig_format.id,
                               dither_type="error_diffusion")
{{/CHROMA_DERAINBOW}}

{{#CHROMA_BIFROST}}
# Bifrost - temporal rainbow / dot-crawl removal. Where LUTDeRainbow decides
# within a frame, this compares across frames (or fields), so it catches
# rainbowing that shimmers rather than sits still. Measured on an alternating-
# chroma clip: frame-to-frame chroma swing halved.
#
# 8-BIT ONLY: "Bifrost: Only constant format 8 bit integer YUV input supported",
# verified against the bundle at 10/12/16-bit and 4:2:2. Same treatment as
# DeScratch — run the pass at 8-bit and restore the source format after. In
# practice the sources this targets (VHS, Video8, DV captures) are 8-bit anyway.
_bifrost_src_format = clip.format
if clip.format.bits_per_sample != 8:
    clip = core.resize.Bilinear(clip, format=clip.format.replace(
        bits_per_sample=8, sample_type=vs.INTEGER).id)
clip = core.bifrost.Bifrost(
    clip,
    luma_thresh={{BIFROST_LUMA_THRESH}},
    variation={{BIFROST_VARIATION}},
    interlaced={{BIFROST_INTERLACED}},
)
if _bifrost_src_format.bits_per_sample != 8:
    clip = core.resize.Bilinear(clip, format=_bifrost_src_format.id,
                               dither_type="error_diffusion")
{{/CHROMA_BIFROST}}

{{#CHROMA_VINVERSE}}
# Vinverse - remove residual combing
clip = haf.Vinverse(
    clip,
{{#VINVERSE_SSTR}}
    sstr={{VINVERSE_SSTR}},
{{/VINVERSE_SSTR}}
{{#VINVERSE_AMNT}}
    amnt={{VINVERSE_AMNT}},
{{/VINVERSE_AMNT}}
)
{{/CHROMA_VINVERSE}}
{{/CHROMA_FIXES}}

# ============================================================================
# PASS 9: COLOR CORRECTION
# ============================================================================
{{#COLOR_CORRECTION}}
{{#CC_AUTO_LEVELS}}
# Auto levels — stretch luma so the darkest and brightest parts of the picture
# land on the target black and white points. The common fix for a washed-out
# capture, and the one thing a non-expert can ask for by name.
#
# Stats are measured on a heavily downscaled copy, not the full frame. Min and
# max of a full frame are set by single outlier pixels — one hot specular or one
# dead pixel re-grades the whole shot, and because those outliers come and go the
# result flickers frame to frame. Averaging them away first is what makes this
# usable on real footage.
#
# PlaneStatsMin/Max come back in the CLIP's own depth, so they are used raw;
# only the user's targets, which are in 8-bit UI units, get scaled to the format.
def _auto_levels(c, black_8bit, white_8bit, strength):
    peak = (1 << c.format.bits_per_sample) - 1
    to_fmt = lambda v: int(round(v * peak / 255.0))
    lo_t, hi_t = to_fmt(black_8bit), to_fmt(white_8bit)
    small = core.resize.Bilinear(c, 64, 48) if c.width > 128 else c
    stats = core.std.PlaneStats(small, plane=0)

    def _apply(n, f, clip_in):
        lo = int(f.props['PlaneStatsMin'])
        hi = int(f.props['PlaneStatsMax'])
        if hi <= lo:
            return clip_in  # flat frame: nothing to stretch, and avoids /0
        out = core.std.Levels(
            clip_in, min_in=lo, max_in=hi, min_out=lo_t, max_out=hi_t, planes=[0]
        )
        if strength >= 1.0:
            return out
        return core.std.Merge(clip_in, out, weight=strength)

    return core.std.FrameEval(c, functools.partial(_apply, clip_in=c), prop_src=stats)

clip = _auto_levels(clip, {{CC_AUTO_LEVELS_BLACK}}, {{CC_AUTO_LEVELS_WHITE}}, {{CC_AUTO_LEVELS_STRENGTH}})
{{/CC_AUTO_LEVELS}}
{{#CC_AUTO_WHITE}}
# Auto white balance, grey-world: assume the scene averages to neutral, and
# shift each chroma plane's mean onto the neutral point. In YUV that is the
# whole of the grey-world assumption — there is no second thing to compute, and
# unlike Retinex it needs no 4:4:4 round trip because it never leaves the native
# plane geometry.
#
# Chroma means are averages already, so they are far steadier frame to frame
# than the luma min/max above and need no outlier handling.
def _auto_white(c, strength):
    if c.format.num_planes < 3:
        return c  # GRAY: PlaneStats(plane=1) would error
    bits = c.format.bits_per_sample
    peak = (1 << bits) - 1
    neutral = 1 << (bits - 1)
    su = core.std.PlaneStats(c, plane=1)
    sv = core.std.PlaneStats(c, plane=2)

    def _apply(n, f, clip_in):
        du = (neutral - f[0].props['PlaneStatsAverage'] * peak) * strength
        dv = (neutral - f[1].props['PlaneStatsAverage'] * peak) * strength
        return _expr(clip_in, ['', 'x {:.6f} +'.format(du), 'x {:.6f} +'.format(dv)])

    return core.std.FrameEval(c, functools.partial(_apply, clip_in=c), prop_src=[su, sv])

clip = _auto_white(clip, {{CC_AUTO_WHITE_STRENGTH}})
{{/CC_AUTO_WHITE}}
import adjust

{{#COLOR_TWEAK}}
# Tweak brightness, contrast, saturation, hue.
#
# adjust.Tweak scales its own hue/saturation/coring constants to the clip's depth,
# but `bright` is added in RAW SAMPLE UNITS — so the identical setting is 4x
# weaker on a 10-bit clip and 256x weaker at 16-bit. Measured on 10-bit 4:2:2:
# brightness 10 moved luma by ~2.5/255 instead of 10/255. The UI works in 8-bit
# levels, so scale it here, exactly as the white-balance block below does.
# Contrast, saturation and hue are ratios and need no scaling.
_tweak_bright_scale = (
    (1 << (clip.format.bits_per_sample - 8))
    if clip.format.sample_type == vs.INTEGER
    else 1.0 / 255.0
)
clip = adjust.Tweak(
    clip,
{{#COLOR_BRIGHTNESS}}
    bright={{COLOR_BRIGHTNESS}} * _tweak_bright_scale,
{{/COLOR_BRIGHTNESS}}
{{#COLOR_CONTRAST}}
    cont={{COLOR_CONTRAST}},
{{/COLOR_CONTRAST}}
{{#COLOR_SATURATION}}
    sat={{COLOR_SATURATION}},
{{/COLOR_SATURATION}}
{{#COLOR_HUE}}
    hue={{COLOR_HUE}},
{{/COLOR_HUE}}
)
{{/COLOR_TWEAK}}

{{#COLOR_LEVELS}}
# Levels adjustment.
#
# std.Levels works in the clip's OWN sample range, but these values arrive from
# the UI at 8-bit scale (0-255). Passed through unscaled they are nonsense on a
# >8-bit clip: on 10-bit 4:2:2, max_in=235 maps everything above 235/1023 to
# white (measured mean error 93/255 against the same edit at 8-bit — the reported
# "levels blows out 10-bit ProRes"). Scale against peak, the way havsfunc's
# scale() does, so 255 lands exactly on the format's maximum.
_levels_peak = (1 << clip.format.bits_per_sample) - 1


def _levels_8bit(value):
    if clip.format.sample_type != vs.INTEGER:
        return value / 255.0
    return int(round(value * _levels_peak / 255))


clip = core.std.Levels(
    clip,
{{#LEVELS_INPUT_LOW}}
    min_in=_levels_8bit({{LEVELS_INPUT_LOW}}),
{{/LEVELS_INPUT_LOW}}
{{#LEVELS_INPUT_HIGH}}
    max_in=_levels_8bit({{LEVELS_INPUT_HIGH}}),
{{/LEVELS_INPUT_HIGH}}
{{#LEVELS_OUTPUT_LOW}}
    min_out=_levels_8bit({{LEVELS_OUTPUT_LOW}}),
{{/LEVELS_OUTPUT_LOW}}
{{#LEVELS_OUTPUT_HIGH}}
    max_out=_levels_8bit({{LEVELS_OUTPUT_HIGH}}),
{{/LEVELS_OUTPUT_HIGH}}
{{#LEVELS_GAMMA}}
    gamma={{LEVELS_GAMMA}},
{{/LEVELS_GAMMA}}
)
{{/COLOR_LEVELS}}

{{#COLOR_SMOOTH_LEVELS}}
# SmoothLevels - the same curve as std.Levels, but dithered and limited as it
# goes, so stretching a narrow range does not band. Measured on a shallow
# gradient stretched to full range: distinct output levels 47 -> 135.
#
# Three things are load-bearing here, all measured against the bundle:
#
#  1. SmoothLevels reads its levels in the CLIP'S OWN range, not 8-bit — the
#     same trap as std.Levels. Six arguments need scaling (input_low/high,
#     output_low/high, Ecenter, protect) and the rest must NOT be touched:
#     gamma and chroma are ratios. Unscaled, a gamma-only edit at 16-bit is off
#     by a worst pixel of 249/255.
#  2. useDB is pinned False. havsfunc calls `core.f3kdb.Deband` and this bundle
#     ships `neo_f3kdb` under a different namespace, so the default useDB=True
#     raises "no attribute named f3kdb" on EVERY format. Fixing that needs a
#     havsfunc patch, i.e. a deps release; useDB=False already gets most of the
#     benefit.
#  3. The black point is dropped when gamma is not 1.0 — havsfunc raises a
#     negative base to a fractional power below input_low, which yields a
#     complex number and fails the LUT. The worker does that, and tells the user.
clip = haf.SmoothLevels(
    clip,
    input_low=_levels_8bit({{SMOOTH_INPUT_LOW}}),
    input_high=_levels_8bit({{SMOOTH_INPUT_HIGH}}),
    output_low=_levels_8bit({{SMOOTH_OUTPUT_LOW}}),
    output_high=_levels_8bit({{SMOOTH_OUTPUT_HIGH}}),
    gamma={{SMOOTH_GAMMA}},
    Smode={{SMOOTH_MODE}},
    useDB=False,
)
{{/COLOR_SMOOTH_LEVELS}}

{{#COLOR_SHADOW_DETAIL}}
# Retinex (MSRCP) - lifts detail out of shadows by comparing each pixel to a
# wide local average, so underexposed footage opens up without simply raising
# the black level.
#
# LUMA ONLY, deliberately. retinex.MSRCP rejects subsampled formats outright
# ("sub-sampled format is not supported") and every source this app handles is
# 4:2:0 or 4:2:2. Rather than round-trip the whole clip through 4:4:4 and
# resample chroma twice for a brightness operation, the luma plane is lifted out
# as greyscale, processed, and put back — colour comes through bit-identical.
# Verified working this way at 8/10/12/16-bit and 4:2:2.
_retinex_y = core.std.ShufflePlanes(clip, planes=0, colorfamily=vs.GRAY)
_retinex_y = core.retinex.MSRCP(
    _retinex_y,
    sigma=[{{SHADOW_SIGMA}}],
    lower_thr={{SHADOW_LOWER}},
    upper_thr={{SHADOW_UPPER}},
)
if clip.format.color_family == vs.GRAY:
    clip = _retinex_y
else:
    clip = core.std.ShufflePlanes([_retinex_y, clip, clip], planes=[0, 1, 2],
                                  colorfamily=clip.format.color_family)
{{/COLOR_SHADOW_DETAIL}}

{{#COLOR_WHITE_BALANCE}}
# White balance: shift the chroma planes. U carries blue-yellow and V carries
# red-cyan, so warming the image is -U/+V and a magenta tint raises both.
# Offsets arrive at 8-bit scale and are scaled to the working depth here, so the
# same setting means the same colour shift on an 8-bit and a 16-bit clip.
if clip.format.color_family == vs.YUV:
    _wb_scale = (
        (1 << (clip.format.bits_per_sample - 8))
        if clip.format.sample_type == vs.INTEGER
        else 1.0 / 255.0
    )
    _wb_u = {{COLOR_WB_U}} * _wb_scale
    _wb_v = {{COLOR_WB_V}} * _wb_scale
    # An empty expression leaves that plane untouched, so luma is never
    # rewritten. Expr clamps to the format's range, so extreme settings
    # saturate rather than wrap around.
    clip = _expr(
        clip,
        ['', 'x ' + repr(_wb_u) + ' +', 'x ' + repr(_wb_v) + ' +'],
    )
{{/COLOR_WHITE_BALANCE}}
{{/COLOR_CORRECTION}}

# ============================================================================
# PASS: STABILIZE
# ============================================================================
{{#STABILIZE}}
# Stab - global motion stabilisation via MVTools' Depan family. Measures the
# frame-to-frame shift and subtracts it, so shake is cancelled while a
# deliberate pan survives. Frame count is unchanged, which is why this is an
# ordinary pass.
#
# The signature is Stab(clp, dxmax, dymax, mirror) — there is no `range`
# argument, whatever other Stab implementations take. `mirror` fills the edges
# the shift exposes rather than leaving them black.
clip = haf.Stab(
    clip,
    dxmax={{STAB_DXMAX}},
    dymax={{STAB_DYMAX}},
    mirror={{STAB_MIRROR}},
)
{{/STABILIZE}}

# ============================================================================
# PASS: ROTATE / FLIP
# ============================================================================
{{#GEOMETRY}}
# Quarter-turn rotation and mirroring, in that order. core.std only, so the ops
# themselves move samples without changing their values.
#
# A quarter turn swaps width and height, which is why this runs before any
# framing decision; the worker also inverts the declared sample aspect for it,
# since SAR is pixel width : height and the turn exchanges those.
#
# A turn ALSO swaps the chroma subsampling axes, and that is not cosmetic:
# 4:2:2 becomes 4:4:0, which vspipe emits as "C440" and ffmpeg rejects outright
# ("YUV4MPEG stream contains an unknown pixel format"), and 4:1:1 has no y4m
# identifier at all so vspipe itself fails. Both are hard job failures, and
# 4:2:2 is the common 10-bit ProRes case. So the source format is captured here
# and restored after the turn, exactly as the LUTDeCrawl and DeScratch guards
# do. It is a no-op for 4:2:0, 4:4:4 and greyscale, whose subsampling is
# symmetric.
_geom_src_format = clip.format
{{#GEOM_ROTATE}}
clip = core.std.{{GEOM_ROTATE_FN}}(clip)
{{/GEOM_ROTATE}}
{{#GEOM_FLIP_H}}
clip = core.std.FlipHorizontal(clip)
{{/GEOM_FLIP_H}}
{{#GEOM_FLIP_V}}
clip = core.std.FlipVertical(clip)
{{/GEOM_FLIP_V}}
if clip.format.id != _geom_src_format.id:
    clip = core.resize.Spline36(clip, format=_geom_src_format.id)
{{/GEOMETRY}}

# ============================================================================
# PASS 10: RESIZE / UPSCALE
# ============================================================================
{{#RESIZE}}

{{#RESIZE_INTEGER_UPSCALE}}
# Integer upscaling: repeated edge-directed 2x doubling (double the height,
# transpose, double again, transpose back).
{{#UPSCALE_EDGE_DIRECTED}}
def _upscale_double_height(c):
{{#UPSCALE_NNEDI3}}
    return _nnedi3(
        c,
        field=1,
        dh=True,
{{#UPSCALE_NSIZE}}
        nsize={{UPSCALE_NSIZE}},
{{/UPSCALE_NSIZE}}
{{#UPSCALE_NNS}}
        nns={{UPSCALE_NNS}},
{{/UPSCALE_NNS}}
{{#UPSCALE_QUAL}}
        qual={{UPSCALE_QUAL}},
{{/UPSCALE_QUAL}}
{{#UPSCALE_ETYPE}}
        etype={{UPSCALE_ETYPE}},
{{/UPSCALE_ETYPE}}
{{#UPSCALE_PSCRN}}
        pscrn={{UPSCALE_PSCRN}},
{{/UPSCALE_PSCRN}}
    )
{{/UPSCALE_NNEDI3}}
{{#UPSCALE_EEDI3}}
    # EEDI3 needs a second opinion to bound its cost search. nnedi3 is the
    # conventional choice and is bundled anyway, so the nnedi3 controls below
    # shape the sclip that guides EEDI3.
    sclip = _nnedi3(
        c,
        field=1,
        dh=True,
{{#UPSCALE_NSIZE}}
        nsize={{UPSCALE_NSIZE}},
{{/UPSCALE_NSIZE}}
{{#UPSCALE_NNS}}
        nns={{UPSCALE_NNS}},
{{/UPSCALE_NNS}}
{{#UPSCALE_QUAL}}
        qual={{UPSCALE_QUAL}},
{{/UPSCALE_QUAL}}
{{#UPSCALE_ETYPE}}
        etype={{UPSCALE_ETYPE}},
{{/UPSCALE_ETYPE}}
{{#UPSCALE_PSCRN}}
        pscrn={{UPSCALE_PSCRN}},
{{/UPSCALE_PSCRN}}
    )
    return core.eedi3m.EEDI3(
        c,
        field=1,
        dh=True,
        sclip=sclip,
{{#UPSCALE_ALPHA}}
        alpha={{UPSCALE_ALPHA}},
{{/UPSCALE_ALPHA}}
{{#UPSCALE_BETA}}
        beta={{UPSCALE_BETA}},
{{/UPSCALE_BETA}}
{{#UPSCALE_GAMMA}}
        gamma={{UPSCALE_GAMMA}},
{{/UPSCALE_GAMMA}}
{{#UPSCALE_NRAD}}
        nrad={{UPSCALE_NRAD}},
{{/UPSCALE_NRAD}}
{{#UPSCALE_MDIS}}
        mdis={{UPSCALE_MDIS}},
{{/UPSCALE_MDIS}}
    )
{{/UPSCALE_EEDI3}}


def _upscale_fix_shift(c, shift):
    # Interpolating the missing field with dh=True leaves the result half an
    # output pixel above (and, after the transposes, left of) where it belongs.
    # Measured on an 8x8 clip with one bright row: the centroid that should land
    # at output y=7.0 lands at 6.51.
    #
    # The correction has to be applied PER PLANE. src_top is expressed in luma
    # pixels, so a single whole-clip -0.5 under-corrects subsampled chroma by a
    # quarter of a chroma row (measured: 6.74 instead of 7.0 on 4:2:0), leaving
    # colour misaligned against luma.
    if shift == 0:
        return c
    if c.format.num_planes == 1:
        return core.resize.Spline36(c, src_left=-shift, src_top=-shift)
    planes = [
        core.resize.Spline36(
            core.std.ShufflePlanes(c, i, vs.GRAY), src_left=-shift, src_top=-shift)
        for i in range(c.format.num_planes)
    ]
    return core.std.ShufflePlanes(planes, [0] * c.format.num_planes, c.format.color_family)


# Each doubling adds half an output pixel of offset, and doubles whatever
# offset it inherited — so correct once at the end rather than per step, which
# keeps it to a single resample.
_upscale_shift = 0.0
for _ in range(max({{UPSCALE_FACTOR}} // 2, 1)):
    clip = _upscale_double_height(clip)
    clip = core.std.Transpose(clip)
    clip = _upscale_double_height(clip)
    clip = core.std.Transpose(clip)
    _upscale_shift = _upscale_shift * 2 + 0.5
clip = _upscale_fix_shift(clip, _upscale_shift)
{{/UPSCALE_EDGE_DIRECTED}}
{{#UPSCALE_SPLINE36}}
# Plain resampling at an integer factor — no edge direction, just fast.
clip = core.resize.Spline36(clip, width=clip.width * {{UPSCALE_FACTOR}}, height=clip.height * {{UPSCALE_FACTOR}})
{{/UPSCALE_SPLINE36}}
{{/RESIZE_INTEGER_UPSCALE}}

{{#RESIZE_STANDARD}}
# The shape the frame is meant to be *seen* at. On an anamorphic source the
# stored frame is the wrong shape on purpose (720x576 shown as 16:9), so fitting
# a target box by stored dimensions alone gets the geometry wrong — which is what
# used to happen here.
{{#ASPECT_DAR_OVERRIDE}}
_display_aspect = {{ASPECT_DAR}}
{{/ASPECT_DAR_OVERRIDE}}
{{#ASPECT_DAR_FROM_SOURCE}}
_display_aspect = (clip.width * {{SOURCE_SAR}}) / clip.height
{{/ASPECT_DAR_FROM_SOURCE}}


def _even(value):
    # Chroma subsampling needs even dimensions; never round down to zero.
    return max(2, int(round(value)) & ~1)


# Storage aspect when the pixel grid is left alone, display aspect when we are
# resampling to square pixels: that is exactly what "square up" means.
{{#ASPECT_SQUARE_PIXELS}}
_fit_aspect = _display_aspect
{{/ASPECT_SQUARE_PIXELS}}
{{#ASPECT_KEEP_PIXELS}}
_fit_aspect = clip.width / clip.height
{{/ASPECT_KEEP_PIXELS}}

# Calculate target dimensions
target_w = {{TARGET_WIDTH}}
target_h = {{TARGET_HEIGHT}}
{{#ASPECT_SQUARE_PIXELS}}
if target_w <= 0 and target_h <= 0:
    # Squaring the pixels with no target size: keep the height and widen (or
    # narrow) the frame until the picture is the right shape.
    target_h = clip.height
{{/ASPECT_SQUARE_PIXELS}}
_box_w, _box_h = target_w, target_h
{{#MAINTAIN_ASPECT}}
# Maintain aspect ratio - calculate the missing dimension, or fit inside the box
if target_w > 0 and target_h <= 0:
    target_h = _even(target_w / _fit_aspect)
elif target_h > 0 and target_w <= 0:
    target_w = _even(target_h * _fit_aspect)
elif target_w > 0 and target_h > 0:
    # Both specified - fit within bounds while maintaining aspect
    scale = min(target_w / (clip.height * _fit_aspect), target_h / clip.height)
    target_w = _even(clip.height * _fit_aspect * scale)
    target_h = _even(clip.height * scale)
{{/MAINTAIN_ASPECT}}

# filter_param_a/b carry the kernel's own tuning: b and c for Bicubic, taps
# for Lanczos. They are ignored by kernels that take neither.
clip = core.resize.{{RESIZE_KERNEL}}(
    clip,
    width=target_w,
    height=target_h,
{{#RESIZE_FILTER_A}}
    filter_param_a={{RESIZE_FILTER_A}},
{{/RESIZE_FILTER_A}}
{{#RESIZE_FILTER_B}}
    filter_param_b={{RESIZE_FILTER_B}},
{{/RESIZE_FILTER_B}}
)

{{#ASPECT_PAD}}
# Letterbox/pillarbox out to the requested box instead of leaving the fitted
# image smaller than it. Borders are split evenly and kept even for chroma.
if _box_w > clip.width or _box_h > clip.height:
    _pad_w = max(0, _even(_box_w) - clip.width)
    _pad_h = max(0, _even(_box_h) - clip.height)
    _left = (_pad_w // 2) & ~1
    _top = (_pad_h // 2) & ~1
    clip = core.std.AddBorders(
        clip,
        left=_left,
        right=_pad_w - _left,
        top=_top,
        bottom=_pad_h - _top,
    )
{{/ASPECT_PAD}}
{{/RESIZE_STANDARD}}
{{/RESIZE}}

# ============================================================================
# PASS: FILM GRAIN
# ============================================================================
{{#GRAIN}}
{{#GRAIN_ADD}}
# AddGrain - one strength control, and the only one of the two that can grain
# chroma or hold a static pattern.
#
# `var` is a VARIANCE: the noise standard deviation is its square root, so
# var=4 gives sigma=2. It is already expressed in 8-bit units and the plugin
# rescales internally, so it must NOT get the _levels_8bit() treatment used for
# std.Levels and Tweak — doing that would quadruple the grain at 10-bit.
# Verified against the bundle: identical 8-bit-equivalent output at 8/10/12/16
# bit and 4:2:2.
clip = core.grain.Add(
    clip,
    var={{GRAIN_VAR}},
    uvar={{GRAIN_UVAR}},
    hcorr={{GRAIN_CORR}},
    vcorr={{GRAIN_CORR}},
    constant={{GRAIN_CONSTANT}},
)
{{/GRAIN_ADD}}

{{#GRAIN_FACTORY3}}
# GrainFactory3 - three grain layers chosen by luma level, so shadows get more
# grain than highlights. Closer to real film stock than a flat noise field.
#
# Two measured limitations worth knowing: it is LUMA-ONLY (chroma comes back
# bit-identical), and it is ALWAYS animated — havsfunc leaves grain.Add's
# `constant` at its default and exposes no way to reach it. `temp_avg` damps the
# animation but cannot stop it.
clip = haf.GrainFactory3(
    clip,
    g1str={{GRAIN_G1}},
    g2str={{GRAIN_G2}},
    g3str={{GRAIN_G3}},
{{#GRAIN_TEMP_AVG}}
    temp_avg={{GRAIN_TEMP_AVG}},
{{/GRAIN_TEMP_AVG}}
)
{{/GRAIN_FACTORY3}}
{{/GRAIN}}

# ============================================================================
# PASS 11: FRAME RATE CONVERSION
# ============================================================================
{{#FRAME_RATE}}
# Standards conversion, not smoothing. Runs genuinely last of the video passes:
# it resamples the timeline, so anything after it would be working on invented
# frames rather than photographed ones.
#
# FlowFPS rather than BlockFPS deliberately. Measured over 35 combinations,
# FlowFPS emits floor(n_in * ratio), which is exactly what FrameMap::Retime
# computes; BlockFPS emits floor((n_in-1) * ratio) + 1 and is off by one in 14
# of them, which would desynchronise the progress total and the preview index.
#
# mvtools rejects 4:1:1 at Super ("input clip must be GRAY, 420, 422, 440, or
# 444") and 4:1:1 is NTSC DV — precisely the tape an NTSC->PAL conversion
# targets — so convert up and restore, as the chroma denoise pass does.
_fps_src_format = clip.format.id
if clip.format.subsampling_w == 2:
    clip = core.resize.Bicubic(
        clip,
        format=vs.YUV422P8 if clip.format.bits_per_sample == 8 else vs.YUV422P16,
    )
{{#FRAME_RATE_FLOWFPS}}
_fps_super = core.mv.Super(clip, pel=2)
_fps_bw = core.mv.Analyse(_fps_super, isb=True, blksize={{FPS_BLOCK_SIZE}}, overlap={{FPS_OVERLAP}})
_fps_fw = core.mv.Analyse(_fps_super, isb=False, blksize={{FPS_BLOCK_SIZE}}, overlap={{FPS_OVERLAP}})
clip = core.mv.FlowFPS(
    clip, _fps_super, _fps_bw, _fps_fw,
    num={{FPS_TARGET_NUM}}, den={{FPS_TARGET_DEN}},
)
{{/FRAME_RATE_FLOWFPS}}
{{#FRAME_RATE_DUPLICATE}}
# No invented pixels — whole frames are repeated or dropped. Visible judder, but
# every frame in the output was photographed. The honest choice for a master.
clip = haf.ChangeFPS(clip, {{FPS_TARGET_NUM}}, {{FPS_TARGET_DEN}})
{{/FRAME_RATE_DUPLICATE}}
if clip.format.id != _fps_src_format:
    clip = core.resize.Bicubic(clip, format=_fps_src_format)
{{/FRAME_RATE}}

# ============================================================================
# OUTPUT FORMAT CONVERSION
#
# The preview applies the output colour format too, so it shows what the render
# will actually look like — including the banding an undithered depth reduction
# used to introduce, which is precisely the thing a preview should reveal before
# a long encode rather than after. Identical to the block in
# pipeline_template.vpy; the two must stay in step (see "Field Order" for why
# preview/encode divergence is treated as a bug).
# ============================================================================
{{#CHROMA_CONVERT}}
target_format = {{CHROMA_FORMAT}}
if clip.format.id != target_format:
    clip = core.resize.Bicubic(clip, format=target_format,
                               dither_type="error_diffusion")
{{/CHROMA_CONVERT}}

# ============================================================================
# OUTPUT - select the exact target frame for preview.
# The worker decodes a window of source frames around the requested frame and
# passes the deterministic output index it maps to (after any frame-rate change
# such as QTGMC double-rate). Clamp defensively in case the decode came up short.
# ============================================================================
target_frame = max(0, min({{PREVIEW_OUTPUT_INDEX}}, clip.num_frames - 1))
clip = clip[target_frame]
clip.set_output()
