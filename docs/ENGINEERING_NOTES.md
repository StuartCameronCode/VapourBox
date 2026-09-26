# VapourBox Engineering Notes

Historical decision log and deep-dive detail moved out of `CLAUDE.md` to keep
that file short. `CLAUDE.md` states the resulting rule; this file has the
investigation, measurements, and dates behind it, organized in the same order
the sections used to appear. Read it when you need to understand *why* a rule
exists, are touching the area it covers, or are deciding whether a similar
"probe before building" investigation is warranted.

### Filters added from the gap analysis (2026-08-15)

Five filters whose plugins were **already in the deps bundle and unused**, so no
deps release was needed: **DFTTest**, **FFT3DFilter** and **TTempSmooth** as
Noise Reduction methods, **aWarpSharp2** as a Sharpen method, and
**HQDeringmod** as a Dehalo method. The three new denoisers are `advancedOnly`;
aWarpSharp2 and HQDeringmod are visible, because each is a different *mechanism*
rather than a variant (and Dehalo's pass name already covers ringing).

Two lessons from doing it, both of which cost a debugging cycle:

> **Probe the bundled plugin, don't read about it.** Running each candidate
> against `deps/macos-arm64` at 8/10/12/16-bit before writing any wiring is what
> kept **KNLMeansCL** out of the batch: its OpenCL path does not initialise
> everywhere (the app's own `knlm-probe.json` reports `false` on the development
> Mac), CI deliberately excludes OpenCL-only plugins from
> `vapoursynth_integration_test`'s required list, and `channels="YUV"` demands
> 4:4:4 — which none of this app's sources are. It looked like a one-line win and
> was not low risk at all.
>
> **A plugin's VapourSynth port may not share its Avisynth parameter
> vocabulary.** `warp.AWarpSharp2` takes `chroma` as **0 or 1** and rejects
> anything else at script evaluation; Avisynth's takes 0-6, where 4 means "warp
> chroma with the luma mask". Shipping the Avisynth value killed vspipe outright.
> Script-generation tests passed the whole time — only the **heavy end-to-end
> test** caught it, which is the argument for keeping that suite. `chroma` is now
> deliberately not passed at all, asserted from both sides, in line with how
> every other optional plugin argument here is treated.

### Fifth filter batch (2026-08-15): two more deps plugins

**Bifrost** (Chroma Fixes) and **Retinex** (Color Correction), joining the
already-pending deps 1.9.0 rather than forcing another bump — the tag was still
unpublished, so it was free to grow.

Screening the remaining effort-2 candidates against the Windows-binary rule is
now the first step, and it disqualifies about half of them:

| plugin | latest release ships a Windows binary? |
|---|---|
| Bifrost v3.0, Retinex r4, MiniDeen v2, MSmooth v1.1, Descale r8 | yes |
| DeDot v3, FillBorders v4, EEDI2 r7.1, EdgeFixer r3, TDeintMod r10.1 | **no** |

> **Bifrost is 8-bit only** — "Only constant format 8 bit integer YUV input
> supported", verified at 10/12/16-bit and 4:2:2. It gets DeScratch's
> convert-down-and-restore guard. Low impact in practice: the composite captures
> it targets are 8-bit anyway. Measured on an alternating-chroma clip, it halves
> the frame-to-frame chroma swing.
>
> **Retinex rejects subsampled formats outright** ("sub-sampled format is not
> supported"), and *every* source this app handles is 4:2:0 or 4:2:2. Rather
> than round-trip the clip through 4:4:4 and resample chroma twice for what is a
> brightness operation, the luma plane is extracted as greyscale, processed, and
> put back — colour comes through bit-identical. Verified working that way at
> 8/10/12/16-bit and 4:2:2.
>
> **bifrost includes `<vapoursynth/VapourSynth4.h>`**, not `<VapourSynth4.h>`,
> so `-I"$VS_INC_DIR"` is not enough — the scripts stage an include root with a
> `vapoursynth/` subdirectory and pass its parent.

### Subtitles: transcribe first, mux last

The order is load-bearing and was wrong until 2026-08-17.

```
transcribe the source  ->  encode (burning in if asked)  ->  mux as a post-pass
```

Whisper used to run only *after* the encode, which made burn-in structurally
impossible — the encoder needs the file while it is running. Muxing genuinely
must be a post-pass, because the file it goes into does not exist until the
encode finishes. So the two ends of the pipeline both have subtitle work in
them, and neither can move.

> **Transcribing the source means honouring the trim, or every cue lands
> early.** The encoder seeks the audio input to the trim point
> (`-ss start/fps` on input 1), so the output's audio starts there. A transcript
> of the *whole* source is offset by exactly the trimmed-off head, with no error
> anywhere — `extract_audio_range` takes the same window the encode uses.
>
> What makes this safe is that **nothing in the pipeline retimes audio**. IVTC
> and frame-rate conversion change the video timeline and leave audio at its
> original duration; audio is only ever `-ss` seeked and `-shortest` truncated.
> If a pass is ever added that *does* retime audio (an `atempo` for a declared
> frame-rate change, say), this breaks and the subtitles drift.

`SubtitleOutput::{burns_in, muxes, keeps_srt_file}` answer the three independent
questions rather than matching the enum in three places. A test asserts every
mode does at least one of them, because a mode that does none produces no
subtitles at all and looks like a silent failure.

### The 2026-08-17 build-out: 18 filters, 4 new passes, deps 1.9.0

The plan from the probe rounds was executed in full. Pipeline went from 16
passes to 20 — **Edge Repair**, **Deflicker**, **Ghost Removal** and
**Frame Rate** — plus methods inside existing passes (Bwdif, Cnr4, RemoveDirt,
mClean, TemporalDegrain2, Auto Gain, Auto White Balance, ContraSharpening,
DeDot, automatic chroma alignment), subtitle burn-in, custom VapourSynth
injection, and an app-side histogram.

Traps found by writing it, none of which the probing predicted:

> **The `-vf` slot was single-use, and nothing would have caught it.**
> `build_ffmpeg_args` appended either `setsar` **or** `setdar` — and ffmpeg
> takes the **last** `-vf` and silently drops earlier ones. Adding subtitle
> burn-in as a second `-vf` would have thrown away the aspect stamp, re-breaking
> issue #50's third leg with no error anywhere. Filters now accumulate into a
> `Vec<String>` joined with commas. **Never append a bare `-vf`** — push onto
> that vec. Verified: a 16:11 anamorphic source with burnt-in subtitles comes
> out still tagged 16:11.

> **Adding a `remove_block` by pattern-matching on a sibling line misses an
> arm.** The new blocks were added by appending to
> `remove_block("{{#NR_STPRESSO}}"...)`, which appears in every method arm
> *except STPresso's own* — so STPresso alone left unsubstituted placeholders.
> A missed `remove_block` chains two denoisers silently: valid VapourSynth,
> twice the runtime, not what the user asked for. `test_115` caught it. When a
> method is added, walk **every** arm programmatically.

> **Whisper burn-in is not a harder version of burn-in, it is a different
> feature.** `SubtitleGenerator` runs *after* the encode (`main.rs`:
> "Post-encode subtitle generation"), so the transcript does not exist when the
> encoder needs it. Burn-in ships for a **user-supplied** file; the two
> burn-in output modes deliberately fall back to writing the sidecar. Moving
> transcription before the encode is separate work.

> **The frame count is the hazard in custom code, not the code.** Arbitrary
> execution is not a new risk in a process that already loads arbitrary plugins
> — `custom_ffmpeg_args` predates this. But a snippet calling `Trim` or
> `SelectEvery` changes the real output length while the declared total stays
> put, which makes the progress bar lie *and* makes frame-accurate preview show
> a different frame than its label, both silently. The generated script captures
> `len(clip)` before the snippet and raises afterwards if it changed. Do not
> relax that without giving the user a way to declare a `FrameMap`.

> **`FrameMap::Retime` existed and nothing emitted one.** Before adding a
> variant, check whether the one you need is already there. FlowFPS was chosen
> over BlockFPS specifically because its output count matches
> `Retime::output_count` exactly across 35 combinations while BlockFPS is off by
> one in 14 — the arithmetic decided the filter, not the picture quality. Also
> **reduce the ratio**: 25 → 29.97 is 1200/1001, not the plugin's 30000/1001,
> and `Retime` multiplies a frame count by that pair.

> **A wheel's macOS tag is a floor, not a promise.** `vapoursynth_dedot` 3.0
> publishes `macosx_15_0_x86_64`, which fails the x64 bundle's 12.0
> `STRICT_MIN_OS` guard — so that arch builds from source while every other
> platform takes the wheel. Check `minos` on the actual binary, not the filename.

> **Enum values and schema options are asserted against each other.**
> `schema_converter_integration_test` failed the moment two subtitle modes were
> added to the Dart enum without adding them to `subtitles.json`. That test
> earns its place; do not weaken it.

### The 2026-08-17 probe round: measure the premise, not just the plugin

Seven parallel read-only agents probed all 25 unshipped Core/Strong candidates
from the gap analysis against `deps/macos-arm64` before any plan was written.
**Probing changed the verdict on nine of the twenty-five.** The plan, the
simple-vs-advanced calls and the preset defaults are in the artifact — see
[[reference-hybrid-filter-gap-analysis]]. The transferable lessons:

> **A forum consensus about AviSynth is not evidence about this pipeline.**
> `TIVTC` was the top-rated candidate on the strength of "TIVTC is definitely
> better for complex DVDs than VIVTC", repeated across VideoHelp. Measured
> against the repo's own `hard_telecine_test.avi`, TFM+TDecimate and the
> `vivtc` VFM+VDecimate path already shipping are **bit-identical** — 0.0000/255
> after matching and after decimation, same 90→72 frames. On a deliberately
> broken cadence they differ by 0.0002. The claim is true; it is true of
> AviSynth's TIVTC against AviSynth's alternatives, not of this app. **Measure
> the premise before pricing the work**, especially when the rating came from
> reading rather than running.

> **Two candidates were already implemented.** EDI upscaling is complete in
> `pipeline_template.vpy` with per-plane centroid correction and measured within
> 0.055 px of a reference resample — it is invisible because its whole schema
> section is `advancedOnly, expanded: false` and reaching it needs two separate
> checkboxes. And `GrayWorld` is not a second filter: in YUV the grey-world
> assumption reduces exactly to shifting the U/V plane means onto neutral, which
> is what AutoWhite does. **Check whether the thing exists before costing it.**

> **Upstream defaults can be no-ops or hard failures — probe the default call,
> not just the function.** `zsmooth.Cnr4` defaults `scenechange=True` and needs
> frame properties this pipeline never sets, so a naive `core.zsmooth.Cnr4(clip)`
> fails **100% of jobs on every platform**; prepend `misc.SCDetect`. `Checkmate`
> is the mirror image: at its own default `tthr2=0` it measured 0.000 difference
> on every dot-crawl pattern tested — shipping upstream's default gives a filter
> that silently does nothing.

> **A plugin can carry a bug that only bites one architecture.** ReduceFlicker's
> `proc_filter.h` reads `prevp[0]/[2]` where its SIMD path correctly reads
> `nextp[0]/[2]`, and the SIMD block is `#if defined(__SSE2__)` — so aarch64 has
> no path but the buggy one, and the ARM bundles would have rendered differently
> from x86. Same failure shape as the znedi3 `_FieldBased` trap that cost two
> nightly cycles. It is transcribed to `Expr` instead, validated against a numpy
> model of the C source at max 1 level difference.

> **"Faster" and "better" are different claims and both need measuring.**
> RemoveDirtMC is *not* additive over the shipped SpotLess (9.99 MAE vs 9.21,
> and 1.4x slower) — but plain RemoveDirt runs **908 fps against 143** for 60%
> of the removal. The filter is worth shipping for the axis the forums actually
> praised it on, and would have been wasted effort on the other.

### Second probe round (2026-08-17): the Useful tier, 21 of 22 deferred

The same seven-agent treatment over every remaining Useful-tier candidate.
**One promotion out of twenty-two** — MVTools `FlowFPS` as a Frame Rate pass —
and that ratio is the finding, not a disappointment: the Useful tier is where
second answers live, and measuring is how you learn they are second. Lessons
that generalise:

> **A "new" filter is often the shipped one with different arguments.**
> `KillerSpots` measured **bit-identical** to `spotless.py` (max diff 0.0) with
> three mvtools arguments changed — the third instance of this after
> `lostfunc.DeSpot` and `GrayWorld`. But those arguments are *better*: spot MAE
> 10.49 → 9.33 at 318 → 424 fps, i.e. **a three-line change to shipped code is
> worth more than the filter was**. Diff the algorithm before costing the port.

> **An automatic filter must be tested on the material it should ignore.**
> `AutoDeblock`'s detection is *inverted*: on genuinely blocked MPEG-2 it never
> escalated past "weak" and altered the picture **less** than it altered clean
> footage, while on grainy-but-unblocked content it fired strong on 99% of
> frames. Heavy quantisation collapses inter-frame detail, so the temporal gate
> it keys on drops exactly when blocking rises. Any "auto" filter gets a
> three-way test — damaged, clean, and noisy-but-clean — and the clean cases
> matter more than the damaged one.

> **Check the filter against the content this app's presets create.**
> `FillDrops` cannot distinguish a dropped frame from a held animation cel —
> both are bit-exact duplicates — so it destroyed 39 of 80 held frames at
> *every* threshold, since none can be below zero. VapourBox ships **Anime DVD**
> and **DVD IVTC** presets where duplicated frames are normal. A filter that is
> safe on live action can be destructive on the sources we advertise.

> **Prefer a crash you can catch.** `vs-placebo` constructs its node with no
> exception when Vulkan is absent and then **segfaults on the first frame** —
> no error to detect, no fallback possible, and vspipe dies as "signal 11" for
> both job and preview. That is strictly worse than KNLMeansCL, which at least
> raises. macOS has no Vulkan driver and the wheels ship no MoltenVK, so it can
> never work on either Mac bundle.

> **`FrameMap::Retime` exists and nothing emits one.** `frame_map_for` produces
> only `Identity`, `Fanout` and `Decimate`. FlowFPS's output count matches
> `Retime::output_count` exactly across 35 combinations; BlockFPS is off by one
> in 14 of them. Choosing FlowFPS makes existing code correct as written —
> check for an unused variant before adding one.

> **Synthetic uniform grain is a bad fixture for a motion-compensated
> denoiser.** A probe reported `SMDegrain` as a near no-op "at the app's
> defaults"; reproducing it showed the repro omitted `RefineMotion` and
> `prefilter`, which the template always emits. With the real defaults it
> removes 3.34 of 4.36 grain, and the reachable parameter space (27
> combinations) is well-behaved throughout. **No bug** — but bare `SMDegrain`
> on uniform noise finds perfect motion matches everywhere and gates everything
> out, so use real footage when validating MC denoisers.

### Fourth filter batch (2026-08-15): probe agents, and what they caught

Five more effort-1 filters: **CTMF** (Noise Reduction), **DCTFilter** (Deblock),
a **Film Grain** pass (AddGrain + GrainFactory3), a **Rotate / Flip** pass, and
**SmoothLevels** as an option on the existing Levels control. All from plugins
already in the bundle, so no deps change.

This batch was probed by parallel read-only agents before any wiring was
written, and that is the only reason it works. The traps they found, none of
which any documentation would have shown:

> **A quarter turn changes the pixel FORMAT, and ffmpeg refuses the result.**
> `std.Turn90` swaps the chroma subsampling axes, so 4:2:2 becomes 4:4:0 — which
> vspipe emits as `C440` and ffmpeg rejects with "YUV4MPEG stream contains an
> unknown pixel format" — and 4:1:1 becomes a format with no y4m identifier at
> all, killing vspipe itself. Both are hard job failures and 4:2:2 is the common
> 10-bit ProRes case. The template captures `clip.format.id` before the turn and
> converts back after, like the LUTDeCrawl guard.
>
> **SAR must be inverted on a quarter turn, in TWO places.** SAR is pixel width
> : height, so turning exchanges them. `GeometryParameters::adjusted_sar` feeds
> both the ffmpeg-side declaration in `pipeline_executor.rs` *and* the
> `{{SOURCE_SAR}}` used by the square-pixel fitting path in the template. Miss
> either and an anamorphic source comes out the wrong shape.
>
> **Turning interlaced material is unrecoverable, not merely lossy.** Fields are
> alternating rows; a quarter turn puts them in alternating *columns*, where
> `SeparateFields` returns two "fields" that each still contain both. No
> deinterlacer can fix it afterwards, and `_FieldBased` still claims the clip is
> fine. `pass_advice.dart` warns when a quarter turn is set with deinterlacing
> off — the pass order already puts deinterlacing first.
>
> **CTMF rejects 9-bit, and 9-bit is reachable.** `pixel_format.rs` rounds an odd
> source depth up through `[8, 9, 10, 12, 14, 16]` and `pipe_source` maps
> `yuv420p9le`, so a 9-bit source would kill the job. Guarded in both templates.
> Its `memsize` is also pinned to 16 MiB: at the plugin's 1 MiB default, 16-bit
> radius 3 measures **0.79 fps against 42 fps**, for bit-identical output.
>
> **DCTFilter accepts NaN and silently blackens the frame.** Its own range check
> is `factor < 0.0 || factor > 1.0`, and both are false for NaN. The worker
> builds the eight factors from a cutoff and a strength and guarantees every one
> is finite. Its coefficient mapping is also **separable** (`factors[u] *
> factors[v]`), not the `max(u, v)` the Avisynth filter of the same name uses.
>
> **`grain.Add`'s `var` must NOT be depth-scaled**, unlike every other level in
> this app. It is already in 8-bit units and the plugin rescales internally;
> applying the `_levels_8bit()` treatment would quadruple the grain at 10-bit.
> Measured identical 8-bit-equivalent output at 8/10/12/16-bit.
>
> **SmoothLevels' default configuration cannot run at all.** havsfunc calls
> `core.f3kdb.Deband` and this bundle ships **`neo_f3kdb`** under a different
> namespace, so `useDB=True` — the default — raises "no attribute named f3kdb"
> on every format. It is pinned `False`; fixing it properly needs a havsfunc
> patch 8 and therefore a deps release. Its levels are also read in the clip's
> own range, so six arguments are scaled in-script; and it **crashes** when
> `input_low > 0` and `1/gamma` is not an integer (a negative base to a
> fractional power yields a Python complex), so the worker drops the black point
> for that combination.

> **TemporalDegrain2 was requested and is NOT effort 1.** Its upstream repo
> declares **no licence**, so vendoring ~4,300 lines of it is a legal decision
> rather than a technical one. Beyond that: it needs five modules, not one;
> `postFFT=5` **aborts the process** rather than raising; `postFFT=4` is broken
> two ways; `extraSharp=True` is a `NameError` at exactly 16-bit; and both
> `limitSigma` and mvtools' `limit=255` default are depth-dependent, so
> `outputStage=0` is a **complete no-op at >=12-bit** and 73% of the degraining
> is silently lost at 16-bit. Good news: bm3d is never reached, so it needs no
> deps addition. Implementable, but effort 3 and blocked on the licence.

### FFmpeg is pinned to one series, and the pin is asserted (2026-08-31)

The bundled FFmpeg is what actually interprets everything in
`pipeline_executor.rs` — the accumulated `-vf` chain, the colour metadata
flags, `-ss`/`-frames:v` trimming, the hardware-encoder options. So a version
skew between platforms means the same job encodes differently depending on
where it ran, silently. It is the same class of hazard as the fmtconv and
zsmooth version pins, and it had been true for months without anyone noticing:

| | FFmpeg, measured 2026-08-31 | how |
|---|---|---|
| Windows | **master N-125978** (post-9.0) | BtbN `master-latest`, **unpinned** |
| macOS x64 | 9.0.1 | evermeet `getrelease`, **unpinned** |
| macOS arm64 | 9.0.1 | martin-riedl `latest`, **unpinned** |
| Linux | **7.1**, two majors behind | BtbN `n7.1`, pinned |

Three floated on "latest" and the fourth was pinned to a series BtbN then
garbage-collected, which 404'd the Linux deps build outright. All four now pin
**9.0**.

> **A version pin against a rolling tag is not a pin.** BtbN publish every
> series to one `latest` tag and drop old ones as they age, so `n7.1` was always
> going to become a 404 — it was a matter of when. Pin the **series**
> (`n9.0-latest`, newest build of the 9.0 branch), which is how all three
> upstreams actually publish, and treat a series bump as a deliberate,
> all-platforms-together change.

> **`curl` without `-f` writes the 404 body to the output file.** That is why
> the failure surfaced as `tar: Error is not recoverable` half a step later
> rather than as a download error naming the URL — the "tarball" was nine bytes
> reading `Not Found`. Every FFmpeg fetch now uses `-f`.

Pinning differs per host because their retention does, and that is deliberate:

- **BtbN** (Windows, Linux) — series URL, rolls patches within 9.0.
- **evermeet** (macOS x64) — an exact version, `FFMPEG_MACOS_X64_VERSION`. It
  keeps old versions reachable (verified: 7.1, 8.0 and 9.0.1 all still resolve),
  so a full-version pin is durable here.
- **martin-riedl** (macOS arm64) — only `latest` plus opaque build-id paths of
  unknown retention, so it takes latest and is **checked afterwards**.

Two guards, and both are needed. `assert_ffmpeg_series` in each script runs
`ffmpeg -version` on what was actually installed and fails the build if it is
not the pinned series — that catches an upstream silently moving a URL, which
no amount of pinning can prevent. And `app/test/ffmpeg_version_pin_test.dart`
(push gate) reads all three scripts and fails if their pins disagree, if a pin
is not a bare `major.minor`, or if a script stops asserting. Without the second,
the pins are just comments.

Note the version parser accepts `n9.0.1` and `9.0.1` and deliberately **rejects
a `master` build** (`N-125978-...`), so reverting any platform to an unpinned
master URL is a red build rather than a silent regression.

### zsmooth ships once per CPU baseline, and is loaded by path (issue #82, 2026-08-28)

A plugin can also have **no** dispatch at all. zsmooth is compiled for a whole
CPU baseline — upstream publishes only `haswell` (AVX2) and `znver4` for x86,
per the targeting essay in vapoursynth#1185 — so on a pre-2013 CPU the library
**loads fine** and then dies the instant a filter runs.

Reported on a Celeron J4105 and a Core i7 870, neither of which has AVX at all.
The symptom is a bare `vspipe exited with exit code -1073741795`, which is
`0xC000001D` **STATUS_ILLEGAL_INSTRUCTION** — a different fault from CTMF's
`0xC0000005`, and worth knowing apart: illegal instruction means the binary
needs a CPU feature this machine lacks, access violation means a genuine bug in
the kernel that ran. Both print nothing else, so the encode surfaces as ffmpeg
reading an empty pipe. `format_exit_status` now decodes both.

Everything reaching `core.zsmooth.*` was affected: CCD, Cnr4, SpotLess →
RemoveDirt, Noise Reduction → mClean and TemporalDegrain2, and hybrid_mv. QTGMC
was not — havsfunc uses `rgvs`.

> **Shipping one portable build for everyone is the obvious fix and the wrong
> one.** Measured (Zig 0.15.2, same source, 720x576, fps, best of 3), as a
> fraction of haswell speed:
>
> | | CCD r0 | CCD r1 | Cnr4 | CCD 16-bit | RemoveGrain | Repair | Median |
> |---|---|---|---|---|---|---|---|
> | `x86_64` | 0.50 | 0.33 | 0.33 | 0.39 | 0.68 | 0.66 | 0.73 |
> | `x86_64_v2` | 0.72 | 0.63 | 0.71 | 0.69 | 0.69 | 0.65 | 0.73 |
>
> That is 2-3x on the two filters the Chroma Denoise pass is *made of*, charged
> to every modern machine to serve the rare old one. Ratios hold at 1080p and
> multithreaded. A locally built `-Dcpu=haswell` matched the shipped binary
> within ±3%, so these are like-for-like and not a toolchain artefact.

So x86 bundles ship **both** builds and the worker picks at load time. Three
things about the mechanism:

- **The builds cannot share a directory.** Each registers the namespace
  `zsmooth`, so whichever autoloads second is rejected — and on macOS/Linux
  `vapoursynth/plugins` is autoloaded implicitly by R78, so "just don't set the
  env var" is not available either. They live in `vapoursynth/zsmooth/`, outside
  any autoload path, and the generated script carries an explicit
  `core.std.LoadPlugin`. `VAPOURSYNTH_EXTRA_PLUGIN_PATH` takes **one** directory
  — verified, a `;`-separated pair silently loads only the first — so the second
  plugin directory idea does not work.
- **The namespace stays `zsmooth`, so no call site changed.** That is the whole
  reason for loading by path rather than under a `forcens` alias: the vendored
  `mclean.py`, `removedirt.py`, `temporaldegrain2.py` and `hybrid_mv.py` all say
  `core.zsmooth.X`, and an alias would have needed a `_zs()` indirection through
  every one of them (and left them on the slow build for AVX2 users).
- **No selected build means no `LoadPlugin`.** Bundles up to 1.9.0 autoload a
  single zsmooth, and the app can be upgraded before the deps download finishes,
  so a worker that always emitted the line would fail every job in that window.
  `DependencyLocator::zsmooth_plugin()` returns `None` there and the script is
  byte-identical to the pre-split one. Verified both ways end to end.

`x86_64_v2` (SSE4.2/POPCNT, Nehalem 2009 on) is the fallback rather than plain
`x86_64`: it is 1.4-2.1x faster on the filters that matter, 0.6 MB smaller, and
covers both CPUs in the report. Note v2 buys **nothing** over v1 on the
RemoveGrain/Repair/Median kernels — the gain is specific to CCD and Cnr4.

macOS x64 was already affected in the other direction: it builds from source for
the issue #39 minos floor and had always used Zig's *default* baseline, i.e. the
0.50/0.33 column. It now builds both, so Intel Macs get the fast path for the
first time.

> **The macOS haswell build needs an fftw patch, and the bug is one line
> upstream.** zsmooth's Zig fftw port sets `HAVE_MEMALIGN` on every non-Windows
> target, but macOS has no `memalign()` — it is declared in `<malloc.h>`, which
> **the same file already knows macOS lacks** (`HAVE_MALLOC_H` is gated on
> `!is_mac`). fftw's `kalloc.c` only reaches that branch when `MIN_ALIGNMENT` is
> 32, i.e. when AVX is on, so it is invisible at every SSE-level baseline and
> kills **only** the haswell build — with a clang implicit-declaration error
> inside a dependency, which reads like a toolchain problem rather than a
> one-line config bug. `HAVE_POSIX_MEMALIGN` is already true, so clearing it
> falls through to `posix_memalign`.
>
> The patch clones the fftw fork at the ref `build.zig.zon` names, edits that
> line, and repoints the dependency as a **path** dependency — path deps take no
> hash, so this is deterministic and survives a cache wipe, unlike editing Zig's
> global package cache. Both a pre-check and a post-check hard-fail, so an
> upstream fix surfaces as a build error telling you to remove the patch rather
> than silently doing nothing.
>
> Verified by **cross-compiling from Windows** (`-Dtarget=x86_64-macos.12.0
> -Dcpu=haswell`), which reproduces the failure exactly and confirms the fix in
> about four minutes — far cheaper than a macOS CI round trip, and worth
> remembering for any Zig-built plugin: the target does not have to be the host.

> **The fallback is not a different picture, only a slower one.** The two builds
> produced identical chroma means (U=123.884, V=131.096) on the same clip, so
> falling back costs throughput and nothing else. Do not treat the choice as
> output-affecting.

Guards: `test_154`/`test_155` (both scripts, both bundle layouts) and
`zsmooth_never_offers_a_build_this_cpu_cannot_run` in `dependency_locator.rs` —
which is the durable one, since it runs on every platform whatever hardware CI
draws. The Dart side loads the chosen build and **renders a frame** (the fault is
in the kernel, so constructing the node proves nothing), asking the worker's
`--probe-cpu` for the CPU rather than deriving it. `deps-expected-plugins.json`
entries for zsmooth are bundle-relative **paths**, and all three packaging guards
understand that form now.

**This is not verifiable in CI.** Every hosted runner has AVX2, so no CI job can
exercise the fallback; the local check is to hide the haswell build and re-run.
Intel SDE (`sde -nhm --`) is the only way to prove a build runs on a CPU you do
not have.

### A plugin's own CPU auto-detect is not trustworthy (CTMF, 2026-08-25)

`ctmf.CTMF`'s AVX-512 kernel for **8-bit** input
(`ctmfHelper_avx512<uint8_t, 16>`) crashes the process. Not an exception — a
**0xC0000005 access violation**, so vspipe dies having printed nothing at all.

That makes the symptom actively misleading. The encode surfaces as the *encoder*
ffmpeg failing to read the empty Y4M pipe:

```
[in#0] Header too large.
[in#0] Error opening input: Invalid argument
ffmpeg exited with exit code -22
```

and the preview as a bare `Preview generation failed (exit code 1)` whose log
ends after the routine API3 plugin warnings. **Nothing anywhere names CTMF**, and
"Header too large" reads like a muxer or template bug.

Scope, measured against the bundle rather than assumed:

| | 8-bit | ≥10-bit |
|---|---|---|
| `radius=2` | OK | OK |
| every other radius | **crash** | OK |

Radius 2 escapes because it has its own `filterRadius2_*` kernel; ≥10-bit
escapes because it uses the `uint16_t` helpers. `opt=1` (C), `2` (SSE2) and `3`
(AVX2) are **bit-identical to each other** and none of them crash.

> **The plugin does not check that the CPU can run the level you ask for.**
> `opt=3` on a pre-AVX2 machine installs the AVX2 kernels and crashes exactly as
> `opt=4` does on an AVX-512 one — there is no guard in `ctmfCreate`, only a
> `0..4` range check. So the fix cannot be a constant. `script_generator::ctmf_opt`
> queries the CPU (`is_x86_feature_detected!`) and emits **3 where AVX2 exists,
> else 2** — SSE2 being part of the x86-64 baseline. Never emit `0`: that is the
> plugin's own auto-detect, and auto-detect is precisely what picks the broken
> kernel. Non-x86 builds compile the dispatch out and ignore the value.
>
> This lives in the worker rather than in the script because it is a property of
> the **machine**, not of the clip — unlike the depth scalings, no preceding pass
> can change the answer. CTMF r5 (2020) is the newest upstream release, so there
> is no fixed build to take instead.

> **CI turned red with no diff, and the runner hardware was the variable.**
> The nightly Windows job started failing 2026-08-24 against a tree unchanged
> since 08-20. x264's capability line in the same logs is the tell: `... AVX2` on
> the three passing nights, `... AVX2 AVX512` on the failing ones. When a job
> fails with no commit to blame, grep the log for that line before bisecting.
> (These machines also align VapourSynth frames to 64 bytes rather than 32 — a
> 720-wide 8-bit plane gets stride 768.)

> **Only CTMF is affected.** `cas`, `grain.Add`, `tcanny`, `dfttest`,
> `warp.AWarpSharp2` and `eedi3m` expose the same `opt` parameter and the same
> `instrset_detect()` dispatch; all six were swept at `opt=0` against `opt=3` on
> an AVX-512 CPU, at 8-bit and 16-bit, and are clean. Do not pin them
> pre-emptively — an unnecessary pin costs throughput and hides a real
> regression later.

`test_152`/`test_153` (Rust) assert both generated scripts carry the pin and that
the value is one the CPU actually has; the Dart twin is in
`integration_filter_parameters_test.dart`. Both matter: the Rust test would pass
against a value no CPU here can run, and the heavy end-to-end
`integration_new_passes_test` CTMF case is the only level that proves vspipe
survives.

### Third filter batch (2026-08-15): the first deps change

**fluxsmooth** is the first plugin this work has *added* to the bundle rather
than found already in it, so it is the first batch that needs a **deps release**
(1.8.0 → **1.9.0**). It unlocks three Noise Reduction methods: `FluxSmoothT`,
`FluxSmoothST`, and **STPresso**, which was dropped from the second batch for
exactly this missing dependency.

What an effort-2 addition actually costs, beyond the usual filter wiring:

1. A build block in **all three** `download-deps-*` scripts.
2. An entry per platform in `Scripts/deps-expected-plugins.json` — the packaging
   guard that turns a dead download URL into a red build.
3. The namespace in `app/test/vapoursynth_integration_test.dart`'s required
   list, or a bundle missing it passes CI and fails at job time.
4. A version + tag bump in `app/assets/deps-version.json`.
5. **A deps release actually built and published**, which is CI work and cannot
   be done or verified locally — see the rc flow in "Testing a deps change".

> **Windows has essentially no from-source build path, and that decides the
> version.** `download-deps-windows.ps1` fetches published release archives, so
> a plugin is only addable if upstream ships a Windows binary — and every
> platform must then pin the version Windows can get. (The single exception,
> added 2026-08-28: zsmooth's portable build compiles there with a pinned Zig
> toolchain, because Zig brings its own libc and needs no MSVC. Do not read that
> as a general from-source path — it exists because upstream ships no binary that
> runs without AVX2, see the zsmooth section above.) FillBorders and Bwdif were the first
> two candidates and were **rejected on this basis**: their newest Windows
> binaries are several releases behind their source (FillBorders v2 vs v4, Bwdif
> r4.1 vs r5.1), and pinning everything back that far would have cost features
> that only exist in the newer source. Check
> `gh api repos/<owner>/<repo>/releases --jq '.[] | "\(.tag_name) \(.assets|length)"'`
> **before** planning any effort-2 addition.
>
> **But that check is no longer sufficient on its own — plugins are migrating to
> PyPI.** Re-probing on 2026-08-17 found the rule intact and *three of its
> conclusions stale*, because upstream had changed distribution channel rather
> than stopping:
>
> | plugin | GitHub releases say | reality |
> |---|---|---|
> | **Bwdif** | last asset r4.1 (2021) | r5 moved to PyPI; `vapoursynth-bwdif` 5.1 ships wheels for **all five** targets |
> | **DeDot** | v2/v3 have no assets | `vapoursynth_dedot` 3.0 ships wheels for all five |
> | **EdgeFixer** | (assumed absent) | r3 (2026-07-22) **does** ship `EdgeFixer_r3.7z`, and it is the newest tag |
>
> So the check is now **two** commands, and the second is the one that was
> missing: `curl -s https://pypi.org/pypi/vapoursynth-<name>/json`. The akarin
> block in `download-deps-windows.ps1` is already a working PyPI-wheel fetcher
> (resolve the hashed URL through the JSON API; a wheel is a zip) — copy it
> rather than concluding a plugin is unavailable.
>
> Two caveats found the same day: a wheel's macOS tag is a **floor, not a
> promise** — dedot's `macosx_15_0_x86_64` fails this bundle's `STRICT_MIN_OS=1`
> 12.0 guard, so x64 still builds from source — and **FillBorders v2 vs v4 is
> still real**, but measured bit-identical at even border widths, differing only
> at odd widths where v2 leaves subsampled chroma unrepaired. Constraining the UI
> to `step: 2` (as every crop control already is) erases the difference.

> **Yes, one filter justified this deps release — that was a deliberate call.**
> zsmooth already provides `FluxSmoothT`/`FluxSmoothST`, so those two methods
> never needed the plugin; they call the canonical `flux` namespace only because
> it is present. **STPresso is the only filter that actually required it**,
> because havsfunc hardcodes `core.flux.SmoothT` and cannot see zsmooth's
> equivalent. The alternative — point the two FluxSmooth methods at zsmooth, drop
> STPresso, revert to deps 1.8.0 — was considered and rejected on 2026-08-15:
> STPresso is well regarded, the plugin is 34 KB, and a deps release is a
> one-time cost. Don't re-litigate this; if the plugin ever needs removing, it is
> STPresso that goes with it.

> **Prefer compiling a small plugin directly over running its build system.**
> fluxsmooth is autotools, and adding autoconf/automake/libtool to three CI
> deps workflows for one plugin is a poor trade. It is a single C file, so the
> macOS and Linux scripts call the compiler directly — one line, no new
> toolchain, and identical output.

### The download scripts do NOT share a vocabulary — porting a block costs four checks

Adding these three plugins took **four** red deps builds, each a different cause
with the same symptom (`deps-expected-plugins.json` reporting missing plugins).
Every one came from writing a block in one platform's script and copying it to
another, carrying an assumption that silently did not hold. Before assuming a
copied block works, check all four:

| | macOS | Linux |
|---|---|---|
| VS headers | `$VS_INC_DIR` | **`$VS_INCLUDE_DIR`** |
| pkg-config for meson | `build_plugin` sets it internally | must prefix **`$PLUGIN_BUILD_ENV`** |
| `<vapoursynth/X.h>` include style | farm added 2026-08-16 (was absent) | permanent symlink farm |
| arch handling | **split**: x64 pre-built / arm64 from-source | both from source, no split |

The failures, in the order they appeared:

1. **`$VS_INC_DIR` is unset on Linux**, so it reached `cc` as a bare `-I`
   ("missing path after '-I'"). Both direct-compile blocks now assert
   `${VS_INCLUDE_DIR:?}` so a rename fails naming the plugin and the variable.
2. **retinex lost `$PLUGIN_BUILD_ENV`** on Linux — macOS has no such prefix, so
   copying its `build_plugin` call across dropped `PKG_CONFIG_PATH` and meson
   could not see VapourSynth at all.
3. **retinex includes `<vapoursynth/VapourSynth.h>`**, so pkg-config *finding*
   VapourSynth is not sufficient — the include root needs a child directory
   named `vapoursynth`. Linux had kept one for years; macOS had none, which is
   why bifrost staged a private tree and retinex (which resolves through
   pkg-config and cannot be handed one) could not work at all. macOS now mirrors
   the farm, so a single `-I"$VS_INC_DIR"` satisfies both include styles.
   Note this needs the **API3** headers: R78 installs only the API4 set, and
   both scripts top up `VapourSynth.h` from the source tree.
4. **The blocks sat inside the macOS arch split's arm64 branch**, so x64 never
   reached them — invisible on arm64, where everything passed. Anything built
   from source on *both* arches belongs after
   `fi  # end plugin arch split`, where zsmooth already lives.

> **A green Windows deps build proves nothing about the other two.**
> `download-deps-windows.ps1` only downloads published binaries, so it passed on
> the first attempt and every attempt after, while macOS and Linux were failing
> for three different reasons. Don't read it as a signal.

### Second filter batch (2026-08-15): two new passes

**Anti-Aliasing** (`daa`, `santiag`) and **Stabilize** (`Stab`) are the first
whole *categories* added rather than alternatives inside an existing pass, plus
**LUTDeRainbow** as a Chroma Fixes toggle. All three come from `havsfunc` and
MVTools, already in the bundle, so again no deps release.

Two orderings are load-bearing and asserted from both sides
(`test_110` in Rust, `pass_list_stages_test.dart` in Dart):

- **Anti-aliasing runs before Sharpen.** Sharpening a stair-stepped edge makes
  the stepping more visible, not less.
- **Stabilize runs last before Crop/Resize.** It shifts the picture within the
  frame and exposes thin empty edges, so a crop afterwards removes them.

> **`santiag`'s `type` is pinned to `nnedi3`.** havsfunc also accepts `eedi2`
> and `sangnom`; **neither is in the deps bundle**, and naming an absent one
> fails at script evaluation with a bare "no attribute" error. `AntiAliasParameters::effective_santiag_type`
> drops anything else. The same shape as `normalized_chroma_edi` — don't bypass it.
>
> **LUTDeRainbow shares LUTDeCrawl's 8-10 bit limit** ("This is not an 8-10 bit
> YUV or YCoCg clip"), so it gets the same convert-down-and-restore guard in both
> templates. Found by probing the bundle, not from documentation.
>
> **STPresso was dropped from this batch.** havsfunc implements it with
> `core.flux.SmoothT`, and the **fluxsmooth plugin is not bundled** — zsmooth
> provides `FluxSmoothT` under a different namespace, which havsfunc does not
> know about. That makes it effort 2, not 1.

> **Probe the signature, not just the call.** `Stab` shipped with a `range`
> argument that the bundled havsfunc does not have
> (`Stab(clp, dxmax, dymax, mirror)`), so every job using it died with a
> `TypeError`. The earlier probe called `haf.Stab(clip)` with no arguments and
> passed, which proved only that the function exists. `inspect.signature` against
> the bundled module is the check that would have caught it — the same lesson as
> aWarpSharp2's `chroma`, one level deeper.

> **A terse plugin error naming a property tells you the property is involved,
> not in which direction.** `daa` failed on macOS x64 and Linux x64 with
> `Failed to retrieve frame 0 with error: znedi3: _FieldBased`. Read as "znedi3
> rejects field-based clips", it produced a fix that cleared the property — and
> changed nothing, because the truth is the opposite. Probed against the bundled
> plugin:
>
> | `field` | no `_FieldBased` | `=0` | `=2` |
> |---|---|---|---|
> | 1 | OK | OK | OK |
> | **3** | **ERROR** | OK | OK |
>
> znedi3's **double-rate** mode *requires* the property; havsfunc's `daa` uses
> `field=3`, and this pipeline only sets `_FieldBased` when a field order is
> **known** — so an ordinary source with none killed the pass. The Anti-Aliasing
> block therefore always marks the clip: `0` after deinterlacing (that output is
> progressive) or when nothing was detected, the detected order otherwise.
> `test_139`–`test_141` pin all three cases.
>
> It survived on macOS arm64 (nnedi3 via patch 6) and on Windows (whose
> *prebuilt* znedi3 tolerates the absence) and died on the two bundles that
> build znedi3 from source — the worst shape a bug can have, since the same job
> worked or failed depending on the user's machine. **Two platforms passing is
> not evidence**; that is the same trap as a green Windows deps build.
>
> The whole detour cost two nightly cycles and would have been avoided by a
> two-minute `vspipe` probe against `deps/` — which is what the two notes above
> already say to do.

> **The heavy tests run the worker BINARY, not the library.** `cargo test`
> compiles `src/` into its own test executable, so the Rust suite can pass
> against new code while `app/test/integration_*` exercises a stale
> `worker/target/debug/vapourbox-worker`. The symptom is badly misleading:
> generated scripts full of unsubstituted `{{PLACEHOLDER}}` and a bare Python
> `SyntaxError` from vspipe, which reads like a template bug. `WorkerHarness`
> now prints a loud warning when the binary is older than anything in
> `worker/src` or `worker/templates` — **run `cargo build` before the heavy
> suite**.

> **The same trap on the Dart side: a stale `.g.dart`.** `app/lib/**/*.g.dart`
> is gitignored and every CI job runs `dart run build_runner build` immediately
> before testing, so **CI can never reproduce this** — it is purely a
> developer-machine failure. Add a field to a model, forget to rebuild, and
> `toJson()` keeps emitting the old key set; the worker's serde models carry
> `#[serde(default)]`, so the field arrives as its default and the pass runs
> with the wrong settings, with no error anywhere. You end up debugging the
> template. `app/test/generated_code_freshness_test.dart` fails the push gate
> when a declared field has no generated code, naming the field and the fix.
>
> It checks **field names, not mtimes**: build_runner is incremental and leaves
> a generated file alone when its output is unchanged, so an mtime comparison
> reports eight models stale straight after a clean build. Don't "simplify" it
> back to timestamps.

### Advanced mode is one app-wide setting, and it is the complexity lever

`AdvancedModeService` (**Settings → General → Show advanced options**, persisted
under `showAdvancedOptions`) gates three things: `advancedOnly` **sections**,
preset-controlled parameters, and `advancedOnly` **methods**. It is provided
through `MultiProvider` in `main.dart` and read with
`context.watch<AdvancedModeService>()`, so every panel agrees and the choice
survives collapsing a pass.

It used to be `bool _advancedMode` inside `_DynamicFilterPanelCompactState` —
per-panel, defaulting off, **reset on every collapse**. That made it useless as
a lever: an expert re-flipped it constantly, so nothing could be hidden behind
it aggressively enough to matter. Adding filters to this app means adding
*methods to existing passes* far more often than new passes, so `advancedOnly`
on a method is what keeps a slot's dropdown short. Field reference and the three
rules for using it: **[docs/FILTER_SCHEMA.md](docs/FILTER_SCHEMA.md)**.

### A method dispatch that removes N-1 blocks is quadratic, and it fails silently

`script_generator.rs` selects a filter method with one `match` arm per method,
each *removing* every sibling template block and then enabling its own. So a
pass with twelve methods has twelve arms each naming eleven blocks, and adding a
method means editing all twelve. A blanket edit that appends the new
`remove_block` to every arm therefore also appends it to the **new arm**, which
then deletes its own block before the `replace` that would have enabled it.

**mClean and TemporalDegrain2 both shipped that way** and were completely
unreachable: the pass was on, the script contained no denoiser at all, and the
encode produced a passthrough. Nothing failed — not the job, not the preview,
not `cargo test`, because neither method had a script-generation test. It was
found only because the parity suite asserts each pass differs from a
passthrough frame.

`test_149_every_noise_reduction_method_emits_its_filter` now walks the whole
enum and asserts each method's own call appears. **Enumerate the enum** — a test
per method only covers the method you thought to write one for, which is never
the broken one. `integration_filter_parameters_test.dart` carries the two
methods too, because the Rust test builds the struct directly and so cannot
catch a Dart `@JsonValue` drifting from the Rust serde name.

> The parameter-name parser in that Dart suite **preserves case**, and the
> spellings genuinely differ between plugins: mvtools takes `thsad`, mClean's
> wrapper takes `thSAD`. Don't "normalise" one to the other.

### `visibleWhen` only works inside `ui`, and 8 schemas had it outside

Reviewed 2026-08-18 after Chroma Fixes was reported as unintuitive. The panel was
showing every tuning slider for every repair at once, and the cause was not the
grouping — it was that **none of the conditions were being read**.

`ParameterDefinition` declares no `visibleWhen`; only `ParameterUiConfig` does.
A schema that writes it one level up therefore has it **dropped at parse time**,
and the control is always visible. Measured across the shipped schemas: **35
parameters in 8 files**, plus **12 sections** — and `UiSection` has no
`visibleWhen` either, so those did nothing at all. The pattern is a clean split by
age: everything written before the 2026-08-17 build-out put it in `ui` correctly,
everything added during it did not.

What that shipped, beyond Chroma Fixes: Noise Reduction showed its mClean and
TemporalDegrain2 knobs under SMDegrain, SpotLess showed RemoveDirt's, Chroma
Denoise showed CCD's threshold and sampling sliders under Cnr4, Deflicker showed
both methods' at once. All fixed by moving the key; section conditions were pushed
down onto their member parameters, which is the only place they work.

> **Both directions are now linted** in
> `app/test/filter_schema_curation_test.dart`: nothing may declare `visibleWhen`
> outside a parameter's `ui`, and every condition must name a parameter that
> exists — a `method` condition naming a method the filter doesn't offer can
> *never* be satisfied, so the control it guards would be invisible forever.
> That is the worse of the two silent failures, and nothing else would catch it.

> **Sections were not visible groups, and now they are.**
> `DynamicFilterPanelCompact` used to render a heading **only** for an
> `advancedOnly` section, and only in advanced mode — so every ordinary section's
> parameters ran together as one undifferentiated list and a `title` was
> effectively a comment. It now prints the title for every section, in both
> modes, **when the schema declares more than one**; a single-section schema
> still gets none, because there is nothing to tell it apart from and most of
> them call it "Settings". `advancedOnly` headings keep the accent colour.
> Pinned by `dynamic_filter_panel_advanced_test.dart`.

### Chroma Fixes: five repairs, one switch each, tuning behind advanced mode

The restructure that came out of the same review. The pass holds five unrelated
repairs — alignment, bleeding, dot crawl, rainbowing, chroma combing — and it now
reads as five: a switch, the one or two controls you would actually reach for, and
an `advancedOnly` tuning section for the thresholds, per filter, in that order.
(Per *filter*, not per repair — dot crawl and rainbowing each offer two, and
several of their labels repeat, so a shared tuning section would give no way to
tell which slider belonged to which.)
Default state is eight checkboxes instead of ~25 always-on controls.

Three things worth keeping:

> **Automatic and manual alignment are alternatives, and the script has to agree
> with the panel.** `_auto_chroma_fix` measures the misalignment and corrects it,
> and its block runs **before** the manual Y/C shift — so with both set the
> picture was shifted by a measured amount and then again by a number the user
> guessed, silently. The schema hides the manual controls
> (`visibleWhen: {"applyAutoChroma": false}`) and
> `ChromaFixParameters::effective_apply_chroma_shift` (Rust) /
> `effectiveApplyChromaShift` (Dart) is the single derivation both the generator
> and the pass summary ask. It deliberately does **not** clear
> `apply_chroma_shift`, so turning automatic off restores what the user set by
> hand. `test_150` and the Dart twin in `integration_filter_parameters_test.dart`
> pin all four combinations.

> **`optional: true` was a lie on every one of these parameters.** It promises
> "unticked → omitted → the plugin's own default applies", but
> `script_generator.rs` passes `Some(...)` for all of them unconditionally, so
> unticking silently substituted *our* default instead (havsfunc's `thr` default
> is 4.0; ours is 0.7). Combined with each repair's own switch it also meant two
> checkboxes per slider. All dropped, and the curation test now asserts nothing
> in this schema is `optional`.

> **`copyWith` silently reset two repairs.** It never gained parameters for
> `applyAutoChroma`/`applyDedot` or their tuning, so it reconstructed them at
> their defaults — and `ProcessingPipeline.togglePass` calls
> `chromaFixes.copyWith(enabled: …)`. Switching the pass off and on again
> therefore discarded the DeDot that **VHS Cleanup** turns on and the automatic
> alignment that **DV Camcorder Tape** turns on, with no error. When a field is
> added to a parameter model, `copyWith` is the third place to change, and it
> fails quietly rather than not compiling.

`bifrostInterlaced`, `deRainbowUseLuma` and `deRainbowLinkUv` are still
deliberately UI-less — they are sent at their defaults and nothing exposes them.
Note `bifrostInterlaced` defaults **true**, which is a question about progressive
sources rather than about the panel.

### The panel audit (2026-08-18): what the newly-visible headings exposed

Making section titles render (above) put every schema's grouping on screen for
the first time, so all 21 were audited together. Three defects, each in more than
one schema, and each invisible until then:

> **A method dropdown that gates nothing.** `color_correction` declared
> `tweak` / `white_balance` and `crop_resize` declared
> `standard` / `nnedi3_2x` / `eedi3_2x`. In both, **no parameter carried a
> `method` condition**, neither model has a `method` field, and the converter
> either hardcoded one value or emitted none — so the dropdown rendered,
> responded, and changed nothing. Crop & Resize is the sharper case: its real
> upscaler choice is the `upscaleMethod` *parameter*, which does gate its tuning,
> so the dropdown was an inert duplicate of a working control. Both are single-
> method now, which suppresses the dropdown entirely. Remember that a method's
> `parameters` list does **not** drive the panel when `ui.sections` exists —
> sections win — so listing parameters under a method is not gating them.

> **A parameter only some methods use, shown for all of them.** `deblock`'s
> `quant1` was ungated while DCTFilter — which does not take it — was one of the
> three methods on offer. Now gated to the two that use it.

> **Sections whose title was written as a comment, not a heading.** Three
> schemas held a section containing only `method`, which renders nothing because
> the panel draws the dropdown itself and always skips that parameter. And
> `chroma_denoise` / `spotless` / `noise_reduction` mixed "Settings" with
> siblings named after a filter ("Cnr4 settings", "RemoveDirt settings"), so the
> generic one read as if it applied to everything. Titles now name the filter
> whose controls they hold ("CCD settings", "SpotLess settings", "SMDegrain"),
> and the dead sections are gone.

All three are linted in `filter_schema_curation_test.dart`: at least one
parameter conditional on `method` wherever a schema declares two or more, a
method condition matching exactly the methods that list the parameter, and no
section consisting solely of `method`.

Deliberately **not** changed: `deinterlace`'s fourteen section titles (QTGMC's
grouping is established, documented and heavily referenced), and the mixed
Title Case / sentence case of parameter labels across schemas — now more visible
side by side under headings, but a cosmetic sweep of several hundred strings that
should be its own change.

### Every pass says which VapourSynth calls it makes

Added 2026-08-19 on request: experts coming from Hybrid, StaxRip or AviSynth
recognise `FixChromaBleedingMod` or `MSRCP` instantly and could not tell what a
VapourBox pass was doing from its labels. Each pass now prints its calls in
**advanced mode**, and only there — a plugin name is not actionable for someone
who has not asked for that level, and advanced mode is the lever for exactly
that judgement. Field reference: **[docs/FILTER_SCHEMA.md](docs/FILTER_SCHEMA.md)**.

Two shapes, because filters come in two shapes:

- **One call per method** — the readout prints the selected method's own
  `function`. That data already existed on every method and had **never been
  rendered anywhere**; this was mostly a display gap, not a data one.
- **Composite passes** — Colour Correction, Chroma Fixes and Crop & Resize are
  not one call. They declare an `implementation` list of everything they can
  invoke, each entry optionally gated by an `activeWhen` that reuses the
  `visibleWhen` matcher, and the readout shows the **whole repertoire with the
  running calls emphasised**. Seeing the inactive ones is the point: it says
  what the pass could do, not only what it is doing.

> **Colour Correction was the reported case and is the sharpest one.** It has no
> method dropdown at all (the inert one was removed in the panel audit), so
> before this there was nothing anywhere in the UI naming any of the six things
> it can run — `adjust.Tweak`, `std.Levels`, `haf.SmoothLevels`,
> `retinex.MSRCP`, and the two `PlaneStats`-driven automatic passes.

> **`activeWhen` takes more than one key, and that is load-bearing.**
> `applyLevels` chooses *between* `std.Levels` and `haf.SmoothLevels`, so each is
> gated on the pair `{applyLevels, smoothLevels}` and precisely one is ever
> emphasised. Gating both on `applyLevels` alone would claim the pass runs two
> levels operations. The same shape covers Chroma Fixes' automatic-supersedes-
> manual alignment, where both entries are `core.resize.Spline36` and only the
> `role` text tells them apart.

Three rules linted by `filter_schema_curation_test.dart`: no method leaves
`function` blank; a method declaring `"function": "custom"` must be explained by
an `implementation` list (`custom` is bookkeeping and is never displayed); and
every `activeWhen` key must name a real parameter, or the call reads as
permanently inactive — the same silent failure as a `visibleWhen` naming a
missing parameter.

### Presets are the other way a hidden setting arrives

A preset is the main route by which settings appear without anyone touching a
control — so it is the main route by which a setting the user *cannot see*
appears. The panel hides a parameter whose `visibleWhen` is unsatisfied and skips
one no section lists, silently in both cases, so a preset can enable a filter that
has no control on screen, cannot be adjusted and cannot be switched off.

Audited 2026-08-18 against the panel changes above: **the nine built-ins map
cleanly.** Worth recording why, because most of it is luck rather than design:

- **No built-in uses Colour Correction at all**, so neither the `apply_levels`
  fix nor the automatic-levels precedence can change what any of them render.
  (That gap is itself noted under "Audit the presets whenever a pass ships".)
- The three that use Chroma Fixes — VHS Cleanup (DeDot), DV Camcorder Tape
  (bleeding + automatic alignment), Anime DVD (DeRainbow + DeDot) — set **no
  manual chroma shift**, so nothing collides with the automatic pass.
- PAL DVD's deblock uses Deblock_QED, so `quant1` is still on screen under its
  new method gating.
- Removing the inert methods from `color_correction` and `crop_resize` can't
  affect a preset, built-in or user-saved: neither model has a `method` field, so
  no stored pipeline ever names one.

> **`builtin-fast` sets a QTGMC preset while selecting Bwdif, and that is
> deliberate** — the source says so: "kept so that switching method in the UI
> lands somewhere sensible". The panel hides it (a `method` condition), nothing
> applies it, and `preset_visibility_test.dart` therefore exempts values hidden
> **only** by a method condition. Don't "fix" it by clearing the value.

`app/test/preset_visibility_test.dart` walks every built-in's enabled passes
through the real converter and fails if a value differing from the schema default
is not reachable in that preset's own state. Advanced-only values are allowed
through a **named allowlist** — currently three, all QTGMC's, in a pass whose own
control and summary say it is doing something expert — and a companion test fails
if that list gains a stale entry, so it cannot quietly become a rubber stamp.

### Color Correction: automatic and manual belong in the same group

The pass reported as unintuitive (2026-08-18) — Chroma Fixes was reviewed first
by mistake, and the same three faults turned out to be in both.

It offers two adjustments that can be made **automatically or by hand**, levels
and white balance, and the automatic halves used to sit together in an
"Automatic" section at the top, three groups above the manual halves they
supersede. Each pair now shares a section, automatic first, so the relationship
is visible without reading the descriptions.

Four things were wrong underneath, all silent:

> **The Method dropdown changed nothing.** The schema declared `tweak` and
> `white_balance` as methods, but **no parameter was conditional on the choice**,
> neither model has a `method` field, and `fromColorCorrection` hardcodes
> `'method': 'tweak'`. Both groups of controls rendered whatever was selected, and
> the worker never saw the value. It is one method now, so no dropdown renders.
> A method that gates nothing is worse than no method: it teaches the user the
> panel responds to it.

> **`apply_levels` was a UI-only flag.** `script_generator.rs` decided by value —
> `has_levels` was true whenever any level differed from its default — so
> unticking "Levels" left the adjustment running with nothing on screen able to
> stop it (the sliders hide with the switch). `effective_apply_levels()` is the
> switch now, and it still requires something to do, so an identity mapping emits
> nothing. `test_151` pins both directions.

> **Automatic levels supersedes the manual points, but not gamma.** The automatic
> block runs first and places black and white itself, so manual input/output
> points on top grade an already-graded picture with numbers measured against the
> original. `effective_levels_points()` drops them and the panel hides them
> (`visibleWhen: {"applyAutoLevels": false}`). **Gamma is deliberately kept** —
> automatic levels never touches the midtones, and the Levels group is the only
> place in the app to reach them. That asymmetry is the whole design; don't
> "simplify" it into hiding the group.

> **White balance is the opposite case and must stay composable.** Automatic
> white balance neutralises the cast; temperature and tint then offset the
> result deliberately ("neutral, but a little warmer"). Same shape as levels,
> different answer, because an offset still means what its label says after a
> correction while a mapping does not. `pass_advice.dart` says which order they
> happen in rather than hiding anything.

`copyWith` had dropped all six automatic fields, which is the systemic bug below.

### `copyWith` silently resets what it forgets, in six models

`ProcessingPipeline.togglePass` rebuilds a pass through `copyWith`, so a field the
method never gained is a field that reverts to its default when the user flicks
the pass switch. It compiles, it runs, and the pass then does something other than
what the panel says.

Audited 2026-08-18 across every parameter model: **26 fields in 6 models**, all
added during the 2026-08-17 build-out — Colour Correction's six automatic fields,
Chroma Fixes' automatic alignment and DeDot (which VHS Cleanup and DV Camcorder
Tape turn on, so those presets lost settings to one click), thirteen in Noise
Reduction including every mClean and TemporalDegrain2 value, SpotLess's `method`
(so RemoveDirt silently reverted to SpotLess), QTGMC's `bwdifEdeint` and
Subtitles' `burnInPath`.

