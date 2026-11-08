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
| 2026-11-08 | [Live-action AI upscalers as add-ons, and AI strength](2026-11-ai-upscale-addons/index.html) | Built: Real-ESRGAN General (+ denoise), Live Action SPAN and Real-ESRGAN x4plus/x2plus on VSNCNN as two add-ons; conversions match PyTorch to 0.02 levels; 2xVHS2HD rejected (ncnn has no ScatterND/Shape/Range); AI strength blend halves a model's tint |
| 2026-11-03 | [Deblock before or after deinterlacing?](2026-11-deblock-order/index.html) | Keep Deblock after Deinterlace (≤0.05 dB gain from moving it); when deinterlacing is off, deblock per field rather than on the woven frame (+0.03 to +0.30 dB; DCTFilter on the woven frame lost 1.5–3.7 dB); built |
| 2026-11-03 | [Issue #144: KNLMeansCL fails on 10-bit sources (Windows), unreliable on macOS](issue-144-knlmeanscl/index.html) | Swap every platform to the maintained fork v1.3 (tag on macOS/Linux, PyPI wheel on Windows); verified on macOS arm64; on Windows x64 (AMD GPU) the bug reproduces with v1.1.1 and v1.3 fixes it |
| 2026-11-03 | [Issue #117: QTempGaussMC (vs-jetpack) as an alternate deinterlacer](issue-117-qtempgaussmc/index.html) | Worth adding as an advanced-only method (not macOS x64); +0.5–0.8 dB over havsfunc QTGMC Slower at equal speed once tuned; not built yet |
