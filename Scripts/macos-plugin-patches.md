# macOS ARM64 Build Patches

This document tracks patches and configuration needed to build VapourSynth and plugins on macOS ARM64 for a fully self-contained app (no Homebrew runtime dependencies).

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

## Plugin Build Patches

## ZNEDI3
- **Issue**: Requires git submodules (graphengine, vsxx)
- **Fix**: Clone with `--recursive` flag
- **Issue**: x86 assembly not compatible with ARM64
- **Fix**: Build with `make X86=0 X86_AVX512=0`
- **Output**: Produces `vsznedi3.so` instead of `.dylib`

## DFTTest
- **Issue**: Requires `fftw3f_threads` library which is not available in Homebrew's fftw package
- **Fix**: Patch meson.build to remove fftw3f_threads dependency (use single-threaded fftw3f only)
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
- **Issue**: Uses autotools with ARM-specific flags that don't work on macOS
- **Specific error**: `clang: error: unsupported option '-mfpu=' for target 'arm64-apple-darwin25.2.0'`
- **Status**: SKIPPED - use ZNEDI3 or NNEDI3CL instead (QTGMC prefers these anyway)
- **Alternative**: Patch Makefile.am to remove `-mfpu=neon` flag for macOS

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

## Plugins from Homebrew (pre-built ARM64)
- FFMS2 (`brew install ffms2` -> copy libffms2.dylib)
- FFTW (`brew install fftw` -> copy libfftw3f.dylib)
