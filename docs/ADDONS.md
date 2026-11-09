# Add-ons

Anything VapourBox can use but does not ship in the app or the deps bundle is
an **add-on**: an optional download the user asks for, from Settings → Add-ons
or from the prompt a feature raises when it needs one (`AddonPrompt.ensure`).
**Every AI model is an add-on, never part of the deps bundle** — a model's
size or licence should never be a cost to users who don't use it, and the deps
bundle must stay freely redistributable.

There are three kinds of installer behind `AddonService`:

| Add-on | Installer | Described by |
|---|---|---|
| Whisper engine + models | `WhisperAddonManager` (hand-written) | `app/assets/whisper-addon.json` |
| AnimeJaNai models | `AnimeJanaiInstaller` (hand-written) | `app/assets/animejanai-addon.json` |
| **Everything new** | `ManifestAddonInstaller` (generic) | `app/assets/addons/<id>.json` |

New add-ons are **manifest add-ons**. This file documents them.

## The manifest

One JSON file per add-on, `app/assets/addons/<id>.json`, named after its id.
The app finds every file in that directory through the asset manifest
(`assets/addons/` is registered in `pubspec.yaml`), and the worker compiles the
same files in (`worker/build.rs` → `worker/src/addons.rs`), so there is one
source of truth for what an add-on is and what an install of it holds.

```json
{
  "id": "face-restore-gfpgan",
  "version": "1.0.0",
  "name": "GFPGAN face restoration model",
  "feature": "Face restoration",
  "description": "One or two sentences for Settings → Add-ons.",
  "licence": "Apache-2.0",
  "licenceUrl": "https://github.com/TencentARC/GFPGAN/blob/master/LICENSE",
  "usageNote": "Free for non-commercial use only.",
  "credit": "Tencent ARC Lab",
  "noticeName": "GFPGAN model",
  "homepage": "https://github.com/TencentARC/GFPGAN",
  "components": [
    {
      "noticeName": "Some bundled part",
      "licence": "MIT",
      "licenceUrl": "https://…",
      "credit": "Its authors",
      "homepage": "https://…",
      "platforms": ["windows-x64"]
    }
  ],
  "requires": ["ai-runtime"],
  "kind": "files",
  "platforms": "all",
  "files": [
    {
      "name": "GFPGANv1.4.onnx",
      "url": "https://github.com/StuartCameronCode/VapourBox/releases/download/addon-models-v1/GFPGANv1.4.onnx",
      "size": 348632874,
      "sha256": "…64 lower-case hex…"
    },
    {
      "name": "upstream-pack.zip",
      "url": "https://example.org/releases/pack.zip",
      "size": 24674026,
      "sha256": "…",
      "platforms": ["macos-arm64", "windows-x64", "linux-x64"],
      "extract": [
        { "path": "pack/model.onnx", "name": "model.onnx", "sha256": "…" }
      ]
    }
  ]
}
```

