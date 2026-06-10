# Handoff: Fix the macOS arm64 dependency build

**For:** a Claude Code instance running on a **macOS (Apple Silicon)** machine — you can build the deps locally, which the Linux dev box could not.

**Goal:** get `build-deps-macos.yml` (and `./Scripts/download-deps-macos.sh`) producing a complete **macOS arm64** dependency bundle again, with **all** plugins built — including the newly added `ttmpsm` (TTempSmooth) and `fft3dfilter`, which `havsfunc.MCTemporalDenoise` needs.

---

## Background / why this exists

A user hit a crash: `No attribute with the name ttmpsm` — `MCTemporalDenoise` calls `core.ttmpsm.TTempSmooth` (and `core.fft3dfilter.FFT3DFilter`), which were missing from the shipped deps. We verified by inspecting the published deps zips:

- `ttmpsm` was missing on **all** platforms.
- macOS additionally lacked **`fft3dfilter`**.

Fixes were added on branch **`fix-ttempsmooth-plugin`** (PR pending):
- **Linux** — `ttmpsm` via `build_plugin` in `download-deps-linux.sh`. ✅ Verified building in CI.
- **Windows** — `ttmpsm` prebuilt (`TTempSmooth-r4.1-win64.7z`) in `download-deps-windows.ps1`. `fft3dfilter` already present.
- **macOS** — `ttmpsm` + `fft3dfilter` added to `download-deps-macos.sh`:
  - **arm64**: downloaded as prebuilt dylibs from the `yuygfgg/Macos_vapoursynth_plugins` pool (mirrors the existing `dfttest` handling, with the FFTW `install_name_tool` repoint).
  - **x86_64**: built from source via meson (mirrors `descratch`/`nnedi3cl`). ✅ **macOS x64 CI build succeeded** — `Built TTempSmooth` and `Built FFT3DFilter`.

deps version was unified to **1.4.0** (`deps-v1.4.0`) across all platforms (`app/assets/deps-version.json`, sha256/size currently `null` pending a clean rebuild).

## The actual problem to fix

The **macОS arm64** job of `build-deps-macos.yml` **fails**, but **not** because of the TTempSmooth/FFT3DFilter additions — those run earlier (prebuilt downloads) and aren't implicated. It fails on **pre-existing** plugin builds, due to **runner environment drift**:

- The `macos-15` runner now ships **Homebrew Python 3.14**.
- `mvtools` (meson) fails:
  ```
  meson.build:14:4: ERROR: Command
  `/opt/homebrew/opt/python@3.14/bin/python3.14 -c 'import vapoursynth as vs; print(vs.get_include())'`
  failed with status 1.
  ModuleNotFoundError: No module named 'vapoursynth'
  ```
  i.e. the plugin's meson uses a runtime `import vapoursynth` to locate VS headers, and the runner's python has no `vapoursynth` module.
- `znedi3` (make) fails: `vsznedi3/vsznedi3.cpp:7:10: fatal error: 'znedi3.h' file not found`.

This is **not** caused by our change — recent `main` builds of `build-deps-macos.yml` were **also failing** (2026-06-08 had multiple failures). It's environmental and predates the branch.

### Evidence / references
- Failing run (branch `fix-ttempsmooth-plugin`): `build-deps-macos.yml` run **27208818617** — `build-x64` ✅, `build-arm64` ❌.
- The matching **Linux** run **27208815698** is fully green (so the cross-platform plugin work itself is sound).
- `gh run list --workflow build-deps-macos.yml --limit 8` shows pre-branch failures on `main`.

## Where things live
- Script: `Scripts/download-deps-macos.sh`
  - `build_plugin()` helper (clones + `eval "$build_cmd"`, copies first `*.dylib`).
  - arm64 prebuilt block (yuygfgg) — where `dfttest`/`ttmpsm`/`fft3dfilter` are pulled.
  - x86_64 source-build block — `neo-f3kdb`, `nnedi3cl`, `vivtc`, `descratch`, and now `ttmpsm`/`fft3dfilter`.
  - **Template for the fix already in the script:** the `vivtc` build patches its `meson.build` to replace the `run_command(python … vs.get_include())` probe with the VS headers path (search for `VS_INC_DIR` / the inline `python3 - vivtc/meson.build <<'PYEOF'` heredoc). `mvtools`/`znedi3` need the equivalent.