> **`app/test/parameter_copy_with_test.dart` checks it two ways, and it needs
> both.** The behavioural pass fills every field through `fromJson`, calls
> `copyWith()` and compares — but it cannot perturb a **string or enum** value
> (an invented one would not decode), which is exactly the shape of the SpotLess
> and Subtitles bugs. So a second pass reads the model source and asserts every
> `final` field of the parameter class appears in the `copyWith` body. Deleting
> either pass loses a real class of bug; both were verified against the actual
> defects.

### Frame counts and geometry are verified against the pipeline, not the model

`FrameMap` was covered only as arithmetic — `output_count`, `inverse`,
`total_radius` — which proves the model is self-consistent and says nothing
about whether the plugins agree with it. `run_job` in the Rust suite cannot
close that gap by design: it generates and inspects the `.vpy` and never runs
`vspipe | ffmpeg`. Two heavy Dart files now do (added 2026-08-20):

- **`integration_frame_mapping_test.dart`** — encodes and *counts* for every
  pass that changes the count: double-rate QTGMC (31 -> 62), single-rate as the
  control (31 -> 31), IVTC cycle 5 (90 -> 72), and FlowFPS 25 -> 23.976
  (75 -> 71). Expected values are derived by hand from the FrameMap definitions
  rather than read back from the model, so a change to the model cannot quietly
  redefine "correct". The retime case is the one that pins why FlowFPS was
  chosen over BlockFPS: `n*num/den` exactly, where BlockFPS gives
  `floor((n-1)*r)+1` and every retimed job's progress total would be a frame out.
