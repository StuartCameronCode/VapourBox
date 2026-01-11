# iDeinterlace - AI Assistant Guide

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

## Build Commands

```bash
# Build both targets (Debug)
xcodebuild -scheme iDeinterlace -configuration Debug build

# Build for Release
xcodebuild -scheme iDeinterlace -configuration Release build

# Build dependencies (requires Homebrew, Python)
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
