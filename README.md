# iDeinterlace

Cross-platform video deinterlacing application using QTGMC via VapourSynth. Provides a simple drag-and-drop interface for converting interlaced video to progressive.

## Supported Platforms

- **macOS** (Apple Silicon and Intel)
- **Windows 10/11** (x64)

## Features

- **Simple drag-and-drop interface** - Just drop your video file and go
- **Full QTGMC configuration** - Access all 70+ QTGMC parameters
- **Real-time progress** - Current FPS, estimated time remaining, detailed logs
- **Standalone application** - All dependencies bundled
- **Multiple output formats** - H.264, H.265, and ProRes encoding
- **Auto field detection** - Automatically detects TFF/BFF with manual override

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    iDeinterlace                              │
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
iDeinterlace/
├── app/                    # Flutter application (Dart)
│   ├── lib/
│   │   ├── models/         # Data models (VideoJob, QTGMCParameters)
│   │   ├── viewmodels/     # State management
│   │   ├── views/          # UI components
│   │   └── services/       # WorkerManager, FieldOrderDetector
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
│       └── qtgmc_template.vpy
│
├── deps/                   # Platform-specific dependencies
│   ├── macos-arm64/
│   ├── macos-x64/
│   └── windows-x64/
│
├── scripts/                # Build and setup scripts
│
├── legacy/                 # Original Swift code (reference)
│
└── packaging/              # Platform installers
```

## Prerequisites

### All Platforms
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (3.16+)
- [Rust](https://rustup.rs/) (1.70+)

### Windows
- Visual Studio Build Tools with C++ workload
- 7-Zip (for extracting dependencies)

### macOS
- Xcode Command Line Tools
- Homebrew

## Quick Start

### 1. Clone the repository
```bash
git clone https://github.com/yourusername/iDeinterlace.git
cd iDeinterlace
```

### 2. Download dependencies

**Windows (PowerShell):**
```powershell
.\scripts\download-deps-windows.ps1
```

**macOS:**
```bash
./scripts/download-deps-macos.sh
```

### 3. Build the Rust worker
```bash
cd worker
cargo build --release
```

### 4. Build the Flutter app

**Windows:**
```bash
cd app
flutter build windows --release
```

**macOS:**
```bash
cd app
flutter build macos --release
```

## Usage

### Basic Workflow
1. Launch iDeinterlace
2. Drag and drop an interlaced video file onto the drop zone
3. Choose an output location (defaults to same folder with "_deinterlaced" suffix)
4. Click **Go** to start processing

### Configuration
Click **Settings** to access QTGMC parameters:

- **Preset**: Quick quality/speed selection (Placebo to Draft)
- **Input/Output**: Field order (TFF/BFF), frame rate options
- **Quality**: Temporal smoothing radius and repair settings
- **Interpolation**: Edge interpolation method (NNEDI3, EEDI3, etc.)
- **Motion Analysis**: Block size, search parameters
- **Sharpening**: Output sharpening controls
- **Noise Processing**: Denoising and grain handling
- **Source Matching**: Higher fidelity source matching options
- **Encoding**: Output codec, quality, and audio settings

## Development

### Running in development mode
```bash
# Run Flutter app
cd app
flutter run -d windows  # or -d macos
```

### Running tests
```bash
# Rust tests
cd worker
cargo test

# Flutter tests
cd app
flutter test
```

## Dependencies

| Component | Version | Purpose |
|-----------|---------|---------|
| Python | 3.8 (Windows) / 3.11+ (macOS) | VapourSynth runtime |
| VapourSynth | R73 | Video processing framework |
| FFmpeg | Latest | Video encoding |
| mvtools | v24 | Motion estimation |
| znedi3 | Latest | Neural network interpolation |
| EEDI3m | r8 | Edge-directed interpolation |
| fmtconv | r30 | Format conversion |
| ffms2 | 2.40 | FFmpeg source |
| havsfunc | Latest | QTGMC implementation |
| MiscFilters | Latest | Misc VapourSynth filters |

## License

[MIT License](LICENSE)

## Acknowledgments

- **QTGMC** by Vit - The deinterlacing algorithm
- **VapourSynth** by Fredrik Mellbin - Video processing framework
- **havsfunc** by HolyWu - QTGMC VapourSynth port
- **FFmpeg** project - Video encoding
- **Hybrid** by Selur - Inspiration for this project
