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
>
> **2026-11-08: one now does.** Audio Restoration's sync offset and drift
> correction move audio in time. It renders the output's soundtrack before the
> encode, and transcription reads that rendered track instead of the source
> window, so cues follow the retiming by construction (see "Audio restoration"
> below). The rule that survives: transcription hears exactly the output's
> audio, and anything that moves audio lives in `audio_restoration`.

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

### The v2 tier became a delta, and the AppImage started carrying its deps (2026-10-09, deps 1.13.0)

**What prompted it.** The AppImage catalog (appimage.github.io) picked up the
1.2.0 AppImage on its own and its test failed
([PR #9839](https://github.com/AppImage/appimage.github.io/pull/9839)). The
catalog launches each AppImage under `firejail --net=none`, screenshots it and
OCRs the screenshot for error text. VapourBox started fine, tried to download
its deps, failed DNS, and showed "Installation Failed" — which the OCR read.
Two warnings rode along: "linux" in the file name, and no AppStream metadata.

**Why not just bundle the two existing zips.** The linux-x64 bundle is 236 MB
and so was its v2 twin; an AppImage that works on any x64 CPU would have
carried both, ~470 MB, for a difference that on Linux is one file. The tiers
were already required to list identical plugins
(`deps-expected-plugins.json`), and the tier blocks in `download-deps-*` only
touch zsmooth (and MVTools on macOS), so v2 as "v3 plus a few files" was
already true; only the packaging said otherwise.

**The delta is declared, not diffed.** The first idea was to build both tiers
and publish whatever differs. That fails on contact: two builds of the same
sources on two runners are not byte-identical, so the diff is most of the
bundle. `_tierFiles` names the files instead, and `make-deps-delta.py` checks
the two things a diff would have told us that still matter — the builds hold
the same set of paths (so overwriting is enough), and each tier file really
does differ (so the tier switch did something).

**What is unverified as of writing.** Everything Linux- and Windows-side was
written on macOS: the `delta-x64` jobs, `install-deps-bundle.sh`, the bundling
and validation in `package-linux.sh`, and the bridge `.zsync`. In particular:

- that the composed macOS v2 tree runs — v2 MVTools is built against the v2
  build's own tree, and is now dropped onto the v3 bundle's `libfftw3f`;
- that `appstreamcli` on ubuntu-22.04 (0.15) accepts the appdata file;
- that AppImageUpdate, started from a 1.2.0 AppImage, follows the old-name
  `.zsync` to the renamed file. zsync's `URL:` header is relative, so it should;
  it has not been run.

The first `build-deps-*` and `build-linux.yml` runs are the test of the first
two. The third needs a Linux machine and a 1.2.0 AppImage.

### x86 bundles split into CPU tiers (issue #92, 2026-09-25)

**The report.** A Mac Pro 5,1 (Xeon X5690, Westmere — SSE4.2, no AVX at all)
failed every preview at once with `vspipe exited with signal 4` (SIGILL), even
with every pass disabled. The reporter's `.ips` put the fault in
`__GLOBAL__sub_I_MVDegrains_AVX2.cpp` inside `libmvtools.dylib`, called from
`dlopen` ← `VSCore::loadAllPluginsInPath` ← `createCore`.

**Why every job.** Stefan-Olt's macOS MVTools compiles six files with
`-mavx2`. Three of them (`MVDegrains_AVX2`, `Overlap_AVX2`, `SADFunctions_AVX2`)
build a `static const std::unordered_map` of kernels at load time, and the
compiler used VEX instructions for it. Static initializers run inside `dlopen`,
before any plugin code can check the CPU, and R78 autoloads every plugin when a
core is created — so one plugin faulting at load kills every job, whatever it
asks for. Runtime dispatch in the filters is irrelevant; they never get to run.

**How it was pinned down, and the traps on the way.**
- A disassembly scan of initializers *by name* (`_GLOBAL__sub_I_*`) came back
  clean on the Linux bundle only because GCC's LTO renames them
  (`__static_initialization_and_destruction_0v.lto_priv.N`). Name-based scans
  are not evidence. `Scripts/check-load-time-simd.py` finds initializers from
  `__init_offsets` / `__mod_init_func` instead, follows direct calls (never
  into `__stubs`), and flags the stock 1.10.0 MVTools and nothing else in the
  bundle.
- The first real-hardware probe reported all 18 prebuilt plugins as crashing,
  because each test autoloaded the whole directory, MVTools included.
  `Scripts/probe-plugin-compat.py` loads one plugin per process into a
  `CoreCreationFlags.DISABLE_AUTO_LOADING` core instead.
- Rosetta 2 translates AVX/AVX2 on macOS 15+ (not AVX-512), so the crashing
  MVTools ran perfectly on Apple Silicon. Nothing about pre-AVX2 behaviour can
  be learned there.
- The reporter's Ivy Bridge MacBook (AVX, no AVX2) loaded everything: the
  initializer VEX is plain AVX, so it is the *pre-AVX* machines that fail.
  (macOS spells the feature `AVX1.0` in `machdep.cpu.features`.)

**Surveyed under Intel SDE** (`probe-cpu-compat.yml`), with three controls: the
runner itself must pass everything; a plugin-free core must pass under SDE; and
upstream's AVX2-only zsmooth must crash *in its own image*.
- **Linux at Westmere:** every plugin in the 1.10.0 bundle renders, MVTools
  included (GCC's build keeps VEX out of that load path), except the zsmooth
  haswell build — which the worker never loaded there anyway.
- **Windows at Westmere is unmeasurable:** every test, including the core
  control, faults in `VCRUNTIME140.dll`'s `memcpy` on a `vmovdqu ymm`. Microsoft's
  runtime takes its AVX path from what the *host kernel* reports
  (`IsProcessorFeaturePresent` reads shared kernel memory), which SDE cannot
  virtualise, and python.org's runtime runs fine on real pre-AVX Windows. Without
  the core control this run looked valid, because the positive control also
  "crashed" — in vcruntime. **Windows at Sandy Bridge** (AVX, no AVX2) is valid,
  and there everything but zsmooth-haswell renders.
- `sde.exe` drops empty arguments when relaunching the child, which once made a
  probe bug look like a CPU finding.

**The design.** Rather than more per-plugin special cases (zsmooth's two
builds loaded by path was the first), each x86 platform ships two bundles:
`v3` (x86-64-v3; the pre-existing asset names) and `v2` (`-v2`). One gateway
chooses — the app downloads by `vapourbox-worker --probe-cpu`'s `tier`, and the
tier lives only in the asset name and `version.json`, never the install path,
so the worker, dev paths and tests are untouched. v3 needs the whole
x86-64-v3 feature set (a v3 build may use FMA/BMI2/MOVBE as well as AVX2).
Startup re-checks the tier, so an install that moved machines is replaced.

What actually differs between the tiers is only what the measurements above
proved must: zsmooth's baseline on all three platforms, and on macOS MVTools.
The v2 MVTools is v24 from source with `patches/mvtools-v24-no-avx2.patch`:

- It replaces the six AVX2 files with stubs compiled at the baseline. With no
  `-mavx2` code in the binary, neither the initializer VEX nor the other
  hazard remains: an `-mavx2` file's copy of shared template code can win the
  linker's choice and put AVX2 into unguarded callers.
- It masks `X264_CPU_AVX2` out of `g_cpuinfo`, the single point where the CPU
  flags are set. Every call into the AVX2 code is gated on that flag.
- The stubs `abort()` rather than return nothing. They are unreachable, and a
  silent no-op would render blank frames on an AVX2 machine running the v2
  bundle if the mask were ever lost.
- Every AVX2 selector call site null-checks (`if (tmp) degrain = tmp;`).
- The nasm assembly stays, and is still runtime-dispatched.
- The patched binary has no compiler-generated VEX outside the asm kernels.

**Gates.** A v2 bundle cannot be published without passing: SDE in
`build-deps-{linux,windows}.yml` (the upload job waits for it), the static
check inside `package-deps-macos.sh`. `release.sh` stopped packaging deps
locally — a checkout holds one tier per platform, so it would have published
half a release.

**Open.** Pre-AVX *Windows* remains unverified (no SDE run is possible, and
`check-load-time-simd.py` reads Mach-O only). MVTools' Windows build is the
official MSVC v24 — if it turns out to have the same initializer problem, the
Windows v2 tier would need an MVTools source build, which the Windows deps
script has no toolchain for today.

### Colour tags on the output only re-matrixed every pixel (2026-09-26)

The colour-metadata fix (read the tags with ffprobe, carry them on `VideoJob`,
re-stamp them on the encode) put them on the encoder as **output-stream flags**
only, with a comment calling it "a *metadata* fix, not a pixel one". With the
bundled FFmpeg 9.0.1 it was a pixel change on every encode from a tagged
source.

**Reproduction** (flat 64x64 `yuv422p10le` frame, Y/U/V = 565/236/756, into
FFV1 and decoded back):

| encoder args | decoded Y/U/V | written tags |
|---|---|---|
| none | 565/236/756 | range tv only |
| output `-colorspace bt709 -color_range tv` | **546/259/741** | bt709/tv |
| output `-colorspace bt709` alone | **546/259/741** | bt709 |
| output `-color_range tv` alone | 565/236/756 | tv |
| output, all four flags | **546/259/741** | bt709/tv; primaries/trc **unknown** |
| same four flags on the **input** (before `-i`) *and* the output | 565/236/756 | all four |
| `-vf setparams=…` (all four) | 565/236/756 | all four |

`rawvideo` and `yuv4mpegpipe` inputs behave identically. The output-only shift
reproduced with ProRes 4444 (with its `-pix_fmt` pin) as well as FFV1, and the
input-side declaration matched the untagged encode exactly with x264, ProRes
4444, HuffYUV (`-pix_fmt yuv422p`, 8-bit) and hevc_videotoolbox. End to end
through the worker on `Tests/TestResources/pal-sd-25.mov` (bt709/tv ProRes)
into FFV1, the tagged encode's frame averages moved from (Y 382.7, U 529.9,
V 509.4) to (382.0, 530.1, 510.7) in 10-bit units, and the encode read back
through its own tags differed from the preview of the same frame by a mean
6.1/255 per RGB sample.

**Root cause.** FFmpeg negotiates the colour matrix and range through the
filter graph the same way it negotiates the pixel format. The Y4M pipe carries
no colour information, so the input is `csp:unknown range:unknown`; the
output flags make the encoder demand `csp:bt709 range:tv`; so the graph
auto-inserts a scaler to get from one to the other (`-v debug`:
`auto_scale_0 … fmt:yuv422p10le csp:unknown range:unknown -> … csp:bt709
range:tv`, followed by swscale's `YUV color matrix differs for YUV->YUV, using
intermediate RGB to convert`). swscale treats "unknown" as BT.601, so it
converts 601→709 — a genuine re-matrix of samples that were already 709. An
explicit range alone caused nothing because unknown range defaults to limited,
which matched.

A second, quieter defect fell out of the same measurements: output-only
`-color_primaries` and `-color_trc` **never reached the file at all**. Those two
are not negotiated; the encoder copies them from the frames, which were
untagged, overriding the option. So the "re-stamp all four tags" fix had only
ever re-stamped two.

**The fix** declares the tags on the pipe's input (`ColorMetadata::to_ffmpeg_input_args`,
between `-f yuv4mpegpipe` and `-i -`) as well as on the output
(`to_ffmpeg_output_args`). Both are the same list by construction. With the
input declared as what it already is, input and output agree, there is nothing
for the scaler to convert, and the frames carry primaries/transfer to the
encoder. Every value `ColorMetadata` accepts (13 matrices, 12 primaries, 16
transfers, the six range spellings) was checked on both sides against the
bundled binary: all pixel-identical.

Why input options rather than `setparams` in the `-vf` chain, which also works:

- **A Custom FFmpeg Argument containing `-vf` replaces the whole chain** (the
  last `-vf` wins), which would silently drop a `setparams` and bring the shift
  back for exactly the users who customise. Input options are untouched by it.
- The tags are true of the frames from the moment they are decoded, so every
  filter in the chain (burnt-in subtitles, anything a user adds) sees the right
  matrix, not just the encoder.
- The `-vf` chain stays empty for a job with no aspect/subtitle work, rather
  than every tagged job gaining a filter.

The output flags are **kept**, not replaced: declared only on the input, a
full-range source came out converted to limited (548/271/726 for the test
frame) — nothing pinned the output range, and ffmpeg negotiated `tv`. Both
sides together are what is pixel-exact.

Consequences worth knowing:

- A Custom FFmpeg Argument like `-colorspace smpte170m` still works and still
  converts — but now from the source's *real* matrix, which is what such an
  argument means. Before, it converted from an assumed 601.
- A forced `-pix_fmt` (HuffYUV, AMF `nv12`, the #74 hardware pins, ProRes
  profile pins) still inserts a scaler, which now only resamples chroma/depth
  and does not re-matrix. The ProRes 4444 case is asserted bit-identical
  tagged-vs-untagged.
- The preview path needed no change: it already feeds the source's matrix and
  range to swscale explicitly (`swscale_input_opts`), which is why the preview
  showed the correct colours while the encode did not.

**Tests.** Rust: `input_and_output_declarations_always_agree` and
`input_declaration_carries_every_tag` (color_metadata.rs);
`test_color_tags_are_declared_on_the_y4m_input_too` (position-checked against
the `-f`/`-i` pair) and `test_real_ffmpeg_builder_declares_colour_on_the_pipe_input`,
which reads `build_ffmpeg_args`' own source — the args-level tests otherwise
only see `build_ffmpeg_args_for_test`'s copy. Flutter (heavy):
`integration_colour_tag_pixels_test.dart` encodes the tagged fixture with and
without tags and asserts the samples are bit-identical to each other and to
the source (FFV1), bit-identical tagged-vs-untagged for ProRes 4444, all four
tags present, and the encode matches the preview (mean diff 0.000/255). With
the input declaration disabled it fails all three, as the Rust tests do.

The existing "tags survive" test in `integration_chroma_subsampling_test.dart`
passed throughout — it checked the label, not the picture. **A metadata change
needs a pixel assertion too**, because FFmpeg decides for itself whether a
label is a label.

### zsmooth ships once per CPU baseline, and is loaded by path (issue #82, 2026-08-28) — superseded by the CPU tiers above

Since deps 1.11.0 each tier's bundle carries exactly one zsmooth build, in the
autoload directory; the two-builds-loaded-by-path mechanism below was removed.
The measurements still hold and are why v2 uses `x86_64_v2` rather than
`x86_64`.

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
- **Sharpen runs after Crop/Resize and before Grain** (added 2026-10-05, issue
  #109 — it used to sit straight after Anti-Aliasing, ahead of Chroma Fixes,
  Colour Correction, Stabilize and the resize). Resampling a sharpened picture
  softens it again on a downscale and enlarges the sharpening halos on an
  upscale, and Stabilize's sub-pixel shifts soften it too. Consequences worth
  knowing: Sharpen now works at the **output** resolution, so it costs more
  when upscaling and less when downscaling, and existing presets and saved
  jobs that combine Sharpen with a resize render slightly differently than
  before. The same issue also removed a `pass_advice.dart` warning that claimed
  Sharpen ran *before* Noise Reduction — it never did.
- **Stabilize runs last before Crop/Resize.** It shifts the picture within the
  frame and exposes thin empty edges, so a crop afterwards removes them.
  **This was not true until 2026-10-05 (issue #109).** The *resize* ran after
  Stabilize, but the crop was a separate `PRE_CROP` block at the top of both
  templates, ahead of Deinterlace — so the reason given for the placement
  described something the pipeline did not do, in this file, the README, the
  model comments and `pass_list_stages_test.dart` alike. The crop is now a
  `CROP` block directly before `RESIZE`, after Stabilize and Rotate / Flip.
  What that costs, deliberately: every earlier pass works on the uncropped
  frame (slower, by the cropped area), Edge Repair rebuilds the edge of the
  *uncropped* frame, and the automatic measurements (levels, white balance,
  chroma alignment) see whatever the crop was going to remove — head-switching
  noise along the bottom of a VHS capture included. Crop values now refer to
  the picture *after* a rotation, where they used to refer to the source.
  `test_110` pins the script order; `integration_new_passes_test.dart` tells
  the two orders apart by frame size on a rotated, cropped encode.

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

akarin is **LGPL-3.0** and statically links **LLVM 22.1.8** (Apache-2.0 with LLVM
exception); both are in `licenses/NOTICES.txt`. It adds ~61 MB uncompressed per
platform, but only about **21 MB to each deps zip** — the earlier "the zips
roughly double" estimate was wrong, because it compared uncompressed size against
compressed zips.


### akarin 1.4.1 segfaulted under SELinux (issue #101, 2026-10-04)

Every job crashed in `vspipe-bin` with `SIGSEGV` on Fedora from app 0.9.12 — the
first release on deps 1.8.0, which is where akarin arrived. The reporter's
`probe-plugin-compat` run isolated it: 22 plugins passed, `libakarin.so` crashed.

The 1.4.1 Linux wheel was built without `REACTOR_ANONYMOUS_MMAP_NAME`, so
`expr2/reactor/ExecutableMemory.cpp` took its generic fallback: allocate the JIT
buffer with `new[]`, then `mprotect` it `r-x`. A page-sized allocation comes off
the **`brk` heap**, and SELinux refuses `PROT_EXEC` there (`execheap`, off by
default for unconfined users on Fedora/RHEL — unlike `execmem`, which is on).
The `mprotect` result is checked only by an `ASSERT`, compiled out in release,
so the plugin jumped into non-executable memory. Upstream: akarin issue #38,
fixed in **1.5.0** by defining the macro (`meson.build`), which switches to an
anonymous `mmap`. macOS (`MAP_JIT`) and Windows (`VirtualProtect`) never took
the heap path.

Signatures worth recognising next time:

- **A one-frame backtrace at `0x55…` with no module.** That range is the PIE
  executable and its `brk` heap; a JIT that used `mmap` would be at `0x7f…`.
  A crash *at* a heap address means the program counter is in data.
- **It depends on allocator state**, so it need not reproduce in every host
  process: a buffer over glibc's mmap threshold comes from `mmap` and works.
- **No hosted runner enforces SELinux** (Ubuntu ships AppArmor), so CI cannot
  see it. `download-deps-linux.sh` instead fails the build if `libakarin.so`
  lacks the `akarin_jit` mapping name, the only trace the option leaves.

The pin moved on all three platforms together to keep output identical per OS;
the Expr parity test passes unchanged against 1.5.0 (run on macos-arm64). 1.5.0
also repaired constant parsing (`0x…` hex and `0…` octal prefixes, which the
README always documented but 1.4.1's `from_chars` call mishandled) — none of
havsfunc's generated expressions are affected.

Workaround for an installed bundle that predates the fix: delete
`deps/linux-*/vapoursynth/plugins/libakarin.so`. Both the havsfunc shim and the
templates' `_expr()` fall back to `std.Expr`, which on x86 has its own JIT.


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

**2026-11-14: macOS x64 had not been on r31.** Through deps 1.16.0 the x64
branch of `download-deps-macos.sh` took Stefan-Olt's prebuilt
`fmtconv-git-18a9cecb` (2024-08-02: 34 commits after r30, 18 before r31). It
has the AVX2 14→16-bit fix but not r31's chroma-placement fix (`3079bd6`), and
nothing checked the version. The skew was latent: on 62 cases through the
published x64 bundle (havsfunc Bob/Resize/MinBlur, bitdepth, mvsfunc Depth,
QTGMC Draft and Placebo), both builds were bit-identical. Only the paths r31
changed differ (`cplace="dv"` on interlaced 4:2:0, 4:4:0, 4:1:0), and
VapourBox reaches none of them: nothing passes `cplace`, and the decoder turns
4:4:0/4:1:0 into 4:2:2. QTGMC Placebo first looked different; it varies from
run to run with several threads and is bit-identical on one. r31 now builds
from source on both macOS arches (same tag and patch; on x86 the patch is dead
code). The x86_64 build targets 12.0 and has no static initializers, so the
v2 gate passes and fmtconv needs no `_tierFiles` entry. The push gate's
`fmtconv version pin` test checks r31's behaviour on every platform: a U = V
ramp resampled with `cplace="dv"` gives U−V = −606 on r31, +606 before. It
skips on a macOS x64 bundle at 1.16.0 or older. Not compared: the SSE2 path,
real footage. See
[docs/reports/2026-11-fmtconv-macos-x64-r31](reports/2026-11-fmtconv-macos-x64-r31/index.html).


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

### The 1 GB frame cache cap (issue #107, 2026-10-05)

Both templates set `core.max_cache_size = 1024` from 2026-01-18, on the premise
that VapourSynth "defaults to minimal caching". It does not: the bundled R78
reports 8192 MB on a 16 GB Mac, so the line cut the cache to an eighth. A user
deinterlacing a 107-minute HD AVI saw ~1 fps and a log full of `memory usage
still over the limit, flushing pipeline`; overriding the value through Custom
VapourSynth took them to ~14 fps.

Measured with bare `haf.QTGMC` on a synthetic interlaced 4:2:2 source under the
bundled vspipe (macos-arm64, 8 threads, deps 1.11.0):

| Source | Preset | Cache (MB) | fps | Peak RSS |
|---|---|---|---|---|
| 1920x1080 | Slower | 1024 | 6.5 | 1.7 GB |
| 1920x1080 | Slower | 2048 | 17.2 | 2.5 GB |
| 1920x1080 | Slower | 4096 | 17.2 | 2.7 GB |
| 1920x1080 | Slower | default (8192) | 18.0 | 2.8 GB |
| 1920x1080 | Very Slow | 1024 | 1.9 | 2.2 GB |
| 1920x1080 | Very Slow | default (8192) | 14.7 | 3.8 GB |
| 720x576 | Slower | 1024 | 92.8 | 0.7 GB |
| 720x576 | Slower | default (8192) | 89.5 | 0.7 GB |

CPU time was the same with and without the cap (119 s vs 123 s for 1080 Slower)
while wall time went from 47 s to 17 s — threads waiting on evicted frames, not
extra work. SD never reaches 1 GB, which is why no test noticed. The limit is a
ceiling, not an allocation: peak memory stayed well under it.

The templates now leave the cache alone, and the user can set a limit in
Settings → Output. Not measured: the default VapourSynth picks on Windows and
Linux, or on an 8 GB machine.

### CLAHE local contrast via vszip (issue #90, 2026-10-17)

Issue #90 asked for NightLift, a Flask/OpenCV still-image app whose "Auto" mode
picks one of four darkness levels from mean luma and dark-pixel ratio and runs
a fixed chain per level. Everything in that chain already existed in Color
Correction (grey-world white balance, auto levels, gamma, MSRCP) except CLAHE,
so CLAHE is what shipped: `vszip.CLAHE` from dnjulek/vapoursynth-zip 22.1.0,
as an option in Color Correction, plus the Low-Light Phone / Camera Video
preset. No NightLift code is used — its upstream has no LICENSE file, and the
fork's MIT LICENSE names a holder the fork's author supplied.

Probed against deps macos-arm64 (native) and macos-x64 (Rosetta) before wiring:

- **No `planes` argument; every plane is equalized.** On a flat-chroma test
  card the U and V planes moved by 2 levels. The template runs it on luma only.
- **8 and 16-bit integer only**; 10/12-bit and float raise.
- **`limit` is an int, and a float is truncated silently** — 2.9 produced output
  identical to 2. `limit=0` is near-passthrough. (This first shipped as an
  integer Strength slider, 1-10, default 2 — see "Strength is a blend" below.)
- **Defaults (`limit=7`, `tiles=3`) are aggressive**: mean luma 31.6 -> 89.4 on a
  dark test card. NightLift's 2/8 gave 31.6 -> 45.2; on `small_clip` darkened
  to 35%, 27.7 -> 43.2. Frame-mean jump stayed under 0.25 levels per frame, so
  no global flicker; per-pixel frame-to-frame change rose 1.7-2.5x, which is the
  contrast gain applied to motion and noise.
- Speed (arm64, 8 threads): ~1000 fps SD, 157 fps 1080p, 42 fps 2160p at 8-bit.

**The limit has to scale by the content's depth, not the container's.** vszip's
limit is a count per histogram bin (`limit * tile_pixels / 2^bits`, as OpenCV),
and a 16-bit histogram has 256 bins per 8-bit level. Content fills only the
bins its real depth reaches: 8-bit content moved to 16-bit uses every 256th,
genuine 10-bit every 64th. Mean |diff| of the 16-bit path against the 8-bit
path, in 8-bit levels, on real footage:

| Content | x1 | x64 | x256 |
|---|---|---|---|
| 8-bit (`small_clip`) | 14.45 | — | **1.29** |
| genuine 10-bit (ProRes fixture) | 3.66 | **1.40** | 2.92 |

On a dithered synthetic card the wrong factor was 9-78 levels off. The
container depth does not say which case applies — ProRes 4444 decodes as
12-bit whatever it holds — so the template measures, per frame, the coarsest
candidate depth (8/10/12) whose step every luma sample is a multiple of, and
uses `limit << (16 - content_depth)`. `std.Expr` has no bitwise, modulo or
rounding operators (checked on the bundle: `bitand`, `%`, `floor`, `trunc`,
`round` all fail to parse) and macOS x64 has no akarin, but both round when they
store an integer, so `x - round(x/step)*step` is two Expr steps. The nightly
parity case (`color_local_contrast`, 8-bit content in a 10-bit clip) measures
1.21 with this, and 9.85 with container-depth scaling — the test was run both
ways to prove it discriminates.

**Packaging: one baseline build, flat in the plugin directory, everywhere.**
The Linux and Windows wheels carry `vszip`, `vszip.avx2` and `vszip.zn4`
builds that VapourSynth R78 chooses between when it loads a plugin through a
`manifest.vs` (it takes `.avx2` only for the full x86-64-v3 set, like
`cpu::cpu_tier`). Only the baseline is shipped: it runs on every CPU, so one
file serves both tiers with no `_tierFiles` entry; the per-plugin probe and the
SDE gate list plugin files flat and would load an AVX-512 build by path and
fault; and the AVX-512 build would be chosen on machines no runner tests (the
CTMF lesson). The macOS x64 wheel is a single build with SSSE3 at most and no
load-time initializers.

**macOS x64 builds from the sdist, and Zig's x86_64 output cannot be signed
as-is.** The wheel is minos 13.0 against the 12.0 floor, so x64 cross-compiles
the 22.1.0 sdist with its pinned Zig 0.16.0 (0.17 rejects its `build.zig`)
for `x86_64-macos.12.0` — byte-identical to upstream's wheel when built for
upstream's own target, which is how the toolchain was confirmed. Ad-hoc signing
that output produced a dylib that segfaulted inside `LoadPlugin`, and
`--remove-signature` did not cure it. Cause: Zig signs only arm64 output, and
on x86_64 leaves **8 bytes** between the end of the load commands (1832) and
`__text` (1840). `codesign` must add a 16-byte `LC_CODE_SIGNATURE` and writes
it over the first 8 bytes of machine code without reporting anything;
`install_name_tool` refuses the same file ("larger updated load commands do not
fit"). The build is patched to set `headerpad_max_install_names` (1968 bytes of
room after signing; output hash unchanged against the wheel), and the vszip
block refuses to sign a Mach-O with no room for the signature.

**Strength is a blend over a fixed limit, not the limit (2026-10-18).** The
first version exposed the clip limit itself as Strength (1-10, default 2), and
everything but 1 looked extreme in use. Not a scaling bug — the 8-bit and
16-bit paths agreed within 2 levels — but the limit's own scale: it is a
multiple of the *average* bin, so whole steps are large. On a dark frame of
`small_clip` (mean luma 34, 8 tiles), mean absolute change was 12.1 levels at
limit 1, 22.2 at 2 (mean 34 -> 57), 29.3 at 3, 38.8 at 5, 52.9 at 10. Nothing
between 1 and 2 is reachable at 8-bit. Fractional limits exist only on the
16-bit path (1/256 steps), and below 1 they collapse: vszip floors the per-bin
cap to a whole pixel count, so on a 320x240 frame every limit up to 0.3 gave
the same output. So CLAHE runs at the conventional limit of 2 and Strength
(0-1, default 0.3; the low-light preset uses 0.5) is `std.Merge`'s weight
between the original luma and the result: linear, and the same at any frame
size or depth, including genuine 16-bit content where a fractional limit could
not exist. The depth scaling above is unchanged — it applies to the fixed
limit.

**Unresolved, found while diagnosing this:** the shipped macOS x64 zsmooth
(also Zig, also `install_name_tool` then `codesign`, both with errors
discarded) has the same layout. In the deps 1.10.0 bundle its load commands end
8 bytes *past* the start of `__text`, so the first 8 bytes of
`_fftwf_set_planner_hooks` are the signature's `dataoff`/`datasize` fields. It
works only because nothing calls that function.

### RIFE 4.26 as a Frame Rate method (2026-10-24)

Probed against deps 1.13.0 on macos-arm64 (M1 Pro) before wiring anything up.
The plugin is styler00dollar/VapourSynth-RIFE-ncnn-Vulkan `r9_mod_v33`
(ncnn on Vulkan; HolyWu's vs-rife needs PyTorch/CUDA and was never a
candidate). What the probe found, in the order it mattered:

- **Without Vulkan it segfaults, it does not raise.** Neither macOS dylib
  bundles a Vulkan implementation; both leave `vkGetInstanceProcAddr`
  undefined (dynamic lookup) and `rife.RIFE()` dies with SIGSEGV in
  `ncnn::create_gpu_instance`. `LoadPlugin` itself succeeds, so nothing at
  load time warns. Preloading MoltenVK 1.4.2 (`RTLD_GLOBAL`) fixes macOS; on
  Windows/Linux ncnn dlopens the driver's loader and raises "failed to create
  GPU instance" / "invalid GPU device" when there is no device. The vs-placebo
  note above is the same failure shape, which is why the method is gated on a
  probe rather than tried. The probe's crash path was exercised for real by
  swapping MoltenVK for an unrelated dylib: classified `noVulkan`.
- **The macOS x64 prebuilt is unusable**: minos 13.0 (floor 12.0) and
  `check-load-time-simd.py` fails it (VEX in `__GLOBAL__sub_I_gpu.cpp`).
  No linux-arm64 asset exists. The Windows DLL imports `VCOMP140.DLL`, which
  is not guaranteed present, so the probe tries it (and the other MSVC
  runtime DLLs) by name first and names the one missing.
- **The count is exactly `FrameMap::Retime`**: `floor(n * num / den)` of the
  reduced ratio, measured 40 → 80 / 47 / 38 for 25 → 50 / 29.97 / 23.976.
  Output frame n copies source `n*den/num` when exact; the last `num/den`
  frames are held copies. Fewer than 2 input frames raises.
- **RGBS only**, so real frames would take a YUV→RGB→YUV round trip; the
  template takes every copied frame from the source instead (`FrameEval`).
  Verified bit-exact on 8/10/16-bit YUV and Gray, for all three ratios.
- **`sc=True` works and matters**: across a hard cut the interpolated frame
  without it was a blend (88 / 73 levels from either side); with it, the
  previous frame exactly (0.00).
- **Speed (2x)**: 49 fps at 720x480, 14.7 fps at 1080p (4.26-large 12.9) —
  roughly 5x slower than FlowFPS.
- **Quality**, dropping every other frame of real footage and comparing the
  interpolated frame against the real one (MAE, 8-bit levels): `small_clip`
  RIFE 3.73 / FlowFPS 4.09 / duplicate 5.84 (worst frame 18.9 vs 21.1);
  `interlaced_test_processed` 2.23 / 2.43 / 7.12. 4.26-large was within noise
  of 4.26, so only 4.26 ships. **On synthetic noise-texture pans FlowFPS won
  by 10x** (0.04 vs 0.38, and with a crossing object too) — block matching is
  ideal for translated noise and RIFE was trained on natural video, so a
  synthetic fixture would have rejected the better method. Real footage only.

The model is the ncnn conversion committed to the plugin repo (commit
`96fdcec`, "add rife-v4.26", by TNTwise); hzwer publishes 4.26 only as
PyTorch weights on Google Drive/Baidu, so there is no official direct URL.
Licensing: weights MIT (hzwer, Practical-RIFE: "under the same MIT license"),
architecture MIT (Megvii, ECCV2022-RIFE), plugin MIT (HolyWu), ncnn BSD-3
(Tencent), MoltenVK Apache-2.0 (Brenwill Workshop, from source headers; no
NOTICE file upstream).

### BM3D and KNLMeans as Noise Reduction methods (2026-10-25)

Probed against the bundle on an M1 Pro (macOS arm64), BM3D r12 built with the
script's own `build_plugin`:

- **BM3D refuses 4:2:0 whenever chroma is processed** ("sub-sampled format is
  not supported when chroma is processed"); `sigma=[s,0,0]` works. Running
  each plane as a GRAY clip handles chroma at its own resolution, and costs
  nothing measurable: 52.5 fps whole-clip vs 53.0 per-plane at 720x480.
- **`VAggregate` always outputs 16-bit** (from 8-bit, 10-bit and even float
  input), and `VFinal` then fails with "input clip and clip "ref" must be of the
  same format" unless the input is 16-bit too. Hence the 16-bit working format.
- **sigma does not depend on depth**: 8-bit vs 16-bit results differ by
  0.30/255 (rounding), and the heavy parity test measures 0.36/255 at 10-bit.
- Throughput at 720x480, luma only, vspipe (frames in parallel):

  | radius | Basic | Basic + Final |
  |---|---|---|
  | 0 | 52.5 fps | 23.0 fps |
  | 1 | 34.0 fps | 14.3 fps |
  | 2 | 24.3 fps | 9.7 fps |

  Defaults are radius 1 with Final. Timing frames with sequential `get_frame`
  calls reads about 10x slower and is not a measure of anything.
- **KNLMeansCL's default `device_type="auto"` fails on this Mac** with
  `oclUtilsGetPlaformDeviceIDs: CL_INVALID_VALUE`; `"gpu"` works (140 fps luma,
  58 fps luma + chroma at 720x480), `"cpu"`/`"accelerator"` find no platform.
  The existing `knlm` probe (default device) correctly reports false here, and
  QTGMC's `knlmeanscl` denoiser has always fallen back to DFTTest on Apple
  Silicon as a result — it is havsfunc's call, so it was left alone. The new
  method probes `gpu` then `auto` and passes the one that works.
- Depth parity for KNLMeans: 0.137/255 at 10-bit, 0.009 at 16-bit, against
  2.74/255 of denoising.

Why BM3D was missing from four of five bundles: Linux's
`patch_meson_vs_include` only matched `incdir = include_directories(run_command(...))`,
and r12 writes the probe inside a list with `'include'`, so meson ran the host
python (no VapourSynth module) and failed at configure. macOS x64 never calls
`build_plugin` (its plugins come from Stefan-Olt's prebuilts, which has no
current BM3D), and the PyPI wheel for x86_64 is minos 15.0. Neither failure was
visible because no expected-plugins list named BM3D outside macOS arm64.

### AI upscaling: Real-ESRGAN / Real-CUGAN through VSNCNN (2026-10-25)

Runtime choice. Neither a maintained "RealESRGAN-ncnn" nor "RealCUGAN-ncnn"
VapourSynth plugin exists (Kiyamou's CUGAN plugin is Windows-only and last
released 2022); vs-mlrt's VSNCNN (GPL-3.0, active) runs any of its ONNX models
on ncnn/Vulkan, the same stack as RIFE. Only its Windows build is published,
so macOS arm64 and Linux x64 build it from the pinned tag: upstream's own
linux-ncnn.yml recipe on Linux; on macOS, Tencent's ncnn ships as static
frameworks with no CMake config, so the three sources are compiled directly
with `-undefined dynamic_lookup` (vkGetInstanceProcAddr from the preloaded
MoltenVK, exactly as for RIFE). It is an API 3 plugin; R78 still loads those.

Models and licences. AnimeJaNai was ruled out: CC BY-NC-SA 4.0. Real-ESRGAN
(BSD-3, Xintao Wang) and Real-CUGAN (MIT, bilibili) are fine. Every model is
2.4-5.2 MB, so they are bundled rather than fetched on demand; vs-mlrt
publishes them only inside one ~810 MB solid 7z per release, so each deps
build downloads it once (pinned by hash), extracts the five files in one pass
(separate extractions each re-decompress the solid archive) and checks each.

Measured on an M1 Pro, fp16 (fp32 is ~3x slower and within 0.06/255
(ESRGAN) / 0.30/255 (CUGAN) of it):

| | SD -> 2x | 1080p -> 2x |
|---|---|---|
| Real-ESRGAN animevideo x2 | ~10 fps | 1.6 fps (whole frame) |
| Real-CUGAN up2x | ~6 fps | out of GPU memory whole-frame; 0.67 fps in 512-px tiles |

num_streams 2 adds ~10%; 4 adds nothing. Without Vulkan (MoltenVK swapped for
an unrelated dylib) VSNCNN raises "get_gpu_device failed" rather than
segfaulting.

Pixel checks (heavy test), against a plain Spline36 upscale of the same frames:

- On real footage the comparison cannot prove correctness. On the interlaced
  VHS fixture without deinterlacing, both networks remove the combing (CUGAN
  smooths it, ESRGAN sharpens it into artefacts), a 9-12 level difference that
  survives downscaling back to source size because it IS source-resolution
  detail. small_clip has duplicate frames (a neighbour can score 0.0), so it
  cannot catch a wrong frame either. It is kept as a sanity bound only.
- A synthetic pattern can: mid-saturation flat patches (nothing clips, where
  the networks roll off by a few levels and a range error would hide) and a
  white bar. Real-CUGAN 2x reproduces flat colour within 1 level on every
  patch, which — the conversions being shared — proves the matrix and range.
  Real-ESRGAN tints/saturates flat colour: up to 3 levels at 2x and 11 at 4x
  (green 160 -> 171), in fp32 too, with vs-mlrt's own `RealESRGAN()` wrapper
  doing nothing more than this template; that is the model. CUGAN 4x drifts ~4.
- Geometry: the networks widen a hard edge (CUGAN 4x: bar 194.6 px wide vs
  192.05), so either edge alone looks shifted (CUGAN 4x left edge 1.65 px off)
  while the bar's centre is within 0.36 px for every model. The test checks the
  centre on both axes (0.75 px), and that Spline36 itself lands on factor x
  source (within 0.25 px), so the reference is known-good.

CI ran it for real on Linux and Windows until 2026-11-09 (see "GPU tests
leave CI" below): Mesa lavapipe (ncnn tags a CPU device as type 3 but does not
skip it) and `VAPOURBOX_EXPECT_VULKAN=1`, so an unavailable feature was a
failure there, not a skip. The first lavapipe probe
takes ~30 s (Windows: 30.4 s), past flutter_test's default timeout, and one
whole 720x576 Real-CUGAN frame took over five minutes, so the push gate crops
to 240x192 first.

**macOS arm64 cannot be given a device, and its GPU tests skip.** Four
attempts, 2026-10-25:

1. The runner's Metal GPU through MoltenVK: both probes SIGSEGV creating the
   instance. The runners are VMs.
2. Homebrew lavapipe via `DYLD_FALLBACK_LIBRARY_PATH`: never reached the
   plugins. SIP strips every `DYLD_*` variable when a protected binary runs,
   and the bundle's vspipe is a `/bin/bash` wrapper.
3. The loader in `~/lib`: dyld no longer searches `~/lib` or `/usr/local/lib`
   for a leaf-name `dlopen` (its own "tried:" list for ncnn's
   `dlopen("libvulkan.1.dylib")` stops at `/usr/lib`).
4. Preloading the loader in place of MoltenVK: it reached lavapipe, which then
   crashed compiling its first shader, in Homebrew's `libLLVM.23` at
   `llvm::PassBuilder::registerCGSCCAnalyses`. The cause: **the bundle's
   macOS `libakarin.dylib` statically links LLVM and exports ~47,000 of its
   symbols, 2,293 of them weak**, and dyld coalesces weak definitions across
   every image in the process, so lavapipe's LLVM 23 ran against akarin's
   LLVM 22 data. Linux's lavapipe passes with the same akarin, so this is
   macOS only.

No user is affected today (MoltenVK has no LLVM), but **any LLVM-based
component loaded into vspipe on macOS will hit the same thing** while akarin
is autoloaded. The fix, if one is ever needed, is an akarin build with LLVM's
symbols hidden (`-fvisibility=hidden`, or an exported-symbols list of just
`VapourSynthPluginInit2`). `.github/scripts/print-crash-reports.py`, run by
both workflows' macOS jobs on failure, is what turned "signal 11" into that
backtrace.

### Descale and native-resolution detection (2026-10-25)

Probed with descale r12 (wheel) on an M1 Pro. A float 720p image upscaled to
1080p with Catmull-Rom and descaled back: round-trip error 2.8e-8 at 720 vs
~2e-4 at every other height; at 720, Catmull-Rom 2.8e-8, Mitchell 1.9e-5,
bilinear 6.3e-5, Spline36 8.0e-5, Lanczos3 1.0e-4. A sequential 231-height
scan took 12 s; spliced into one clip and read with `frames()` the whole
1080p detection (4 kernels x 540 heights, then 12 kernels x 4 frames, plus
decoding) takes ~30 s.

What went wrong on the way, so it is not repeated:

- **One-sided neighbourhoods.** The first version picked H-1 (1079, 574) on
  everything: the round-trip error falls steadily toward the source height,
  and a window that only has neighbours below reads that slope as a dip.
- **A smooth fixture proves nothing.** testing on small_clip (240p) scaled to
  "native" 720p: after 8-bit FFV1 storage every height's misfit (~0.05 levels)
  is below rounding (~0.25), so no dip exists to find. testsrc2 at native 720p
  works.
- **Credits swamp a mean.** A dense one-pixel grid over 4% of the frame
  (misfit at every height) flattened the dip to ~0.9; capping each pixel's
  error at 2 levels before averaging restores it (0.48 at 4% coverage, 0.35 at
  2%, 0.14 with none).
- **Scan with every kernel family.** Bilinear + Catmull-Rom alone missed
  Lanczos- and spline-made masters entirely (dip 0.63 / 0.56); adding
  Lanczos 3 and Spline36 to the scan finds all four at 720. ffmpeg's `spline`
  is not Spline36; its master is detected as Spline64, the nearest family.
- **A drawgrid on a transparent layer draws nothing** (alpha is not written):
  the first "credits" fixture had no credits, and protected/unprotected came
  out identical. The heavy test now asserts the unprotected grid is destroyed.

Results on the fixtures: Catmull-Rom master -> 720 bicubic 0/0.5 (dip 0.14);
bilinear -> 720 bilinear (0.14); Lanczos -> 720 lanczos 3 (0.16); with 2%
credits -> 720 (0.35); the VHS capture -> not found (0.91). Encode with
protection: credits exact (0.0 levels), picture within 0.27 of the source;
without it the credits move 62.6 levels. 8- vs 10-bit parity 0.32.

### AnimeJaNai as an add-on, and one add-on system (2026-10-25)

**Why it is a download, not in the bundle.** AnimeJaNai's models are CC BY-NC-SA
4.0. VapourBox distributing them free is a non-commercial use, so shipping
them would be allowed. But the restriction binds every recipient: users doing
paid work (client restorations, monetised channels), and anyone who repackages
VapourBox (the GPL permits selling it). Bundling is lawful aggregation, but it
would make the deps bundle the one part of VapourBox that can't be passed on
freely, and nobody would see the terms. So: an opt-in download from upstream,
with the terms in front of the user at download time and whenever the method
is chosen.

**Source.** The only standalone download is release `3.0.0`'s
`2x_AnimeJaNai_HD_V3_ModelsOnly.zip` (24.7 MB). The V3.1 models upstream's
README mentions exist only inside the ~170 MB full player package. The zip's
entries are dated 2024-07-30, six months after the release, so the asset has
been replaced once; it is pinned by SHA-256 and each model by its own hash.

**Probe (M1 Pro, VSNCNN fp16).** All seven ONNX models load and run unchanged
(they are Real-ESRGAN Compact networks, the same kind as the bundled
Real-ESRGAN model).

- Speed at 2x: Compact 8–9 fps SD / 0.9 fps 1080p; UltraCompact 14–16 / 1.7;
  SuperUltraCompact 35–37 / 4.
- Colour on flat patches (direct, RGB): 0.1–0.5 levels, against Real-ESRGAN's
  3.7. Through the full YUV pipeline, AnimeJaNai is 0.3 levels off at 2x and
  0.5 at 4x, against Real-ESRGAN's 3 and 11.
- fp16 vs fp32: within 0.36/255.

**SD vs HD.** Upstream trained the HD models on 1080p anime and warns that they
don't always suit SD. So the script picks the SD model at or below 576 lines,
per doubling. The heavy test shows the size setting has no effect on an SD
picture (difference 0.000) and does change a 720p one (0.52).

**One add-on system.** Whisper had its own manager and dialogs. Both are now
`AddonInstaller`s behind `AddonService`, shown on Settings → Add-ons and in
the shared `AddonPrompt`. Requirements (a Whisper model needs the engine) are
installed first and removed with what needs them.

### Variable-frame-rate sources (issue #137, 2026-11-02)

**Report.** "Output video stuttering and lag after frame interpolation", no
source details. On `small_clip` (CFR) every Frame Rate method was clean:
uniform timestamps, rates right, interpolated frames at true midpoints
(half-step balance 0.85 FlowFPS / 0.91 RIFE, 1 = even).

**Cause.** A VFR source. The decoder wrote `rawvideo` with no `-fps_mode`, and
ffmpeg converts that to constant rate by repeating a frame into each gap. The
app's frame count was `nb_frames` (stored frames), so `-frames:v` then cut the
tail. A 10 s clip at 30 fps slowing to 20 for its second half (250 stored
frames) came out 8.34 s against 10.00 s of audio, with frozen frames in
24/60 output frames of every second of the slow half (12/60 in the first) after
FlowFPS to 59.94: interpolating a repeat gives a stall, then a jump.

**Fix.** The worker reads packet timestamps (only when the two ffprobe rates
differ), decodes with `-fps_mode passthrough`, and maps grid slots to stored
frames in the script, so gaps are known. With a synthesizing Frame Rate pass a
gap is `mv.FlowInter`-interpolated at its position; otherwise it repeats as
before. Same clip after: 9.98 s, frozen 4–6/60 per second (RIFE 4/60).

**Measurements.** Ground truth is a lossless pan (2 px/frame) with every third
frame dropped from frame 150. Gap slots against the dropped frame (RGB mean abs
diff): interpolated 1.2–1.7, repeating would be 3.4–4.6. Real slots match their
own frame (0.4–0.6) against neighbours 2.6–4.3, so there is no off-by-one, and
the preview of a gap matches the encode (0.44 vs 1.5 for neighbours). A CFR
source's decoded output is bit-identical to before (same video MD5).

**Not done.** The grid is the app's chosen rate, which prefers `r_frame_rate`.
A VFR file whose `r_frame_rate` is far above its real rate (some Android
recordings report 90 or 120 for ~30 fps) gets a dense grid: mostly gap slots,
repeated or interpolated, which is correct but slow. Choosing a better grid
needs the timestamps, which the app does not read.

### HDR sources and Dolby Vision (issue #133, 2026-11-02)

**Report.** Dolby Vision files (Profile 8.1 named) show pink and green in the
timeline and preview.

**What the profiles are, to every decoder but Dolby's.** ffmpeg decodes only
the base layer; the RPU (dynamic metadata) rides along as side data. Profile
8.1 / 7 have an HDR10 base layer, 8.4 HLG, 9 SDR. **Profile 5's** base layer
is IPTPQc2 (ffprobe: `color_space=ipt-c2`, `dv_bl_signal_compatibility_id=0`),
which only the RPU's reshaping turns into YCbCr — undone, it *is* pink and
green. A Profile 8.1 fixture (x265 + `dovi_tool generate`/`inject-rpu`, then a
re-encode with `-dolbyvision 1` so the MP4 gets a `dvcC`) showed no pink or
green at all: it showed **grey and washed out**, because every preview path
read PQ as SDR (green bar 112/143/84 instead of 23/177/7). So the reported 8.1
symptom is either a Profile 5 file or a description of the washed-out look;
the fix covers both as far as is possible.

**Profile 5 can't be fixed here.** The reshaping is in libplacebo
(`vf_libplacebo`, `apply_dolbyvision`) and vs-placebo. The macOS FFmpeg builds
(martin-riedl arm64, evermeet x64) have no libplacebo; BtbN's Windows/Linux
ones do, but the Y4M pipe drops the RPU anyway, so the pipeline would need the
reshape at decode time on every platform. Shown as a warning instead (status
bar badge, Video Info, job log).

**Display tone-map.** `zscale` + `tonemap` (Hable, `desat=0`, npl 100) exist in
all four FFmpeg builds. Two traps, both measured:

- On the preview's Y4M input (no tags) `zscale` fails with "code 3074: no path
  between colorspaces" even with `min/pin/tin/rin` given. Declaring the tags
  with `setparams` first works, and the same chain then serves the app's
  file-based decodes unchanged.
- zscale's RGB output keeps the source's YUV matrix tag (`bt2020nc`), so the
  app's JPEG encode converted RGB→YUV with BT.2020's matrix while the decoder
  reads JPEG as BT.601: the green bar came back 28/198/14 against the PNG's
  23/177/7 (up to 21 levels). Ending in `format=rgb24,setparams=colorspace=gbr`
  brings it to within 1 level. Preview vs before-frame after the fix: mean
  abs diff 0.28.

**The preview job never carried colour tags.** `PreviewGenerator` built its
`VideoJob` without `inputColor*`, so the worker's `swscale_input_opts` (the
2026-09-26 preview hue fix) only ever ran from tests. It now sends them, which
also gives SDR BT.709 sources the right preview matrix.

**HDR10 static metadata.** The pipe drops mastering display / MaxCLL with all
other side data, and ffmpeg has no CLI to attach it to frames, so the output
had the PQ tags but no ST 2086 / CLL SEI. libx265 takes them as
`master-display=…:max-cll=…`; the worker reads them with ffprobe (stream side
data first, else the first decoded frame — `%+#8` packets, since `%+#1` can
yield no frame through reorder delay) and passes them. x265 also turns on
`repeat-headers` for it. No other offered encoder takes them on the command
line; those outputs keep the tags only. The Dolby Vision RPU is not carried.

### A long source comment stopped ffmpeg starting on Windows (issue #138, 2026-11-02)

Reported on Windows: `Failed to start ffmpeg: … The filename or extension is
too long. (os error 206)`. The decoder and vspipe had started with the same
environment, so it was the encoder's arguments: `CreateProcess` refuses a
command line over 32,767 characters. The one argument whose length came from
the source was `-metadata comment=VapourBox X | <source comment>`. The source
was an AI-generated MP4, and tools such as ComfyUI store their whole workflow
JSON in that tag.

- The comment now goes to ffmpeg as an FFMETADATA file input
  (`-f ffmetadata -i <file>`, `-map_metadata:g <n>`), the same in the encode
  (input 2) and the subtitle mux. Checked against the bundled ffmpeg 9.0 with a
  100 KB comment holding `= ; # \` and a newline: it came back byte-identical.
- In the subtitle mux the source's other global tags are kept by mapping
  `-map_metadata:g 0` *after* the file. ffmpeg never overwrites a tag an earlier
  mapping copied, so the comment comes from the file and the rest (title, …)
  from the source.
- The probe used `-of csv=p=0`, which quoted the value and doubled each `"`
  inside, so a JSON comment came back altered and grew on every pass. It now
  uses `-of json`, whose escaping is exact. (`default=nw=1:nk=1`, tried first,
  passed on macOS/Linux and failed the Windows nightly: ffprobe's stdout is in
  text mode there, so each newline came back `\r\n`, and an unescaped `\r` ends
  an FFMETADATA line, cutting the comment at its first line break. The file
  now escapes `\r` as well.) A comment that already
  begins `VapourBox <version>` (re-processing an output, or the mux after an
  encode) keeps one prefix rather than gaining another.

The same Windows nightly failed NTSC DV 4:1:1 (`integration_source_formats_test`),
which turned out to be two things. The test claimed 25 fps for a DV file
(always stored at 29.97), and raw DV reports `avg_frame_rate` 60000/1, so
`source_timing` read the timestamps and placed 10 stored frames on 8 slots of a
25 fps grid; the test now takes `r_frame_rate` as the app does and checks the
frame count. vspipe then stopped reading early, and the decoder's write into the
closed pipe failed. That is SIGPIPE/EPIPE (141/224) on Linux/macOS, tolerated,
but on Windows it is EINVAL, exit -22, which was not:
`decoder_lost_its_reader` now recognises it by the decoder's own muxer error, since -22
is also what ffmpeg returns for a bad argument. IVTC jobs, whose VDecimate
always reads fewer frames than the decoder sends, could hit the same thing on
Windows whenever the decoder had not finished writing.

### RIFE's scene-change threshold and `skip`: measured, not exposed (issue #129, 2026-11-03)

#129 asked for less ghosting at scene transitions. RIFE r9_mod_v33 has two
options that look like the answer; both were measured on `small_clip.mp4`
(3154 frames, real film) on an M1 Pro before deciding.

- **Scene-change threshold.** Every boundary `misc.SCDetect` flags at the
  default 0.1 was checked by eye: 22 real cuts, 24 fast motion within one
  shot. Their difference values overlap completely (fight-scene motion
  reaches 0.226; most cuts are 0.11–0.17), so a threshold only moves the
  error: 0.15 catches 12 cuts and 10 motion frames, 0.2 catches 1 and 4.
  With every other frame dropped and re-made by RIFE, the default makes fast
  motion 11% worse than no detection (MAE 21.98 → 24.41 against the real
  frames) and is a wash at cuts (20.61 vs 20.80). That protocol can't show
  what detection is for — at a real 2x cut the made frame is a double
  exposure without it, a clean hold with it — so detection stays on at 0.1.
- **Motion-compensated detection** (`mv.SCDetection`, forward vectors set
  `_SceneChangePrev`, backward `_SceneChangeNext`) at its defaults caught 18
  of the 22 cuts and held 5 of the 24 motion frames, plus one other: 10
  mistakes to 24. The four cuts it missed are all between dark shots, where
  its fixed per-block threshold sees little difference. One black-and-white
  clip at 320x240 isn't enough to swap a double exposure at dark cuts for
  fewer holds in action, so it isn't used yet.
- **`skip`** needs the VMAF plugin ("VMAF plugin is required when
  skip=True"), which no bundle ships, and only triggers above PSNR 60 dB —
  pairs that are effectively identical. RIFE already returns such a pair
  unchanged (0.02–0.03 levels on five pairs), so it would only save time on
  duplicate-heavy material.
- In passing: ncnn reports a single queue on the M1 ("gpu_thread is
  recommended to be between 1 and 1"), which is why `gpu_thread` made no
  speed difference (15.3 / 14.7 / 15.1 fps at 1080p for default / 1 / 4).

### QTempGaussMC (vs-jetpack) as an alternate deinterlacer: investigated, not built (issue #117, 2026-11-03)

Full report with screenshots, charts and scripts:
[docs/reports/issue-117-qtempgaussmc/](reports/issue-117-qtempgaussmc/index.html).

vs-jetpack's QTGMC rewrite (`vsjetpack` 2.2.6, MIT) was run against the
macOS arm64 bundle, with the plugins it lacks loaded from PyPI wheels. Ground
truth: `small_clip.mp4` frames treated as 50 Hz fields, interlaced with
`interlace=scan=tff:lowpass=0`, deinterlaced at double rate, luma PSNR
against the originals.

- **Quality:** +0.5 / +0.8 dB over havsfunc Slower at equal speed, and
  +0.2 to +0.9 with sharpening off on both. Modest, and near-invisible side
  by side. PSNR rewards softness here: havsfunc Medium beats its own Placebo.
- **Speed:** its defaults run at 5.5 fps at 720x576 against havsfunc
  Slower's 84. It hard-codes `znedi3` (scalar on ARM, the same trap as
  havsfunc patch 6) and defaults to NNEDI3 `nns=4` (havsfunc Slower uses 1).
  With dubhater's `nnedi3` and `nns=1` it reaches 75 fps.
- **Deps:** needs mvutensils (`mvu`; **v9 only**, since v10 removed the
  `fields` argument that 2.2.6 still passes), resize2, and ~54 MB of Python
  packages. `akarin.Expr` is mandatory, so not on macOS x64.
- **`qtgmc_convert`** (the issue's suggestion) needs Python 3.13, and its
  author advises against it except for parity with havsfunc. Not viable.
- A bottom-edge streak looked like havsfunc's own (MVTools border) bug, but
  the tuned jetpack configuration has it too: it comes from the NNEDI3
  settings. Don't cite it as a reason to switch.

Recommendation, if built: an `advancedOnly` Deinterlace method with its own
small control set, tuned as above, vs-jetpack and mvutensils pinned
together. x86 speed and the v2 CPU tier are unmeasured.

### KNLMeansCL: 10-bit sources failed on Windows, results unreliable on macOS (issue #144, 2026-11-03)

Full report with scripts:
[docs/reports/issue-144-knlmeanscl/](reports/issue-144-knlmeanscl/index.html).

- **Windows** shipped Khanattila's v1.1.1 release zip (2018). Its VapourSynth
  filter accepts 10-bit only as packed YUV444P10/RGB30 with all channels
  together, and 9/12/14-bit not at all, so our `channels="Y"` / `"UV"` calls
  failed on every 10-bit 4:2:0/4:2:2 source ("only YUV444P10 and RGB30 are
  supported!"). QTGMC's `knlmeanscl` goes through havsfunc's wrapper, which
  makes the same calls. Never caught because no runner has OpenCL, and the
  10-bit check of 2026-10-25 ran on a Mac.
- **macOS** built Khanattila's unpinned master. Apple's `clEnqueueFillBuffer`
  doesn't complete unless an event is requested, so the max-weight buffer
  (meant to start at `CL_FLT_EPSILON`) holds stale data. On an M1 Pro, 24 of 60
  depth/layout/channel cases gave a different result on a repeat run (by
  110–255 levels), and a CPU reference showed it denoising at `h=1.2` where
  the algorithm leaves the picture alone (3.28 levels off).
- **Fix:** Jaded Encoding Thaumaturgy's fork, v1.3, everywhere: tag `v1.3` from
  source on macOS/Linux, PyPI wheel 1.3 on Windows. It carries pinterf's
  9–16-bit support and the fill fix. Same kernel as master. Repeatable in all
  60 cases, within 0.26 of the reference, and the source build is
  bit-identical to the wheel.
- v1.3's `meson.build` assigns the VapourSynth include probe to a variable
  (`r = run_command(...)`, then `r.stdout().strip()`); both scripts' meson
  patchers now handle that form.
- **Behaviour changes:** a Mac's KNLMeans now denoises less at low `h`
  (matching Windows/Linux, as designed), and its `auto` device works, so
  QTGMC's `knlmeanscl` denoiser runs on Apple Silicon instead of falling back
  to DFTTest.
- **Windows x64, verified 2026-11-03** (Radeon 780M, driver 32.0.32015.7029,
  OpenCL probe `gpu`, so nothing skipped). With the 1.14.0 DLL (v1.1.1, sha256
  `bb60e8fa…7a42`), every 10-bit KNLMeans case failed with the predicted
  message, 12-bit failed with "P8, P10, P16, Half and Single", and 16-bit
  passed. QTGMC's `knlmeanscl` failed too on a 10-bit 4:2:0 source, inside
  havsfunc. With v1.3 (sha256 `c7092121…a343`; the same DLL from the script,
  the wheel and the rc1 bundle), all of these pass. Parity was 0.638 at 4:2:2
  (Mac 0.301), and 1.620 at 4:2:0 against a fixtures-only baseline of 1.885
  (Mac 1.394 / 1.717). One thing to know when reading these runs: the 10-bit
  encode failure shows up in ffmpeg as "Header too large", not the KNLMeans
  message. Only the preview path surfaces the Python error.
- Not yet run on macOS x64, Linux, or an NVIDIA GPU.

### FlowFPS's frame count depends on the MVTools version (issue #129, 2026-11-03)

The custom-rate test in `integration_frame_mapping_test.dart` (25 fps to
59.94, 75 frames, expecting `floor(75 * 2400/1001)` = 179) produced 178 on
both macOS x64 nightly jobs and 179 everywhere it was run before. The file had
not compiled since #142 (its harness change was never committed), so this was
its first CI run.

- **Cause.** The platforms do not ship the same MVTools. macOS arm64 and Linux
  build dubhater's unpinned `master`; Windows (the v24 release zip) and macOS
  x64 (Stefan-Olt's v24 build for v3, v24 from source for v2) ship v24.
  Between them `MVFlowFPS` changed its length from
  `1 + (n - 1) * fb / fa` (v24) to `n * fb / fa` (master). The template's
  "FlowFPS emits floor(n * ratio)" was measured on master only. So a FlowFPS
  job on Windows or an Intel Mac wrote one frame fewer than `FrameMap::Retime`
  counts when the ratio is above 1 (one more below 1), and the progress total
  and preview index were off by one at the tail.
- **Reproduced locally** by running an x86_64 worker against the rc1
  macos-x64 bundle under Rosetta (an arm64 worker ignores
  `VAPOURBOX_DEPS_DIR` for its tools and quietly uses the installed arm64
  deps, so it reproduces nothing). vspipe: "Output 178 frames".
- **Fix: the script sets the length.** Both templates compute
  `floor(n * ratio)` with `Fraction` before the call and trim or extend
  after it. The frame v24 leaves off lies past the last source frame, where
  master returns that source frame, so it is padded with the last frame.
  `test_184` asserts the order in both scripts; the frame-mapping suite passes
  on both arm64 (master) and x64 under Rosetta (v24).
- **Not done: one MVTools everywhere.** Pinning arm64/Linux to v24 would lose
  master's ARM speed work (sse2neon removals); Windows has no build newer
  than v24. Any other FlowFPS/BlockFPS/FlowInter behaviour that differs
  between the two versions is still per-platform.

### Deblock before or after deinterlacing: order kept, interlaced output deblocked per field (2026-11-03)

Full report with screenshots and scripts:
[docs/reports/2026-11-deblock-order/](reports/2026-11-deblock-order/index.html).

A user asked whether deblocking should precede deinterlacing (Gemini's
advice). It should in theory: `Deblock_QED` / `deblock.Deblock` assume an 8x8
grid from (0,0), exact only on the decoded interlaced frame, and QTGMC moves
the horizontal block edges. Measured on two 720x576 TFF fixtures (film
ground truth; a real capture against QTGMC of its lossless original), each
MPEG-2 at 1000/1500/3000 kbps with `+ildct+ilme`:

- **Deinterlacing on:** per-field deblocking before QTGMC beats today's
  after-QTGMC order by ≤0.05 dB at the 24/26 default (0.05–0.14 dB at
  36/44), blockiness equal. Not worth reordering.
- **Deinterlacing off:** the deblocker ran on the woven frame; per field
  (`SeparateFields → deblock → DoubleWeave[::2]`) won on PSNR and SSIM in
  all 14 edge-deblocker comparisons, +0.03 to +0.30 dB. **DCTFilter on the
  woven frame was destructive**: 1.5–3.7 dB *below no filtering*, because it
  attenuates the field-to-field alternation on moving edges as high-frequency
  detail; per field it is neutral to slightly positive. Built: every method
  now runs per field when `ScriptGenerator::still_interlaced_tff` says the
  picture is still interlaced (`{{#DEBLOCK_PER_FIELD}}`, both templates;
  `test_183`). A 4:2:0 frame with an odd chroma field height (486 lines)
  can't be split and keeps the woven path. The round trip is bit-exact with
  frame props restored.
- At 1000 kbps a stronger Deblock_QED (36/44) gained ~3x what 24/26 did
  (+0.48 against +0.16 dB): more than any order choice. One clip, one
  strength; not a reason to change the default without its own probe.
- The film fixture's reference carries `small_clip.mp4`'s own (upscaled)
  H.264 blocks; PSNR rewards deblocking's smoothing, and VMAF dips slightly.

### AI models become add-ons; the AI runtime is ONNX Runtime wheels (2026-11-08)

Policy (owner's decision): every AI model ships as an optional add-on, never
in the deps bundle, through one generic manifest format (docs/ADDONS.md). The
first manifest add-on is `ai-runtime`, ONNX Runtime + NumPy for passes that
need per-crop inference or NumPy around a network, which VSNCNN can't do.
The facts the manifest rests on, checked against PyPI and the wheels on this
date (groundwork, not a quality comparison, so no report):

- **What `import onnxruntime` needs is NumPy, nothing else.** The wheels
  declare flatbuffers, packaging, protobuf (and on 1.23.2 / DirectML
  coloredlogs and sympy), but importing the package and running an
  `InferenceSession` in the deps Python with only onnxruntime + numpy on
  `sys.path` loaded no other third-party module; a scan of the 1.23.2 and
  DirectML wheels' runtime modules found no top-level import of them
  either (they are used by `tools/`, `transformers/`, `quantization/`).
- **Intel Macs stop at onnxruntime 1.23.2**, whose wheel is
  `macosx_13_0_x86_64` — above the x64 app floor (12.0), so the add-on carries
  `minOs: 13.0` there and an older Mac is told so. NumPy 2.5.4's Intel wheel
  is `macosx_10_13`, and its arm64 one `macosx_14_0` (Accelerate), both
  within their app floors.
- **Windows uses onnxruntime-directml 1.24.4**, so any DirectX 12 GPU works.
  Its `DirectML.dll` (1.15.4) is under Microsoft's proprietary DirectML
  licence (read from the Microsoft.AI.DirectML 1.15.4 NuGet package — the
  wheel ships no licence text for it), credited as its own component.
- **Windows' embeddable Python ignores PYTHONPATH** (its `._pth` fixes
  `sys.path`), so `ai_runtime.setup()` inserts the add-on's `site-packages`
  itself, and registers `onnxruntime/capi` with `os.add_dll_directory`.
  Untested on Windows from macOS: the nightly heavy run is the first check.
- On an M-series Mac the self-test session reports `CoreMLExecutionProvider`
  first; whether Core ML or the CPU fallback executed the two-node model is
  not distinguishable from `get_providers()`.

### Live-action AI upscalers as add-ons, and AI strength (2026-11-08)

Full report with crops, every number and the scripts:
[docs/reports/2026-11-ai-upscale-addons/](reports/2026-11-ai-upscale-addons/index.html).
Crop & Resize's AI upscalers were all trained on anime; three more methods
now cover real-world footage, run by the same VSNCNN block, with their
models in two manifest add-ons (`upscale-general`, `upscale-esrgan-plus`).
Measured on an M1 Pro (16 GB):

- **Converting Real-ESRGAN's `.pth`** (`Scripts/models/convert_realesrgan.py`):
  SRVGGNetCompact and RRDBNet transcribed, opset 13 / IR 7 like vs-mlrt's own
  conversions. PyTorch vs ONNX Runtime: at most 0.017 of an 8-bit level. The
  TorchScript export of x2plus's `pixel_unshuffle` is a 6-D Reshape/Transpose
  ncnn can't import; a one-hot stride-2 convolution is exactly equal and
  imports. Two runs are byte-identical.
- **VSNCNN fp32 reproduces ONNX Runtime exactly** (≤0.005 levels) for all
  five models; fp16 (what the template uses) differs by a mean 0.05–0.12
  levels, the same order as the bundled anime model's 0.03.
- **2xVHS2HD (RealPLKSR) can't run on VSNCNN.** Its official ONNX (dynamic
  shapes, in-place slice assignment) has 225 Shape, 56 Range/Where/Equal/
  ConstantOfShape/Cast and 28 ScatterND nodes, none of which ncnn's ONNX
  importer supports ("load param failed"). Re-exporting from the `.pth` with
  concatenation instead of slice assignment might work; not attempted (the
  brief was to stop there).
- **Real-ESRGAN x4plus needs tiles at any size.** Whole-frame at 720x576 lost
  the Vulkan device (`vkWaitForFences failed -4`, then a segfault); 512-px
  tiles thrashed at 29 s a frame; 384 is the fastest (6.8 s a frame), 256
  gave 10 s. x2plus runs a DVD frame whole at 0.8 fps.
- **A tile larger than the frame segfaults VSNCNN** (found converting the
  PSNR run: 384 tiles on a 360x288 frame). The template tiled whenever the
  area passed the threshold, so an 800x200 picture (x4plus) — or, for every
  AI method, a frame above 720x576 in area but under 512 lines — would have
  crashed. Tiles are now `min(tile, width/height)`; the heavy suite runs
  x4plus 4x on an 800x200 source.
- **General at 2x = 4x, then resample down**, as upstream's own `--outscale`.
  The kernel moves PSNR by under 0.7 dB, and softer kernels score higher
  (bilinear 28.40, Spline36 27.75, Lanczos 27.70) because PSNR rewards blur;
  Spline36 is the pipeline's kernel and was kept.
- **Flat colour vs Spline36** on the synthetic pattern (worst channel): General
  2.9 levels, Live Action SPAN 0.6 at 2x / 1.3 at 4x, x2plus 4.2, x4plus 12.2.
  Bar centre within 0.3 px for all. **AI strength** 0.5 lands within 0.38
  levels of the mid-point of network and Spline36 and halves Real-ESRGAN 4x's
  tint (11.2 → 5.8).
- Speed at 720x576 (fp16, two streams, quiet machine): SPAN 2x 8.9 fps, General 2x 4.0,
  x2plus 0.9, SPAN 4x 1.5, General 4x 3.9, x4plus 4x 0.15; bundled anime
  Real-ESRGAN 2x 8.3 and CUGAN 4.8 for scale.

### Audio restoration: rendered before the encode; four filter traps measured (2026-11-08)

Full report with scripts:
[docs/reports/2026-11-audio-restoration/](reports/2026-11-audio-restoration/index.html).

A new pass, Audio Restoration, renders one audio stream to a WAV before the
video encode (channel fix, sync offset, drift, declip/declick/rumble/hum,
afftdn, DeepFilterNet as an add-on, two-pass loudness, limiter); the encoder
maps that track first and keeps the other streams. Rendering first, not an
`-af` on the encode, is what DeepFilterNet, two-pass loudness, negative offsets
and subtitle alignment all need. Measured with ffmpeg 9.0.2 and deep-filter
0.5.6 on Apple Silicon, on lavfi-generated signals:

- **afftdn delays by 25 ms at every rate and strength** (1200 samples at
  48 kHz, 1102 at 44.1, 800 at 32; Video-Enhancer's 1200 confirmed) — trimmed
  with `atrim=start_sample`. Its default `nf=-50` took 0.7 dB off −39 dB white
  noise; with the measured floor (quietest tenth of 50 ms windows) 5.5/9.8/
  13.5/15.2 dB at nr 6/12/20/30, a 440 Hz tone unchanged; `tn=1` (noise
  tracking) undid the measured floor entirely (0.7 dB again), so it is off.
- **atempo moved every click ~20 ms early** (≈ −19 to −21 ms after the first,
  at 1.004, 0.996 and 1.02), on top of the stretch. Drift is now an exact
  resample (`aresample` to 4–8× → integer `asetrate` → `aresample` back,
  ratio within ~1e-11): click positions within 0.01 ms. Resampling is also
  the physically right inverse of a sample-clock error (it restores pitch).
- **`alimiter` delays by its attack unless `latency=1`, and normalises to
  0 dBFS unless `level=0`**: measured 239 samples (5 ms) late at 48 kHz, and a
  limit of −6 dB came out peaking at 0.00 dBFS; with both set, 0 lag and
  −6.02 dBFS. loudnorm, adeclick, adeclip, highpass, the notches and the
  drift resample measured zero lag; loudnorm outputs 192 kHz.
- **A late-starting audio stream** (capture audio 0.5 s after the video) lost
  its gap in a WAV: `aresample=first_pts=0` restores it with no seek; with an
  input seek the window starts at the seek point as before.
- **DeepFilterNet** delays 30 ms (1440 samples at 48 kHz); `-D` compensates
  and shortens the output by as much, padded back. It takes 44.1 kHz input and
  always writes 48 kHz. On a synthetic voiced signal in pink noise: pauses
  25.3/22.5/13.7 dB quieter at `-a` 100/30/15, voiced level −1.1 dB, ~4 s per
  minute (mono, M-series CPU). Its SNR *inside* the synthetic voice dropped
  (20.9 → 13.8 dB): a harmonic test tone is not speech, which is the network's
  domain — judge it by ear on real dialogue. Not tested on Windows/Linux, or
  the macOS x64 build (unsigned; the installer signs it).
- Hum notches (`bandreject` Q 8 at f/2f/3f): 47/61/71 dB down at 50/100/150 Hz,
  1 kHz unchanged. Two-pass linear loudnorm hit −23 and −16 LUFS to 0.0 LU.
- Found on the way, not fixed (another area): `whisper-addon.json` states
  `ggml-small.bin` as 466,616,853 bytes; HuggingFace serves 487,601,967. The
  app only uses the size for progress, but `WorkerHarness`'s downloader
  enforces it, so `WorkerHarness.ensureWhisper(model: 'small')` fails until
  the manifest is corrected.

### SangNom, vszip 24 (NLMeans, WNNM) and three vs-jetpack ports (2026-11-08, deps 1.16.0 unreleased)

Report: [docs/reports/2026-11-classical-filters](reports/2026-11-classical-filters/index.html).
Probed on macOS arm64 against a private deps copy with vszip 24.0.0 and
SangNom r45; fixtures are three Kodak images panned 2 px/frame (exact ground
truth, real motion).

- **havsfunc's `santiag(type="sangnom")` is broken against SangNom r45.** Its
  strength-0 step calls `SangNom(order=0)`; r45 documents order 0 as
  double-rate and refuses a clip without `_FieldBased`. So SangNom became its
  own Anti-aliasing method (2x Spline36, `SangNom(order=1)` per axis, back
  down). Every depth runs; 8 vs 10-bit 0.44 levels (santiag's own: 0.37).
- **SangNom's licence is split.** Source header + LICENSE: MIT (james1201,
  Victor Efimov); the same header: "Binaries are GPL v2"; PyPI metadata:
  GPL-2.0. GitHub's SPDX detection only sees the MIT file. Credited as both.
- **vszip: NLMeans arrived in 24.0.0, WNNM in 22.0.0.** 23.0.0 moved to Zig
  0.17 (the macOS x64 sdist build needs `-Doptimize=fast` and the headerpad
  patch on the 8-space `use_llvm` inside `if (build_vs)`; cross-built and
  loaded under Rosetta with the 1.10.0 x64 VapourSynth) and made CLAHE accept
  every depth. The arm64 wheel is now minos 15.0, exactly the floor.
- **vszip's NLMeans is KNLMeansCL on the CPU.** Same arguments, identical
  output (0.0000 levels on the probe, 0.0003 through the worker), h
  depth-independent (8 vs 10-bit 0.005). Hence one set of `knlm_*` parameters
  for both methods.
- **WNNM was measured and not added.** At each method's best sigma, against
  the shipped BM3D path: luma +0.7 to −2.3 dB (ahead only at sigma 4 with
  `radius=1`), chroma 2.6–7.2 dB worse. Widening its sweep to 4x the noise
  found nothing past 2–2.5x. It is fast (10.3 fps at 1080p with `radius=1`;
  the shipped BM3D path ran 0.2 fps there on arm64, all three planes at
  sigma 16), but NLMeans (CPU) is faster (23.0 fps) with better chroma.
  SangNom AA turned out the slowest AA method at 1080p (8.6 fps; daa 15.9,
  santiag 19.6) — an early clip.frames() probe under load had it fastest,
  and the first draft said so. WNNM needs 32-bit float and divides sigma by 255,
  so its float conversion must keep sigma in 8-bit units: with the default
  (limited) range, luma spans 219 levels per 1.0 and chroma 224. Passing
  `range_in_s="full"` instead broke at 10-bit (a 7-level offset) because the
  clip carried `_ColorRange=limited`.
- **vszip's own CPU BM3D** (also new in 24.0.0) scored 1.1–2.2 dB below the
  bm3d r12 path on every fixture; not used.
- **The ports were checked against vs-jetpack itself** (vsjetpack 2.2.7 on the
  bundle's Python 3.12; its three functions are byte-identical to 3.0.0's):
  mpeg2stinx 0.04 levels, FixInterlacedFades exact in both modes. vine could
  not run there — vs-jetpack's Catrom is a custom resize2 kernel.
- **mpeg2stinx lost PSNR on every fixture** (progressive pans as interlaced
  MPEG-2, and 3:2-telecined MPEG-2 after VIVTC): −0.1 to −3.0 dB, about −4.5 dB
  on cleanly coded frames and +0.1 on starved ones. It clamps each field to a
  bob of the other, which costs vertical detail; the fixtures lack the
  comb-like noise it targets. Shipped advanced-only with that in its
  description. VFM flagged every frame of the detailed pan `_Combed`.
- **FixInterlacedFades closes the comb of a fade applied after the field
  split**: field gap 5.27 → 0.29 levels (average), 0.00004 (match); through the
  worker on a real clip 4.12 → 0.06. Two traps: `average` leaves the last
  frame of a fade to full black half-lit (one field's distance is 0, so it is
  left alone and the other set to half); and `std.DoubleWeave` sets
  `_FieldBased=2`, which made a later 4:2:0 resize treat the progressive
  frames as fields ("dimensions must be divisible by subsampling factor" at
  an odd field-chroma height) until the block reset it.
- **The first fade fix crashed or hung real jobs.** It made an akarin
  `Expr` per frame inside two concurrent FrameEvals. Under vspipe that
  aborted (SIGABRT, 10 frames), segfaulted (SIGSEGV, a 720x576 IVTC job
  through the worker) or spun one core indefinitely (97 minutes on 30
  frames, found when the benchmark hung); single-threaded, or with
  `std.Expr`, it was fine, and the 320x240 heavy test and the Python-side
  probes never tripped it. Fixed by stamping the gains as frame properties
  (`ModifyFrame`, no node creation) and applying them with one akarin
  expression; the std.Expr FrameEval remains only where akarin is absent.
  Colour Correction's auto white balance makes an akarin node per frame in a
  single FrameEval the same way; it did not reproduce (30 frames, vspipe), but
  it is the same pattern. A heavy test now times a full-size IVTC + fade-fix
  job (2.5 s), and fails on the old block with the SIGSEGV.
- **vine** on an oversharpened pan: +0.9 to +1.1 dB, against DeHalo_alpha's
  +4.1 to +4.4 (which blurs the amplified texture away). Advanced-only.
### Face restoration: RestoreFormer++ on ONNX Runtime, steadied in aligned space (2026-11-08)

Full report with images and scripts:
[docs/reports/2026-11-face-restoration/](reports/2026-11-face-restoration/index.html).

A Face Restoration pass (after Crop & Resize) on the `ai-runtime` add-on, its
models as add-ons: `face-restoration` (RetinaFace R50, BiSeNet,
RestoreFormer++; Apache-2.0/MIT), `face-gfpgan` and `face-codeformer` (both
non-commercial: NVIDIA's licence on GFPGAN's StyleGAN2 code, S-Lab License
1.0). Measured on an M1 Pro with a VHS-degraded clip of NASA public-domain
footage (`Tests/TestResources/face_restore_test.mp4`):

- **Conversions are exact**: ONNX vs PyTorch ≤2.5e-4 on [-1, 1] (0.03 of an
  8-bit level), reproducible byte for byte. Two departures from upstream:
  GFPGAN exported with its fixed noise buffers (upstream draws fresh noise
  per call — new texture every frame), and CodeFormer's `w` as a graph input
  (the traced `w > 0` branch adds exactly zero at `w = 0`).
- **The NumPy pipeline matches facexlib + OpenCV**: landmarks 6e-5 px,
  alignment 7e-5, final frame ≤0.16 levels for the same restored face.
- **Detector: ResNet-50 over mobilenet0.25.** Both found the face in every
  frame, but mobilenet's landmarks jittered 1.5x (SD) to 2.2x (1080p wide
  shot) as much; ResNet-50 costs 87 ms vs 7 ms per frame on Core ML.
- **Temporal stability**: smoothing landmarks over n±1 (the obvious fix)
  changed nothing measurable here (flick 2.287 → 2.284; this detector was
  already steady). What works is blending each restored face with its
  neighbours' in the aligned 512 space, weighted to zero where the input
  crops moved: RestoreFormer++'s excess flicker over the clean source halved
  (2.287 → 1.799; 1.571 at the default strength 0.8), GFPGAN's fell 86%,
  with no rise in distance from the clean source (no ghosting the metric
  sees). One mostly still clip; fast motion untested.
- **Bit-exact outside the faces** (MaskedMerge in the source format): 0
  samples changed outside the face box over 16 frames at 8 and 10 bits;
  preview = encode exactly.
- **Speed** (one face per frame, RestoreFormer++): 2.2 fps SD and
  1.8 fps 1080p on Core ML; 0.085 / 0.072 fps on the CPU,
  ~25x slower (Linux has only the CPU).
- **Core ML traps**: concurrent predictions from VapourSynth's threads ran
  the GPU out of memory (`kIOGPUCommandBufferCallbackErrorOutOfMemory`), so a
  pass's model runs are serialised (`ai_runtime.Runner`, one lock) with a CPU
  retry; `ModelCacheDirectory` made the second session fail
  (`output_features has no value`), so every job compiles — CodeFormer takes
  30–50 s, the others 2–8 s.
- Untested: Windows (DirectML), Linux (CPU), macOS x64; crowds, profiles and
  scene cuts across a face.

### Colourisation: DDColor and DeOldify Video, luma kept bit-exact (2026-11-08)

Full report with images and scripts:
[docs/reports/2026-11-colourisation/](reports/2026-11-colourisation/index.html).

A Colourisation pass (between Chroma Fixes and Color Correction) on the
`ai-runtime` add-on, one add-on per model: `colorize-ddcolor` (DDColor-T,
Apache-2.0, 220.7 MB) and `colorize-deoldify` (DeOldify's Video generator,
MIT, 872.8 MB; DeepAI's copy cross-checked by SHA-256 against a Hugging Face
mirror). Measured on an M1 Pro with 5 s of "Diary of a Sergeant" (1945, US
War Department, public domain; `Tests/TestResources/colorize_test.mp4`):

- **Conversions are exact and reproducible byte for byte.** DDColor ≤1.8e-3
  CIELAB units from PyTorch at 256-640; DeOldify ≤1.4e-6. DeOldify had to be
  rebuilt without fastai (v1 doesn't install with a current torch); checked
  against FaceFusion's independent export it first differed by 0.016 mean —
  fastai's `PixelShuffle_ICNR(blur=False)` blurs anyway (it tests the module,
  not the flag) — then agreed to 1.8e-6.
- **Core ML needs the graph rewritten, and still compiles DDColor slowly.**
  Edge-mode `Pad`, `Expand` (`Tensor.repeat`) and `Einsum` aren't in ML
  Program: DDColor split into six partitions. Rewritten exactly, each model is
  one partition and DDColor runs at 101 ms per frame at 512 (261 ms before), but compiling it
  takes 77 s in every process (DeOldify: 3 s). Previews (a process each) run
  DDColor on the CPU (5 frames in 3.8 s); `ModelCacheDirectory` cut a second
  session to 14.5 s but cached 898 MB per render size, keyed by model path.
  Core ML refused DDColor with free dimensions outright, so one dynamic-shape
  file serves every size through ONNX Runtime's free-dimension overrides
  (`ai_runtime.session(dims=)`).
- **Luma bit-exact** at 8, 10 and 16 bits, field-based, and on a colour source:
  the colour becomes YUV in the source's matrix and only U/V are taken.
  DDColor's CIELAB recombination (std.Expr) matches the exact formulas to
  0.0014 levels; OpenCV's float path (what upstream calls) differs by up to
  3.8 levels near black because it tabulates the sRGB curve. Upstream scales
  DDColor's a/b nearest-neighbour; the pass uses bilinear.
- **Flicker**: per frame, colour flickers by 1.45 levels where the picture is
  still (DDColor; DeOldify 0.33, but with 4.5x less colour). Averaging each
  prediction with 2 neighbours either side, weighted to zero where the grey
  picture moved, cuts both by 84%; the motion weighting changes still flicker
  by <0.01 but cuts the colour lag in moving areas by a third (2.00 → 1.33).
- **Speed** (whole pass, steady colour 2): DDColor 9.1 fps SD / 8.4 fps 1080p
  on Core ML (1.3 on the CPU); DeOldify 6.0 / 6.0 (0.65 on the CPU).
- No preset turns it on (8 mm home movies are mostly colour). Untested:
  Windows (DirectML), Linux, macOS x64; fast pans.
### Crop & Resize: BT.601 → BT.709 on SD → HD, and Detect borders (2026-11-08)

Full report with images and scripts:
[docs/reports/2026-11-crop-detect-709/](reports/2026-11-crop-detect-709/index.html).

**BT.709 conversion.** An SD source resized to HD kept its BT.601 matrix and
tag; a player that ignores the tag on an HD picture (many do) decodes it as
709. Measured: a 75% green comes back 30 levels dark (191 → 161), 100% green
40, magenta and red 25–30. Crop & Resize now converts the matrix in the
script when the output is HD (`convertToBt709`, default `auto`), and
`VideoJob::output_color_metadata` is the one decision every site after the
conversion follows. Measured through the real worker: every patch within
0.67 levels of the source decoded as 601, whether the output is read through
its tags or as 709 regardless; preview = encode exactly. The conversion costs
~7–10 ms per 1350x1080 frame (8 threads, M1 Pro); a 601 → 709 → 601 round
trip changes luma by 0.25/255 on average.

- **Matrix only, primaries kept and tagged as the source's.** Also converting
  SMPTE C → BT.709 primaries moved a 75% green to (55,188,0) and a 75% magenta
  to (187,47,191) when decoded without colour management (most players): a
  hue shift of its own, as large as the one being fixed. EBU (PAL) primaries
  differ only in green, and still moved 75% green to (0,191,30). A
  colour-managed player reads the kept primaries tag and shows the source's
  colour either way.
- **Default `auto`, deliberately changing existing output**: an SD job that
  resizes to HD now writes 709-tagged, converted samples where it wrote
  601-tagged ones. The 601-tagged HD file was correct but shown wrong by the
  players people use; the converted one is shown right by all of them. No
  built-in preset resized before, so none changes; the new `SD Tape → HD
  (YouTube / TV)` preset sets `on`.
- **VapourSynth R78 trap**: a frame's `_Matrix` property overrides
  `matrix_in_s`. The first measurement script read "601 decoded as 709" equal
  to the source because of it; the template's block removes `_Matrix`/`_Range`
  before converting.

**Detect borders (`--detect-crop`).** VCG Deinterlacer 2.0's `edges.rs` (MIT)
was read for the signals; the code is our own (nothing ported, so no NOTICES
entry). On fixtures built from real VHS picture with known borders every edge
came back exact (noisy blanking 14/10 px, a 2-line top, an 8-line band; 12
lines per field interlaced; 72-line letterbox bars reported apart; subtitles
40 lines up and fades to black ignored); on a real DVB-T broadcast 7/8 black
columns and 4 black + 1 dim bottom line, as measured by eye; ~0.5–1.5 s per SD
source and ~2.9 s at 1080p (release worker, 24 frames). Traps designed
against, each with a unit test: dark scenes (98th percentile over all frames,
dark frames dropped), noisy blanking (absolute detail floor), letterbox
(bars over 5% are framing), subtitles (band must span 6 of 8 width segments in
half the frames, from the bottom), interlaced (compare within the field).
Untested: a real capture with a visible head-switching band (none in
`Tests/TestResources/`; the real VHS fixture's bottom is too dark to show
one), and Windows/Linux (the analysis is plain Rust; only the decode is
platform-specific).

### Frame Rate + Noise Reduction + Sharpen: dark patches not reproduced (issue #148, 2026-11-10)

Full report with scripts:
[docs/reports/issue-148-frame-rate-combined/](reports/issue-148-frame-rate-combined/index.html).

- Reported: "black shadow-like patches" once Denoise and Sharpen were added to
  a frame rate conversion that was clean alone. No clip, method or platform.
- Measured on macOS arm64 by exec'ing the template's own `{{#FRAME_RATE}}`
  block after the filters: the share of synthesized-frame pixels darker than
  **both** real neighbours by >24/255. 5 denoisers x 4 sharpeners x
  FlowFPS/RIFE x 8/10-bit sit at 0.001-0.005% with or without the filters (a
  single black 32x32 block in the 320x240 fixture is 1.3%). Fast pan and hard
  cuts: same with and without.
- Suspects ruled out here: FlowFPS at 10/16-bit matches 8-bit to 0.14/255
  mean (MVTools master); RIFE's RGBS input is already out of range from the
  *source* (1.2% of samples < -0.05), sharpening barely moves it.
- No pass changed. A clamp before RIFE or a prefiltered FlowFPS search would
  change every frame-rate job's output for no measured defect.
- Untested and most likely: MVTools **v24** (Windows, macOS x64) and RIFE on
  non-Apple Vulkan drivers. `integration_frame_rate_combined_test.dart`
  (heavy, nightly, all four platforms) asserts NR + Sharpen stay within 0.05
  percentage points of frame rate alone on the mean over synthesized frames
  **and** within 0.25 on the worst single frame, so it covers exactly those.
  The mean alone would miss a one-frame patch (~0.03 points over 40 frames).
- `pal-sd-25.mov` is static colour bars: useless for anything motion-related.

### Sources tagged `reserved`: clear invalid colour tags before converting (2026-11-10)

Full report with scripts:
[docs/reports/2026-11-reserved-colour-tags/](reports/2026-11-reserved-colour-tags/index.html).

- Reported on the videohelp forum with a ProRes 422 capture: no Original
  frame, no thumbnails, Detect borders "No frames could be decoded." Its tags
  are `color_primaries=reserved`, `color_transfer=reserved`. FFmpeg's ProRes
  decoder reads code 0 (Apple's "unknown") as ISO 23091's `reserved`, and
  FFmpeg 9's scaler refuses to convert such a frame
  (`Unsupported input … prim:reserved trc:reserved`).
- Every decode that converts the pixel format failed: the app's before frame
  and thumbnails, `--detect-crop`, `--detect-native` (not reported), and the
  encode/preview of a ProRes 4444 with alpha (`yuva444p12le` is converted to
  the pipe format). Decodes in the source's own format were fine.
- Fix: `setparams` sets each *invalid* tag (off `ColorMetadata`'s lists;
  `gbr` counts as valid) to `unknown`, first in the decode's one `-vf`
  (worker `decode_tag_neutraliser` via `source_decode::decoder_filter`; app
  `ColorTags.decodeNeutraliser` via `PreviewGenerator.beforeFrameArgs` /
  `thumbnailArgs`). The result is bit-identical to the same file untagged.
- Never clear a valid tag: on a bt709 source, yuv → gray16le with
  `colorspace=unknown` differs by up to 28 levels (mean 15). That is also why
  the job keeps the raw `reserved` (the app's `colorTag` forwards it). The
  worker decides from it rather than clearing whatever `from_raw` dropped.
- Clearing only one of primaries/transfer is not enough when both are
  reserved.
- Open: `--detect-native`'s gray16le decode depends on the matrix tag in any
  case (the same 28 levels). `--detect-noise-halo` avoids it by reading the
  luma plane of the source's own format.
  **Fixed 2026-11-14**: `--detect-native` now decodes the pipe format and
  scales the Y plane itself (`native_res::luma_gray16`: limited range
  expanded to 0–65535, full range scaled — within one code of an *untagged*
  source's gray16le, so the calibrated cap and dip threshold are unchanged).
  It mattered more than 28 levels suggests: a BT.709-tagged copy of the 10-bit
  Catmull-Rom test master lost its dip altogether (1063p, dip 0.59, not
  found; untagged 720p, 0.144). Now both give the identical report.
- Also found then: the app built all three Detect jobs (`--detect-native`,
  `--detect-crop`, `--detect-noise-halo`) without the matrix, primaries and
  transfer (Descale's without the range too), so `decode_tag_neutraliser`
  never fired from the app — only the heavy test, whose jobs carry tags,
  proved the fix. They now share `MainViewModel._detectorJob`, which always
  carries the four raw tags. See the report's addendum (section 8).

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

### GPU tests leave CI: the `gpu` tag (2026-11-09)

From 2026-10-25 the Linux and Windows CI jobs ran the RIFE and AI upscaling
tests on Mesa's lavapipe, a CPU Vulkan driver, with `VAPOURBOX_EXPECT_VULKAN=1`.
On the 1.7.0 branch that stopped being workable, almost all of it on Windows:

- One 240x192 Real-CUGAN preview frame took 2m21s on `main` and from 3 to over
  5 minutes on the branch, with nothing in our code to account for it (CI runs
  42484522476, 42499908163). Real-ESRGAN x4plus at 4x took ~18 minutes for five
  frames on Linux and ran past 20 on Windows (nightly 42484525297).
- When a timed-out test's harness killed only the worker, Windows left vspipe
  running the network on every core and the next test timed out too. The
  harness now kills the whole tree (`ProcessTree.killTree`). Even so, run
  42516550724 timed out both AnimeJaNai tests at 5 minutes; that test had
  taken about 15 s before.

These timings measure the runner's CPU, not the GPU path a user has, and every
budget raise was followed by another timeout. So tests that need a Vulkan device
are tagged `gpu` and both workflows exclude the tag, and
`.github/scripts/provision-vulkan.sh` is deleted (it is in git history if a GPU
runner ever appears). Without a device CI keeps the probe-answer and refusal
tests. What is lost: CI no longer proves that RIFE and VSNCNN load and run on
the Windows and Linux bundles. That now has to be checked by hand on a machine
with a GPU (`VAPOURBOX_EXPECT_VULKAN=1 flutter test --tags gpu`), as MoltenVK
always was.

### RIFE's and the anime upscalers' models leave the deps bundle; probes on stand-in models (2026-11-09, deps 1.16.0 rc2)

The 2026-11-08 policy (every AI model an add-on) had two exceptions left from
deps 1.14.0: RIFE 4.26's model in `vapoursynth/rife/models/` (11 MB) and
vs-mlrt's Real-ESRGAN anime / Real-CUGAN ONNX files in
`vapoursynth/ncnn/models/` (20 MB). They are now the `frame-rate-rife` and
`upscale-anime` manifest add-ons; the plugins (librife, VSNCNN, MoltenVK)
stay in the bundle. Mechanism findings, read from the pinned sources and
checked on an M1 Pro against the deps 1.16.0-rc1 bundle with its model
directories deleted (groundwork, not a comparison, so no report):

- **RIFE's model directory name is load-bearing.** The plugin
  (`styler00dollar/VapourSynth-RIFE-ncnn-Vulkan` r9_mod_v33, `plugin.cpp`)
  decides the model family from substrings of `model_path` (`rife-v2`,
  `rife-v3.9`, `rife-v3`, `rife-v4`, `rife4`) and the padding from more
  (`rife-v4.25` 64, `rife-v4.25-lite` 128, `rife-v4.26` 64, else 32). An
  add-on id cannot hold a dot, so the manifest format now allows a file
  `name` to be a relative path of plain names, and the add-on installs as
  `addons/frame-rate-rife/rife-v4.26_ensembleFalse/flownet.{param,bin}`.
- **VSNCNN takes a model as bytes**: `network_path` with
  `path_is_serialization=True` (vs-mlrt v15.16 `vs_ncnn.cpp`). `loadONNX`
  needs one 4-D input and output; it fixes N/H/W itself, so dynamic dims
  (`n`, `h`, `w`) are fine. A 264-byte ONNX (`Tests/TestResources/
  ncnn_selftest.onnx`, one 1x1 Conv swapping channels 0 and 2, bias 0.125)
  ran on Metal through MoltenVK: input (0.2, 0.4, 0.6) gave
  (0.72510, 0.52490, 0.32495) with `fp16=True` (exact: 0.725, 0.525, 0.325).
- **RIFE runs a weightless stand-in.** Its v4 path feeds `in0`, `in1` (the
  two padded frames, 0-255), `in2` (the timestep plane) and extracts `out0`,
  through its own preproc / timestep / postproc shaders. A two-layer ncnn
  param file (`BinaryOp` add of `in0`+`in1`, then multiply by 0.5) with an
  empty `flownet.bin`, in a directory named `rife-v4.26_selftest`, turned
  frames (0.2, 0.4, 0.6) and (0.6, 0.4, 0.2) into exactly 0.4 in every
  channel at frame 1 of a 25 → 50 retime.
- So both probes now run a stand-in network and check the answer
  (`WrongResult` if the GPU computes garbage, tolerance 0.01), and report
  available on a bundle with no model in it and no model add-on installed.
  "Can't run here" (no Vulkan, missing VC++/libgomp, old CPU) is therefore
  known before the user downloads anything; a missing add-on is a separate
  refusal, through `required_addons()`, naming the add-on and Settings →
  Add-ons. A stand-in that fails to load (`failed to load model`, `load param
  failed`) is now `LoadFailed`, not `NotInstalled`: nothing the user installs
  would fix it.
- The anime models are hosted by us, byte for byte as vs-mlrt ships them
  (same SHA-256 as the deps scripts pinned), because vs-mlrt publishes them
  only inside `models.v15.16.7z` (~810 MB). RIFE's come from upstream's
  repository at the commit the deps scripts pinned.
- Upgrade path: deps 1.14/1.15 users are moved to 1.16.0 by the app anyway,
  which removes the bundled copies. A saved pipeline with RIFE or an anime
  upscaler selected shows the add-on notice with a Download button in its
  panel, prompts when the pass is switched on, and a job is refused with the
  add-on's name rather than failing in the plugin. No built-in preset selects
  either.

### Noise and halo scores for the pass list (2026-11-09)

Full report with images and scripts:
[docs/reports/2026-11-noise-halo-scores/](reports/2026-11-noise-halo-scores/index.html).

Noise Reduction and Dehalo were always neutral in `pass_relevance.dart`. A
survey of VCG Deinterlacer (MIT) suggested measuring both; its measures were
tried first and rejected: ffmpeg `signalstats` TOUT stays at 0.000-0.012
whatever noise is added (it counts vertical outliers, not noise), YDIF follows
motion and isn't scaled for 10-bit, and its halo ratio read a clean, dense
photo (0.149) above a sharpened one (0.066).

- **Noise is measured in time, not space.** Immerkaer's spatial estimator
  (block 10th percentile) is exact for white noise but read tape-like noise
  (blurred along the line) and grain-like noise of sigma 6 at 1.2-2.5, and
  dense texture at 3.6 — spatially they are the same thing. A
  motion-compensated frame difference (16x16 blocks, +-10 px search, match
  chosen on 3x3-smoothed pictures) sees noise at every frequency and cancels
  texture that moved: white sigma 4 reads 3.66-3.79, tape sigma 6 5.0-5.4,
  texture panned by 1.37 px a frame at most 2.06. +-6 px was too small for
  interlaced fields 8 px apart (clean read 5.5-8.3).
- **Halos: per edge, two-sided, over 7 lines.** Overshoot and undershoot
  against plateaus 6-10 px out, with equal near/far sample counts so noise
  cancels; min of the two, so outlines score 0; plateau flatness also allows
  3% of the step, or strongly sharpened pictures lose their edges. Clean max
  1.48 (3.30 on real 1080p footage), unsharp amount 1 on sharp SD pictures
  11-71. Sharpening of soft edges (Kodak 23, NASA 1080p, the VHS capture)
  rings past the plateau zone and is missed.
- **Thresholds 3.5 and 6.0**, decided in the worker; no clean fixture of 154
  crossed either. Both under-report (compressed sources' skipped blocks read
  as noiseless), so only a high score says anything. On the repo's real
  footage neither fires (VHS noise 1.40, 1968 film grain 1.57).
- The Rust matches the NumPy reference on the same frame pairs to 0.002
  (noise) and 0.49 (halo; median under 1e-6 — edges on the flatness limit
  fall either way between float32 and f64); no verdict differs. 0.5-0.9 s on
  SD, 2.7-3.4 s at 1080p, 2.9 s at 2160p (release, M1 Pro). Untested: non-rigid motion (water, foliage), real footage
  with known halos, sources with many shots.

### deps 1.16.0 and `addon-models-v1` published (2026-11-09)

**deps 1.16.0** is the `deps-v1.16.0-rc2` bundles with only the version
changed, as 1.15.0 was from its rc1. The re-stamp is now committed as
`Scripts/promote-deps-rc.py`, which verifies every entry but `version.json`
against the candidate (CRC, size, permissions, timestamp, compression). One
trap it hit: Python's `zipfile` (3.15, in both `writestr` and `open(..., 'w')`)
gives an entry whose attributes are 0 a mode of `0600`, and every entry of the
Windows bundle (written by PowerShell) has 0, so a naive copy changed every
Windows file's attributes. The script puts each original value back before the
central directory is written. rc2 had passed CI on all four platforms; the
nightly's one failure was the known KNLMeans `std::out_of_range` flake on
linux-x64-v2 (QTGMC's KNLMeansCL path on the runner's CPU OpenCL).

**`addon-models-v1`** now hosts the sixteen model files we convert or
re-host (face restoration, colourisation, the Real-ESRGAN / Real-CUGAN
upscalers), moved from `deps-v1.16.0-rc1` byte for byte (hashes checked against
the manifests before upload, two re-downloaded and checked after), each family
beside its upstream LICENSE as `LICENSE-<project>.txt` — GFPGAN's includes
NVIDIA's Source Code License terms, which with CodeFormer's S-Lab licence
require the text to accompany a redistributed copy. The release notes list
every file's add-on, upstream, licence and the script that made it. The
manifests point there; the rc1 copies were left in place.

While uploading the anime models to rc1 on the same day, github.com's
anonymous download link for one asset returned 504 for a while (a
GitHub incident; the API served the file) — re-uploading did not help, waiting
did. A manifest's `url` is independent of its installed `name`, so a stuck
asset could have been re-hosted under another name without touching code.

### Source grid: frame N is a slot, placed by timestamp; Soft Telecine at a film rate (issue #174, 2026-11-14)

Full report with scripts:
[docs/reports/issue-174-source-grid/](reports/issue-174-source-grid/index.html).

- The follow-up #157 left: on sources whose stored frames are not one per
  frame number, the `rawvideo` decoders' constant-rate output disagreed with
  the timestamps. ffmpeg emits a frame as often as its *duration* covers, and
  a `repeat_pict` flag lengthens the duration while the next timestamp stays
  put: `soft_telecine_test.mkv` (23.976 header, frame-repeat flags) decoded
  to 122 slots for 120 frames, every encoded frame two late. At a gap's edge
  it rounds differently (`interlaced_test.avi` slot 4; a MakeMKV-like MKV put
  the pulldown repeat a slot early in one cycle of four). And #157's reset
  rebased a seek to the first frame it *kept*, which inside a null run or on a
  pulldown repeat is the frame after the slot.
- **Decision: frame N is slot N of the grid at the job's rate (the stream's
  exact fraction) from the first picture**, each slot showing the stored frame
  its timestamp puts there: the rule the VFR path already uses, and what the
  sound and the app's counts already assumed. Every constant-rate decoder runs
  `-copyts`, `setpts=PTS-<first picture>/TB` (the same constant everywhere, so
  `fps` rounds pulldown's half-slot ties identically in every decoder),
  `fps=N/D`, `trim=start_pts=N`, `setpts=PTS-STARTPTS`, seeking 8 slots early
  (plus #169's preroll). Measured exact against an independent timestamp
  placement on 14 fixtures, untrimmed and from every start tried; regular
  sources identical frame for frame. Rejected: the grid with #157's reset
  (still wrong in null runs and on pulldown: 7/11, 2/17), and routing null-frame
  AVIs through the VFR timeline (a whole-file packet scan on every preview of
  a large capture).
- **No grid without PTS.** MPEG-2/MPEG-4/H.264 in AVI store decode-order
  timestamps; #173's decoder delay handles them and they keep its arguments.
- **What the app sends for soft telecine:** a DVD's header always says 29.97,
  and ffprobe reports 29.97 for it in a VOB (r 60000/1001, avg 30000/1001;
  `selectFrameRate` takes avg) and in Matroska even with one timestamp per
  film frame. So VDecimate was right there, and wrong only for a source whose
  own rate is the film rate: 24 of 120 film frames removed, 19.18 fps stamped.
  Soft Telecine now decimates at 29.97/30 only (`soft_telecine_decimates_at`,
  app twin `VideoInfo.softTelecineDecimates`, shared `soft_telecine_rates.json`);
  the app treats a 23.976 soft-telecine source as progressive film. And it
  pipes whole 5-frame cycles (`pipe_frames`): the VOB's 149 slots left a
  partial last cycle from which VDecimate took real frame 118/119.
- Matroska with no `nb_frames` and no stream duration is counted from its last
  picture (`frameCountFromLastPicture`): the container duration counted the
  last frames' repeat flags (121 for 120).
- Not fixed: a start inside a null run longer than the 8-slot lookback;
  `small_clip.mp4`'s `nb_frames` still counts 3 frames its edit list drops.
- **Corrected at review: frame 0 of a TS/PS drops `-copyts`.** The grid's
  `-copyts` turns off ffmpeg's timestamp discontinuity correction. Two
  program streams joined so the clock resets at picture 150 (what the DVD
  import writes for a title whose cells reset) gave 150 of 300 pictures
  through the grid from frame 0 (`reset_probe.py`); in the worker
  `pipe_source` would have frozen the last one for the rest. Frame 0 of a
  `SeekPlan` source now decodes without `-copyts`, the grid anchored by
  `setpts=PTS-STARTPTS` instead of the origin constant
  (`SourceGrid::filters_from_first_picture`, app `startAt`): 300 of 300, and
  slot for slot the `-copyts` grid on the VOB, the DVB-T clip and the
  late-video TS. Dropping the grid there instead was tried first and lost the
  VOB's last film frame under Soft Telecine again. Seeking TS/PS decodes
  still run `-copyts` (#169) and still stop at such a reset (task #21).
- Also at review: `output_duration_secs` counts `pipe_frames`, so Audio
  Restoration fits the sound to Soft Telecine's padded last cycle (120 film
  frames from 149 slots, not 119).

### Seek alignment: the decoder repeated the first frame after a seek (issue #157, 2026-11-10)

Full report with scripts:
[docs/reports/issue-157-seek-alignment/](reports/issue-157-seek-alignment/index.html).

- Reported (videohelp forum, thread 419911 post #152): with every filter off,
  the preview's Processed frame lagged the Original by one.
- Cause: the worker's decoders write `rawvideo`, which has
  `AVFMT_NOTIMESTAMPS` but not `AVFMT_VARIABLE_FPS`, so the ffmpeg CLI times
  it at a **constant rate**. The preview decoder (always) and a trimmed encode's
  decoder seek to `(first - 0.5) / fps`; the kept frame then sits half a frame
  after the output's zero, and for time bases such as MP4 1/2997, MOV 1/11988,
  MKV 1/1000 and TS 1/90000 the constant-rate grid fills that gap by emitting
  the frame twice. Preview: frame N-1 beside a correct Original (an image
  muxer gets passthrough timing). Trim 41..52: `41, 41, 42 .. 51`. Noise
  score: every sampled pair one picture twice, so sigma ~4.5 noise read 0.0
  and was never suggested. A soft-telecine trim lost 15 of 60 film frames.
- Fix: `setpts=PTS-STARTPTS` first in the seeking decoder's single `-vf`
  (`source_decode::RESET_PTS_FILTER`), and no `-ss` at all when the preview
  window starts at frame 0, so it decodes like the untrimmed encode (which
  moved preview frame 0 onto the encode's frame 0 on two sources and left the
  other 11 unchanged). Untrimmed encodes are bit-identical (framemd5, five
  jobs incl. QTGMC). Not `-fps_mode passthrough`: on soft telecine it hands
  over stored frames instead of the constant-rate slots an untrimmed encode
  gets.
- Why no test saw it: preview and encode shifted together, and the
  frame-mapping fixture (`interlaced_test.avi`, 1/25) has no doubled frame.
- Correction (review): that fixture's **leading** null frames (stored pts 0,
  then 5) are the one case the reset changes. A seek into them was right
  from the first real frame on (constant-rate timing filled the gap from the
  seek point); the reset rebases to the frame after the gap, so a trim from
  1..4 runs up to two frames early. The frame-mapping test's "from an
  in-point" used in-point 3 and failed; it now starts at 6. Mid-stream null
  frames (dropped-frame captures, which report `avg == r` and so never reach
  the VFR decoder) are unchanged: frames 100-104 dropped, old decoder and
  reset give the same frames from every start 97-106 (both wrong for an
  in-point inside the run). Subtracting the seek's half frame
  instead (`PTS-0.5/fps/TB`, keeps gaps) fixes the same doubles but ties
  and rounds early in a 1/25 time base and broke starts 98-99 there. Leading
  null frames were a follow-up, fixed by the source grid (issue #174, entry
  above). Script: the report's
  `scripts/gap_probe.py`.
  `integration_seek_alignment_test.dart` compares the preview, the app's
  Original (`PreviewGenerator.beforeFrameArgs`) and a trimmed FFV1 encode each
  with an independent `select=eq(n,N)` decode; against the old worker it fails
  8 of 12. New fixture `seek_timebase_2997.mov` (1/11988).
- The noise report's thresholds stand: its fixtures are intra FFV1 MKVs, which
  seek correctly, and its reference reads from frame 0.
- Found while measuring, **not fixed here**, all the same under passthrough
  timing: MPEG-PS/TS seeks start at a later keyframe (DVD-style PS: 40 -> 48;
  TS: 40 -> 50; the DVB-T capture); MPEG-2 in AVI lands 1-2 frames early
  (cause and fix: "AVI seeks", 2026-11-14, below: three faults, two of them
  wider than MPEG-2);
  AVI null frames and soft telecine give an untrimmed decode leading repeat
  slots (79 slots for 75 frames; 122 for 120), so frame numbers disagree.

### Field order for FFV1/HuffYUV/FFVHuff and x264; not x265 (2026-11-14)

Follow-up to the v210 entry below. Full evidence:
[docs/reports/2026-11-field-order-other-codecs/](reports/2026-11-field-order-other-codecs/index.html).

- **FFV1, HuffYUV, FFVHuff take `-top` like v210**: MKV `tb`/`bt`, MOV
  `fiel`, bit-identical pixels. FFV1 also writes it in its bitstream, so it
  survives in AVI; HuffYUV/FFVHuff in AVI record nothing (job log says so).
- **x264 codes interlaced (MBAFF)**: `-flags +ildct -x264-params tff=1|bff=1`.
  Field PSNR at equal bitrate +0.33 to +1.00 dB (VHS), +0.07 to +0.18 dB
  (DVB-T); BD-rate −16.5 % / −2.2 %; ~20 % slower; Apple's hardware decoder
  refuses MBAFF (software decode is fine). `+ildct` alone left a BFF
  picture's `pic_struct` saying top-first on 46 of 79 frames.
- **x265 and the hardware encoders stay unflagged.** x265's `interlace` mode
  declares each woven frame one field; a container-only flag is read by
  AVFoundation and ignored by VLC. VideoToolbox ignores `+ildct`; NVENC/QSV/AMF
  were not available. `field_order_note` logs it instead of refusing.

### v210 output, and interlaced ProRes/v210 flagged progressive (2026-11-10)

Forum request (videohelp 419911, #154): uncompressed 10-bit 4:2:2 in MOV for
Premiere/Resolve. Full evidence:
[docs/reports/2026-11-v210-field-order/](reports/2026-11-v210-field-order/index.html).

- **Every still-interlaced ProRes/v210 MOV was flagged progressive**
  (`fiel 0x0100`). vspipe writes `Ip` in the Y4M header whatever
  `_FieldBased` says. `-field_order tt` on the output is inert in FFmpeg 9
  (overwritten from the frame flags); `-top 1|0` on the pipe input works
  (`fiel 0x0209` / `0x020e`, MKV `tb`/`bt`; AVI has nowhere to put it).
  ProRes also needs `-flags +ildct`, or its own frame header stays
  progressive. The choice is `pipeline_executor::field_order_args`, from
  `ScriptGenerator::output_field_order`.
- **FFmpeg's `-pix_fmt` conversion of interlaced 4:2:0 to 4:2:2 blends the
  fields' chroma** (U rows 64/192 came out 172/84; zimg with `_FieldBased`
  keeps 64/192). v210's 4:2:2 10-bit is therefore made in the script
  (`EncodingSettings::effective_chroma_subsampling`). ProRes from interlaced
  4:2:0 still goes through FFmpeg's conversion: a follow-up, since changing it
  changes existing output. (Done 2026-11-14, next entry.)
- v210 is ~221 Mbit/s at 720x576 25p and ~1.1 Gbit/s at 1080p25, so it skips
  `+faststart` (a second full pass over the file) and restored audio beside it
  is PCM.
- Found on the way: `DependencyLocator::probe_frame_count` failed on a MOV
  whose stream FFmpeg 9 also prints under a stream group (`125\n125\n`), so a
  job without `totalFrames` encoded one frame. It now takes the first line.

### ProRes converts to its profile's format in the script (2026-11-14)

Follow-up to the v210 entry above: every ProRes profile now gets its stored
format (10-bit 4:2:2, or 4:4:4 for 4444/XQ) from the script's field-aware
`resize`, not from ffmpeg's `-pix_fmt`; the Color Format selection is ignored,
as for v210. Full evidence:
[docs/reports/2026-11-prores-script-chroma/](reports/2026-11-prores-script-chroma/index.html).

- **Interlaced 4:2:0**: an interlaced 4:2:2 clip subsampled per field and
  brought back: chroma PSNR 38.5 → 49.5 dB (U), 41.9 → 52.7 dB (V), the same
  after ProRes 422 HQ. Only when the clip is marked field-based: with no
  detected field order the result equals the old one.
- **Existing output changes** wherever the script now converts, and every
  case measured equal or better: progressive 4:2:0 → 4:2:2 +0.5 dB (OLD vs
  NEW 0.03 levels mean), 4:2:0/4:2:2 → 4:4:4 about +3 dB, 12/16-bit → 10-bit
  RMS error 14-18% lower with zimg's error diffusion (so the dither stays). A
  source already in the profile's format is bit-identical (the block is
  guarded by the format id). An 8-bit selection no longer drops a deeper
  source to 8 bits. No measurable speed cost.
- The warnings judge loss/padding from the source (the selection never
  reaches the encode); the bit-depth warning is silent for ProRes, or every
  ProRes 4444 source (decoded as 12-bit) would warn on every job.

### Sources whose video starts after their audio (2026-11-14)

Report: [docs/reports/2026-11-video-start-offset](reports/2026-11-video-start-offset/index.html).

- **The fault.** An input `-ss` counts from the container's start, which is
  the earliest stream's. On a DVB-T capture the sound starts 1.2 s before the
  first picture, so every seek landed ~30 frames early. On constructed
  fixtures with a 1 s gap (TS, MKV, MP4; `generate_video_start_offset.sh`)
  the preview, the before frame and a trim of 30..59 all showed frame N−25;
  frames 0–25 all showed frame 0.
- **Untrimmed decodes differed by container.** For TS, ffmpeg rebases the
  video to its own first timestamp: no padding, but the sound came out
  **1.01 s late** (the DVB-T clip: 1.2 s), for every job. For MKV/MP4 the
  constant-rate decode led with 25 copies of the first picture; an MP4 (which
  has `nb_frames`) then lost its last 25 pictures to `-frames:v`.
- **The frame count.** Without `nb_frames` the app counted the container's
  duration: 158 frames for the DVB-T clip's 128, 125 for a 100-frame MKV.
  It now counts the video's own duration plus its leading pictures, else the
  container's less the offset.
- **The offset's definition took one correction.** First taken as the
  smallest PTS among the first 64 video packets (the stream's `start_time` is
  the first *packet*, an I picture 0.12 s after three leading B pictures on
  the DVB-T clip). That made `hard_telecine_test.avi` (MPEG-2 in AVI, no
  audio) read 0.067 s: its first two packets carry no PTS. The offset is now
  the earlier of the stream's `start_time` and that smallest PTS, which
  reads 0 there.
- **Keeping sync: delay the picture, copy the sound.** Measured alternatives
  (planning): a stream-copy `-ss` on the sound is off by 0.06–0.30 s and pads
  the video; `-itsoffset` keeps the desync. Re-encoding the sound with an
  exact cut works but loses the sound before the picture. Delaying the
  picture in the encoder (`settb=1/120000`, `setpts`, `-enc_time_base`; at
  the default 1/fps time base the delay rounded to 10 ms off) keeps the
  sound-first layout, losslessly: sync ≤ 0.8 ms in MKV, MP4 and AVI output
  (AVI writes null frames for the gap), copied or restored, trimmed or not.
- **The step and the badge.** "Start the sound with the picture" (Audio
  Restoration) drops the sound before the first picture; it is suggested at
  a gap ≥ 0.25 s (fixtures: 0 or ≥ 1.0 s; ffmpeg's TS muxer leaves 10–21 ms).
  The detected gap is never put into the sync offset, which moves sound
  against picture.
- **Unchanged:** every fixture whose streams start together encodes and
  previews bit-identically (framemd5 of every stream, preview PNG bytes).
- **Not fixed (fixed since by issue #169, entry below):** MPEG-TS seeks that land on a later keyframe, so the DVB-T
  clip's preview and before frame are still off between keyframes (its trim
  30..59 and untrimmed encode are now exact), and past its last keyframe
  (frames 120–127 of 128) the preview is black and the before frame empty;
  before the fix the same fault hit timeline slots 128–157, which held no
  picture at all. An MKV without stream durations whose audio outlasts its
  video still over-counts by the tail.
- **The heavy test** (`integration_video_start_offset_test.dart`) fails 28
  of its 40 cases against the worker from before the fix.


### MPEG-PS/TS seeks started at the next keyframe (issue #169, 2026-11-14)

Report: [docs/reports/issue-169-mpeg-seek](reports/issue-169-mpeg-seek/index.html).

- **The fault.** MPEG-TS and MPEG-PS have no keyframe index, so libavformat
  seeks them by a binary search over timestamps whose `read_timestamp`
  callback indexes every packet as a keyframe. The search stops on a non-key
  packet inside frame N's GOP, and the decoder starts at the *next* keyframe:
  DVD (GOP 12) 10 → 12, 40 → 48; H.264 TS (GOP 25) 10 → 25, 40 → 50; DVB-T
  40 → 56; past the last keyframe, nothing (a black preview, an empty
  Original, a detector sample dropped). Preview, Original, trims, thumbnails
  and detectors were all affected, the preview and the Original often
  together. The trims of the GOP fixtures started at the next GOP.
- **The fix:** `-copyts -ss (T − preroll)` and `trim=start=container_start+T`
  ahead of the PTS reset. The preroll is measured once per source (largest
  keyframe gap + largest PTS − DTS + 0.5 s, at least 1 s, 20 s with under two
  keyframes in the 20 s probe): 1.22 s (DVD fixture), 1.66 s (H.264 TS),
  1.82 s (DVB-T). Only `format_name` `mpegts`/`mpeg` get a plan. Every other
  format's arguments are unchanged byte for byte.
- **`-copyts` is required.** Seeking early and trimming *relative* to the
  seek failed whenever the early seek fell before a late video's first packet
  (or there was no seek): ffmpeg then rebased the frames to the first picture,
  and the trim kept frame 25 for frame 1 on the 1 s late TS.
- **A fixed 0.5 s preroll fails** on 25- and 28-frame GOPs (the measured
  preroll is per file for that reason). 1 s happens to cover every fixture.
  No real broadcast stream with 2–5 s GOPs was tested; a synthetic 1080p TS
  with 2 s GOPs costs 0.071 → 0.155 s per 11-frame preview decode.
- **The DVB-T clip's last 8 pictures** repeat 124 and drop one at every
  preroll and in the untrimmed decode too: the clip's tail timestamps, not
  the seek (task #16's area).
- **Not handled:** raw elementary streams (`.m2v`, `.h264`: no timestamps;
  their seeks are byte guesses), timestamp discontinuities (spliced
  recordings, VOB sets whose clock resets), GOPs longer than the 20 s window.
  Across a backward clock reset a trimmed decode was already wrong. It used
  to start a GOP late and run through the reset. With `-copyts` it starts on
  the right frame and stops at the reset (review: 52 of 150 frames;
  `discontinuity_probe.py`).
  *Fixed since by task #21 (entry below): a source with a reset is decoded
  from a joined copy.*

### AVI seeks landed 1-2 frames early, and frames 1-3 about 1.5 s late (issue #173, 2026-11-14)

Report: [docs/reports/issue-173-avi-seek](reports/issue-173-avi-seek/index.html).

- **Three faults, measured against a sequential decode of every start frame.**
  An AVI's tick is one frame and it stores decode-order timestamps only.
  - **Decoder delay.** With MPEG-2, MPEG-4 ASP or H.264 B-frames, ffmpeg
    stamps display picture k as k + D (D = 1; 2 for H.264). Every seek landed
    D frames early.
  - **Half-tick rounding tie.** `(N - 0.5)/fps` sits exactly on half a tick;
    `%.6f` printed it just below on 1 start in 3, and the trim rounded to
    N - 1. **This hits every NTSC-rate AVI, B-frames or not** (HuffYUV, DV:
    29/90 wrong), not just MPEG-2. 25 fps is exact and safe.
  - **No seek near the start.** ffmpeg starts a seek 3/23 s early when a
    stream has a decoder delay; below 0 the AVI demuxer reports "could not
    seek" and decoding resumes where probing stopped (frame 1 -> 45; H.264
    in AVI: -> 60).
- **Fix.** Seek values are rounded up to the microsecond (`seek_arg`).
  The decoder delay is measured (only when a first packet has no PTS: no
  committed MP4/MOV/MKV/TS fixture has one) and added to every seek; below
  0.5 s a delayed source decodes from the start and trims by count. With
  delay 0 nothing but the rounding changes, and untrimmed encodes of five
  other fixtures are framemd5-identical.
- **The delay moves seeks only**, not `video_start_offset` or the
  output's sync. The untrimmed encode treats stored frame k as time k/fps
  and trims now do the same. Folding it into the start offset would delay
  the picture against the sound in every B-frame AVI.
- **Found on the way: the H.264 AVI's untrimmed encode was wrong too.** Its
  2-frame timestamp gap made rawvideo's constant-rate output start
  `0, 0, 0, 1 …` and lose the last two frames. MPEG-2's 1-frame gap is under
  ffmpeg's duplication threshold. A delayed source now rebases PTS even
  when it doesn't seek (`DecoderSeek::rebase`).
- **Not fixed: the sound.** The same failed seek drops ~1.25-1.3 s of audio
  from a trim whose in-point is under 0.13 s on such an AVI (input `-ss` on
  the audio). A stream-copied soundtrack can't be trimmed by filter, so this
  needs its own mechanism; a follow-up task.
  *(Fixed the same day; see "A delayed AVI cannot seek its sound near its
  start" below.)*
- Rejected: `-fflags +genpts` (the I picture's generated PTS is still 1),
  `-noaccurate_seek`, a fixed +1/fps for every AVI (H.264 is 2, intra 0),
  seeking at `(N - 0.25)/fps` (changes every source's seek and narrows the
  timing-jitter margin), decoding from the start for every AVI seek (O(N)).
- `integration_seek_alignment_test.dart` gains `hard_telecine_test.avi`,
  `avi_h264_bframes.avi` and `avi_ntsc_intra.avi`
  (`generate_avi_seek_test.sh`); the worker from before the fix fails 17 of
  its 38 cases.

### Unblend (SRestore): havsfunc's srestore only decimates on R78; a windowed port (2026-11-14)

Full report with scripts:
[docs/reports/2026-11-srestore/](reports/2026-11-srestore/index.html).

- Requested on the videohelp forum: deblend footage frame-rate converted by
  blending (film on PAL through a standards converter, PAL to NTSC).
- **havsfunc r31's `srestore` is plain decimation on VapourSynth R78.** Its
  detector's history only advances when `FrameEval` is called for the frame
  after the last one (`jmp`); it relied on `std.Cache(make_linear=True)`,
  which R78 ignores ("Critical: … passed through instead"), and its
  `ChangeFPS` requests only the frames it keeps (0, 2, 4, …). `jmp` was true
  0 times in 143 calls at 1 and 8 requests; its picks equal decimation's,
  frame for frame. Never call it.
- `worker/templates/srestore.py` ports upstream's arithmetic line for line
  (300/300 decisions identical to havsfunc driven frame by frame) but makes
  each decision a replay over a fixed window (`UNBLEND_WINDOW` = 48 frames),
  so encode, preview and thread count agree by construction: vspipe `-r 1` vs
  default byte-identical, preview = encode at 42 emulated and 5 real targets.
  Pre-roll can't do this: the phase tracker still disagreed at 36% of frames
  after 160 frames of pre-roll (plan-stage synthetic fixture).
- Recovery on ground-truth fixtures (`generate_blended_test.sh`): film in 50i
  143/143 frames clean (decimation 87), PAL in 59.94i 101/125 (73). The
  window is never below the linear run's clean count at 48; 32 was (141).
- **A preview radius must cover the window index, not just the pixels read**
  (46 back): a radius of 46 mismatched 6 of 22 targets. `FrameMap` radius =
  window + 8, converted to source frames.
- **Pin a clip's cache when many shifted copies read it.** The 49 shifted
  reads of the 1x1 measurement clip made VapourSynth's automatic cache evict
  it, and QTGMC behind it ran 830-894 times for 300 frames (3x the time).
  `std.SetVideoCache(mode=1, fixedsize=1, maxsize=4096)` brought it to 299
  and the pass to within ~2% of QTGMC alone.
- srestore's own `numr/denm` must be the exact target ratio or the job is
  refused (89 of 150 swept pairs pass, including every conversion the pass is
  for; 59.94 → 50 would be 835/1001). `unblend_parameters.rs` ports the
  arithmetic and is tested against the sweep's table.
- It is its own pass right after Deinterlace, not a Frame Rate method: the
  Frame Rate pass runs after denoise, sharpen, grain and resize, which change
  what the detector measures.
- Not tested: a real blended capture (none available), non-macOS platforms
  beyond the nightly run.

### ProRes in MOV: no `+faststart`, PCM for restored audio (2026-11-14)

Follow-up to the v210 entry above. Full evidence:
[docs/reports/2026-11-prores-faststart/](reports/2026-11-prores-faststart/index.html).

- ProRes and v210 are both **editing intermediates**
  (`VideoCodec::is_editing_intermediate`), and both now skip `+faststart` and
  get PCM for a restored track under Passthrough. Field-order flagging
  is decided separately (`field_order_signal`).
- `+faststart`'s second pass on 3 min of ProRes HQ 1080p (191 Mbit/s,
  4.3 GB) added 1.5–6.0 s on an M1 Pro's internal SSD (0.4–1.4 s/GB, median
  ~0.9), after the bar reached 100%. Slow disks were not measured (an
  estimated 10–20 min per hour of HQ on a ~150 MB/s HDD). It shifts the file
  **in place**: the old `uses_faststart` comment's "needs the space twice"
  was wrong.
- A restored track beside ProRes was AAC; an editor re-encodes the soundtrack
  on delivery, so that was two lossy generations. Now `pcm_s16le` (`sowt`),
  ~1.5 Mbit/s stereo. 24-bit PCM for intermediates (the render is f32) is a
  separate, open question. *(2026-11-14: answered — now 24-bit, see the next entry.)*

### 24-bit PCM for an editing intermediate's restored audio (2026-11-14)

Follow-up to the entry above. Full evidence:
[docs/reports/2026-11-intermediate-pcm-depth/](reports/2026-11-intermediate-pcm-depth/index.html).

- The restored track beside ProRes / v210 under Passthrough is now
  `pcm_s24le` (`in24` + `enda` in MOV, `A_PCM/INT/LIT` in MKV,
  `WAVE_FORMAT_EXTENSIBLE` in AVI), via its own `RestoredTrackCodec`;
  `AudioCodec::Pcm` (Convert → PCM, a wire value) stays `pcm_s16le`.
- Measured through the worker's own render (`--audio-plan`), synthetic
  VHS/DV hiss over real speech at −24 dBFS: 16-bit's error is −101 dBFS
  (inaudible), but noise reduction takes DV 16-bit pauses to −92…−118 dBFS,
  where rounding erases 45–100% of their samples, correlated with the signal
  (distortion, not noise); DeepFilterNet's fades to silence lose 41–63% of
  their tail samples (24-bit: 8–14%). TPDF dither adds −93 dBFS noise, as
  loud as or louder than those pauses. 24-bit's error is −143 dBFS.
- No overs in any case (loudnorm's −1.5 dBTP holds even without the
  limiter), so float PCM was not needed.
- The same render as FLAC in MKV (ffmpeg picks s32/24-bit from float) and as
  24-bit PCM in MOV/MKV/AVI decodes bit-identical; AVFoundation reads the MOV
  track sample-identical to ffmpeg. Cost: +0.77 Mbit/s (0.3% of v210 SD,
  5.5% of ProRes Proxy SD).
- The first probe run used music and quiet speech (5 dB SNR) and found ≥ 24
  dB of margin everywhere; corrected in place in the report. Premiere,
  Resolve and Avid were not tested. AVI beside a non-intermediate is now the
  only 16-bit restored track. *(2026-11-15: no longer — see the next entry.)*

### 24-bit restored audio in AVI beside every codec (2026-11-15)

Follow-up to the entry above (task 25). Evidence: F6 of
[docs/reports/2026-11-intermediate-pcm-depth/](reports/2026-11-intermediate-pcm-depth/index.html#f6).

- AVI beside FFV1, HuffYUV, FFVHuff or H.264 now gets `pcm_s24le` for the
  restored track under Passthrough, as MKV already got 24-bit FLAC.
  `RestoredTrackCodec::Pcm16` is gone; no restored track is 16-bit.
  Convert → PCM (`pcm_s16le`) is unchanged and is the way to get 16 bits.
- The question was the readers, not the depth: ffmpeg writes >16-bit PCM in
  AVI only as `WAVE_FORMAT_EXTENSIBLE` (0xFFFE, 24 valid bits, mask 0x3,
  subformat PCM), with no option for a plain 0x0001 header.
- Measured on a GitHub Windows Server 2025 runner (scripts in the report):
  Video for Windows (`AVIStreamRead`), DirectShow (AVI Splitter → Sample
  Grabber, offering `MEDIASUBTYPE_PCM` with the extensible format) and
  Media Foundation's Source Reader return the stored 24-bit samples exactly;
  VirtualDub 1.10.4 (HuffYUV fixture; it has no VfW decoder for FFV1/H.264,
  the 16-bit control fails identically) and VirtualDub2 save them exactly in
  direct copy and full processing. MF starts 96 frames in and VirtualDub2
  pads 960 frames, for the 16-bit control too. VLC 3.0.23 (macOS) reads them
  exactly.
- **ACM refuses 24-bit PCM** (`ACMERR_NOTPOSSIBLE`) whether the header is
  extensible or plain 0x0001, and converts the 16-bit control. So the header
  is not the problem there, and only tools that convert through ACM are
  affected; VirtualDub 1.10.4's own full processing is not one of them.
- Blackmagic's Resolve 16.2 and 20 codec lists document embedded AVI audio
  as Linear PCM 16/24/32-bit. Premiere Pro and Vegas were not tested; forum
  reports (unverified) describe both dropping 24-bit AVI audio.

### A delayed AVI cannot seek its sound near its start (2026-11-14)

Report: [docs/reports/2026-11-avi-audio-seek](reports/2026-11-avi-audio-seek/index.html).
Follow-up to #173.

- **Cause.** ffmpeg starts an input seek 3/23 s early when *any* stream has
  a decoder delay, so `-ss` on the sound of such an AVI below ~0.12 s fails
  even with `-vn`. A trim of `avi_h264_bframes.avi` from frame 2 to MKV had
  its sound start 1.277 s after the picture; in AVI or a WAV the whole track
  shifted 1.28 s early. MOV/MP4 copies of the same streams seek exactly.
- **Fix, one decision** (`source_decode::sound_seek`, rule 9, gated on the
  decoder delay and `COUNT_SEEK_BELOW` like rule 7). Audio Restoration's
  render decodes from 0 and drops the head in its chain, right after
  `aresample=first_pts=0`; an output `-ss` would be applied after the whole
  chain (afftdn's trim, the length fix) and cut in the wrong place. Analysis
  and transcription use an output-side `-ss`. Both exact.
- **The copy encode seeks a NUT copy of the sound.** It can't filter audio
  and routing through Audio Restoration would change the codec under
  Passthrough. NUT keeps 1/sample-rate time bases: exact for PCM and MP3.
  MKA was 9 samples off, an audio-only AVI 5 ms on MP3. Pre-trimming the
  copy at the in-point was worse: ffmpeg rebased its first packet to 0
  (29 ms late).
- **Found: Passthrough trims to AVI run their sound late** by the stream
  copy's pre-roll (the copy starts where the demuxer's seek lands). MKV/MP4
  store it as a later video start and stay in sync; AVI can't. Frame 20:
  667 ms on the fixture, 395 ms on `small_clip.mp4`, with or without this
  fix. Task #24.
- `integration_avi_audio_seek_test.dart` (heavy) uses a chirp copy of the
  fixture's picture (the 440 Hz sine can't show 1.3 s: 572 whole periods);
  11 of 12 cases fail without rule 9, the frame-20 control passes either way.

### MPEG-PS/TS whose timestamps reset mid-file (task #21, 2026-11-14)

Report: [docs/reports/2026-11-timestamp-resets](reports/2026-11-timestamp-resets/index.html).

- **The fault was wider than the trim.** On a TS/PS whose clock goes back
  (a DVD title spanning VOB IDs, a spliced capture) ffprobe's duration covers
  the last segment only, so the app counted 150 of 300 frames and the
  untrimmed encode stopped there too; a seek past the reset is undefined
  (`-ss` searches timestamps that occur once per segment: from 140 the TS
  fixture delivered pictures 290 on); #169's `-copyts` trim stops at it
  (from 100: 52 of 101 frames; from 150 on: none).
- **Fix: a same-container copy without `-copyts`**, made only when the scan
  finds a reset. ffmpeg's discontinuity correction then joins the segments
  with one offset per segment for every stream (sync kept), and every
  decoder, count and seek works unchanged on the copy: 300 frames, every
  start exact, sound within 60 ms of a flash after the reset. A reset is
  ffmpeg's own rule (DTS > 0.1 s back or > 10 s forward, per A/V stream);
  a 5 s drop-out and a 33-bit wrap are not resets.
- **Rejected:** per-segment offsets in every decoder (`-ss` can't reach a
  later segment; copied sound can't be filtered), dropping `-copyts`, an MKV
  copy (`+genpts`, 1 ms timestamps, leaves the TS/PS seek rules). The
  planning measurement that an MKV remux grows quadratically with the number
  of resets did **not** reproduce on the cost probe's segments (0.31 s at 90);
  the rejection rests on the other reasons.
- **Cost:** the scan reads the whole file (~0.1–0.3 s for 30–260 MB; ~1–2 s
  per GB); the copy needs free temp space equal to the source.
- **Found on the way:** the DVD import copies the whole title set (every
  title, every angle, chapters ignored), so its output often has resets; it
  now joins them, and extracting the title alone is a separate task. A PS
  whose last picture has no PTS counts one frame short with or without a
  reset (task #26).
- **Not measured:** how often resets occur in real DVD/DVB material (none on
  the test machine); `reset_survey.py` does it.