- **Preview/render correspondence** in the same file, and for geometry in
  `integration_upscale_resize_test.dart`. `--frame N` is a **source** index (the
  worker logs "Preview: source frame N") and the target's output index is
  `output_count(local)`, so under double-rate the preview of source frame S must
  be output frame 2S. Measured **0.00** mean abs diff at the right frame against
  8-30 at its neighbours, which is bit-exact; and 0.00 for crop, resize and
  crop+resize. The geometry half also asserts the size, because a preview
  rendered at a different resolution shows up as a buffer-length mismatch in
  `meanAbsDiff` rather than as a pixel difference.
- **Crop pixels, not just crop size.** A size assertion cannot tell a correct
  crop from one that swaps left with right - both give the requested
  dimensions. The offset test crops asymmetrically and compares against the
  pipeline's own uncropped output cropped in Dart, so the swapped offsets are
  available as negative controls (measured 1.06 correct against 9.65 and 15.97).

> **`totalFrames` is the POST-TRIM count, and getting that wrong looks like a
> filter bug.** Trimming is decoder-side (`-ss` + `-frames:v`) and
> `pipe_source` builds a fixed-length clip from `totalFrames`, so the number has
> to be what the decoder will actually pipe. The app sets it that way
> (`main_viewmodel.dart`: `effectiveEnd - effectiveStart + 1`) and `main.rs`
> computes the same thing when it is absent ("effective after trim"). Pass the
> **full** source length alongside a trim and the script declares a clip longer
> than the data: pipe_source hits EOF and repeats the last real frame to pad, so
> the output is full-length with a frozen tail. The frame-mapping test was
> written that way first and reported 150 frames for a 31-frame trim, which
> reads exactly like FPSDivisor being ignored.

