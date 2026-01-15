# VapourBox

Cross-platform video restoration and cleanup application powered by VapourSynth. Provides a simple drag-and-drop interface for restoring analog and interlaced media captures.

## Supported Platforms

- **macOS** (Apple Silicon and Intel)
- **Windows 10/11** (x64)

## Features

- **Simple drag-and-drop interface** - Just drop your video file and go
- **Multi-pass restoration pipeline** - Deinterlace, denoise, dehalo, deblock, deband, sharpen, color correction
- **Full QTGMC configuration** - Access all 70+ QTGMC parameters
- **Real-time preview** - Side-by-side before/after comparison with live updates
- **Zoomable timeline** - Mouse wheel zoom centered on cursor, visual drag panning
- **In/Out point markers** - Export only a portion of your video
- **Preset system** - Save and load filter configurations for reuse
- **Custom filters** - Add your own VapourSynth filters via JSON schema
- **Real-time progress** - Current FPS, estimated time remaining, detailed logs
- **Standalone application** - All dependencies bundled
- **Multiple output formats** - H.264, H.265, and ProRes encoding
- **Auto field detection** - Automatically detects TFF/BFF with manual override

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      VapourBox                               │
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
├── scripts/                # Build and setup scripts
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
git clone https://github.com/stuartcameron/VapourBox.git
cd VapourBox
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
1. Launch VapourBox
2. Drag and drop a video file onto the drop zone
3. Choose an output location (defaults to same folder with "_restored" suffix)
4. Configure restoration passes as needed
5. Click **Go** to start processing

### Timeline Navigation
- **Click** on thumbnails to jump to that position
- **Drag** thumbnails to scrub through video
- **Mouse wheel** to zoom in/out (centers on cursor position)
- **Drag when zoomed** to pan left/right with visual feedback
- **Minimap** below thumbnails shows current view position

### In/Out Point Markers
- Click **Set In** to mark the start of export range
- Click **Set Out** to mark the end of export range
- Markers appear on the minimap with dimmed regions outside
- Export will only process frames within the marked range
- Click **Clear** (X button) to remove markers and export full video

### Presets
- Click the **tuning icon** (🎛) in the toolbar
- **Built-in presets**: Fast, Balanced, High Quality, VHS Restoration
- **Save current settings**: Save your configuration for reuse
- **User presets** stored in `~/.vapourbox/presets/`

### Configuration
Click **Settings** to access advanced parameters:

- **Preset**: Quick quality/speed selection (Placebo to Draft)
- **Input/Output**: Field order (TFF/BFF), frame rate options
- **Quality**: Temporal smoothing radius and repair settings
- **Interpolation**: Edge interpolation method (NNEDI3, EEDI3, etc.)
- **Motion Analysis**: Block size, search parameters
- **Sharpening**: Output sharpening controls
- **Noise Processing**: Denoising and grain handling
- **Source Matching**: Higher fidelity source matching options
- **Encoding**: Output codec, quality, and audio settings

## Adding Custom Filters

VapourBox supports user-defined filters via JSON schema files. Place your filter JSON files in `~/.vapourbox/filters/` and they will appear in the filter list.

See the **Custom Filters Guide** section below for detailed documentation.

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

## Packaging / Deployment

### Windows

Create a standalone zip file with all dependencies:

```powershell
# First, ensure dependencies are downloaded
.\Scripts\download-deps-windows.ps1

# Package the application
.\Scripts\package-windows.ps1 -Version "1.0.0"
```

Output: `dist/VapourBox-1.0.0-windows-x64.zip`

### macOS

Create a standalone .app bundle with all dependencies:

```bash
# First, ensure dependencies are downloaded
./Scripts/download-deps-macos.sh

# Package the application
./Scripts/package-macos.sh --version 1.0.0
```

Output: `dist/VapourBox.app` and `dist/VapourBox-1.0.0-macos-arm64.zip`

### Package Contents

The packaged application includes:
- Flutter application executable
- Rust worker executable
- VapourSynth (vspipe) and plugins
- FFmpeg
- Python runtime and packages (havsfunc, mvsfunc)
- QTGMC script templates
- License files (GPL, LGPL, NOTICES)

---

## Custom Filters Guide

VapourBox uses a JSON schema system to define filters. This allows you to add new VapourSynth filters without modifying the application code.

### Filter Location

- **Built-in filters**: `app/assets/filters/core/`
- **User filters**: `~/.vapourbox/filters/` (created on first run)

### Filter Schema Structure

```json
{
  "$schema": "https://vapourbox.app/schemas/filter-v1.json",
  "id": "my_filter",
  "version": "1.0.0",
  "name": "My Filter",
  "description": "What this filter does",
  "category": "enhancement",
  "icon": "auto_fix_high",
  "order": 100,

  "dependencies": {
    "plugins": ["havsfunc"],
    "vs_plugins": ["MyPlugin.dll"]
  },

  "methods": [
    {
      "id": "method_a",
      "name": "Method A",
      "description": "First algorithm",
      "function": "haf.SomeFunction",
      "parameters": ["param1", "param2"]
    }
  ],

  "parameters": {
    "enabled": {
      "type": "boolean",
      "default": false,
      "ui": { "hidden": true }
    },
    "method": {
      "type": "enum",
      "default": "method_a",
      "options": ["method_a"],
      "ui": { "hidden": true }
    },
    "param1": {
      "type": "number",
      "default": 1.0,
      "min": 0.0,
      "max": 10.0,
      "step": 0.1,
      "optional": true,
      "vapoursynth": { "name": "strength" },
      "ui": {
        "label": "Strength",
        "description": "Processing strength",
        "widget": "slider",
        "precision": 1
      }
    }
  },

  "ui": {
    "sections": [
      {
        "title": "Settings",
        "parameters": ["param1", "param2"],
        "expanded": true
      }
    ]
  }
}
```

