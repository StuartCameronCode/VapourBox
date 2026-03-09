# Building VapourBox from Source

## Prerequisites

### All Platforms
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (3.16+)
- [Rust](https://rustup.rs/) (1.70+)

### Windows
- Visual Studio Build Tools with C++ workload
- 7-Zip (for extracting dependencies)

### macOS
- Xcode Command Line Tools

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      VapourBox                              │
├─────────────────────────────────────────────────────────────┤
│  Flutter App (UI)           │  Rust Worker (CLI)            │
│  - Cross-platform GUI       │  - Receives job config JSON   │
│  - Settings management      │  - Generates .vpy script      │
│  - Process coordination     │  - Runs: vspipe | ffmpeg      │
│  - Progress display         │  - Reports progress (stdout)  │
└─────────────────────────────────────────────────────────────┘
```

## Project Structure

```
VapourBox/
├── app/                    # Flutter application (Dart)
│   ├── lib/
│   │   ├── models/         # Data models (VideoJob, FilterSchema, Presets)
│   │   ├── viewmodels/     # State management
│   │   ├── views/          # UI components
│   │   ├── services/       # WorkerManager, PresetService, FilterLoader
│   │   └── widgets/        # Reusable UI widgets
│   ├── assets/filters/     # Built-in filter schemas (JSON)
│   ├── macos/              # macOS platform config
│   └── windows/            # Windows platform config
│
├── worker/                 # Rust worker crate
│   ├── src/
│   │   ├── models/         # Matching data models
│   │   ├── script_generator.rs
│   │   ├── pipeline_executor.rs
│   │   └── progress_reporter.rs
│   └── templates/
│       └── pipeline_template.vpy
│
├── deps/                   # Platform-specific dependencies
│   ├── macos-arm64/
│   ├── macos-x64/
│   └── windows-x64/
│
├── licenses/               # License files (GPL, LGPL, NOTICES)
│
├── Scripts/                # Build, packaging, and release scripts
│
└── docs/                   # Additional documentation
```

## Download Dependencies

**Windows (PowerShell):**
```powershell
.\Scripts\download-deps-windows.ps1
```

**macOS:**
```bash
./Scripts/download-deps-macos.sh
```

## Development Builds

### macOS (recommended)

Use the debug script which handles the full workflow (build worker + app, copy into bundle, remove quarantine from deps, launch):

```bash
./Scripts/run-debug-macos.sh            # Full build and launch
./Scripts/run-debug-macos.sh --skip-worker  # Rebuild app only
./Scripts/run-debug-macos.sh --skip-app     # Rebuild worker only
./Scripts/run-debug-macos.sh --run-only     # Just copy and launch
```

### Windows (manual)

1. Build worker: `cd worker && cargo build`
2. Copy worker: `cp worker/target/debug/vapourbox-worker.exe app/build/windows/x64/runner/Debug/`
3. Run app: `cd app && flutter run`

## Release Builds

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

> **Note**: The macOS Flutter build may fail with "Unable to find module dependency" errors. If so, use xcodebuild directly:
> ```bash
> cd app/macos
> rm -rf Pods Podfile.lock && pod install
> xcodebuild -workspace Runner.xcworkspace -scheme Pods-Runner -configuration Release build ONLY_ACTIVE_ARCH=NO
> xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
> ```

### Generate Dart JSON Serialization

Run this after model changes:
```bash
cd app
dart run build_runner build --delete-conflicting-outputs
```

## Packaging

**Important**: Never manually assemble a release build by copying binaries into the .app bundle. Always use the packaging scripts.

### Windows
```powershell
.\Scripts\package-windows.ps1 -Version "1.0.0" [-SkipBuild]
```
Output: `dist/VapourBox-1.0.0-windows-x64.zip`

### macOS
```bash
./Scripts/package-macos.sh --version 1.0.0 [--skip-build]
```
Output: `dist/VapourBox.app` and `dist/VapourBox-1.0.0-macos-arm64.dmg`

### Testing a Packaged Build

Run from the terminal to see error output (release mode swallows exceptions silently):
```bash
dist/VapourBox.app/Contents/MacOS/vapourbox
```

## Running Tests

```bash
# Rust tests
cd worker && cargo test

# Flutter tests
cd app && flutter test
```

## Dependencies

VapourBox bundles all runtime dependencies. No external installations are required at runtime.

| Component | Version | Purpose |
|-----------|---------|---------|
| Python | 3.8 (Windows) / 3.12 (macOS) | VapourSynth runtime |
| VapourSynth | R73 | Video processing framework |
| FFmpeg | Latest | Video encoding/decoding |
| havsfunc | Latest | QTGMC implementation |
| BestSource | Latest | Frame-accurate video source |
| mvtools | v24 | Motion estimation |
| znedi3 | Latest | Neural network interpolation |
| EEDI3m | r8 | Edge-directed interpolation |
| fmtconv | r30 | Format conversion |
| neo_f3kdb | Latest | Debanding |
| DFTTest | Latest | FFT-based denoising |
| VIVTC | Latest | Inverse telecine (VFM + VDecimate) |
| whisper.cpp | Latest | Speech-to-text for subtitles |