> **`select=eq(n,N)` on a source is not the pipeline's frame N.**
> `interlaced_test.avi` declares 79 frames and decodes 75: it carries null
> frames, and the decoder's default CFR mode expands them onto the 25 fps grid
> (measured: the first seven decoded frames come out 0,0,0,0,1,1,2). So `select`
> counts *decoded* frames while the pipeline counts *timeline* positions, and
> the two diverge wherever a null frame sits. That is correct behaviour —
> pipe_source needs a fixed-length CFR clip — but it makes ffmpeg-side frame
> indexing useless as a reference. Compare pipeline output against pipeline
> output, which uses one decoder and one indexing scheme.
> `WorkerHarness.frameRgb24` exists for that and decodes from the start rather
> than seeking, because an input seek lands on the nearest keyframe and would
> silently compare the wrong frame.

### Clean aperture: decode the stored frame, never resample to fit (2026-09-26)

**Found:** `Tests/TestResources/pal-sd-25.mov` (720x576 `yuv422p10le` ProRes)
carries a QuickTime `clap` (clean aperture) atom — 8 columns off the left, 9 off
the right. Since FFmpeg 7.1 the CLI applies **container** cropping by default:
`clap`, and Matroska's `PixelCrop*` elements, are exported as frame-cropping
side data and cut off at decode time. So the bundled 9.0.1 decodes that file at
**702x576** (1,617,408 bytes/frame) while ffprobe reports `width=720
height=576` — ffprobe's `width`/`height` do **not** include a container crop;
it appears only as `side_data_list: [{side_data_type: "Frame Cropping",
crop_left: 8, crop_right: 9, …}]`. (703 columns rounds down to 702 for 4:2:2.)