### Schema Reference

#### Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique identifier (lowercase, underscores) |
| `version` | string | Yes | Semantic version (e.g., "1.0.0") |
| `name` | string | Yes | Display name in UI |
| `description` | string | Yes | Brief description |
| `category` | string | Yes | Category: `restoration`, `enhancement`, `color`, `custom` |
| `icon` | string | No | Material icon name |
| `order` | integer | No | Sort order in filter list |
| `dependencies` | object | No | Required plugins |
| `methods` | array | Yes | Available processing methods |
| `parameters` | object | Yes | Parameter definitions |
| `ui` | object | No | UI layout configuration |

#### Parameter Types

| Type | Description | Additional Fields |
|------|-------------|-------------------|
| `boolean` | True/false toggle | - |
| `integer` | Whole number | `min`, `max`, `step` |
| `number` | Decimal number | `min`, `max`, `step` |
| `string` | Text input | - |
| `enum` | Selection from options | `options` (array) |

#### Parameter Fields

```json
{
  "type": "number",
  "default": 1.0,
  "min": 0.0,
  "max": 10.0,
  "step": 0.1,
  "optional": true,
  "vapoursynth": { "name": "vs_param_name" },
  "ui": {
    "label": "Display Name",
    "description": "Tooltip text",
    "widget": "slider",
    "precision": 2,
    "hidden": false,
    "visibleWhen": { "method": ["method_a"] },
    "booleanLabels": { "true": "Yes", "false": "No" }
  }
}
```

#### Optional Parameters

When `"optional": true` is set, the parameter:
- Shows a checkbox to enable/disable the parameter
- When disabled, the parameter is not passed to VapourSynth (uses VS default)
- When enabled, the user-specified value is used

This is useful for parameters where you want the user to choose whether to override the VapourSynth default.

#### Conditional Visibility

Use `visibleWhen` to show parameters only when certain conditions are met:

```json
"visibleWhen": { "method": ["method_a", "method_b"] }
```

The parameter is visible when the `method` parameter equals any of the listed values.

#### Widget Types

| Widget | Best For |
|--------|----------|
| `slider` | Numeric values with min/max range |
| `dropdown` | Enum selections |
| `checkbox` | Boolean values |
| `textfield` | Free-form text |
| `number` | Numeric input without slider |

### Example: Simple Sharpening Filter

```json
{
  "$schema": "https://vapourbox.app/schemas/filter-v1.json",
  "id": "simple_sharpen",
  "version": "1.0.0",
  "name": "Simple Sharpen",
  "description": "Basic unsharp mask sharpening",
  "category": "enhancement",
  "icon": "blur_on",
  "order": 50,

  "dependencies": {
    "plugins": [],
    "vs_plugins": []
  },

  "methods": [
    {
      "id": "unsharp",
      "name": "Unsharp Mask",
      "description": "Standard unsharp mask",
      "function": "core.std.MakeDiff",
      "parameters": ["strength"]
    }
  ],

  "parameters": {
    "enabled": {
      "type": "boolean",
      "default": false,
      "ui": { "hidden": true }
    },
    "method": {
      "type": "enum",
      "default": "unsharp",
      "options": ["unsharp"],
      "ui": { "hidden": true }
    },
    "strength": {
      "type": "number",
      "default": 0.5,
      "min": 0.0,
      "max": 2.0,
      "step": 0.1,
      "vapoursynth": { "name": "strength" },
      "ui": {
        "label": "Strength",
        "description": "Sharpening intensity",
        "widget": "slider",
        "precision": 1
      }
    }
  },

  "ui": {
    "sections": [
      {
        "title": "Settings",
        "parameters": ["strength"],
        "expanded": true
      }
    ]
  }
}
```

### Testing Custom Filters

1. Create your JSON file in `~/.vapourbox/filters/`
2. Restart VapourBox (or it will auto-detect on next launch)
3. Your filter appears in the filter list
4. Enable it and configure parameters
5. Check the preview to verify it works

---

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

This program is free software: you can redistribute it and/or modify it under the terms of the [GNU General Public License](LICENSE) as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

See the [licenses/](licenses/) directory for full license texts and third-party component attributions.

## Author

Stuart Cameron - [stuart-cameron.com](https://stuart-cameron.com)

## Acknowledgments

- **QTGMC** by Vit - The deinterlacing algorithm
- **VapourSynth** by Fredrik Mellbin - Video processing framework
- **havsfunc** by HolyWu - QTGMC VapourSynth port
- **FFmpeg** project - Video encoding
- **Hybrid** by Selur - Inspiration for this project
