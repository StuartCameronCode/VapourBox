# VapourBox - AI Assistant Guide

## Important: Documentation Maintenance

**Always keep both `README.md` and `CLAUDE.md` up to date when making changes to:**
- Build instructions or dependencies
- Project structure
- Development workflow
- Configuration or setup steps

Both files should stay synchronized - README.md is for humans, CLAUDE.md is for AI assistants.

## Project Overview

VapourBox is a **cross-platform** (macOS + Windows) video deinterlacing application using QTGMC via VapourSynth. It provides a simple drag-and-drop interface as an alternative to more complex tools like Hybrid.

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
- **Progress**: JSON lines from worker stdout
- **Cancel**: SIGTERM (Unix) or TerminateProcess (Windows)

### JSON Message Format (Worker → App)

```json
{"type":"progress","frame":1234,"totalFrames":50000,"fps":45.2,"eta":892}
{"type":"log","level":"info","message":"Starting encoding..."}
{"type":"error","message":"Failed to load input"}
{"type":"complete","success":true,"outputPath":"/path/to/output.mp4"}
```

## Project Structure

```
VapourBox/
├── app/                        # Flutter application
│   ├── lib/
│   │   ├── models/             # VideoJob, QTGMCParameters, ProgressInfo
│   │   ├── viewmodels/         # MainViewModel, SettingsViewModel
│   │   ├── views/              # MainWindow, DropZone, ProgressSection
│   │   │   └── settings/       # QTGMC parameter UI sections
│   │   ├── services/           # WorkerManager, FieldOrderDetector
│   │   └── utils/              # Platform utilities
│   ├── macos/                  # macOS platform config
│   └── windows/                # Windows platform config
│
├── worker/                     # Rust worker crate
│   ├── src/
│   │   ├── models/             # Matching data models (serde)
│   │   │   ├── video_job.rs
│   │   │   ├── qtgmc_parameters.rs
│   │   │   └── progress_info.rs
│   │   ├── script_generator.rs # VapourSynth .vpy generation
│   │   ├── pipeline_executor.rs# vspipe | ffmpeg execution
│   │   ├── progress_reporter.rs# JSON stdout output
│   │   ├── dependency_locator.rs# Find bundled deps
│   │   └── platform/           # Platform-specific code
│   │       ├── macos.rs
│   │       └── windows.rs
│   └── templates/
│       └── qtgmc_template.vpy  # VapourSynth script template
│
├── deps/                       # Platform-specific dependencies
│   ├── macos-arm64/
│   │   ├── python/             # Python.framework
│   │   ├── vapoursynth/plugins/# VS plugins (.dylib)
│   │   ├── ffmpeg/             # FFmpeg binary
│   │   └── python-packages/    # havsfunc, mvsfunc, etc.
│   ├── macos-x64/
│   └── windows-x64/
│       ├── python/             # Embeddable Python
│       ├── vapoursynth/plugins/# VS plugins (.dll)
│       ├── ffmpeg/             # FFmpeg binary
│       └── python-packages/
│
├── licenses/                   # License files
│   ├── GPL-2.0.txt
│   ├── GPL-3.0.txt
│   ├── LGPL-2.1.txt
│   └── NOTICES.txt             # Third-party attributions
│
├── scripts/                    # Build and setup scripts
│   ├── download-deps-windows.ps1
│   └── download-deps-macos.sh
│
├── packaging/                  # Platform installers
│   ├── macos/                  # Info.plist, entitlements
│   └── windows/                # NSIS installer config
│
└── legacy/                     # Original Swift code (reference)
    ├── VapourBox/           # SwiftUI app
    ├── VapourBoxWorker/     # Swift worker
    └── Shared/                 # Shared models
```

## Key Files

### Rust Worker
| File | Purpose |
|------|---------|
| `worker/src/models/video_job.rs` | Job config, EncodingSettings, enums |
| `worker/src/models/qtgmc_parameters.rs` | All 70+ QTGMC parameters (serde) |
| `worker/src/script_generator.rs` | Template substitution for .vpy |
| `worker/src/pipeline_executor.rs` | vspipe \| ffmpeg execution |
| `worker/templates/qtgmc_template.vpy` | VapourSynth script template |

### Flutter App
| File | Purpose |
|------|---------|
| `app/lib/models/video_job.dart` | Job config (json_serializable) |
| `app/lib/models/qtgmc_parameters.dart` | QTGMC params matching Rust |
| `app/lib/services/worker_manager.dart` | Process spawning, IPC |
| `app/lib/views/main_window.dart` | Main UI |
| `app/lib/views/about_dialog.dart` | About dialog with licenses |

## Build Commands

### Prerequisites
- Flutter SDK 3.16+
- Rust 1.70+
- Windows: Visual Studio Build Tools with C++ workload
- macOS: Xcode Command Line Tools

