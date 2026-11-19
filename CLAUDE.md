# VapourBox - AI Assistant Guide

## Important: Documentation Maintenance

**Always keep both `README.md` and `CLAUDE.md` up to date when making changes to:**
- Build instructions or dependencies
- Project structure
- Development workflow
- Configuration or setup steps

Both files should stay synchronized - README.md is for humans, CLAUDE.md is for AI assistants.

**This file states current rules.** The investigation, measurements, and dates
behind non-obvious ones live in [docs/ENGINEERING_NOTES.md](docs/ENGINEERING_NOTES.md) —
check it when you need the *why*, are touching an area it covers, or are deciding
whether a similar probe-before-building investigation is warranted before adding
a new filter or plugin.

**Investigations that rest on measurements get a report** in
`docs/reports/<slug>/` (`issue-<N>-<topic>`): a self-contained `index.html`,
captioned screenshots in `img/`, and the scripts that produced every number in
`scripts/`. Write one for any probe-before-building, plugin swap, performance or
quality comparison, whatever the outcome. Then add a short dated entry to
ENGINEERING_NOTES that links to it, and a row to the index in
[docs/reports/README.md](docs/reports/README.md), which holds the full rules
(no personal or scratch paths, no network dependencies, the metric's limits
stated beside the result, corrections left visible).

**[docs/FEATURE_MAP.md](docs/FEATURE_MAP.md) compares VapourBox with other
tools.** When a shipped change alters one of its rows (a new codec, pass,
platform or input), update the VapourBox column in the same change. Change a
competitor's cell only from that tool's own docs, release notes or source, with
the source listed and the "as of" date moved; mark anything unconfirmed ❓,
never a guess. The same rule as "Attribution" below applies.

## Project Overview

VapourBox is a **cross-platform** (macOS + Windows + Linux) video processing application using VapourSynth. It provides a simple drag-and-drop interface for deinterlacing, denoising, sharpening, and other video processing tasks as an alternative to more complex tools like Hybrid.

**Technology Stack:**
- **UI**: Flutter (Dart) - cross-platform desktop app
- **Worker**: Rust - CLI that runs vspipe | ffmpeg pipeline
- **Processing**: VapourSynth + QTGMC (havsfunc)

## Architecture

### Two-Process Design

```
┌─────────────────────────────────────────────────────────────┐
│                    VapourBox                              │
├─────────────────────────────────────────────────────────────┤
│  Flutter App (Dart)         │  Rust Worker (CLI)            │
│  - Cross-platform GUI       │  - Receives job config JSON   │
│  - Settings management      │  - Generates .vpy script      │
│  - Process coordination     │  - Runs: vspipe | ffmpeg      │
│  - Progress display         │  - Reports progress (stdout)  │
└─────────────────────────────────────────────────────────────┘
```

### Communication Protocol

