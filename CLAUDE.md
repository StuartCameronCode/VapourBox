# VapourBox - AI Assistant Guide

## Important: Documentation Maintenance

**Always keep both `README.md` and `CLAUDE.md` up to date when making changes to:**
- Build instructions or dependencies
- Project structure
- Development workflow
- Configuration or setup steps

Both files should stay synchronized - README.md is for humans, CLAUDE.md is for AI assistants.

## Project Overview

VapourBox is a **cross-platform** (macOS + Windows) video processing application using VapourSynth. It provides a simple drag-and-drop interface for deinterlacing, denoising, sharpening, and other video processing tasks as an alternative to more complex tools like Hybrid.

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
│   ├── macos/                  # macOS platform config
│   └── windows/                # Windows platform config
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
├── deps/                       # Platform-specific dependencies
│   ├── macos-arm64/            # Python 3.12, VS, FFmpeg, plugins
│   ├── macos-x64/
│   └── windows-x64/            # VSPipe, Python 3.8, FFmpeg, plugins
│
├── licenses/                   # GPL, LGPL, NOTICES
├── Scripts/                    # Build, package, and release scripts
└── .github/workflows/          # CI build workflows
```

## Key Files

### Rust Worker
| File | Purpose |
|------|---------|
| `worker/src/models/video_job.rs` | Job config, EncodingSettings, processing passes |
| `worker/src/models/qtgmc_parameters.rs` | All 70+ QTGMC parameters (serde) |
| `worker/src/script_generator.rs` | Template substitution for .vpy |
| `worker/src/pipeline_executor.rs` | vspipe \| ffmpeg execution |
| `worker/templates/pipeline_template.vpy` | VapourSynth script template |
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
| `app/assets/filters/core/*.json` | Built-in filter schema definitions |

## Build Commands

### Prerequisites
- Flutter SDK 3.16+
- Rust 1.70+
- Windows: Visual Studio Build Tools with C++ workload
- macOS: Xcode Command Line Tools

### Download Dependencies

```bash
# macOS
./scripts/download-deps-macos.sh

# Windows (PowerShell)
.\scripts\download-deps-windows.ps1
```

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
3. Run app: `cd app && flutter run`

### Production Packaging

**IMPORTANT**: Never manually assemble a release build. Always use packaging scripts — the app will silently crash on video drop if the bundle is incomplete.

```bash
# macOS
./Scripts/package-macos.sh --version X.Y.Z [--skip-build]

# Windows
.\Scripts\package-windows.ps1 -Version "X.Y.Z" [-SkipBuild]

# Test packaged app from terminal to see errors:
dist/VapourBox.app/Contents/MacOS/vapourbox
```

Do NOT run `app/build/macos/Build/Products/Release/vapourbox.app` directly — it lacks templates and proper bundle structure.

## Common Tasks

### Adding a New Filter (JSON Schema)

1. Create JSON file in `app/assets/filters/core/` (or `~/.vapourbox/filters/` for user filters)
2. Define required fields: `id`, `version`, `name`, `description`, `category`
3. Add `methods` array with at least one method
4. Add `parameters` object with `enabled` and `method` (hidden), plus filter-specific params
5. Configure `ui.sections` to organize parameters in the UI
6. For built-in filters: add to `pubspec.yaml` assets if new directory
7. **Add integration test** in `worker/tests/filter_integration_test.rs` (see below)
8. Restart app to load the filter

See existing filters in `app/assets/filters/core/` for schema reference.

### Adding a New Built-in Preset

1. Edit `app/lib/services/preset_service.dart`
2. Add new `ProcessingPreset` in `_createBuiltInPresets()`
3. Configure `pipeline` with desired filter settings, set `isBuiltIn: true`

### Adding a New QTGMC Parameter

1. Add to `worker/src/models/qtgmc_parameters.rs` (with serde attributes)
2. Add to `app/lib/models/qtgmc_parameters.dart` (with json_annotation)
3. Add to `worker/templates/pipeline_template.vpy` using `{{#PARAM}}...{{/PARAM}}` syntax
4. Add to `worker/src/script_generator.rs` substitution logic
5. Add UI control in Flutter settings view
6. **Add integration test** in `worker/tests/filter_integration_test.rs` (see below)

### Integration Tests for Filter Changes (Required)

**Every filter addition or parameter change must include an integration test** in `worker/tests/filter_integration_test.rs`. Tests are numbered sequentially (e.g., `test_50_chroma_shift`).

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

Filters are defined as JSON schemas in `app/assets/filters/core/` (built-in) or `~/.vapourbox/filters/` (user). See existing filters for full examples. Key structure:

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
**`visibleWhen`**: Conditional visibility, e.g. `{ "method": ["method_a"] }`.

### Preset System

Presets save complete filter pipeline + encoding settings. Built-in presets (Fast, Balanced, High Quality, VHS Cleanup) are in `PresetService._createBuiltInPresets()`. User presets save to `~/.vapourbox/presets/*.json`.

---

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
cd worker && cargo test

# Flutter tests
cd app && flutter test

# Test worker standalone
cd worker && cargo run --release -- --config test_job.json
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

## havsfunc Compatibility Patches

The `download-deps-windows.ps1` and `download-deps-macos.sh` scripts apply these automatically. Three patches are needed for modern VapourSynth:
1. **mvtools API**: Renamed `_lambda`→`lambda`, `_global`→`global` parameters
2. **DFTTest API**: `sstring` parameter removed, replaced with `sigma=10.0`
3. **VapourSynth YCOCG removal**: `vs.YCOCG` removed, simplify to `!= vs.YUV`

## Debugging Tips

1. **Worker crashes**: Run worker standalone with `--config` to isolate
2. **JSON mismatch**: Compare Rust and Dart model serialization
3. **Plugin load failures**: Check environment variables in `DependencyLocator`
4. **Encoding fails**: Run generated .vpy script manually with vspipe
5. **Template not found**: Check search paths in `script_generator.rs`
6. **Filter not appearing**: Check JSON syntax, verify `id` is unique
7. **macOS build fails with "Unable to find module dependency"**: Build Pods-Runner scheme first, then Runner for arm64 only (see Build Commands)
8. **App crashes silently on video drop (release build)**: Bundle is incomplete. Use packaging scripts. Run from terminal to see errors.

## Platform-Specific Notes

### Windows

- VapourSynth R73 portable uses Python 3.8 (not 3.11+)
- Worker sets env vars via `DependencyLocator`: `PYTHONHOME`, `PYTHONPATH`, `VAPOURSYNTH_PLUGIN_PATH`, `PATH`
- Plugins in `deps/windows-x64/vapoursynth/vs-plugins/`, Python packages in `Lib/site-packages/`
- Show in Folder: `cmd /c explorer /select, <path>`

### macOS

- Fully self-contained deps (no Homebrew): Python 3.12 (python-build-standalone), VS built from source
- Worker sets: `PYTHONHOME`, `PYTHONPATH`, `VAPOURSYNTH_CONF_PATH`, `DYLD_LIBRARY_PATH`
- `vspipe` is a wrapper script that generates config dynamically (needed because `VAPOURSYNTH_PLUGIN_PATH` is additive, not a replacement)
- **Code signing**: After `install_name_tool` modifications, binaries must be re-signed: `codesign -s - -f <binary>` (exit code 137 = SIGKILL means invalid signature)
- Quarantine removal: `xattr -cr` on deps after download
- Show in Folder: `open -R <path>`

Plugin lists for both platforms: see `deps/` directories or download scripts.

---

## Dependency Versioning and Auto-Download

Dependencies are versioned separately from the app via `app/assets/deps-version.json` and distributed as separate GitHub releases (tag: `deps-vX.Y.Z`). The app auto-downloads deps on launch if missing or outdated.

**Key files**: `app/assets/deps-version.json` (expected version), `app/lib/services/dependency_manager.dart` (check/download/extract), `app/lib/views/dependency_download_dialog.dart` (progress UI).

App and deps use **separate release tags** so unchanged deps aren't re-uploaded on every app release. Download URLs are constructed from `releaseTag` in `deps-version.json`.

---

## Release Process

### Quick Start (Automated)

```bash
./Scripts/release.sh [--skip-deps-check] [--skip-build] [--dry-run]
```

This prompts for version, checks deps changes, builds, packages, and creates draft GitHub releases.

### CI Build and Release

```bash
# Full flow: trigger CI builds, wait, download artifacts, upload to draft release
./Scripts/ci-build-and-release.sh --version 0.7.0 [--deps-tag deps-v1.1.0] [--arch both]

# Just download latest artifacts (skip triggering new builds)
./Scripts/ci-build-and-release.sh --version 0.7.0 --skip-trigger
```

Prerequisites: draft release must exist for the tag, `gh` CLI authenticated.

### Release Scripts

| Script | Purpose |
|--------|---------|
| `Scripts/release.sh` | Main orchestrator |
| `Scripts/ci-build-and-release.sh` | Trigger CI, download artifacts, upload to draft |
| `Scripts/get-github-version.sh` | Fetch versions from GitHub (`--app`, `--deps`, `--next-app`, `--next-deps`) |
| `Scripts/update-version.sh` | Update version across all files (`--app X.Y.Z --deps X.Y.Z --deps-tag deps-vX.Y.Z`) |
| `Scripts/check-deps-changed.sh` | Detect if deps changed since last release (exit 0=changed, 1=unchanged) |
| `Scripts/package-macos.sh` | Package macOS app |
| `Scripts/package-windows.ps1` | Package Windows app |
| `Scripts/package-deps-macos.sh` | Package macOS deps |
| `Scripts/package-deps-windows.ps1` | Package Windows deps |

### Release Checklist

1. **Confirm version** — ask user, update `pubspec.yaml`
2. **Check deps** — run `check-deps-changed.sh`; if changed, bump version in `deps-version.json`
3. **Build & package** — use packaging scripts (or `release.sh` for full automation)
4. **Test** — fresh install + upgrade test
5. **Create GitHub releases** — deps release first (if changed, tag `deps-vX.Y.Z`), then app release (tag `vX.Y.Z`)

### Cross-Platform Notes

- Flutter Windows can't build on macOS — use GitHub Actions
- Windows deps can be zipped on macOS if `deps/windows-x64/` exists
- CI builds are ad-hoc signed; sign locally for distribution

### Dependency Version History

| Deps Version | Date | Changes |
|--------------|------|---------|
| 1.0.0 | 2025-01-15 | Initial release |
