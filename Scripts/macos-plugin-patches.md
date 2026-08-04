# macOS ARM64 Build Patches

This document tracks patches and configuration needed to build VapourSynth and plugins on macOS ARM64 for a fully self-contained app (no Homebrew runtime dependencies).

> **`Scripts/download-deps-macos.sh` is the authority**, not this file. These are
> notes from the original arm64 bring-up, kept because the reasoning behind the
> install-name and code-signing work is not obvious from the script. Where the two
> disagree, the script wins. In particular, arm64 now takes **most plugins
> pre-built** from the `yuygfgg/Macos_vapoursynth_plugins` pool rather than
> building them, so several build patches below apply only to the x86_64 path (or
> no longer run at all).

## VapourSynth Core

VapourSynth must be built from source to:
1. Disable hardcoded system plugin paths
2. Link against embedded Python instead of Homebrew Python

### Build Configuration

```bash
# Use embedded Python (python-build-standalone)
PYTHON_VERSION="3.12.8"
PYTHON_DIR="$DEPS_DIR/python"

# Create pkg-config files for embedded Python
# (see download-deps-macos.sh for full pkg-config setup)

# Configure with no system plugin path
meson setup build \
    --prefix="$VS_INSTALL_DIR" \
    --buildtype=release \
    -Dlibdir=lib \
    -Dplugindir="" \
    -Dpython3_bin="$PYTHON_DIR/bin/python3.12"
```

### Library Path Fixes

After building, fix install names to use relative paths:

```bash
# Fix vspipe-bin
install_name_tool -change "$VS_INSTALL_DIR/lib/libvapoursynth-script.4.dylib" \
    "@executable_path/libvapoursynth-script.4.dylib" vspipe-bin

# Fix libvapoursynth-script to find libvapoursynth
install_name_tool -change "$VS_INSTALL_DIR/lib/libvapoursynth.4.dylib" \
    "@loader_path/libvapoursynth.4.dylib" libvapoursynth-script.4.dylib

# Fix Python library reference to embedded Python
install_name_tool -change "$PYTHON_DIR/lib/libpython3.12.dylib" \
    "@executable_path/../python/lib/libpython3.12.dylib" libvapoursynth-script.4.dylib

# Fix zimg reference
install_name_tool -change "/opt/homebrew/opt/zimg/lib/libzimg.2.dylib" \
    "@loader_path/libzimg.dylib" libvapoursynth.4.dylib
```

### Wrapper Script

A wrapper script (`vspipe`) sets environment variables for the self-contained setup:
- `PYTHONHOME` → embedded Python
- `VAPOURSYNTH_PLUGIN_PATH` → bundled plugins
- `PYTHONPATH` → bundled Python packages
- `DYLD_LIBRARY_PATH` → bundled libraries
- `VAPOURSYNTH_CONF_PATH` → config that disables system plugin paths

### Python Module Fix

The `vapoursynth.cpython-312-darwin.so` module also needs path fixes:

```bash
# Fix libvapoursynth reference
install_name_tool -change "@rpath/libvapoursynth.4.dylib" \
    "@loader_path/../vapoursynth/libvapoursynth.4.dylib" vapoursynth.cpython-312-darwin.so

# Fix Python library reference (python-build-standalone uses /install/lib internally)
install_name_tool -change "/install/lib/libpython3.12.dylib" \
    "@loader_path/../python/lib/libpython3.12.dylib" vapoursynth.cpython-312-darwin.so
```

### Wrapper Script (Dynamic Config)

The wrapper script generates the config dynamically to handle absolute paths:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_ROOT="$(dirname "$SCRIPT_DIR")"

export PATH="$DEPS_ROOT/python/bin:$PATH"
export PYTHONHOME="$DEPS_ROOT/python"
export VAPOURSYNTH_PLUGIN_PATH="$SCRIPT_DIR/plugins"
export PYTHONPATH="$DEPS_ROOT/python-packages:${PYTHONPATH:-}"
export DYLD_LIBRARY_PATH="$SCRIPT_DIR:$DEPS_ROOT/python/lib:${DYLD_LIBRARY_PATH:-}"

# Generate config dynamically with correct absolute path
CONF_FILE=$(mktemp)
cat > "$CONF_FILE" << EOF
UserPluginDir=$SCRIPT_DIR/plugins
AutoloadUserPluginDir=true
AutoloadSystemPluginDir=false
EOF
export VAPOURSYNTH_CONF_PATH="$CONF_FILE"

"$SCRIPT_DIR/vspipe-bin" "$@"
EXIT_CODE=$?
rm -f "$CONF_FILE"
exit $EXIT_CODE
```

### Code Signing

**CRITICAL**: All modified binaries must be re-signed after `install_name_tool` modifications. macOS will kill unsigned/invalid-signed binaries with SIGKILL (exit code 137).

```bash
# Sign all libraries and binaries
codesign -s - -f vspipe-bin
codesign -s - -f libvapoursynth.4.dylib
codesign -s - -f libvapoursynth-script.4.dylib
codesign -s - -f ../python/lib/libpython3.12.dylib
codesign -s - -f ../python-packages/vapoursynth.cpython-312-darwin.so