| Field | |
|---|---|
| `id` | lower-case-with-dashes; the directory it installs to (`addons/<id>/`) and the id features ask for. Must not collide with the hand-written ids (`whisper`, `whisper-model-*`, `animejanai`). |
| `version` | the add-on's own version. **Bump it whenever its files change**: an install of another version counts as missing (the app offers it again and the install replaces it; the worker refuses with "out of date"). |
| `name`, `feature`, `description` | what Settings → Add-ons shows; `feature` groups the list. |
| `licence`, `licenceUrl`, `credit`, `noticeName`, `homepage` | the main component's credit (see "Credits" below). |
| `usageNote` | required exactly when the licence is non-commercial (`NC`), and shown bold wherever the add-on is offered. |
| `components` | further components credited separately, each optionally limited to `platforms`. |
| `requires` | add-on ids installed first, and removed with this one's dependants. A model run through ONNX Runtime requires `ai-runtime`; one run by a bundled ncnn plugin (VSNCNN for the Crop & Resize upscalers, `upscale-*.json`; RIFE for `frame-rate-rife.json`) requires nothing, and lists only the platforms that plugin ships on. |
| `kind` | `files` — a model pack: each file is saved as `addons/<id>/<name>`, or for an entry with `extract`, only the listed members are kept (each checked against its own hash; nothing else in the archive is written). `python` — every file is a wheel, unpacked into `addons/<id>/site-packages/` as pip lays it out (`*.data/purelib`/`platlib` at the top, other `.data` dropped). |
| `python` | for a python add-on, the wheel tag it targets (`cp312`: the deps bundle's Python on every platform). |
| `platforms` | `"all"`, or a table of the deps platform ids (`macos-arm64`, `macos-x64`, `windows-x64`, `linux-x64`, `linux-arm64`) it supports, each with optional `minOs` (macOS only, checked at run time against the running system). Anything else gets an `unavailableReason` and cannot be installed. |
| `files[]` | `name` (a plain file name, or a relative path of plain names joined by `/` — see below), `url` (https), `size` (bytes), `sha256`; optional `platforms` (default: every supported platform), `extract` (members: `path` in the archive, `name` to install as, default its basename, and `sha256`) and `executable` (see below). Every supported platform must have at least one file. |

`AddonManifest.fromJson` validates all of this, so a malformed manifest fails
`manifest_addon_test.dart` rather than half-working.

### Programs: `executable`

A plain file (not an archive entry, not in a `python` add-on) marked
`"executable": true` is a program the worker runs — DeepFilterNet's
`deep-filter` (`app/assets/addons/deepfilternet.json`) is the first. On install
the app sets its executable bit (downloads have none) and, on macOS, signs it
ad hoc when `codesign --verify` fails: Apple Silicon refuses to run an unsigned
arm64 binary, and upstream builds are often unsigned (DeepFilterNet's Intel one
is; its arm64 one is linker-signed and left alone). Quarantine is cleared with
the rest of the install. Each platform's program can keep upstream's own file
name: the worker finds it with `addons::Manifest::executable_for(platform)`.

### Subdirectories: a path in `name`

A file's `name` (or an archive member's) may be a relative path such as
`rife-v4.26_ensembleFalse/flownet.param`: every `/`-separated part must be a
plain name, so nothing can land outside the add-on's directory. It exists for
a plugin that reads meaning from its model's directory name — the RIFE plugin
takes the model's version, and with it the padding it runs at, from
substrings of the path it is given, so `frame-rate-rife` installs into
`addons/frame-rate-rife/rife-v4.26_ensembleFalse/`. The mirror still looks a
file up by the last segment of its URL. Prefer plain names otherwise.

### What an install looks like

```
addons/
  <id>/
    <files, extracted members, or site-packages/>
    .vapourbox-addon.json        {"id", "version", "platform"} — written last
  .downloads/<id>-<version>/     kept across a cancel so the download resumes;
                                 deleted once installed
```

An install downloads and verifies **every** file first, builds the add-on in
`addons/<id>.new`, writes the marker, then renames the old install aside and
the new one into place. A failure or cancel at any point leaves the previous
state; the app and the worker both treat a directory without a matching marker
(id, version, *platform*) as not installed.

### Testing before the files exist: the mirror

`VAPOURBOX_ADDON_MIRROR=<dir>` makes the installer take each file from
`<dir>/<last path segment of its url>` instead of downloading it — still
checked against the manifest's size and hash. A file the mirror doesn't hold
is downloaded as usual, so it can be set for a whole test run: add-ons whose
files come from upstream (the AI runtime's wheels) still install. Use it to
test an add-on whose files are converted locally and not uploaded yet. It
applies to the app and to `WorkerHarness.ensureAddon`.

## Hosting files we convert ourselves

Where upstream publishes only a PyTorch checkpoint (`.pth`), we convert it to
ONNX and host the result on this repository's releases:

```
https://github.com/StuartCameronCode/VapourBox/releases/download/addon-models-v1/<file>
```

That release is created by the project owner, not by a change.

**While a release is in development** (currently app 1.7.0), converted files
are hosted on the deps release candidate instead (`deps-v1.16.0-rc1`, a
prerelease), and the manifests point there, so CI and nightly can install
them. Before the app release they move to `addon-models-v1` and the manifests
are repointed: `Scripts/release.sh` refuses to cut a release while any
manifest downloads from an `-rc` tag, exactly as it does for
`deps-version.json`.

Before a file is uploaded anywhere, put it in `addon-staging/` at the repo
root (gitignored) and test through the mirror:

```bash
VAPOURBOX_ADDON_MIRROR=$PWD/addon-staging \
VAPOURBOX_DEPS_DIR=$PWD/deps/macos-arm64 \
  (cd app && flutter test test/integration_<feature>_test.dart)
```

### The conversion environment

A shared Python venv for converting checkpoints lives at
`addon-staging/convert-venv/` (gitignored; Python 3.14 with CPU `torch`,
`torchvision`, `onnx`, `onnxruntime`, `onnxscript`, `numpy`). Recreate it with:

```bash
python3.14 -m venv addon-staging/convert-venv
addon-staging/convert-venv/bin/pip install torch torchvision onnx onnxruntime onnxscript numpy
```

Add a model's own packages to it as needed. Every conversion is a script
committed under `Scripts/models/` (see `make_ai_runtime_selftest.py` for the
shape): it must reproduce the hosted file from the upstream checkpoint, pin the
checkpoint by URL and hash, and state the opset and IR version (keep them
loadable by the oldest ONNX Runtime the `ai-runtime` add-on pins — 1.23.2 on
Intel Macs).

## Models for the bundled ncnn plugins (RIFE, VSNCNN)

The RIFE and VSNCNN plugins are in the deps bundle; every model they run is
an add-on — RIFE's (`frame-rate-rife`, upstream's ncnn conversion fetched at
a pinned commit) and all of Crop & Resize's upscalers' (`upscale-anime`,
`upscale-general`, `upscale-esrgan-plus`, and the hand-written `animejanai`).
Until deps 1.16.0 RIFE's model and the Real-ESRGAN anime / Real-CUGAN models
were bundled; the rule now has no exceptions, and `attribution_test.dart`
fails if `Scripts/deps-expected-plugins.json` lists a model or a
`download-deps-*` script fetches one.