The first fix for the resulting garbage (June 2026, `8aad3f3`) forced the
decoder to `-s 720x576` on both paths. That stopped the desync by **rescaling
the 702-wide crop back to 720**: every clean-aperture source was cropped *and*
resampled before any filter ran, stretched 2.6% horizontally while the output
was still stamped with the source SAR, and the user's Crop values applied to an
already-altered picture. The regression test agreed with it because its
reference was scaled to 720x576 the same way.

**Mechanism, measured against 9.0.1:** `-apply_cropping` (an *input* option)
takes `none`/`all`/`codec`/`container`, default `all`:

| `-apply_cropping` | pal-sd-25.mov | H.264 1080p (1088 coded) |
|---|---|---|
| default / `all` / `container` | 702x576 | 1920x1080 |
| `codec` | **720x576** | **1920x1080** |
| `none` | 720x576 | 1920x**1088** |

`codec` is the one that equals ffprobe's `width`/`height` in both cases —
ffprobe *does* include the bitstream's own (SPS) crop. `none` would break every
H.264/HEVC 1080p source.

**Decision:** decode the full stored frame. `worker/src/source_decode.rs` builds
both decoders (encode + preview) with `-apply_cropping codec` before `-i`, and
no `-s`. Reasons:

- The pipeline then sees exactly what ffprobe reported, so the job's
  `input_width`/`input_height`, `pipe_source`'s frame size and the decode agree
  by construction, and the **Crop controls are the only crop**.
- The clean aperture is a *display* hint (the nominal analogue active area of a
  720-wide SD frame), not damaged picture; the 17 columns are real samples, and
  an archival tool shouldn't discard them unasked.
- **SAR is unchanged** by a clean aperture: it describes the pixel grid, and the
  grid is the same whether or not the edges are cut. ffprobe reports 59:54 either
  way, the encode stamps it as before, and the full frame at 59:54 is
  geometrically correct (DAR 295:216 over 720 columns; the clean aperture alone
  would be 767:576). What is lost is only the `clap` hint itself — the output
  doesn't carry it — which a user who wants the clean aperture replaces with an
  8/9 Crop.

**A size mismatch is now an error, not a resample.** Removing `-s` alone would
return a mismatch to the original silent desync, so the decoder carries a size
guard, `crop=w='if(eq(iw,W),iw,0)':h='if(eq(ih,H),ih,0)':x=0:y=0:exact=1`. At
the right size that is a full-frame, zero-copy crop (measured bit-identical to
no filter); at any other size `crop` rejects the zero width and the decode
fails. `crop` is re-configured on every input size change, so it also catches a
**mid-stream resolution change** (e.g. a DVB recording switching 720 -> 544 at an
ad break), which with `-s` was silently rescaled and with nothing would have
desynced. The worker recognises the crop filter's message
(`SIZE_GUARD_SIGNATURE`) and reports an explanation *before* the vspipe/encoder
status — `pipe_source` pads a short stream with its last frame, so without that
ordering the job would "succeed" with a frozen tail. This is a deliberate
behaviour change for mid-stream size changes: they fail with a clear message
rather than producing a distorted segment.

The guard immediately exposed a second silent resample: a job **without**
`input_width`/`input_height` fell back to 720x480, and `-s` squeezed whatever
the source was into that. `integration_video_trimming_test.dart` had been
encoding the 720x576 `interlaced_test.avi` to 720x480 all along, and passing,
because nothing asserted the size. The app always sends ffprobe's size, but the
worker now probes it itself when a job omits it (`fill_frame_size` in
`main.rs`, `DependencyLocator::probe_frame_size`), the same way it already
probed a missing frame count.

**Checked unchanged:** MKV/AVI/TS/MP4/DV fixtures without container crop decode
identically with and without the option (`small_clip.mp4`,
`soft_telecine_test.mkv`, `pal-dvbt-fieldcoded-25i.ts`, the two AVIs,
`prores422_10bit_telecine.mov`, DV from stdin); DVD import extracts MPEG-PS to a
file first and MPEG-2 has no container crop. The app's own picture decodes —
the "before" frame and the timeline thumbnails in `preview_generator.dart` —
use the same option (`PreviewGenerator.sourceDecodeOptions`), or the
before/after comparison would put a 702-column frame beside a 720-column one.
`field_order_detector`'s `idet` pass doesn't care about geometry and was left
alone. The option requires FFmpeg >= 7.1, which the 9.0 pin guarantees.

**Tests:** `source_decode.rs` unit tests assert both decoders carry
`-apply_cropping codec` *before* `-i`, never `-s` or a scale, and exactly one
`-vf` (the guard). `integration_clean_aperture_test.dart` (heavy) encodes
pal-sd-25.mov — and an MKV remux of it, generated at run time, for `PixelCrop` —
as a passthrough to FFV1 and requires the output's raw MD5 to equal a
full-frame decode of the source: a resampled picture can't pass that, while the
frame size alone would (the old `-s` also gave 720x576). It also builds a
mid-stream 720->544 TS and requires the job to fail with the explanation. Against
the pre-fix worker all three fail (MD5 `848ce4a8…` vs `784b2e46…`; the size
change encodes "successfully"). `preview_integration_test.rs`'s reference now
decodes the full frame unscaled; its 20.0 threshold is too loose to separate
the two (5.8 after vs 9.0 before) — the heavy Dart test is the one that does.

### Suggestions and advice are hints, and must stay hints

Two small pure-function models sit beside the pass list, and both are
deliberately toothless — neither blocks a job, disables a control or changes a
value:

