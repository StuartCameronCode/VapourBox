"""
iDeinterlace Multi-Pass Restoration Pipeline Template
Supports: Crop, Deinterlace (QTGMC), Noise Reduction, Dehalo, Deblock, Deband, Sharpen, Chroma Fixes, Color Correction, Resize
Placeholders use the format: {{PARAMETER_NAME}}
Conditional blocks use: {{#BLOCK_NAME}}...{{/BLOCK_NAME}}
"""

import vapoursynth as vs
import sys

core = vs.core

# Load input video using ffms2 for frame-accurate seeking
clip = core.ffms2.Source(source=r"{{INPUT_PATH}}")

# Get input properties for progress tracking
input_fps_num = clip.fps.numerator
input_fps_den = clip.fps.denominator
total_frames = clip.num_frames
print(f"INPUT_INFO:frames={total_frames},fps_num={input_fps_num},fps_den={input_fps_den}", file=sys.stderr)

# Import havsfunc for various filters (QTGMC, SMDegrain, chroma fixes)
import havsfunc as haf

# ============================================================================
# PASS 1: PRE-CROP (before deinterlacing to reduce processing area)
# ============================================================================
{{#PRE_CROP}}
clip = core.std.Crop(clip, left={{CROP_LEFT}}, right={{CROP_RIGHT}}, top={{CROP_TOP}}, bottom={{CROP_BOTTOM}})
{{/PRE_CROP}}

# ============================================================================
# PASS 2: DEINTERLACING (QTGMC)
# ============================================================================
{{#DEINTERLACE}}
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
{{/DEINTERLACE}}

# ============================================================================
# PASS 3: NOISE REDUCTION
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
)
{{/DEHALO_FINE_DEHALO}}

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
{{/COLOR_CORRECTION}}

# ============================================================================
# PASS 10: RESIZE / UPSCALE
# ============================================================================
{{#RESIZE}}

{{#RESIZE_INTEGER_UPSCALE}}
# Integer upscaling using NNEDI3/ZNEDI3
# Manual 2x upscale: nnedi3 on Y, transpose, nnedi3 again, transpose back
{{#UPSCALE_NNEDI3}}
def nnedi3_2x(c):
    # Double height
    c = core.znedi3.nnedi3(c, field=1, dh=True)
    c = core.std.Transpose(c)
    # Double width
    c = core.znedi3.nnedi3(c, field=1, dh=True)
    c = core.std.Transpose(c)
    return c
for _ in range({{UPSCALE_FACTOR}} // 2 if {{UPSCALE_FACTOR}} > 1 else 1):
    clip = nnedi3_2x(clip)
{{/UPSCALE_NNEDI3}}
{{#UPSCALE_EEDI3}}
# EEDI3 upscaling - fall back to spline36 for now
clip = core.resize.Spline36(clip, width=clip.width * {{UPSCALE_FACTOR}}, height=clip.height * {{UPSCALE_FACTOR}})
{{/UPSCALE_EEDI3}}
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

{{#RESIZE_SPLINE36}}
clip = core.resize.Spline36(clip, width=target_w, height=target_h)
{{/RESIZE_SPLINE36}}
{{#RESIZE_LANCZOS}}
clip = core.resize.Lanczos(clip, width=target_w, height=target_h)
{{/RESIZE_LANCZOS}}
{{#RESIZE_BICUBIC}}
clip = core.resize.Bicubic(clip, width=target_w, height=target_h)
{{/RESIZE_BICUBIC}}
{{#RESIZE_BILINEAR}}
clip = core.resize.Bilinear(clip, width=target_w, height=target_h)
{{/RESIZE_BILINEAR}}
{{/RESIZE_STANDARD}}
{{/RESIZE}}

# ============================================================================
# OUTPUT
# ============================================================================
clip.set_output()