- Workflow: `.github/workflows/build-deps-macos.yml` (arm64 native on `macos-15`; `workflow_dispatch` with `version`, `release_tag`, `arch`).

## Suggested investigation / fix steps

1. **Reproduce locally** on the Apple Silicon machine:
   ```bash
   ./Scripts/download-deps-macos.sh --force
   ```
   Watch for the `mvtools` and `znedi3` failures (and note any others — the build is flaky; `nnedi3`/`bm3d` have also failed in CI).

2. **mvtools (and any meson plugin using the python VS-include probe):** make the build locate VapourSynth headers without `import vapoursynth`. Options, in order of preference:
   - Pass the built VS via pkg-config: set `PKG_CONFIG_PATH` to the VS install's `lib/pkgconfig` for the `build_plugin` meson invocations, if the plugin's `meson.build` prefers `dependency('vapoursynth')`.
   - Otherwise, **patch the plugin's `meson.build`** to hardcode the VS include dir — reuse the exact approach already used for `vivtc` in this script. Consider extending `build_plugin()` to apply this patch generically.

3. **znedi3 (`znedi3.h` not found):** ensure the build clones submodules / sees its headers. Check the znedi3 build invocation in the script (it's a `make`-based build); the header is part of the repo/submodule — confirm `--recurse-submodules` and the include path.

4. **Re-run `./Scripts/download-deps-macos.sh --force` until it completes with an empty/expected `FAILED_PLUGINS` list.** Important: `build_plugin` failures are **non-fatal** (the job can report "success" while plugins silently fail), so check the **`Failed plugins:` summary line**, not just the exit code.

5. **Verify the new plugins actually load** (and the reported bug is fixed) on arm64:
   ```python
   import vapoursynth as vs
   c = vs.core
   print(c.ttmpsm.TTempSmooth)
   print(c.fft3dfilter.FFT3DFilter)
   import havsfunc as haf
   clip = c.std.BlankClip(width=160, height=120, format=vs.YUV422P8, length=20, fpsnum=25, fpsden=1)
   haf.MCTemporalDenoise(clip, settings='medium').get_frame(5)   # must not raise
   ```
   (Run with the bundled-deps environment: `PYTHONHOME`/`PYTHONPATH`/`VAPOURSYNTH_PLUGIN_PATH`/`DYLD_LIBRARY_PATH`/`VAPOURSYNTH_CONF_PATH` per `worker/src/dependency_locator.rs` macOS branch.)

6. **Confirm the FFTW dylib path resolves at runtime for `fft3dfilter`** (the arm64 yuygfgg dylib and the x64 source build are repointed at `@loader_path/../../lib/libfftw3f.3.dylib`). The CI build only proves it *compiles*; loading `core.fft3dfilter` is the real check — do it in step 5.

7. **Run CI** to confirm:
   ```bash
   gh workflow run build-deps-macos.yml --ref fix-ttempsmooth-plugin -f version=1.4.0 -f arch=both
   ```
   Both `build-arm64` and `build-x64` should be green and ship all plugins.

## Definition of done
- `build-deps-macos.yml` green for **both** arm64 and x64 on `fix-ttempsmooth-plugin`, with no unexpected `FAILED_PLUGINS`.
- `core.ttmpsm` and `core.fft3dfilter` load on macOS arm64 and `MCTemporalDenoise` runs.
- macОS deps published at `deps-v1.4.0`; fill `app/assets/deps-version.json` → `macos-arm64`/`macos-x64` `sha256`+`size`.

## Notes / gotchas
- Don't re-add TTempSmooth/FFT3DFilter — they're already in the script; the work is unblocking the **pre-existing** `mvtools`/`znedi3` (and possibly `nnedi3`/`bm3d`) builds on the current runner image.
- The same Python-3.14 `import vapoursynth` probe issue may eventually hit other meson plugins — a generic fix in `build_plugin()` is preferable to per-plugin patches.
- macОS deps build is **flaky** in general; treat a single green run as necessary-but-confirm by checking the `Failed plugins:` line.