- **`pass_relevance.dart`** (`relevanceFor`) decides whether a pass is
  `recommended` / `neutral` / `notApplicable` for the loaded file, from the
  `VideoInfo` detection already does (scan type, height, codec, SAR). It drives a
  "Suggested" badge and a reason line, and **never reorders the list** — row
  order is pipeline order, asserted by `pass_list_stages_test.dart`.
  The load-bearing property is restraint: a badge on nine of thirteen rows is
  decoration, not a recommendation, so passes detection cannot judge (dirt,
  scratches, grain, halos, banding, colour) return `neutral` and say nothing.
  `pass_relevance_test.dart` bounds the number of suggestions per source and
  asserts those nine stay silent for every scan type / height / codec
  combination. `ScanType.unknown` must stay neutral too — detection failed, so
  claiming either way is worse than silence.
- **`pass_advice.dart`** (`adviseOn` / `adviceFor`) comments on pass
  *combinations*, which is the complexity that actually bites: sharpening that
  the denoiser will undo, an FPS divisor that IVTC ignores, Vinverse with
  deinterlacing off. Rendered through the existing `WarningBanner` in
  `pass_settings_inline.dart`. Every combination it mentions still produces a
  valid render, so none of it is validation. Advice must only ever attach to an
  **enabled** pass — a banner on a pass the user isn't using is how advisory UI
  gets learned-to-ignore — and `pass_advice_test.dart` asserts that, plus that a
  default pipeline is completely silent.

**Curation is asserted, not just recommended.**
`app/test/filter_schema_curation_test.dart` lints every shipped schema: the first
method is never `advancedOnly` (it is the resolved default), at least one method
survives simple mode, every method carries a description (the only guidance the
dropdown shows), and **no schema offers more than 4 methods in simple mode**.
That last one is the load-bearing assertion — adding methods is expected, letting
a simple-mode dropdown grow without curating is what it catches. Currently
curated: dehalo 7 → 3, noise_reduction 4 → 3, crop_resize 3 → 2.

> The one trap: `FilterSchema.visibleMethods` **always keeps the currently
> selected method**, advanced-only or not. A preset can select one, and hiding it
> would both misreport the pipeline and hand `DropdownButtonFormField` a value
> that isn't in its items — a thrown assertion, not a graceful fallback. Don't
> "simplify" that argument away; `dynamic_filter_panel_advanced_test.dart`
> asserts it, along with the case that a filter filtered down to a single method
> still tells the user more exist.


### Attribution — never write a name you have not read upstream

Third-party credit lives in **three** places that must agree:
`licenses/NOTICES.txt` (shipped in every package), the About dialog
(`app/lib/views/about_dialog.dart`), and the README's Acknowledgments.
`app/test/attribution_test.dart` lints the first two against
`Scripts/deps-expected-plugins.json`, so **adding a plugin without crediting it
fails the build** — the map in that test has to gain an entry too.