Their probes (`--probe-rife`, `--probe-upscale`, `worker/src/gpu_plugin.rs`)
need no add-on: each runs its plugin on a stand-in network of its own and
checks the answer, so "this computer can't run it" is told before the user
downloads anything, and a missing add-on is a separate refusal through
`required_addons()`:

- **VSNCNN**: `Tests/TestResources/ncnn_selftest.onnx` (264 bytes, one 1x1
  convolution that swaps the first and third channels and adds 0.125; built by
  `Scripts/models/make_ncnn_selftest.py`), compiled into the worker and handed
  to `ncnn.Model` as bytes (`path_is_serialization=True`).
- **RIFE**: a two-layer ncnn network with RIFE's v4 inputs and output
  (`in0`, `in1`, `in2` → `out0`, the average of the two frames, no weights),
  written beside the probe script in a directory named `rife-v4.26_selftest`.

## The worker side

`worker/src/addons.rs`:

- `addon_dir(addons_root, id)`, `site_packages(addons_root, id)` — where it is.
- `state(addons_root, id, platform)` → `Installed | Missing | Outdated | Unsupported | Unknown`,
  and `is_installed(...)`: the marker for this id, version and platform, plus
  every expected path (a model pack's files; a python add-on's `site-packages`).
- `require(addons_root, &[ids], feature, platform) -> anyhow::Result<()>` —
  refuses with a message naming the add-on(s) and Settings → Add-ons
  (`DependencyLocator::require_addons(&[ids], feature)` fills in the root and
  platform).

A pass declares what it needs in `ProcessingPipeline::required_addons()`
(`AddonNeed { feature, ids }`). `ScriptGenerator::ensure_methods_ready` refuses
the job unless all are installed, exactly as for AnimeJaNai, and emits the
`{{#AI_RUNTIME}}` block when any of them (or what they require) is
`ai-runtime`.

## The AI runtime add-on (`ai-runtime`)

ONNX Runtime and NumPy, as wheels for the deps bundle's Python 3.12, for
passes that run a model the VSNCNN plugin can't (per-crop inference, several
inputs, NumPy around the network):

| Platform | onnxruntime | Execution providers |
|---|---|---|
| macOS arm64 | 1.31.1 | Core ML, CPU |
| macOS x64 | 1.23.2 (the last Intel wheel; needs macOS 13) | Core ML, CPU |
| Windows x64 | onnxruntime-directml 1.24.4 | DirectML (any DX12 GPU), CPU |
| Linux x64 / arm64 | 1.31.1 | CPU |

plus NumPy 2.5.4. `import onnxruntime` and an `InferenceSession` need nothing
else (checked: no sympy, protobuf, flatbuffers or coloredlogs at run time,
though the wheels declare them).

### Using it from a pass

Both templates carry, near the top:

```python
{{#AI_RUNTIME}}
import ai_runtime
ai_runtime.setup({{AI_RUNTIME_DIR}})
{{/AI_RUNTIME}}
```

`ScriptGenerator` keeps it (with `{{AI_RUNTIME_DIR}}` the add-on's directory as
a Python string literal) when the job needs the runtime, and removes it
otherwise. A pass's own block then uses `templates/ai_runtime.py`:

