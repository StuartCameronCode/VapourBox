# iDeinterlace - AI Assistant Guide

## Important: Documentation Maintenance

**Always keep both `README.md` and `CLAUDE.md` up to date when making changes to:**
- Build instructions or dependencies
- Project structure
- Development workflow
- Configuration or setup steps

Both files should stay synchronized - README.md is for humans, CLAUDE.md is for AI assistants.

## Project Overview

iDeinterlace is a macOS SwiftUI application for video deinterlacing using QTGMC via VapourSynth. It provides a simple drag-and-drop interface as an alternative to more complex tools like Hybrid.

## Architecture

### Two-Process Design

```
┌─────────────────────────────────────────────────────────────┐
│                    iDeinterlace.app                          │
├─────────────────────────────────────────────────────────────┤
│  Main Process (SwiftUI)     │  Worker Process (CLI)         │
│  - User interface           │  - Receives job config JSON   │
│  - Settings management      │  - Generates .vpy script      │
│  - Process coordination     │  - Runs: vspipe | ffmpeg      │
│  - Progress display         │  - Reports progress (stdout)  │
└─────────────────────────────────────────────────────────────┘
```

### Communication Protocol

- **Config**: JSON file path passed as CLI argument to worker
- **Progress**: JSON lines from worker stdout
- **Cancel**: SIGTERM to worker process

### JSON Message Format (Worker → App)

```json
{"type":"progress","frame":1234,"totalFrames":50000,"fps":45.2,"eta":892}
{"type":"log","level":"info","message":"Starting encoding..."}
{"type":"error","message":"Failed to load input"}
{"type":"complete","success":true}
```

## Key Directories

```
iDeinterlace/
├── iDeinterlace/           # Main SwiftUI app target
│   ├── Models/             # Data models (QTGMCParameters, VideoJob, etc.)
│   ├── Views/              # SwiftUI views
│   ├── ViewModels/         # View models (MVVM pattern)
│   └── Services/           # WorkerManager, ProgressParser, etc.
├── iDeinterlaceWorker/     # CLI worker target
│   └── Templates/          # VapourSynth script templates
├── BundledDependencies/    # Pre-built deps (gitignored)
└── Scripts/                # Build and signing scripts
```

## Key Files

| File | Purpose |
|------|---------|
| `iDeinterlace/Models/QTGMCParameters.swift` | All 70+ QTGMC parameters as Codable struct |
| `iDeinterlace/Services/WorkerManager.swift` | Spawns worker process, handles IPC via pipes |
| `iDeinterlaceWorker/PipelineExecutor.swift` | Executes vspipe \| ffmpeg pipeline |
| `iDeinterlaceWorker/Templates/qtgmc_template.vpy` | VapourSynth script template |
| `iDeinterlace/Views/Settings/SettingsView.swift` | Full QTGMC configuration UI |

## Development Environment Setup

For development and testing, use Homebrew Python 3.14 (VapourSynth is built against this version):

```bash
# 1. Install system dependencies
brew install vapoursynth ffmpeg ffms2
ln -s "../libffms2.dylib" "/opt/homebrew/lib/vapoursynth/libffms2.dylib"

# 2. Install Python packages
pip3.14 install mvsfunc adjust --break-system-packages

# 3. Download and install havsfunc r31 (last version with QTGMC)
curl -L "https://github.com/HomeOfVapourSynthEvolution/havsfunc/archive/refs/tags/r31.tar.gz" | tar -xz
cp havsfunc-r31/havsfunc.py /opt/homebrew/lib/python3.14/site-packages/

# 4. Build and install VapourSynth plugins from source:
# - mvtools: https://github.com/dubhater/vapoursynth-mvtools
# - NNEDI3CL: https://github.com/HomeOfVapourSynthEvolution/VapourSynth-NNEDI3CL
# - fmtconv: https://github.com/EleonoreMizo/fmtconv
# - miscfilters: https://github.com/vapoursynth/vs-miscfilters-obsolete
# - resize2: https://github.com/Jaded-Encoding-Thaumaturgy/vapoursynth-resize2

# Each plugin: meson setup build && meson compile -C build
# Then copy .dylib to /opt/homebrew/lib/vapoursynth/

# 5. Install NNEDI3CL weights file
mkdir -p /opt/homebrew/share/NNEDI3CL
curl -L "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-NNEDI3CL/raw/master/NNEDI3CL/nnedi3_weights.bin" \
  -o /opt/homebrew/share/NNEDI3CL/nnedi3_weights.bin

# 6. Verify setup
vspipe --version
python3.14 -c "import vapoursynth; print(str(vapoursynth.core))"
```