### Download Dependencies

**Windows (PowerShell):**
```powershell
.\scripts\download-deps-windows.ps1
```

**macOS:**
```bash
./scripts/download-deps-macos.sh
```

### Build Rust Worker

```bash
cd worker
cargo build --release
```

### Build Flutter App

**Windows:**
```bash
cd app
flutter pub get
flutter build windows --release
```

**macOS:**
```bash
cd app
flutter pub get
flutter build macos --release
```

### Generate Dart JSON Serialization

```bash
cd app
dart run build_runner build
```

## Common Tasks

### Adding a New QTGMC Parameter

1. Add to `worker/src/models/qtgmc_parameters.rs` (with serde attributes)
2. Add to `app/lib/models/qtgmc_parameters.dart` (with json_annotation)
3. Add to `worker/templates/qtgmc_template.vpy` using `{{#PARAM}}...{{/PARAM}}` syntax
4. Add to `worker/src/script_generator.rs` substitution logic
5. Add UI control in Flutter settings view

### Modifying Worker Communication

1. Update `WorkerMessage` enum in both:
   - `worker/src/models/progress_info.rs`
   - `app/lib/models/progress_info.dart`
2. Update JSON serialization to match
3. Update `ProgressReporter` (Rust) and `WorkerManager` (Dart)

### Adding Platform Support

1. Add deps directory: `deps/{platform}-{arch}/`
2. Create download script in `scripts/`
3. Update `DependencyLocator` in Rust for new paths
4. Add Flutter platform config if needed

## QTGMC Parameters Reference

The most important parameters:

- **Preset**: Master setting (Placebo → Draft) that sets defaults
- **TFF**: Top-field-first (true) or bottom-field-first (false)
- **TR0/TR1/TR2**: Temporal radius settings controlling smoothing
- **EdiMode**: Interpolation method (NNEDI3, EEDI3+NNEDI3, etc.)
- **SourceMatch**: Higher fidelity mode (0=off, 1-3=increasingly accurate)
- **FPSDivisor**: 1=double-rate (50i→50p), 2=single-rate (50i→25p)

## Testing

```bash
# Rust tests
cd worker
cargo test

# Flutter tests
cd app
flutter test

# Test worker standalone
cd worker
cargo run --release -- --config test_job.json
```

## havsfunc Compatibility Patches

The havsfunc.py file requires patches for API compatibility. The `download-deps-windows.ps1` script applies these automatically, but for reference:

### 1. mvtools API (renamed parameters)
```python
def _fix_mv_args(args):
    result = {}
    for k, v in args.items():
        if k == '_lambda': result['lambda'] = v
        elif k == '_global': result['global'] = v
        else: result[k] = v
    return result
```
Replace `**analyse_args)` with `**_fix_mv_args(analyse_args))` and similarly for `recalculate_args`.

### 2. DFTTest API (sstring parameter removed)
The newer DFTTest plugin removed the `sstring` parameter. Replace:
```python
# Old (havsfunc r31):
core.dfttest.DFTTest(clip, tbsize=1, sstring='0.0:4.0 0.2:9.0 1.0:15.0', planes=planes)
# New:
core.dfttest.DFTTest(clip, tbsize=1, sigma=10.0, planes=planes)
```

### 3. VapourSynth YCOCG removal
Newer VapourSynth versions removed `vs.YCOCG`. In LUTDeCrawl, replace:
```python
# Old:
input.format.color_family not in [vs.YUV, vs.YCOCG]
# New:
input.format.color_family != vs.YUV
```

## Code Style

### Rust
- Use `anyhow` for error handling
- Use `serde` with `rename_all = "camelCase"` for JSON compatibility
- Platform-specific code in `platform/` module with `#[cfg]`

### Dart/Flutter
- Provider for state management
- `json_annotation` + `json_serializable` for models
- MVVM pattern (models, viewmodels, views, services)

## Debugging Tips

1. **Worker crashes**: Run worker standalone with `--config` to isolate
2. **JSON mismatch**: Compare Rust and Dart model serialization
3. **Plugin load failures**: Check environment variables in `DependencyLocator`
4. **Progress not updating**: Check stdout parsing in `WorkerManager`
5. **Encoding fails**: Run generated .vpy script manually with vspipe
6. **Template not found**: Check that `worker/templates/qtgmc_template.vpy` exists and search paths in `script_generator.rs`

## Windows-Specific Notes

### VapourSynth Portable Setup

On Windows, VapourSynth R73 portable bundles `VSScriptPython38.dll` which requires Python 3.8 (not 3.11+):