- **Config**: JSON file path passed as CLI argument to worker (`--config path/to/job.json`)
- **Progress**: JSON lines from worker stdout (`{"type":"progress","frame":1234,...}`)
- **Cancel**: SIGTERM (Unix) or TerminateProcess (Windows)
- **Source facts**: `--probe-source <path>` prints the `SourceModel` (task #50)
  — size, rate, frame count, video start, decoder delay, seek plan, grid, VFR
  times, colour tags, Dolby Vision, audio streams, the reset scan. Analysis
  asks with `--defer-scan`, leaving a TS/PS's whole-file reset scan for
  `--complete-source <model>` in the background (task #55). The app
  stores it on `QueueItem.sourceModel` at analysis and sends it in every job
  (inline `source`, or `--source <file>` for previews); the worker probes only
  when a job carries none. **A new source fact goes in the model, computed in
  the worker; the app never probes a source itself** (idet and the
  soft-telecine flags, which look at pictures, are the exceptions). The
  remaining Rust↔Dart twins and why each is kept: [docs/TWINS.md](docs/TWINS.md)

## Project Structure

```
VapourBox/
├── app/                        # Flutter application
│   ├── lib/
│   │   ├── models/             # VideoJob, FilterSchema, ProcessingPreset
│   │   ├── viewmodels/         # MainViewModel, SettingsViewModel
│   │   ├── views/              # MainWindow, DropZone, PreviewPanel
│   │   │   └── settings/       # QTGMC parameter UI sections
│   │   ├── services/           # WorkerManager, PresetService, FilterLoader
│   │   └── widgets/            # Reusable UI widgets
│   ├── assets/filters/         # Built-in filter schemas (JSON)
│   │   └── core/               # Core filters (deinterlace, denoise, etc.)
│   ├── assets/addons/          # Add-on manifests, one JSON per add-on (docs/ADDONS.md)
│   ├── macos/                  # macOS platform config
│   ├── windows/                # Windows platform config
│   └── linux/                  # Linux platform config
│
├── worker/                     # Rust worker crate
│   ├── src/
│   │   ├── models/             # Matching data models (serde)
│   │   ├── script_generator.rs # VapourSynth .vpy generation
│   │   ├── pipeline_executor.rs# vspipe | ffmpeg execution
│   │   ├── progress_reporter.rs# JSON stdout output
│   │   ├── dependency_locator.rs# Find bundled deps
│   │   └── platform/           # Platform-specific code
│   ├── templates/              # VapourSynth script templates
│   └── tests/                  # Integration tests
│
├── deps/                       # Platform-specific dependencies (NOT committed —
│   │                           #   generated by Scripts/download-deps-*; gitignored)
│   ├── macos-arm64/            # Python 3.12, VS, FFmpeg, plugins
│   ├── macos-x64/
│   ├── windows-x64/            # VSPipe, Python 3.8, FFmpeg, plugins
│   ├── linux-x64/              # Python 3.12, VS, FFmpeg, plugins
│   └── linux-arm64/
│
├── licenses/                   # GPL, LGPL, NOTICES
├── docs/                       # BUILDING, FILTER_SCHEMA, ADDONS, ENGINEERING_NOTES, FEATURE_MAP, PITCH_FACTOR_FILES, TWINS, …
│   └── reports/                # Investigation reports (evidence behind decisions)
├── Scripts/                    # Build, package, and release scripts
│   └── models/                 # Model conversion scripts for self-hosted add-on files
└── .github/workflows/          # CI build workflows
```

## Key Files

### Rust Worker
| File | Purpose |
|------|---------|
| `worker/src/models/video_job.rs` | Job config, EncodingSettings, processing passes |
| `worker/src/models/qtgmc_parameters.rs` | All 70+ QTGMC parameters (serde) |
| `worker/src/models/processing_pipeline.rs` | Pipeline passes + `FrameMap` (source↔output frame mapping: `output_count` drives the progress total, `invert`/`total_radius`/`preview_output_in` drive frame-accurate preview, including a decimation's phase) |
| `worker/src/script_generator.rs` | Template substitution for .vpy |
| `worker/src/pipeline_executor.rs` | vspipe \| ffmpeg execution |
| `worker/src/pixel_format.rs` | Source `pix_fmt` → pipe format (see "Source Pixel Formats") |
| `worker/templates/stabilize.py` | Stabilize pass: the weave (`Stab` measured at 16-bit) and the vertical pitch correction (see "Stabilize") |
| `worker/templates/srestore.py` | The Unblend pass: VapourBox's windowed port of srestore (see "Unblend (SRestore)") |
| `worker/templates/plugin_formats.py` | Each limited plugin's format `Contract` and `run_within()`, the one way a pass runs a plugin outside its formats; `pad_around()` / `read_padded()` for a frame size it refuses (see "High Bit Depth Sources") |
| `Scripts/probe-plugin-formats.py` | Runs every plugin call the template makes at every format and size a pass can be handed; writes / checks `Tests/TestResources/plugin_format_table.json` (task #48) |
| `worker/src/models/unblend_parameters.rs` | Unblend's parameters, srestore's ratio arithmetic (`srestore_ratio`) and the refusal wording |
| `worker/src/cpu.rs` | The x86 deps CPU tier (`v3`/`v2`) — the single decision; see "CPU tiers" |
| `worker/src/source_decode.rs` | Decoder ffmpeg args for encode + preview: full stored frame, size-guarded, PTS reset after a seek, invalid colour tags cleared; the video start offset, an AVI's decoder delay, and the one seek decision, `source_seek` / `seek_arg`, the source grid every constant-rate decoder starts on (`decode_start`; see "Source Frame Size", "Colour metadata") |
| `worker/src/dvd_reader.rs` | DVD import: IFO parsing for the title picker, `title_cells` (a title's cells for a chapter range and angle), the copy plan, the NAV walk for interleaved cells, and the libdvdread copy (see "DVD Import") |
| `worker/src/source_model.rs` | `SourceModel` and `--probe-source`: every fact about a source a decoder needs, probed once (the frame-count rules included, an MP4 edit list's discards too); `VideoJob::apply_source_model` fills a job from it, its frame count included |
| `worker/src/source_continuity.rs` | Timestamp resets in an MPEG-PS/TS: the rule (`ResetScanner`, one packet line at a time), `--scan-timestamps` (streamed, with progress), and the continuous same-container copy decoded instead (see "Source Frame Size") |
| `worker/src/vspipe_failure.rs` | A failed encode's blame (encoder first, unless it only saw vspipe's empty pipe) and vspipe's stderr turned into the job error (see Debugging Tips #11) |
| `worker/src/source_timing.rs` | A variable-frame-rate source's stored frames placed on the constant-rate grid (see "Variable Frame Rate Sources") |
| `worker/src/gpu_plugin.rs` | The ncnn-on-Vulkan plugins (RIFE, AI upscaling): file layout, RIFE's model add-on, the `--probe-rife` / `--probe-upscale` probe (on stand-in models, no add-on needed), and the user-facing reason/remedy when they can't run (see "GPU Plugins") |
| `worker/src/animejanai.rs` | AnimeJaNai's add-on models: where they live, which one a job runs, the refusal when they're missing (see "Add-ons") |
| `worker/src/upscale_addons.rs` | The manifest add-on upscalers (Real-ESRGAN anime, Real-CUGAN, Real-ESRGAN General, Live Action SPAN, Real-ESRGAN x4plus/x2plus): which add-on holds which model, each network's own factor (see "GPU Plugins") |
| `worker/src/addons.rs` | Manifest add-ons (compiled in from `app/assets/addons/` by `worker/build.rs`): install state, `require`, `addon_dir` (see "Add-ons", docs/ADDONS.md) |
| `worker/src/ai_runtime.rs` | The AI runtime add-on's `--probe-ai-runtime`: runs the self-test model through `templates/ai_runtime.py`, classifies failures |
| `worker/templates/ai_runtime.py` | ONNX Runtime helpers for passes: `setup`, `session` (provider choice), `map_frames`, NCHW frame conversion, `to_rgbs`/`from_rgbs`, `shifted`, `FrameMemo`, `Runner` |
| `worker/templates/face_restore.py` | The Face Restoration pass: RetinaFace decode, FFHQ alignment, restore, BiSeNet mask, temporal smoothing, bit-exact merge (see "Face Restoration") |
| `worker/src/models/face_restore_parameters.rs` | Face Restoration's parameters, its add-ons per model, and its temporal reach |
| `worker/templates/colorize.py` | The Colourisation pass: model run at a fixed square size, temporal smoothing, Lab/RGB to chroma, luma kept bit-exact (see "Colourisation") |
| `worker/src/models/colorize_parameters.rs` | Colourisation's parameters, its add-on per model, render size and temporal reach |
| `worker/src/comment_metadata.rs` | The source's comment tag, prefixed with the version and passed to ffmpeg as an FFMETADATA file (issue #138) |
| `worker/src/hdr_metadata.rs` | HDR10 mastering display / MaxCLL read from the source for x265 and SVT-AV1, and the Dolby Vision profile (see "HDR Sources and Dolby Vision") |
| `worker/src/native_res.rs` | `--detect-native`: the resolution and kernel a source was upscaled from, for the Descale pass (see "Descale") |
| `worker/src/crop_detect.rs` | `--detect-crop`: black borders, blanking, letterbox bars and the head-switching band, for Crop & Resize's Detect (see "Crop Detection"); also the detectors' shared sampling and decode (`decode_samples`) |
| `worker/src/noise_halo.rs` | `--detect-noise-halo`: a source's noise sigma and halo score, for the pass list's suggestions (see "Noise and Halo Scores") |
| `worker/src/audio_restoration.rs` | Audio restoration: probes, the one `AudioPlan` (every `-af` filter, in order), the render before the encode, and the encoder's audio map/codec args, including the NUT sound copy, the AVI copy cut (`SoundCut`, trimmed or a primed head: `sound_cut_applies`) and the encoder priming for Convert into AVI (`EncoderPriming`) (see "Audio Restoration", "Source Frame Size") |
| `Tests/TestResources/output_capabilities.json` | What each container holds and how it times it: video codec verdicts, Convert and copied audio codecs, the container traits; compiled into the worker (`worker/src/models/output_capabilities.rs`) and generated into the app (`app/lib/models/output_capabilities_table.dart`) (see "Output capabilities: one table") |
| `worker/src/avi_header.rs` | An AVI output's AAC block size raised to its largest packet after the encode (task #41; see "Source Frame Size") |
| `worker/templates/pipeline_template.vpy` | The one VapourSynth script template, for the encode and the preview (see "One script template") |
| `worker/templates/gauss_blur.py` | TCanny's Gaussian blur (`mode=-1`) on `std.Convolution`; never call `tcanny.TCanny` from a template (see "One script template") |
| `worker/tests/filter_integration_test.rs` | Filter integration tests |

### Flutter App
| File | Purpose |
|------|---------|
| `app/lib/models/video_job.dart` | Job config (json_serializable) |
| `app/lib/models/filter_schema.dart` | FilterSchema, ParameterDefinition models |
| `app/lib/models/parameter_converter.dart` | Bidirectional typed ↔ dynamic conversion |
| `app/lib/services/worker_manager.dart` | Process spawning, IPC |
| `app/lib/services/filter_loader.dart` | Load filter schemas from JSON |
| `app/lib/services/preset_service.dart` | Save/load user presets |
| `app/lib/services/timestamp_continuity_service.dart` | Runs the worker's `--probe-source` (deferred scan), `--complete-source` (the scan, cancellable, with progress) and, on a reset, the copy; `ContinuityProxy` is `QueueItem.decodePath` |
| `app/lib/models/source_model.dart` | The worker's `SourceModel` as the app reads it: typed getters over the JSON, sent back unchanged |
| `app/lib/services/temp_directory_service.dart` | Configurable scratch-file directory (see "Temporary Files Directory") |
| `app/lib/services/pitch_factor_file.dart` | Per-video pitch factor files: sidecar lookup + summary (see "Stabilize") |
| `app/lib/services/overwrite_behavior_service.dart` | Default action for existing output files (see "Existing Output Files") |
| `app/lib/models/native_res_report.dart` | What `--detect-native` found, as the Descale panel's Detect shows and applies it |
| `app/lib/models/crop_detect_report.dart` | What `--detect-crop` found, and which suggestion (`CropApply`) the panel applies |
| `app/lib/models/noise_halo_report.dart` | What `--detect-noise-halo` measured; stored on `QueueItem.noiseHalo`, read by `relevanceFor` |
| `app/lib/views/pass_settings/crop_detect_panel.dart` | Crop & Resize's Detect borders panel: findings, Apply crop / Crop the bars too / Repair the band instead |
| `app/lib/services/addon_service.dart` | Every optional third-party download (Whisper, AnimeJaNai): catalogue, install with requirements, remove with dependants (see "Add-ons") |
| `app/lib/services/manifest_addon.dart` | `AddonManifest` + `ManifestAddonInstaller`: the generic installer for `app/assets/addons/*.json` (docs/ADDONS.md) |
| `app/lib/models/audio_restoration_parameters.dart` | The Audio Restoration pass (`ProcessingPipeline.audio`, `PassType.audioRestoration`) and the DeepFilterNet add-on prompt |
| `app/lib/models/ai_runtime_status.dart` | The worker's `--probe-ai-runtime` result |
| `app/lib/models/face_restore_parameters.dart` | Face Restoration's parameters and the add-ons each model needs (`faceRestoreAddonIds`) |
| `app/lib/models/colorize_parameters.dart` | Colourisation's parameters and the add-on each model needs (`colorizeAddonSelectedBy`) |
| `app/lib/models/color_tags.dart` | FFmpeg's accepted colour-tag lists (twin of `color_metadata.rs`) and `decodeNeutraliser`, the filter that clears invalid tags before the app's decodes |
| `app/lib/models/hdr_display.dart` | The display tone-map for the app's own source decodes (twin of `ColorMetadata::display_tonemap_filter`) and Dolby Vision detection |
| `app/lib/models/gpu_plugin_status.dart` | The worker's GPU-plugin probe results, and the panels' notice decision |
| `app/assets/filters/core/*.json` | Built-in filter schema definitions |

## Build Commands

### Prerequisites
- Flutter SDK, stable channel — `app/pubspec.yaml` requires Dart SDK `^3.6.2`, so Flutter 3.27.4+
- Rust stable (worker is edition 2021; CI uses `dtolnay/rust-toolchain@stable`)
- Windows: Visual Studio Build Tools with C++ workload, plus **7-Zip** at
  `C:\Program Files\7-Zip\7z.exe` — `download-deps-windows.ps1` skips the `.7z`
  plugins (mvtools, nnedi3cl, znedi3, …) with a warning if it's missing
- macOS: Xcode Command Line Tools
- Linux: `clang cmake git ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev`

### Download Dependencies

> **Required before building/running locally.** Dependency binaries are **not**
> committed to the repo — they are reproduced entirely by these scripts from
> upstream release URLs, and CI (`build-deps-*.yml`) is the source of truth. Run
> the script for your platform once to populate `deps/` (gitignored). Re-run after
> the relevant `download-deps-*` script changes.

```bash
# macOS arm64 (native, on Apple Silicon)
./Scripts/download-deps-macos.sh

# macOS x64 (native, on an Intel Mac): same script — uname -m reports x86_64 so
# it targets deps/macos-x64. FFmpeg comes pre-built from martin-riedl.de, most
# plugins from Stefan-Olt; descratch/neo-f3kdb/nnedi3cl/vivtc/fmtconv build
# from source.
./scripts/download-deps-macos.sh
# x64 deps can NOT be built on Apple Silicon any more: Homebrew's installer
# refuses to create the Intel prefix under Rosetta. Use CI, or unzip a
# published/artifact macos-x64 bundle into deps/macos-x64.

# Windows (PowerShell)
.\Scripts\download-deps-windows.ps1

# Linux
./Scripts/download-deps-linux.sh

# Any x64 platform, older-CPU tier (see "CPU tiers"); switching tier in an
# existing deps/<platform> needs --force (Windows: delete it first)
./Scripts/download-deps-linux.sh --force --tier v2
```

Both macOS architectures are produced in CI by `build-deps-macos.yml` (arm64 on
`macos-15`, x64 natively on `macos-15-intel`), and every x64 platform's
workflow builds both CPU tiers.

### Build Rust Worker

```bash
cd worker
cargo build --release
```

### Build Flutter App

**Windows:**
```bash
cd app && flutter pub get && flutter build windows --release
```

**macOS:**

> **Important**: The macOS build requires arm64-only targeting. Standard `flutter build macos` may fail with "Unable to find module dependency" errors — use the manual xcodebuild process if so.

```bash
cd app && flutter pub get && flutter build macos --release
```

**Manual xcodebuild (if flutter build fails):**
```bash
cd app/macos
rm -rf Pods Podfile.lock && pod install
xcodebuild -workspace Runner.xcworkspace -scheme Pods-Runner -configuration Release build ONLY_ACTIVE_ARCH=NO
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
mkdir -p ../build/macos/Build/Products/Release
cp -R ~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/Release/vapourbox.app ../build/macos/Build/Products/Release/
```

**Linux:**
```bash
cd app && flutter pub get && flutter build linux --release
```

### Generate Dart JSON Serialization

```bash
cd app
dart run build_runner build
```

---

## Development vs Production Builds

### Worker Build Types

| Build | Command | Dependency Search | Use Case |
|-------|---------|-------------------|----------|
| **Debug** | `cargo build` | Searches upward from executable for `deps/` | Development |
| **Release** | `cargo build --release` | Only checks known production paths | Production |

**IMPORTANT**: During development, always use **debug** builds of the worker. The upward search is restricted to debug builds for security — a malicious `deps/` folder in a parent directory could inject compromised binaries in release mode.

### Development Workflow

**macOS: Always use the debug script:**

```bash
./Scripts/run-debug-macos.sh            # Full build (worker + app) and launch
./Scripts/run-debug-macos.sh --skip-worker  # Rebuild app only
./Scripts/run-debug-macos.sh --skip-app     # Rebuild worker only
./Scripts/run-debug-macos.sh --run-only     # Just copy and launch
```

**Windows (manual):**

1. Build worker: `cd worker && cargo build`
2. Copy worker: `cp worker/target/debug/vapourbox-worker.exe app/build/windows/x64/runner/Debug/`
3. **Copy the templates too**: `cp worker/templates/*.vpy worker/templates/*.py app/build/windows/x64/runner/Debug/templates/`
4. Run app: `cd app && flutter run`

> Step 3 is not optional and it fails silently. `exe_dir/templates` is the
> **first** path `ScriptGenerator` searches, so the copy sitting next to the
> debug exe **shadows** `worker/templates/` — a `.vpy` change you just made has
> no effect on the running app, with no error to suggest why. Anything that
> edits a template must re-copy, or delete `Debug/templates/` so the upward
> search finds the repo's copy.

**Linux: Use the debug script:**

```bash
./Scripts/run-debug-linux.sh            # Full build (worker + app) and launch
./Scripts/run-debug-linux.sh --skip-worker  # Rebuild app only
./Scripts/run-debug-linux.sh --skip-app     # Rebuild worker only
./Scripts/run-debug-linux.sh --run-only     # Just copy and launch
```

### Production Packaging

**IMPORTANT**: Never manually assemble a release build. Always use packaging scripts — the app will silently crash on video drop if the bundle is incomplete.

```bash
# macOS
./Scripts/package-macos.sh --version X.Y.Z [--skip-build]

# Windows — writes an installer (-setup.exe) and a zip of the same tree
.\Scripts\package-windows.ps1 -Version "X.Y.Z" [-SkipBuild] [-SkipInstaller]

# Linux — writes an AppImage (+ its .zsync) and a tarball of the same tree
./Scripts/package-linux.sh --version X.Y.Z [--skip-build] [--skip-appimage]

# Test packaged app from terminal to see errors:
# macOS:
dist/VapourBox.app/Contents/MacOS/vapourbox
# Linux:
dist/VapourBox-X.Y.Z-linux-x64/vapourbox
```

Do NOT run `app/build/macos/Build/Products/Release/vapourbox.app` directly — it lacks templates and proper bundle structure.

## Common Tasks

### Adding a New Filter (Full Pipeline Checklist)

Adding a filter touches many files. Missing any step causes silent failures (filter not appearing, parameters not saved, preview errors). Follow this checklist completely:

**1. Filter Schema & Registration**
- Create JSON file in `app/assets/filters/core/<filter_id>.json`
- **Add to `app/assets/filters/manifest.json`** — filters won't load without this
- **Field reference: [docs/FILTER_SCHEMA.md](docs/FILTER_SCHEMA.md)** — every key,
  which are required, and the ones that look plausible but are silently ignored
- Closest existing examples: `dehalo.json` (multi-method), `spotless.json` (minimal)

**2. Rust Model & Pipeline**
- Create `worker/src/models/<filter>_parameters.rs` with serde `rename_all = "camelCase"`
- Register in `worker/src/models/mod.rs` (both `mod` and `pub use`)
- Add field to `ProcessingPipeline` struct in `worker/src/models/processing_pipeline.rs`
- Add to `PassType` enum + `display_name()` + `description()` + `Default` + `from_legacy()` + `enabled_passes()` + `enabled_pass_count()` + `is_pass_enabled()`

**3. VapourSynth Templates & Script Generator**
- Add template block to `worker/templates/pipeline_template.vpy` — the one
  template, used by the encode and the preview alike (see "One script
  template"); mark encode-only or preview-only lines, never copy a block
- Add pass handling in `worker/src/script_generator.rs`
- Every keyword argument must be one the called function takes, in the
  bundle: `template_call_arguments_test.dart` checks each `haf.*` call against
  havsfunc's signatures and each `core.<ns>.<fn>` call against the loaded
  core's (task #42 found two QTGMC arguments that failed every encode)

**4. Dart Model & Pipeline**
- Create `app/lib/models/<filter>_parameters.dart` with `@JsonSerializable()`
- Run `dart run build_runner build` to generate `.g.dart`
- Add to `app/lib/models/processing_pipeline.dart`: import, `PassType` enum, `displayName`, `description`, field, constructor, `fromLegacy`, `enabledPasses`, `enabledPassCount`, `videoPassCount`, `isPassEnabled`, `getPassSummary`, `copyWith`, `togglePass`

**5. Parameter Converter (ALL THREE locations)**
- Add `fromX()` and `toX()` in `app/lib/models/parameter_converter.dart`
- Add to `fromPipeline()` map
- Add to `toPipeline()` construction

**6. UI Wiring (ALL FIVE locations — missing any causes silent failures)**
- `app/lib/views/pass_list/pass_list_panel.dart` — add a `row()` case **and** put
  the pass in a `PassListPanel.stages` entry. A `PassType` absent from `stages`
  renders nothing at all — no error, the pass is simply unreachable.
  `pass_list_stages_test.dart` fails if one is missed. Stages are labels over the
  **existing pipeline order**, so a pass goes in the stage its position already
  falls in; never reorder rows to suit a grouping.
  The README's "The filter pipeline" table is the user-facing statement of the
  same order — add the pass's row at its position there too;
  `readme_pipeline_order_test.dart` fails if the table and `stages` disagree.
- `app/lib/views/pass_list/pass_list_item.dart` — add icon in `_getIconForPass()`
- `app/lib/views/pass_settings/pass_settings_inline.dart` — add case in `_getFilterId()`
- `app/lib/viewmodels/main_viewmodel.dart` — add case in BOTH `_convertToParams()` AND `_updatePipelineFromDynamic()`

**7. Optional Parameter Defaults**
- If parameters should default to OFF (not passed to VapourSynth), the `fromX()` converter must put values in `lastOptionalValues` instead of `values`. Otherwise the UI shows all optional params as enabled.
- Example: `DynamicParameters(filterId: 'x', enabled: true, values: {}, lastOptionalValues: {'param1': 5})`

**8. VapourSynth Compatibility Guards**
- **Add the call to `CALLS` in `Scripts/probe-plugin-formats.py`** (with the
  template's arguments) and re-run it with `--out` on the table
  (`plugin_format_contracts_test.dart` fails on a template call the probe
  doesn't list). If the table shows it refusing a depth or subsampling a pass
  can be handed, add a `Contract` to `worker/templates/plugin_formats.py` and
  call it through `_pf.run_within(clip, '<ns.Fn>', fn, label='<Pass>')`
  (test_252 fails on a contracted plugin called any other way). A frame
  size the plugin refuses (a 4:2:0 height 2 mod 4, a width 2 mod 4) is a
  Contract's `width_step` / `height_step` (luma samples, or `CHROMA`):
  `run_within` pads to it with `pad_around` and crops back (tasks #56, #57),
  with `field_based_only=True` when the plugin refuses it only
  field-flagged. A refusal no contract expresses (a field flag) is handled
  in the pass and explained in `plugin_formats.HANDLED`, or filed as a task
  and listed in `plugin_formats.KNOWN` until it is. **Anything that reaches
  MVTools' Compensate, Degrain or BlockFPS with an overlap** (directly or
  through havsfunc / a vendored module) goes through
  `_pf.mvtools_blocks(clip, fn)` (test_256): MVTools picks the overlap
  window with `(by + nBlkY - 3) / (nBlkY - 2)`, so a picture two block rows
  tall is SIGFPE on x86 and silently 100+ levels off on arm64, and one block
  row or column is that far off everywhere; the helper pads a picture under
  64x96 (task #56 F9). Check on a fixture with real low
  bits that the plugin leaves the samples it doesn't change exact — see
  "High Bit Depth Sources"
- If any parameter is a **level, threshold or offset expressed in 8-bit units**
  (which is how the UI presents them), scale it to `clip.format` *in the script*.
  A filter working in the clip's own range is silently wrong on a 10-bit source
  otherwise, with no error to go on
- Add the plugin's **namespace** to the required list in
  `app/test/vapoursynth_integration_test.dart`, or a deps bundle missing it will
  pass CI and fail at job time
- If the plugin fails on field-based clips, note this — the template sets field-based via `{{#SET_FIELD_BASED}}`, emitted whenever `ScriptGenerator::field_based_for` returns a value (see "Field Order" below)
- **Probe the bundled plugin before wiring it up** — run it against `deps/` at
  8/10/12/16-bit, check its argument vocabulary matches the VapourSynth port (not
  the AviSynth one), and check its own defaults actually do something. A plugin
  that looks like a one-line win on paper has repeatedly turned out to have a
  format restriction, a broken default, or an Avisynth-only argument that only a
  real run against the bundle reveals — see docs/ENGINEERING_NOTES.md for the
  specific traps found this way.

**9. Integration Tests** — required, BOTH suites (see "Integration Tests for Filter Changes" below):
- Add a numbered Rust test in `worker/tests/filter_integration_test.rs`.
- Update the Flutter integration tests in `app/test/integration_*_test.dart`: add
  script-generation param coverage to `integration_filter_parameters_test.dart`
  (assert the new pass's call + key params appear in the generated `.vpy`), and a
  full-encode smoke test for the new pass in `integration_new_passes_test.dart`
  (or another `@Tags(['heavy'])` file). These now run in CI.
- The generated format sweep (`integration_format_sweep_test.dart`, see
  "High Bit Depth Sources") picks a new pass, method or `implementation`
  entry up by itself: update its count in `expectedVariantCounts`
  (`format_sweep_cases_test.dart`), classify a new `PassType` in
  `sweepClassOf`, add an `actuationOverrides` entry only if the pass is inert
  at its defaults (the sweep fails "changed nothing" otherwise), and a
  `deltaOnly` row if it wraps a low-depth plugin (`WorkDepth`) or promises
  untouched planes.

**10. Plugin Binaries**
- Add a download/build block to each `Scripts/download-deps-*` script (deps
  binaries are **not** committed — the scripts are the source of truth). Before
  planning an addition, check whether the plugin's *newest* release ships a
  Windows binary (`gh api repos/<owner>/<repo>/releases`) — Windows has
  essentially no from-source path, so every platform must pin the version
  Windows can get. Also check PyPI (`pypi.org/pypi/<name>/json`): several
  plugins have migrated to publishing wheels there instead of GitHub releases.
- **Add the plugin filename to `Scripts/deps-expected-plugins.json`** for every
  platform that ships it (a file outside the plugin directory, like RIFE's in
  `vapoursynth/rife/`, goes under `_extraFiles` as a path from the bundle root). The `package-deps-*` scripts assert this list is
  present before zipping and fail the build if any are missing, so a dead
  download URL becomes a red build instead of a silently-incomplete bundle.
  x64 platforms have a second key per CPU tier (`macos-x64-v2`, …) that must
  list the same plugins — `attribution_test.dart` asserts it. **If the plugin
  is built differently for the v2 tier, also add its path to `_tierFiles`** in
  the same file: that list is the entire content of the published v2 delta, so
  a tier-specific plugin missing from it ships as its v3 build to older CPUs.
- **Check it for load-time SIMD on x64** (see "CPU tiers" below): a prebuilt
  x86 binary built with `-mavx2`-style flags can SIGILL inside `dlopen` on an
  older CPU, and autoload makes that every job. Run
  `Scripts/check-load-time-simd.py` on a macOS dylib; the v2 gates in the
  `build-deps-*` workflows cover all three platforms.
- For local testing, run the download script to populate `deps/` (e.g.
  `deps/windows-x64/vapoursynth/vs-plugins/`, `deps/macos-arm64/vapoursynth/plugins/`).
- **Credit it**: add an entry to `licenses/NOTICES.txt` and a `_ComponentTile`
  to `app/lib/views/about_dialog.dart`, then map the binary's filename in
  `app/test/attribution_test.dart` — that test fails until all three exist.
  Take the copyright holder and licence from upstream, never from the handle or
  the repo owner (see "Attribution" below).
- **A copied `download-deps-*` block does not port as-is** — macOS and Linux use
  different env var names for the VapourSynth include dir (`$VS_INC_DIR` vs
  `$VS_INCLUDE_DIR`), different pkg-config wiring, and macOS needed a
  `vapoursynth/` include-farm subdirectory added for parity with Linux's. Check
  all four before assuming a block copied from one platform's script works on
  another; see docs/ENGINEERING_NOTES.md for the specific failures.

### Regenerating the App Icon

`Scripts/generate-app-icon.swift` is the vector source of truth — it draws the
icon with CoreGraphics at whatever size you ask for, so no ImageMagick or
librsvg is needed (and every size is drawn at its own scale rather than
downsampled from one bitmap). `Scripts/generate-app-icons.sh` drives it at the
sizes each platform wants, packs the Windows `.ico` in pure Python, and writes
the Linux AppImage icon (`packaging/linux/app.vapourbox.VapourBox.png`):

```bash
./Scripts/generate-app-icons.sh     # macOS only; needs Swift from the Xcode CLT
```

The generated PNGs and `.ico` **are committed**, because Xcode's asset catalog
and the Windows resource compiler read them at build time. Re-run the script
after editing the design, and rebuild to see it: macOS caches icons
aggressively, so `run-debug-macos.sh` (which replaces the whole bundle) is the
reliable way to check.

`--style macos` insets the artwork in a rounded body per Apple's icon grid;
`--style square` is full-bleed for Windows and Linux, which draw no mask of
their own. The design rationale — and two rejected concepts, so they are not
tried again — is in the renderer's header comment.

> **Audit the presets whenever a pass ships.** A shipped pass is easy to forget
> to wire into any built-in preset, which means it never gets used by a normal
> user. When adding a pass, check whether an existing preset named after the
> source it targets (e.g. a film-scan preset and a Stabilize pass) should turn
> it on.

### Adding a New Built-in Preset

1. Edit `app/lib/models/processing_preset.dart`
2. Add a `static ProcessingPreset builtInX()` factory beside the existing ones
   (`builtInFast()`, `builtInVhsCleanup()`, …), with `isBuiltIn: true` and an
   `id` of the form `builtin-x`
3. Configure `pipeline` with the desired filter settings and `encodingSettings`
4. Add it to the list returned by `ProcessingPreset.builtInPresets()` — nothing
   picks it up otherwise
5. Assert in `app/test/processing_preset_test.dart` that it does what its **name**
   says.

> **`ProcessingPipeline()`'s default deinterlaces.** `QTGMCParameters.enabled`
> defaults to **`true`**, so a preset that simply doesn't mention deinterlacing
> gets it anyway — which on a progressive source (a film scan) just softens the
> picture for no reason. Pass `deinterlace: QTGMCParameters(enabled: false)`
> explicitly when you don't want it.
>
> **A `preset:` enum on its own is only a label.** `NoiseReductionParameters(
> preset: NoiseReductionPreset.light)` leaves every threshold at its default, so
> "light" denoises exactly as hard as "moderate". Use the
> `NoiseReductionParameters.fromPreset(...)` factory, which applies the matching
> values.

**Name presets after the source, not the technique.** The user knows they
captured a DV tape; they don't know it wants SMDegrain with a chroma-bleed fix.
That is why the set includes `DV Camcorder Tape`, `PAL DVD / Broadcast`,
`Anime DVD`, `8mm / Super 8 Film Scan`, `Low-Light Phone / Camera Video` and
`SD Tape → HD (YouTube / TV)` alongside the three quality tiers.

**Set `category`.** `PresetCategory.quality` for a speed/quality tier,
`PresetCategory.source` for one shaped around a kind of source; the menu in
`main_window.dart` groups on it ("For Your Source" / "Quality Only"). One that
omits it defaults to `custom` and files itself under the source presets, so
`processing_preset_test.dart` asserts every built-in declares one.

### Adding a New QTGMC Parameter

1. Add to `worker/src/models/qtgmc_parameters.rs` (with serde attributes)
2. Add to `app/lib/models/qtgmc_parameters.dart` (with json_annotation)
3. Add to `worker/templates/pipeline_template.vpy` using `{{#PARAM}}...{{/PARAM}}` syntax
4. Add to `worker/src/script_generator.rs` substitution logic
5. Add UI control in Flutter settings view
6. **Add integration test** in `worker/tests/filter_integration_test.rs` (see below)

### Integration Tests for Filter Changes (Required)

**Every filter addition or parameter change must update BOTH integration suites — they both run in CI:**

1. **Rust** — a numbered test in `worker/tests/filter_integration_test.rs` (patterns below).
2. **Flutter** — `app/test/integration_*_test.dart`:
   - Add script-generation coverage to `integration_filter_parameters_test.dart`
     (or `integration_qtgmc_parameters_test.dart` for QTGMC): enable the pass with
     explicit non-default values and assert its VapourSynth call + those params
     appear in the generated `.vpy` (see the `descratch`/`spotless` tests for the
     pattern). These are script-only (no encode) and run in the **per-push gate**.
   - Add a full-encode smoke test in `integration_new_passes_test.dart` (or another
     `@Tags(['heavy'])` file): run the worker end-to-end and assert a valid output
     (e.g. via `WorkerHarness.firstStream`). `heavy` tests run in **nightly.yml**,
     not the push gate.

All Flutter integration tests share `app/test/support/worker_harness.dart`, which
resolves the worker + deps cross-platform and **downloads the pinned deps release
if `deps/<platform>` is absent** (honoring `$VAPOURBOX_DEPS_DIR`). Call
`await WorkerHarness.ensureReady()` in `setUpAll`.

**Rust patterns** — every filter/parameter change must include a numbered test in `worker/tests/filter_integration_test.rs` (e.g., `test_50_chroma_shift`).

Two test patterns are used:

1. **`run_job`** — verifies the full pipeline compiles and generates a valid script:
   ```rust
   #[test]
   fn test_50_chroma_shift() {
       create_output_dir();
       let mut job = create_base_job("test_50_chroma_shift");
       job.qtgmc_parameters.enabled = true;
       job.qtgmc_parameters.preset = QTGMCPreset::Fast;
       job.qtgmc_parameters.tff = Some(true);
       job.processing_pipeline = Some(ProcessingPipeline {
           deinterlace: job.qtgmc_parameters.clone(),
           chroma_fixes: ChromaFixParameters {
               enabled: true,
               apply_chroma_shift: true,
               chroma_shift_h: 2.5,
               ..ChromaFixParameters::default()
           },
           ..ProcessingPipeline::default()
       });
       run_job(&job, "Chroma Shift").unwrap();
   }
   ```

2. **`run_job_and_verify`** — additionally checks the generated `.vpy` script contains expected strings:
   ```rust
   run_job_and_verify(&job, "Chroma Shift", &[
       "ShufflePlanes",
       "resize.Spline36",
       "2.5",
   ]).unwrap();
   ```

Use `run_job_and_verify` when you want to confirm specific VapourSynth function calls or parameter values appear in the generated script.

### Modifying Worker Communication

1. Update `WorkerMessage` enum in both `worker/src/models/progress_info.rs` and `app/lib/models/progress_info.dart`
2. Update JSON serialization to match
3. Update `ProgressReporter` (Rust) and `WorkerManager` (Dart)

---

## Filter Schema System

Built-in filters are defined as JSON schemas in `app/assets/filters/core/`, listed
in `app/assets/filters/manifest.json`. See existing filters for full examples.

Full field reference: **[docs/FILTER_SCHEMA.md](docs/FILTER_SCHEMA.md)**.

> **User-supplied filters are not a supported feature.** `FilterRegistry` still
> scans `~/.vapourbox/filters/` and `FilterLoader` still exposes
> `installFilter()`, but that path was never finished and must not be offered to
> users or mentioned in the README. The schema itself is the internal format for
> **built-in** filters and is documented as such.

```json
{
  "$schema": "https://vapourbox.app/schemas/filter-v1.json",
  "id": "my_filter",
  "version": "1.0.0",
  "name": "My Filter",
  "description": "What this filter does",
  "category": "cleanup|enhancement|color|custom",
  "methods": [{ "id": "...", "name": "...", "function": "...", "parameters": [...] }],
  "parameters": {
    "enabled": { "type": "boolean", "default": false, "ui": { "hidden": true } },
    "param1": {
      "type": "number", "default": 1.0, "min": 0.0, "max": 10.0, "step": 0.1,
      "optional": true,
      "vapoursynth": { "name": "vs_param_name" },
      "ui": { "label": "...", "description": "...", "widget": "slider", "precision": 1 }
    }
  },
  "ui": { "sections": [{ "title": "Settings", "parameters": ["param1"], "expanded": true }] }
}
```

**Parameter types**: `boolean`, `integer`, `number`, `string`, `enum` (with `options` array).
**Widgets**: `slider`, `dropdown`, `checkbox`, `textfield`, `number`.
**`optional: true`**: Shows enable checkbox; when disabled, parameter is omitted (uses VS default).
**`visibleWhen`**: Conditional visibility, e.g. `{ "method": ["method_a"] }` — only
works when declared **inside a parameter's `ui` block**, not on `ParameterDefinition`
or `UiSection` directly (both silently drop it if written one level up).
`filter_schema_curation_test.dart` lints for this both ways: nothing may declare
`visibleWhen` outside `ui`, and every condition must name a parameter/method the
filter actually has.

**`sinceAppVersion`** (filter-level, per-parameter, per-method, or per enum
option via `optionSinceAppVersion`, e.g. `"1.2.0"`): tags
when a filter or parameter shipped, purely so `WhatsNewService` can draw a
"NEW" badge next to it — persisting across every launch of the current app
version, and only advancing on the next real update, not clearing after one
run. A patch-only update (1.5.0 → 1.5.1) is not one: the baseline moves only
when major or minor changes, so a bugfix release keeps the feature release's
badges. **Stamp it in the same change that adds or modifies the property, using
the version that change will actually ship in** (a minor bump on the latest
public release, or whatever's already in `app/pubspec.yaml` if that's ahead)
— not retroactively at release time, which is exactly how properties get
missed. Never touch the stamp on anything already shipped — see "NEW badges"
in [docs/FILTER_SCHEMA.md](docs/FILTER_SCHEMA.md). **Stamp only what is new**
(the option, not the parameter it was added to; never a hidden parameter):
every control leading to it badges automatically — its dropdown, the switch
that reveals it, its section, the pass row, and for a new Settings tab the
Settings button.

Several ongoing rules for schemas and the panel that renders them, each guarded by
`filter_schema_curation_test.dart` unless noted — see
docs/ENGINEERING_NOTES.md for the audits that found violations of each:

- **A method dropdown must gate something.** If no parameter is conditional on
  `method` (and the model has no `method` field), the dropdown is inert — remove
  it rather than leave a control that changes nothing.
- **A parameter used by only some methods must be gated to those methods.**
- **No section may consist solely of the `method` control** — the panel already
  draws the dropdown itself and skips it, so such a section renders nothing;
  give every section a title naming the filter/repair it configures.
- **No shipped schema may offer more than 4 methods in simple mode**; the first
  method is never `advancedOnly` (it's the resolved default); every method needs
  a description (the only guidance the dropdown shows).
- **`FilterSchema.visibleMethods` always keeps the currently selected method**,
  advanced-only or not, so a preset-selected method is never hidden out from
  under a `DropdownButtonFormField`.
- **Every pass prints the VapourSynth call(s) it makes, in advanced mode only**
  (`ui.sections` gates it the same way as other advanced-only content). A
  single-method pass shows the method's own `function`; a composite pass (e.g.
  Colour Correction, Chroma Fixes, Crop & Resize) declares an `implementation`
  list gated per-entry by `activeWhen`, showing the whole repertoire with the
  active calls emphasised. A method's `function` must never be blank, and
  `"function": "custom"` must be explained by an `implementation` list.

**`copyWith` silently resets any field it forgets.** `ProcessingPipeline.togglePass`
rebuilds a pass through `copyWith`, so a parameter field added to a model but not
to its `copyWith` reverts to its default the moment the pass is toggled off and
on — compiles fine, runs fine, silently does the wrong thing. When adding a field
to a parameter model, `copyWith` is a required third edit alongside the
constructor and `fromJson`/`toJson`. `app/test/parameter_copy_with_test.dart`
checks this two ways (round-trip every field, and statically assert every
`final` field appears in the `copyWith` body) because a string/enum field can't
be perturbed through the round-trip check alone.

**A preset is the main route by which a setting the user cannot see gets
enabled.** The panel hides a parameter whose `visibleWhen` is unsatisfied and
skips one no section lists — so a preset can turn on a filter with no reachable
control. `app/test/preset_visibility_test.dart` walks every built-in preset's
enabled passes through the real converter and fails if a non-default value isn't
reachable in that preset's own state (an allowlist covers a handful of
deliberately advanced-only QTGMC values).

**Frame counts and geometry are verified against the running pipeline, not just
the model.** `run_job` in the Rust suite only generates and inspects the
`.vpy` — it never proves the plugins agree with `FrameMap`'s arithmetic or that a
preview frame matches its labelled source frame. `integration_frame_mapping_test.dart`
and `integration_upscale_resize_test.dart` (both heavy) encode real jobs and count
output frames / diff pixels for exactly this reason — see docs/ENGINEERING_NOTES.md
if you're touching `FrameMap`, trim/frame-count plumbing, or crop/resize geometry,
since the "obviously correct" arithmetic has been wrong in ways only an actual
encode caught.

**Advisory UI (`pass_relevance.dart`, `pass_advice.dart`) must stay advisory.**
Neither may block a job, disable a control, or change a value — they only badge
suggestions and warn about pass *combinations* (e.g. sharpening a pass the
denoiser will undo). Advice must only ever attach to an **enabled** pass, and a
default pipeline must be completely silent — both are asserted in
`pass_advice_test.dart` / `pass_relevance_test.dart`.

**Subtitles: transcribe first, mux last.** The pipeline order is
`render restored audio (if on) -> transcribe -> encode (burning in if asked) ->
mux as a post-pass`, and it is load-bearing: burn-in needs the transcript before
the encoder runs; muxing needs the encoded file to exist first. **Transcription
must hear exactly the output's soundtrack.** With Audio Restoration on, that is
the rendered track (`AudioRestorer::render`), which is the output's audio
sample for sample — trimmed, offset, drift-corrected — so cues follow any
retiming by construction (`integration_audio_restoration_test.dart` checks a
2 s offset moves the cues ~2 s). Without it, transcription reads the same
trimmed window the encode uses (`extract_audio_range`), or cues drift by exactly
the trimmed-off head; that is safe because nothing *else* retimes audio (IVTC
and frame-rate conversion change the video timeline only). Any new step that
moves audio in time belongs in `audio_restoration`, never in the encode.
(The encoder's delay of a late-starting picture, `output_video_delay`, is not
an exception: it keeps the source's own timing and moves no audio.)
`SubtitleOutput::{burns_in, muxes, keeps_srt_file}` are asserted to cover every
mode, so a mode that does none of the three can't silently produce nothing.

**FFmpeg's `-vf` chain accumulates into one `Vec<String>` joined with commas —
never push a second bare `-vf`.** ffmpeg only honours the *last* `-vf`, so two
separate pushes (e.g. aspect stamping and subtitle burn-in) would silently drop
the first one's effect. The same goes for `-af`: every audio filter is chosen in
`AudioPlan::new` and each ffmpeg run gets exactly one `-af`; the encode itself
never filters audio (`test_real_ffmpeg_builder_delegates_audio_to_audio_restoration`).

**Nothing of unbounded length goes on a child process's command line.**
Windows caps it at 32,767 characters and refuses to start the process (os
error 206). The source's `comment` tag is the case that hit it (issue #138: AI
tools store a whole workflow there), so it reaches ffmpeg as an FFMETADATA
file input via `comment_metadata::CommentFile`, in both the encode and the
subtitle mux. `integration_long_comment_test.dart` (heavy) encodes a 40 KB
comment.

**FFmpeg is pinned to one series (currently 9.0) across all four platforms, and
the pin is asserted, not just documented.** Each `download-deps-*` script
verifies the installed binary's series after fetching it, and
`app/test/ffmpeg_version_pin_test.dart` fails if the three scripts' pins
disagree. Pin the **series** against a rolling host tag (e.g. BtbN's
`n9.0-latest`), never an exact old build — a fixed old tag gets garbage-collected
off a rolling `latest` alias and 404s the deps build outright.

**CPU tiers (issue #92): every x86 platform's deps come in two tiers.** `v3`
is built for x86-64-v3 CPUs (Haswell, 2013, and later); `v2` runs on anything
older. From deps 1.13.0 only v3 is a full bundle: v2 is a small **delta**
extracted over it. The rules:

- **One decision, in the worker.** `cpu::cpu_tier()` (`worker/src/cpu.rs`)
  requires the *whole* x86-64-v3 set, not just AVX2. `--probe-cpu` reports it,
  the app downloads by it, and `ctmf_opt` derives from it. Never re-derive the
  tier elsewhere (sysctl is wrong under Rosetta); on x86 an unclear answer means
  `v2`, which only costs speed. `VAPOURBOX_DEPS_TIER=v2|v3` overrides it.
- **The tier lives only in which assets are installed and in version.json.**
  The v3 bundle keeps the plain name (`VapourBox-deps-X-macos-x64.zip`); the v2
  tier is that same bundle plus `…-macos-x64-v2-delta.zip`, extracted over it.
  Either way the result installs to `deps/<platform>`.
  `DependencyManager.installAssetIds` is the one statement of which zips make
  up an install, and `"tierFormat": "delta"` in `deps-version.json` is what
  selects this (absent = the 1.11.0–1.12.0 scheme of a second full
  `…-x64-v2.zip`). The app re-checks the installed tier at startup
  (`DependencyStatus.wrongTier`) and reinstalls on a mismatch — from the
  bundle, never by patching the installed tree — even when it is newer than
  expected.
- **The delta is the files in `_tierFiles`, nothing else, and it is tied to
  its bundle.** `Scripts/make-deps-delta.py` takes exactly the paths listed
  per platform under `_tierFiles` in `Scripts/deps-expected-plugins.json` from
  a full v2 build. It is deliberately not a diff of the two builds (two builds
  of the same sources are not byte-identical, so a diff names nearly every
  binary); instead it fails if the builds hold different *sets* of paths
  (a pure overwrite could not reproduce v2) or if a tier file is
  byte-identical in both (the tier switch did nothing). The delta's
  `version.json` records `baseSha256`, and both the app and the test harness
  refuse to apply it over any other bundle.
- **No zip's `version.json` is ever extracted by the app.**
  `_writeInstalledVersion` writes that file last, as the commit marker. The v3
  bundle's own copy says `tier: v3`; letting it through would make a v2
  install interrupted before its delta look like a finished v3 one.
- **One `--tier` block per `download-deps-*` script** maps the tier to build
  variables; nothing else in the script branches on it. The two tiers differ
  only where running the bundle on an old CPU proved they must: zsmooth
  (`haswell` / `x86_64_v2`, one build per bundle, autoloaded — upstream has no
  runtime dispatch) everywhere, and on macOS MVTools (v2 builds v24 from source
  with `patches/mvtools-v24-no-avx2.patch`, because Stefan-Olt's build SIGILLs
  in its AVX2 static initializers inside `dlopen`).
- **A v2 delta is gated before it can be published**, against what a v2 user
  ends up with — the v3 bundle with the delta applied, composed by the
  `delta-x64` job of each `build-deps-*` workflow — not against the v2 build it
  was cut from: under Intel SDE by `probe-cpu-compat.yml` (Linux at Westmere;
  Windows at Sandy Bridge, since SDE cannot emulate pre-AVX Windows —
  Microsoft's runtime reads the host's CPU features from the kernel), and on
  macOS statically by `Scripts/check-load-time-simd.py` (once on the v2 build
  inside `package-deps-macos.sh`, again on the composed tree). The full v2
  build is a CI intermediate (artifact `…-x64-v2-build`) and must never reach a
  release; `deps_delta_install_test.dart` asserts no workflow can upload it.
- **CI installs a v2 tier the way the app does.**
  `.github/scripts/install-deps-bundle.sh` is the one place the workflows learn
  that `linux-x64-v2` means "bundle, then delta"; `WorkerHarness._downloadDeps`
  is the same for local test runs. Don't unzip a deps asset in a workflow
  directly.

**CTMF's `opt` (SIMD level) must be chosen by the worker from the CPU, never
left at the plugin's own auto-detect (`opt=0`).** Its AVX-512 kernel for 8-bit
input crashes with an access violation on real hardware — auto-detect is
exactly what selects that broken kernel. `script_generator::ctmf_opt` picks 3
(AVX2) on a v3-tier CPU, else 2 (SSE2), never 0. This is independent of the
tiers: a v3 machine can have AVX-512.

See docs/ENGINEERING_NOTES.md for the specific plugin-by-plugin decisions,
probe-round methodology, and dated write-ups behind all of the above.

### Aspect Ratio (issue #50)

Three things decide the shape of the output, and they live in different places:

1. **The stored frame size** — computed in the `.vpy`, because only the script
   knows the clip's dimensions after cropping and deinterlacing.
2. **The declared aspect** — applied by ffmpeg (`setsar` / `setdar`), because the
   Y4M pipe from vspipe **strips aspect metadata entirely**.
3. **`CropResizeParameters::aspect_declaration`** — the single decision of *what*
   to stamp, unit-tested, used by the encode path.

- **`pixelAspect: preserve`** (default) — leave the grid alone, re-stamp the
  source's SAR. Fitting a target box uses the **stored** aspect.
- **`pixelAspect: square`** — resample so the output is square-pixel at the same
  display shape. Fitting uses the **display** aspect, `clip.width * SAR / clip.height`.
- **`pixelAspect: custom`** — stamp a given SAR verbatim.
- **`displayAspect`** — force the shape on screen, declared as **`setdar`**
  (not `setsar`) because the SAR that produces a given DAR depends on the final
  frame size, known only to the script.
- **`padToAspect`** — letterbox/pillarbox to the exact target box.

`parse_ratio` accepts `16:9`, `16/9` and `1.7778`, returning `None` for anything
else so a typo falls back to the source's own aspect rather than reaching ffmpeg
as a broken filter argument.

**The preview has to show the same shape (issue #149).** The preview PNG carries
no aspect, so the app used to draw the processed frame at the **source's**
display aspect. Anything a pass reshaped (a 720x576 4:3 source resized and
padded to 1920x1080, say) came out squashed. Three invariants now hold:

- **One decision, two consumers.** `ProcessingPipeline::output_aspect(input_sar)`
  (rotation-adjusted SAR → `aspect_declaration`) is used by the encode's
  `setsar`/`setdar` **and** by the preview. The preview reports it on its
  `PREVIEW_INFO:` stderr line as `sar=N/D` or `dar=N/D` (nothing for square
  pixels). `PreviewFrameInfo.displayAspectFor` turns that plus the PNG's size into
  the shape to draw.
- **Each side has its own aspect.** `BeforeAfterComparisonWidget` takes
  `beforeAspectRatio` (source) and `afterAspectRatio` (processed). 1:1 is
  measured against the processed one. The processed aspect is stored on the
  `QueueItem` next to the image (`processedPreviewAspect`), not read from
  `previewFrameInfo`, which goes null as soon as the scrubber moves.
- **The preview job must carry `inputSar`.** `{{SOURCE_SAR}}` falls back to 1
  without it, so square-pixel fitting previewed a different frame from the
  one encoded (1350 vs 1440 wide in the #149 setup). `PreviewGenerator` reads it
  from the same source model (`source_model::normalize_sar`) as the encode job.

The panel reads both sides' aspects from the view model
(`sourceDisplayAspect`, `comparisonAfterAspect`), not from its own arithmetic,
so the wiring is testable without a worker (`debugAcceptProcessedPreview`).

Covered by `test_185` (Rust), `preview_frame_info_test`, `preview_aspect_test`
(including the view-model wiring: an unreshaped anamorphic source keeps its
shape, the aspect survives a scrubber move), `before_after_comparison_test`, and
the heavy `preview aspect (issue #149)` group in `integration_aspect_ratio_test.dart`,
which compares the preview with the encode for square, preserve, forced DAR,
denoise-only anamorphic and rotated anamorphic jobs.

### Borders (issue #86)

Two ways to add bars, sharing one step at the **very end of the template**
(`{{#BORDERS}}`, after `CHROMA_CONVERT`): **Add Borders** (`padEnabled`/
`padWidth`/`padHeight`) pads to a fixed canvas without rescaling, independent
of Resize; **Pad to Fill** (`padToAspect`) pads to the resize target, and its
block inside `RESIZE_STANDARD` only *records* the box (`_aspect_box_w/h`).

- **Last, on purpose.** Grain after the bars would noise them; a format
  conversion after them would resample their edge. Nothing may be added after
  `BORDERS` that touches pixels.
- **Never call `AddBorders` without `color=`.** Its default is luma 0 —
  below video black on a limited-range clip. `_border_color()` converts the
  chosen RGB into the clip's own format via `resize` with the source's matrix and
  range (`ColorMetadata::zimg_matrix` / `is_full_range`), so depth, range and
  matrix come out right from one path.
- **Offsets stay on the chroma grid, and on the field grid if still
  interlaced** (`{{BORDER_FIELD_ALIGN}}`: deinterlacing off + a detected field
  order). A picture bigger than the canvas **raises** rather than being
  cropped or left short — a wrong frame size is the one thing authoring can't
  take.

`integration_borders_test.dart` (heavy) checks bar levels at 8 and 10-bit, and
that the picture inside the bars is not rescaled.

### Colour metadata: read it, carry it, re-stamp it

Same shape as the SAR handling above, same fix site. Colour tags (`color_space`,
`color_range`, etc.) must be read from ffprobe, carried on `VideoJob`, and
re-stamped with `-colorspace`/`-color_primaries`/`-color_trc`/`-color_range` —
`SetFrameProps` in the script is inert, because the Y4M pipe strips frame
properties the same way it strips SAR.

**Declare them on BOTH sides: on the Y4M input (`to_ffmpeg_input_args()`,
between `-f yuv4mpegpipe` and `-i -`) and on the output (`to_ffmpeg_output_args()`),
always identical.** Output-only tags are not a label to FFmpeg: it sees an
untagged input, auto-inserts a scaler that reads "unknown" as BT.601, and
**re-matrixes every pixel** to the output tag — and output-only primaries/trc
never reach the file at all. Input-only lets a full-range source be negotiated
down to limited. Don't move this into `setparams` in the `-vf` chain: a Custom
FFmpeg Argument `-vf` replaces the chain and would bring the shift back. Test a
change here with **pixels**, not just ffprobe tags
(`integration_colour_tag_pixels_test.dart`, heavy) — the tag-only test passed
throughout the shift. See docs/ENGINEERING_NOTES.md (2026-09-26). `ColorMetadata::from_raw`
validates against FFmpeg's own accepted values rather than forwarding ffprobe's
`"unknown"` verbatim. `build_ffmpeg_args_for_test` duplicates `build_ffmpeg_args`
rather than calling it, so anything added to one must be added to the other.
The preview path needs the same source tags fed to swscale
(`swscale_input_opts()`) or it guesses the matrix and shows a colour shift the
real encode doesn't have.

**A tag FFmpeg rejects (ProRes's `reserved`) is cleared before any decode
converts, and only that tag.** FFmpeg 9's scaler fails a frame tagged
`reserved` outright, so every decode of the source that may convert its pixel
format puts `ColorMetadata::decode_tag_neutraliser` (worker, via
`source_decode::decoder_filter`: encode, preview and every detector) or its
byte-identical twin `ColorTags.decodeNeutraliser` (app: before frame and
thumbnails, via `PreviewGenerator.beforeFrameArgs`/`thumbnailArgs`) **first**
in its one `-vf`. Never clear a valid tag (a valid matrix moves yuv → gray16le
by up to 28 levels), which is why the job carries ffprobe's **raw** tags
(`source_model::color_tag` keeps `reserved`) and `from_raw` drops them only for the
encoder's flags. A new decode of the source must use the same helper.
**Every detector job carries the source's raw tags**
(`MainViewModel._detectorJob`): the worker can only clear a `reserved` tag
the job tells it about.
`integration_reserved_colour_tags_test.dart` (heavy) checks each one against
an untagged twin; see docs/reports/2026-11-reserved-colour-tags.

**BT.601 → BT.709 on SD → HD (app 1.7.0) is the one place the script
converts colour.** Crop & Resize's `convertToBt709` (`Bt709Conversion`:
`auto` default, `on`, `off`) converts a BT.601 source (tagged
`bt470bg`/`smpte170m`, or untagged below 720 lines) when the output is HD
(≥ 720 lines or ≥ 1280 wide, from `CropResizeParameters::output_size`, which
mirrors the script's fitting). Rules:

- **One decision: `VideoJob::converts_to_bt709`.** Everything that describes
  what the script DELIVERS uses `VideoJob::output_color_metadata()`, never
  `color_metadata()`: the encoder's input and output tags, the preview's
  swscale step, and the passes after Crop & Resize (Face Restoration, RIFE,
  the border fill). Only the AI upscale, which runs inside the resize before
  the conversion, keeps the source's. A missed site relabels the converted
  samples back to 601 — a silent colour shift.
- **The matrix only.** Output tags say `bt709` for matrix and transfer; the
  primaries keep the source's (tagged, or EBU/SMPTE C by height), because the
  samples were not gamut-converted. A gamut conversion moved a 75% green by
  55 levels on a player that does not colour-manage
  (docs/reports/2026-11-crop-detect-709).
- **Always needs the pass on, not its geometry.** With Cropping and Resize
  both off, an enabled Crop & Resize still converts, at the source's size
  (choosing Always in the panel switches the pass on). So `enabled_passes()` /
  `enabledPasses` list Crop & Resize whenever it is on: the app's subtitle-only
  test (`ProcessingPipeline.isSubtitleOnly`) reads that list, and a pass
  missing from it is skipped with the whole encode. `test_222`.
- **R78's resizers let frame properties override `*_in_s` arguments**, so the
  `{{#COLOR_709}}` block (right after `{{/RESIZE}}`) removes
  `_Matrix`/`_Range` first. Any new block that converts colour with explicit
  `*_in_s` arguments needs the same.
- `integration_bt709_conversion_test.dart` (heavy) checks the pixels: every
  patch within 3 levels (measured ≤ 0.67) of the source decoded as 601,
  through the tags and when read as 709 regardless, preview = encode, and Off
  stays 601 and bit-identical in YUV; with no crop or resize, Always converts
  at SD size and Auto / Off are byte-identical to the source.

### HDR Sources and Dolby Vision (issue #133)

An HDR source is processed and encoded as HDR; only what the user *sees* is
tone-mapped.

- **One display chain, two copies.** `ColorMetadata::display_tonemap_filter`
  (the worker's preview) and `HdrDisplay.toneMapFilter` (the app's "before"
  frame and timeline thumbnails) must be byte-identical for the same tags;
  `hdr_display_test.dart` fills the Rust `format!` string from source and
  compares. Keep its two odd stages: `setparams` first (zscale finds no path
  from an untagged Y4M), and `format=rgb24,setparams=colorspace=gbr` last (else
  the JPEG encode converts with BT.2020's matrix — a 21-level hue shift).
- **The preview job carries the source's colour tags** (`PreviewGenerator`
  sends `inputColor*`). Without them the worker can't tell the source is HDR,
  and the SDR matrix fix in `swscale_input_opts` doesn't apply either.
- **HDR10 static metadata goes to libx265 and SVT-AV1 only**, as
  `-x265-params` / `-svtav1-params` (`HdrMetadata::encoder_args`), and only
  when the tags are PQ/HLG. Probed by the executor (stream side data, else
  the first frame's SEI). Any other encoder keeps the tags only; never hand
  it another encoder's options.
- **Dolby Vision RPU is not carried.** Profiles 7/8/9 decode as their HDR10 /
  HLG / SDR base layer and come out as that. **Profile 5** (IPTPQc2,
  `ipt-c2`) can't be decoded correctly — no bundled FFmpeg on macOS has
  libplacebo — so it is warned about (`DynamicRangeBadge`, Video Info, job
  log), never blocked. `ipt-c2` stays off `ColorMetadata`'s matrix list.

`integration_hdr_test.dart` (heavy) encodes an HDR10 fixture and checks the
metadata and that preview = before-frame. See docs/ENGINEERING_NOTES.md
(2026-11-02).

### Source Pixel Formats (issue #50)

`templates/pipe_source.py` reads **raw planar frames off stdin** and can only
handle the formats in its `_FORMAT_MAP`. `worker/src/pixel_format.rs::decode_pixel_format`
is the **single** decider of the pipe format, and **all four** call sites
(decoder args + generated script, on both encode and preview paths) must use
it — if they disagree, the byte stream desyncs from the frame geometry
`pipe_source` expects and the output is garbage rather than an error.

- Readable formats pass through unchanged. **4:1:1 (NTSC DV) is the one the
  script itself converts**, to 4:2:2, losslessly, right after the pipe source
  and before the VFR placement and every pass (task #48; test_252 holds the
  order). So no pass sees 4:1:1 and none carries a 4:1:1 guard of its own;
  mvtools, Cnr4, RemoveDirt and DeScratch all refuse it.
- Anything else is converted **by the decoder ffmpeg** to the nearest readable
  superset format (never less chroma resolution or bit depth): 4:1:0/4:4:0 go to
  4:2:2; depth rounds *up* to 8/10/12/16; unrecognized names fall back to
  `yuv444p16le`.
- **14-bit is never piped** (task #23): a 14-bit (or 13-bit) source decodes as
  16-bit, losslessly (an exact shift in limited range). fmtconv's
  `bitdepth` has no 14-bit output and havsfunc returns to the clip's depth
  through it (`Bob`, `Resize`, `Deblock_QED`), so a 14-bit clip failed QTGMC at every preset, santiag and
  Deblock QED (docs/reports/2026-11-14-bit-sources).
- **9-bit is never piped either** (task #31): a 9-bit source decodes as
  10-bit, losslessly. CTMF has no 9-bit format and havsfunc reaches it
  through `MinBlur(r>=2)`: YAHR, HQDeringmod at HD, ContraSharpening,
  SMDegrain's contrasharp at HD, MCTemporalDenoise pfMode 2, FineDehalo's
  contra. So the Noise Reduction CTMF block has no 9-bit guard of its own
  (docs/reports/2026-11-9-bit-sources). `test_no_native_format_is_9_or_14_bit`
  keeps both depths out of `NATIVE_FORMATS` and `native_name`.

`NATIVE_FORMATS` (Rust) and `_FORMAT_MAP` (Python) must stay in step —
`test_native_formats_match_pipe_source` parses the Python file and fails if they
drift.

### Source Frame Size: decode the stored frame, never resample to fit

The frame size must agree the same way, and `worker/src/source_decode.rs` is
the **single** builder of both decoders' arguments (encode + preview):

- **`-apply_cropping codec` before `-i`.** FFmpeg (7.1+) applies *container*
  cropping by default — a QuickTime clean aperture (`clap`) or Matroska
  `PixelCrop` — but ffprobe's `width`/`height` exclude it (it shows only as
  `Frame Cropping` side data). `codec` decodes exactly what ffprobe reports;
  `none` would be wrong (it undoes the H.264 SPS crop: 1080p decodes at 1088).
  The user's Crop controls are the only crop. The app's own source-picture
  decodes (`PreviewGenerator.sourceDecodeOptions`) use the same option so the
  "before" frame matches the "after".
- **Never `-s` or scale on a decoder.** A size mismatch is an error, not a
  resample: the decoder's `-vf` is a size guard (`size_guard_filter`) that
  passes the probed size untouched and fails the decode on anything else,
  including a mid-stream resolution change, reported via
  `explain_decoder_failure` ahead of the vspipe/encoder status. A job that
  omits `inputWidth`/`inputHeight` gets them from the source model
  (`resolve_source`), not the old 720x480 fallback.
- **A decoder that seeks resets PTS first (issue #157).** `rawvideo` gets
  constant-rate output timing, and after an `-ss` to `(N - 0.5)/fps` that
  timing repeated the first kept frame on many time bases (MP4 1/2997, MOV
  1/11988, MKV 1/1000): the preview showed N-1, a trim of 41..52 came out
  `41, 41, 42 .. 51`, and the noise score read duplicated pairs as noiseless.
  So `RESET_PTS_FILTER` (`setpts=PTS-STARTPTS`) goes **in the one `-vf`**,
  ahead of the size guard (after only the colour-tag neutraliser, see
  "Colour metadata"), only when the decoder seeks; a decoder that doesn't seek passes no
  `-ss` (not even `-ss 0`) and no reset, so untrimmed encodes are untouched and
  preview frame 0 is the encode's frame 0. Never `-fps_mode passthrough` here:
  it drops the constant-rate slots a soft-telecine source decodes to (only the
  VFR decoder uses it). **Test seek alignment against an independent decode**
  (`select=eq(n,N)` of the source), never preview against encode, which shift
  together — `integration_seek_alignment_test.dart` (heavy). MPEG-PS/TS (issue
  #169) and AVI (issue #173, below) seek with rules of their own; on a source
  with a grid (next rule) the grid's own trim and reset replace this one.

- **Frame N is slot N of the source's grid, placed by timestamp (issue
  #174).** The grid is the job's rate as the stream's exact fraction
  (`2997/100` is not `30000/1001`), from the first picture; each slot shows
  the stored frame its timestamp puts there, so an AVI null frame or a
  pulldown repeat is a slot showing the frame before it. `rawvideo`'s own
  constant-rate output did not do that (a first frame's repeat flag became
  extra slots: every frame of `soft_telecine_test.mkv` two late), and a seek
  kept the frame *after* a null run or a repeat. So every constant-rate
  decoder (encode, preview, detectors) starts through
  `source_decode::decode_start` / `VideoJob::decode_start`: `-copyts`, a seek
  `GRID_LOOKBACK_SLOTS` (8) early, then `SourceGrid::filters` —
  `setpts=PTS-<first picture>/TB` (the **same constant in every decoder**, so
  `fps` rounds half-slot ties identically), `fps=N/D`, `trim=start_pts=N`,
  `setpts=PTS-STARTPTS`. The grid comes from the video-start probe
  (`grid_from_probe`, in the source model); the app's `SourceGrid.startAt`
  (a twin of `decode_start` until R3b, see docs/TWINS.md) drives the Original
  and thumbnails from the model's grid, pinned by
  `Tests/TestResources/source_grid_vectors.json`. **No grid when a probed
  packet lacks PTS** (MPEG-2/MPEG-4/H.264 in AVI: decode-order timestamps);
  those keep the seek rules here. **Frame 0 of a TS/PS runs without
  `-copyts`** (a `SeekPlan` source; `filters_from_first_picture`, the grid
  anchored by `setpts=PTS-STARTPTS`): `-copyts` turns off ffmpeg's timestamp
  discontinuity correction, and an untrimmed decode of a program stream whose
  clock resets (the DVD import writes cells back to back) stopped at the
  reset, the rest a frozen frame.
  The VFR decoder is separate and unchanged.
  `integration_source_grid_test.dart` (heavy) checks preview, Original, trims,
  untrimmed encodes and counts against an independent timestamp placement
  (docs/reports/issue-174-source-grid).
- **Soft Telecine decimates only at 29.97/30 fps** (`soft_telecine_decimates_at`,
  reported to the app as the source model's `pulldownRate`, which
  `VideoInfo.softTelecineDecimates` reads; `soft_telecine_rates.json`). A DVD's header says 29.97 and ffprobe reports
  that in VOB and MKV alike, so its decode holds 3:2 repeats; a source stored
  at its film rate already is the film, and VDecimate removed one real frame
  in five. The encode script pipes whole 5-frame cycles
  (`ProcessingPipeline::pipe_frames`) so a partial last cycle loses a repeat,
  not a film frame. The app treats a film-rate soft-telecine source as
  progressive (no auto-switch, no Deinterlace suggestion).

- **Frame N counts from the video's first picture, and every seek says so.**
  An input `-ss` counts from the *container's* start, the earliest stream's;
  on a broadcast (DVB-T) capture that is the sound, 1.2 s before the first
  picture, so frame N used to name a picture ~30 frames early. The offset is
  the earlier of the video stream's `start_time` and the smallest PTS of its
  first 64 packets, less the container's `start_time`
  (`source_decode::video_start_from_probe`; an open GOP shows B pictures
  stored after the first packet, MPEG-2 in AVI stores packets with no PTS).
  It is in the source model (`VideoJob.video_start_offset`, filled by
  `resolve_source`), which is where the app reads it too.
  - **Every seek goes through `source_decode::seek_time`** (encode, preview,
    every detector) and the app's `beforeFrameArgs` / `thumbnailArgs`; none
    keeps its own `(N - 0.5)/fps`. Frame 0 never seeks, on either side.
  - **A decoder that does not seek still resets PTS when the offset is
    non-zero** (`resets_pts`): that drops ffmpeg's constant-rate copies of
    the first picture (MKV/MP4) and keeps an open GOP's leading pictures
    (TS). With offset 0 every argument list is byte-for-byte as before.
  - **The frame count is the video's**, not the file's, and is the source
    model's (`source_model::frame_count`): `nb_frames` when stored (an
    AVI's null frames are slots: `interlaced_test.avi` stores 79 and the
    grid decode makes 79, where `-count_frames` decodes 75); else
    `frame_count_from_duration` (stream duration plus leading pictures);
    with no stream duration either (Matroska), the last picture's grid slot
    + 1 (`frame_count_from_last_picture`), since the container duration
    counts repeat flags (issue #174). On an MPEG-TS/PS the stream duration
    misses a last picture whose packet has no PTS (DVD: 149 of 150), so the
    probe decodes the last 3 s and counts it as ffmpeg's decoder stamps it
    (previous frame + its duration; `untimed_last_picture`), never lowering
    the count (task #26).
  - **An MP4/MOV edit list's discarded packets are not frames (task #54).**
    The demuxer keeps an edit's pre-roll (and B pictures past its end) for
    decoding and marks it discard (`D` in `packet=flags`); `nb_frames`
    counts it (`small_clip.mp4`: 3154 stored, 3151 decoded). When the head
    probe (`VIDEO_START_PROBE_ARGS`, now with `flags`,
    `discards_from_probe`) or an MP4/MOV's tail probe (`probe_tail`, the
    last 3 s, run with the others; `TailPictures`) sees one, the count is
    the last **kept** picture's grid slot + 1. Never "packets not
    discarded": a stream-copy cut leaves holes the grid fills
    (`edit_list_bframes.mp4`: 146 stored, 125 kept, 128 slots). A file
    whose discards are only mid-file (a multi-entry edit list) still counts
    `nb_frames` (docs/reports/task-54-edit-list-count).
  - **A job without a count takes the model's** (`apply_source_model`, over
    its trim), as the app's always has. Only `VideoJob::counts_by_decoding`
    (no model, or a raw MPEG-PS/TS whose timestamps reset in a job without
    `continuity_checked`, whose model counts the last segment) is still
    counted with `-count_frames` (`resolve_source`), which is wrong on AVI
    null frames, open GOPs, soft-telecine repeats and holes. Audio
    Restoration's drift reads the whole source's length the same way
    (`model_frame_count`).
  - **The output keeps the source's layout: sound first, picture delayed.**
    `VideoJob::output_video_delay` is the one decision (0 when trimmed, when
    there is no sound, or with Audio Restoration's `startWithPicture`); the
    encoder delays the picture in its one `-vf` (`settb=1/120000`, `setpts`,
    `-enc_time_base`) and copies the sound from the start, which is in sync
    and lossless. A trim seeks the sound to offset + in-point
    (`source_audio_start`), as do `OutputWindow` and transcription.
  - **Except in AVI** (`ContainerFormat::stores_stream_start`, Dart
    `storesStreamStart`): avienc cannot store a late picture (it wrote a
    1/600 time base with null frames, the first picture held from 0), so
    `output_video_delay` is 0 there and both start with the picture, the
    sound seeked and cut as a trim's is (task #24's `SoundCut`). The job log
    says how much sound is left out (`lead_sound_note`), and so does the
    Audio Restoration panel (task #30, docs/reports/2026-11-avi-late-video).
  - **Only `startWithPicture`, or AVI output, drops the sound before the first picture**, and
    **never prefill the sync offset (`offsetMs`) from the start offset**: it
    moves sound against picture and would create the desync it seems to fix.
  `integration_video_start_offset_test.dart` (heavy) checks pictures and sync
  on late-video TS/MKV/MP4 fixtures, and the AVI layout (stored frames =
  pictures; the 600 fps trap hides from `nb_read_frames`)
  (docs/reports/2026-11-video-start-offset).

- **MPEG-TS/PS seek a GOP early and trim to the frame (issue #169).** They
  have no keyframe index: libavformat's timestamp search lands on a non-key
  packet inside frame N's GOP and decoding started at the *next* keyframe
  (DVD 40 → 48, H.264 TS 40 → 50, nothing past the last keyframe). For
  `format_name` `mpegts`/`mpeg` (DVD rips and the DVD import's own output
  included) the job carries a `SeekPlan` (`source_decode::seek_plan_from_probe`:
  largest keyframe gap + largest PTS − DTS + 0.5 s, ≥ 1 s, from 20 s of
  packets), in the source model (`VideoJob.seek_plan`).
  `source_decode::decoder_seek` is the one place a decoder's seek is built:
  with a plan, `-copyts -ss (T − preroll)` and `trim=start=container_start+T`
  in the one `-vf` after the tag fix and before the PTS reset; without one,
  exactly the old `-ss T`.
  - **Never trim relative to the seek** (no `-copyts`): when the early seek
    falls before a late video's first packet, ffmpeg rebases the frames to
    the first picture and the trim keeps the wrong one.
  - **The app reads the plan from the source model**; its `SeekPlan.seekArgs`
    (used by `beforeFrameArgs` and `thumbnailArgs`) is a twin of
    `decoder_seek` until R3b, pinned by `mpeg_seek_plan_test.dart`.
  - **Every other format has no plan and keeps its arguments byte for byte.**
    Raw elementary streams (`mpegvideo`, `h264`) are not covered: they have no
    timestamps to trim by.
  `integration_seek_alignment_test.dart` checks a DVD-style PS, a late-video
  H.264 TS (`generate_mpeg_seek_test.sh`) and the DVB-T clip at mid-GOP
  frames, leading B pictures and past the last keyframe; see
  docs/reports/issue-169-mpeg-seek.

- **An AVI lands on frame N too (issue #173).** `source_decode::source_seek`
  is the one decision for a decoder that starts at frame N (encode, preview,
  every detector; `VideoJob::source_seek`); the app's twin is
  `SeekPlan.frameSeekArgs`. Three rules, each fixing a measured fault:
  - **Every seek value is rounded *up* to the microsecond**
    (`source_decode::seek_arg`, Dart `SeekPlan.formatSeek`, 1 ns allowance).
    An AVI's tick is one frame, so `(N - 0.5)/fps` sits exactly on half a
    tick; `%.6f` often printed it just below and ffmpeg rounded to N - 1, on
    1 start in 3 of **every NTSC-rate AVI** (HuffYUV, DV, B-frames or not).
    Never format a seek with `{:.6}` / `toStringAsFixed` directly.
  - **A source that stores decode-order timestamps adds its decoder delay.**
    AVI with MPEG-2, MPEG-4 ASP or H.264 B-frames stamps display picture k as
    k + D (1, or 2 for H.264). Probed only when a first packet has no PTS
    (`stores_decode_order`), by decoding a few packets
    (`decoder_delay_from_probe`, whole frames, 1..4); `VideoJob.decoder_delay_frames`
    (in the source model, which the app's `PreviewGenerator` reads too). **It moves seeks only**, never
    `video_start_offset` or the output's sound/picture layout. A delayed
    source also **rebases PTS when it doesn't seek** (`DecoderSeek::rebase`):
    H.264 in AVI's two-frame gap made the untrimmed decode repeat frame 0
    twice and lose the last two frames. A `SeekPlan` source never takes a delay.
  - **Below 0.5 s a delayed source decodes from the start and drops N
    pictures** (`trim=start_frame=N` before the PTS reset; `COUNT_SEEK_BELOW`).
    ffmpeg starts such a seek 3/23 s early and an AVI cannot seek before its
    start ("could not seek"): frame 1 decoded as frame 45. The first
    thumbnail never seeks for the same reason.
  - **The sound seeks the same way (rule 9).** ffmpeg's early start applies
    when *any* stream has a delay, so an input `-ss` on a delayed source's
    sound below `COUNT_SEEK_BELOW` failed too and lost ~1.3 s. One decision,
    `source_decode::sound_seek` (`VideoJob::sound_seek`; `None` / `Input` /
    `Skip`): decodes of the sound skip after decoding (Audio Restoration's
    render with `atrim=start_sample` right after `aresample=first_pts=0`,
    never an output `-ss`, which ffmpeg applies after the whole chain; its
    analysis and transcription with `-ss` after `-i`). The copy encode, which
    never filters audio, seeks a **NUT copy** of the source's sound
    (`audio_restoration::needs_sound_sidecar`, `SoundSidecar`, an extra
    encoder input after the restored track, held to the end of the job,
    tags still mapped from input 1). NUT, not MKA (ms timestamps, 9 samples
    off) or audio-only AVI (5 ms off on MP3). A failed copy is a warning,
    never a refusal. Every other source's arguments are unchanged
    (`integration_avi_audio_seek_test.dart`, heavy;
    docs/reports/2026-11-avi-audio-seek).
  `seek_arg_cases.json` holds the rules as a table both sides check;
  `integration_seek_alignment_test.dart` (heavy) covers three AVI fixtures
  (`generate_avi_seek_test.sh`, `hard_telecine_test.avi`)
  (docs/reports/issue-173-avi-seek).
- **A TS/PS whose timestamps reset is decoded from a joined copy (task #21).**
  A DVD title over several VOB IDs (so the DVD import's own output too), or
  a spliced capture, has a clock that goes back
  mid-file: ffprobe counts the last segment only, `-ss` can't reach a later
  segment, and `-copyts` stops at the reset. `source_continuity.rs` is the
  one decision: a reset is ffmpeg's own (DTS > 0.1 s back or > 10 s forward,
  per A/V stream), and the fix is a **same-container stream copy**, checked
  (no reset left, every video packet) before use and made only when a reset
  is found — a file without one keeps every argument.
  - **The picture decides the join (task #58).** Each segment moves by one
    offset, every stream alike, so its first picture follows the last
    segment's last by one frame (`JoinPlan`, made by the scan from each
    packet's DTS, duration and position): `-copyts` and a `setts` filter per
    stream (by packet index `N` for a stream that resets, by byte position
    `POS` for one that doesn't: subtitles; MPEG audio split from a PES has
    no position). A sound packet overhanging the next segment by more than
    half of itself is dropped (`noise`), and the log says so. ffmpeg's own
    correction (no `-copyts`) took the offset from whichever stream showed
    the reset first: a part whose sound ran 16 ms past its last picture put
    every later picture off the grid (125 fps, 493 pictures for 100). It is
    still the fallback when no plan can be made (no durations, streams
    resetting a different number of times) or the planned copy fails its
    check.
  - **The app makes it after analysis, in the background (task #55).**
    The scan reads every byte (77 s for a 2 h DVD title on a network
    share), so analysis probes with `--probe-source --defer-scan` (the model
    says `continuityDeferred`), shows what needs no seek, then runs
    `--complete-source` on a serial queue, one source at a time, with
    progress. On a reset, `--make-continuous --source <model>` copies into
    the temp directory using the model's scan (never a second full read).
    **While `QueueItem.continuityPending`, nothing may seek the source**:
    a seek on a file whose clock resets can land in any segment, *before*
    the reset too (the #21 report's frame 140 landed at 290), so no
    "frontier" makes a seek safe. Only frame 0 (never seeks), the processed
    preview at frame 0 and sequential decodes from the start without
    `-copyts` run (idet on a TS/PS drops its first 2 s by frame count, not
    `-ss`; `FieldOrderDetector.idetArgs`). Thumbnails, the scrubber, in/out
    points, zoom, the detectors (they await `continuityReady`) and jobs
    (`_processNextItem` awaits it; Cancel stops the wait) hold until it
    answers. Gate a new seeking decode on `QueueItem.seeksAllowed`;
    `timestamp_continuity_deferred_test.dart` records every decode.
    **`QueueItem.decodePath` is what every probe and decode reads;
    `inputPath` stays the user's file** (output name, display, Show in
    Folder, sidecars). `queue_item_decode_path_test.dart` fails on any new
    `.inputPath` read until it is classified. Jobs carry
    `continuityChecked`; without it the worker scans and only **warns**.
  - **The DVD import joins** (extracts to `.part`, then renames or joins).
  - **Never per-segment offsets in the decoders** (copied sound can't be
    filtered, `-ss` can't target a segment) and never an MKV copy (leaves
    the TS/PS rules). `integration_seek_alignment_test.dart` checks the
    `seek_reset_*` fixtures through the copy (docs/reports/2026-11-timestamp-resets;
    deferral: docs/reports/task-55-deferred-reset-scan).
- **A copied sound trimmed into AVI is cut, not pre-rolled (task #24).** A
  stream copy keeps packets from where the seek lands (the keyframe before
  the in-point); MKV/MP4/MOV store that as a later video start, but AVI
  cannot store where a stream starts, so the sound ran late by up to a GOP.
  One decision, `audio_restoration::needs_sound_cut` (Passthrough,
  `!ContainerFormat::stores_stream_start()`, `source_audio_start() > 0`),
  and one probe, `sound_cut_from_probe` (`SoundCut`):
  - **Linear PCM** (`EXACT_PCM_CODECS`) is re-written in its own codec
    (`-c:a:N`): seeked and decoded, it is the source sample for sample.
  - **Compressed sound stays a copy**, from a second input of the same file
    (or the NUT copy) with `-copypriorss:a 0`, seeked half a packet early
    **only where the stream's time base is finer than a quarter packet**:
    ffmpeg drops by timestamp in the stream's own time base, so an AVI's
    MP3/AC-3 (counted in packets) is already cut at the nearest packet, and
    an early seek kept the one before. **The NUT copy always seeks early**
    (`half_any_packet`): NUT counts that same sound in samples.
  - Both builders (`build_ffmpeg_args`, `build_ffmpeg_args_for_test`) take
    it through `sound_cut_input` / `sound_cut_input_args`; a failed probe is
    a warning, never a refusal; everything else keeps its arguments byte for
    byte (`a_sound_cut_changes_nothing_outside_a_seeked_copy_into_avi`).
    `integration_avi_copy_trim_test.dart` (heavy;
    docs/reports/2026-11-avi-copy-trim).
  - **An untrimmed copy is cut the same way when its sound starts before
    the container (task #43).** ffmpeg-encoded AAC/MP3/AC-3/MP2 in MKV/MP4
    starts with its priming at a negative timestamp; AVI cannot store one,
    so ffmpeg shifted every stream by it (a null frame at the head, AAC
    −18.6 ms). `may_cut_sound_head` (the same clauses with
    `source_audio_start() <= 0`) asks the probe, which reads each stream's
    first packet against the format start (`SoundCut::head_before_start`,
    `starts_early`, copied compressed streams only);
    **`sound_cut_applies` is the one decision** for both cases. The packet
    input moves `-copypriorss`'s threshold half a packet before the start:
    `-ss` when that is inside the file, else `-itsoffset` by the remainder
    (never both). Every packet kept is then ≥ 0, so no output option is
    added. AAC lands at 0.08 ms, MP3 −0.9 ms (its next packet starts 47
    samples in); AC-3/MP2 keep their first packet (nearest) and their timing.
    Never `-avoid_negative_ts disabled` alone: the sound is then late by the
    whole priming (+21 ms). Heavy: `primed_aac.mkv` / `primed_mp3.mp4`
    (`generate_primed_sound_test.sh`) in `integration_video_start_offset_test.dart`
    (docs/reports/2026-11-avi-copy-priming).
- **Convert into AVI reads its sound late by the encoder's priming (task
  #38).** A lossy encoder's first packet is negative (AAC 1024 samples,
  libmp3lame 1105, AC-3 256); MKV/MP4/MOV mark it skipped, AVI cannot, so
  ffmpeg shifted every stream by it (a null frame at the head for AAC/MP3)
  and the player played the priming as sound (AAC −18.6 ms, MP3 −16.9 ms,
  AC-3 +5.4 ms). One decision, `audio_restoration::needs_priming_shift`
  (Convert, `!stores_stream_start()`, with sound; a copied primed sound is
  task #43's head cut, above), and one probe,
  `priming_from_probe` (`EncoderPriming`: the job's own encoder on silence
  at the sound's rate, `-f framecrc`; FLAC/PCM measure none):
  - **Every encoded sound input** is seeked `+P`
    (`encode_sound_start`): the source (`source_audio_input_seek`), the NUT
    copy, and the restored track (`-ss P` on its WAV). The output gets
    `-avoid_negative_ts disabled` (`ENCODER_PRIMING_OUTPUT_ARGS`, replacing
    an IVTC job's `make_zero`). Never `-itsoffset` (inert beside `-ss`).
  - **`source_audio_start` is never changed by it**: the render,
    transcription, `OutputWindow`, `SoundCut` and the notes keep the true
    start. The sidecar decision (`needs_sound_sidecar`) asks with the
    encoder's start, so `main.rs` measures the priming before the sound copy.
  - **A trimmed one stops at the window's length (`-t`), not `-shortest`**
    (`encode_end_args`, task #58): read late by P, a sound that ends with the
    window (the restored track; a source's sound at a trim to its last
    picture) ends P before the picture on ffmpeg's timeline, and
    `-shortest` dropped the last picture (49 stored for 50).
  - The cost is the first P (21–23 ms) of sound, replaced by the encoder's
    near-silent start-up; a failed probe is a warning, never a refusal; every
    other job keeps its arguments byte for byte
    (`a_priming_shift_changes_nothing_outside_convert_into_avi`).
  `integration_video_start_offset_test.dart` (heavy): AAC/MP3/AC-3 into AVI
  store 100 frames and are in sync within 1 ms, restored and trimmed too
  (the matrix counts trimmed pictures since task #58),
  and `small_clip.mp4` 0..49 stores 50 (docs/reports/2026-11-avi-convert-priming).
- **An AAC stream in AVI declares a block size no packet exceeds (task
  #41).** avienc writes AAC's `nBlockAlign` as 768 × channels, and ffmpeg,
  VLC and DirectShow time a VBR chunk as `ceil(size / nBlockAlign)` packets
  (Media Foundation splits it in two). ffmpeg's AAC encoder overshoots at
  ≥ 192 kbps per channel (mono at High/Very High; mono 160 kbps at 32 kHz),
  and nothing in the encoder stops it, so each such packet made the rest of
  the sound 21.3 ms later (320 ms by 12 s at 256 kbps); a copied AAC stream
  too. After a successful encode into AVI with sound
  (`avi_header::checks_block_align`), `avi_header::fix_aac_block_align`
  raises each AAC (`0x00FF`) VBR stream's `nBlockAlign` to its largest
  chunk, which avienc's trailer already records as `strh.dwSuggestedBufferSize`
  (OpenDML's `AVIX` part included): one header read, 2 bytes written, and
  only when needed, so every other file is byte for byte as before. Never
  MP3 (its 1152 is a convention readers rely on) or AC-3 (within theirs at
  every app setting). A failure is a warning. **It must follow anything that
  writes the AVI** (today nothing: the subtitle mux never touches an AVI).
  The heavy group `mono AAC over 768 bytes a packet into AVI (task #41)`
  (fixture `generate_avi_aac_overshoot.sh`) asserts oversized packets were
  written before checking the header, gap-free packet timestamps and each
  beep on its flash (the copied case too, since task #43); `_expectAacTimedOnce` also guards the other AVI Convert tests
  (docs/reports/issue-41-aac-avi-block-align).

`integration_clean_aperture_test.dart` (heavy) asserts a clean-aperture MOV and
MKV come through bit-exact at full size. See docs/ENGINEERING_NOTES.md,
"Clean aperture" and "Seek alignment".

### DVD Import (task #27)

`--dvd-extract <disc> --title N [--chapters S-E] [--angle A]` copies the
title's own sectors to an MPEG-PS, then #21's join (above) makes its
timeline continuous.

- **`dvd_reader::title_cells` is the one decision of what a title plays**:
  chapter by chapter from the VTS PTT table (pgcn, pgn), each program's cells
  from its PGC's program map (a chapter runs on through programs no chapter
  starts at, which a player plays too), one cell of each angle block. The picker's
  chapter and title durations come from the same cells (angle 1), so they
  match what is extracted. **Never copy the whole title set** (what the
  import did before: every title of the VTS, every angle interleaved), not
  even as a fallback: an unmappable title is refused with the reason.
- **Interleaved cells are walked, not copied as a range**: a seamless angle
  or branching cell's range spans the other angles' units. `walk_interleaved`
  follows each NAV pack's `next_vobu` (libdvdread's `play_title.c`); ordinary
  cells are plain ranges, touching ones merged (`copy_plan`).
- **What to copy is pure and tested without libdvdread** (synthetic IFOs, an
  in-memory disc, and the committed fixture's VOBs read directly);
  `dvd_extract_integration_test.rs` runs the worker with libdvdread on
  `Tests/TestResources/dvd_titles` (`generate_dvd_titles_test.sh`, needs
  dvdauthor) and checks each title's and chapter range's frames by colour.
  dvdauthor can't author angles, so those are covered synthetically only
  (docs/reports/2026-11-dvd-title-extraction).
- The app's picker offers no chapter or angle choice yet; `DvdService`
  already passes `--chapters` when given one.

### Variable Frame Rate Sources (issue #137)

Phone and screen recordings drop their rate when the scene gets dark or busy.
Everything after the decoder assumes constant rate, so the worker places the
stored frames on the grid itself:

- **One decision, in the worker.** `source_timing::probe` reads the stored
  frames' timestamps only when `r_frame_rate` and `avg_frame_rate` differ by
  more than `VFR_RATE_TOLERANCE` (not the 2:1 field-coded case), and returns
  `None` unless they really are irregular — a CFR job's decode and script are
  byte-for-byte unchanged. The grid is `job.input_frame_rate`; IVTC and Soft
  Telecine jobs are skipped, since VDecimate expects ffmpeg's constant-rate
  decode with the pulldown repeats.
- **Decode stored frames, place them in the script.** The decoder runs with
  `-fps_mode passthrough` (`timeline_decoder_args`); left alone, ffmpeg
  writing `rawvideo` repeats a frame into each gap and the script can no
  longer tell gap from frame. `{{#VFR_TIMELINE}}`, right after the pipe in
  **both** templates, maps slots to stored frames. Encode and preview take
  their window from the same `SourceTimeline` (`window_for_trim` /
  `window`), so preview = encode.
- **A gap repeats the frame before it — unless the Frame Rate pass
  synthesizes frames** (`ScriptGenerator::interpolates_gaps`: FlowFPS/RIFE,
  progressive source), when it is `mv.FlowInter`-interpolated at its true
  position. Interpolating a repeat is what made retimed VFR video stutter;
  inventing pixels for any other job is not ours to do.
- **Count by duration, not `nb_frames`.** `nb_frames` counts stored frames,
  so the app's timeline was short, trims landed early and the encode lost its
  tail. The source model counts a VFR source as its timeline's slots (else,
  if only the rates suggest VFR, duration × rate), and the worker sets
  `total_frames` to the window's slot count regardless. The model carries the
  stored times (`frameTimes`, VFR sources only), so a preview builds the
  timeline without reading the file again.

`integration_vfr_source_test.dart` (heavy) checks length, gap pixels against
the dropped ground-truth frames, slot alignment and preview = encode.

### High Bit Depth Sources (10-bit ProRes 422 and deeper)

A >8-bit source is read natively off the pipe. Two ways this breaks after that:

1. **The filter rejects the depth** and vspipe dies. Known 8-bit-only cases
   (`vivtc.VFM`, `descratch.DeScratch`, `dedot.Dedot`; `bifrost.Bifrost`
   until v4.0, task #60, which runs at 8–16 bits natively) and
   10-bit-max cases (`havsfunc.LUTDeCrawl`, `LUTDeRainbow`) are measured,
   not remembered: `Scripts/probe-plugin-formats.py` runs every plugin call
   the template makes at every format and size and keeps the result in
   `Tests/TestResources/plugin_format_table.json`, re-checked against the
   installed bundle by the push gate (quick) and nightly (full). VFM takes
   metrics from an 8-bit copy (`clip2`); every other limited plugin has a
   `Contract` in `worker/templates/plugin_formats.py` and is called through
   `_pf.run_within(clip, key, fn, label=…)` (task #48), which **applies only
   the filter's change at full depth**: `src + back(fn(work)) - back(work)`,
   so every sample it left alone stays bit-exact (tasks #34, #37). **Never
   up-convert a filter's whole low-depth result**: it quantised 78% of samples at 10-bit and 99.6% at 16-bit, in
   planes the filter never touches. Test a guard like this on a fixture with
   real sub-target-depth content: one converted from a shallower master has
   zero low bits and passes either way
   (docs/reports/issue-34-descratch-high-bit-depth,
   docs/reports/issue-37-chroma-fixes-high-bit-depth).
   **DeScratch on 4:2:0 runs its luma on a 4:2:2 carrier** (task #29): the
   plugin's internal blur is a resize that zimg runs per field on a
   field-flagged clip, which fails on most 4:2:0 heights. Keep the carrier
   (blank half-width chroma, source chroma put back); don't "simplify" it to
   one call or strip `_FieldBased`, which removed less scratch
   (docs/reports/issue-29-descratch-420). Blur Radius is clamped in the
   script to `c.height // 2 - 1`, which the plugin refuses past (frames
   under 402 lines; task #35, docs/reports/issue-35-descratch-blurlen).
   **A 4:2:0 frame whose height is 2 mod 4 (720x486) has an odd number of
   chroma rows** (task #57), so it can't be split into fields
   (`SeparateFields`), and zimg refuses any resize of it while it is
   field-flagged, a depth change included ("Resize error 1027"). Every such
   site goes through `plugin_formats.pad_around()` (or `read_padded()` for a
   resize): 2 more rows repeating each field's own last row, the call, the
   rows cropped back. It adds nothing to a frame that fits; with
   `field_based_only` a progressive frame takes the unpadded path, chosen per
   frame, so jobs that ran before keep their output exactly (padding LSFmod
   every time moved it 26 levels: it supersamples at a size that follows
   the height). `run_within()` pads whatever it converts. test_258 fails on
   a `SeparateFields` outside `pad_around`/`run_within`; the format sweep
   runs a 96x66 row. Never strip `_FieldBased` to get round it, except for a
   copy whose samples it can't change (stabilize.weave's undithered depth
   change); error diffusion runs per field
   (docs/reports/task-57-height-2-mod-4-and-removedirt).
2. **The filter accepts the depth and misapplies 8-bit-unit parameters.** Every
   threshold/offset in the UI is expressed in 8-bit levels (0-255), so a filter
   working in the clip's own range is silently wrong by 4x at 10-bit, 256x at
   16-bit — found in `std.Levels` (scaled by `_levels_8bit()`, against *peak*)
   and `adjust.Tweak(bright=…)` (scaled by `_tweak_bright_scale`; contrast/
   saturation/hue are ratios and must **not** be scaled). Both scalings are
   computed **in the script from `clip.format`**, since a preceding pass may
   have changed the depth.
3. **A limit counted per histogram bin can't be scaled to a deeper
   histogram.** `vszip.CLAHE`'s clip limit is a whole count per bin
   (`limit x tile pixels / bins`, at least 1). The per-bin limit that matches
   an 8-bit picture's is a fraction at 16-bit, so genuinely deep content was
   barely clipped. So Local Contrast **decides on an 8-bit copy at every
   depth and adds only its change at the clip's depth**
   (`plugin_formats.change_at`, task #56 F7): genuine 10–16-bit content lands
   ~1 level from the 8-bit result at 720x480 (it was 3–22 with the old
   `limit << (16 - content_depth)` scaling, which assumed each 8-bit level's
   samples fill its sub-bins evenly), and 8-bit content in a deeper
   container is exactly the 8-bit result. The cost: samples of one 8-bit
   level get the same change, so a smooth deep ramp steps about as the
   8-bit result does (docs/reports/task-56-format-sweep-findings).

**Test this class of bug with a reference, not an expected value** — a
correctly-scaled filter produces the same picture at 10-bit as at 8-bit, to
within rounding. `app/test/integration_high_bit_depth_filters_test.dart` (heavy)
compares every pass at 8 and 10-bit with hand-tuned parameters at 352x288,
and compares a 9-bit source with the 10-bit one and a 14-bit source with the
16-bit one they are decoded as. A >8-bit preview PNG comes out `rgb48be`, not
`rgb24` — that's expected, don't force 8-bit.

**The generated format sweep (task #47) is what checks every pass runs on
every format.** `app/test/support/format_sweep.dart` builds the cases from
the code, never from a list: every `PassType` (classified by a switch with
no `default`), every schema `methods` entry or `implementation` `activeWhen`,
three enum axes (QTGMC presets, rotation, pitch mode), through the app's own
`ParameterConverter`; × depth {8, 9, 10, 12, 14, 16} × {4:2:0, 4:2:2, 4:4:4}
plus every other `NATIVE_FORMATS` entry (parsed from `pixel_format.rs`) ×
{progressive, TFF} × {96x64, 98x64 (chroma width odd), 720x480}. Fixtures are
one degraded 8-bit master per size, the deeper depths derived from it by a
chain with real sub-8-bit content (`chainSample`). Per row
`integration_format_sweep_test.dart` checks the preview **runs**, keeps the
source's **depth** (PNG bit depth), the variant **acts** on some row, and
(nightly) 8-bit vs deeper **parity** above the passthrough's own difference
(swscale converts 8-bit 4:2:0 to RGB without chroma interpolation: ~4.5
levels at passthrough). Passes declared in `deltaOnly` also get an FFV1
encode whose untouched samples must be bit-exact. A failing row is either
fixed or listed in `knownFailures` with the text it must fail with and its
task; a listed row that starts passing fails the test.
`format_sweep_cases_test.dart` (push gate, no worker) pins the variant count
per filter, each `*Method` enum against its schema both ways, and the hand
tables' keys. Rows run in parallel (`VAPOURBOX_SWEEP_JOBS`, default half the
cores) with the cache capped at 512 MB a job: uncapped, 7 concurrent SD
previews took 26.5 s each instead of 1.4.

### Output Colour Format

`ChromaSubsampling` (**Settings → Color Format**) is the last thing the script
does, and decides bit depth as well as chroma:

| Option | Output | For |
|---|---|---|
| `original` (default) | source format, depth included (a 9-bit source comes out 10-bit, a 14-bit one 16-bit, see "Source Pixel Formats"); a pass that changed the depth (Deband's Working Depth) is dithered back to the source's after the passes (`{{#DEPTH_RESTORE}}`, task #56) | archival; a 10-bit source stays 10-bit |
| `yuv420` | `vs.YUV420P8` | compatibility — the only one every player opens |
| `yuv420p10` | `vs.YUV420P10` | the only 10-bit layout NVENC/QSV/AMF encode (issue #74) |
| `yuv422` | `vs.YUV422P8` | more chroma detail, 8-bit |
| `yuv422p10` | `vs.YUV422P10` | normalize chroma without dropping to 8-bit |
| `yuv444p10` | `vs.YUV444P10` | full chroma — ProRes 4444, x264/x265; no GPU encoder |

**v210 overrides the selection**: the script always converts to `YUV422P10`
for it (`EncodingSettings::effective_chroma_subsampling`, Dart
`effectiveChromaSubsampling`) — see "Intermediate codecs" below. Anything that
reads the output format (the conversion block, `encoder_input_pix_fmt`, the
bit-depth warning) must use the effective one.

Tests must **sweep the enum** (`ChromaSubsampling::ALL` in Rust, kept complete
by a catch-all-free match plus a count assertion; `ChromaSubsampling.values` in
Dart) rather than a hand-written list — `yuv420p10` was once missing from three
such lists at once, and a skipped row looks exactly like a passing one. Before
wiring up a new format, verify the Y4M pipe can actually name it (vspipe writes
the header, not ffmpeg's muxer — the muxer calling a format "not official" is
irrelevant, only what vspipe emits matters); an unnameable format is a hard job
failure with no error, the same trap as `Turn90`'s 4:4:0 case.

- The default can produce a file many players refuse (10-bit 4:2:2 → H.264
  High 4:2:2 / HEVC Rext) — deliberate, the user picks the format.
- The 8-bit conversion **must dither** (`dither_type` left at its
  `"error_diffusion"`-capable default, not `"none"`) or shallow gradients band.
- The block is shared by the encode and the preview, so a preview shows the
  output format's banding. Add new formats in `ChromaSubsampling::vapoursynth_format`,
  not as a new match arm in `script_generator.rs`.

Rust's serde names and Dart's `value` strings are the wire format
(`test_91` / `pixel_format_test.dart` assert the same list both sides). The
Dart enum's `outputBitDepth` drives the "your N-bit source will be output as
M-bit" warning.

### One script template (task #42)

The encode and the preview are generated from **one** file,
`worker/templates/pipeline_template.vpy`. The preview used to have its own
copy, which drifted: it lost MCTemporalDenoise's `settings` (the preview
denoised at havsfunc's default profile) and five QTGMC arguments, which hid
that havsfunc's QTGMC takes none of them (setting one failed every encode).

- **The few lines that genuinely differ** sit in `{{#ENCODE_ONLY}}` /
  `{{#PREVIEW_ONLY}}` blocks: the pipe-source reads, Unblend's and the Frame
  Rate pass's phase padding, DDColor's `preview=True`, the arrangement of
  IVTC's and Soft Telecine's VDecimate input and the read of its drop
  (task #46: VDecimate itself runs on both sides), and the preview's final
  frame pick.
  `script_generator::select_side` keeps one side and drops the other when the
  file is **loaded**, before any substitution, so no other block ever sees the
  side tags. Never nest them, and never write the tags anywhere else (the
  docstring once did, and selection ate it). `test_248` checks the blocks and
  that there is exactly one `.vpy`.
- **A template keyword argument must exist in the bundle.**
  `template_call_arguments_test.dart` (push gate) checks every `haf.*` call in
  the template and its `.py` modules against havsfunc's `def` lines, and every
  `core.<ns>.<fn>` call against the signatures the bundle's own core reports.
  The Rust suite only inspects the generated text, and a default leaves most
  optional arguments out, so nothing else catches a wrong name.
- **Never call `tcanny.TCanny` from a template or its modules** (task #52).
  TCanny r14, in every bundle, fills shared per-thread maps with no lock, and
  two threads starting together abort vspipe with an uncaught
  `std::out_of_range` ("unordered_map::at: key not found"). For its Gaussian
  (`mode=-1`) use `gauss_blur.gaussian_blur`, within 1 level of it;
  `test_250` enforces this. `std.Convolution` repeats the edge sample when it
  mirrors, which TCanny doesn't: that helper pads each plane first
  (docs/reports/task-52-tcanny-race).
- **RemoveDirt's `RestoreMotionBlocks` gives each frame an instance to
  itself** (`templates/removedirt.py`, `_ExclusiveInstances`, task #57). v1.1
  is `fmParallel` but shares one object's block buffers between frames, so
  output changed run to run (upstream pinterf/RemoveDirt#5). A frame takes a
  free instance from a pool and hands it back when done. **Never a new
  instance per frame**: the plugin leaks every instance it frees (~0.6 MB at
  720x480), so memory grew with the job's length. Keep the pool until the
  bundle has the fixed release (task #63); `removedirt_determinism_test.dart`
  checks it.

### VapourSynth Frame Cache (issue #107)

**The template does not set `core.max_cache_size` on its own.** VapourSynth sizes
the cache from the machine's memory (8192 MB on a 16 GB Mac); the templates
used to pin it to 1024, which starved QTGMC's threads on HD sources (1.9 fps
instead of 14.7 at 1080i Very Slow). The only assignment is the
`{{#MAX_CACHE_SIZE}}` block, emitted when the user ticks **Settings → Output →
VapourSynth Cache → Override max cache size** (`EncodingSettings.maxCacheSizeMb`,
MB, null = off). `EncodingSettings::effective_max_cache_size_mb` treats 0 as
off. `test_162` asserts both scripts. Don't reintroduce a hard-coded value —
SD never reaches the cap, so a too-low one passes every SD test.

### Stabilize: weave and pitch (issue #150)

One pass, two independent corrections, weave first. It runs **last before
framing** (after Colour Correction, before Rotate / Flip and Crop & Resize), so
a crop can remove the edges both corrections expose.

- **Weave / shake** — `stabilize.weave`: havsfunc's `Stab(clp, dxmax,
  dymax, mirror)` (`mv.DepanEstimate` / `DepanCompensate` against a 15-frame
  average) with the motion **measured on a 16-bit copy**. MVTools' Depan
  reads every format as 16-bit samples (`frame_data2d` compares bytes per
  sample with 8 and 32), so on 8-bit it measured horizontal shake at about
  half. The clip itself is compensated, at its own depth. **Never call
  `haf.Stab` or `mv.DepanEstimate` on a non-16-bit clip directly**
  (task #32, docs/reports/2026-11-depan-8-bit). On by default (`weave: true`).
  On a picture with no global motion, Depan's estimate is a ±0.011 px
  near-tie that varies with VapourSynth's threading. So a test of this pass
  needs a fixture with real shake (`_shakenFixture` in
  `integration_high_bit_depth_filters_test.dart`).
- **Vertical pitch ("frame height breathing")** — pull-through film scanners
  let the film slip in the gate, so each frame is a fraction of a percent
  taller or shorter than the last. `worker/templates/stabilize.py`
  (`correct_pitch`, imported by **both** templates so preview and encode can't
  drift) resamples each frame about its centre at a **constant frame size**
  (`src_top`/`src_height`), sub-pixel. Rounding the height to even pixels and
  padding back, as the issue proposed, makes any correction under ~0.19% at
  1080 lines a no-op — i.e. all real breathing. **Off by default.**
  - `auto`: the relative scale + shift between **adjacent** frames is measured
    by grid search on a narrow luma strip, then each frame is corrected to the
    mean of its ±radius window. Comparing against a temporal *average* was
    clearly less accurate: motion and the breathing itself blur the average.
    Pairs whose best match still differs by > 3/255 are treated as cuts.
    Stateless per frame, so a preview measures exactly what the encode does.
  - `file`: one factor per **source** frame. The factor is the *measured*
    height ratio (1.004 = 0.4% too tall); `invertFactors` accepts the other
    convention.

Invariants that are easy to break:

- **A pipeline saved before pitch existed must produce the same script.** Old
  JSON has only `enabled/dxmax/dymax/mirror`; it deserialises to weave on,
  pitch off, and the generator emits the weave block byte-for-byte. It was
  changed deliberately once (task #32: `Stab` became `stabilize.weave`). The
  inner `{{#STAB_WEAVE}}`/`{{#STAB_PITCH}}` tags go with their whole lines
  (`keep_block_lines`). `test_212` pins it.
- **The pass's temporal reach is declared.** `Stab` reads n-8…n+9 (measured
  under vspipe: the ±7 average, its scene-change look-ahead, and Depan's
  interleaved pair), auto pitch another radius+1. `StabilizeParameters::radius`
  feeds the preview window and `pipe_cache_frames`; it used to be treated as
  spatial, which starved a windowed preview.
- **Every per-frame lookup must add the clip's source-frame offset.** Frame `n`
  in the script is not source frame `n`: the preview decodes a window starting
  at `first` (`PreviewParams::source_frame_offset`), a trimmed encode starts at
  `start_frame`, and double-rate deinterlacing or IVTC before the pass changes
  the count (`ProcessingPipeline::rate_before_stabilize`, composed from the
  `FrameMap`s of the passes ahead of it). Lose any of these and every frame
  gets another frame's factor, with no error.
- **The factor file is per job, never per pipeline.** `VideoJob.pitchFactorsPath`
  (Rust and Dart), set from `QueueItem.pitchFactorsPath`. Pipelines are saved
  into presets shared by every video in the queue. `<video>.pitch.txt` (also
  `<stem>.pitch.txt`, `<stem>_pitch.txt`) is picked up when a video is added.
- **File mode without a usable file is an error**, raised by the script
  generator with the bad line's number — not a silent pass-through.
- **The file format is documented for users in
  [docs/PITCH_FACTOR_FILES.md](docs/PITCH_FACTOR_FILES.md)** (linked from the
  README's pipeline table). Change it with `parse_pitch_factors`,
  `PitchFactorFile.sidecarCandidates` or the factor's meaning (`invertFactors`).
- **Pitch on a still-interlaced clip clears `_FieldBased`** (a vertical resample
  would mix the fields; film scans are progressive). Weave alone leaves it.
- **`pipe_source` raises on a frame it has dropped (task #58).** A pipe reads
  forward only, and VapourSynth asks out of order: vspipe requests a frame
  whenever any completes, so one late callback let the reader read the whole
  clip past it (frames 6–7 served after 99 was read, on a plain job under
  load). It keeps every frame until it is served and `cache_frames` behind
  the oldest frame not yet served, with a memory cap (512 MB beyond the
  window) for frames never asked for; a frame asked for after it was dropped
  raises. It used to return the *last* frame read instead, silently. The
  window is sized from the pipeline's declared radius (`pipe_cache_frames`,
  never below 40), so a pass with a large window must report it through its
  `FrameMap` radius, or its job now fails rather than writing wrong frames.
  `pipe_source_order_test.dart` (push gate) drives the reader in that order.

Tests: `test_211`…`test_218` (script generation, legacy block, offsets, errors,
cache size, field marking) and `app/test/integration_stabilize_test.dart`
(heavy), which injects known breathing with the pass's own file mode and checks
that file mode, auto mode and the preview each bring the picture back toward
the undistorted original.

### Temporary Files Directory

Scratch files default to the system temp directory; the user can redirect them
in **Settings → General → Temporary Files**, persisted as `tempDirectoryOverride`
and loaded by `TempDirectoryService.initialize()` before the first-run deps
download.

- **Dart** call sites must use `TempDirectoryService.instance` (`resolve()`,
  `filePath()`, `createTemp()`) — never `Directory.systemTemp` directly.
- **Rust** needs no per-path plumbing: `ToolLocator.workerEnvironment` sets
  `TMPDIR`/`TMP`/`TEMP` from the effective path, so every `env::temp_dir()` in
  the worker and its ffmpeg/vspipe children follows it. **Any new worker/tool
  spawn must pass `workerEnvironment`** or it silently reverts to system temp.

`resolve()` falls back to system temp if the configured directory can't be
recreated; `setOverride` verifies writability with a probe file before accepting
a path.

### Existing Output Files (issue #85)

Before a job starts, `_getConflictingItems` (`main_window.dart`) checks whether
any queued item's `outputPath` already exists. What happens next is decided by
`OverwriteBehaviorService` (persisted as `overwriteBehavior`, default `ask`,
configurable in **Settings → General → Existing Output Files**):

- **`ask`** (default) — shows `OverwriteWarningDialog`, which now also notes
  where to change the default. Cancelling aborts the job.
- **`overwrite`** — proceeds silently; the existing file is replaced.
- **`rename`** — `OverwriteBehaviorService.uniquePath` picks the first free
  `name (2).ext`, `name (3).ext`, … and each conflicting item's `outputPath` is
  updated to it before the job starts; the existing file is untouched. Mutating
  `QueueItem.outputPath` directly needs a `notifyListeners()` call afterward —
  `MainViewModel.notifyOutputPathsChanged()` is that call for callers outside
  the view model.

### Shut Down When Finished (issue #123)

The progress panel's **Shut down computer when the queue finishes** checkbox is
`MainViewModel.setShutdownWhenDone`, backed by `SystemShutdown`
(`app/lib/services/system_shutdown.dart`, injectable like `JobRunner`). Rules,
asserted in `shutdown_when_done_test.dart`:

- **Never forced.** `osascript` → System Events `shut down` (macOS),
  `shutdown /s /t 0` (Windows — any `/t` above 0 implies `/f`),
  `systemctl poweroff --no-ask-password` (Linux). A refusal leaves the machine
  on and is shown, never escalated.
- **Checked when armed, not at shutdown.** `check()` runs when the box is
  ticked — the only time the user is known to be present — so macOS's
  Automation prompt is answered then rather than blocking all night, and Linux
  arms only when logind's `CanPowerOff` says `yes` (not `challenge`).
- **One run only.** `_stopProcessing` disarms it, so a cancelled run can't
  leave it armed — invisibly, since the checkbox only shows while processing —
  for the next one. A queue that ends with failures still shuts down.
- **60 s cancellable countdown** (`MainViewModel.shutdownCountdown`); Done /
  Try Again / a new run cancel it.
- **A failed video's log survives the shutdown.** Just before shutting down,
  `FailureLogWriter` (`app/lib/services/failure_log_writer.dart`) writes
  `<output stem>.error.log` beside each failed item's output path, falling back
  to the source's folder. It holds only that video's lines, from
  `MainViewModel._itemLogs` — the shared `_logMessages` interleaves every video
  and is capped. Log lines about a specific item go through `_logForItem`, not
  `_logMessages.add`, or they're missing from its file. Nothing is written when
  the shutdown is cancelled: the user is there to read the log.
- **macOS needs `com.apple.security.automation.apple-events`** in
  `packaging/macos/distribution.entitlements` plus `NSAppleEventsUsageDescription`
  in `Info.plist`; without them the hardened runtime refuses the event (-1743)
  with no prompt, in signed builds only. `package-macos.sh` asserts the
  entitlement after signing.

### Keyboard Shortcuts, Timeline and Themes (issue #102)

- **`AppShortcut` (`app/lib/models/app_shortcut.dart`) is the one list of
  shortcuts** — key, modifiers, and the label tooltips print. A button with a
  shortcut takes its tooltip from it (`shortcut.tooltip` /
  `tooltipFor(...)`), never a hand-written string, so the hint can't drift
  from the key. `MainWindow._shortcutBindings` maps each to an action, `null`
  when it can't apply (the key then passes through).
- **Shortcuts must never take keys from text input.** `AppShortcutScope` is a
  `Focus` around the main window, so focused widgets that handle keys
  (sliders, dropdowns) get them first; a typed letter, though, still bubbles
  up as a raw key event, so every shortcut **without** Cmd/Ctrl is ignored
  while focus is inside an `EditableText`. `app_shortcut_test.dart` asserts
  this with a real `TextField` and checks no two shortcuts share a key.
- **Timeline zoom keeps its anchor on screen** (`TimelineMath`,
  `MainViewModel.zoomTimelineBy`): the point under the cursor for the wheel
  and pinch, the playhead for buttons and keys. Recentring on the anchor made
  the strip jump. Thumbnails record the span they were generated for
  (`QueueItem.thumbnailRange*`) and are drawn over that span in the current
  view, so they stay in place during the regeneration debounce. Controls in
  the transport and zoom bars are always present (disabled, not removed) so
  nothing shifts as the zoom changes.
- **In/out points are scrubber positions, and only `FrameMath` turns them
  into frames** (task #59). `QueueItem.inPointFrame` / `outPointFrame` use
  `FrameMath.frameForPosition` (`round(pos × (N − 1))`), the scrubber's own
  rule, and the encode, preview and detector jobs all read them. The old
  `round(pos × N)` started a second-half in point one frame late and turned
  an out point at the end into frame N, one past the last (the output
  repeated its last picture). `trim_points_test.dart` fails on any other
  position × frame count in `app/lib`; `integration_trim_points_test.dart`
  (heavy) checks the encode against an independent decode.
- **Preview 1:1 (issue #8) means one stored pixel per *physical* screen
  pixel**, so `BeforeAfterComparisonWidget` derives the scale from the frame's
  real size (`encodedImageSize`, read from the PNG/JPEG header), the fitted
  size and the device pixel ratio — recomputed every build, so a resize stays
  at 1:1 — and snaps the frame's corner onto the physical pixel grid, since
  off-grid nearest-neighbour sampling repeats rows. Anamorphic frames are
  exact vertically (stretched horizontally by SAR). The shortcuts reach the
  widget's zoom through `MainViewModel.previewZoom`
  (`ComparisonZoomController`); `before_after_comparison_test.dart` covers it.
- **Preview view mode (Original / Split / Processed)** is
  `MainViewModel.previewViewMode` (shortcuts B / S / P), passed into the
  controlled `BeforeAfterComparisonWidget`, so it survives scrubber moves and
  new previews. The divider spans the full 0–1 of the panel (it was 5–95%,
  which hid a typical left crop); line and handle are drawn inset at the
  edges. Each mode draws only its side at its own aspect, and 1:1 measures the
  frame on screen (Original: the source; otherwise the processed frame).
- **Themes** are `AppTheme` in `theme_service.dart`, persisted as `appTheme`
  and provided above the MaterialApp. Theme-specific decoration beyond
  `ColorScheme` (Pride's stripe) goes through the `AppDecorations` theme
  extension. Use `colorScheme` roles, not fixed colours, for UI chrome —
  fixed black/white only belongs on overlays drawn over video.

### Previewing every output frame (issue #129)

A source frame can have several output frames (a frame rate conversion,
double-rate deinterlacing). `--sub-frame K` previews the Kth of those in its
time span `[t, t+1)`; the worker reports `sub_frame`, `sub_frames` and
`generated` on its `PREVIEW_INFO:` line, and the panel steps through them
(`PreviewFrameInfo`, `MainViewModel.stepPreviewSubFrame`).

- **A retime's phase depends on where its clip starts.** The preview's clip
  starts at its window, the encode's at its in-point, so at a ratio that
  isn't a whole number (24 → 60) they generated frames at different moments.
  `ProcessingPipeline::preview_output` is the one derivation: it pads the
  Frame Rate pass's input with copies of the first frame (`{{PREVIEW_RATE_PAD}}`,
  a `PREVIEW_ONLY` block) back to a whole period from the in-point, which the
  preview job therefore carries as `startFrame` (the preview uses it for
  nothing else). `integration_frame_mapping_test.dart` checks every output
  frame against a lossless encode, and fails by 13 levels without the pad.
- **A decimation runs in the encode's phase too (task #46).** IVTC and Soft
  Telecine at 29.97 run VDecimate in the preview, which used to skip it while
  `preview_output` assumed it (the preview was `radius / 5` film frames
  early). VDecimate counts cycles from its clip's first frame, reads the
  frame before each cycle, and never drops a clip's frame 0, so
  `preview_output_in` arranges its input as the encode's
  (`DecimatePreview`): the window's frames before the in-point dropped (for
  IVTC before VFM), `e0 mod cycle` copies of the first frame in front, and
  the clip ended where the encode's ends (the preview job carries `endFrame`,
  else the worker takes `totalFrames`; Soft Telecine's last cycle filled as
  `pipe_frames` does). `FrameMap::Decimate` declares radius `cycle + 1`.
  Which frame of the target's cycle goes depends on the picture: each frame
  is tagged with its index, and a `FrameEval` at the very end
  (`_preview_decimate_pick`, `prop_src` the frame where the target would
  be) picks between the two outputs the walk computed (`after_drop`) and
  prints `PREVIEW_DECIMATE:corr=N` for `PREVIEW_INFO` when vspipe requests
  the frame. **No template requests a frame while the script is
  evaluated** (task #65): the first version read the tag with `get_frame()`
  there, so the target's frame was ready the moment vspipe asked, and
  **R78's vspipe counts a frame done before writing it**: its main thread
  tore the script down under the frame callback (SIGSEGV, 2-3% of x86 IVTC
  previews under load). The bundle's vspipe carries upstream's fix from
  deps 1.18.0 (task #68, see "R78: …" below); before it, any preview could
  still hit it, only far more rarely.
  `test_259` allows only the border colour's one-frame swatch. Stabilize's pitch
  lookup starts at `preview_source_offset` (`first + skip - pad`).
  `integration_ivtc_preview_test.dart` (heavy) checks previews against a
  lossless encode by the film frame they hold, and repeats the decimating
  preview 36 times (docs/reports/issue-46-ivtc-preview,
  docs/reports/task-65-ivtc-preview-teardown). An IVTC test needs a source
  with pulldown: on progressive frames IVTC keeps each frame unchanged
  (`_telecineFixture` in the parity test).
- A source frame with no output of its own (down-conversion, decimation)
  shows the output just before it, as the preview always has.

### Unblend (SRestore) (app 1.8.0)

The Unblend pass (`UnblendParameters`, `PassType::Unblend`) recovers the
original frames of a frame-rate conversion done by blending. Rules, from
[docs/reports/2026-11-srestore](docs/reports/2026-11-srestore/index.html):

- **Never call `haf.srestore`.** On R78 it is plain decimation: it relied on
  `std.Cache(make_linear=True)`, which R78 ignores, and its detector's
  history only advances on consecutive frames, which `ChangeFPS` never
  requests. `worker/templates/srestore.py` runs upstream's arithmetic
  unchanged (`_Detector.step`); keep it line for line with havsfunc.
- **Every decision is a pure function of a window**: a replay over frames
  `max(origin, n - UNBLEND_WINDOW) .. n` with fresh state, in encode and
  preview alike. The detector's phase tracker never converges from a fresh
  start, so pre-rolling a preview or forcing linear access cannot make it
  match the encode. No state may survive between frames other than memos of
  pure values.
- **Its own pass, right after Deinterlace** (before Edge Repair): denoising,
  deflicker, sharpening, grain and resizing all change what the detector
  measures. Not a Frame Rate method; the two combine.
- **The preview pads and tells the detector where real frames start**
  (`PreviewOutput::unblend_pad` / `unblend_origin`, `{{PREVIEW_UNBLEND_*}}`),
  computed by `preview_output`, which walks every retime the same way. The
  `FrameMap` radius covers the replay's start index (window + 8), not only
  the pixels it reads: a radius of the measured reach mismatched.
- **The measurement clip's cache is pinned** (`std.SetVideoCache` in
  `stats_clip`). Each decision reads it through one shifted copy per window
  frame; left to automatic sizing it was evicted and QTGMC ran ~3x.
  Picks come from a few pre-built shifted clips, never a node per frame.
- **Only exact ratios run.** srestore computes `numr/denm` in floating point;
  `unblend_ratio` (Rust port, tested against the report's
  `data/ratio_table.json`) refuses any target where that is not exactly the
  target/input ratio, or where srestore would not decimate (not lower, or
  below a fifth). The script raises on the same condition. The app warns with
  the same wording (`unblendTargetProblem`) and advises on Deinterlace off,
  single rate or IVTC (`pass_advice.dart`).
- Not exposed: `thresh`, `mode`, `omode`, `speed` (upstream defaults); no
  built-in preset turns it on.

- **Its decisions are not stable to a level of input change** (task #64):
  the detector thresholds min/max statistics of blend maps, so QTGMC's
  rounding at 10 bits (~0.35 levels) moves ~10% of decisions and ~5-8% of
  output frames to a neighbouring original, with recovery as good. Never
  expect two depths, deinterlacers or plugin versions to pick the same
  frames; only the same picture at two depths (an exact shift) does.

`integration_unblend_test.dart` (heavy) checks recovery on the blended
fixtures (`generate_blended_test.sh`) against plain decimation, exact length
and rate, depth two ways (the same picture at 8 and 10 bits: identical
output; a real 10-bit source: as good a recovery, mostly the same picks),
and preview = encode.

### Frame Rate targets (issue #129)

The Frame Rate pass offers the six broadcast rates plus **`custom`**, whose
rate is `FrameRateParameters.customFps` (a plain number, default 48).

- **The worker alone turns it into a fraction**: `custom_fps_fraction`, via
  `FrameRateParameters::target_fraction`, which both the script and
  `FrameMap::Retime` use. It must be exact. NTSC decimals (23.976, 29.97,
  59.94, …) become n×1000/1001, never 2997/100, which would drift against an
  NTSC source. Anything else is taken to three decimals. Out-of-range input is
  clamped to 1–240 rather than refused: the panel's number box doesn't
  enforce the schema's bounds. The Dart enum carries no numbers.
- **FlowFPS's length is set by the script, not MVTools.** macOS arm64 and
  Linux build MVTools `master` (`floor(n * ratio)` frames), Windows and macOS
  x64 ship v24 (`floor((n - 1) * ratio) + 1`). The script trims or extends
  to `floor(n * ratio)` after the call (`test_184`); a frame-count assertion
  that passes on one platform proves nothing about the others.
- **Don't check an NTSC output rate on an MKV.** Matroska's 1/1000 timebase
  can't hold 60000/1001, so ffprobe reports an estimate (`19001/317`) for any
  NTSC rate. `integration_frame_mapping_test.dart` encodes its custom-rate
  test to MOV for that reason.

### GPU Plugins: RIFE and AI Upscaling

Two features run a neural network through ncnn on Vulkan: **RIFE** 4.26
(`rife.RIFE`), the Frame Rate pass's `FrameRateMethod::Rife`, and **AI
upscaling** (vs-mlrt's VSNCNN, `ncnn.Model`, with Real-ESRGAN's anime video
model, Real-CUGAN or AnimeJaNai), Crop & Resize's `UpscaleMethod::RealEsrgan` /
`RealCugan` / `AnimeJanai`. `worker/src/gpu_plugin.rs` (`GpuPlugin::{Rife, Upscale}`) holds
everything they share, and the rules all follow from one fact: **without a
usable Vulkan implementation ncnn can segfault** (RIFE does, in
`ncnn::create_gpu_instance`; VSNCNN raises "get_gpu_device failed") rather
than fail cleanly.

- **Plugins in the bundle, models in add-ons (deps 1.16.0).** RIFE's model
  is the `frame-rate-rife` add-on (upstream's ncnn conversion, fetched from
  the plugin's repo at a pinned commit, installed under
  `rife-v4.26_ensembleFalse/` because the plugin reads the model version — and
  its padding — from substrings of that path); Real-ESRGAN anime and
  Real-CUGAN are `upscale-anime` (vs-mlrt's ONNX files, byte for byte, which
  we host because vs-mlrt publishes them only in an ~810 MB archive). Both are
  declared in `ProcessingPipeline::required_addons()` and refused through
  `addons::require` like every add-on; the panels prompt via
  `modelAddonSelectedBy`, on choosing the method and on switching the pass
  on. `attribution_test.dart` fails if the bundle lists a model or a
  `download-deps-*` script fetches one.
- **Never autoloaded.** RIFE lives in `vapoursynth/rife/`, VSNCNN in
  `vapoursynth/ncnn/`, and on macOS the MoltenVK both use in
  `vapoursynth/moltenvk/` — all outside the plugin directory. The templates
  `LoadPlugin` them inside `{{#FRAME_RATE_RIFE}}` / `{{#UPSCALE_AI}}` only, so
  a missing runtime DLL, a broken driver or AVX in a static initializer can
  only affect a job that uses them. Don't move them into `plugins/` /
  `vs-plugins/`.
- **macOS preloads MoltenVK** (`ctypes.CDLL(..., RTLD_GLOBAL)`) before the
  first call: both dylibs leave `vkGetInstanceProcAddr` to whatever is already
  in the process.
- **One probe, one wording.** `gpu_plugin.rs` prechecks the platform and files,
  then runs the plugin once in a throwaway vspipe on a **stand-in network of
  its own** — never an add-on, so "can't run here" is known before anything
  is downloaded: VSNCNN gets `NCNN_SELFTEST_MODEL` (264 bytes, a 1x1 conv,
  `Scripts/models/make_ncnn_selftest.py`) as bytes
  (`path_is_serialization=True`), RIFE a two-layer weightless `flownet` with
  its v4 blobs written beside the script — and checks the answer (a wrong one
  is `WrongResult`). It prints stage markers so a
  silent crash still says where it died, and classifies the result into a
  `GpuPluginReason` with a user-facing remedy (`GpuPluginStatus::message`,
  naming the feature). The app shows that text the moment the feature is
  selected (`--probe-rife` / `--probe-upscale`, `gpuPluginSelectedBy`,
  `gpuPluginNoticeFor`, with a *Check again* button); the worker refuses such
  a job with the same text (`ScriptGenerator::with_rife` / `with_upscale`,
  `ensure_methods_ready`) rather than emit a script that would crash. Only a
  **positive** result is cached per boot (`rife-probe.json`,
  `ncnn-probe.json`) — a cached failure would keep blaming a driver the user
  has just installed. `VAPOURBOX_DISABLE_VULKAN=1` forces the unavailable path.
- **Platforms:** macos-arm64, windows-x64 (both tiers), linux-x64 (both tiers),
  for both. `gpu_plugin::platform_ships_rife` / `platform_ships_upscale` and
  `_extraFiles` in `deps-expected-plugins.json` must agree
  (`attribution_test.dart`). macOS x64 has no MoltenVK copy or usable RIFE
  prebuilt; linux-arm64 has no upstream RIFE and Tencent publishes no aarch64
  Linux ncnn.
- **RIFE: real frames pass through untouched.** It works in RGBS; every output
  frame it would merely copy (an exact source position, the held tail) is
  taken from the source by `FrameEval`, so photographed frames are bit-exact.
  The count is `floor(n * num / den)` of the reduced ratio — exactly
  `FrameMap::Retime`. That ratio needs the source rate, which the app does
  **not** send: `VideoJob::effective_pipeline` fills `sourceFpsNum/Den` from
  the job's input rate, and the ratio is taken against the rate *at the pass*
  (×2 after double-rate deinterlacing). Without that the progress total stays
  at the source count and pins at 100% with no ETA (issue #134). `sc=True` with `misc.SCDetect` holds the frame across a
  cut rather than blending two shots.
- **Don't expose RIFE's scene-change threshold or `skip` (issue #129).** On
  real footage no `SCDetect` threshold separates cuts from fast motion — it
  only trades blended cuts for held frames in action — and `skip` needs a VMAF
  plugin no bundle ships, for a speed-only gain (RIFE already returns a static
  pair unchanged). MVTools' motion-compensated `SCDetection` halved the
  mistakes on one clip but missed cuts between dark shots; switching needs
  more footage first. See docs/ENGINEERING_NOTES.md (2026-11-03).
- **Upscaling: models, factors, tiles.** Five of vs-mlrt's ONNX conversions
  are the `upscale-anime` add-on (`upscale_addons::MODELS`, files prefixed
  `upscale-`): Real-ESRGAN animevideo 2x/4x and Real-CUGAN 2x at three
  strengths. Factors follow the edge-directed path's
  rule (3x behaves as 2x); CUGAN 4x is its 2x model twice, denoising on the
  first pass only (`CropResizeParameters::ai_upscale_models`). Above SD the
  frame runs in 512-px tiles with 16 px overlap — whole-frame CUGAN at 1080p
  ran out of GPU memory on a 16 GB Mac. Float RGB in and out with the source's
  matrix/range, odd sizes edge-padded, frame props copied back, fp16 (≤0.3/255
  from fp32, ~3x faster). Real-ESRGAN measurably tints flat colour (up to ~11
  levels at 4x, in fp32 too); that is the model, not the pipeline.
- **AnimeJaNai** (`UpscaleMethod::AnimeJanai`) runs on the same plugin and
  block, but its models are an **add-on**, never in the deps bundle — they are
  CC BY-NC-SA 4.0, non-commercial only, and the bundle must stay freely
  redistributable (see "Add-ons"). Each doubling is an `(sd, hd)` pair the
  script picks by height (`_ai_rgb.height <= 576` → the SD model), so the size
  and Sharp settings only reach HD pictures, and a 4x DVD runs SD then HD.
  `ensure_methods_ready` also refuses it when `animejanai::runtime` finds the
  models missing (`MISSING_MESSAGE`). It keeps flat colour within 0.5 levels
  (Real-ESRGAN: up to 11).
- **Live-action models are manifest add-ons on the same block** (app 1.7.0,
  `upscale_addons.rs`): `upscale-general` — Real-ESRGAN General
  (`realesr-general-x4v3`, optional denoise variant `-wdn-`) and jcj83429's
  2xLiveActionV1 SPAN (Apache-2.0, upstream's ONNX pinned at a commit) — and
  `upscale-esrgan-plus` — Real-ESRGAN x4plus/x2plus. Real-ESRGAN publishes
  `.pth` only: `Scripts/models/convert_realesrgan.py` converts (opset 13,
  x2plus's `pixel_unshuffle` as a one-hot stride-2 conv, which ncnn imports)
  and we host the ONNX on `addon-models-v1`. They run on VSNCNN, so they need
  no `ai-runtime` and exist exactly where VSNCNN ships (asserted). Declared in
  `required_addons()` via `UpscaleMethod::addon`; the panel prompts with
  `upscaleAddonSelectedBy`. **Factor rules:** General is 4x only, so 2x runs
  4x and resamples down (`{{#AI_RESAMPLE}}`, Spline36 in float RGB — as
  upstream's `--outscale`); SPAN is 2x only, 4x runs it twice; x2plus/x4plus
  by factor. **x4plus runs in 384-px tiles above 384x384** (`ai_tiling`):
  whole-frame at 720x576 lost the Vulkan device on a 16 GB Mac and 512 tiles
  thrashed (29 s a frame); ~7 s a DVD frame at 4x. **A tile never exceeds
  the frame** (`min(tile, width/height)`, every method): a tile larger than
  the frame in either direction segfaults VSNCNN, and a wide, short picture
  passes the area test. Flat-colour drift vs
  Spline36: General 2.9, SPAN 0.6 (2x) / 1.3 (4x), x2plus 4.2, x4plus 12.2.
  2xVHS2HD (RealPLKSR) was probed and **rejected**: ncnn's importer has no
  ScatterND/Shape/Range/Where in its ONNX (see
  docs/reports/2026-11-ai-upscale-addons).
- **AI strength** (`aiStrength`, 0-1, default 1) applies to every AI method:
  one `std.Merge` of a Spline36 upscale of the same frame with the network's
  result, at the clip's format, before the props copy (`{{#AI_STRENGTH}}`).
  At 1.0 the block is removed and the script is byte-identical to one without
  the field (`test_188`); 0.5 halves a model's tint (11.2 → 5.8 levels).
- **VSNCNN is built from source on macOS and Linux** (only Windows has a
  published build): static protobuf v3.21.12 and onnx at vs-mlrt's pinned
  commit, Tencent's prebuilt ncnn 20260526, VapourSynth's API 3 headers from
  the R78 tag. Every pin is in all three `download-deps-*` scripts, which
  install no model.
- **Tests that need a Vulkan device are tagged `gpu`, and CI leaves them
  out.** The hosted runners have no GPU, so the push gate runs
  `--exclude-tags heavy,gpu` and nightly `--tags heavy --exclude-tags
  gpu` (`app/dart_test.yaml`). Without a device CI still checks that each
  probe answers with a real reason (not `probeFailed`) and that a job that
  cannot run is refused with the probe's wording. **Run the `gpu` tests on a
  machine with a GPU after touching RIFE, VSNCNN, MoltenVK, the upscale
  block or a model add-on**, with `VAPOURBOX_EXPECT_VULKAN=1`
  (`flutter test --tags gpu`, plus `--tags heavy` for the encodes): under
  that variable an unavailable feature **fails** rather than skips
  (`app/test/support/gpu_expectations.dart`), so a broken bundle cannot hide
  behind "no GPU". Nothing else proves the Windows and Linux bundles' GPU
  plugins actually run, so do it on those platforms before a deps or app
  release too. Any test that runs a network through ncnn gets the tag (a
  `group` cannot take tags in flutter_test, so tag each `test`).
  `integration_gpu_plugins_test.dart` probes, checks the refusal and the
  script, and renders a real frame per feature;
  `integration_ai_upscale_test.dart` and the RIFE group of
  `integration_frame_mapping_test.dart` (heavy) encode and check pixels — the
  upscalers against Spline36 on a synthetic pattern (colour within 2 levels for
  CUGAN 2x, bar centre within 0.75 px for all). The ONNX Runtime passes (Face
  Restoration, Colourisation) are not `gpu`: they run on the CPU provider
  where there is no GPU, which is a path users take.

See docs/ENGINEERING_NOTES.md (2026-10-24, 2026-10-25, 2026-11-09) for the measurements.

### Descale

The Descale pass (`DescaleParameters`, `PassType::Descale`, app 1.5.0) inverts
a studio's upscale on luma with `descale.De*` (r12, MIT, a PyPI wheel on every
platform, autoloaded — its AVX2 kernel is picked at run time), re-upscales
with NNEDI3 (`_nnedi3()`, doubling to at least the source size, then one
Spline36 resample that also folds in the doublings' half-pixel shifts), and
keeps chroma and the source size. Rules:

- **It runs right after SpotLess, before Noise Reduction** — descale needs the
  upscale exactly as the studio made it. `test_177` asserts the order.
- **Protect credits and text** (`protectDetail`, default on): where
  re-applying the kernel to the descaled picture misses the source by more
  than `detailThreshold` 8-bit levels, the source is kept (binarised, grown
  twice, softened). On a never-upscaled picture that is nearly every pixel —
  correct, and why the parity test switches it off.
- **Detect** (`--detect-native`, `native_res.rs`) is what makes the pass
  usable: getnative's method, with these measured traps. Scan every height
  from half the source's, with one kernel per family (bilinear, Catmull-Rom,
  Lanczos 3, Spline36 — a master only dips under its own); only heights with
  neighbours on *both* sides are candidates (the error slopes down toward the
  source height and a one-sided window reads that as a dip); cap each pixel's
  error at 2 levels before averaging, or credits swamp the dip; rank 12
  kernels at the best height over four sampled frames. `found` only when the
  dip is ≤ 0.5 of its neighbours' median — a never-upscaled VHS capture
  measures ~0.9, a credit-free master ~0.14. All candidates are spliced into
  one clip and read with `frames()`, so VapourSynth runs them in parallel
  (~30 s at 1080p). **The luma is the source's own Y plane**: decoded in the
  pipe format and scaled by `native_res::luma_gray16` (limited expanded to
  full-range GRAY16, full scaled), never a decode to gray — swscale makes
  that with the matrix tag, and a BT.709-tagged copy of a master lost its dip
  entirely. The thresholds are calibrated on this scaling. A fixture for
  any of this must have real detail at its native resolution: an upscale of low-res footage is so smooth that 8-bit
  rounding hides every height's misfit.
- The panel never applies a guess: no clear dip is reported as such.
  `integration_descale_test.dart` (heavy) checks detection on known masters,
  protection (grid exact vs. destroyed without the mask) and preview = encode.

### Crop Detection (`--detect-crop`, app 1.7.0)

Crop & Resize's **Detect borders** (`CropDetectPanel`) runs
`crop_detect::detect`: 24 frames across the source or its trim, decoded as
8-bit 4:4:4 and measured line by line in plain Rust (no VapourSynth). It is
advisory exactly like Descale's Detect: nothing changes until the user picks
Apply crop, Crop the bars too, or Repair the band instead. Rules:

- **Brightness is a high percentile over every usable frame**, so a line that
  carries picture in any frame is picture; a border line must also be flat
  (detail floor 6 levels, so noisy blanking still counts). Frames too dark to
  judge (central p90 < 48) are left out of everything. One line counts only if
  it is true black in every frame (a capture card's first line).
- **Bars wider than 5% of the dimension are framing** (letterbox / pillarbox):
  reported, in `cropWithBars`, never in the recommended `crop`.
- **Head switching**: a bottom line torn against the line above *in the same
  field* (d = 2 when the job's field order is TFF/BFF), in luma or chroma
  across ≥ 6 of 8 width segments, or shifted sideways by ≥ 3 px; in ≥ 50% of
  usable frames; touching the bottom (≤ 2 lines skipped). Breadth and
  persistence are what keep a burnt-in subtitle out.
- **Rounded outward to steps the Crop pass accepts**, in the Crop pass's
  orientation (`orient` maps through Rotate / Flip): even everywhere, fours
  vertically when a 4:2:0 picture is still interlaced at the crop. Edge
  Repair's alternative stays in source orientation and is offered only up to
  its panel's 16-line maximum.
- `confidence` is the share of usable frames whose picture reaches the edge;
  low means thin evidence (a dark film), not a wrong edge. The panel warns
  below 0.25.
- `integration_crop_detect_test.dart` (heavy) builds fixtures from real VHS
  picture with known borders, a band, a letterbox, subtitles and fades, and
  asserts every edge within 2 lines; the unit tests in `crop_detect.rs` cover
  the same traps on synthetic frames.

### Noise and Halo Scores (`--detect-noise-halo`, app 1.7.0)

The pass list badges Noise Reduction and Dehalo as Suggested only from a
measurement of the picture (`noise_halo::detect`), run by
`MainViewModel._measureNoiseHalo` in the background once a source is
analysed, one source at a time, and stored on `QueueItem.noiseHalo`. Rules,
from docs/reports/2026-11-noise-halo-scores:

- **The worker decides.** `NOISE_HIGH` (3.5, sigma in 8-bit levels) and
  `HALO_HIGH` (6.0, % of the step) live in `noise_halo.rs`; the report's
  `noiseHigh` / `haloHigh` are the verdicts, and `relevanceFor` reads only
  those, never the numbers. Change a threshold only with the report's scripts
  re-run (`probelib.final_*` mirrors the Rust; `worker_parity.py` checks them
  against each other; no verdict may differ).
- **Suggest only; a low or missing score is silent.** Both measures
  under-report (codec-skipped blocks read noiseless, sharpening of soft edges
  rings past the plateau zone), so a low score is not evidence and nothing is
  ever `notApplicable` from it. A failed measurement suggests nothing and
  logs nothing.
- **Noise is temporal, not spatial.** Motion-compensated frame difference
  (16x16 blocks, +-10 px, match chosen on smoothed pictures), 10th percentile
  of blocks, 25th percentile of 24 sampled pairs (12 above 1080p). A spatial
  high-pass (Immerkaer, signalstats) is blind to tape-like and grain noise and
  reads dense texture as noise; VCG's TOUT does not respond to noise at all.
- **Halo is per edge and two-sided.** Step edges followed over 7 lines of one
  field, plateaus 6-10 px out; each edge scores min(overshoot, undershoot), so
  a cartoon outline scores 0. Fewer than 200 edges is no score.
- **Per field unless known progressive** (`ScanType.progressive` /
  `softTelecine`), so combing never reads as noise; **luma in the source's own
  format and depth** (a yuv -> gray decode expands the range), in 8-bit units.
- **The whole source is sampled, not the trim**, so the badge doesn't change
  as in / out points move. Uses `crop_detect::decode_samples`, so all
  detectors sample and decode alike.

`integration_noise_halo_test.dart` (heavy) checks real clips: the VHS capture
clean / with sigma 6 noise (8- and 10-bit agree), DVB-T clean / sharpened.

### Add-ons: optional third-party downloads

Anything VapourBox can use but does not ship — because of its size (Whisper)
or its licence (AnimeJaNai) — is an **add-on**: downloaded from its upstream
source into the add-ons directory (`DependencyLocator::addons_dir`, mirrored
by `AddonService.addonsDir`), only when the user asks. Rules:

- **One service.** `AddonService` holds the catalogue (`AddonInfo`: size,
  licence, credit, source, `usageNote` for a restriction, `requires`) and one
  `AddonInstaller` per add-on. **Settings → Add-ons** (`AddonsSettingsTab`)
  lists, installs and removes; a feature that needs one calls
  `AddonPrompt.ensure(context, ids, reason:)`, which states the source,
  licence and size before downloading. Never add a feature-specific download
  dialog. Installing installs requirements first (a Whisper model needs the
  engine); removing removes what requires it, after saying so.
- **A licence restriction is shown, not buried**: `usageNote` is bold in the
  prompt, the Settings row and (for AnimeJaNai) the panel notice whenever the
  method is chosen. Such an add-on also gets a NOTICES entry and About tile
  that say it is a separate download.
- **Pinned and verified**: `assets/animejanai-addon.json` pins upstream's
  release asset by SHA-256 *and* each model by its own hash; extraction
  (`AnimeJanaiInstaller.extractModels`) keeps only the listed files, stages
  beside the target and renames into place, so a bad download installs
  nothing. Upstream re-uploaded that asset once (2024-07), which is why the
  pin matters: a changed asset fails closed.
- **The worker checks presence, the app checks hashes.** `animejanai::MODELS`
  and the manifest list the same files (asserted on both sides).
- **Tested against the real download**: `WorkerHarness.ensureAnimeJanai()`
  installs from the pinned URL with the app's own extraction, so CI fails if
  the link or hashes stop holding.
- **Every AI model is an add-on, never in the deps bundle** — no exceptions
  since deps 1.16.0, when RIFE's and the anime upscalers' models moved out
  (`attribution_test.dart` guards it) — and every new
  add-on is a **manifest add-on**: one `app/assets/addons/<id>.json`
  (format, checklist and hosting: **[docs/ADDONS.md](docs/ADDONS.md)**),
  installed by the generic `ManifestAddonInstaller`
  (`app/lib/services/manifest_addon.dart`) and compiled into the worker by
  `worker/build.rs` (`worker/src/addons.rs`), so both sides read the same
  file. Kinds: `files` (model pack, archive members hash-checked one by one)
  and `python` (wheels unpacked into `addons/<id>/site-packages/`). An install
  is staged in `<id>.new` and ends with the `.vapourbox-addon.json` marker
  (id, version, platform); a manifest `version` bump makes the old install
  count as missing. Whisper and AnimeJaNai keep their hand-written installers.
  A plain file marked `"executable": true` is a program the worker runs
  (DeepFilterNet): the installer sets its executable bit and, on macOS, signs
  it ad hoc if `codesign --verify` fails (Apple Silicon will not run an
  unsigned arm64 binary); the worker finds it with `Manifest::executable_for`.
- **A pass declares its add-ons in `ProcessingPipeline::required_addons()`**
  (`AddonNeed { feature, ids }`); `ScriptGenerator::ensure_methods_ready`
  refuses the job via `addons::require` (naming them and Settings → Add-ons),
  and emits the `{{#AI_RUNTIME}}` block when one needs
  `ai-runtime`.
- **The AI runtime (`ai-runtime`, python kind)** is ONNX Runtime + NumPy for
  the deps Python 3.12: onnxruntime 1.31.1 (macOS arm64, Linux),
  onnxruntime-directml 1.24.4 (Windows), 1.23.2 on Intel Macs (`minOs` 13.0 —
  the last Intel wheel). Passes use `templates/ai_runtime.py` (`setup`,
  `session`, `map_frames`, NCHW helpers): it puts `site-packages` on
  `sys.path` itself because **Windows' embeddable Python ignores
  PYTHONPATH**. `--probe-ai-runtime` runs a committed self-test model the way
  a job would (`ai_runtime.rs`, positive results cached per boot);
  `VAPOURBOX_AI_FORCE_CPU=1` forces the CPU provider.
- **`VAPOURBOX_ADDON_MIRROR=<dir>`** makes the installer (app and
  `WorkerHarness.ensureAddon`) take files from a local directory, still size-
  and hash-checked — how an add-on is tested before its files are uploaded.
  Files we convert ourselves are staged in `addon-staging/` (gitignored, with
  the conversion venv in `addon-staging/convert-venv`) and hosted on the
  `addon-models-v1` release (not Latest), which only the owner uploads to,
  each beside its upstream licence text (`LICENSE-<project>.txt`). While a
  release is in development they may sit on a deps release candidate instead;
  `release.sh` refuses to cut an app release while any manifest names an
  `-rc` tag (docs/ADDONS.md, "Hosting").
- **Tested for real**: `WorkerHarness.ensureAddon(id)` installs an add-on and
  its requirements with the app's own installer; `integration_ai_runtime_test.dart`
  (heavy) installs `ai-runtime` and runs the probe. `manifest_addon_test.dart`
  asserts the worker (`--list-addons`) compiled in the same manifests.

### Face Restoration

The Face Restoration pass (`FaceRestoreParameters`, `PassType::FaceRestore`,
app 1.7.0) finds faces with RetinaFace, aligns each to the FFHQ 512 template,
restores it with RestoreFormer++ (default), GFPGAN v1.4 or CodeFormer, masks
it to the face itself with BiSeNet and blends it back
(`worker/templates/face_restore.py`, on `ai_runtime`). Rules:

- **Models are add-ons, converted by committed scripts.** `face-restoration`
  (RetinaFace R50 + BiSeNet + RestoreFormer++, the base), `face-gfpgan` and
  `face-codeformer` (each `requires` the base; both non-commercial, with a
  `usageNote`). `Scripts/models/make_face_*.py` reproduce the ONNX files from
  upstream checkpoints pinned by hash; files are hosted on `addon-models-v1`.
  Static shapes (detector 640x640 padded, 512x512 faces) so Core ML takes the
  whole graph. GFPGAN is exported with its **fixed noise buffers**
  (upstream draws new noise per call: flicker by construction); CodeFormer's
  `w` is a graph **input** (exact at w = 0). Never ParseNet (CC BY-NC-SA, from
  PSFRGAN) or InsightFace's detectors (non-commercial), whatever upstreams
  default to.
- **After Crop & Resize, before Sharpen** — restored at the delivered
  resolution; first row of the Finishing stage.
- **A pure function of neighbouring frames, never stateful.** Neighbours come
  through `ai_runtime.shifted` clips into `std.ModifyFrame`; shared work
  (detections, each frame's restored faces) through `ai_runtime.FrameMemo`.
  Temporal smoothing (radius 1): landmarks averaged with hysteresis and
  one-frame gap filling, and each restored face averaged in aligned space with
  its neighbours', weighted down where the *input* moved. The preview's
  `FrameMap` radius is **twice** that (`frames_read_either_side`): the blend
  reads a neighbour, whose landmarks read one more.
- **Bit-exact outside the faces**: the restored RGB frame is converted back
  to the source format and composited with `std.MaskedMerge` (mask luma-sized,
  `first_plane=True`), so a zero mask leaves every plane untouched. Never blend
  in RGB and convert the whole frame back.
- **Model runs are serialised per pass** (`ai_runtime.Runner` with one shared
  lock), with a CPU retry if a GPU run fails: concurrent Core ML predictions
  from VapourSynth's threads ran a 16 GB Mac out of GPU memory.
- **NumPy only** — no OpenCV (it is in neither the deps bundle nor the
  ai-runtime add-on); `pipeline_parity.py` in the report checks the NumPy
  detection, alignment and paste-back against facexlib/OpenCV.
- The panel prompts for the model's add-ons (`AddonPrompt.ensure`) when the
  pass is turned on or the model changes, and shows the non-commercial note
  for GFPGAN/CodeFormer; the worker refuses through `required_addons()`.

`integration_face_restore_test.dart` (heavy) checks the face changes and every
sample outside it is bit-exact (8- and 10-bit), each model runs, and preview =
encode. See docs/ENGINEERING_NOTES.md (2026-11-08) and
docs/reports/2026-11-face-restoration.

### Colourisation

The Colourisation pass (`ColorizeParameters`, `PassType::Colorize`, app 1.7.0)
colours black-and-white footage with DDColor-T (default) or DeOldify's Video
model (`worker/templates/colorize.py`, on `ai_runtime`). Rules:

- **The luma is never touched.** The model's colour (DDColor: CIELAB a/b,
  recombined with the frame's own lightness by a chain of `std.Expr` stages;
  DeOldify: RGB) becomes YUV with the source's matrix, is converted to the
  source format, and only its U and V are taken (`ShufflePlanes` with the
  input as plane 0). Y is bit-exact at every depth; strength 0 is the input.
  A source that already has colour is coloured from its luma all the same
  (its own chroma replaced) — said in the panel's text, never blocked.
- **Between Chroma Fixes and Color Correction** (Detail & Color stage): the
  model judges the cleaned-up picture, and the result can be graded. It runs
  before Crop & Resize, so it uses the source's colour tags, not the BT.709
  conversion's.
- **Models are add-ons, one per model** (`colorize-ddcolor`, 220 MB, Apache-2.0;
  `colorize-deoldify`, 870 MB, MIT; each `requires` `ai-runtime`), converted by
  `Scripts/models/make_colorize_{ddcolor,deoldify}.py` byte for byte. DeOldify
  is rebuilt in plain PyTorch (fastai v1 does not install with a current
  torch) and verified against an independent export. Both exports have
  **dynamic** height/width; each session fixes them with ONNX Runtime's
  free-dimension overrides (`ai_runtime.session(..., dims=)`), so one file
  serves every render size and Core ML still gets static shapes. Core ML takes
  each whole graph only because the exports rewrite `ReplicationPad2d`,
  `Tensor.repeat` and DDColor's einsum (`colorize_models_common.py`) — without
  that DDColor split into six partitions and ran 2.6x slower.
- **Core ML compiles DDColor for 50-80 s per session** (every vspipe process;
  DeOldify ~5 s). So the preview script passes `preview=True` (a `PREVIEW_ONLY` line) and DDColor
  previews on the CPU (`colorize.PREVIEW_ON_CPU`); outputs agree to <0.001
  CIELAB units. Don't add `ModelCacheDirectory` casually: its cache is ~900 MB
  per render size and the key is the model path, not the overridden shape.
- **Temporal smoothing is a pure function of frames n-r..n+r**: each frame's
  render-size prediction is averaged with its neighbours' (`shifted` +
  `FrameMemo`), weighted to zero where the grey picture differs
  (`MOTION_LIMIT`), so colour follows motion and a cut takes nothing from the
  last shot. The `FrameMap` radius is `temporal_radius`.
- No built-in preset turns it on (not even the film-scan one): a download of
  220-870 MB and an invented colour are the user's choice.

`integration_colorize_test.dart` (heavy) checks luma bit-exact (8- and 10-bit,
and on a colour source), strength 0 = input, both models, and preview = encode.
See docs/ENGINEERING_NOTES.md (2026-11-08) and docs/reports/2026-11-colourisation.

### Output capabilities: one table (task #49)

`Tests/TestResources/output_capabilities.json` is the one statement of what
each output container holds and how it times it. It widened task #39's Convert
table. Rules:

- **Both sides read the file; nothing restates it.** `worker/build.rs` checks
  its shape (a malformed table fails the build) and compiles it in;
  `models::output_capabilities` reads it (`ContainerFormat::traits`,
  `VideoCodec::container_verdict`, `AudioCodec::supports_container`,
  `audio_copy_allowed`). The app reads
  `app/lib/models/output_capabilities_table.dart`, **generated and committed**:
  after editing the JSON run `dart run tool/generate_output_capabilities.dart`
  in `app/` (and don't `dart format` it). `output_capabilities_table_test.dart`
  fails when it is stale.
- **Container traits** (`containers`): `storesStreamStart` (AVI: no, so a late
  picture, a copy's pre-roll and encoder priming all land at 0 — read by
  `stores_stream_start` and so by `output_video_delay`, `needs_sound_cut`,
  `may_cut_sound_head`, `needs_priming_shift`), `videoTimeBase` (AVI one tick
  per frame), `fieldFlag` (AVI none: `field_order_note`), `audioPacketTiming`
  (AVI `blockAlign`: `avi_header::checks_block_align`), `restoredPassthrough`
  (`restored_passthrough_codec`, after the editing intermediates' PCM
  override), `subtitles` (copy / mov_text / none) and `isoMedia` (faststart,
  `hvc1`). **No code outside the table module compares or matches on a
  container**: `no_container_is_compared_outside_the_table` (Rust) and its
  Dart twin fail on `== ContainerFormat::…` / `case ContainerFormat.…`. A new
  container fact is a new column, not a boolean.
- **Video: three verdicts per codec × container** (`video`), measured against
  the bundled FFmpeg (docs/reports/task-49-output-conformance): `offered`
  (the app offers it: `supportsContainer`), `notOffered` (FFmpeg writes it,
  the app keeps it off, the worker runs it with the row's note — the
  field-order test needs HuffYUV in MOV), `refused` (HuffYUV, FFVHuff, ProRes
  and v210 in MP4 and AV1 in MOV, which FFmpeg can't write; AV1 in AVI, which
  it writes with a non-standard tag, `ffmpegWrites: true`). The worker refuses
  a refused pair in `run_worker` before any work, with the row's message; the
  app's pre-run check offers the codec's own container
  (`EncodingSettings.videoContainerProblem`).
- **Audio**: `audioConvert` is #39's table (Opus into AVI/MOV and FLAC into
  MOV refused; the Codec dropdown lists `audioCodecChoices`, the container
  switch applies `fallbackFor`, a preset that still pairs them gets a "Use
  <fallback>" dialog, the worker refuses via `audio_container_problem`).
  `audioCopy` is the Passthrough copy table (issue #118), which the worker now
  checks too: the source model's audio codecs (`audioStreams`), refused with
  `audioCopyMessage` (`audio_copy_problem`, Dart
  `AudioCompatibilityService.copyProblem`); a stream Audio Restoration
  re-encodes is not checked.
- **Checked against FFmpeg both ways** in the push gate
  (`output_capabilities_test.dart`): every video row muxed (hardware encoders
  through their software twin, `muxEncoder`), every Convert codec, every
  copied codec. The table is self-consistent (`the_table_is_consistent`: the
  restored track is a codec its container copies, every codec's preferred
  container is offered, the container switch lands on offered pairs).
- **The output conformance matrix** (`integration_output_conformance_test.dart`,
  heavy) encodes every container × audio mode (Passthrough, Convert × each
  codec the container takes, Restore, Restore + Convert AAC) × source class
  (plain MP4, late-video TS, delayed AVI, reset PS through the continuity
  copy) × trim (none, from frame 2, from frame 40), plus ProRes/MOV and
  AV1/MP4 rows and trims to the last picture for the primed Convert codecs
  into AVI (`tailCases`), from `generate_output_conformance.sh`'s
  flash/click sources: 448 cases, generated from the enums and the table
  (`test/support/output_matrix.dart`, which also holds the oracle; the push
  gate's `output_matrix_cases_test.dart` checks the cases). Each checks the
  header, picture count and first picture, no null frames, every flash's
  click within one audio packet **of where the source has it** (each
  source's own lag, measured: `conf_delayed.avi`'s MP3 is 23 ms late by
  libmp3lame's priming, which AVI cannot mark), packet timing, and lossless
  paths sample- or byte-exact (a restore against the render's decoder).
  **A new container fact or source rule gets a case here, not another
  one-cell heavy test.** Cases that fail today are `knownFailures` (id →
  task; empty since task #58); they still run and fail when they pass. One
  case:
  `flutter test --tags heavy test/integration_output_conformance_test.dart
  --plain-name 'avi/convert-aac/delayed-avi/near-start'`. The shared
  measuring helpers are `test/support/av_sync.dart`.

### Audio Restoration

The one pass that works on the soundtrack (`AudioRestorationParameters`,
`ProcessingPipeline.audio`, app 1.7.0), in the pass list's "Audio & Subtitles"
stage. **Not a VapourSynth pass**: it is not in `PassType` (Rust) or
`enabled_passes`, never touches either `.vpy` (`test_185`), and the preview is
picture only (the panel says so; its edits don't regenerate the preview).
Rules, from docs/reports/2026-11-audio-restoration:

- **Rendered before the encode, to a WAV, then mapped by the encoder** — never
  an `-af` on the encode. That is what makes DeepFilterNet (a separate
  program), two-pass loudness, a negative offset (reading audio from before the
  trim point) and transcribing the output's own soundtrack possible, and it
  keeps audio independent of how the video encode is run. `RenderedAudio` owns
  the scratch directory and is held to the end of the job (after the mux).
- **One decision site, fixed order.** `AudioPlan::new` chooses every filter:
  `aresample=first_pts=0` (a stream that starts after the video keeps its gap —
  a WAV has no timestamps) → [`atrim=start_sample` + `asetpts`: the read's
  head, only where a delayed AVI cannot seek its sound, `source_decode` rule
  9] → `pan` → `adeclip` → `adeclick` → rumble `highpass`
  → hum `bandreject` ×3 → `afftdn` + `atrim` of its delay → drift resample →
  lead `adelay` → [DeepFilterNet] → `loudnorm` + `aresample` → `alimiter` →
  `apad`+`atrim` to the picture's length. Each ffmpeg run gets one `-af`
  (`every_combination_keeps_the_order_and_one_af_per_run`, 512 × 5 cases).
- **MP1/MP2 are read with the float decoder** (`render_decoder`:
  `mp2float`, task #58). FFmpeg's default for them is fixed-point, which
  rounds with an error carried from frame to frame, so a render that seeked
  differed from the source's decode by one 16-bit step in ~40% of samples;
  the float decode is exact from any seek. MP3 and AC-3 default to float
  already; Convert and the analysis keep the default.
- **Measured traps, each now handled in the plan:** `afftdn` outputs 25 ms
  late at every rate (`atrim=start_sample=rate/40`); its default `nf=-50` took
  0.7 dB off −39 dB hiss — it gets the source's measured floor (quietest tenth
  of 50 ms windows, clamped −80…−30), and never `tn=1`, which undid it;
  `alimiter` needs `latency=1` (else it delays by its attack) and `level=0`
  (else it normalises up to 0 dBFS); `loudnorm` resamples to 192 kHz, so an
  `aresample` follows it; DeepFilterNet delays 30 ms — `-D` compensates and
  shortens the tail, which `apad` restores.
- **Drift is corrected by resampling, not `atempo`.** atempo moved every click
  ~20 ms early; drift is a sample-clock error, so resampling restores pitch as
  well as length. `asetrate` takes only an integer, so the plan upsamples to an
  `r1` in 4–8× the rate where `s / r1` is within ~1e-11 of the factor
  (`resample_ratio`). The factor is (whole source's audio length) / (whole
  encoded picture's length, `ProcessingPipeline::output_duration_secs` —
  output frames over output rate from the `FrameMap`s); applied only when the
  difference is > 0.05 s and ≤ the user's cap (0.5% default), skipped within
  1e-6 of 1.
- **Offset and drift compose on the source's timeline**: source time for output
  time t is `(start + t − offset) × factor`; a positive offset from the start
  is silence (`adelay`), never a negative seek.
- **The window is the encoded picture's** (`OutputWindow::for_job`): from the
  trim's in-point, `output_duration_secs` long. The rendered track is exactly
  that many samples, so with restoration the output's audio is the picture's
  length (passthrough could leave it longer).
- **"Start the sound with the picture"** (`startWithPicture`) drops the sound
  before a late-starting video's first picture: the window starts at the
  offset and the encoder's video delay goes to 0. It has no value (the worker
  reads the gap from the timestamps) and does nothing without a gap. The pass
  list suggests the pass when the gap is ≥ 0.25 s
  (`videoStartSuggestThreshold`; ffmpeg's TS muxer leaves 10–21 ms), and the
  panel describes any gap; neither ticks anything. In AVI output it changes
  nothing (AVI already starts with the picture), so the suggestion is not
  shown there (`relevanceFor(..., container:)`). See "Source Frame Size".
- **One stream is restored** (`streamIndex`, default the first). The encoder
  maps the rendered track first, then the source's other audio streams
  untouched (trimmed into AVI, cut like any copy: `SoundCut`), each with its own tags (`encode_map_args`; naming one stream's
  `-map_metadata` switches off ffmpeg's copying for the rest). Passthrough
  copies the others but must encode the restored one: FLAC in MKV, AAC at the
  chosen quality in MP4/MOV, and 24-bit PCM (`pcm_s24le`) in AVI beside any
  codec and in any container beside an editing intermediate, ProRes or v210
  (`restored_passthrough_codec`, which returns its own `RestoredTrackCodec`:
  `AudioCodec::Pcm` is the user's Convert choice and stays `pcm_s16le` on the
  wire; the per-container choice is the table's `restoredPassthrough`, see
  "Output capabilities"). No restored track is 16-bit. The render is f32; ffmpeg's FLAC from it
  is already 24-bit, and the same render as FLAC/MKV and 24-bit PCM in
  MOV/MKV/AVI decodes bit-identical. 24-bit PCM in AVI can only be
  `WAVE_FORMAT_EXTENSIBLE`; Video for Windows, DirectShow, Media Foundation
  and VirtualDub 1.10.4/VirtualDub2 read it sample for sample, ACM refuses
  24-bit in any header, Premiere and Vegas are untested
  (docs/reports/2026-11-intermediate-pcm-depth, F6). Convert → PCM is the
  16-bit way out.
- **Automatic choices are measured, never guessed**: a dead channel (≥30 dB
  below the other, which is above −60 dBFS) and 50/60 Hz hum (Goertzel over
  2 s blocks, a line ≥12 dB above its neighbours) are read from a minute in
  the middle of the window; finding nothing leaves the audio alone and says so.
- **DeepFilterNet is the `deepfilternet` manifest add-on** (upstream
  deep-filter 0.5.6 binaries pinned by hash, MIT OR Apache-2.0, `minOs` 13.0
  on macOS since upstream builds target it). The worker checks it in
  `AudioRestorer::plan` (`DEEP_FILTER_FEATURE`), **not** in
  `required_addons()`: that list gates the script generator, and a preview
  must never be refused for an audio add-on.
- **No built-in preset turns it on** (audited when it shipped): every step
  depends on the recording, and switching the pass on re-encodes audio that
  the presets otherwise copy. A source preset may later enable only the
  self-checking steps (automatic channel fix, automatic hum), which do nothing
  when they find nothing.
- `vapourbox-worker --audio-plan --config job.json` prints every argument list
  without rendering (`integration_audio_plan_test.dart`, push gate);
  `integration_audio_restoration_test.dart` (heavy) measures the encoded audio.

### BM3D and KNLMeans Noise Reduction

Two advanced-only Noise Reduction methods (`bm3d`, `knlmeans`, app 1.5.0;
the simple slots are full at four).

- **BM3D works in 16-bit, one GRAY plane at a time.** `VAggregate` always
  returns 16-bit and `VFinal` needs its basic estimate in its input's format,
  so the block converts up and restores the source format with dither. BM3D
  refuses subsampled chroma, so each plane is its own GRAY clip: 4:2:0 chroma
  is denoised at its own resolution rather than resampled to 4:4:4 and back.
  `sigma` is in 8-bit units at every depth (parity 0.36/255 at 10-bit).
- **BM3D ships everywhere from deps 1.14.0**, pinned to r12 (`BM3D_TAG` on
  macOS/Linux = PyPI wheel 12.0 on Windows). Before, only macOS arm64 had it:
  Linux's `patch_meson_vs_include` missed r12's nested
  `include_directories('include', run_command(py, '-c', 'import vapoursynth…'))`,
  and macOS x64 never ran `build_plugin`. Both failed silently because the
  plugin wasn't in their `deps-expected-plugins.json` lists.
- **KNLMeansCL is Jaded Encoding Thaumaturgy's fork, v1.3, on every
  platform** (issue #144): tag `v1.3` from source on macOS/Linux (`KNLM_TAG`),
  PyPI wheel 1.3 on Windows; keep them in step. Never Khanattila's v1.1.1
  release (refuses 9–15-bit except packed YUV444P10, so every 10-bit 4:2:0
  source failed on Windows) or master (races its buffer fills on Apple's
  OpenCL: unrepeatable, sometimes garbage). No runner has OpenCL, so after
  touching it run the KNLMeans cases of
  `integration_high_bit_depth_filters_test.dart` on a machine with a GPU —
  they skip otherwise.
- **KNLMeans has its own device probe**, separate from `knlm_available`.
  havsfunc calls KNLMeansCL with the default `device_type="auto"`, which
  failed on Apple Silicon (`CL_INVALID_VALUE`) before v1.3, where `"gpu"`
  worked; v1.3's `auto` works there, so QTGMC's `knlmeanscl` now runs on a Mac
  instead of falling back to DFTTest. `knlm` still answers for QTGMC's call, and `DependencyLocator::knlm_device` (gpu, then
  auto; `knlm-device-probe.json`) is the device our own call passes. With no
  device the job is refused with `KNLM_NO_DEVICE_MESSAGE`, the same text the
  panel shows (`knlmDevice`/`knlmMessage` from `--probe-opencl`), through
  `ScriptGenerator::with_knlm` / `ensure_methods_ready`, as for RIFE.
- **The Noise Reduction pass's preview radius is per method**
  (`NoiseReductionParameters::temporal_radius`): BM3D's Final step re-reads
  its basic estimate's neighbours, so it reaches 2r; a fixed 3 was too few.

### SangNom, NLMeans (CPU) and the vs-jetpack ports (deps 1.16.0, app 1.7.0)

Five classical additions, all in the deps bundle (no add-ons). The evidence is
[docs/reports/2026-11-classical-filters](docs/reports/2026-11-classical-filters/index.html).

- **SangNom is its own Anti-aliasing method, never santiag's `type`.**
  havsfunc's `santiag(type="sangnom")` calls `SangNom(order=0)` at strength
  0, which SangNom r45 treats as double-rate: it refuses a clip without
  `_FieldBased` and would double the frame count with it. So
  `effective_santiag_type` stays pinned to nnedi3 and `AntiAliasMethod::SangNom`
  runs its own block (2x Spline36, `SangNom(order=1)` per axis, back down,
  field order restored — SangNom flags its output progressive). `aa` is in
  8-bit units; the plugin scales it (8 vs 10-bit: 0.05 levels).
- **SangNom's licence is split**: the source header and LICENSE grant MIT
  (james1201, Victor Efimov) and the same header says "Binaries are GPL v2";
  the PyPI wheels we ship declare GPL-2.0. NOTICES, About and the README say
  both. One file per platform from the r45 wheels; x64 is SSE2 only, so no
  `_tierFiles` entry.
- **vszip must be >= 24.0.0** — the first release with the CPU `NLMeans`
  (WNNM has been there since 22.0.0). `vapoursynth_integration_test` checks
  `vszip.NLMeans` itself, not just the namespace, so a stale 22.1.0 bundle
  fails. macOS x64 builds the sdist with **Zig 0.17.0** (`-Doptimize=fast`;
  0.17 renamed the modes), and the headerpad patch now matches the
  8-space `lib.use_llvm` inside `if (build_vs)`. vszip 23 made CLAHE accept
  every depth; the template still feeds it 16-bit and its parity test holds
  (1.34 levels against a 3.0 tolerance).
- **NLMeans (CPU)** (`NoiseReductionMethod::NlMeans`, advanced) shares the
  `knlm_*` parameters with KNLMeansCL: same algorithm, same arguments, same
  picture (0.000 levels apart on the probe, 0.0003 in the heavy test). It
  needs no OpenCL, so `KNLM_NO_DEVICE_MESSAGE` (and the app's fallback text
  in `worker_manager.dart`) names it as the way out.
- **WNNM is not a method.** Measured against the shipped BM3D on three Kodak
  pans at sigma 4/8/12, each at its best sigma: luma +0.7 to −2.3 dB (ahead
  only at sigma 4 with a temporal radius), chroma 2.6–7.2 dB worse. It is
  fast (10 fps at 1080p with a temporal radius on an M1 Pro, where the shipped
  BM3D path runs 0.2 fps), but NLMeans (CPU) fills that niche with better
  chroma (23 fps).
  Revisit only with a reason BM3D's quality and NLMeans' speed don't cover.
- **The vs-jetpack ports are template code, not a dependency**: vine_dehalo
  (`DehaloMethod::Vine`, advanced), mpeg2stinx (`DeblockMethod::Mpeg2Stinx`,
  advanced) and FixInterlacedFades (`QTGMCParameters::ivtc_fix_fades`, an IVTC
  option, mode `average`/`match`). Ported from release 3.0.0 (MIT,
  Jaded-Encoding-Thaumaturgy) through `_expr()` / `_nnedi3()` (test_92/93),
  without akarin's frame-property Expr (macOS x64 has no akarin), and checked
  against vs-jetpack itself: mpeg2stinx 0.04 levels, the fade fix exact
  (vine could not run there: its scalers need resize2, which we don't ship).
- **mpeg2stinx is a cross-field filter and always takes the whole frame** —
  the Deblock pass's per-field path skips it — and reads one frame each side
  (`FrameMap::Identity { radius: 1 }`). On every synthetic fixture tried it
  *lost* PSNR (it softens vertical detail); the schema says so. It is for the
  specific comb-like noise of film DVDs encoded as interlaced MPEG-2.
- **The fade fix runs right after VFM, before VDecimate**, in float. Its
  per-frame gains are stamped as frame properties by `ModifyFrame` and applied
  by **one** akarin expression (`x x.FadeGain0 *`); only where akarin is
  absent (macOS x64) does a FrameEval make a `std.Expr` per frame. **Never
  create an akarin node per frame inside concurrent FrameEvals**: the first
  version did, and vspipe segfaulted, aborted or spun one core for 97 minutes
  on 30 frames — fine single-threaded, and the small heavy test missed it. The
  heavy suite now times a full 720x576 IVTC job. `std.DoubleWeave` flags its output
  interlaced, so the block sets `_FieldBased` back to 0 — without it a later
  resize treats progressive frames as fields. `average` leaves the last frames
  of a fade to full black half-lit (one field is already black); `match`
  cleans them.

### Preset System

Presets save complete filter pipeline + encoding settings. The built-in presets
are static factories in `app/lib/models/processing_preset.dart`, collected by
`ProcessingPreset.builtInPresets()`, which `PresetService` calls in
`initialize()`/`reload()`. User presets save to `~/.vapourbox/presets/*.json`,
and can be exported to and imported from any file (issue #81).

> **A preset is executable, and import has to say so.** It carries
> `customVapoursynth` — Python the worker runs — and `customFfmpegArgs`, both of
> which survive a round trip. Importing someone else's preset is closer to
> running their script than to loading their settings, and **nothing else in the
> app would reveal it**: those fields only render in advanced mode. So import is
> two-phase. `inspectPresetFile` reads and validates without committing;
> the dialog shows any custom code verbatim; `commitImport` installs it, with
> `stripCustomCode` as the middle option between trusting everything and
> importing nothing. Don't collapse that into a one-shot `importPreset`.

> **Never take `isBuiltIn` from a file** — the flag survives `fromJson`, and a
> built-in cannot be deleted or overwritten, so a preset claiming to be one
> would be stuck in the menu permanently. Both the load path and the import
> path force it false.

> **The on-disk filename is the preset's id, not its name.** It used to be
> `<sanitized-name>.json`, and the sanitizer lowercases and collapses
> whitespace and separators — so `VHS Cleanup`, `vhs cleanup`, `VHS/Cleanup`
> and `VHS  Cleanup` all produced `vhs_cleanup.json`. Saving one destroyed
> another; renaming left the original behind as a duplicate; and `deletePreset`
> removed the name-derived file *before* looking by id, so deleting one preset
> took a similarly-named one's file with it. Import makes all three easy to hit,
> since an imported preset is very likely to be named like an existing one.
> `savePreset` now also sweeps any other file carrying the same id, which
> migrates legacy name-based files as they are touched.

> **Load failures are collected, not printed.** `_loadUserPresets` used to
> `print()` per bad file, which in a release build means the preset silently
> never appears — indistinguishable from one that was never saved. They now land
> in `PresetService.loadFailures` and the preset menu shows a red row. Tolerable
> when the app wrote every preset itself; wrong once files arrive from elsewhere.

`app/test/preset_service_test.dart` is the first test over this service — set
`directoryOverride` to a temp dir, since the real path comes from `$HOME`. All
three filename bugs above have a regression test named after the behaviour.

**Not done:** encoder-only profiles. A preset always carries the whole pipeline,
so "just my ProRes output settings" cannot be expressed without also pinning
someone's deinterlacer. That needs an optional-pipeline model change and is its
own piece of work.

## Hardware Encoders (issue #51)

Three invariants that show up as "this GPU doesn't work" rather than as an
error when broken:

- **The availability probe must use a large enough frame** — hardware encoders
  reject frames below their minimum dimensions. `HardwareEncoderDetector.probeFrameSize`
  is 512.
- **Presets are per-family vocabularies** (x264 `ultrafast…placebo`, NVENC
  `p1…p7`, QSV `veryfast…veryslow`, AMF `speed|balanced|quality`) — a saved
  preset/job config can pair the wrong family with a codec, so
  `VideoCodec::normalized_preset` substitutes the family default. Rust's
  `available_presets`/`default_preset` must stay in step with Dart's
  `availablePresets`/`defaultPreset`.
- **AMF is pinned to `nv12`** — a >8-bit source left to negotiate reaches AMF
  as p010, and where the ASIC has no 10-bit HEVC mode the runtime hard-faults
  rather than failing cleanly. `h264_amf` has no 10-bit mode at all. Custom
  FFmpeg Arguments can still override it (a later `-pix_fmt` wins).
- **A hardware encoder's declared pix_fmt list is not a statement about the
  machine (issue #74).** ffmpeg's negotiation is against a compiled-in list, not
  the driver's real capability, so a build that advertises 4:2:2 support for
  newer hardware fails outright on older cards of the same family.
  `VideoCodec::forced_pix_fmt` picks the format for the pipeline instead of
  trusting negotiation, whenever the source/output would hand an H.264/HEVC
  hardware encoder 4:2:2, 4:4:4, or >8-bit — HEVC keeps depth (`p010le`), H.264
  cannot (drops to 8-bit `yuv420p`/`nv12`). VideoToolbox is excluded (its
  negotiation is trustworthy); QSV is included preventively.
- **The user-facing warning (`hardwareEncoderChromaWarning`) is a second
  implementation of the same decision** and must be pinned to the same table of
  cases as the worker's (`hardware_encoder_chroma_warning_test.dart` against
  `video_job.rs`) — the two disagreeing is worse than either being wrong alone.

None of the AMF behaviour (and little of NVENC/QSV's) can be verified in CI —
there's no matching hardware in the runner matrix — so this rests on unit tests
over emitted arguments; the functional probe encodes one `yuv420p` frame and
so cannot catch the #74 class at all. See docs/ENGINEERING_NOTES.md for the
full case table and the two help dialogs that explain this to the user.

### ProRes: the profile decides the chroma, not ffmpeg (issue #81)

**ffmpeg's pixel-format negotiation never looks at `-profile:v`** — left alone,
`prores_ks` auto-selects `yuv422p10le` for *every* profile including 4444/4444 XQ,
so an unpinned encode silently writes a file stamped 4444 that actually carries
4:2:2. `VideoCodec::forced_pix_fmt` decides from the profile instead (4/5 →
`yuv444p10le`, 0-3 → `yuv422p10le`), the same pattern as the HuffYUV/AMF/#74
pins: an encoder's declared format list is not a statement about what the
output should be. The decoder reports ProRes 4444 as 12-bit
(`yuv444p12le`) regardless of what 10-bit format it was fed — assert on the
chroma part of the name, not the depth, and never claim "12-bit" in UI copy,
since `prores_ks` has no 12-bit pixel format at all.

`proresChromaPinWarning` is a **sibling** of `hardwareEncoderChromaWarning`,
not an extension — it says "nothing is lost" rather than "something is lost,"
because 4444 pads 4:2:0 chroma *up* rather than discarding anything. Both
warnings are second implementations of a worker-side decision and both must be
pinned case-for-case against it (see the Hardware Encoders section above).

`VideoCodec.hasQualityControl` (not `isLossless`) decides whether the quality
slider applies, and is asserted across `VideoCodec.values` rather than a
hand-written per-codec list — ProRes previously showed a CRF slider wired to
nothing. `bits_per_mb` (advanced-mode, ProRes-only) is clamped to 8192 **in the
worker**, not just the UI, since ffmpeg rejects anything above it and dies
having written nothing.

See docs/ENGINEERING_NOTES.md for the specific measurements (which profiles are
bit-identical with/without the pin, the dB gain from the advanced quant-matrix
options) and the `copyWith`/enum-dispatch traps this shipped with.

### Intermediate codecs: v210 and ProRes; field order for every codec

`VideoCodec::V210` (serde `"v210"`, app 1.8.0) is uncompressed 10-bit 4:2:2
for editors: MOV (default), MKV, AVI; never MP4 (no tag). Its own family,
`EncoderFamily::Uncompressed` / Dart `isUncompressed` — **not** `isLossless`,
which means AVI and the "Lossless" group. No quality, presets or `-crf`. The
evidence for every rule here is docs/reports/2026-11-v210-field-order.

- **vspipe's Y4M header always says `Ip`**, whatever `_FieldBased` is, so
  ffmpeg never learns a still-interlaced picture's field order from the pipe.
  `VideoCodec::field_order_signal` decides per codec, exhaustively (no
  catch-all arm), and `pipeline_executor::field_order_args` declares it
  **on the pipe input**, `-top 1|0` before `-i -`, from
  `ScriptGenerator::output_field_order`. Never `-field_order` (inert in
  FFmpeg 9: overwritten from the frame flags) and never `setfield` in `-vf`
  (a Custom FFmpeg Argument `-vf` drops it). Without it a MOV's `fiel` atom
  says progressive (`0x0100`). Per codec (docs/reports/2026-11-field-order-other-codecs):
  - **v210, FFV1, HuffYUV, FFVHuff: `-top` only** — MKV FieldOrder, MOV
    `fiel`; pixels bit-identical. FFV1 also writes it in its own bitstream,
    so it survives in AVI; the others in AVI carry nothing.
  - **ProRes: `-top` + `-flags +ildct`** — its frame header has its own
    field flag, which stays progressive unless the frame is coded as fields.
  - **x264: `-top` + `-flags +ildct` + `-x264-params tff=1|bff=1`** — real
    interlaced (MBAFF) coding; it beat progressive coding of the woven frame
    at equal bitrate on every fixture. `+ildct` alone left a BFF picture's
    `pic_struct` SEI saying top-first on most frames (libx264 starts from
    TFF). A Custom FFmpeg Argument `-x264-params` replaces ours. Apple's
    hardware decoder refuses MBAFF (AVFoundation decodes it in software).
  - **x265 and every hardware encoder: nothing.** x265 has no interlaced
    coding (its `interlace` mode declares each woven frame one field,
    `field_seq_flag=1`); a container-only flag is read by AVFoundation but
    not by FFmpeg-based players, so they would disagree about one file.
    VideoToolbox ignores `+ildct`; NVENC/QSV/AMF can't be verified here.
  - **`field_order_note` logs it** when a still-interlaced picture goes out
    unflagged (these codecs, or a container-only codec in AVI). Said, never
    refused.
- **A pass that makes a still-interlaced clip progressive must be taught to
  `output_field_order`** (today: Stabilize pitch, Deblock mpeg2stinx, a
  quarter turn in Rotate / Flip, the Frame Rate pass; a vertical flip or half
  turn swaps the order). `test_221` counts every `SetFieldBased(` in the template
  and fails on one it doesn't know.
- **The stored format comes from the script, never from ffmpeg's
  `-pix_fmt`**, which blends interlaced 4:2:0 chroma across the fields; zimg
  honours `_FieldBased`. `VideoCodec::fixed_output_format` (Dart
  `fixedOutputFormat`) is the one statement: v210 → 10-bit 4:2:2, ProRes by
  profile number (≥ 4 → 10-bit 4:4:4, else 4:2:2). The Color Format
  selection is ignored for both. `forced_pix_fmt` still pins the same format
  as a guard (`fixed_output_format_agrees_with_the_pin`). This changed
  existing ProRes output (app 1.8.0) wherever a conversion happens; every case
  measured equal or better, and a source already in the profile's format is
  bit-identical (docs/reports/2026-11-prores-script-chroma).
- `v210ChromaPinWarning` / `proresChromaPinWarning` (Dart, one shared body)
  are second implementations of the override, pinned case for case to
  `v210_stores_422_10_whatever_is_selected` /
  `prores_converts_to_its_profile_format_whatever_is_selected`. Loss and
  padding are judged from the **source**, since the selection never reaches
  the encode. `chromaConversionBitDepthWarning` is silent for ProRes (every
  ProRes 4444 source decodes as 12-bit).
- **Editing intermediates (ProRes and v210, `VideoCodec::is_editing_intermediate`)
  get no `+faststart` and 24-bit PCM restored audio.** Faststart reads and rewrites
  the whole file after the last frame (in place, no extra space; ~0.9 s/GB on
  an internal SSD, much more on a USB disk or NAS, with the progress bar at
  100%) for web playback no editor needs (`uses_faststart`). A restored track
  under Passthrough is PCM rather than AAC, since the editor encodes the
  soundtrack again on delivery (`restored_passthrough_codec`), and 24-bit
  (`in24` in MOV): 16-bit is not audible on VHS/DV audio but rounds the
  float render's quietest pauses and fades to zero, for ~0.8 Mbit/s saved.
  Field-order flagging is a separate table (`field_order_signal`). See
  docs/reports/2026-11-prores-faststart and
  docs/reports/2026-11-intermediate-pcm-depth.
- **Test field order with the `fiel` atom's bytes** (`0x0209` TFF, `0x020e`
  BFF; `WorkerHarness.movFielAtom`, which walks the boxes — x265's option
  string contains "fiel"), not only ffprobe's `tb`/`bt` labels, and x264's
  with the bitstream (`bitstreamHeaderCounts`: `frame_mbs_only_flag`,
  `pic_struct`). `test_field_order_args_matrix` sweeps every codec x
  container. `integration_field_order_test.dart` (heavy) checks each codec's
  flags and that the lossless ones stay bit-exact;
  `integration_v210_output_test.dart` (heavy) checks v210 bit-exact against a
  10-bit 4:2:2 source, per-field chroma (v210, ProRes Proxy/HQ/4444), PCM in
  MOV and preview = encode.

### AV1 (SVT-AV1) (task #40, app 1.8.0)

`VideoCodec::Av1` (serde `"libsvtav1"`, Dart `VideoCodec.av1`) is software
AV1 through SVT-AV1, its own family (`EncoderFamily::SvtAv1`, Dart
`encoderFamily` `'SVT-AV1'`). Evidence: docs/reports/task-40-av1-svtav1.

- **MP4 (default) and MKV only** (`VideoCodec::allows_container`, Dart
  `supportsContainer`). FFmpeg refuses AV1 in MOV; AVI's `AV01` fourcc is
  non-standard. The worker refuses either (`container_problem`).
- **In every bundled FFmpeg, and asserted.** From deps 1.17.0-rc2 every
  bundle has `libsvtav1` (task #45: macOS x64 moved from evermeet's FFmpeg,
  which has none, to martin-riedl's). `download-deps-macos.sh` fails the build
  without it (`assert_ffmpeg_encoder`, both arches), and
  `vapoursynth_integration_test`'s `libsvtav1 is compiled in` checks every
  bundle with no exception. The availability check stays for an FFmpeg
  without it: `HardwareEncoderDetector` checks every codec with
  `needsAvailabilityCheck` (hardware + AV1) and the panel shows AV1
  unavailable; the worker refuses it before the pipeline starts
  (`missing_encoder_problem`).
- **4:2:0 at 8 or 10 bits, converted in the script.**
  `VideoJob::output_chroma_subsampling` is the one decision (script
  `CHROMA_CONVERT`, encode and preview, and `encoder_input_pix_fmt`):
  `effective_chroma_subsampling` first, then for a codec with
  `limits_to_420_10` a result already 4:2:0 <= 10-bit is kept, else 4:2:0 at
  8 bits (8-bit content) or 10. FFmpeg's own conversion blended an
  interlaced picture's field chroma. `forced_pix_fmt` is only a guard.
  `av1ChromaWarning` (Dart, via `limitTo420Up10`) is pinned row for row to
  `av1_stores_420_up_to_10_bits` by `app/test/av1_test.dart`, which parses
  the Rust table.
- **Presets `"1"`..`"10"`, default `"6"`; CRF 0-63, clamped in the worker;
  the app's default AV1 quality is 24** (≈ x264 CRF 18 by VMAF).
  `EncodingSettings.withCodec` resets the preset on a family change and the
  quality when the scale changes (AV1 <-> the 0-51 codecs); use it for any
  codec switch. Rust `available_presets` / `SVT_AV1_DEFAULT_PRESET` and Dart
  `availablePresets` / `defaultPreset` are pinned by `av1_test.dart`.
- **HDR10 metadata goes in `-svtav1-params`** (`HdrMetadata::svtav1_params`,
  decimals: chromaticity / 50000, luminance / 10000), only for PQ/HLG tags.
  It is the only `-svtav1-params` today; a Custom FFmpeg Argument
  `-svtav1-params` replaces it, as with `-x265-params`.
- **No field-order signalling** (`FieldOrderSignal::None`): AV1 has no
  interlaced coding; the job log says so.
- **`SVT_LOG=2` on the encoder** (`encoder_env`): SVT's ~20-line info banner
  otherwise fills the stderr tail a failure is reported from.
- Not built: hardware AV1 (NVENC/QSV/AMF), WebM/VP9, film grain. No
  built-in preset uses AV1.

`integration_av1_output_test.dart` (heavy) checks MP4/MKV output, 10-bit
4:2:2 -> 10-bit 4:2:0, per-field chroma, preview = encode and the MOV refusal;
`integration_hdr_test.dart` the metadata. Both skip without `libsvtav1`.

## QTGMC Parameters Reference

The most important parameters:

- **Preset**: Master setting (Placebo → Draft) that sets defaults
- **TFF**: Top-field-first (true) or bottom-field-first (false)
- **TR0/TR1/TR2**: Temporal radius settings controlling smoothing
- **EdiMode**: Interpolation method (NNEDI3, EEDI3+NNEDI3, etc.)
- **SourceMatch**: Higher fidelity mode (0=off, 1-3=increasingly accurate)
- **FPSDivisor**: 1=double-rate (50i→50p), 2=single-rate (50i→25p)

### Field Order (issue #49) — read before touching `_FieldBased` or `TFF`

`std.SeparateFields` **ignores its `tff` argument whenever the `_FieldBased`
frame property is set** — the property wins, so QTGMC's `TFF=` parameter is
inert on a marked clip. `ScriptGenerator::field_based_for` is the single
derivation both the encode and preview paths must use.

- Deinterlacing enabled → `_FieldBased` comes from `pipeline.deinterlace.tff`,
  **except Soft Telecine, which is never marked** (task #33): its frames are
  progressive film, and `VDecimate` copies the property through without
  reading it, so a marked film frame had its 4:2:0 chroma resampled per field
  by every later zimg resize (docs/reports/issue-33-soft-telecine-field-based).
- Deinterlacing disabled → falls back to `job.detected_field_order` (zimg
  honours `_FieldBased` for chroma resampling too).
- **A filter that works vertically must not run on a woven interlaced frame**:
  it blends the two fields on every moving edge. `ScriptGenerator::still_interlaced_tff`
  (deinterlacing off + a detected order) is the one test for "still
  interlaced"; Deblock uses it to run every method per field
  (`{{#DEBLOCK_PER_FIELD}}`) — DCTFilter on the woven frame scored 1.5–3.7 dB
  *below no filtering* (docs/reports/2026-11-deblock-order).
- **After Rotate / Flip, the field order is `ScriptGenerator::field_order_at_framing`**
  (task #56 F3): a quarter turn makes the picture progressive (its "fields"
  would be columns) and a vertical flip or half turn swaps TFF and BFF; the
  geometry block stamps it (`{{#GEOM_SET_FIELD_BASED}}`) before its format
  restore. Everything after it reads that, not `still_interlaced_tff`: the
  border alignment, the crop step and the resize height step
  (`framing_steps`: a still-interlaced 4:2:0 picture is resized to a height
  that is a multiple of 4, F5), and `output_field_order`.

### Deinterlace Working Format (issue #49)

Two **opt-in** QTGMC options wrap the deinterlace pass in a format conversion,
restoring the source format after (`{{#DEINT_WORKING_FORMAT}}` /
`{{#DEINT_RESTORE_FORMAT}}`), independent of each other:

- **`chromaUpsampleFix`** (default off): convert 4:2:0 to 4:2:2 before
  deinterlacing (field-aware). ~30% throughput cost; no-op on 4:2:2/4:4:4.
- **`highPrecision`** (default off): run at 16-bit, dither back. ~2x time/memory.

With both off, the generated script is byte-for-byte what it was before the
block existed.

**`ChromaEdi` is validated, not passed through** — havsfunc implements only
`''`, `'nnedi3'` and `'bob'`; `QTGMCParameters::normalized_chroma_edi` drops
anything else, since an unsupported value silently corrupts chroma.

## Testing

VapourBox has **three distinct test suites**. Know which is which before adding
or changing tests — they live in different places and run differently.

### 1. Rust worker tests — `worker/tests/`, run by `cargo test`

```bash
cd worker && cargo test
cd worker && cargo test --test subtitle_integration_test -- --nocapture
```

- `filter_integration_test.rs` — **every filter/parameter change must add a
  numbered test here** (see "Adding a New Filter"). Despite the name, `run_job`
  **only generates and inspects the `.vpy` script** — it does not run
  `vspipe | ffmpeg`, so it validates script generation only; runtime/plugin
  bugs need the Dart shell-out/integration tests.
- `subtitle_integration_test.rs` — runs `whisper-cli` on
  `Tests/TestResources/small_clip.mp4`; needs the whisper add-on + ffmpeg.
- In **debug** builds `DependencyLocator` finds repo-root `deps/`/`addons/` by
  searching upward — **except Linux**, which only reads
  `~/.local/share/VapourBox/` (no upward search), so CI symlinks those there.

### 2. Flutter `test/` suite — `app/test/`, run by `flutter test`  ← the CI gate

```bash
cd app && flutter test --exclude-tags heavy,gpu   # what the push gate runs
cd app && flutter test                          # everything, incl. heavy (local)
```

Headless Dart-VM tests. Three groups:
- **Pure unit tests** — `dynamic_parameters`, `filter_schema`,
  `parameter_converter`, `widget_test`, `scan_type_detection`,
  `attribution` (NOTICES/About-dialog/deps-manifest agreement — see
  "Attribution" below), `advanced_mode_service`,
  `dynamic_filter_panel_advanced` (a widget test — pumps the generated panel
  through a `ChangeNotifierProvider`, no desktop needed),
  `filter_schema_curation` (lints every shipped schema), `pass_list_stages`,
  `pass_relevance`, `pass_advice`, `processing_preset`.
- **Shell-out tests** — `vapoursynth_integration_test`,
  `schema_converter_integration_test`, `template_call_arguments_test`,
  `plugin_format_contracts_test` (the quick plugin format probe against its
  table, the contracts, and `run_within()` on real low bits; the full probe
  is the heavy `plugin_format_probe_test`), `removedirt_determinism_test`
  (task #57); need the per-arch `deps/` and
  (for whisper) `addons/`.
- **Integration tests** — `integration_*_test.dart`. They spawn the worker
  end-to-end via `app/test/support/worker_harness.dart`. The encode-heavy ones
  are `@Tags(['heavy'])`: the **push gate** runs `--exclude-tags heavy,gpu`
  (script-only: `integration_filter_parameters_test`,
  `integration_qtgmc_parameters_test`, and the format sweep's untagged
  rotating rows, ~500 tiny previews); **nightly.yml** runs two legs per
  bundle: `--tags heavy --exclude-tags gpu,sweep` and the format sweep's full
  product, `--tags sweep --exclude-tags gpu` (every `sweep` test is also
  `heavy`; its per-row results are uploaded as an artifact). Tests that need
  a Vulkan device are tagged `gpu` and run on no CI runner (see "GPU
  Plugins: RIFE and AI Upscaling").
  `grep -l "Tags(\['heavy'\])" app/test/*.dart` is the authority for which files
  those are.

> **Feeding a test clip to vspipe's stdin: start draining stdout/stderr BEFORE
> writing, and never `await` the write.** These scripts request a single frame,
> so vspipe reads only a fraction of the payload and exits; awaiting
> `stdin.close()` first deadlocks on a pipe nobody is reading. This is always a
> race (whether it's hit depends on how long script evaluation takes), not a
> version difference.

`WorkerHarness` also runs the worker in **preview** mode (`runPreview`) and
compares rendered frames (`imageToRgb24` + `meanAbsDiff`) — preview and encode
are separate scripts and separate ffmpeg invocations, so assert both; a filter
can render fine and still fail the preview.

> **Decode the side a preview is compared with as the preview converts:
> `WorkerHarness.previewFrameRgb24` (or `previewScaleFilterFor` in a
> test's own `-vf`), never `frameRgb24`.** The preview turns YUV into RGB
> with `scale=…:out_range=pc:flags=accurate_rnd+full_chroma_int` and the
> picture's tags (`preview_scale_filter`, task #56 F8); `frameRgb24` uses
> ffmpeg's defaults, and the two conversions of one frame differ by
> 0.2–0.5 levels on camera 8-bit 4:2:0, 0.9 on chroma-detailed 10-bit 4:2:2
> and 2.5 on the synthetic testsrc2 fixtures. A lossless preview = encode
> or preview = source check then reads 0.000, as it must against a 0.5
> bound. The helper reads the tags the decoded file carries
> (an encode's are the stamped output tags), so it needs no copy of
> `output_color_metadata`; `preview_scale_filter_test.dart` (push gate) pins
> it to the Rust. `frameRgb24` stays right for comparisons that don't
> involve the preview (encode vs source, the app's before frame). Never
> loosen a bound to absorb a conversion difference
> (docs/reports/task-67-preview-rgb-decode).

> `vapoursynth_integration_test`'s "all required plugins load" list is the
> runtime contract for a **complete deps install** and must name every
> namespace a filter can reach. Add the namespace whenever
> you add a plugin, or a bundle missing it passes CI and fails at job time.
> OpenCL-only plugins (`nnedi3cl`, `knlm`) stay **out** of the list — the app
> degrades to a CPU path without them.

The harness honors `$VAPOURBOX_DEPS_DIR`, else uses repo-root `deps/<platform>`,
else **downloads the deps release pinned in `app/assets/deps-version.json`**
(opt out with `$VAPOURBOX_SKIP_DEPS_DOWNLOAD=1`), in the tier the app would
pick (`$VAPOURBOX_DEPS_TIER` overrides it). The worker binary is found under
`worker/target/{release,debug}` (CI's `cargo test`/`cargo build` produces debug).
Subtitle heavy tests skip when the whisper add-on is absent.

```bash
# Run the worker standalone (no test harness)
cd worker && cargo run --release -- --config test_job.json
```

> **A heavy test job on a >8-bit fixture sets `inputPixelFormat` and asserts
> the output's `pix_fmt`.** Before the source model (task #50) a job without
> it was decoded as 8-bit 4:2:0, silently, and Unblend's "10-bit = 8-bit"
> test compared the 8-bit run with itself for as long as it existed
> (task #64). The worker now probes the format, but only the assertion makes
> a test fail if its depth stops reaching the pass.

> **The heavy tests run the worker BINARY, not the library**, and
> `app/lib/**/*.g.dart` is gitignored — **run `cargo build` before the heavy
> suite** and `dart run build_runner build` before any Dart test, or you'll
> debug a stale binary/generated-code mismatch that reads like a template or
> serialization bug. `generated_code_freshness_test.dart` catches the Dart half
> in CI (which always rebuilds first, so it can't reproduce this locally-only
> trap); nothing catches the Rust half but discipline.

### CI test gate (`.github/workflows/ci-test.yml`)

Runs on push to `main` + PRs (skipped for doc-only changes via `paths-ignore`).
Each job pulls the published deps bundle + the whisper add-on, then runs
**suite #1 (`cargo test`) and suite #2 (`flutter test --exclude-tags heavy,gpu`)** —
including the subtitle integration test, excluding the heavy full-encode
integration tests. Matrix: macOS **arm64** (`macos-15`), macOS **x64**
(`macos-15-intel`), **Windows x64**, **Linux x64** (`ubuntu-24.04`). The heavy
full-encode integration tests run separately in `.github/workflows/nightly.yml`
(cron + `workflow_dispatch`) via `flutter test --tags heavy --exclude-tags gpu,sweep` on the same
4-platform matrix, running each x64 platform against **both** CPU-tier bundles,
with the format sweep (`--tags sweep`) as a parallel leg of each.
Fixtures (`small_clip.mp4`, telecine/interlaced clips) are
committed under `Tests/TestResources/`. The Linux jobs of both keep core
dumps and print a gdb backtrace when a step fails (see Debugging Tips #11).

> **Old-CPU behaviour cannot be tested on the runners, or on Apple Silicon.**
> Every hosted runner is a v3 CPU, and Rosetta 2 translates AVX/AVX2 on macOS
> 15+ — so a plugin that SIGILLs on a pre-AVX2 Intel Mac runs fine under
> Rosetta. The tools that do answer it: `probe-cpu-compat.yml` (every plugin
> under Intel SDE, with controls that prove the emulation is valid), and
> `Scripts/probe-plugin-compat.sh` for a user to run on the real machine
> (one plugin per process, into a `DISABLE_AUTO_LOADING` core — under autoload
> one faulting plugin masks every other result).

> **A green CI run on hosted hardware is not proof about CPU-dispatched code.**
> The runner fleet is mixed for features like AVX-512, so a filter that only
> crashes on that instruction set can pass for days and then fail on no code
> change at all when the draw changes. Prefer a script-generation assertion
> (which runs on every draw) over relying on the heavy end-to-end test to catch
> a CPU-dispatch bug. `WorkerHarness`'s banner reports the actual CPU features
> the pipeline process saw (`--probe-cpu`), so check it before reading a green
> run as evidence either way.

## Attribution — never write a name you have not read upstream

Third-party credit lives in **four** places that must agree:
`licenses/NOTICES.txt` (shipped in every package), the About dialog
(`app/lib/views/about_dialog.dart`), the README's Acknowledgments, and — for an
add-on — its `AddonInfo` (licence, credit, `noticeName`), which Settings →
Add-ons and the download prompt display. Guarded by:

- `app/test/attribution_test.dart`: NOTICES and About against
  `Scripts/deps-expected-plugins.json`, so **adding a plugin without crediting
  it fails the build**; and every About tile states the same licence(s) as its
  NOTICES entry (compared as licence families, so a dropped component licence
  fails — RemoveGrain's tile once omitted its MIT part).
- `app/test/addon_service_test.dart` ("credits agree everywhere"): each add-on's
  NOTICES entry has its licence and credit and says it is a download, it has an
  About tile with the same licence, the README credits it, and a
  non-commercial licence carries a `usageNote`.

**Every copyright line must come from the upstream LICENSE file or a source
header, fetched at the time of writing — never from a GitHub handle expanded
into a plausible name, and never assumed from the repo owner.** `gh api
repos/<r>` gives the SPDX id; the LICENSE / first 40 lines of the main source
file give the actual holder. This has gone wrong before ([issue #72](https://github.com/StuartCameronCode/VapourBox/issues/72):
zsmooth was credited to a name that doesn't exist, invented from the author's
GitHub handle) and cost a public correction. When a project genuinely states no
licence, say so plainly rather than guessing one — see docs/ENGINEERING_NOTES.md
for the full audit and the specific licence/year errors it found.

## Code Style

### Rust
- Use `anyhow` for error handling
- Use `serde` with `rename_all = "camelCase"` for JSON compatibility
- Platform-specific code in `platform/` module with `#[cfg]`

### Dart/Flutter
- Provider for state management
- `json_annotation` + `json_serializable` for models
- MVVM pattern (models, viewmodels, views, services)

### Line endings: accept both CRLF and LF, everywhere

**Any code that reads a text file from the repo or the user, in the app,
the worker, a test or a script, must work on CRLF (Windows) and LF (macOS
/ Linux) line endings alike.** Windows CI checks the repo out with CRLF,
so a file that is LF on a Mac is CRLF there, and the failure only shows on
Windows. Normalise first (`text.replace("\r\n", "\n")` in Rust,
`replaceAll('\r\n', '\n')` in Dart), or split with `.lines()` /
`LineSplitter`, which accept both. Never:

- search for a multi-line pattern containing `"\n"` in raw file text (task
  #49's container lint looked for `"#[cfg(test)]\nmod "` and scanned every
  test module on Windows);
- compare a file byte for byte against generated text (task #49's
  generated-table freshness check);
- substitute a pattern that spans a line break in a loaded template
  (`load_template_by_name` normalises for this; see Debugging Tips #5).

Text the code writes may use `\n`; it is what it reads that must accept
both.

## havsfunc Compatibility Patches

All three `download-deps-*` scripts apply these automatically, and they must stay
**identical across platforms** — a patch applied on only some platforms makes the
same job produce different output per OS. Each is a **literal string match**
against havsfunc r31, so if upstream ever changes one of those lines the patch
silently does nothing — behavioural tests matter more than usual here (see
`app/test/vapoursynth_integration_test.dart`).

1. **mvtools API**: Renamed `_lambda`→`lambda`, `_global`→`global` parameters
2. **DFTTest API**: `sstring` parameter removed, replaced with `sigma=10.0`
3. **VapourSynth YCOCG removal**: `vs.YCOCG` removed, simplify to `!= vs.YUV`
   (known gap: `KNLMeansCL`'s own YCOCG check is unpatched, but unreachable —
   only hit by a non-default denoiser/chroma combination that's never shipped)
4. **EEDI3CL fallback**: modern `eedi3m` dropped `EEDI3CL`, so `opencl=True` fell
   over; fall back to CPU `EEDI3` (NNEDI3CL still uses the GPU)
5. **`Bob()` 16-bit resample** — defence in depth for the fmtconv aarch64
   integer-scaler bug (see docs/ENGINEERING_NOTES.md); redundant now that fmtconv
   is patched, but also covers the prebuilt Windows DLL
6. **ARM interpolator preference** — routes every nnedi3 call site to the
   bundled dubhater `nnedi3` (real NEON kernels) instead of `znedi3` (x86-only
   SIMD, scalar fallback on ARM) on **ARM builds only**; x86 is unaffected.
   **Never call `core.znedi3.nnedi3`/`core.nnedi3.nnedi3` directly** — always go
   through the templates' `_nnedi3()` helper (`test_92` enforces this). Measured
   ~6x CPU-time win on arm64 QTGMC for a picture within 0.045/255 of znedi3's.
7. **akarin Expr routing** — on ARM, rebinds havsfunc's `core` so `.std.Expr`
   calls go to `akarin.Expr` (a real LLVM JIT) instead of VapourSynth's own
   x86-only Expr JIT, which falls back to a scalar per-pixel interpreter on
   ARM (measured ~20x slower). **Never call `core.std.Expr` directly in a
   template** — use the `_expr()` helper (`test_93` enforces this, and only
   scans the two `.vpy` templates — extend it before vendoring any `.py` module
   that calls `Expr`, e.g. TemporalDegrain2 or mClean). Not applied on macOS
   x64: the only akarin wheel would raise that arch's Intel-compatibility floor
   to macOS 14, and x64 already has VapourSynth's own JIT. Not bit-identical to
   `std.Expr` in every case (one known 1-level difference in a dehalo mask, see
   docs/ENGINEERING_NOTES.md) — `akarin_expr_parity_test.dart` (heavy) bounds it.

### Linux builds on ubuntu-24.04, and that sets the glibc floor

The Linux **deps** builds and the CI runners that test against them must stay on
`ubuntu-24.04` in step — the deps binaries need R78's toolchain requirements
(GCC ≥13, Cython 3), which ubuntu-22.04 cannot build at all. This means the
shipped Linux bundle needs **glibc 2.39**, so Ubuntu 22.04 and Debian 12 can no
longer run it (documented in the README's platform table). The app and whisper
builds deliberately stay on `ubuntu-22.04` since their binaries run fine on
newer systems regardless — the effective floor is set by whichever component
needs the newest glibc, currently the deps bundle.

### Testing a deps change before publishing

`ci-test.yml`/`nightly.yml` download the bundle named by
`app/assets/deps-version.json`, so a `deps/` change can't be tested until it's
published. Two ways around that:

**1. `deps_run_id` (preferred)** — both workflows take an optional
`workflow_dispatch` input pointing at unpublished `build-deps-*` workflow-run
artifacts instead of a release, so nothing is public and nothing needs cleanup:

```bash
gh workflow run build-deps-macos.yml   -f version=1.9.0 -f arch=both
gh workflow run build-deps-windows.yml -f version=1.9.0
gh workflow run build-deps-linux.yml   -f version=1.9.0 -f arch=both

gh workflow run ci-test.yml --ref <branch> \
  -f deps_run_id="<macos-run>,<windows-run>,<linux-run>"
```

It's a comma-separated list because macOS/Windows/Linux are three separate
`build-deps-*` workflow runs; each CI job tries every ID and takes the first
holding its platform's artifact (`.github/scripts/install-deps-bundle.sh`,
which for a `-v2` row fetches the bundle and the `-v2-delta` artifact and
extracts one over the other). The bundle version is deliberately not
cross-checked against `deps-version.json` — it logs a `::warning::` instead, so
a green run against an unreleased bundle can't be mistaken for one against the
released bundle.

**2. Release-candidate prereleases** — needed only when the thing under test is
the download path itself (an installed app has no token and can't read
artifacts): `gh release create deps-vX.Y.Z-rc1 --prerelease`, point
`deps-version.json` at it on the PR branch only, iterate, then publish the real
tag and repoint before merge. `Scripts/release.sh` refuses to cut an app release
while `deps-version.json` names an `-rc` tag.

See docs/ENGINEERING_NOTES.md for why draft releases don't work for this and
the full mechanics of both flows.

### Installing a deps bundle

`DependencyManager` **replaces** a bundle rather than merging into one — an
upgrade is verified, extracted to `<deps>.new`, stamped with `version.json`, and
only then swapped in via two renames (old tree to `<deps>.old`, deleted after);
a **first install** extracts straight into `<deps>` with no rename, since
there's nothing to protect. `version.json` is written **last**, as the commit
marker. Direction is checked with `compareVersions`, not `!=`/string compare — a
deliberately newer install must never be treated as outdated and overwritten.

An install can be more than one zip (the v2 tier is bundle + delta, see "CPU
tiers"): each is extracted into the same target in order (`extractBundle`,
`overlay: true` for all but the first), the macOS quarantine strip and re-sign
run once after the last, and the cache keeps every zip of the current install
(`_cachedDownloadPath(keep:)`) so fetching the second doesn't prune the first.
`extractBundle` reads a whole zip into memory, ~240 MB for the Linux bundle.

On Windows, both renames go through a retry loop (`retryTransientFsOperation`)
because a directory rename fails with **errno 5** (not a permissions error) if
anything — a scanner, the search indexer — briefly holds a handle inside it
right after a ~200MB bundle is written; `PathExistsException`/`PathNotFoundException`
are rethrown immediately since those won't clear. The downloaded zip is cached
and only deleted after a successful install, so Retry doesn't re-download.
`DependencyManager.remedyFor` maps the failure to specific advice rather than
one fixed "check your connection" message.

### R78: `deps/<platform>/vapoursynth/` IS the Python package (macOS/Linux)

VapourSynth R78 ships as a Python package on macOS/Linux; `vsscript` resolves
its library through a config file keyed by the **absolute path** of the
imported package's `libvsscript`, so the copy `vspipe-bin` loads and the copy
the Python module reports must be the same file. Consequences:

- Ship the pure-Python files (`__init__.py`, `_cli.py`, …) alongside the
  compiled libraries in `deps/<platform>/vapoursynth/` — without them,
  `vapoursynth config`'s automatic configuration has nothing to call.
- `XDG_CONFIG_HOME` must point somewhere writable (`deps/<platform>/config`);
  the worker, app, and vspipe wrapper all set it.
- **Do not set `VAPOURSYNTH_EXTRA_PLUGIN_PATH` on macOS/Linux** — R78 autoloads
  `vapoursynth/plugins` itself, and setting it too double-loads every plugin.
  **Windows still needs the variable** (its plugins live in `vs-plugins`, not
  the autoload directory). `vspipe_environment_test` (Rust) runs vspipe under
  the worker's environment and fails on any "already loaded" line (task #61).

**vspipe is R78 plus one backported fix (task #68).** R78's vspipe counted a
frame done before writing it, so its main thread could free the script under
the last frame's callback: SIGSEGV after the last frame, intermittently (tasks
#65, #66). `Scripts/patches/vapoursynth-r78-vspipe-frame-done-count.patch` is
upstream's fix (4ff3f8a0, R80) plus a `vspipe --version` line, `VapourBox
patch: vspipe frame-done count (task #68)`, which every `download-deps-*`
script requires (and rebuilds a vspipe without), and
`vapoursynth_integration_test` checks from deps 1.18.0. macOS and Linux apply
it in their source build; **Windows replaces the wheel's `vspipe.exe`** with
one Zig builds from patched R78 (import library for the wheel's
`vsscript.dll`, upstream's manifest embedded: it sets `longPathAware`). The
race is too rare to test unaided; `widened_race_ab.sh` in
docs/reports/task-68-vspipe-teardown-backport makes it fire every run.

**Moving past R79 means every plugin must be API 4.** R80 dropped API 3 and
refuses a plugin that only exports `VapourSynthPluginInit` ("uses API 3,
which is no longer supported"). Twelve bundled plugins are API 3 only
(DFTTest, nnedi3, NNEDI3CL, neo_f3kdb, CTMF, AWarpSharp2, FluxSmooth,
TemporalMedian, LGhost, Retinex, FillBorders v2, VSNCNN), most with no API 4
release; `scan_plugin_api.py` in the same report lists a bundle's. When
VapourSynth does move, drop the vspipe patch (and the zimg guard).

No source-indexing plugin is bundled — sources are read as raw frames piped
from ffmpeg (`templates/pipe_source.py`); BestSource was removed in 2026-08-07
once nothing called it. If a source filter is ever needed again, add it back
deliberately with a call site — don't reintroduce it into the preview path.

### fmtconv's aarch64 integer scaler bug (already patched)

`fmtc.resample`'s C++ (non-SIMD) integer kernel returned black output on
`macos-arm64`/`linux-arm64` whenever the source bit depth was below 16 — x86
never hit it because the SSE2/AVX2 scalers replace that code path there. This
broke havsfunc's `Bob()` (used by QTGMC's noise-restore and `EdiMode='bob'`),
producing brightened or near-black frames on those two Placebo/Very Slow/Draft
QTGMC presets on Apple Silicon and Linux ARM. Fixed by
`Scripts/patches/fmtconv-r31-arm-int-scaler.patch`, applied by
`download-deps-{macos,linux}.sh` right after cloning fmtconv — it **hard-fails
the build** if it stops applying. Not submitted upstream (needs a GitLab
account); see docs/ENGINEERING_NOTES.md for the root-cause analysis if
resubmitting or re-checking against a newer fmtconv release.

fmtconv is pinned to **r31**, sourced from GitLab (the GitHub mirror is
abandoned and stale) on every platform — keep macOS/Linux's `FMTCONV_TAG` and
the Windows zip URL in step, since r31 changed interlaced PAL-DV chroma
placement and a version skew would change chroma per-OS. Both macOS arches
build it from source with the patch applied (dead code on x86, as on Linux
x64); **never take a prebuilt fmtconv on macOS x64** — Stefan-Olt's only
x86_64 build is git-18a9cecb, pre-r31, which is what deps ≤ 1.16.0 shipped
(docs/reports/2026-11-fmtconv-macos-x64-r31). The push gate's
`fmtconv version pin` test (`vapoursynth_integration_test.dart`) checks r31's
chroma placement by its pixels on every platform; it skips only on a macOS x64
bundle at 1.16.0 or older, the known skew.

### FFT3DFilter: built from source with our determinism patch (task #62)

Every published FFT3DFilter build (myrsloik's R1/R2 releases, yuygfgg's
macOS arm64 prebuilt, upstream HEAD, the AmusementClub fork) gives a
**different output on every run**, so the Noise Reduction FFT3DFilter method,
TemporalDegrain2 (its spatial pass at every setting, and its post pass) and
QTGMC's `Denoiser='fft3dfilter'` never previewed exactly what they encoded.
Two faults, both fixed by `Scripts/patches/fft3dfilter-r2-determinism.patch`:

- **The left border was mirrored before the source line was copied**
  (`FramePlaneToCoverbuf`), so the left 10 luma / 6 chroma columns came from
  the previous frame's pixels, or uninitialised memory. Upstream regression
  da50417 (2018).
- **A per-frame Wiener sigma lived in a shared member** of a filter
  registered `fmParallel`: an edge frame (`btcur` 1) could overwrite it while
  a middle frame used it, filtering that frame at 1/bt of its sigma. Hit
  whenever `bt > 1` with a single sigma (the FFT3D method, TD2's post pass,
  QTGMC with NoiseTR > 0).

Rules:

- **Built from source at tag R2 on every platform, patched; never a
  prebuilt.** `FFT3DFILTER_TAG` in `download-deps-{macos,linux}.sh` and
  `$Fft3dTag` in `download-deps-windows.ps1` stay in step. macOS compiles the
  four files directly (its meson.build can't find `fftw3f_threads` on arm64)
  and links the bundle's own FFTW; Linux uses meson; Windows cross-compiles
  with the Zig the script already pins, against FFTW 3.3.5's DLL through an
  import library from its `.def`. All three **fail the build** if the patch
  stops applying. Plain C++, so one build serves both x64 tiers.
- **Never `bt=0` (Kalman).** It carries state from frame to frame by design
  (upstream says it is "broken due to non-linear access"), so it can never
  preview what it encodes. `NoiseReductionParameters::fft3d_effective_bt` clamps to
  1..5 and no other call site passes 0; keep it that way.
- **FFTW plans are measured per process** (`measure=1`, the default). Seven
  processes agreed on macOS arm64, and so does the push gate's second process
  everywhere it runs; if one platform ever disagrees, pass `measure=0`
  (FFTW_ESTIMATE) at our call sites and make it the plugin's default in the
  patch (havsfunc's QTGMC call).
- `vapoursynth_integration_test.dart`'s `fft3dfilter is deterministic (task
  #62)` (push gate) runs each argument class six times in fresh graphs at 8
  threads, compares a second process, and checks a flat picture stays flat at
  the left edge; it skips on bundles up to 1.17.x.
  `integration_fft3dfilter_determinism_test.dart` (heavy) checks that two
  previews and the lossless encode agree sample for sample, for the FFT3D
  method and TD2 with its post pass (docs/reports/task-62-fft3dfilter-determinism).

## Debugging Tips

1. **Worker crashes**: Run worker standalone with `--config` to isolate
2. **JSON mismatch**: Compare Rust and Dart model serialization
3. **Plugin load failures**: Check environment variables in `DependencyLocator`
4. **Encoding fails**: Run generated .vpy script manually with vspipe
5. **Template not found**: Check search paths in `script_generator.rs`. Note
   that `load_template_by_name` **normalizes CRLF to LF** on read: a Windows
   checkout gives the `.vpy` files CRLF, so any substitution whose pattern spans
   a line break silently stops matching there, leaving a plausible-looking
   script rather than an error. `templates_load_with_lf_endings_only` guards it
   on every platform; prefer single-line substitution patterns regardless.
6. **Filter not appearing**: Check JSON syntax, verify `id` is unique
7. **macOS build fails with "Unable to find module dependency"**: Build Pods-Runner scheme first, then Runner for arm64 only (see Build Commands)
8. **App crashes silently on video drop (release build)**: Bundle is incomplete. Use packaging scripts. Run from terminal to see errors.
9. **macOS debug build and the shipped app must stay unsandboxed** (issue #50):
   `packaging/macos/distribution.entitlements` has **no** `app-sandbox`, and
   must not gain one — sandboxing redirects `HOME`, splitting deps installs from
   what the shipped app uses, and a sandboxed process can't remove
   `com.apple.quarantine` from downloads, so macOS SIGKILLs ffmpeg/vspipe.
   `DependencyManager.executabilityProblem()` catches this class by *running*
   ffmpeg after install and on every startup, reporting the `xattr -cr` fix.
10. **Job appears to hang**: `StallWatchdog` in `pipeline_executor.rs` fails the
    job after **600s with no frame progress** rather than hanging forever.
    Raise/disable with `VAPOURBOX_STALL_TIMEOUT_SECS=<secs>` (`0` = wait
    forever) when deliberately debugging a stall.
11. **A vspipe failure is reported as vspipe's, not the encoder's (task #28).**
    When vspipe dies before writing the Y4M header, the encoder ffmpeg says only
    `Header too large`; `vspipe_failure::blame` then reports vspipe instead (it
    must have failed for real, not by SIGPIPE, *and* the encoder must say it got
    no header — every other encoder failure is still reported first). The job
    error is the Python exception and its traceback (`The VapourSynth script
    failed: …`, `VapourSynth failed on output frame N: …`) or, for a **native
    crash inside a plugin**, `vspipe exited with <status> — a native crash …;
    no Python error was printed`: absence of a traceback is the diagnostic.
    Bisect a crash by generating the script (`--config`, keep the `.vpy`) and
    running it under vspipe with passes commented out; on Windows `0xC0000005`
    = access violation, `0xC000001D` = illegal instruction (CPU feature the
    machine lacks), `0xC0000094` = integer divide by zero (SIGFPE elsewhere:
    exit 136) — decoded by `format_exit_status`, as are SIGILL/SIGSEGV/SIGFPE.
    The preview reports a failure the same way (task #56 F9b: it used to quote
    vspipe's first stderr line, a plugin warning, instead of the crash).
    `Header too large` in a job error now means vspipe exited cleanly (or by
    SIGPIPE) with nothing to send.
    **If it happens with every pass disabled, it is load-time, not a filter**:
    VapourSynth autoloads every plugin when the core starts, so one plugin whose
    static initializers use a missing instruction set kills every job (issue #92,
    MVTools' AVX2 tables, `SIGILL` = signal 4 on macOS/Linux). Commenting out
    passes cannot find it; the OS crash report (`.ips` on macOS) names the image,
    and `Scripts/probe-plugin-compat.sh` tests each plugin in isolation.
    **A crash in CI names its plugin on macOS and Linux** (task #66): the
    on-failure step `.github/scripts/print-crash-reports.py` reads macOS's
    `.ips` reports, and on Linux runs gdb over the cores
    `.github/scripts/enable-core-dumps.sh` keeps (piped to a handler, at most
    5, whatever `ulimit -c` says): faulting thread, registers, every thread's
    top frames, the library map. The harness banner prints the CPU model
    (`cpuModel=`). **An intermittent one is reproduced with
    `.github/workflows/repro-native-crash.yml`** (Linux x64; dispatch, or
    push a change to it on a branch): it runs one test with a capturing
    `vspipe-bin` (`replay-vspipe.sh`; the worker runs `vspipe-bin`, never the
    `vspipe` wrapper), then replays the captured runs directly, hundreds a
    minute, plain / single-thread / under valgrind, and runs the report's
    `bare.vpy` calls under valgrind. Valgrind is the instrument for an
    intermittent crash: it reports an uninitialised or out-of-bounds read
    whether or not that run crashes. **A backtrace with the crashing thread
    in vspipe's own `frameDoneCallback` / `outputFrame` and main in
    `freeScript` is vspipe R78's teardown race** (task #68, fixed in R80), not
    the script: any one-frame preview can hit it, roughly 1 in 1,000.
    **A memcheck "uninitialised" report at more than 8 bits and an odd
    plane width is expected and harmless on its own** (task #70):
    VapourSynth's AVX2 kernels read stride padding into lanes they discard,
    and memcheck models `vpmaddwd` per 64-bit half, so the last column is
    marked with the padding beside it. Confirm a finding at the output
    before acting on it: the repro workflow's `verify` input (two
    `--malloc-fill` runs, compared) and `bisect` with `:cpu=none`.
    `qtgmc_stride_padding_test.dart` (push gate) checks QTGMC's picture
    ignores padding on every platform.

## Platform-Specific Notes

### Windows

- **VapourSynth R78 ships Windows purely as a Python wheel** (no `VSPipe.exe`,
  no DLLs, no Python in the zip). `download-deps-windows.ps1` unpacks the Python
  3.12.10 embeddable, adds `Lib\site-packages` to its `._pth`, then expands the
  wheel (copied to a `.zip` name first, since `Expand-Archive` rejects `.whl`).
- Layout moved from R73: vspipe is now at
  `vapoursynth\Lib\site-packages\vapoursynth\vspipe.exe`; the plugin path var is
  **`VAPOURSYNTH_EXTRA_PLUGIN_PATH`** (the old `VAPOURSYNTH_PLUGIN_PATH` is
  inert from R74 on); core filters (`std`, `resize`, …) live in a separate
  **`libvapoursynthfilters.dll`**, without which every job fails at script
  evaluation with missing namespaces (`package-deps-windows.ps1` guards on it).
- Worker sets env vars via `DependencyLocator`: `PYTHONHOME`, `PYTHONPATH`,
  `VAPOURSYNTH_EXTRA_PLUGIN_PATH`, `PATH`.
- Plugins in `deps/windows-x64/vapoursynth/vs-plugins/`, Python packages in `Lib/site-packages/`
- Plain `nnedi3` is **not** in the Windows bundle; it ships `znedi3` +
  `nnedi3cl`. The authoritative required-namespace list is
  `app/test/vapoursynth_integration_test.dart`.
- The script writes `deps/windows-x64/version.json` (as macOS and Linux do) —
  without it the app reports "Version file missing" and re-downloads the
  published bundle over a locally built one.
- Show in Folder: `cmd /c explorer /select, <path>`
- **Ships as an Inno Setup installer, with the zip of the same tree as the
  portable option** (`packaging/windows/vapourbox.iss`, compiled by
  `Scripts/build-windows-installer.ps1`). The rules that keep it working:
  - **Per-user only (`PrivilegesRequired=lowest`), with no all-users option.**
    On Windows the app installs deps and add-ons into `deps\` and `addons\`
    **next to the executable**, so the install directory must be user-writable;
    under `Program Files` the first-launch download fails. Don't add
    `PrivilegesRequiredOverridesAllowed` or an admin install without first
    moving those directories out of the app folder.
  - **Never change `AppId`.** It is how an upgrade finds the existing install;
    a new one installs a second copy with its own uninstall entry.
  - **Upgrade keeps `deps\`/`addons\`; uninstall removes them**
    (`[UninstallDelete]` — the app downloaded them, so the uninstaller doesn't
    otherwise know they exist). `[InstallDelete]` clears `templates\` and
    `data\` first, because Inno never removes a file a newer version dropped
    and `exe_dir\templates` is the first path the worker searches.
  - **The installer is unsigned**, like the rest of the Windows build, so
    SmartScreen warns on it; the README says how to proceed.
  - `build-windows.yml` assembles the package directory inline rather than
    calling `package-windows.ps1` (and the two zips differ in layout), which
    is why the installer is its own script both call. Inno Setup is pinned to
    6.7.3 by SHA-256 in the workflow and passed to the script as `$env:ISCC`
    — the runner image has its own unpinned `ISCC.exe` on `PATH`, which wins
    otherwise. The `.iss` is written against 6, not 7.
  - Not verifiable from macOS: `build-windows.yml` is the test.

### macOS

- Two arches: `deps/macos-arm64` and `deps/macos-x64`, each built natively
  (arm64 on Apple Silicon, x64 on `macos-15-intel`). `DependencyLocator` picks
  the arch at runtime via `uname`.
- Fully self-contained deps (no Homebrew at runtime): Python 3.12
  (python-build-standalone), VapourSynth built from source.
- **Nothing in the bundle may load from outside it, and it is asserted.**
  `Scripts/check-macho-refs.py` fails on any dependency (weak ones included)
  with an absolute path outside `/usr/lib/` and `/System/`, and on any
  absolute `LC_RPATH`, in every Mach-O file of the bundle; it runs at the end
  of `download-deps-macos.sh` (with `--strip-absolute-rpaths`, which deletes
  build-machine rpaths left by Homebrew/Nix builds and re-signs),
  in `package-deps-macos.sh` and on the composed v2 tree. Never whitelist a
  reference to get a build through: libdvdcss was, as a "weak link" that
  wasn't, and deps 1.16.0's arm64 DVD import failed on every Mac without
  Homebrew libdvdcss (task #36). Linux's twin is `check-elf-refs.py`
  (`package-deps-linux.sh`).
- **libdvdread is built from source on both arches** (6.1.3,
  `--without-libdvdcss`, arm64 at minos 15.0), never Homebrew's bottle, which
  links libdvdcss. libdvdcss is never linked or bundled; libdvdread opens it
  at run time if the user installed it, and
  `patches/libdvdread-6.1.3-macos-dvdcss-paths.patch` (hard-fails if it stops
  applying) makes that look in `/opt/homebrew/lib`, `/usr/local/lib` and
  `/opt/local/lib`: dyld's fallback for a bare name misses Apple Silicon
  Homebrew and MacPorts, and preloading it in the worker doesn't help. Every
  platform's bundle must carry libdvdread (`_extraFiles`), and
  `dvd_extract_integration_test` fails, not skips, without a loadable one
  (docs/reports/2026-11-libdvdread-dvdcss).
- Worker sets: `PYTHONHOME`, `PYTHONPATH`, `VAPOURSYNTH_CONF_PATH`, `DYLD_LIBRARY_PATH`
- `vspipe` is a wrapper script that generates config dynamically.
- **FFmpeg** is a pre-built static binary linking only system frameworks,
  from martin-riedl.de on both arches (Homebrew's build is dynamically linked
  to Homebrew dylibs and can't be bundled). x64 is pinned by build ID and
  SHA-256 (`FFMPEG_MACOS_X64_BUILD`, minos 12.0); arm64 takes `latest` and is
  series-checked. Both must have `libsvtav1`. x64 was evermeet.cx's build up
  to deps 1.17.0-rc1, which has no SVT-AV1 (task #45,
  docs/reports/task-45-macos-x64-ffmpeg-svtav1).
- **x64 minimum macOS = 12.0 (Monterey), issue #39**: the only hosted Intel
  runner is `macos-15-intel`, so the x64 build exports
  `MACOSX_DEPLOYMENT_TARGET=12.0` and builds bundled support libs from source
  to target it. **arm64 targets 15.0** (matching its prebuilt plugins). The
  app/worker deployment target is set per-arch in `build-macos.yml`/`package-macos.sh`.
- **Code signing**: after `install_name_tool` modifications, binaries must be
  re-signed: `codesign -s - -f <binary>` (exit code 137 = SIGKILL means invalid
  signature).
- **A Zig-built x86_64 dylib must be linked with header padding before it is
  signed.** Zig leaves ~8 bytes after the load commands and does not sign
  x86_64 output; `codesign` then writes its 16-byte load command over the start
  of `__text`, silently, and the plugin segfaults on load (`--remove-signature`
  does not undo it). The vszip block patches `headerpad_max_install_names` into
  `build.zig` and refuses to sign without room. The shipped x64 zsmooth has the
  same overlap and works only because the clobbered function is never called —
  see docs/ENGINEERING_NOTES.md, "CLAHE local contrast via vszip".
- Quarantine removal: `xattr -cr` on deps after download
- Show in Folder: `open -R <path>`
- **Apple Silicon app build for x64**: `app/macos/Podfile` reads
  `VAPOURBOX_ARCHS` (default `arm64`); set to `x86_64` + `ARCHS=x86_64` on
  xcodebuild to cross-compile the Intel Runner.
- **Impeller is force-disabled** (`FLTEnableImpeller = false` in
  `app/macos/Runner/Info.plist`). CI floats on `channel: stable` with no
  Flutter version pin, so Flutter 3.47 (2026-08-12) making Impeller the
  default macOS renderer reached a VapourBox release with no code change on
  our side, and corrupted the window on Intel GPUs (issue #91). Re-evaluate
  once Impeller's Intel-Mac path is solid — don't remove this to silence a
  lint or "modernize" without re-testing on real Intel hardware first.

### Linux

- Bundled deps in `~/.local/share/VapourBox/deps/linux-{x64,arm64}/` (or `$XDG_DATA_HOME`)
- Worker sets: `PYTHONHOME`, `PYTHONPATH`, `VAPOURSYNTH_CONF_PATH`, `LD_LIBRARY_PATH`
- `patchelf` used for RPATH fixup (equivalent to macOS `install_name_tool`)
- GPU/OpenCL: requires user-installed GPU driver; nnedi3cl degrades gracefully without it
- Show in Folder: `xdg-open <directory>`
- Debug builds: use `./Scripts/run-debug-linux.sh`
- No code signing or quarantine removal needed
- **Ships as an AppImage, with a tarball of the same tree as the fallback**
  (`package-linux.sh`; pieces in `packaging/linux/`). The rules that keep it
  working:
  - **`AppRun` exports nothing** — no `LD_LIBRARY_PATH`, no bundled GTK. Its
    environment is inherited by the worker and by the ffmpeg/vspipe it spawns
    from the downloaded deps bundle, so anything set there leaks into them.
  - **The mount is read-only** (`/tmp/.mount_*`). Nothing may be written next
    to the executable on Linux; deps and add-ons install under
    `$XDG_DATA_HOME`.
  - **The AppImage carries the deps zips; the tarball does not.**
    `package-linux.sh --bundle-deps DIR` copies the published bundle (and on
    x64 the v2 delta), each with its `.sha256.json`, into
    `usr/lib/vapourbox/bundled-deps/`, and `DependencyManager` installs from
    there instead of downloading (see "Dependency Versioning"). They go in as
    the published zips, not unpacked: the mount is read-only and the install
    path, tier choice and verification stay exactly the download's. So a deps
    release must exist **before** the app build (`build-linux.yml` fetches it
    by `deps_tag`), the script refuses zips of any version but the one
    `deps-version.json` names, and a deps-only fix still reaches AppImage
    users only through a new AppImage or the normal download fallback.
  - **Named `VapourBox-X-x86_64.AppImage` / `-aarch64.AppImage`** — the
    AppImage convention, which the catalog (appimage.github.io) checks: the
    machine's architecture name and no "linux". The tarball keeps
    `linux-<arch>`.
  - **The `.AppImage.zsync` must be uploaded beside every AppImage.** The
    embedded update information names it
    (`gh-releases-zsync|…|latest|VapourBox-*-<x86_64|aarch64>.AppImage.zsync`),
    so one missing is an updater that fails for every user. The script fails
    if `zsyncmake` is absent rather than build without it, and
    `packaging_test.dart` asserts the release upload picks the files up.
    `latest` is GitHub's Latest release — one more reason a deps or whisper
    release must never be marked Latest.
  - **A second `.zsync`, under the old name, is a bridge for 1.2.0.** 1.2.0 was
    the only release named `…-linux-<arch>.AppImage` and embeds
    `VapourBox-*-linux-<arch>.AppImage.zsync`. Each release therefore also
    publishes a copy of its `.zsync` as `VapourBox-X-linux-<arch>.AppImage.zsync`
    (`LEGACY_ZSYNC`); its relative `URL:` header names the new file. Remove it
    only once updating from 1.2.0 no longer matters. **Not yet proven
    end-to-end**: it needs one real AppImageUpdate run from a 1.2.0 AppImage.
  - **AppStream metadata** is `packaging/linux/app.vapourbox.VapourBox.appdata.xml`,
    installed to `usr/share/metainfo/` with the version, date and a
    tag-pinned screenshot URL stamped in at package time. It is what the
    catalog and software centres list. Named `.appdata.xml` because the
    catalog's lint only looks for that name, and limited to tags a 2021
    `appstreamcli` knows because that is what the catalog runs. The script
    validates it with `--no-net` and passes `--no-appstream` to appimagetool,
    whose own check would fetch the screenshot from a tag that does not exist
    until the release is published. **`docs/images/screenshot.png` is the
    listing's screenshot** — keep it current.
  - The desktop file and icon are named for `APPLICATION_ID`
    (`app.vapourbox.VapourBox`, `app/linux/CMakeLists.txt`), which is what
    the window reports as its app id; rename one and the running window stops
    matching its launcher.
  - `appimagetool` is pinned by version **and** SHA-256 in the script. The
    AppImage runtime it embeds is fetched by appimagetool itself at build time
    and is not pinned.
  - Not verifiable from macOS (appimagetool is a Linux binary):
    `build-linux.yml` is the test.

Plugin lists for all platforms: see `deps/` directories or download scripts.

---

## Dependency Versioning and Auto-Download

Dependencies are versioned separately from the app via `app/assets/deps-version.json` and distributed as separate GitHub releases (tag: `deps-vX.Y.Z`). The app auto-downloads deps on launch if missing, outdated, or built for a different CPU tier (x64 only — see "CPU tiers"; the assets are `DependencyManager.installAssetIds(platformId, tier, …)`).

**"Download" is the last of three sources.** For each zip an install needs,
`DependencyManager._obtainZip` takes, in order: a copy the package shipped in
`bundled-deps/` beside the executable (`findBundledZip`; today only the Linux
AppImage ships one), the cached download from an earlier attempt, then the
network. The bundled directory is one fixed path inside the app's own tree and
must never become a search: a zip found there is extracted and run, so it gets
the trust of the executable next to it and no more places than that. A bundled
zip **must** match the `.sha256.json` shipped beside it (not best-effort, as a
download's sidecar is — offline there is nothing else to say it is whole); one
that doesn't is ignored and the download happens as usual. A bundled zip is
never deleted or copied; only zips the app fetched are cleaned up.

`deps-version.json` is a **slim pointer** — `{version, releaseTag, githubRepo}`. Integrity metadata is **not** stored here: each `package-deps-*` script writes a **sidecar** `<zip>.sha256.json` uploaded next to the zip, which the app fetches and verifies at download time (best-effort if the sidecar is missing). **Net effect: a new deps release only needs a `version`/`releaseTag` bump.**

**Key files**: `app/assets/deps-version.json`, `app/lib/services/dependency_manager.dart`, `app/lib/views/dependency_download_dialog.dart`.

App and deps use **separate release tags** so unchanged deps aren't re-uploaded on every app release.

> **Rebuilding a version in place doesn't refresh anyone's install.** The
> up-to-date check is a string comparison against the installed version, so
> re-uploading different contents under an existing tag leaves every machine
> that already downloaded it on the old bundle, silently. Only reuse a version
> while **no released app references it**; once one does, adding anything needs
> a **new** version.

---

## Release Process

### Quick Start (Automated)

```bash
./Scripts/release.sh [--skip-deps-check] [--skip-build] [--dry-run]
```

This prompts for version, checks deps changes, builds, packages, and creates draft GitHub releases.
It does **not** package deps: if they changed, it stops and prints the
`build-deps-*` workflow commands. A local checkout holds only one CPU tier per
x64 platform, so a locally packaged deps release would be missing the other.

### CI Build and Release

```bash
# Full flow: trigger CI builds, wait, download artifacts, upload to draft release
./Scripts/ci-build-and-release.sh --version 0.7.0 [--deps-tag deps-v1.1.0] [--arch both]

# Just download latest artifacts (skip triggering new builds)
./Scripts/ci-build-and-release.sh --version 0.7.0 --skip-trigger
```

Prerequisites: draft release must exist for the tag, `gh` CLI authenticated.

### Triggering a Release (concrete step-by-step)

This is the exact flow to cut an app release built entirely in CI (no local
build). Deps are separate — only touch them if they changed (see step 2).

```bash
# 1. Bump the app version everywhere (pubspec + build number, worker/Cargo.toml,
#    Windows Runner.rc, macOS Info.plist). The build number auto-increments.
./Scripts/update-version.sh --app 0.9.10
#    Deps unchanged? skip. Deps changed? also pass --deps X.Y.Z --deps-tag deps-vX.Y.Z
#    (check first: ./Scripts/check-deps-changed.sh)

# 2. Commit and push to main (the Build workflows run from main via workflow_dispatch).
git add -A && git commit -m "chore: bump app version to 0.9.10" && git push origin main

# 3. Create the DRAFT release for the tag, pointing at the pushed commit.
#    The tag (vX.Y.Z) is created when the release is published.
gh release create v0.9.10 --draft --target main --title "VapourBox 0.9.10" --notes "..."

# 4. Trigger the three platform Build workflows, wait for them, then download the
#    artifacts and upload them to the draft. deps-tag is auto-read from
#    deps-version.json. macOS defaults to arch=both → separate arm64 + x64 DMGs.
#    LONG-RUNNING (~20–40 min of `gh run watch`) — run it detached/in background.
./Scripts/ci-build-and-release.sh --version 0.9.10

# 5. Review the draft, then publish when ready.
gh release view v0.9.10 --web
gh release edit v0.9.10 --draft=false
```

Notes:
- **Order matters**: the draft release (step 3) must exist *before* running
  `ci-build-and-release.sh` (step 4) — the script aborts if it can't find it.
- Re-run just the upload against existing green runs with `--skip-trigger`
  once all three builds have completed.
- **`gh run watch` false-failure gotcha**: it can exit non-zero on a transient
  `HTTP 401: Bad credentials`, aborting the script even though the build is
  fine. Confirm with `gh run view <id> --json status,conclusion` before
  assuming a build failed; if actually green, re-run with `--skip-trigger`.
- macOS DMGs are signed + notarized inside `build-macos.yml`; Windows/Linux are
  unsigned. See "macOS Code Signing & Notarization" for required secrets.

### Release Scripts

| Script | Purpose |
|--------|---------|
| `Scripts/release.sh` | Main orchestrator |
| `Scripts/ci-build-and-release.sh` | Trigger CI, download artifacts, upload to draft |
| `Scripts/get-github-version.sh` | Fetch versions from GitHub (`--app`, `--deps`, `--next-app`, `--next-deps`) |
| `Scripts/update-version.sh` | Update version across all files (`--app X.Y.Z --deps X.Y.Z --deps-tag deps-vX.Y.Z`) |
| `Scripts/check-deps-changed.sh` | Detect if deps changed since last release (exit 0=changed, 1=unchanged) |
| `Scripts/package-macos.sh` | Package macOS app |
| `Scripts/package-windows.ps1` | Package Windows app (installer + zip) |
| `Scripts/build-windows-installer.ps1` | Compile the Inno Setup installer from an assembled package dir |
| `Scripts/package-linux.sh` | Package Linux app (AppImage + `.zsync` + tarball) |
| `Scripts/package-deps-macos.sh` | Package macOS deps |
| `Scripts/package-deps-windows.ps1` | Package Windows deps |
| `Scripts/package-deps-linux.sh` | Package Linux deps |
| `Scripts/promote-deps-rc.py` | Re-stamp a tested deps release candidate's assets as the final version: names, `version.json`, delta `baseSha256`, sidecars; verifies every other entry unchanged |
| `Scripts/make-deps-delta.py` | Cut an x64 platform's v2 delta from a full v2 build and the v3 bundle (run by the `delta-x64` job of each `build-deps-*` workflow) |
| `Scripts/download-deps-linux.sh` | Build Linux deps from source |
| `Scripts/run-debug-linux.sh` | Dev build + run for Linux |

### Release Checklist

1. **Confirm version** — ask user, update `pubspec.yaml`
2. **Check deps** — run `check-deps-changed.sh`; if changed, bump `version`/`releaseTag` in `deps-version.json`.
3. **Build & package deps in CI** — dispatch `build-deps-{macos,windows,linux}.yml` with `release_tag`. They build both x64 tiers, cut the v2 delta, gate the composed v2 tree, and only then upload each zip **and** its `<zip>.sha256.json` sidecar.
4. **Check the deps release** — eight zips, each with a sidecar: the five bundles `macos-arm64`, `macos-x64`, `windows-x64`, `linux-x64`, `linux-arm64`, and the three deltas `macos-x64-v2-delta`, `windows-x64-v2-delta`, `linux-x64-v2-delta`. There must be **no** full `…-x64-v2.zip`.
5. **Test** — fresh install + upgrade test
6. **Create GitHub releases** — deps release first (if changed, tag `deps-vX.Y.Z`), then app release (tag `vX.Y.Z`)

> ### NEVER mark a deps release as "Latest"
>
> **Always pass `--latest=false` when creating or editing a `deps-v*` release** —
> `gh release create` defaults to Latest, and deps are cut *after* the paired
> app release, so the default silently demotes the app release from Latest.
> The scripts already do this correctly; the trap is a hand-rolled
> `gh release create` (an rc being promoted, a rebuild, a one-off).
>
> If it happens, fix **both** halves:
> ```bash
> gh release edit deps-vX.Y.Z --latest=false
> gh release edit vX.Y.Z      --latest        # put it back on the app release
> ```
> Same rule applies to whisper add-on releases (`whisper-vX.Y.Z`).

### macOS Code Signing & Notarization

The macOS app is signed with a **Developer ID Application** certificate and
notarized by Apple. Signing happens **in CI** (`build-macos.yml`) —
`package-macos.sh --notarize` signs every Mach-O inner-out, signs the DMG,
submits to the notary service, and staples the ticket.

`package-macos.sh` also works locally with a Developer ID cert in your
keychain; `--notarize` uses a stored `notarytool` keychain profile (default
`VapourBox`), falling back to `NOTARY_APPLE_ID`/`NOTARY_PASSWORD`/`NOTARY_TEAM_ID`
env vars in CI. Use `--no-sign` for ad-hoc local test builds.

> **Every helper executable needs the entitlements too, not just the app.**
> Entitlements are per-Mach-O, so `vapourbox-worker` must be signed with
> `--entitlements packaging/macos/distribution.entitlements` in its own right —
> without them it gets library validation and can't `dlopen` the ad-hoc-signed
> `libdvdread.dylib` it needs for DVD import, failing with a Team ID mismatch.
> Debug builds are ad-hoc signed (no Team ID to mismatch) so this only shows up
> in a released build; `package-macos.sh` asserts `disable-library-validation`
> on both `vapourbox` and `vapourbox-worker` after signing.

> **A notarization `403` is not necessarily your account.** The notary service
> can return a permissions-shaped 403 during Apple-side outages. Check
> <https://developer.apple.com/system-status/> first, then account causes
> (membership renewal, pending license agreement, app-specific password
> revoked by an Apple ID password change) before assuming the credentials are
> wrong — `git log` showing no change to the signing scripts since the last
> success is the strongest signal it isn't us.

**Required GitHub repo secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE` | Base64 of the exported Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password set when exporting the `.p12` |
| `MACOS_KEYCHAIN_PASSWORD` | Any random string (temp keychain password) |
| `MACOS_NOTARY_APPLE_ID` | Apple ID email for notarization |
| `MACOS_NOTARY_PASSWORD` | App-specific password from appleid.apple.com |
| `MACOS_NOTARY_TEAM_ID` | `PMXZ63S6YG` |

**One-time setup** (export the cert and load secrets via `gh`):

```bash
# 1. Export the Developer ID Application cert + private key from Keychain Access
#    (right-click the identity → Export → .p12, set a password) to ~/devid.p12
# 2. Base64-encode and store all secrets:
gh secret set MACOS_CERTIFICATE < <(base64 -i ~/devid.p12)
gh secret set MACOS_CERTIFICATE_PASSWORD   # paste the .p12 export password
gh secret set MACOS_KEYCHAIN_PASSWORD      # paste any random string
gh secret set MACOS_NOTARY_APPLE_ID        # paste your Apple ID email
gh secret set MACOS_NOTARY_PASSWORD        # paste app-specific password
gh secret set MACOS_NOTARY_TEAM_ID         # paste PMXZ63S6YG
rm ~/devid.p12
```

Create the app-specific password at appleid.apple.com → Sign-In and Security → App-Specific Passwords. The Developer ID cert expires **2027-02-01**; re-export and update `MACOS_CERTIFICATE` before then.

### Cross-Platform Notes

- Flutter Windows can't build on macOS — use GitHub Actions
- Flutter Linux can't build on macOS — use GitHub Actions or a Linux VM
- Deps for every platform are built in CI by their own workflow: `build-deps-macos.yml` (arm64 + x64), `build-deps-linux.yml` (x64 + arm64), `build-deps-windows.yml` (x64, on `windows-latest`). All take `version` + optional `release_tag` (leave empty to skip the release upload).
- Windows deps can also be zipped on macOS if `deps/windows-x64/` exists (`Scripts/package-deps-windows.ps1` via pwsh), but the CI workflow is the canonical path.
- Linux deps must be built on Linux (`./Scripts/download-deps-linux.sh`) or via `build-deps-linux.yml`
- macOS ships as **two separate per-arch DMGs** (arm64 + x64), not a universal binary — `build-macos.yml` takes an `arch` input (`both` | `arm64` | `x64`, default `both`), one DMG per arch, each with its own deployment target (arm64 → 15.0, x64 → 12.0; the x64 slice cross-compiles on the `macos-15` runner).
- Deps are **not** bundled — the app downloads `macos-arm64` or `macos-x64` deps at runtime per `uname`, so both deps bundles must be published.
- `app/macos/Podfile` reads `VAPOURBOX_ARCHS` (default `arm64`; set to `x86_64` for the Intel build) and `VAPOURBOX_DEPLOYMENT_TARGET` (default `12.0`; the arm64 build sets `15.0`).
- Publishing a new x64 deps zip needs no `deps-version.json` edit — upload the zip and its `.sha256.json` sidecar.

### Dependency Version History

Full write-ups (root causes, measurements) for each entry are in
[docs/ENGINEERING_NOTES.md](docs/ENGINEERING_NOTES.md).

| Deps Version | Date | Changes |
|--------------|------|---------|
| 1.0.0 | 2025-01-15 | Initial release |
| … | | (1.1.0–1.6.0 went unrecorded) |
| 1.7.0 | 2026-08-01/02 | fmtconv r30→**r31** (pinned, from GitLab) + patch fixing an aarch64 integer-scaler bug that brightened/blackened QTGMC Placebo/Very Slow/Draft on arm64. Rebuilt 2026-08-02 to add **zsmooth** (MIT: CCD, Cnr4, RemoveGrain/TemporalMedian family), pinned 0.19.0 |
| 1.8.0 | 2026-08-07 | VapourSynth **R73 → R78** everywhere (Windows Python-wheel layout; `deps/<platform>/vapoursynth/` is the Python package on macOS/Linux). Adds **akarin** (LLVM JIT for `std.Expr`, ~4x on arm64 QTGMC; not on macos-x64). Fixes nnedi3 on linux-arm64. Removes BestSource. Linux now needs glibc 2.39 |
| 1.9.0 | 2026-08-15 | Adds **fluxsmooth** (unlocks havsfunc's STPresso), **bifrost** (temporal rainbow/dot-crawl removal), **retinex** (shadow-detail lift) — all pinned to the newest release with a published Windows binary |
| 1.10.0 | 2026-08-31 | **Issue #82**: zsmooth now ships one build per x86 CPU baseline (haswell, x86_64_v2), fixing an illegal-instruction crash on pre-2013 CPUs. **FFmpeg pinned to 9.0 on all four platforms** (they had silently diverged: Windows on an unpinned post-9.0 master, macOS on floating 9.0.1, Linux stuck at 7.1 after BtbN garbage-collected the pinned tag) |
| 1.11.0 | 2026-09 | **Issue #92**: every x86 bundle ships in two **CPU tiers** — `v3` (x86-64-v3; the plain asset names) and `v2` (`…-x64-v2`, anything older), chosen by the app from `vapourbox-worker --probe-cpu`. Each bundle carries one autoloaded zsmooth (replacing 1.10.0's two-builds-loaded-by-path). macOS v2 builds MVTools v24 from source without its AVX2 files, whose static initializers SIGILLed inside `dlopen` on pre-AVX Macs. v2 bundles are gated (SDE on Linux/Windows, static check on macOS) before publishing |
| 1.12.0 | 2026-10-04 | **Issue #101**: akarin 1.4.1 → **1.5.0** on every platform. The 1.4.1 Linux wheel put JIT code on the `brk` heap, where SELinux denies `PROT_EXEC`, so every job segfaulted on Fedora/RHEL from deps 1.8.0 on. `download-deps-linux.sh` now fails if `libakarin.so` lacks the mmap allocator |
| 1.13.0 | 2026-10 | One new plugin; every other binary is built from the same sources as 1.12.0. Adds **vszip** 22.1.0 (MIT) for `vszip.CLAHE`, Color Correction's local contrast (issue #90). Baseline build only, flat in the plugin directory on every platform (the wheels' AVX2/AVX-512 variants are left out); macOS x64 builds the sdist with Zig 0.16.0 for the 12.0 floor, with header padding so it can be signed. The v2 CPU tier is no longer a second full bundle: each x64 platform publishes its v3 bundle plus `…-x64-v2-delta.zip`, the files in `_tierFiles` (zsmooth; on macOS also MVTools), extracted over it (`"tierFormat": "delta"`). Every x64 machine downloads the same bundle; only an older CPU fetches the few MB more. This is also what lets the Linux AppImage carry its deps for both tiers without doubling in size |
| 1.14.0 | 2026-10-25 | Adds **RIFE** 4.26 (`r9_mod_v33`, MIT) + its model in `vapoursynth/rife/`, and **VSNCNN** (vs-mlrt v15.16, GPL-3.0) + Real-ESRGAN / Real-CUGAN models in `vapoursynth/ncnn/`, on macos-arm64, windows-x64 and linux-x64, with **MoltenVK** 1.4.2 (Apache-2.0) in `vapoursynth/moltenvk/` on macOS. Not autoloaded; see "GPU Plugins". **BM3D** r12 (MIT) on every platform; it had been macOS arm64 only (see "BM3D and KNLMeans Noise Reduction"). **descale** r12 (MIT) on every platform, for the Descale pass. (AnimeJaNai's models, used by the same VSNCNN, are an app add-on, not in the bundle). Published as the tested `deps-v1.14.0-rc1` bundles with only the version changed; every other file is byte-identical |
| 1.15.0 | 2026-11-03 | **Issue #144**: KNLMeansCL moves to Jaded Encoding Thaumaturgy's fork **v1.3** on every platform (Windows: PyPI wheel, replacing Khanattila's 2018 v1.1.1 zip, which refused 10-bit 4:2:0; macOS/Linux: the `v1.3` tag, replacing unpinned master, which gave unrepeatable results on Apple's OpenCL). Both meson patchers learn v1.3's assigned `run_command` include probe. Published as the tested `deps-v1.15.0-rc1` bundles with only the version changed |
| 1.16.0 | 2026-11-09 | **vszip 22.1.0 → 24.0.0** on every platform (CPU `NLMeans` for Noise Reduction's NLMeans (CPU) and the vine dehalo; macOS x64 sdist now built with Zig 0.17.0). Adds **SangNom** r45 (PyPI wheels; MIT source, GPL-2.0 binaries) on every platform for Anti-aliasing's SangNom method. Both single-file on x64 (no AVX), so `_tierFiles` is unchanged. **rc2: the AI models leave the bundle** — RIFE 4.26's (now the `frame-rate-rife` add-on) and the Real-ESRGAN anime / Real-CUGAN ones (now `upscale-anime`); the plugins stay, and their probes run stand-in models. Published as the tested `deps-v1.16.0-rc2` bundles with only the version changed (`Scripts/promote-deps-rc.py`) |
| 1.17.0 | rc1 2026-11-15, rc2 2026-11-16, rc3 2026-11-17 | **Task #36**: macOS arm64 libdvdread built from 6.1.3 source (patched to find a user's libdvdcss in `/opt/homebrew/lib`, `/usr/local/lib`, `/opt/local/lib`) instead of Homebrew's bottle, which linked `/opt/homebrew/opt/libdvdcss/…` and failed to load on Macs without it; macOS x64 gets the same patched build. Absolute build-machine rpaths stripped from libvapoursynth, vapoursynth.abi3.so, libfftw3f*, libboost_charconv, bm3d, dctfilter and mvtools (inert: nothing used `@rpath`). Windows and Linux binaries unchanged; libdvdread is now a required file on every platform. **rc2** (task #45): macOS x64 FFmpeg evermeet 9.0.1 → martin-riedl 9.0.2 (build 1789931006, pinned by SHA-256), which has SVT-AV1, so AV1 output works on Intel Macs; x264/x265/MP3 bitstreams change there, native codecs byte-identical. **rc3** (task #60): **Bifrost** v3.0 → **4.0** from its PyPI wheels on every platform (was the v3.0 tag's `bifrost.c` built from source on macOS/Linux, v3.0's 7z on Windows), under the same file names; v3.0 left chroma past the last whole 4x4 block uninitialised (different output run to run at width 98, 720x486), v4.0 initialises it and runs at 8–16 bits natively. No AVX, so `_tierFiles` unchanged |
| 1.18.0 | rc1 2026-11-19 | **Task #62**: FFT3DFilter built from source at R2 with `patches/fft3dfilter-r2-determinism.patch` on every platform (Windows: Zig cross-compile replacing the R2 release DLL; macOS arm64: replacing yuygfgg's prebuilt), so its output no longer differs from run to run. One build for both x64 tiers; file names unchanged. **Task #68**: vspipe R78 with upstream's frame-done count fix (`patches/vapoursynth-r78-vspipe-frame-done-count.patch`, 4ff3f8a0) on every platform (Windows: Zig build replacing the wheel's `vspipe.exe`), so a one-frame preview can no longer be torn down under its last frame's callback (SIGSEGV). VapourSynth stays R78: R80 dropped API 3, which 12 bundled plugins need |
