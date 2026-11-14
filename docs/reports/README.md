# Investigation reports

A report is the full evidence behind a decision: what was tried, what was
measured, what it looked like, and why the recommendation came out the way it
did. They complement the other two places decisions are recorded:

| Where | What it holds |
|---|---|
| `CLAUDE.md` | The resulting **rule**, stated briefly |
| `docs/ENGINEERING_NOTES.md` | A dated **summary** of the why, with the key numbers |
| `docs/reports/<slug>/` | The **evidence**: screenshots, charts, every variant measured, the scripts |

## When to write one

Write a report for any investigation whose outcome rests on measurements or
visual comparison, especially a probe before building: a new filter, plugin
or method, a plugin swap, a performance question, a quality comparison. A
one-line fix or a decision that rests on reading the code alone doesn't need
one.

Write it whether or not the answer is "build it". A negative result keeps the
same idea from being re-investigated from scratch.

## Layout

```
docs/reports/<slug>/
├── index.html      # the report: self-contained, opens from disk
├── img/            # screenshots it links to, numbered in reading order
└── scripts/        # what produced the numbers and images
```

`<slug>` is `issue-<N>-<topic>` when there's an issue, otherwise a short
kebab-case topic with the date (`2026-11-avx512-ctmf`).

## Rules

- **Self-contained.** `index.html` must open from disk with no network access:
  inline CSS and JS, chart data embedded, images as relative links. No CDNs,
  no third-party tooling copied in.
- **Images are evidence, not decoration.** Every screenshot needs a caption
  saying what it shows and what to look for. Label side-by-side panels. Use
  nearest-neighbour scaling for zoomed crops so the pixels are real, and link
  each image to full size.
- **Every number traces to a script.** Put the scripts in `scripts/`. They find
  the repo from their own location (`HERE="$(cd "$(dirname "$0")" && pwd)"`)
  and take scratch paths from an environment variable. Never commit a personal
  or temporary path. Large generated inputs (decoded video, `.y4m`) stay out of
  the repo; the report says how to rebuild them.
- **Say what the metric can't tell you.** PSNR rewards softness, a single clip
  isn't a population, and Apple Silicon isn't x86. State those limits next to
  the result, not only at the end.
- **Corrections stay visible.** If a finding turned out wrong during the work
  (or after), say so in the report, in place, rather than quietly deleting it.
- **List what wasn't tested** and **the decisions taken, each with its reason.**
- **Keep it under ~5 MB.** Crop screenshots to the region that matters; PNG
  for pixel comparisons.
- **Link it from `docs/ENGINEERING_NOTES.md`** with a short dated entry, and add
  it to the index below.

Reports are point-in-time records. Don't rewrite one when things change later;
write a new report, or add a dated note at the top of the old one that links
to it.

## Index

