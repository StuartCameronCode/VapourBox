# Feature map: VapourBox and other video tools

How VapourBox compares with the tools people also use to convert, restore and
archive video:
- encoder front-ends (HandBrake, FastFlix, StaxRip, Hybrid, Shutter Encoder);
- AI enhancers (Topaz Video, Video2X, Flowframes, REAL Video Enhancer, FluidFrames / QualityScaler);
- the open-source restoration tools listed in [sd-video-restore#1](https://github.com/gljuks/sd-video-restore/issues/1);
- script editors;
- the archival tools that sit beside all of them.

**As of 2026-11-10.** Every tool here is under active development, so check the
links at the end of this page before you rely on a cell. Corrections are welcome
as an [issue](https://github.com/StuartCameronCode/VapourBox/issues).

## How to read it

| Mark | Meaning |
|---|---|
| ✅ | Built in |
| 🟡 | Partly. It needs a plugin, script or manual setup, works only on some platforms or hardware, or is in development but not released. The cell says which |
| ❌ | Not available. The tool's own docs, settings list or source show it is absent |
| ❓ | Not confirmed either way. The tool's docs don't say |
| — | Outside what the tool is built for |

**Method and limits.** Each cell comes from the tool's own README,
documentation, release notes or source code, read on 2026-11-10. Licence,
release and activity data come from the GitHub API. Nothing was installed or
tested hands-on, so a ✅ means "documented", not "works well". ❓ is used
whenever the documentation is silent; it never means "probably". The VapourBox
column comes from this repository (README, filter schemas, worker source). Many
small projects document little, so their columns are mostly ❓. That says how
much they document, not how good they are. The sources for each tool are listed
under [Sources](#sources).

This map is written by VapourBox's author. That is the reason for the
[gaps](#where-vapourbox-is-behind) section, and for holding the VapourBox column
to the same standard as the others.

## At a glance

| Tool | Platforms | Licence / price | QTGMC | IVTC | Classical restoration filters | AI upscaling | AI interpolation | Audio restoration | Speech-to-text subtitles | ProRes / FFV1 | AV1 | Hardware encoding | Before/after preview |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **VapourBox** | macOS, Win, Linux | GPL-3.0, free | ✅ | ✅ | ✅ broad | ✅ | ✅ RIFE | ✅ | ✅ Whisper | ✅ / ✅ | ❌ | ✅ | ✅ |
| HandBrake | macOS, Win, Linux | GPL-2.0, free | ❌ | ✅ | 🟡 a few | ❌ | ❌ | 🟡 in development | ❌ | ✅ / ✅ | ✅ | ✅ | 🟡 live preview |
| FastFlix | macOS, Win, Linux | MIT, free | ❌ | ❓ | 🟡 a few | ❌ | ❌ | ❓ | ❓ | ❌ / ❌ | ✅ | ✅ | 🟡 thumbnail |
| StaxRip | Win | MIT, free | ✅ | ✅ | ✅ broad (AviSynth/VapourSynth) | 🟡 NVIDIA VSR | ❓ | ❓ | ❓ | ❓ / ❓ | ✅ | ✅ | ✅ |
| Hybrid | macOS, Win, Linux | Closed, free for personal use | ✅ | ✅ | ✅ broad (VapourSynth/AviSynth) | ✅ | ✅ RIFE | ❓ | ❓ | ✅ / ✅ | ✅ | ✅ | ✅ |
| Shutter Encoder | macOS, Win, Linux | GPL-3.0, free | ❌ | ✅ | 🟡 some (FFmpeg) | ✅ Real-ESRGAN | ❓ | ❓ | ✅ Whisper | ✅ / ✅ | ✅ | ✅ | 🟡 player |
| VirtualDub2 | Win | GPL-2.0, free | 🟡 via script | ✅ | 🟡 a few | ❓ | ❓ | ❓ | ❓ | ✅ / ✅ | 🟡 external FFmpeg | 🟡 external FFmpeg | ✅ |
| VapourSynth Editor / AvsPmod | Win (vsedit also builds on macOS/Linux) | MIT / GPL-2.0, free | 🟡 via script | 🟡 via script | 🟡 via script | ❓ | ❓ | ❓ | ❓ | 🟡 external encoder | 🟡 external encoder | 🟡 | ✅ |
| Topaz Video | macOS (Apple Silicon), Win | Proprietary, subscription | ❌ | 🟡 | AI equivalents | ✅ own models | ✅ own models | ❓ | ❓ | ✅ / ✅ | 🟡 Win, some GPUs | 🟡 NVENC | ✅ |
| Video2X | Win, Linux | AGPL-3.0, free | ❌ | ❌ | ❌ | ✅ | ✅ RIFE | ❓ | ❓ | 🟡 any FFmpeg encoder | 🟡 any FFmpeg encoder | ❓ | ❓ |
| Flowframes | Win | GPL-3.0, pay what you want | — | — | — | ❌ | ✅ RIFE, DAIN, FLAVR… | ❓ | ❓ | ✅ / ✅ | ✅ | ✅ | 🟡 output only |
| REAL Video Enhancer | macOS, Win, Linux | AGPL-3.0, free | ❓ | ❓ | 🟡 AI deblock/denoise | ✅ | ✅ RIFE, GMFSS… | ❓ | ❓ | ✅ / ✅ | ✅ | 🟡 NVENC, VAAPI | 🟡 output only |
| FluidFrames / QualityScaler | Win | MIT source; ready-made builds paid | — | — | — | ✅ QualityScaler | ✅ FluidFrames | ❓ | ❓ | ❌ / ❌ | ❌ | ✅ | 🟡 |
| sd-video-restore | Win, Colab | No licence stated | ✅ | ❓ | 🟡 a few | 🟡 separate release | ❓ | ❓ | ❓ | ❓ / ❓ | ❓ | 🟡 NVENC | ❓ |
| Video Enhancer (ErynVorn) | Win + NVIDIA | MIT, free | ❌ | ❓ | 🟡 a few | ✅ | ❓ | ✅ | ❓ | ❓ / ❓ | ❓ | 🟡 NVENC | 🟡 |
| RestoraX | Any (Python, Docker) | MIT, free | ❓ | ❓ | 🟡 AI dust/scratch | ✅ | ✅ RIFE | ✅ | ❓ | ❓ / ❓ | ❓ | ❓ | 🟡 |
| LTX-2.5 Enhancer Studio | Win + NVIDIA RTX | No licence stated | ❓ | ❓ | — | 🟡 generative | ❓ | ❌ | ❓ | ❓ / ❓ | ❓ | 🟡 NVENC | ✅ |
| VCG Deinterlacer (v1) | Win | MIT, free | ✅ | ✅ | ✅ several | ❌ | ❓ | ❓ | ❓ | ✅ / ✅ | ❓ | ❓ | ✅ |
| vhs-vapourizer | ❓ (Windows paths) | No licence stated | ✅ | ❓ | ❌ | ❌ | ❓ | ❓ | ❓ | ✅ / ✅ | ❓ | ❓ | 🟡 test mode |
| Auto-VHS-Deinterlacer | macOS, Win, Linux | MIT, free | ✅ | ❓ | 🟡 QTGMC's own | ❓ | ❓ | ❓ | ❓ | ✅ / ❓ | ✅ | 🟡 AV1 NVENC | ❓ |
| videer | macOS (Apple Silicon), Win, Linux | MIT, free | ✅ (QTGMC / QTempGaussMC) | ❓ | 🟡 via AviSynth script | ❓ | ❓ | ❓ | ❓ | ✅ / ❓ | ✅ | 🟡 NVENC | ❓ |

"Platforms" is what each project publishes builds for. VapourBox ships for Apple
Silicon and Intel Macs, Windows x64, and Linux x64 and arm64.

## Encoder front-ends and converters

The tools most people try first. HandBrake and FastFlix convert well and have a
few filters. StaxRip and Hybrid are full AviSynth and VapourSynth front-ends
with the same filters VapourBox uses. Shutter Encoder is a general-purpose
converter with some AI features.

| Feature | VapourBox | HandBrake | FastFlix | StaxRip | Hybrid | Shutter Encoder |
|---|---|---|---|---|---|---|
| **Basics** | | | | | | |
| Platforms | macOS arm64/x64, Win x64, Linux x64/arm64 | Win x64/ARM64, macOS 10.13+, Linux (Flatpak) | Win, macOS 15 arm64, Ubuntu x64 | Win x64 only | Win x64, macOS arm64, Linux x64 | Win, macOS, Linux |
| Licence, price | GPL-3.0, free | GPL-2.0 (most files), free | MIT, free | MIT, free | Closed source, free for personal use, no redistribution | GPL-3.0, free |
| Interface | GUI | GUI + CLI | GUI | GUI (switches drive the GUI) | GUI | GUI + CLI arguments (20.5) |
| Engine | VapourSynth + FFmpeg; ncnn/Vulkan and ONNX Runtime for AI | libhb + FFmpeg libraries | FFmpeg + rigaya's NVEncC/QSVEncC/VCEEncC | AviSynth+ / VapourSynth + 200+ tools | FFmpeg + VapourSynth (+ AviSynth on Win) | FFmpeg + Real-ESRGAN-ncnn, Whisper, DeOldify |
| Getting the dependencies | Downloaded on first launch (the Linux AppImage carries them) | Bundled | Offers to download FFmpeg | Bundled, portable | Bundled on Win/macOS; AI add-ons downloaded in the app | ❓ |
| Latest release | 1.7.0 (2026-11-10) | 1.11.2 (2026-06-07) | 6.3.2 (2026-11-04) | 2.52.6 (2026-09-27) | 2026.10.09.1 | 20.5 (2026-11-04) |
| **Input** | | | | | | |
| NTSC DV (4:1:1) | ✅ | ❓ | ❓ | ❓ | ❓ | ❓ |
| DVD discs / `VIDEO_TS` | ✅ (encrypted discs need libdvdcss) | ✅ also Blu-ray | ❓ | ❓ | ✅ also Blu-ray | 🟡 merges VOB files |
| 10–16-bit sources | ✅ | ✅ | ✅ | ✅ | ❓ | ❓ |
| HDR10 / HLG | ✅ | ✅ HDR10 (HLG not documented) | ✅ | ✅ HDR10 | ✅ HDR10 | ✅ |
| Dolby Vision | 🟡 profiles 7/8/9 as their base layer; profile 5 can't be decoded | ✅ profiles 5, 7.6, 8.1, 8.4 | 🟡 with rigaya's encoders | ✅ | ❓ | ❓ detected only |
| Folder / batch input | ✅ | ✅ | ❓ | ✅ | ✅ folder monitoring | ✅ |
| **Analysis** | | | | | | |
| Interlace / telecine detection | ✅ | ✅ comb detection | ✅ `idet` | ❓ | ✅ | ❓ |
| Border / crop detection | ✅ incl. head-switching band | ✅ | ✅ | ✅ | ✅ | ✅ |
| Noise measurement | ✅ noise and halo scores | ❓ | ❓ | ❓ | ❓ | ❓ |
| **Deinterlace** | | | | | | |
| QTGMC | ✅ all 70+ parameters | ❌ | ❌ | ✅ any parameter, in the script editor | ✅ many parameters | ❌ |
| Yadif / Bwdif | ✅ Bwdif | ✅ + Decomb | ✅ | ✅ | ✅ | ✅ |
| Inverse telecine | ✅ VIVTC; soft-telecine flag removal | ✅ pullup | ❓ | ✅ TIVTC, VIVTC | ✅ TIVTC, VIVTC | ✅ |
| AI deinterlacing | ❌ | ❌ | ❌ | ❓ | ❓ | ❓ |
| **Classical restoration** | | | | | | |
| Motion-compensated denoise | ✅ | 🟡 hqdn3d (not motion-compensated) | 🟡 hqdn3d, atadenoise | ✅ SMDegrain, MCTemporalDenoise… | ✅ SMDegrain, TemporalDegrain2… | ❓ |
| BM3D / NLMeans | ✅ both | ✅ NLMeans (BM3D in development) | ✅ NLMeans | ✅ both | ✅ both | ✅ NLMeans |
| Chroma, dot crawl, rainbows | ✅ | 🟡 chroma smooth | ❓ | ✅ | ✅ | ❓ |
| Dehalo | ✅ | ❌ | ❓ | ✅ | ✅ | ❓ |
| Deblock | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Deband | ✅ | 🟡 in development | ❓ | ✅ | ✅ | ✅ |
| Anti-aliasing | ✅ | ❌ | ❓ | ✅ | ✅ | ❓ |
| Dust and scratches | ✅ SpotLess, DeScratch | ❌ | ❓ | ✅ DeScratch | ✅ SpotLess, DeScratch… | ❓ |
| Deflicker | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| Stabilisation | ✅ incl. film-scan pitch | ❌ | ❓ | 🟡 plugins bundled, no profile | ✅ | ✅ vid.stab |
| Colour correction | ✅ | 🟡 colourspace, tone map | ✅ | ✅ | ✅ | ✅ |
| Film grain | ✅ | ❌ | ❓ | ✅ | ✅ | ✅ |
| **AI** | | | | | | |
| Upscaling | ✅ Real-ESRGAN, Real-CUGAN, AnimeJaNai, SPAN | ❌ | ❌ | 🟡 NVIDIA super-resolution via NVEncC | ✅ Real-ESRGAN, Real-CUGAN, BasicVSR++, … | ✅ Real-ESRGAN |
| Frame interpolation | ✅ RIFE 4.26 | ❌ | ❌ | ❓ | ✅ RIFE | ❓ |
| Face restoration | ✅ RestoreFormer++, GFPGAN, CodeFormer | ❌ | ❌ | ❓ | ✅ CodeFormer | ❓ |
| Colourisation | ✅ DDColor, DeOldify | ❌ | ❌ | ❓ | ✅ DDColor, DeOldify | ✅ DeOldify |
| AI video denoise | ❌ | ❌ | ❌ | 🟡 NVIDIA only | ✅ DPIR, SCUNet | ❓ |
| GPU back-ends | Vulkan (ncnn), Core ML, DirectML | — | — | CUDA (NVIDIA effects) | TensorRT, CUDA, Vulkan | Vulkan |
| **Frame rate** | | | | | | |
| Non-AI conversion | ✅ motion-compensated, any rate | 🟡 drop/duplicate | 🟡 drop/duplicate | ✅ InterFrame, SVPFlow… | ✅ MVTools, InterFrame, SVP | ✅ minterpolate |
| **Audio** | | | | | | |
| Passthrough / re-encode | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| Hum, clicks, hiss, clipping | ✅ + DeepFilterNet speech | 🟡 in development | ❓ | ❓ | ❓ | ❓ |
| Sync and drift correction | ✅ | ❓ | ❓ | 🟡 delay only | 🟡 delay only | 🟡 offset only |
| Loudness normalisation | ✅ | 🟡 in development | ❓ | 🟡 | ✅ | ✅ |
| **Subtitles** | | | | | | |
| Keep existing tracks | 🟡 MKV all; MP4/MOV text only | ✅ | ✅ | ✅ | ✅ | ✅ |
| Speech-to-text | ✅ Whisper | ❌ | ❓ (OCR of image subtitles only) | ❓ | ❓ | ✅ Whisper |
| Burn-in | ✅ | ✅ | ✅ | ✅ | ❓ | ✅ |
| **Output** | | | | | | |
| H.264 / H.265 | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| AV1 / VP9 | ❌ / ❌ | ✅ / ✅ | ✅ / ✅ | ✅ / ❓ | ✅ / ✅ | ✅ / ✅ |
| ProRes / FFV1 | ✅ Proxy–4444 XQ / ✅ | ✅ / ✅ | ❌ / ❌ | ❓ / ❓ | ✅ / ✅ | ✅ / ✅ |
| Hardware encoders | NVENC, QSV, AMF, VideoToolbox | NVENC, QSV, AMF, VideoToolbox, MF, VAAPI | NVENC, QSV, AMF, VideoToolbox, VAAPI | NVENC, QSV, AMF | NVENC, QSV, AMF, VideoToolbox (ProRes) | NVENC, QSV, AMF, VideoToolbox, MF, VAAPI |
| 10-bit | ✅ | ✅ | ✅ | ✅ | ❓ | ❓ |
| HDR10 static metadata kept | ✅ (x265) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Dolby Vision RPU / HDR10+ kept | ❌ / ❌ | ✅ / ✅ | 🟡 rigaya encoders / ✅ | ✅ / ✅ | ❓ / ✅ | ❓ / ❓ |
| Chapters kept | ❓ not handled explicitly | ✅ | ✅ | ✅ | ✅ | ❓ |
| Containers | MKV, MP4, MOV, AVI | MP4, MKV, WebM, MOV | MKV, MP4 (+ GIF/WebP/AVIF) | MKV, MP4, others via FFmpeg | MOV, MP4, MKV, M2TS, WebM, AVI, Blu-ray | many, incl. MXF |
| **Workflow** | | | | | | |
| Presets | ✅ named after the source (VHS, DV, film scan, anime DVD…) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Preview | ✅ before/after, frame-accurate, 1:1 | ✅ live preview | ✅ thumbnail | ✅ comparison tool | ✅ original/filtered/diff | 🟡 player |
| Trim / queue | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| Custom script or FFmpeg arguments | ✅ both | 🟡 encoder options | ✅ FFmpeg | ✅ script editor | ✅ VapourSynth sections | ✅ FFmpeg |
| Command line | 🟡 worker takes a JSON job; not documented for users | ✅ | ❓ | 🟡 | ❓ | ✅ |
| Chunked / parallel encoding | ❌ | ❓ | 🟡 NVEncC only | ✅ | 🟡 experimental | ❓ |

"In development" means the feature is on HandBrake's main branch (BM3D and
deband from PR #7693; audio filters and loudnorm from PR #8101) but not in
release 1.11.2.

## AI enhancement apps

These apps are built around neural networks rather than classical filters.
Topaz Video is the commercial reference point.

| Feature | VapourBox | Topaz Video | Video2X | Flowframes | REAL Video Enhancer | FluidFrames / QualityScaler |
|---|---|---|---|---|---|---|
| **Basics** | | | | | | |
| Platforms | macOS arm64/x64, Win x64, Linux x64/arm64 | Win x64, macOS 13+ on Apple Silicon | Win, Linux (macOS via container) | Win | Win, Linux, macOS | Win (DirectX 12 GPU) |
| Licence, price | GPL-3.0, free | Proprietary; from $299/yr (Personal) | AGPL-3.0, free | GPL-3.0; pay what you want, newer builds on Patreon | AGPL-3.0, free (also on Steam, Flathub) | MIT source; ready-made builds from $9.99 each |
| Interface | GUI | GUI | CLI + GUI (Win) | GUI | GUI (+ backend CLI) | GUI |
| Engine | VapourSynth + FFmpeg; ncnn/Vulkan, ONNX Runtime | Own models + FFmpeg | FFmpeg + ncnn/Vulkan + libplacebo | FFmpeg + PyTorch / ncnn | FFmpeg + PyTorch / TensorRT / ncnn | ONNX Runtime (DirectML) + FFmpeg |
| Latest release | 1.7.0 (2026-11-10) | 1.7.2 (2026-11-03) | 6.4.0 (2025-01-24) | free build 1.36.0; last commit 2026-05-20 | RVE-2.4.1 (2026-01-02); refactor in progress | 2026.4 (2026-09 / 2026-08) |
| **Input** | | | | | | |
| NTSC DV / DVD | ✅ / ✅ | ✅ `.dv` / 🟡 `.vob` files | ❓ / ❓ | ❓ / ❓ | ❓ / ❓ | ❓ / ❓ |
| 10–16-bit, HDR | ✅ | ❓ | 🟡 processed as 8-bit | ❓ | 🟡 HDR mode only | ❌ 8-bit processing |
| Batch | ✅ | ✅ | 🟡 GUI queue | ✅ | ✅ | ✅ |
| **Analysis** | | | | | | |
| Interlace / telecine detection | ✅ | ❓ (user chooses video type) | ❌ | ❓ | ❓ | — |
| Border / crop detection | ✅ | ✅ | ❌ | ❓ | ✅ | — |
| **Deinterlace** | | | | | | |
| QTGMC / IVTC | ✅ / ✅ | ❌ / 🟡 | ❌ / ❌ | — | ❓ / ❓ | — |
| AI deinterlacing | ❌ | ✅ Dione, Iris, Proteus | ❌ | — | ❓ | — |
| **Restoration** | | | | | | |
| Classical filters (denoise, dehalo, deblock, dust, deflicker…) | ✅ | AI equivalents only | ❌ | — | ❓ | — |
| AI denoise | ❌ | ✅ Nyx | 🟡 Real-CUGAN noise level | — | ✅ DRUNet, DnCNN | ✅ IRCNN (QualityScaler) |
| AI dehalo / deblock / motion deblur | 🟡 Live Action SPAN upscaler repairs compression and halos | ✅ | ❌ | — | 🟡 deblock (DeH264) | — |
| Stabilisation | ✅ | ✅ | ❌ | — | ❓ | — |
| Film grain | ✅ | ✅ | ❌ | — | ❓ | — |
| **AI** | | | | | | |
| Upscaling | ✅ Real-ESRGAN, Real-CUGAN, AnimeJaNai, SPAN | ✅ Proteus, Iris, Rhea, Gaia, … | ✅ Real-ESRGAN, Real-CUGAN, Anime4K | ❌ | ✅ SPAN, AnimeJaNai, OpenProteus, custom models | ✅ Real-ESRGAN, BSRGAN, … (QualityScaler) |
| Frame interpolation | ✅ RIFE 4.26 | ✅ Apollo, Chronos, Aion | ✅ RIFE (to 4.26) | ✅ RIFE, DAIN, FLAVR, XVFI, IFRNet | ✅ RIFE, GMFSS, IFRNet | ✅ RIFE (FluidFrames) |
| Face restoration | ✅ | ✅ Iris | ❌ | — | ❓ | — |
| Colourisation | ✅ | ❓ | ❌ | — | ❓ | — |
| Generative / diffusion restoration | ❌ | ✅ Starlight (some variants cloud-only) | ❌ | — | ❓ | — |
| SDR → HDR | ❌ | ✅ | ❓ | — | ❓ | — |
| GPU back-ends | Vulkan (ncnn), Core ML, DirectML | NVIDIA, AMD, Intel, Apple | Vulkan (ncnn) | CUDA, Vulkan | TensorRT, CUDA, ROCm, Vulkan, MPS, DirectML | DirectML |
| **Audio and subtitles** | | | | | | |
| Audio passthrough | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Audio restoration | ✅ | ❓ | ❓ | ❓ | ❓ | ❓ |
| Subtitles kept / speech-to-text | 🟡 / ✅ | ❓ / ❓ | ✅ / ❓ | ✅ / ❓ | ✅ / ❓ | ❌ / ❓ |
| **Output** | | | | | | |
| H.264 / H.265 | ✅ / ✅ | ✅ / ✅ | 🟡 any FFmpeg encoder | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| AV1 / VP9 | ❌ / ❌ | 🟡 Win, RTX 40 / Arc / ✅ | 🟡 any FFmpeg encoder | ✅ / ✅ | ✅ / ✅ | ❌ / ❌ |
| ProRes / FFV1 | ✅ / ✅ | ✅ / ✅ | 🟡 any FFmpeg encoder | ✅ / ✅ | ✅ / ✅ | ❌ / ❌ |
| Hardware encoders | NVENC, QSV, AMF, VideoToolbox | 🟡 NVENC documented | ❓ | NVENC, AMF, QSV | NVENC, VAAPI | NVENC, AMF, QSV |
| 10-bit output | ✅ | ✅ | 🟡 | ✅ | ✅ | ❌ |
| **Workflow** | | | | | | |
| Presets | ✅ | ✅ | ❓ | ❓ | 🟡 encoder presets | ❓ |
| Before/after preview | ✅ | ✅ | ❓ | 🟡 output only | 🟡 output only | 🟡 |
| Trim / queue | ✅ / ✅ | ✅ / ✅ | ❌ / ✅ | ✅ / ✅ | 🟡 / ✅ | ❓ / ✅ |
| Command line | 🟡 | 🟡 export as FFmpeg command | ✅ | ❓ | 🟡 backend | ❌ |

REAL Video Enhancer was briefly marked "archived until further notice" in its
README (July–September 2026). The notice has since been removed, and work
continues on a `refactor` branch. FluidFrames and QualityScaler are free to
build from source; the ready-made Windows builds are paid.

## Community restoration tools

Mostly small, recent projects aimed at the same jobs as VapourBox: VHS, Hi8 and
DV captures and old footage. Several are a few weeks or months old. Their
columns reflect what they document now.

| Feature | VapourBox | sd-video-restore | Video Enhancer | RestoraX | LTX-2.5 Enhancer Studio | VCG Deinterlacer (v1) | vhs-vapourizer | Auto-VHS-Deinterlacer | videer |
|---|---|---|---|---|---|---|---|---|---|
| **Basics** | | | | | | | | | |
| Platforms | macOS, Win, Linux | Win, Google Colab | Win + NVIDIA GPU | Any (Python 3.11, Docker) | Win + NVIDIA RTX | Win | ❓ | macOS, Win, Linux | macOS arm64, Win, Linux |
| Licence | GPL-3.0 | none stated | MIT (models have their own) | MIT | none stated; source not published | MIT | none stated | MIT | MIT |
| Interface | GUI | Scripts + dialog | GUI + CLI | Web UI, REST API, CLI | GUI | GUI wizard | CLI script | CLI launcher | GUI |
| Engine | VapourSynth + FFmpeg | VapourSynth + FFmpeg | FFmpeg + PyTorch | PyTorch + FFmpeg | ComfyUI + LTX-2.5 + FFmpeg | VapourSynth + FFmpeg | VapourSynth + FFmpeg | VapourSynth + FFmpeg | FFmpeg + AviSynth+ / VapourSynth |
| Latest release | 1.7.0 (2026-11-10) | v0.1-ai (2026-06-19) | none (first commit 2026-10-12) | none (active) | v1.2.0 (2026-10-11) | v1.8.0 (2026-10-05) | none (last commit 2025-09-24) | v1.1.9 (2026-10-20) | 3.17.5 (2026-11-06) |
| **Input** | | | | | | | | | |
| NTSC DV (4:1:1) | ✅ | ✅ DV presets | 🟡 `.dv` files | ❓ | ❓ | ✅ | ❓ | ❓ | ❓ |
| DVD | ✅ discs, `VIDEO_TS` | ❓ | 🟡 `.vob` files | ❓ | ❓ | 🟡 MPEG-2 files | ❓ | ❓ | ❓ |
| 10–16-bit sources | ✅ | ❓ | ❓ (8-bit processing) | ❓ (8-bit processing) | ❓ | 🟡 converted to 8-bit | ❓ | 🟡 | ❓ |
| Batch | ✅ | ✅ | ❓ | 🟡 API job queue | ✅ | ✅ | ❓ | ✅ | ✅ |
| **Analysis** | | | | | | | | | |
| Interlace / telecine detection | ✅ | ❓ (chosen by preset) | ✅ interlace | 🟡 per frame | ❓ | ✅ incl. pulldown | 🟡 field order check | 🟡 PAL/NTSC only | ❓ |
| Border / crop detection | ✅ | ❓ | ❓ | ❓ | ❓ | ❓ (v2.0 claims auto-crop) | ❓ | ❓ | ❓ |
| Noise / halo measurement | ✅ | ❓ | ❓ | ❓ | ❓ | ✅ noise, halo, cast, bleed | ❓ | ❓ | — (VMAF CRF search instead) |
| **Deinterlace** | | | | | | | | | |
| QTGMC | ✅ all parameters | ✅ field order only | ❌ | ❓ | ❓ | ✅ fixed settings | ✅ hard-coded | ✅ several parameters | ✅ QTGMC (Win) or QTempGaussMC |
| Yadif / Bwdif | ✅ | ❓ | ✅ Bwdif | ✅ Yadif | ❓ | ❓ | ❓ | ❌ | ✅ |
| Inverse telecine | ✅ | ❓ | ❓ | ❓ | ❓ | ✅ | ❓ | ❓ | ❓ |
| **Classical restoration** | | | | | | | | | |
| Denoise | ✅ MC, BM3D, NLMeans, … | 🟡 hqdn3d | 🟡 hqdn3d | ❓ | ❓ | ✅ BM3D, KNLMeansCL, SMDegrain | ❓ | 🟡 QTGMC's own | ❓ |
| Chroma, dehalo, deblock, deband, AA | ✅ | ❓ | ❌ chroma bleed not repaired | ❓ | ❓ | 🟡 dehalo, Y/C delay | ❓ | ❓ | 🟡 via AviSynth script |
| Dust, scratches, deflicker | ✅ | ❓ | ❓ | ✅ AI inpainting (ProPainter) | ❓ | ❓ | ❓ | ❓ | 🟡 via AviSynth script |
| Stabilisation | ✅ | ❓ | ❓ | 🟡 | ❓ | ❓ | ❓ | ❓ | ❓ |
| Colour correction / grain | ✅ / ✅ | ❓ / ❓ | ❓ / ❓ | ❓ / ❓ | ❓ / ❓ | ✅ / ✅ | ❓ / ❓ | ❓ / ❓ | ❓ / ❓ |
| **AI** | | | | | | | | | |
| Upscaling | ✅ | 🟡 Real-CUGAN in the AI release asset | ✅ SPAN, Real-ESRGAN, RealPLKSR | ✅ Real-ESRGAN, BasicVSR++, VRT, … | 🟡 generative, to a target size | ❌ NNEDI3 | ❌ NNEDI3 | ❓ | ❓ |
| Interpolation / face / colour | ✅ / ✅ / ✅ | ❓ | ❓ | ✅ RIFE / ✅ CodeFormer, GFPGAN / ✅ DDColor | ❓ | ❓ | ❓ | ❓ | ❓ |
| Diffusion restoration | ❌ | ❓ | ❓ | ❌ not implemented yet | ✅ LTX-2.5 + LoRAs | ❓ | ❓ | ❓ | ❓ |
| **Audio** | | | | | | | | | |
| Restoration (hum, clicks, hiss, speech) | ✅ | ❓ | ✅ incl. DeepFilterNet | ✅ Demucs, VoiceFixer, RNNoise | ❌ | ❓ | ❓ | ❓ | ❓ |
| Sync / drift correction | ✅ | 🟡 `-async 1` | 🟡 filter delays only | ❓ | ❓ | 🟡 | ❌ no audio yet | ✅ | 🟡 start offset |
| Loudness | ✅ | ❓ | ✅ EBU R128 | ❓ | ❓ | ❓ | — | ❓ | ❓ |
| **Subtitles** | | | | | | | | | |
| Keep existing / speech-to-text | 🟡 / ✅ | ❓ / ❓ | ❌ / ❓ | ❓ / ❓ | ✅ / ❓ | ❓ / ❓ | ❓ / ❓ | ❓ / ❓ | ✅ / ❓ |
| **Output** | | | | | | | | | |
| Codecs | H.264, H.265, ProRes, FFV1, HuffYUV | H.264 | H.264, H.265 (NVENC) | H.264 | H.265 (NVENC) | H.264, ProRes HQ, FFV1, HuffYUV, UT Video | ProRes HQ, FFV1 | ProRes HQ, AV1 | H.264, H.265, AV1, VP9, ProRes, VVC |
| 10-bit output | ✅ | ❌ | ❌ | ❌ | ✅ | 🟡 ProRes only | ✅ | ✅ | 🟡 |
| Containers | MKV, MP4, MOV, AVI | MP4 | MP4 | by file extension | MP4, MOV, MKV | MP4, MOV, MKV, AVI | MKV, MOV | MOV, MKV | MKV, MP4, AVI, MOV, WebM |
| **Workflow** | | | | | | | | | |
| Presets | ✅ | ✅ by source (PAL DV, VHS, NTSC DV) | ❓ | ✅ pipelines (VHS, film, newsreel…) | 🟡 | ❓ | ❓ | 🟡 hardware profiles | ✅ |
| Before/after preview | ✅ | ❓ | 🟡 10 s render | 🟡 image compare | ✅ | ✅ | 🟡 test mode | ❓ | ❓ |
| Queue / command line | ✅ / 🟡 | ✅ / ✅ | ❓ / ✅ | ✅ / ✅ | ✅ / ❓ | ✅ / ❓ | ❓ / ✅ | ✅ / ✅ | ✅ / 🟡 |

Notes:
- **VCG Deinterlacer** has a successor, a Rust rewrite called
  [VCG-Deinterlacer 2.0](https://github.com/Video-Capture-Guide/VCG-Deinterlacer-2.0)
  (MIT, v2.0.6, 2026-11-07). It says it "measures your capture, auto-crops the
  blanking, and writes an archival master". The v1 column above is not a
  statement about 2.0.
- **videer** chooses a CRF per file by measuring quality (VMAF, SSIM and
  others). None of the other tools here do this.
- **Auto-VHS-Deinterlacer** encodes in resumable 5-minute segments.

## Script editors

These write and preview your own AviSynth or VapourSynth scripts. Anything a
plugin can do is possible, but you install the plugins and write the script
yourself. That is the work VapourBox, StaxRip and Hybrid do for you.

| | VirtualDub2 | VapourSynth Editor (YomikoR fork) | AvsPmod (gispos fork) |
|---|---|---|---|
| Platforms | Win | Win builds; macOS and Linux build from source | Win |
| Licence | GPL-2.0 | MIT | GPL-2.0 |
| Status | Last release build 44282 (2020-03-19); dormant | R19-mod-6.10 (2026-04-17); active | 2.7.9.7 (2026-04-20); active |
| Built-in filters | Yadif, IVTC, temporal smoother, levels, colour tools, frame-rate interpolation (blending) | None; your VapourSynth script | None; your AviSynth script |
| QTGMC | 🟡 through an AviSynth or VapourSynth script | 🟡 your script | 🟡 your script |
| Output | Built in: H.264, H.265, VP9, ProRes, FFV1, HuffYUV, 10-bit; others via an external FFmpeg | Pipes to any encoder you configure | FFmpeg / x264 presets you supply (incl. AV1, NVENC) |
| Preview, trim, queue | ✅ timeline, ✅ cuts, ✅ job control | ✅ previewer, script trim, ✅ job queue | ✅ preview with sliders, ✅ trim editor, 🟡 batch file |

## Archival tools that work alongside VapourBox

These tools capture, check or package video rather than restore it. A common
archival workflow:

1. Capture with vrecord or DVRescue.
2. Check the capture with QCTools.
3. Keep the lossless master (FFV1/MKV).
4. Restore a copy with VapourBox for viewing or delivery, keeping the master untouched.

| Tool | What it does | Platforms | Licence | Latest release | How it fits with VapourBox |
|---|---|---|---|---|---|
| [vrecord](https://github.com/amiaopensource/vrecord) | Captures analogue or SDI video through Blackmagic cards (and DV on macOS) to archival formats (FFV1, v210, ProRes…), with framemd5, MediaConch checks and QCTools reports | macOS, Linux | CC BY 4.0 | 2026-10-05 | Capture before restoration; VapourBox doesn't capture |
| [DVRescue](https://github.com/mipops/dvrescue) | Transfers DV tape over FireWire, reports DV errors from per-frame metadata, merges several transfers into the best copy | macOS (GUI), Windows and Linux (CLI) | BSD-3-Clause | v24.07 (2025-03-02) | The best possible DV master before VapourBox processes it |
| [QCTools](https://github.com/bavc/qctools) | Graphs per-frame signal statistics (levels, TOUT, VREP, crop, PSNR) to find capture errors; `qcli` makes reports headlessly | macOS, Windows, Linux | GPL-3.0 (BAVC's code BSD-3-Clause) | 1.4 (2025-01-03) | Check a capture before restoring; compare before/after statistics |
| [RAWcooked](https://github.com/MediaArea/RAWcooked) | Losslessly and reversibly packs DPX/TIFF/EXR film-scan sequences into FFV1/FLAC MKV | macOS, Windows, Linux | BSD-2-Clause (paid support for some formats) | v25.12 (2025-12-30) | Store film scans compactly, then feed the MKV to VapourBox |
| [MediaConch](https://mediaarea.net/MediaConch) | Checks preservation files (MKV, FFV1, LPCM) against specifications and policies | macOS, Windows, Linux | BSD-2-Clause | v25.04 (2025-05-05) | Validate the FFV1 masters VapourBox writes |

## Where VapourBox fits

### Where it is ahead

- **One app for the whole restoration job.** It covers:
  - classical VapourSynth restoration (QTGMC, IVTC, motion-compensated and BM3D denoising, dehalo, dust, deflicker, stabilisation);
  - AI upscaling, interpolation, face restoration and colourisation;
  - audio restoration, including drift correction;
  - Whisper subtitles.

  Hybrid comes closest in breadth, but it is closed source and its
  documentation covers neither audio restoration nor speech-to-text. StaxRip has the classical filters, but on
  Windows only and with little AI.
- **Analysis that sets things up for you.** VapourBox detects:
  - interlacing and telecine;
  - borders, blanking and the head-switching band;
  - a studio upscale's native resolution;
  - noise and halos.

  The pass list then marks what the source needs. Among the tools here, only
  VCG Deinterlacer documents a comparable noise/halo measurement.
- **Every platform, without setup.** It runs on Apple Silicon and Intel Macs,
  Windows, and Linux x64 and arm64, and everything is downloaded or bundled.
  StaxRip, VCG Deinterlacer, Flowframes, FluidFrames and several community tools
  are Windows-only. Several AI tools need an NVIDIA GPU.
- **Tape and disc sources handled correctly.** It reads NTSC DV's 4:1:1 chroma,
  10–16-bit film scans and variable-frame-rate phone video, reads DVDs and
  `VIDEO_TS` directly, and carries aspect ratio and colour tags through.
- **A preview that matches the encode.** The before/after preview is
  frame-accurate and shows every generated frame of a rate conversion, at 1:1
  if you want. The presets are named after the source, not the technique.

### Where VapourBox is behind

These gaps are candidates for future work:

- **No AV1 or VP9 output.** HandBrake, FastFlix, StaxRip, Hybrid, Shutter
  Encoder, Flowframes, REAL Video Enhancer, videer and Auto-VHS-Deinterlacer all
  offer AV1.
- **No Dolby Vision RPU or HDR10+ passthrough.** HandBrake, StaxRip and FastFlix
  (on some encoders) keep both. VapourBox keeps HDR10 static metadata only, and
  can't decode Dolby Vision profile 5.
- **No chunked or parallel encoding.** StaxRip has it, Hybrid has it
  experimentally, and Auto-VHS-Deinterlacer encodes in resumable segments.
- **No documented command line.** HandBrake, Shutter Encoder (since 20.5),
  Video2X and RestoraX have one. VapourBox's worker runs a JSON job, but that
  isn't documented as a user interface.
- **No NVIDIA-specific AI back-ends.** Hybrid and REAL Video Enhancer offer
  TensorRT and CUDA, which are often faster on NVIDIA cards than VapourBox's
  Vulkan (ncnn) path. VapourBox's speed against them has not been measured.
- **Fewer AI model families.** VapourBox has no AI deinterlacing, AI video
  denoising, motion deblur, SDR→HDR, or diffusion-based restoration. Topaz Video
  has all of these, Hybrid has DPIR/SCUNet denoising, and LTX-2.5 Enhancer
  Studio is diffusion-based.
- **Blu-ray input.** HandBrake and Hybrid read Blu-ray discs and folders.
  VapourBox reads DVDs only.
- **Subtitles and chapters.** MP4/MOV output keeps only text subtitles (DVD
  image subtitles survive only in MKV). Chapter handling is FFmpeg's default:
  VapourBox does nothing special with chapters, and it hasn't been tested.
- **No capture.** None of the restoration apps here capture. Use vrecord or
  DVRescue first.

### Related investigation

[QTempGaussMC](https://github.com/Jaded-Encoding-Thaumaturgy/vs-jetpack), the
vs-jetpack rewrite of QTGMC raised in sd-video-restore#1, is a library rather
than an app. videer uses it. VapourBox measured it as an alternative
deinterlacer and decided not to adopt it for now. The measurements and reasons
are in [docs/reports/issue-117-qtempgaussmc](reports/issue-117-qtempgaussmc/index.html).

## Also considered

- **MeGUI** (Windows, AviSynth front-end): last build 2944, 2023-05-07; unmaintained.
- **Avidemux**: cross-platform editor and encoder; last stable 2.8.1, 2022-09; development continues on GitHub.
- **VidCoder**: Windows front-end that uses HandBrake's engine; its filters and formats follow HandBrake's.
- **DaVinci Resolve Studio**: a paid editing and grading suite. It has Super Scale upscaling, deinterlacing, temporal noise reduction, dust and deflicker tools, and optical-flow retiming. It is an editor rather than a batch restoration tool, so it is not in the tables.
- **Upscayl** and other image-only upscalers: left out because they don't process video.

## Sources

Read on 2026-11-10. GitHub licence, release and activity data come from the
GitHub API.

- **VapourBox:**
  - [README](../README.md)
  - filter schemas in `app/assets/filters/core/`
  - `worker/src/models/video_job.rs` (`VideoCodec`, `ContainerFormat`)
  - `worker/src/pipeline_executor.rs` (stream mapping)
- **HandBrake:**
  - [filters](https://handbrake.fr/docs/en/latest/technical/filters-summary.html)
  - [HDR and Dolby Vision](https://handbrake.fr/docs/en/latest/technical/hdr.html)
  - [subtitles](https://handbrake.fr/docs/en/latest/advanced/subtitles.html)
  - [source formats](https://handbrake.fr/docs/en/latest/technical/source-formats.html)
  - [queue](https://handbrake.fr/docs/en/latest/advanced/queue.html)
  - [preview](https://handbrake.fr/docs/en/latest/workflow/preview-settings.html)
  - [downloads](https://handbrake.fr/downloads.php)
  - [1.11.0 release notes](https://github.com/HandBrake/HandBrake/releases/tag/1.11.0)
  - [`libhb/common.c`](https://github.com/HandBrake/HandBrake/blob/master/libhb/common.c)
  - [`libhb/handbrake/common.h`](https://github.com/HandBrake/HandBrake/blob/master/libhb/handbrake/common.h)
  - [`test/test.c`](https://github.com/HandBrake/HandBrake/blob/master/test/test.c)
  - [BM3D commits](https://github.com/HandBrake/HandBrake/commits/master/libhb/bm3d.c)
  - [audio filter commits](https://github.com/HandBrake/HandBrake/commits/master/libhb/avaudiofilters.c)
- **FastFlix:**
  - [README](https://github.com/cdgriffith/FastFlix/blob/master/README.md)
  - [`advanced_panel.py`](https://github.com/cdgriffith/FastFlix/blob/master/fastflix/widgets/panels/advanced_panel.py)
  - [encoders](https://github.com/cdgriffith/FastFlix/tree/master/fastflix/encoders)
  - [`flix.py`](https://github.com/cdgriffith/FastFlix/blob/master/fastflix/flix.py)
  - [NVEncC command builder](https://github.com/cdgriffith/FastFlix/blob/master/fastflix/encoders/nvencc_hevc/command_builder.py)
  - [6.3.2 release](https://github.com/cdgriffith/FastFlix/releases/tag/6.3.2)
- **StaxRip:**
  - [README](https://github.com/staxrip/staxrip/blob/master/README.md)
  - [features](https://github.com/staxrip/staxrip/blob/master/Docs/Introduction/Features.md)
  - [system requirements](https://github.com/staxrip/staxrip/blob/master/Docs/Introduction/System-Requirements.md)
  - [command line](https://github.com/staxrip/staxrip/blob/master/Docs/Usage/Command-Line-Interface.md)
  - [AviSynth profiles](https://github.com/staxrip/staxrip/blob/master/Source/Video/AviSynthFilterProfileDefaults.txt)
  - [VapourSynth profiles](https://github.com/staxrip/staxrip/blob/master/Source/Video/VapourSynthFilterProfileDefaults.txt)
  - [`Package.vb`](https://github.com/staxrip/staxrip/blob/master/Source/General/Package.vb)
  - [`NVEnc.vb`](https://github.com/staxrip/staxrip/blob/master/Source/Encoding/NVEnc.vb)
  - [changelog](https://github.com/staxrip/staxrip/blob/master/CHANGELOG.md)
- **Hybrid:**
  - [home](https://www.selur.de/)
  - [downloads](https://www.selur.de/downloads)
  - [licence](https://www.selur.de/license)
  - [changelog](https://www.selur.de/changelog)
- **Shutter Encoder:**
  - [README](https://github.com/paulpacifico/shutter-encoder/blob/master/README.md)
  - [documentation](https://www.shutterencoder.com/documentation/)
  - [20.5 release](https://github.com/paulpacifico/shutter-encoder/releases/tag/20.5)
  - source files `Corrections.java`, `VideoEncoders.java`, `Picture.java` and `AdvancedFeatures.java` in [the repository](https://github.com/paulpacifico/shutter-encoder)
- **VirtualDub2:**
  - [mirror](https://github.com/shekh/VirtualDub2)
  - [wiki](https://sourceforge.net/p/vdfiltermod/wiki/Home/)
  - [changes](https://sourceforge.net/p/vdfiltermod/wiki/changes/)
  - [compression](https://sourceforge.net/p/vdfiltermod/wiki/compression/)
  - [format changes](https://sourceforge.net/p/vdfiltermod/wiki/format_changes/)
- **VapourSynth Editor:** [repository, README and CHANGELOG](https://github.com/YomikoR/VapourSynth-Editor)
- **AvsPmod:** [repository, readme, changelog and FFmpeg presets](https://github.com/gispos/AvsPmod)
- **Topaz Video:**
  - [file formats and encoders](https://docs.topazlabs.com/topaz-video/reference-guide/supported-file-formats-encoders-and-containers)
  - [enhancement models](https://docs.topazlabs.com/topaz-video/filters/enhancement)
  - [frame interpolation](https://docs.topazlabs.com/topaz-video/filters/frame-interpolation)
  - [Starlight](https://docs.topazlabs.com/topaz-video/project-starlight-series)
  - [stabilisation](https://docs.topazlabs.com/topaz-video/filters/stabilization)
  - [denoise](https://docs.topazlabs.com/topaz-video/filters/denoise)
  - [grain](https://docs.topazlabs.com/topaz-video/filters/grain)
  - [trim and crop](https://docs.topazlabs.com/topaz-video/reference-guide/trim-and-crop)
  - [presets](https://docs.topazlabs.com/topaz-video/reference-guide/presets)
  - [import and export](https://docs.topazlabs.com/topaz-video/reference-guide/importing-previewing-and-exporting)
  - [system requirements](https://docs.topazlabs.com/topaz-video/system-requirements)
  - [pricing](https://www.topazlabs.com/pricing)
  - [1.7.2 release](https://community.topazlabs.com/t/topaz-video-1-7-2-patch/105580)
- **Video2X:**
  - [README](https://github.com/k4yt3x/video2x)
  - [`argparse.cpp`](https://github.com/k4yt3x/video2x/blob/master/tools/video2x/src/argparse.cpp)
  - [documentation](https://docs.video2x.org)
  - [Qt6 GUI](https://github.com/k4yt3x/video2x-qt6)
- **Flowframes:**
  - [README and source (`Data/Enums.cs`, `Data/Implementations.cs`)](https://github.com/n00mkrad/flowframes)
  - [itch.io page](https://nmkd.itch.io/flowframes)
- **REAL Video Enhancer:**
  - [README, `backend/rve-backend.py`, `backend/src/utils/Encoders.py` and README history](https://github.com/TNTwise/REAL-Video-Enhancer)
- **FluidFrames / QualityScaler:**
  - [FluidFrames](https://github.com/Djdefrag/FluidFrames)
  - [QualityScaler](https://github.com/Djdefrag/QualityScaler)
  - [QualityScaler on itch.io](https://jangystudio.itch.io/qualityscaler)
  - [FluidFrames on itch.io](https://jangystudio.itch.io/fluidframesrife)
- **sd-video-restore:**
  - [README, `restore.vpy`, `convert.bat`, `create.ps1`](https://github.com/gljuks/sd-video-restore)
  - [releases](https://github.com/gljuks/sd-video-restore/releases)
- **Video Enhancer:** [README and `enhancer.py`](https://github.com/ErynVornTechnologies/Video-Enhancer)
- **RestoraX:** [README, `restorax/video/writer.py`, presets](https://github.com/karailker/restorax)
- **LTX-2.5 Enhancer Studio:**
  - [README and screenshots](https://github.com/skv89/LTX-2.5-Enhancer-Studio)
  - [releases](https://github.com/skv89/LTX-2.5-Enhancer-Studio/releases)
- **VCG Deinterlacer:**
  - [README, release notes, `vcg_deinterlacer_v130.py`](https://github.com/Video-Capture-Guide/VCG-Deinterlacer)
  - [VCG-Deinterlacer 2.0](https://github.com/Video-Capture-Guide/VCG-Deinterlacer-2.0)
- **vhs-vapourizer:** [README, `upscale.vpy`, `vs_pipeline.py`](https://github.com/Hank-tha-Cowdog/vhs-vapourizer)
- **Auto-VHS-Deinterlacer:** [README, `config.yaml`, `modules/runtime/`](https://github.com/ventura8/Auto-VHS-Deinterlacer)
- **videer:** [README, `utils/ffmpeg_utils.py`, `modules/frameservers/`](https://github.com/hclivess/videer)
- **Archival tools:**
  - [vrecord](https://github.com/amiaopensource/vrecord)
  - [DVRescue documentation](https://mipops.github.io/dvrescue/)
  - [QCTools](https://mediaarea.net/QCTools)
  - [RAWcooked](https://mediaarea.net/RAWcooked)
  - [MediaConch](https://mediaarea.net/MediaConch)
- **Also considered:**
  - [MeGUI files](https://sourceforge.net/projects/megui/files/)
  - [Avidemux](https://avidemux.sourceforge.net/)
  - [VidCoder](https://vidcoder.net/)
  - [DaVinci Resolve Studio](https://www.blackmagicdesign.com/products/davinciresolve/studio)