What the test cannot catch, and what actually shipped
([issue #72](https://github.com/StuartCameronCode/VapourBox/issues/72)):

> **zsmooth was credited to "Adrian Woracz" — a name that does not exist.** The
> author's GitHub handle is `adworacz`; his LICENSE says **Austin Dworaczyk
> Wiltshire**. The handle was expanded into a plausible-looking human name
> instead of being looked up, and it went out in the README, the About dialog
> and NOTICES simultaneously. The author found it and opened an issue.
>
> **Every copyright line must come from the upstream LICENSE file or a source
> header, fetched at the time of writing.** A GitHub handle is not a name. A
> repo owner is not necessarily the copyright holder. `gh api repos/<r>` gives
> the SPDX id, and the LICENSE / first 40 lines of the main source file give the
> holder — that is a 30-second check per component.

The 2026-08-17 audit that fixed it found the same class of error throughout,
which is why the whole file was rebuilt from upstream rather than patched:

- **Licences were wrong, not just names.** CTMF is GPL-3.0 (listed as 2.0),
  DCTFilter is MIT (listed as GPL-2.0), AWarpSharp2 is ISC and RemoveGrain is
  WTFPL (both listed as GPL-2.0). The bundled FFmpeg is built
  `--enable-gpl --enable-version3`, so it is **GPL-3.0**, not the LGPL the file
  claimed.
- **Year ranges were invented.** "Copyright (c) 2012-2024 …" appeared on
  components whose upstream states no such range, including projects that
  assert no copyright at all (havsfunc is Unlicense; FluxSmooth's author
  explicitly disclaimed copyright).
- **It credited something not shipped** (ffms2, removed with BestSource) and
  **omitted about fifteen plugins that are, or shortly will be** — Retinex,
  bifrost, fluxsmooth, DeScratch, VIVTC, TCanny, TTempSmooth, AddGrain,
  FFT3DFilter, KNLMeansCL, MiscFilters, TemporalMedian, BM3D, zimg, Zstandard,
  and the Agner Fog VCL that eight HolyWu plugins compile in. Both directions
  are now asserted.
- **`mvsfunc` has no licence at all upstream** — no LICENSE, no header. That is
  now stated plainly rather than guessed as "Unlicense". Don't "tidy" it into a
  licence name.

When a project genuinely states nothing, say so and offer to remove it on
request. An honest "no licence stated" is worth more than a confident guess.


### The ARM interpolator choice: nnedi3, not znedi3 (patch 6)

**Never name an nnedi3 implementation directly.** Both templates define a
`_nnedi3()` helper and havsfunc gets an `_nnedi3_impl()` via patch 6; every call
site goes through one of those. `test_92` fails the build if a template
reintroduces a direct `core.znedi3.nnedi3` / `core.nnedi3.nnedi3` call.

The reason is a pure-performance trap that produces a **correct picture**, so
nothing but a benchmark or that assertion catches it:

- znedi3's SIMD kernels are x86-only, so `download-deps-{macos,linux}.sh` build it
  `make X86=0 X86_AVX512=0` and ARM gets the scalar `PredictorC`/`PrescreenerOldC`
  path. The bundled dubhater **`nnedi3` has real NEON kernels**
  (`computeNetwork0_neon`, `dotProd_neon`, …).
- Measured on an M1, QTGMC Slow, 400 frames of 720x576: **37.8s of CPU for znedi3
  vs 5.95s for nnedi3 — 6.3x**, and 30% of the entire arm64 QTGMC cost. End to end
  the swap is worth **+10% (Faster) to +40% (Slow)**.
- havsfunc hardcoded `core.znedi3.nnedi3 if hasattr(core, 'znedi3')` at three call
  sites (daa, santiag, QTGMC), so *every* ARM deinterlace paid it.

The two plugins implement the same network from the same `nnedi3_weights.bin` and
their signatures are identical for every argument used, so this is a drop-in swap:
measured mean output difference **0.045/255** for the interpolator alone and
**0.072/255** end-to-end through QTGMC (tolerance is 2.0). Worst single pixel is
~48/255 on hard edges, where the two implementations' float rounding flips a
prescreener decision — expected for independent implementations of the same net.

The choice is made **at runtime** (`platform.machine()`), not by the build, so the
patch text stays identical on every platform and **x86 keeps using znedi3
unchanged**. nnedi3 is therefore required only on the **ARM** bundles —
`deps-expected-plugins.json` lists it for `macos-arm64` and `linux-arm64` and
deliberately **not** for the three x86 ones, which never call it. Requiring it on
x86 just fails the packaging guard on a plugin nothing would load (nnedi3's x86
path also needs `yasm`, which the runners don't have).

> **Building nnedi3 on aarch64 needs two source patches**, because dubhater's
> build system treats every ARM as 32-bit ARMv7. `-mfpu=neon` is an ARMv7 option
> that aarch64 gcc rejects outright, and `cpufeatures.cpp` reads `HWCAP_ARM_*`
> from `getauxval()` — constants that exist only for 32-bit ARM. macOS only ever
> hit the first (it takes the `__APPLE__` branch in `cpufeatures.cpp`), which is
> why Linux arm64 shipped without the plugin until 2026-08-07. Both edits, and a
> guard that hard-fails if either stops matching, are in the nnedi3 block of
> `download-deps-linux.sh`; keep the `-mfpu` expression identical to the macOS
> one. The second patch is the one to be careful with: `nnedi3.cpp` only does
> `if (!cpu.neon) d->opt = 0`, so a wrong answer there yields a **correct picture
> at scalar speed** — the same silent failure this whole section is about.

> This is one instance of a much larger arm64 gap: native arm64 QTGMC runs
> **3–4.5x slower than the x64 bundle under Rosetta**. The dominant cause is not
> this but `std.Expr` — VapourSynth's `compile_jit()`
> (`src/core/expr/jitcompiler.cpp`) is wrapped in `#ifdef VS_TARGET_CPU_X86`, so on
> aarch64 it returns no compiler and `exprfilter.cpp` falls back to
> `ExprInterpreter::eval()`, a scalar switch-dispatch interpreter run **once per
> pixel**: 69.5s vs 3.3s of CPU on the same job, **21x**. Most of VS core is
> x86-SIMD-only the same way (genericfilters, mergefilters, averageframes,
> planestats). Not a cause: mvtools is *faster* natively (it compiles its SSE2
> paths through simde). **That Expr gap is now closed by akarin** — see below.

### `std.Expr` on ARM goes through akarin's LLVM JIT

VapourSynth's `compile_jit()` is x86-only, so on ARM every expression is walked
**once per pixel** by `ExprInterpreter::eval()`. Measured on an M1 under R78,
`Expr` costs **550–640 CPU-seconds** in a QTGMC Slow graph against the
interpolator's **30** — it is not one cost among several, it is the cost.
`akarin.Expr` is a real LLVM JIT that works on aarch64: **QTGMC Slow 11.5s →
2.8s, 4.1x** (3 runs each, 720x576, 120 output frames).

Three things to keep straight:

- **The routing is a shim, not 116 edits.** havsfunc has 116 `core.std.Expr`
  call sites, so **patch 7** rebinds its module-level `core` to a proxy that
  swaps *only* `.std.Expr` and forwards everything else. The proxy installs
  **only when `core.akarin` exists**, so where it doesn't, `core` stays the real
  core — no wrapper, no overhead, no behaviour change. Both templates get an
  `_expr()` helper for their own two call sites each, mirroring `_nnedi3()`;
  `test_93` fails the build if either calls `core.std.Expr` directly, and also
  if the helper's fallback calls *itself* (a blanket search-and-replace made it
  infinitely recursive once — the fallback must name `core.std.Expr`).
  **`test_93` only scans the two `.vpy` templates**, not vendored `.py` modules
  in `worker/templates/`. That has never mattered because `spotless.py` uses no
  `Expr` at all — but TemporalDegrain2 and mClean both do, so vendoring either
  as-is would silently take the 21x scalar-interpreter path on ARM with nothing
  failing. Extend the assertion to `worker/templates/*.py` before vendoring
  anything that calls `Expr`.
- **macOS x64 deliberately does not get it.** The only wheel is
  `macosx_14_0_x86_64` and that bundle targets **12.0** (issue #39), so shipping
  it would raise the Intel floor to macOS 14 — for a platform that already has
  the JIT. It keeps `std.Expr` through the fallback. The namespace requirement in
  `vapoursynth_integration_test.dart` is therefore **conditional**, like `nnedi3`.
- **It is not bit-identical, and the one difference is known.** Of the **46**
  expressions havsfunc actually generates, 45 match exactly. The exception is the
  `DeHalo_alpha`/`FineDehalo` edge-**mask** scale `x {thmi} - {i} / 255 *`, where
  one input value lands on an exact `.5` tie: `std.Expr` rounds half-to-even,
  akarin rounds down — one level, in a mask. So macOS x64 differs from every
  other platform by that one level. That is far smaller than the ARM/x86
  difference already accepted for nnedi3 vs znedi3 (mean 0.045/255, worst pixel
  27/255).

**Test the corpus, not a sample.** The expressions are mostly f-strings with
computed thresholds, so a static scan of havsfunc finds **11** of the 46.
`app/test/akarin_expr_parity_test.dart` (heavy) collects them *at runtime* across
every QTGMC preset plus daa/santiag/LSFmod/DeHalo_alpha/FineDehalo/SMDegrain/
Deblock_QED/EdgeCleaner/YAHR, then compares both implementations over inputs
covering all 256 values. It asserts `corpus >= 40` so a broken collector fails
rather than passing vacuously, and bounds the difference at exactly what is
measured today (worst ≤ 1 level, ≤ 1 differing expression).

The plugin comes from the `vapoursynth-akarin` **PyPI wheel** (a wheel is a zip;
never pip-install it into the embedded interpreter), pinned to a version and
resolved through the PyPI JSON API so the hashed file URL is never hardcoded.
Per-platform placement differs and matters:

| | plugin | its private libs |
|---|---|---|
| macOS arm64 | `vapoursynth/plugins/` | `lib/`, repointed from `@loader_path/../../../vapoursynth_akarin.dylibs` and **re-signed** |
| Linux x64/arm64 | `vapoursynth/plugins/` | `lib/`, via `patchelf --set-rpath` |
| Windows x64 | `vapoursynth/vs-plugins/` | **beside the plugin** |

On Unix the private libs go in `lib/` rather than `plugins/`, because `plugins/`
is autoloaded and a non-plugin `.so` there gets probed on every core init. `lib/`
is deliberately **not** on `DYLD_LIBRARY_PATH`, so the bundled libz cannot shadow
the system one for ffmpeg. Linux's zstd carries a **per-arch build hash** in its
filename (`libzstd-5df4f4df…` on x64, `-a1561916…` on arm64), so glob it — and
the ELF `NEEDED` entry uses that exact hashed name.

akarin is **LGPL-3.0** and statically links **LLVM 22.1.2** (Apache-2.0 with LLVM
exception); both are in `licenses/NOTICES.txt`. It adds ~61 MB uncompressed per
platform, but only about **21 MB to each deps zip** — the earlier "the zips
roughly double" estimate was wrong, because it compared uncompressed size against
compressed zips.


### Installing a deps bundle: staged, swapped, and version-directional

`DependencyManager` **replaces** a bundle rather than merging into one, which is
what makes a layout change like R73 → R78 safe: no `libvapoursynth-script`,
`vapoursynth.conf`, `libbestsource`, `python38.*` or stale `VSPipe.exe` survives
into the new install. (That last one matters — `dependency_locator.rs` keeps a
deliberate fallback to the old top-level `VSPipe.exe`, so a leftover R73 binary
could otherwise be picked up silently.)

Three properties worth preserving if you touch this:

- **Staged, then swapped — but only when there is an install to protect.** An
  *upgrade* is verified, extracted to `<deps>.new`, stamped with its
  `version.json` and only then swapped in via two renames, with the old tree
  moved to `<deps>.old` and deleted afterwards; if the second rename fails the
  first is undone. It used to delete the live install and extract over the top,
  which left the user with *nothing* if that window was interrupted. A **first
  install** extracts straight into `<deps>` and performs no rename at all —
  there is nothing to protect, and the rename is the fragile step (see below).
- **`version.json` is written last**, inside whichever tree was written. It is
  the commit marker: a tree that never completed can never look valid — which
  is also what makes extracting a first install in place safe.
- **Direction is checked, not just equality.** Installed *newer* than expected
  is `newerThanExpected` — kept, with a one-time warning at startup — not
  `outdated`. Treating it as outdated downgraded a deliberately newer bundle,
  and since installing wipes and replaces, that was destructive. Use
  `compareVersions`, not `!=` or a string compare: `"1.10.0"` sorts before
  `"1.9.0"` lexically.

> **A Windows directory rename is refused while anything holds a handle inside
> it, and that is not a permissions problem (issue #87).** Measured: an open
> read handle on one descendant file, or a child process whose working directory
> is inside the tree, is enough — both surface as
> `PathAccessException … Access is denied, errno = 5`. A *running* `.exe` inside
> the tree is **not** enough, and a destination that already exists gives
> **errno 183** instead, so the two can be told apart. Straight after writing a
> ~200 MB bundle there is routinely something holding a handle for a few hundred
> milliseconds — a scanner, the search indexer, Explorer building a thumbnail —
> and the reporter's install failed on that every time, throwing away the whole
> download at the very last step.
>
> Both renames therefore go through `retryTransientFsOperation` (~7.5s over 12
> attempts), as does the `.new`/`.old` cleanup at the start — a leftover `.new`
> can still be held by whatever blocked the swap, and an unguarded delete there
> failed the *next* attempt with a second, different error.
> `PathExistsException`/`PathNotFoundException` are rethrown immediately: those
> will not clear, and burning the budget on them delays a fault the user can act
> on. `dependency_install_retry_test.dart` reproduces the real errno 5 on
> Windows and skips elsewhere, because POSIX renames a directory happily with
> its files open.
>
> **`executabilityProblem()` runs after the swap on Windows, before it
> everywhere else.** The quarantine case it guards (issue #50) is macOS-only, so
> on Windows all it can report is a generic "would not run" — while executing a
> freshly written, unsigned 100 MB binary is exactly what makes a scanner open
> the tree we are about to rename. A Windows failure rolls the previous bundle
> back out of `<deps>.old`, so it still cannot leave the user worse off.

**The zip survives a failed install, and the dialog says what is happening.**
Three things about the feedback, all of which #87 exposed:

- **The download is cached, not thrown away.** It lands in
  `<temp>/vapourbox-deps-cache/<filename>` and is deleted **only after the
  install succeeds**, so Retry skips a ~200 MB re-download of bytes that were
  never the problem. It is reused only when the sidecar supplied a sha256 to
  check it against — without one, a truncated download is indistinguishable
  from a complete one and would surface as a corrupt bundle. Anything in that
  directory under another name is another version's leftovers and is pruned,
  which is what bounds the cache.
- **The install phase emits progress.** It used to emit nothing between the last
  extraction tick and `Complete`, so the swap happened under a bar reading
  "Extracting… 100%" — and the retry budget added to that would have been
  indistinguishable from a hang. `_reportInstallStep` sends 0/0 events (an
  indeterminate bar, deliberately: the swap has no fraction to report) and
  `retryTransientFsOperation`'s `onRetry` names the wait.
- **The remedy is chosen from the failure.** `DependencyManager.remedyFor` maps
  the error to advice — held handles, a full disk, a permissions fault, or the
  connection line as the fallback — and `DependencyInstallException` carries its
  own for messages that already say what to do (macOS quarantine ships its
  `xattr` command). The dialog used one fixed line of *connection* advice under
  every failure, which is why the reporter went looking at folder ACLs. The
  headings were wrong for the same reason and now say **Installation Failed**,
  not "Download Failed" — most of what can fail here happens after the download.

The critical-file list also includes a file that exists **only** in the R78
layout (`libvapoursynthfilters`, plus `vapoursynth/__init__.py` on Unix).
`vspipe`, `plugins/` and `ffmpeg` all exist in both layouts, so without an
R78-only marker a stale tree carrying a newer `version.json` passes every check
and fails later at job time.

### R78: `deps/<platform>/vapoursynth/` IS the Python package (macOS/Linux)

R78 ships VapourSynth as a Python package, and this is not cosmetic. `vsscript`
resolves the Python library through a config file at
`$XDG_CONFIG_HOME/vapoursynth/vapoursynth.toml`, **keyed by the absolute path of
`libvsscript`**. That file is written by `vapoursynth config`, which records the
`libvsscript` belonging to the *imported package*. So the copy `vspipe-bin`
loads and the copy the module reports must be the same file, or every script
dies with:

> Python executable and library path couldn't be determined despite automatic
> configuration. Run `vapoursynth config` ...

Hence the layout: the libraries, `vapoursynth.abi3.so` and the pure-Python files
(`__init__.py`, `_cli.py`, `_utils.py`, …) all live in
`deps/<platform>/vapoursynth/`, and the **platform directory is on `PYTHONPATH`**
so `import vapoursynth` resolves there. Four consequences:

- **Ship the `.py` files too.** Without them `vapoursynth config` cannot run and
  vsscript's automatic configuration has nothing to call.
- **A `vapoursynth` shim goes in `python/bin/`.** vsscript self-configures by
  literally running `system("vapoursynth config")`; a from-source build creates
  no console script, so we provide one.
- **`XDG_CONFIG_HOME` must point somewhere writable** (`deps/<platform>/config`).
  The worker, the app and the vspipe wrapper all set it.
- **Do not set `VAPOURSYNTH_EXTRA_PLUGIN_PATH` on macOS/Linux.** The plugins are
  at `vapoursynth/plugins`, which is `<libdir>/plugins` — R78 autoloads it. With
  both, every plugin loads twice and warns `Plugin ... already loaded`. Windows
  still needs the variable: its plugins are in `vs-plugins`, which is not the
  autoload directory.

`_has_implicit_config()` returns true **only on Windows** (where `python.exe`
sits next to the package), which is why the Windows bundle needs none of this and
why a Windows-only test pass does not prove the Unix path works.

### No source-indexing plugin is bundled

Sources are read as **raw frames piped from ffmpeg** (`templates/pipe_source.py`),
so nothing in the product opens a file through a VapourSynth source filter.

FFMS2 went first, replaced by **BestSource**; then the pipe source replaced that,
and BestSource stayed in the macOS bundle for years afterwards calling itself
"bundled for parity" — parity with nothing, since Windows and Linux never shipped
it. Removed 2026-08-07: no `core.bs.` call site existed anywhere in the
templates, worker, app or tests.

It was worth removing rather than leaving alone. At **16.9 MB** it was four times
the next largest plugin and about a sixth of the macOS deps zip, and it was the
**only** consumer of `liblzma` — so it also carried the `xz` from-source build on
x64, two `install_name_tool` repoint blocks (its arm64 build links the *system*
liblzma, its x64 build Homebrew's), and their codesign steps, all of which went
with it.

If a source filter is ever needed again, add it back deliberately with a call
site — don't reintroduce it into the preview path, which is pipe-source-based for
frame-accuracy reasons.

### fmtconv's aarch64 integer scaler bug (fixed by our own patch)

**Symptom.** `fmtc.resample` returned **black** whenever fmtconv's integer kernel
ran with a source bitdepth below 16. Only **macos-arm64** and **linux-arm64** were
affected: on x86 the SSE2/AVX2 scalers replace the offending function in the
`Scaler` constructor, so there it is dead code. Measured by scaling a flat plane
by two:

| source | axis | kernel | result |
|---|---|---|---|
| 8-bit | horizontal | `SB=16 DB=16` | correct |
| 8-bit | vertical | `SB=8 DB=16` | **black** |
| 10-bit | either | `SB=10 DB=16` | **black** |
| 12-bit | either | `SB=12 DB=16` | **black** |
| 16-bit | either | `SB=16 DB=16` | correct |

It is **not** vertical-only: 10- and 12-bit sources broke on both axes. 8-bit
horizontal is the single case that escaped, because that route converts to 16-bit
*before* the scaler and so lands on `SB = DB = 16`. Same-size resampling and float
sources were never affected. (Deinterlacing hit it via the vertical axis, which is
why it first looked like a vertical-only bug.)

**Root cause** (`src/fmtcl/Scaler.cpp`, `process_plane_int_cpp`). That kernel
applied the same sign-conversion constants as its SSE2/AVX2 siblings:

```c
s_in  = (SB < 16) ? -(0x8000 << (SHIFT_INT + SB - DB)) : 0;
```

The vector kernels need those because they accumulate in **signed** 16-bit lanes
and their proxy (`ProxyRwSse2<SplFmt_INT16>::S16<CLIP_FLAG, SIGN_FLAG>`) XORs bit
15 back on read/write. The C++ kernel has no such counterpart — it accumulates in
a plain `int` and `ProxyRwCpp` is **unsigned** at both ends (`read()` returns the
raw value, `write_clip<DB>()` clamps to `[0, 2^DB-1]`). So the bias was applied
with nothing to undo it and every output clamped to 0. For 8→16-bit,
flat input 120: `120*4096 - 524288 + 8 = -32760`, `>>4 = -2048`, clamped to `0`.
`SPAN_I` covers SB = 16, 14, 12, 10, 9, 8 with DB always 16, so only SB = DB = 16
was correct — there the constants are already 0.

**Fix.** `Scripts/patches/fmtconv-r31-arm-int-scaler.patch` drops the sign
constants from the C++ kernel. Applied by `download-deps-{macos,linux}.sh` right
after the clone, and it **hard-fails the build** if it stops applying rather than
silently shipping the bug back. Windows needs nothing (prebuilt x86 DLL).

Not submitted upstream — that needs a GitLab account. If anyone wants to send it
later, the patch is the whole change and its header carries the full analysis.

**How it surfaced.** havsfunc's `Bob()` bobs fields via
`fmtc.resample(scalev=2, ...)`, so on Apple Silicon it destroyed the image:

- **Placebo / Very Slow** came out **~+10/255 brighter**. They are the only
  presets that default `NoiseProcess=2`, and that noise pass calls `Bob()` to
  expand fields before extracting noise. The near-black "denoised" clip made
  `MakeDiff` clip hard, so `GrainRestore`/`NoiseRestore` merged a large positive
  bias back in.
- **Draft** came out nearly black (`EdiMode='bob'` interpolates via `Bob()`).
- **Slower and below** were fine: their only fmtconv use is the same-size `Sbb`
  gauss blur, which doesn't scale vertically.

havsfunc patch 5 (`Bob()` at 16-bit) is kept as **defence in depth** — it is
redundant now that fmtconv is fixed, and both routes were measured to produce the
same output, but it also covers the prebuilt Windows DLL and any future build
where the fmtconv patch is dropped. Removing it would be safe; removing the
fmtconv patch would not, since `Bob()` is far from the only sub-16-bit
resample in havsfunc.

**Upstream status.** Not fixed as of r31. Its changelog has a promising "program
path without x86 SIMD: fixed wrong conversions (noticed on ARM/Apple)" entry, but
r31 reproduces the failure exactly — as do yuygfgg's prebuilt arm64 binary and a
local `-O0` build. Worth re-checking on the next release so the patch can be
dropped; the tests assert pixel behaviour, not patch text, so they stay valid
either way.

### fmtconv version is pinned, and upstream moved to GitLab

fmtconv development moved to **`gitlab.com/EleonoreMizo/fmtconv`** in Aug 2023.
The GitHub repo is an abandoned mirror whose last commit is literally
*"Repository moved to Gitlab"*, so cloning its `master` silently pinned us to a
stale post-r30 snapshot. All platforms now use **r31**, pinned:

- macOS / Linux: `FMTCONV_TAG` in `download-deps-{macos,linux}.sh` (GitLab tag)
- Windows: the r31 zip in `download-deps-windows.ps1` (from the author's site —
  GitHub release assets stopped at r30, and that URL is what the official GitLab
  r31 release links to)

**Keep these in step.** r31 changed interlaced PAL-DV chroma placement (U/V
vertical positions were swapped, vertical subsampling > 2 unhandled), so a
version skew between platforms would change chroma per-OS.


---

### Hardware Encoders (issue #51)

Three invariants that are easy to break and hard to notice, because a wrong
value here shows up as "this GPU doesn't work" rather than as an error:

- **The availability probe must use a large enough frame.** Hardware encoders
  have minimum dimensions, and below them they fail — so a too-small probe
  reports a *working* encoder as broken. AMD AMF rejects 64x64, which is exactly
  what the probe used to send. `HardwareEncoderDetector.probeFrameSize` is now
  512 (AMF's floor is 192x128 on some ASICs); `hardware_encoder_probe_test.dart`
  keeps it there.
- **Presets are per-family vocabularies and must not cross over.** x264 takes
  `ultrafast…placebo`, NVENC `p1…p7`, QSV `veryfast…veryslow`, AMF
  `speed|balanced|quality`. A saved preset or imported job config can pair a
  codec with the wrong family's preset; ffmpeg then rejects the option and the
  whole encode dies. `VideoCodec::normalized_preset` (Rust) substitutes the
  family default — the Rust `available_presets`/`default_preset` must stay in
  step with `availablePresets`/`defaultPreset` in `app/lib/models/video_job.dart`.
- **AMF is pinned to `nv12`.** Left to negotiate, a >8-bit source reaches the
  encoder as p010; 10-bit HEVC encode exists only on some AMD ASICs, and where
  it doesn't the AMF runtime faults (0xC0000005) instead of failing cleanly.
  h264_amf has no 10-bit mode at all. Custom FFmpeg Arguments still override it
  (a later `-pix_fmt` wins), which is the escape hatch for 10-bit HEVC on
  hardware that supports it.

- **A hardware encoder's declared pix_fmt list is not a statement about the
  machine (issue #74).** The list ffmpeg negotiates against is compiled in;
  NVENC's real capabilities are queried from the driver at `avcodec_open2`. A
  recent ffmpeg built against NVENC SDK 13 advertises `yuv422p` on
  `h264_nvenc` for Blackwell's 4:2:2 support, so negotiation picks it for any
  4:2:2 source — and every pre-Blackwell card then fails the job outright with
  *"YUV422P not supported / No capable devices found"*, zero frames written.
  Reported on an RTX 4070 Super with a CineForm `yuv422p10le` capture at the
  default "Match source" colour format. **ffmpeg cannot negotiate its way out
  of this**, so `forced_pix_fmt` picks the format instead.

`VideoCodec::forced_pix_fmt` therefore takes the format the pipeline will
actually hand the encoder — `VideoJob::encoder_input_pix_fmt`, which is the
output conversion when one is selected and the pipe format otherwise. Three
things about it are load-bearing:

- **The NVENC/QSV arm is conditional and the other two are not.** HuffYUV and
  AMF take one format whatever the source was; NVENC does not. Pinning it
  unconditionally the way AMF is pinned would flatten a 10-bit 4:2:0 source to
  8-bit for everyone it already serves correctly, so the guard fires only on
  4:2:2, 4:4:4, or >8-bit into an H.264 encoder (neither family has a 10-bit
  H.264 mode). A 4:2:0 job emits no `-pix_fmt` at all, exactly as before.
- **HEVC keeps the depth, H.264 cannot.** 4:2:2 10-bit into `hevc_nvenc`
  becomes `p010le`, not `yuv420p` — only the chroma has to go. NVENC gets the
  planar `yuv420p` and QSV the semi-planar `nv12`, each family's native name.
- **VideoToolbox is deliberately excluded.** It never advertises a mode it
  lacks, so its negotiation is trustworthy and forcing a format would only
  throw away chroma it could have kept. QSV *is* included, preventively rather
  than on a report: `hevc_qsv` advertises `y210le` on builds whose hardware may
  not have it, which is the same trap.

None of the AMF behaviour can be verified in CI or on macOS — there is no AMD
hardware in the matrix — and the same is true of NVENC and QSV, so these rest
on unit tests over the emitted arguments plus reporter confirmation. Note the
functional probe in `HardwareEncoderDetector` cannot catch the #74 class at
all: it encodes one `yuv420p` frame from lavfi, so it correctly reports NVENC
as *available* — the device works, only the format doesn't. Don't try to fix a
format problem in the device probe; the format isn't known until a file loads.

### The user-facing half of #74

The guard above keeps the job running, but silently changing someone's output
is only acceptable if they can see it coming and choose otherwise. Two things
shipped with it:

**A 4:2:0 10-bit output format.** `ChromaSubsampling::Yuv420P10` /
`ChromaSubsampling.yuv420p10` — the only 10-bit layout NVENC, QSV and AMF can
encode, so it is how a 10-bit source keeps its grading through a GPU encoder by
the user's own choice rather than by the guard's fallback. Verified end to end
(`integration_high_bit_depth_filters_test`): a 10-bit 4:2:2 source comes out
`yuv420p10le`, profile **High 10**. Adding an option touches four places —
`vapoursynth_format`, `ffmpeg_pix_fmt`, the Dart enum with its `outputBitDepth`,
and `chromaFormatHelpSections`, which `settings_chroma_help_test` fails on if
the new label goes unmentioned.

**A warning under the dropdown.** `hardwareEncoderChromaWarning` in
`app/lib/utils/pixel_format.dart` says which format will be substituted and
why, before the job runs. It covers both routes into #74 — a 4:2:2 *source* at
"Match source", and an explicitly chosen 4:2:2 *output* — and it stays silent
for everything encodable, for VideoToolbox and AMF, and until a file is loaded.

> **It is a second implementation of the worker's decision, and that is the
> risk.** If the two disagree the interface promises one thing and the encode
> does another, which is worse than either being wrong alone. Both sides are
> therefore pinned to **the same table of cases** — `substitutions match the
> worker, case for case` in `hardware_encoder_chroma_warning_test.dart` against
> `test_nvenc_cannot_be_handed_422` and its neighbours in `video_job.rs`. Change
> one and change both. `pixelFormatChromaLayout` is likewise a coarse Dart twin
> of `ChromaClass`; the Dart side already reimplements this kind of pix_fmt
> parsing in `pixelFormatBitDepth`, so it follows that precedent rather than
> inventing a new one.

**A second help dialog**, `ColourPipelineHelpIcon` /
`colourPipelineHelpSections`, beside the existing `ChromaFormatHelpIcon`. The
two answer different questions and both are worth having: the first is *what
are these formats and which do I pick*, the second is *what does the app do to
my colour* — the pipe source normalising upward on the way in, filters
converting down and back per pass, every UI threshold being in 8-bit units and
rescaled to the clip depth, the output conversion dithering, the Y4M pipe
stripping SAR and colour tags so they must be re-stamped, and the encoder
having the last word. A deliberately distinct icon (`schema_outlined`, not a
second `info_outline`), asserted, because two identical adjacent buttons read
as one control repeated.



### ProRes: the profile decides the chroma, not ffmpeg (issue #81)

Reported as "please add ProRes", when Proxy/LT/422/HQ had shipped for months.
Most of what was wrong was that the app said otherwise, so this is mostly a
correctness change with two profiles added on the end.

> **ffmpeg's pixel-format negotiation never looks at `-profile:v`.** Measured
> against the bundled build: `prores_ks -profile:v 4` and `-profile:v 5`
> auto-select `yuv422p10le` from a `yuv420p` input, exactly as `-profile:v 2`
> does. So ProRes 4444 shipped without a pin writes a file **stamped 4444
> carrying 4:2:2** — valid, playable, and the profile's entire point discarded
> with no error anywhere. `VideoCodec::forced_pix_fmt` now decides from the
> profile (4/5 → `yuv444p10le`, 0-3 → `yuv422p10le`), joining the HuffYUV and
> AMF pins. Issue #74's lesson generalises: an encoder's declared format list
> is not a statement about what the output should be.
>
> Pinning 0-3 is a measured no-op, not an assumed one — `pal-sd-25.mov` at all
> four profiles gives identical `framemd5` with and without the flag, because
> `yuv422p10le` is the only 4:2:2 format the encoder has.
>
> **The decoder reports ProRes 4444 as 12-bit** (`yuv444p12le`) whatever 10-bit
> format the encoder was handed, so assert on the chroma part of the name. And
> `prores_ks` offers no 12-bit pixel format at all: **4444 XQ is 10-bit here**,
> whatever Apple's spec says. Don't write "12-bit" in any UI copy.

> **ProRes was showing a CRF slider wired to nothing.** It is not `isLossless`,
> so the dialog rendered one labelled "High (CRF 18)" while
> `build_encoder_quality_args` took the `prores_profile()` branch and never read
> `settings.quality`. The decision is now `VideoCodec.hasQualityControl`, a
> getter rather than a widget condition, so it can be asserted across
> `VideoCodec.values` — a hand-written list only covers the codecs someone
> thought of, which is never the broken one.

> **`prores_profile()` and `encoder_family()` lost their catch-all arms.** They
> dispatch two halves of one decision — the quality-args branch uses the first,
> its fallthrough the second — so a ProRes variant reaching the family but not
> the profile table would emit no `-profile:v` and encode as profile 2 while
> claiming otherwise. Adding the two new variants then produced four compile
> errors naming exactly the sites that mattered, which is the point.

> **`proresCodecs` in `settings_dialog.dart` was the only place the ProRes UI
> group was enumerated.** A profile missing from it exists in the model and is
> unreachable on screen, silently. Derived from `isProRes` now.

The three advanced options (`-vendor apl0`, `-bits_per_mb`, `-quant_mat`) are
behind advanced mode, ProRes-only, default off. Their copy carries measurements
rather than the linked guide's framing, because **at profile 3 the guide's four
flags produce bit-identical frames** — `quant_mat auto` already resolves to the
HQ matrix and the bitrate is already under the cap. They only do anything on
Proxy/LT (+3.6 dB for 2.8% size, +5.5 dB for 19%), and `-vendor apl0` is a
compatibility flag: four bytes per frame header, identical pixels.

`bits_per_mb` is clamped to 8192 **in the worker**, not just the UI — ffmpeg
rejects anything above it and the encode dies having written nothing, so a saved
preset can otherwise fail a job on an option nobody can see. `quant_mat` is an
enum on both sides for the same reason ("Undefined constant" kills the encode).

> **`copyWith` needed explicit clear flags, and `parameter_copy_with_test` could
> not have caught it.** That test globs `lib/models/*_parameters.dart`, so it had
> never seen `encoding_settings.dart` — now added, and confirmed live by dropping
> a field and watching it fail by name. The blast radius here is worse than in a
> pass model: **every** edit in the settings dialog goes through
> `updateEncodingSettings(settings.copyWith(...))`, so a forgotten field resets on
> the user's next click, not on a pass toggle. `x ?? this.x` can only set a
> nullable field, never clear it, so an unticked override would stick forever —
> `videoBitrateKbps` still has that defect and works around it in
> `_buildCodecRadio`.

`proresChromaPinWarning` is a **sibling** of `hardwareEncoderChromaWarning`, not
an extension. The two make opposite claims — one says the hardware cannot encode
what you asked and something is lost; the other says the profile defines what is
stored, and 4444 pads 4:2:0 *up*, costing size rather than detail. The message
says "Nothing is lost" explicitly, asserted, because a warning that reads as a
quality problem pushes people off a profile doing exactly what they asked. Both
are second implementations of the worker's decision and both are pinned
case-for-case to it. Depth is deliberately not warned about alone: ProRes is
always 10-bit, so that would fire on most ProRes jobs and become wallpaper.
---

### Testing a deps change before publishing

A PR that changes `deps/` has a chicken-and-egg problem: `ci-test.yml` and
`nightly.yml` download the bundle named by `app/assets/deps-version.json`, so a
deps change could not be tested until it was published — and publishing an
untested bundle is what you were trying to avoid.

There are two ways out, and **the artifact one is now the default answer**
because nothing about it is public.

#### 1. `deps_run_id` — test an unpublished bundle (preferred)

Both `ci-test.yml` and `nightly.yml` take an optional `deps_run_id`
`workflow_dispatch` input. Set it, and `.github/scripts/fetch-deps-bundle.sh`
pulls the zip from that `build-deps-*` **workflow run's artifact** instead of
from a release. No tag, no release, nothing publicly visible, and nothing to
clean up — artifacts expire on their own.

```bash
# 1. Build the bundles. release_tag may be empty (artifact only) or name a
#    draft release to stage the assets in — the artifact is uploaded either way.
gh workflow run build-deps-macos.yml   -f version=1.9.0 -f arch=both
gh workflow run build-deps-windows.yml -f version=1.9.0
gh workflow run build-deps-linux.yml   -f version=1.9.0 -f arch=both

# 2. Point a CI run at all three runs at once. Must be workflow_dispatch — a
#    push/PR trigger cannot carry an input, so it always takes the release path.
gh workflow run ci-test.yml --ref <branch> \
  -f deps_run_id="<macos-run>,<windows-run>,<linux-run>"
```

Three things to know:

- **It needs `actions: read`**, which the repo's *restricted* default workflow
  token (`contents` + `packages` read, everything else none) does **not** grant.
  Both workflows therefore declare an explicit read-only `permissions:` block.
  Don't "simplify" it away — the failure is a 404 on the artifact fetch.
- **`deps_run_id` is a list, and has to be.** One CI dispatch runs all four
  platform jobs, but macOS, Windows and Linux are three separate `build-deps-*`
  workflows and therefore three separate run IDs (macOS produces both arches in
  one run). Each job tries every ID and takes the first holding an artifact for
  *its* platform, so order doesn't matter and a partial list is fine — the jobs
  whose platform is missing fail with `no <platform> deps artifact in any of:`
  rather than silently testing the wrong thing.
- **The version isn't cross-checked** against `deps-version.json`, deliberately —
  the bundle under test is unreleased and may carry a throwaway version. The
  script logs a `::warning::` naming the run, so a green tick can't be mistaken
  for a run against the released bundle.

> **Draft releases were the obvious idea and are the wrong one.** Not for the
> reason this section used to give — CI *does* authenticate (`gh release
> download` with `GH_TOKEN`), so the old claim that "neither CI nor the app can
> fetch them" was only ever true of the app. The real blocker is narrower: draft
> assets need **push** access, and the default token is read-only, so it would
> take widening the token to `contents: write` on a workflow that runs against
> pull requests. The artifact route gets the same privacy for a read-only scope.

#### 2. Release-candidate prereleases — when the download path itself is the thing under test

A prerelease is publicly downloadable at the ordinary
`releases/download/<tag>/<asset>` URL, and every consumer here is tag-driven —
`getDownloadUrl()` builds the URL from `releaseTag`, and nothing in the repo uses
`/releases/latest`. So a prerelease is indistinguishable from a stable release to
CI, the nightly suite *and* a real app build. That last one is what `deps_run_id`
can't do: an installed app has no token and cannot read artifacts, so **testing
the actual first-run download flow still needs an rc**.

The workflow:

1. `gh release create deps-vX.Y.Z-rc1 --prerelease` on the PR branch.
2. Run the three `build-deps-*` workflows with `version: X.Y.Z-rc1` and
   `release_tag: deps-vX.Y.Z-rc1`. They upload the zip and its `.sha256.json`
   sidecar. (They also always upload a workflow artifact, so `release_tag` can
   be left empty for a build-only run.)
3. Point `deps-version.json` at the rc **on the PR branch only**.
4. Iterate — rc bundles are disposable, because the rule about never reusing a
   deps version only binds once a *released app* references one.
5. Before merge, publish the final `deps-vX.Y.Z` and repoint.

`Scripts/release.sh` refuses to cut an app release while `deps-version.json`
names an `-rc` tag. That is the one way this bites: an rc escaping into a shipped
build, where later deleting the prerelease breaks the download for everyone who
installed it.