# Sign all plugins
for plugin in plugins/*.dylib; do
    codesign -s - -f "$plugin"
done
```

---

## Two things that bite every time

**Plugin build failures are non-fatal.** `build_plugin` appends to
`FAILED_PLUGINS` and carries on; the script prints `Failed plugins: …` at the end
(`download-deps-macos.sh:1825`) and still exits 0 with "Installation complete". So
a green run does **not** mean a complete bundle — read that summary line. The
backstop is `Scripts/deps-expected-plugins.json`: `package-deps-macos.sh` asserts
every listed plugin is present and fails there instead.

**Meson plugins that locate VapourSynth headers by running `import vapoursynth`
break on runner images with a newer Homebrew Python** (they probe the *host*
python, which has no `vapoursynth` module — seen as `ModuleNotFoundError` from
`meson.build`, e.g. mvtools on `macos-15` with Homebrew Python 3.14). `build_plugin`
now rewrites that probe generically with the real VS include dir (`VS_INC_DIR`,
`download-deps-macos.sh:663`); `vivtc` has the same patch inline. If a newly added
meson plugin fails this way, it needs the same treatment.

## Plugin Build Patches

## ZNEDI3
- **Issue**: Requires git submodules (graphengine, vsxx)
- **Fix**: Clone with `--recursive` flag
- **Issue**: x86 assembly not compatible with ARM64
- **Fix**: Build with `make X86=0 X86_AVX512=0`
- **Output**: Produces `vsznedi3.so` instead of `.dylib`

## DFTTest
- **Superseded on arm64**: `libdfttest.dylib` is now fetched pre-built from the
  yuygfgg pool, with its `@rpath/libfftw3f_threads.3.dylib` reference repointed at
  `@loader_path/../../lib/`. `libfftw3f_threads.3` **is** shipped, so the
  single-threaded workaround below is no longer needed or applied.
- **Issue** (historical): Requires `fftw3f_threads` library which is not available in Homebrew's fftw package
- **Fix** (historical): Patch meson.build to remove fftw3f_threads dependency (use single-threaded fftw3f only)
- **Patched meson.build**:
```meson
project('DFTTest', 'cpp',
  default_options: ['buildtype=release', 'b_lto=true', 'cpp_std=c++17'],
  meson_version: '>=0.51.0',
  version: '7'
)

sources = ['DFTTest/DFTTest.cpp']
vapoursynth_dep = dependency('vapoursynth', version: '>=55').partial_dependency(compile_args: true, includes: true)
fftw3f_dep = dependency('fftw3f')
deps = [vapoursynth_dep, fftw3f_dep]

shared_module('dfttest', sources,
  dependencies: deps,
  install: true,
  install_dir: join_paths(vapoursynth_dep.get_variable(pkgconfig: 'libdir'), 'vapoursynth'),
  gnu_symbol_visibility: 'hidden'
)
```

## fmtconv
- **Issue**: Uses autotools, not meson
- **Fix**: Build from `build/unix` directory with `./autogen.sh && ./configure && make`
- **Output**: Library in `.libs/libfmtconv.dylib`

## NNEDI3 (CPU version)
- **Status**: **no longer skipped** — `download-deps-macos.sh` builds it via
  `build_plugin "nnedi3"`, and `libnnedi3.dylib` is in the `macos-arm64` list in
  `deps-expected-plugins.json` (arm64 only; the x64 bundle ships znedi3/nnedi3cl).
- **Issue** (historical): Uses autotools with ARM-specific flags that don't work on macOS
- **Specific error**: `clang: error: unsupported option '-mfpu=' for target 'arm64-apple-darwin25.2.0'`
- **Fix**: Patch Makefile.am to remove the `-mfpu=neon` flag for macOS

## neo-f3kdb
- **Issue**: Uses CMake, not meson
- **Fix**: Build with `cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 && cmake --build build`

## Plugins that build without patches (meson)
- MVTools
- NNEDI3CL
- EEDI3m
- MiscFilters
- RemoveGrain
- AddGrain
- CAS
- DCTFilter
- Deblock
- AWarpSharp2
- CTMF
- TCanny
- BM3D (may need patches)
- KNLMeansCL (may need patches)

## Support libraries — no longer from Homebrew

The bundle must not depend on Homebrew at runtime, so nothing is copied out of
`brew` on arm64 any more:

- **FFTW** — `libfftw3f.3` and `libfftw3f_threads.3` come pre-built from the
  yuygfgg `support/` pool on arm64, and are **built from source** (3.3.10, float)
  for x86_64 so they meet the macOS 12 deployment target.
- **FFMS2** — no longer used. Source indexing is **bestsource**
  (`libbestsource.dylib`).
- The other bundled support libs on x86_64 (zimg, libdvdread, xz, boost) are also
  built from source targeting macOS 12; see the `SRCLIB` section of
  `download-deps-macos.sh` and the x64/#39 notes in `CLAUDE.md`.