### havsfunc Compatibility Patches

The havsfunc.py file requires patches for current mvtools API:

1. Add helper function at top of file to rename `_lambda`/`_global` to `lambda`/`global`:
```python
def _fix_mv_args(args):
    result = {}
    for k, v in args.items():
        if k == '_lambda': result['lambda'] = v
        elif k == '_global': result['global'] = v
        else: result[k] = v
    return result
```

2. Replace `**analyse_args)` with `**_fix_mv_args(analyse_args))` globally
3. Replace `**recalculate_args)` with `**_fix_mv_args(recalculate_args))` globally
4. Replace `_global=True, overlap=overlap)` with `overlap=overlap, **{'global': True})`
5. Update NNEDI3/EEDI3 fallback to check for nnedi3cl:
   - Change `myNNEDI3 = ... else core.nnedi3.nnedi3` to include `core.nnedi3cl.NNEDI3CL` fallback
   - Make myEEDI3 assignment conditional (return None if eedi3 not available)

## Build Commands

```bash
# Activate conda environment first
conda activate ideinterlace

# Build both targets (Debug)
xcodebuild -scheme iDeinterlace -configuration Debug build

# Build for Release
xcodebuild -scheme iDeinterlace -configuration Release build

# Build dependencies for distribution (requires Homebrew, Python)
./Scripts/build-dependencies.sh

# Sign all bundled binaries
./Scripts/codesign-dependencies.sh "Developer ID Application: Name (TEAMID)"

# Run tests
xcodebuild test -scheme iDeinterlace
```

## Common Tasks

### Adding a New QTGMC Parameter

1. Add property to `QTGMCParameters.swift` struct
2. Add corresponding entry in `qtgmc_template.vpy` template
3. Add UI control in appropriate settings section view
4. Update JSON serialization tests

### Modifying Worker Communication

1. Update message types in `iDeinterlaceWorker/ProgressReporter.swift`
2. Update parsing in `iDeinterlace/Services/ProgressParser.swift`
3. Update `WorkerMessage` enum if adding new message types

### Adding a New Encoding Option

1. Add to `EncodingSettings` struct in `VideoJob.swift`
2. Update FFmpeg argument building in `PipelineExecutor.swift`
3. Add UI controls in `EncodingSectionView.swift`

## QTGMC Parameters Reference

The most important parameters to understand:

- **Preset**: Master setting (Placebo → Draft) that sets defaults for most other params
- **TFF**: Top-field-first (true) or bottom-field-first (false) - critical for correct output
- **TR0/TR1/TR2**: Temporal radius settings controlling smoothing strength
- **EdiMode**: Interpolation method (NNEDI3, EEDI3+NNEDI3, etc.)
- **SourceMatch**: Higher fidelity mode (0=off, 1-3=increasingly accurate)
- **FPSDivisor**: 1=double-rate output (50i→50p), 2=single-rate (50i→25p)

## Testing

```bash
# Unit tests
xcodebuild test -scheme iDeinterlace -only-testing:iDeinterlaceTests

# Test worker standalone (with test config)
./build/Debug/iDeinterlaceWorker --config test_job.json

# Integration test with sample video
./Scripts/integration-test.sh sample.mov
```

## Bundle Structure

```
iDeinterlace.app/Contents/
├── MacOS/
│   ├── iDeinterlace           # Main app
│   └── iDeinterlaceWorker     # Worker CLI
├── Frameworks/
│   └── Python.framework/      # Embedded Python + VapourSynth
├── PlugIns/VapourSynth/       # VS native plugins (.dylib)
├── Helpers/
│   ├── vspipe                 # VapourSynth pipe utility
│   └── ffmpeg                 # FFmpeg binary
└── Resources/
    ├── vapoursynth.conf       # VS config pointing to bundled plugins
    └── qtgmc_template.vpy     # Script template
```

## Code Style

- SwiftUI with MVVM pattern
- Async/await for concurrency
- Combine for reactive bindings
- Guard/if-let instead of force unwrapping
- Prefer editing existing files over creating new ones
- Keep implementations simple and focused

## Debugging Tips

1. **Worker crashes**: Check Console.app for crash logs, run worker standalone
2. **Plugin load failures**: Check `vapoursynth.conf` paths, verify dylib signatures
3. **Progress not updating**: Check JSON parsing in `ProgressParser.swift`
4. **Encoding fails**: Run the generated .vpy script manually with vspipe to isolate issue
