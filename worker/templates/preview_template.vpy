"""
VapourBox Preview Template
Reads raw frames piped from FFmpeg for fast preview generation.
Uses the same filter pipeline as the main template.
"""

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
{{/SPOTLESS}}

# ============================================================================
# PASS 5: NOISE REDUCTION
# ============================================================================
{{#NOISE_REDUCTION}}
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
_mcds_sharpened = core.std.Expr(
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
{{/NOISE_REDUCTION}}

# ============================================================================
# PASS 5b: CHROMA DENOISE (CCD - Camcorder Colour Denoise)
# ============================================================================
{{#CHROMA_DENOISE}}
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
{{/SHARPEN}}

# ============================================================================
# PASS 8: CHROMA FIXES
# ============================================================================
{{#CHROMA_FIXES}}

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
# LUTDeCrawl - remove dot crawl artifacts
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
{{/CHROMA_DECRAWL}}

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
import adjust

{{#COLOR_TWEAK}}
# Tweak brightness, contrast, saturation, hue
clip = adjust.Tweak(
    clip,
{{#COLOR_BRIGHTNESS}}
    bright={{COLOR_BRIGHTNESS}},
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
# Levels adjustment
clip = core.std.Levels(
    clip,
{{#LEVELS_INPUT_LOW}}
    min_in={{LEVELS_INPUT_LOW}},
{{/LEVELS_INPUT_LOW}}
{{#LEVELS_INPUT_HIGH}}
    max_in={{LEVELS_INPUT_HIGH}},
{{/LEVELS_INPUT_HIGH}}
{{#LEVELS_OUTPUT_LOW}}
    min_out={{LEVELS_OUTPUT_LOW}},
{{/LEVELS_OUTPUT_LOW}}
{{#LEVELS_OUTPUT_HIGH}}
    max_out={{LEVELS_OUTPUT_HIGH}},
{{/LEVELS_OUTPUT_HIGH}}
{{#LEVELS_GAMMA}}
    gamma={{LEVELS_GAMMA}},
{{/LEVELS_GAMMA}}
)
{{/COLOR_LEVELS}}

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
    clip = core.std.Expr(
        clip,
        ['', 'x ' + repr(_wb_u) + ' +', 'x ' + repr(_wb_v) + ' +'],
    )
{{/COLOR_WHITE_BALANCE}}
{{/COLOR_CORRECTION}}

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
    return core.znedi3.nnedi3(
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
    sclip = core.znedi3.nnedi3(
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
# Calculate target dimensions
target_w = {{TARGET_WIDTH}}
target_h = {{TARGET_HEIGHT}}
{{#MAINTAIN_ASPECT}}
# Maintain aspect ratio - calculate missing dimension
aspect = clip.width / clip.height
if target_w > 0 and target_h <= 0:
    target_h = int(target_w / aspect)
    target_h = target_h - (target_h % 2)  # Ensure even
elif target_h > 0 and target_w <= 0:
    target_w = int(target_h * aspect)
    target_w = target_w - (target_w % 2)  # Ensure even
elif target_w > 0 and target_h > 0:
    # Both specified - fit within bounds while maintaining aspect
    scale_w = target_w / clip.width
    scale_h = target_h / clip.height
    scale = min(scale_w, scale_h)
    target_w = int(clip.width * scale)
    target_w = target_w - (target_w % 2)
    target_h = int(clip.height * scale)
    target_h = target_h - (target_h % 2)
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
{{/RESIZE_STANDARD}}
{{/RESIZE}}

# ============================================================================
# OUTPUT - select the exact target frame for preview.
# The worker decodes a window of source frames around the requested frame and
# passes the deterministic output index it maps to (after any frame-rate change
# such as QTGMC double-rate). Clamp defensively in case the decode came up short.
# ============================================================================
target_frame = max(0, min({{PREVIEW_OUTPUT_INDEX}}, clip.num_frames - 1))
clip = clip[target_frame]
clip.set_output()