| Call | |
|---|---|
| `setup(*addon_dirs)` | puts each add-on's `site-packages` on `sys.path` (first argument wins) and, on Windows, registers onnxruntime's DLL directory. Done by the block; never rely on `PYTHONPATH` — Windows' embeddable Python ignores it. |
| `session(model, force_cpu=False, providers=None, dims=None)` | a cached `InferenceSession` for a path or the model's bytes, on TensorRT → CUDA → DirectML → Core ML → CPU (those available), retried on the CPU if a GPU provider fails (`ai_runtime.last_fallback` says why). `dims` (`{"height": 512, "width": 512}`) fixes a model's named dynamic dimensions for the session (free-dimension overrides), so one exported file serves several input sizes and Core ML still gets static shapes (the colourisation models use it). `Runner(model, force_cpu, lock, dims)` takes the same. |
| `preferred_providers(force_cpu=False)`, `available_providers()`, `session_provider(sess)` | the provider choice. `VAPOURBOX_AI_FORCE_CPU=1` forces the CPU everywhere. |
| `frame_to_nchw(frame)` / `nchw_to_frame(array, frame)` | planar RGBS `VideoFrame` ↔ float32 `(1, 3, h, w)`. |
| `map_frames(clip, fn, width=None, height=None)` | apply `fn(nchw) -> nchw` to every frame of an RGBS clip, at an output size, keeping frame properties. |
| `to_rgbs(clip, matrix, range_)` / `from_rgbs(rgbs, fmt, matrix, range_)` | any clip ↔ planar float RGB with the source's matrix and range (zimg names), dithered on the way back — the conversion the AI upscaling block does, for a pass that works in RGB. |
| `shifted(clip, offset)` | the clip moved by `offset` frames, clamped at the ends. Pass several to `std.ModifyFrame` and a callback gets its neighbours' frames without calling `get_frame()` inside a request. |
| `FrameMemo(capacity)` | `.get(key, compute)`: a bounded cache of a pure per-frame computation, computed once even when several requests want it at the same time (several nodes reading one result, neighbours sharing a detection). |

A pass that reads neighbouring frames must stay a **pure function of its
input frames**: VapourSynth requests frames in parallel and out of order, so
nothing may depend on which frame was computed first. Take neighbours through
`shifted` clips, share work through a `FrameMemo` (losing an entry only costs
recomputing it), and declare the reach as the pass's `FrameMap` radius so the
preview decodes enough context (`worker/templates/face_restore.py` is the
worked example).

TensorRT/CUDA are hooks for a future NVIDIA add-on (its directory passed to
`setup()` before `ai-runtime`'s); today's wheels don't offer them.

### The probe

`vapourbox-worker --probe-ai-runtime` imports the runtime the way a job does,
runs the committed self-test model (`Tests/TestResources/ai_runtime_selftest.onnx`,
embedded in `ai_runtime.py`, built by `Scripts/models/make_ai_runtime_selftest.py`)
directly and through `map_frames`, and prints JSON: `available`, `reason`,
`detail`, `message` (user-facing, with a remedy), `version`, `providers`,
`provider`, `fallback`. Only a positive result is cached, per boot, add-on
version and force-CPU setting (`<deps>/ai-runtime-probe.json`). The app reads
it with `WorkerManager.probeAiRuntime()` → `AiRuntimeStatus`.

## Adding an add-on: checklist

1. **Conversion** (if upstream ships no ONNX): a script in `Scripts/models/`,
   run in the conversion venv, writing into `addon-staging/`.
2. **Manifest**: `app/assets/addons/<id>.json`, every file pinned by size and
   SHA-256, `requires: ["ai-runtime"]` for an ONNX Runtime model. Self-hosted
   files use the `addon-models-v1` URL above.
3. **Credits** — `addon_service_test.dart` ("credits agree everywhere") fails
   until all exist for the main component and each `components` entry:
   a `licenses/NOTICES.txt` entry headed `<noticeName> — <licence>` whose body
   names the credit and says it is an add-on; an About tile in
   `app/lib/views/about_dialog.dart` named `<noticeName> (optional download…)`
   with the same licence; the credit in the README's Acknowledgments. Take
   holders and licences from upstream's LICENSE, never from a handle (see
   CLAUDE.md, "Attribution"). A non-commercial licence needs `usageNote`.
4. **Worker**: the pass adds an `AddonNeed` in `ProcessingPipeline::required_addons()`
   and loads its files from `addons::addon_dir(...)`; its template block uses
   `ai_runtime` (both templates).
5. **App**: the feature calls `AddonPrompt.ensure(context, ['<id>'], reason: …)`
   when it is chosen.
6. **Tests**: a heavy integration test that calls
   `WorkerHarness.ensureAddon('<id>')` (installs it and its requirements with
   the app's own installer, so a dead URL or changed hash fails CI) and runs
   the feature. Before upload, run it with `VAPOURBOX_ADDON_MIRROR=addon-staging`.
7. **Upload** (the owner): attach the files in `addon-staging/` to the
   `addon-models-v1` release (`gh release upload addon-models-v1 <files>`;
   the release is created once with `--latest=false`, like every deps and
   whisper release, so it never takes Latest from the app). Never replace a
   file a released manifest already pins — a changed file gets a new name and
   the manifest a new `version`. Then run the test again without the mirror.
