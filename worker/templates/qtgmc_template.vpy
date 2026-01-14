"""
VapourBox QTGMC VapourSynth Script Template
Uses havsfunc QTGMC for deinterlacing.
Placeholders use the format: {{PARAMETER_NAME}}
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

# Import havsfunc for QTGMC
import havsfunc as haf

# Apply QTGMC deinterlacing
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

{{#NOISE_REDUCTION}}
# Apply noise reduction
{{#NR_SMDEGRAIN}}
clip = haf.SMDegrain(clip, tr={{NR_TEMPORAL_RADIUS}}, thSAD={{NR_THRESHOLD}}, prefilter={{NR_PREFILTER}}, contrasharp={{NR_CONTRA_SHARP}}, RefineMotion={{NR_REFINE_MOTION}})
{{/NR_SMDEGRAIN}}
{{#NR_MCTD}}
clip = haf.MCTemporalDenoise(clip, settings="{{NR_MCTD_SETTINGS}}")
{{/NR_MCTD}}
{{#NR_BM3D}}
clip = core.bm3dcpu.BM3D(clip, sigma={{NR_BM3D_SIGMA}}, radius={{NR_BM3D_RADIUS}})
{{/NR_BM3D}}
{{/NOISE_REDUCTION}}

{{#DEHALO}}
# Apply dehalo
{{#DEHALO_DEHALO_ALPHA}}
clip = haf.DeHalo_alpha(clip, rx={{DEHALO_RX}}, ry={{DEHALO_RY}}, darkstr={{DEHALO_DARK_STR}}, brightstr={{DEHALO_BRIGHT_STR}})
{{/DEHALO_DEHALO_ALPHA}}
{{#DEHALO_FINE_DEHALO}}
clip = haf.FineDehalo(clip, rx={{DEHALO_RX}}, ry={{DEHALO_RY}}, darkstr={{DEHALO_DARK_STR}}, brightstr={{DEHALO_BRIGHT_STR}})
{{/DEHALO_FINE_DEHALO}}
{{#DEHALO_YAHR}}
clip = haf.YAHR(clip, blur={{DEHALO_YAHR_BLUR}}, depth={{DEHALO_YAHR_DEPTH}})
{{/DEHALO_YAHR}}
{{/DEHALO}}

{{#DEBLOCK}}
# Apply deblocking
{{#DEBLOCK_QED}}
clip = haf.Deblock_QED(clip, quant1={{DEBLOCK_QUANT1}}, quant2={{DEBLOCK_QUANT2}})
{{/DEBLOCK_QED}}
{{#DEBLOCK_SIMPLE}}
clip = core.deblock.Deblock(clip, quant={{DEBLOCK_QUANT}})
{{/DEBLOCK_SIMPLE}}
{{/DEBLOCK}}

{{#DEBAND}}
# Apply debanding
clip = core.neo_f3kdb.Deband(clip, y={{DEBAND_Y}}, cb={{DEBAND_CB}}, cr={{DEBAND_CR}}, grainy={{DEBAND_GRAINY}}, grainc={{DEBAND_GRAINC}}, range={{DEBAND_RANGE}}, output_depth={{DEBAND_OUTPUT_DEPTH}})
{{/DEBAND}}

{{#SHARPEN}}
# Apply sharpening
{{#SHARPEN_LSFMOD}}
clip = haf.LSFmod(clip, strength={{SHARPEN_STRENGTH}}, Overshoot={{SHARPEN_OVERSHOOT}}, Undershoot={{SHARPEN_UNDERSHOOT}}, soft={{SHARPEN_SOFT_EDGE}})
{{/SHARPEN_LSFMOD}}
{{#SHARPEN_CAS}}
clip = core.cas.CAS(clip, sharpness={{SHARPEN_CAS_SHARPNESS}})
{{/SHARPEN_CAS}}
{{/SHARPEN}}

{{#CHROMA_FIXES}}
# Apply chroma fixes
{{#CHROMA_FIX_BLEEDING}}
clip = haf.FixChromaBleedingMod(clip, cx={{CHROMA_CX}}, cy={{CHROMA_CY}}, thr={{CHROMA_THR}}, strength={{CHROMA_STRENGTH}})
{{/CHROMA_FIX_BLEEDING}}
{{#CHROMA_DECRAWL}}
clip = haf.LUTDeCrawl(clip, ythresh={{CHROMA_Y_THRESH}}, cthresh={{CHROMA_C_THRESH}}, maxdiff={{CHROMA_MAX_DIFF}}, scnchg={{CHROMA_SCNCHG}})
{{/CHROMA_DECRAWL}}
{{#CHROMA_VINVERSE}}
clip = core.vinverse.Vinverse(clip, sstr={{CHROMA_VINVERSE_SSTR}}, amnt={{CHROMA_VINVERSE_AMNT}}, scl={{CHROMA_VINVERSE_SCL}})
{{/CHROMA_VINVERSE}}
{{/CHROMA_FIXES}}

{{#COLOR_CORRECTION}}
# Apply color correction
{{#COLOR_TWEAK}}
clip = haf.Tweak(clip, hue={{COLOR_HUE}}, sat={{COLOR_SAT}}, bright={{COLOR_BRIGHT}}, cont={{COLOR_CONT}})
{{/COLOR_TWEAK}}
{{#COLOR_LEVELS}}
clip = core.std.Levels(clip, min_in={{COLOR_MIN_IN}}, max_in={{COLOR_MAX_IN}}, min_out={{COLOR_MIN_OUT}}, max_out={{COLOR_MAX_OUT}}, gamma={{COLOR_GAMMA}})
{{/COLOR_LEVELS}}
{{/COLOR_CORRECTION}}

{{#RESIZE}}
# Apply resize/crop
{{#PRE_CROP}}
clip = core.std.Crop(clip, left={{CROP_LEFT}}, right={{CROP_RIGHT}}, top={{CROP_TOP}}, bottom={{CROP_BOTTOM}})
{{/PRE_CROP}}
{{#RESIZE_INTEGER_UPSCALE}}
# Integer upscale using edge-directed interpolation
{{#UPSCALE_NNEDI3}}
clip = core.nnedi3cl.NNEDI3CL(clip, field=0, dh=True)
clip = core.std.Transpose(clip)
clip = core.nnedi3cl.NNEDI3CL(clip, field=0, dh=True)
clip = core.std.Transpose(clip)
{{/UPSCALE_NNEDI3}}
{{#UPSCALE_EEDI3}}
clip = core.eedi3m.EEDI3(clip, field=0, dh=True)
clip = core.std.Transpose(clip)
clip = core.eedi3m.EEDI3(clip, field=0, dh=True)
clip = core.std.Transpose(clip)
{{/UPSCALE_EEDI3}}
{{/RESIZE_INTEGER_UPSCALE}}
{{#RESIZE_STANDARD}}
{{#MAINTAIN_ASPECT}}
# Resize maintaining aspect ratio
{{/MAINTAIN_ASPECT}}
{{#RESIZE_SPLINE36}}
clip = core.resize.Spline36(clip, width={{TARGET_WIDTH}}, height={{TARGET_HEIGHT}})
{{/RESIZE_SPLINE36}}
{{#RESIZE_LANCZOS}}
clip = core.resize.Lanczos(clip, width={{TARGET_WIDTH}}, height={{TARGET_HEIGHT}})
{{/RESIZE_LANCZOS}}
{{#RESIZE_BICUBIC}}
clip = core.resize.Bicubic(clip, width={{TARGET_WIDTH}}, height={{TARGET_HEIGHT}})
{{/RESIZE_BICUBIC}}
{{#RESIZE_BILINEAR}}
clip = core.resize.Bilinear(clip, width={{TARGET_WIDTH}}, height={{TARGET_HEIGHT}})
{{/RESIZE_BILINEAR}}
{{/RESIZE_STANDARD}}
{{/RESIZE}}

# Output the processed clip
clip.set_output()