| Date | Report | Outcome |
|---|---|---|
| 2026-11-14 | [macOS x64 shipped fmtconv git-18a9cecb, not r31](2026-11-fmtconv-macos-x64-r31/index.html) | Built: fmtconv r31 from source on macOS x64 too (minos 12.0, no load-time SIMD). The skew was latent: 62 cases through the x64 bundle were bit-identical except the paths r31 changed (`cplace="dv"` interlaced 4:2:0, 4:4:0, 4:1:0), which VapourBox never reaches; QTGMC Placebo's apparent difference was multithreaded nondeterminism (bit-identical on one thread). A push-gate pixel fingerprint (U−V −606 on r31, +606 before) now checks every platform. SSE2 path and real footage not compared |
| 2026-11-14 | [24-bit PCM for an editing intermediate's restored audio](2026-11-intermediate-pcm-depth/index.html) | Built: ProRes/v210's restored track (Passthrough) is `pcm_s24le` (`in24` in MOV), not 16-bit. 16-bit's −101 dBFS error is inaudible, but erased 45–100% of DV pauses after noise reduction (−92…−118 dBFS, correlated) and 41–63% of DeepFilterNet's fade tails; TPDF dither adds −93 dBFS noise. 24-bit = MKV's FLAC sample for sample, read identically by AVFoundation, +0.77 Mbit/s. NLEs other than AVFoundation untested |
| 2026-11-14 | [A delayed AVI cannot seek its sound near its start](2026-11-avi-audio-seek/index.html) | Fixed: on an AVI with a decoder delay, an input `-ss` on the sound under ~0.12 s failed and a trim lost ~1.3 s of sound (frame 2 to MKV: sound 1.277 s late). Decodes of the sound now skip after decoding (exact), and the copy encode seeks a NUT copy of the sound (exact; MKA 9 samples off, audio-only AVI 5 ms on MP3). Found: Passthrough trims to AVI run their sound late by the copy's pre-roll (frame 20: 667 ms; task #24) |
| 2026-11-14 | [Issue #173: AVI seeks land on the wrong frame](issue-173-avi-seek/index.html) | Fixed: an AVI's one-frame tick put every seek on a half tick, which rounded a frame early on 1 start in 3 of every NTSC AVI (HuffYUV, DV …); MPEG-2/MPEG-4/H.264 AVIs also stamp pictures 1-2 frames late (every seek early by that) and cannot seek at all below 0.13 s (frame 1 -> 45). Seeks now round up, add the measured decoder delay and count from the start near it; the H.264 AVI's untrimmed encode (frame 0 three times) is fixed too; all other sources' untrimmed encodes identical. Not fixed: a trim under 0.13 s on such an AVI still loses ~1.3 s of sound |
| 2026-11-14 | [ProRes in MOV: no `+faststart`, PCM for restored audio](2026-11-prores-faststart/index.html) | Built: ProRes follows v210 as an editing intermediate. Faststart's second pass cost 0.4–1.4 s/GB (median ~0.9) on an internal SSD, rewrites in place (the "needs the space twice" comment was wrong) and stalls the bar at 100%; a restored track under Passthrough is PCM (`sowt`) instead of AAC. Slow disks not measured |
| 2026-11-14 | [Field order for the other codecs: FFV1, HuffYUV, FFVHuff, x264, x265](2026-11-field-order-other-codecs/index.html) | Built: FFV1/HuffYUV/FFVHuff flagged like v210 (MKV/MOV; FFV1 also in its bitstream, so in AVI too); x264 codes a picture left interlaced as MBAFF with the order named in `-x264-params` (+0.33 to +1.00 dB field PSNR on VHS at equal bitrate, BD-rate −16.5 %; ~20 % slower). Not built: x265 (its interlace mode calls each woven frame a field; a container-only flag splits AVFoundation from VLC) and hardware encoders; the job log says when output goes unflagged |
| 2026-11-14 | [Issue #174: the source grid, leading repeat slots and Soft Telecine at 23.976](issue-174-source-grid/index.html) | Fixed: every constant-rate decoder now places frames on the source's grid by timestamp (`-copyts`, `setpts` to the first picture, `fps`, `trim=start_pts=N`, an 8-slot lookback). `soft_telecine_test.mkv` encoded every frame two late (122 slots for 120), trims from inside AVI null runs and onto pulldown repeats started a frame late, and Soft Telecine removed 24 of 120 film frames from a 23.976 source; now exact on 14 fixtures from every start, regular sources identical. Soft Telecine decimates at 29.97/30 only (a DVD reports 29.97 in VOB and MKV) and pipes whole cycles |
| 2026-11-14 | [Issue #169: MPEG-PS/TS seeks started at the next keyframe](issue-169-mpeg-seek/index.html) | Fixed: TS/PS have no keyframe index, so a seek to frame N decoded from the keyframe after it (DVD GOP 12: 40 → 48; H.264 TS GOP 25: 40 → 50; DVB-T 40 → 56; nothing past the last keyframe). Preview, Original, trims, thumbnails and detectors now seek one measured GOP early with `-copyts` and trim to the frame: exact on every fixture and frame tried; other formats' arguments unchanged. ~0.08 s more per 1080p preview decode |
| 2026-11-14 | [Sources whose video starts after their audio](2026-11-video-start-offset/index.html) | Fixed: on a file whose sound starts first (every DVB-T capture), `-ss` counted from the sound's start, so the preview, before frame and trims showed frame N−25 on 1 s fixtures, MKV/MP4 untrimmed decodes led with 25 copies of the first picture (MP4 lost its last second), the app counted 158 frames for a 128-frame DVB-T clip, and untrimmed TS encodes were 1.01 s out of sync. Every seek now adds the video's start offset, the output keeps the sound-first layout (in sync to ≤ 0.8 ms, sound copied losslessly), and Audio Restoration gains "start the sound with the picture". Sources whose streams start together are bit-identical. MPEG-TS seeks to a later keyframe remain (DVB-T preview still off) |
| 2026-11-14 | [Unblend (SRestore): blended frame-rate conversions](2026-11-srestore/index.html) | Built as its own pass after Deinterlace: havsfunc's `srestore` is plain decimation on R78 (`make_linear` ignored, its detector never sees consecutive frames); a port with upstream's arithmetic (300/300 decisions identical when driven linearly) and a 48-frame window recovers 143/143 film frames from PAL blending (decimation 87) and 101/125 PAL frames from NTSC blending (73); encode = preview, thread-independent, exact lengths; pinning the measurement clip's cache took it from 3x to ~2% over QTGMC. No real blended capture tested |
| 2026-11-10 | [Issue #157: seek alignment, the decoder repeated the first frame after a seek](issue-157-seek-alignment/index.html) | Fixed: `setpts=PTS-STARTPTS` on every seeking `rawvideo` decoder. MP4 1/2997, MOV 1/11988, MKV 1/1000 sources previewed frame N-1 and trimmed encodes doubled their first frame (41, 41, 42 .. 51); now right from every start tried, untrimmed encodes bit-identical, and noisy sources the noise score read as 0.0 now score ~4.5. Also found, not fixed: MPEG-PS/TS seeks land on a later keyframe, MPEG-2 in AVI 1-2 frames early, AVI null frames / soft telecine add leading repeat slots |
| 2026-11-10 | [Sources tagged with `reserved` colour primaries/transfer](2026-11-reserved-colour-tags/index.html) | Fixed: FFmpeg 9's scaler refuses ProRes's `reserved` tags (code 0, Apple's "unknown"), which failed the before frame, thumbnails, Detect borders, Descale Detect and a 4444-alpha encode; every converting decode now clears only the invalid tags first (bit-identical to the untagged file). Clearing a valid matrix was rejected: it moves yuv→gray16le by up to 28 levels. Addendum 2026-11-14: Descale Detect now reads the Y plane itself (a BT.709-tagged master had lost its 720p dip), and the app's Detect jobs carry the raw tags |
| 2026-11-14 | [ProRes chroma conversion in the script](2026-11-prores-script-chroma/index.html) | Built: ProRes gets its profile's format (10-bit 4:2:2 / 4:4:4) from the script's field-aware resize, not FFmpeg's `-pix_fmt`; interlaced 4:2:0 chroma +11 dB on a ground-truth round trip; every other changed case equal or better, already-matching sources bit-identical; Color Format ignored for ProRes |
| 2026-11-10 | [v210 output and interlaced field-order flagging](2026-11-v210-field-order/index.html) | Built: v210 (uncompressed 10-bit 4:2:2) in MOV/MKV/AVI. Every still-interlaced ProRes/v210 MOV was flagged progressive (`fiel 0x0100`, vspipe's Y4M is always `Ip`); `-field_order` is inert in FFmpeg 9, so the pipe input gets `-top` (`fiel 0x0209`/`0x020e`) and ProRes `+ildct`. FFmpeg's 4:2:0 → 4:2:2 conversion blends the fields' chroma, so v210's is done in the script, field-aware |
| 2026-11-10 | [Issue #148: Frame Rate combined with Noise Reduction and Sharpen](issue-148-frame-rate-combined/index.html) | Not reproduced on macOS arm64 across 5 denoisers x 4 sharpeners x FlowFPS/RIFE x 8/10-bit; no pipeline change; nightly regression test added to cover Windows/MVTools v24 and other GPUs; reporter asked for a clip |
| 2026-11-09 | [Noise and halo scores for the pass list](2026-11-noise-halo-scores/index.html) | Built: `--detect-noise-halo` badges Noise Reduction at a motion-compensated noise sigma ≥ 3.5 and Dehalo at a two-sided edge overshoot ≥ 6% of the step; no false positives on 154 fixtures (clean max 2.06 / 1.48), catches white noise from sigma 4 and tape/grain noise from sigma 6, misses sharpening of already-soft edges. VCG's signalstats TOUT and halo ratio did not separate the fixtures; a spatial (Immerkær) noise score was rejected as blind to tape and grain noise |
| 2026-11-08 | [Crop & Resize: BT.601 → BT.709 on SD → HD, and Detect borders](2026-11-crop-detect-709/index.html) | Built: matrix-only 601 → 709 conversion when the output is HD (default Auto; patches within 0.67 levels of the source; a gamut conversion rejected: it moved 75% green by 55 levels on players without colour management); `--detect-crop` finds blanking, bars and the head-switching band exactly on real-picture fixtures, and matches a by-eye measurement of a DVB-T broadcast |
| 2026-11-08 | [Classical filters for deps 1.16.0: SangNom, vszip NLMeans/WNNM, vs-jetpack ports](2026-11-classical-filters/index.html) | Built: SangNom AA (sharpest; 8/10/16-bit parity; slowest of the three at 1080p), NLMeans (CPU) = KNLMeansCL's output without OpenCL, the IVTC fade fix (field gap 4.12 → 0.06), vine dehalo and mpeg2stinx (both advanced; mpeg2stinx lost PSNR on every fixture). Not built: WNNM (luma ≈ BM3D, chroma 2.6–7.2 dB worse; fast, but NLMeans (CPU) covers that with better chroma); havsfunc's santiag `sangnom` type stays off (calls a double-rate SangNom) |
| 2026-11-08 | [Colourisation: DDColor and DeOldify Video on ONNX Runtime](2026-11-colourisation/index.html) | Built: DDColor-T (default) and DeOldify Video as add-ons, luma kept bit-exact (8/10/16-bit); conversions exact (DeOldify rebuilt without fastai, verified against an independent export); Core ML needs Pad/Expand/Einsum rewritten and still compiles DDColor for 77 s, so previews run it on the CPU; temporal smoothing cuts colour flicker 84% for both |
| 2026-11-08 | [Face restoration: RestoreFormer++, GFPGAN and CodeFormer on ONNX Runtime](2026-11-face-restoration/index.html) | Built: RetinaFace R50 (steadier landmarks than mobilenet0.25) + BiSeNet + RestoreFormer++ as the base add-on, GFPGAN/CodeFormer as non-commercial add-ons; ONNX parity ≤2.5e-4; NumPy pipeline within 0.16/255 of facexlib; bit-exact outside the faces; flicker cut by blending restored faces in aligned space |
| 2026-11-08 | [Live-action AI upscalers as add-ons, and AI strength](2026-11-ai-upscale-addons/index.html) | Built: Real-ESRGAN General (+ denoise), Live Action SPAN and Real-ESRGAN x4plus/x2plus on VSNCNN as two add-ons; conversions match PyTorch to 0.02 levels; 2xVHS2HD rejected (ncnn has no ScatterND/Shape/Range); AI strength blend halves a model's tint |
| 2026-11-08 | [Audio restoration: filter delays, drift and DeepFilterNet](2026-11-audio-restoration/index.html) | Built: render the soundtrack before the encode; trim afftdn's 25 ms delay and give it the measured noise floor; correct drift by resampling (atempo moved audio ~20 ms); alimiter `latency=1:level=0`; DeepFilterNet as an add-on with `-D` |
| 2026-11-03 | [Deblock before or after deinterlacing?](2026-11-deblock-order/index.html) | Keep Deblock after Deinterlace (≤0.05 dB gain from moving it); when deinterlacing is off, deblock per field rather than on the woven frame (+0.03 to +0.30 dB; DCTFilter on the woven frame lost 1.5–3.7 dB); built |
| 2026-11-03 | [Issue #144: KNLMeansCL fails on 10-bit sources (Windows), unreliable on macOS](issue-144-knlmeanscl/index.html) | Swap every platform to the maintained fork v1.3 (tag on macOS/Linux, PyPI wheel on Windows); verified on macOS arm64; on Windows x64 (AMD GPU) the bug reproduces with v1.1.1 and v1.3 fixes it |
| 2026-11-03 | [Issue #117: QTempGaussMC (vs-jetpack) as an alternate deinterlacer](issue-117-qtempgaussmc/index.html) | Worth adding as an advanced-only method (not macOS x64); +0.5–0.8 dB over havsfunc QTGMC Slower at equal speed once tuned; not built yet |