```
deps/windows-x64/vapoursynth/
├── VSPipe.exe              # Main executable
├── VSScriptPython38.dll    # Requires Python 3.8
├── python38.dll            # Python 3.8 runtime
├── python3.dll
├── python38.zip            # Python stdlib
├── vs-plugins/             # VapourSynth plugins (.dll)
└── Lib/site-packages/      # Python packages (havsfunc, etc.)
```

### Environment Variables (Windows)

The worker sets these via `DependencyLocator`:
- `PYTHONHOME` → `deps/windows-x64/vapoursynth`
- `PYTHONPATH` → `deps/windows-x64/vapoursynth/Lib/site-packages`
- `VAPOURSYNTH_PLUGIN_PATH` → `deps/windows-x64/vapoursynth/vs-plugins`
- `PATH` → prepend vapoursynth and ffmpeg directories

### Required Plugins (Windows)

All plugins go in `deps/windows-x64/vapoursynth/vs-plugins/`:
- `libmvtools.dll` - Motion estimation
- `EEDI3m.dll` - Edge-directed interpolation
- `libvs_znedi3.dll` + `nnedi3_weights.bin` - Neural network interpolation
- `libfmtconv.dll` - Format conversion
- `ffms2.dll` - FFmpeg source
- `MiscFilters.dll` - Misc filters
- `DFTTest.dll` - FFT-based denoising (used by SMDegrain prefilter=3 and MCTemporalDenoise)
- `neo-f3kdb.dll` - Debanding (f3kdb)
- `CAS.dll` - Contrast Adaptive Sharpening
- `DCTFilter.dll` - DCT filtering (used by Deblock_QED)
- `Deblock.dll` - Deblocking (used by Deblock_QED and simple deblock)
- `libawarpsharp2.dll` - Edge warping (used by YAHR dehalo)
- `RemoveGrainVS.dll` - Grain removal/repair (used by YAHR dehalo)
- `CTMF.dll` - Constant Time Median Filter (used by YAHR dehalo)
- `fft3dfilter.dll` - FFT-based denoising (used by QTGMC Very Slow/Slower presets)

### Required Libraries (Windows)

These go in `deps/windows-x64/vapoursynth/`:
- `libfftw3f-3.dll` - FFTW library (required by DFTTest)

### Show in Folder (Windows)

Uses `cmd /c explorer /select, <path>` to open File Explorer with the file selected.

## Packaging / Deployment

### Scripts

| Script | Purpose |
|--------|---------|
| `Scripts/download-deps-windows.ps1` | Download all Windows dependencies |
| `Scripts/download-deps-macos.sh` | Download all macOS dependencies |
| `Scripts/package-windows.ps1` | Create standalone Windows zip |
| `Scripts/package-macos.sh` | Create standalone macOS .app bundle |

### Windows Packaging

```powershell
.\Scripts\package-windows.ps1 -Version "1.0.0" [-SkipBuild]
```

Creates `dist/VapourBox-1.0.0-windows-x64.zip` containing:
```
VapourBox-1.0.0-windows-x64/
├── vapourbox.exe              # Flutter app
├── vapourbox-worker.exe       # Rust worker
├── *.dll                         # Flutter runtime DLLs
├── data/                         # Flutter assets
├── templates/
│   └── qtgmc_template.vpy
├── deps/
│   ├── vapoursynth/
│   │   ├── VSPipe.exe
│   │   ├── vs-plugins/           # VapourSynth plugins
│   │   └── Lib/site-packages/    # Python packages
│   └── ffmpeg/
│       └── ffmpeg.exe
├── Launch VapourBox.bat
└── README.txt
```

### macOS Packaging

```bash
./Scripts/package-macos.sh --version 1.0.0 [--arch arm64|x64] [--skip-build]
```

Creates `dist/VapourBox.app` and `dist/VapourBox-1.0.0-macos-arm64.zip` containing:
```
VapourBox.app/Contents/
├── MacOS/
│   └── vapourbox             # Flutter app
├── Helpers/
│   ├── vapourbox-worker      # Rust worker
│   ├── vspipe                   # VapourSynth (wrapper script)
│   ├── vspipe-bin               # VapourSynth (actual binary)
│   ├── ffmpeg
│   └── ffprobe
├── Frameworks/
│   ├── Python.framework/        # Python runtime
│   ├── VapourSynth/             # VS plugins (.dylib)
│   ├── libvapoursynth.dylib
│   └── libvapoursynth-script.dylib
├── Resources/
│   ├── Templates/
│   │   └── qtgmc_template.vpy
│   ├── PythonPackages/          # havsfunc, mvsfunc
│   └── NNEDI3/
│       └── nnedi3_weights.bin
└── Info.plist
```

### Build Flags

- `--skip-build` / `-SkipBuild`: Skip Flutter and Rust compilation (use existing builds)
- `--version` / `-Version`: Set version number in package name and Info.plist
- `--arch`: (macOS only) Target architecture: `arm64` or `x64`
