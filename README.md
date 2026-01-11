# iDeinterlace

A macOS application for high-quality video deinterlacing using QTGMC (via VapourSynth).

iDeinterlace provides a simple, accessible interface for deinterlacing interlaced video content, producing high-quality progressive output suitable for modern displays and editing workflows.

## Features

- **Simple drag-and-drop interface** - Just drop your video file and go
- **Full QTGMC configuration** - Access all QTGMC parameters through an organized settings panel
- **Real-time progress** - See current FPS, estimated time remaining, and detailed logs
- **Standalone application** - All dependencies bundled; no external software required
- **Multiple output formats** - H.264, H.265, and ProRes encoding options
- **Auto field detection** - Automatically detects TFF/BFF with manual override option

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon or Intel Mac

## Installation

### From DMG (Direct Download)
1. Download the latest release DMG from the Releases page
2. Open the DMG and drag iDeinterlace to your Applications folder
3. On first launch, right-click the app and select "Open" to bypass Gatekeeper

### From Mac App Store
*(Coming soon)*

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

### During Processing
- **Progress bar** shows completion percentage
- **FPS** displays current processing speed
- **ETA** shows estimated time remaining
- **Cancel** button stops processing (partial output is deleted)
- **Log** section (expandable) shows detailed processing output

## Building from Source

### Prerequisites
- Xcode 15 or later
- macOS 13.0 SDK or later
- Homebrew

### Development Environment Setup

1. **Install system dependencies via Homebrew:**
   ```bash
   brew install vapoursynth ffmpeg ffms2 meson
   ln -s "../libffms2.dylib" "/opt/homebrew/lib/vapoursynth/libffms2.dylib"
   ```

2. **Install Python packages** (uses Homebrew's Python 3.14):
   ```bash
   pip3.14 install mvsfunc adjust --break-system-packages
   ```

3. **Download havsfunc r31** (last version with QTGMC):
   ```bash
   curl -L "https://github.com/HomeOfVapourSynthEvolution/havsfunc/archive/refs/tags/r31.tar.gz" | tar -xz
   cp havsfunc-r31/havsfunc.py /opt/homebrew/lib/python3.14/site-packages/
   ```

4. **Build VapourSynth plugins from source:**

   The following plugins need to be built and copied to `/opt/homebrew/lib/vapoursynth/`:
   - [mvtools](https://github.com/dubhater/vapoursynth-mvtools)
   - [NNEDI3CL](https://github.com/HomeOfVapourSynthEvolution/VapourSynth-NNEDI3CL)
   - [fmtconv](https://github.com/EleonoreMizo/fmtconv)
   - [miscfilters](https://github.com/vapoursynth/vs-miscfilters-obsolete)

   Build each with:
   ```bash
   git clone <repo-url>
   cd <repo-name>
   meson setup build
   meson compile -C build
   cp build/*.dylib /opt/homebrew/lib/vapoursynth/
   ```

5. **Install NNEDI3CL weights:**
   ```bash
   mkdir -p /opt/homebrew/share/NNEDI3CL
   curl -L "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-NNEDI3CL/raw/master/NNEDI3CL/nnedi3_weights.bin" \
     -o /opt/homebrew/share/NNEDI3CL/nnedi3_weights.bin
   ```

6. **Apply havsfunc patches** (see CLAUDE.md for details):

   The havsfunc.py file requires patches for mvtools API compatibility. Add a helper function to rename `_lambda`/`_global` parameters and update interpolation fallbacks for nnedi3cl.

7. **Verify setup:**
   ```bash
   vspipe --version
   python3.14 -c "import vapoursynth; print(str(vapoursynth.core))"
   ```

### Building Dependencies for Distribution

For bundling all dependencies in the app:

```bash
cd Scripts
./build-dependencies.sh
```

This will download and prepare all required dependencies in the `BundledDependencies/` folder.

### Building the App

1. Open `iDeinterlace.xcodeproj` in Xcode
2. Select the **iDeinterlace** scheme
3. Build and Run (Cmd+R)

### Testing with Development Environment

```bash
# Activate conda environment
conda activate ideinterlace

# Test VapourSynth setup
vspipe --version
python -c "import vapoursynth; print(vapoursynth.core.version())"

# Test with sample script
vspipe -i test_script.vpy -
```

### Code Signing for Distribution

```bash
./Scripts/codesign-dependencies.sh "Developer ID Application: Your Name (TEAMID)"
```

## Architecture

iDeinterlace uses a two-process architecture:

1. **Main App** (SwiftUI): Handles the user interface
2. **Worker Process** (CLI): Runs the VapourSynth + FFmpeg pipeline

This separation improves stability and makes sandboxing/code signing easier.

```
Main App                    Worker Process
┌─────────────┐             ┌─────────────────┐
│  SwiftUI UI │──JSON IPC──►│ vspipe | ffmpeg │
│  Settings   │◄──Progress──│ QTGMC script    │
└─────────────┘             └─────────────────┘
```

## Technology

- **QTGMC**: State-of-the-art deinterlacing algorithm using motion compensation
- **VapourSynth**: Video processing framework
- **FFmpeg**: Video encoding and muxing
- **Swift/SwiftUI**: Native macOS application framework

## License

[MIT License](LICENSE)

## Acknowledgments

- **QTGMC** by Vit - The deinterlacing algorithm
- **VapourSynth** by Fredrik Mellbin - Video processing framework
- **havsfunc** by HolyWu - QTGMC VapourSynth port
- **FFmpeg** project - Video encoding
- **Hybrid** by Selur - Inspiration for this project

## Support

For bug reports and feature requests, please open an issue on GitHub.
