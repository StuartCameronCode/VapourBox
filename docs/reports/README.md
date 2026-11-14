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
| 2026-11-10 | [Issue #157: seek alignment, the decoder repeated the first frame after a seek](issue-157-seek-alignment/index.html) | Fixed: `setpts=PTS-STARTPTS` on every seeking `rawvideo` decoder. MP4 1/2997, MOV 1/11988, MKV 1/1000 sources previewed frame N-1 and trimmed encodes doubled their first frame (41, 41, 42 .. 51); now right from every start tried, untrimmed encodes bit-identical, and noisy sources the noise score read as 0.0 now score ~4.5. Also found, not fixed: MPEG-PS/TS seeks land on a later keyframe, MPEG-2 in AVI 1-2 frames early, AVI null frames / soft telecine add leading repeat slots |
| 2026-11-10 | [Sources tagged with `reserved` colour primaries/transfer](2026-11-reserved-colour-tags/index.html) | Fixed: FFmpeg 9's scaler refuses ProRes's `reserved` tags (code 0, Apple's "unknown"), which failed the before frame, thumbnails, Detect borders, Descale Detect and a 4444-alpha encode; every converting decode now clears only the invalid tags first (bit-identical to the untagged file). Clearing a valid matrix was rejected: it moves yuv→gray16le by up to 28 levels |
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
