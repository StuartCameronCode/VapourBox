<#
.SYNOPSIS
    Downloads all dependencies for VapourBox on Windows x64.

.DESCRIPTION
    This script downloads and sets up:
    - VapourSynth R78 (installed as a Python wheel)
    - Python 3.12 embeddable (hosts the wheel and VSScript)
    - FFmpeg (latest GPL build)
    - VapourSynth plugins (mvtools, nnedi3cl, znedi3, eedi3m, fmtconv, miscfilters, dfttest, neo_f3kdb, cas, fft3dfilter, descratch, temporalmedian)
    - FFTW library (required by dfttest)
    - Python packages (havsfunc, mvsfunc, adjust)
    - NNEDI3 weights
    - Patches havsfunc for API compatibility (mvtools, DFTTest, YCOCG, EEDI3CL fallback)

.PARAMETER TargetDir
    The target directory for dependencies. Default: deps/windows-x64

.EXAMPLE
    .\download-deps-windows.ps1
    .\download-deps-windows.ps1 -TargetDir "C:\vapourbox\deps\windows-x64"
#>

param(
    [string]$TargetDir = "deps\windows-x64"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Speed up downloads

# Get script directory and project root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$FullTargetDir = Join-Path $ProjectRoot $TargetDir

Write-Host "=== VapourBox Windows Dependency Downloader ===" -ForegroundColor Cyan
Write-Host "Target directory: $FullTargetDir"
Write-Host ""

# Create directory structure
$Directories = @(
    "$FullTargetDir\vapoursynth\vs-plugins",
    "$FullTargetDir\vapoursynth\Lib\site-packages",
    "$FullTargetDir\ffmpeg"
)

foreach ($Dir in $Directories) {
    if (-not (Test-Path $Dir)) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        Write-Host "Created: $Dir" -ForegroundColor Gray
    }
}

# Temporary download directory
$TempDir = Join-Path $env:TEMP "vapourbox-deps"
if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
}

# VapourSynth release and the embeddable Python it is installed into.
# The wheel is cp312-abi3, so any Python >= 3.12 works; keep this in step
# with the macOS and Linux bundles.
$VSRelease = "R78"
$PythonVersion = "3.12.10"
$PythonTag = "312"

function Download-File {
    param([string]$Url, [string]$OutFile)
    Write-Host "  Downloading: $Url" -ForegroundColor Gray
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

# =============================================================================
# 1. Python 3.12 embeddable + VapourSynth R78 wheel
# =============================================================================
# R74 turned VapourSynth into a Python package and R78 ships Windows purely as
# a wheel: VapourSynth64-Portable-R78.zip contains only wheel\, vspipe.bat,
# pip.bat and docs - no VSPipe.exe, no DLLs, no Python. The wheel itself is
# self-contained (vspipe.exe, libvapoursynth.dll, libvapoursynthfilters*.dll,
# vsscript.dll, vapoursynth.pyd), so the R73 flow - portable zip first, then
# bolt Python 3.8 on the side - no longer applies.
#
# This mirrors the official Install-Portable-VapourSynth-R78.ps1: unpack an
# embeddable Python, add Lib\site-packages to its ._pth, then install the
# wheel. We expand the wheel rather than bootstrapping pip into the embeddable
# interpreter; a wheel is a zip, this one has no .data payload and no scripts,
# and expanding keeps the build deterministic and offline-friendly.
#
# Python 3.12 is the floor R74 set (the wheel is cp312-abi3, so 3.12+ all work)
# and matches the macOS and Linux bundles. Pinned rather than probing for the
# newest patch, so the bundle is reproducible.
Write-Host ""
Write-Host "[1/7] Installing Python $PythonVersion embeddable + VapourSynth $VSRelease..." -ForegroundColor Yellow

$VSDir = "$FullTargetDir\vapoursynth"
$VSPipePath = "$VSDir\Lib\site-packages\vapoursynth\vspipe.exe"

if (-not (Test-Path $VSPipePath)) {
    # --- Python embeddable ---
    $PythonZip = Join-Path $TempDir "python-embed.zip"
    $PythonUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
    Download-File -Url $PythonUrl -OutFile $PythonZip
    Expand-Archive -Path $PythonZip -DestinationPath $VSDir -Force
    Remove-Item $PythonZip -Force

    # The embeddable interpreter ignores site-packages unless its ._pth says so.
    @"
python$PythonTag.zip
.
Lib\site-packages
import site
"@ | Set-Content "$VSDir\python$PythonTag._pth"

    # --- VapourSynth wheel ---
    $VSZip = Join-Path $TempDir "vapoursynth.zip"
    $VSUrl = "https://github.com/vapoursynth/vapoursynth/releases/download/$VSRelease/VapourSynth64-Portable-$VSRelease.zip"
    Download-File -Url $VSUrl -OutFile $VSZip
    $VSTemp = Join-Path $TempDir "vs-portable"
    Expand-Archive -Path $VSZip -DestinationPath $VSTemp -Force
    Remove-Item $VSZip -Force

    $Wheel = Get-ChildItem "$VSTemp\wheel" -Filter "*.whl" | Select-Object -First 1
    if (-not $Wheel) {
        Write-Host "  ERROR: no wheel found in VapourSynth64-Portable-$VSRelease.zip" -ForegroundColor Red
        exit 1
    }
    # A wheel *is* a zip, but Expand-Archive validates the file extension and
    # rejects .whl outright ("is not a supported archive file format"), so copy
    # it to a .zip name first rather than unpacking in place.
    $WheelZip = Join-Path $TempDir "$($Wheel.BaseName).zip"
    Copy-Item $Wheel.FullName $WheelZip -Force
    Expand-Archive -Path $WheelZip -DestinationPath "$VSDir\Lib\site-packages" -Force
    Remove-Item $WheelZip -Force
    Remove-Item $VSTemp -Recurse -Force

    if (-not (Test-Path $VSPipePath)) {
        Write-Host "  ERROR: vspipe.exe missing after installing $($Wheel.Name)" -ForegroundColor Red
        exit 1
    }
    Write-Host "  VapourSynth $VSRelease installed (Python $PythonVersion)" -ForegroundColor Green
} else {
    Write-Host "  VapourSynth $VSRelease already installed" -ForegroundColor Gray
}

# =============================================================================
# 3. FFmpeg
# =============================================================================
Write-Host ""
Write-Host "[2/7] Downloading FFmpeg..." -ForegroundColor Yellow

$FFmpegZip = Join-Path $TempDir "ffmpeg.zip"
$FFmpegUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"

if (-not (Test-Path "$FullTargetDir\ffmpeg\ffmpeg.exe")) {
    Download-File -Url $FFmpegUrl -OutFile $FFmpegZip

    # Extract to temp, then copy just the binaries
    $FFmpegTempDir = Join-Path $TempDir "ffmpeg-extract"
    Expand-Archive -Path $FFmpegZip -DestinationPath $FFmpegTempDir -Force

    # Find the bin directory
    $BinDir = Get-ChildItem -Path $FFmpegTempDir -Recurse -Directory -Filter "bin" | Select-Object -First 1
    if ($BinDir) {
        Copy-Item "$($BinDir.FullName)\ffmpeg.exe" "$FullTargetDir\ffmpeg\" -Force
        Copy-Item "$($BinDir.FullName)\ffprobe.exe" "$FullTargetDir\ffmpeg\" -Force -ErrorAction SilentlyContinue
    }

    Remove-Item $FFmpegZip -Force
    Remove-Item $FFmpegTempDir -Recurse -Force
    Write-Host "  FFmpeg installed" -ForegroundColor Green
} else {
    Write-Host "  FFmpeg already installed" -ForegroundColor Gray
}

# =============================================================================
# 4. VapourSynth Plugins (via 7z)
# =============================================================================
Write-Host ""
Write-Host "[3/7] Downloading VapourSynth plugins..." -ForegroundColor Yellow

# Check for 7-Zip
$7zPath = "C:\Program Files\7-Zip\7z.exe"
$Has7z = Test-Path $7zPath

$PluginsDir = "$FullTargetDir\vapoursynth\vs-plugins"

# Plugins that require 7z extraction
$Plugins7z = @(
    @{
        Name = "mvtools"
        Url = "https://github.com/dubhater/vapoursynth-mvtools/releases/download/v24/vapoursynth-mvtools-v24-win64.7z"
        Check = "libmvtools.dll"
    },
    @{
        Name = "nnedi3cl"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-NNEDI3CL/releases/download/r8/NNEDI3CL-r8.7z"
        Check = "NNEDI3CL.dll"
    },
    @{
        Name = "znedi3"
        Url = "https://github.com/sekrit-twc/znedi3/releases/download/r2.1/znedi3_r2.1.7z"
        Check = "vsznedi3.dll"
    },
    @{
        Name = "eedi3m"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-EEDI3/releases/download/r8/EEDI3-r8.7z"
        Check = "EEDI3m.dll"
    },
    @{
        Name = "miscfilters"
        Url = "https://github.com/vapoursynth/vs-miscfilters-obsolete/releases/download/R2/miscfilters-r2.7z"
        Check = "MiscFilters.dll"
    },
    @{
        Name = "dfttest"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DFTTest/releases/download/r7/DFTTest-r7.7z"
        Check = "DFTTest.dll"
    },
    @{
        # core.ttmpsm.TTempSmooth - used by havsfunc MCTemporalDenoise
        Name = "ttempsmooth"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-TTempSmooth/releases/download/r4.1/TTempSmooth-r4.1-win64.7z"
        Check = "TTempSmooth.dll"
    },
    @{
        Name = "neo_f3kdb"
        Url = "https://github.com/HomeOfAviSynthPlusEvolution/neo_f3kdb/releases/download/r10/neo_f3kdb_r10.7z"
        Check = "neo-f3kdb.dll"
    },
    @{
        Name = "cas"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CAS/releases/download/r2/CAS-r2.7z"
        Check = "CAS.dll"
    },
    @{
        Name = "dctfilter"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DCTFilter/releases/download/r2/DctFilter-r2.7z"
        Check = "DCTFilter.dll"
    },
    @{
        Name = "deblock"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-Deblock/releases/download/r6/Deblock-r6.7z"
        Check = "Deblock.dll"
    },
    @{
        Name = "awarpsharp2"
        Url = "https://github.com/dubhater/vapoursynth-awarpsharp2/releases/download/v4/vapoursynth-awarpsharp2-v4-win64.7z"
        Check = "libawarpsharp2.dll"
    },
    @{
        # FluxSmooth (core.flux.SmoothT / SmoothST), and what havsfunc's STPresso
        # calls internally. Pinned to v2 on every platform: this is the newest
        # tag with a published Windows binary, and Windows has no from-source
        # build path here, so macOS/Linux track the version Windows can get
        # rather than letting the same job denoise differently per OS.
        Name = "fluxsmooth"
        Url = "https://github.com/dubhater/vapoursynth-fluxsmooth/releases/download/v2/vapoursynth-fluxsmooth-v2-win64.7z"
        Check = "libfluxsmooth.dll"
    },
    @{
        Name = "removegrain"
        Url = "https://github.com/vapoursynth/vs-removegrain/releases/download/R1/removegrain-r1.7z"
        Check = "RemoveGrainVS.dll"
    },
    @{
        Name = "ctmf"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CTMF/releases/download/r5/CTMF-r5.7z"
        Check = "CTMF.dll"
    },
    @{
        Name = "fft3dfilter"
        Url = "https://github.com/myrsloik/VapourSynth-FFT3DFilter/releases/download/R2/FFT3DFilter-r2.7z"
        Check = "fft3dfilter.dll"
    },
    @{
        Name = "addgrain"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-AddGrain/releases/download/r10/AddGrain-r10-win64.7z"
        Check = "AddGrain.dll"
    },
    @{
        Name = "tcanny"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-TCanny/releases/download/r14/TCanny-r14-win64.7z"
        Check = "TCanny.dll"
    },
    @{
        Name = "vivtc"
        Url = "https://github.com/vapoursynth/vivtc/releases/download/R1/VIVTC-R1.7z"
        Check = "VIVTC.dll"
    },
    @{
        # core.descratch.DeScratch - vertical scratch removal (pipeline Pass 3).
        # Same upstream repo macOS builds from; R3 is the latest tag with a win64 asset.
        Name = "descratch"
        Url = "https://github.com/vapoursynth/descratch/releases/download/R3/descratch-r3.7z"
        Check = "DeScratch.dll"
    },
    @{
        # core.tmedian.TemporalMedian - used by the SpotLess filter (spotless.py).
        Name = "temporalmedian"
        Url = "https://github.com/dubhater/vapoursynth-temporalmedian/releases/download/v1/vapoursynth-temporalmedian-v1-win64.7z"
        Check = "libtemporalmedian.dll"
    }
)

# Plugins with zip format. NOTE: fmtconv-r31.zip ships BOTH win32/fmtconv.dll and
# win64/fmtconv.dll under arch subfolders, so the copy loop below must pick win64
# (copying both would let win32 clobber the 64-bit DLL depending on file order).
#
# fmtconv upstream moved from GitHub to GitLab in Aug 2023 and no longer publishes
# GitHub release assets, so r31 comes from the author's site - that is the asset the
# official GitLab release for r31 links to. Keep this version in step with
# FMTCONV_TAG in download-deps-{macos,linux}.sh: r31 changed interlaced PAL-DV
# chroma placement, so a version skew between platforms would make the same job
# produce different chroma on Windows than on macOS/Linux. If this URL ever dies,
# deps-expected-plugins.json makes it a red build rather than a silent gap.
$PluginsZip = @(
    @{
        Name = "fmtconv"
        Url = "https://ldesoras.fr/src/vs/fmtconv-r31.zip"
        Check = "fmtconv.dll"
    },
    @{
        # core.knlm.KNLMeansCL - OpenCL denoiser used by QTGMC when its Denoiser
        # is set to "knlmeanscl". The release zip ships a 32-bit DLL at the root
        # AND x64\KNLMeansCL.dll; the $Win64 filter below picks the x64 one (and
        # the PE-arch verifier rejects the 32-bit one if it ever slipped through).
        Name = "knlmeanscl"
        Url = "https://github.com/Khanattila/KNLMeansCL/releases/download/v1.1.1/KNLMeansCL-v1.1.1.zip"
        Check = "KNLMeansCL.dll"
    },
    @{
        # core.zsmooth.CCD - chroma denoiser (also Cnr4 and a set of
        # RemoveGrain/TemporalMedian-family filters). Written in Zig, so it is
        # taken pre-built on every platform rather than adding a Zig toolchain to
        # the deps builds. Keep the version in step with ZSMOOTH_VERSION in
        # download-deps-{macos,linux}.sh: a skew would make the same job produce
        # different chroma per OS.
        Name = "zsmooth"
        Url = "https://github.com/adworacz/zsmooth/releases/download/0.19.0/zsmooth-x86_64-windows.zip"
        Check = "zsmooth.dll"
    }
)

foreach ($Plugin in $Plugins7z) {
    if (-not (Test-Path "$PluginsDir\$($Plugin.Check)")) {
        Write-Host "  Downloading $($Plugin.Name)..." -ForegroundColor Gray

        if (-not $Has7z) {
            Write-Host "    Skipping (7-Zip not installed)" -ForegroundColor Yellow
            continue
        }

        try {
            $ArchiveFile = Join-Path $TempDir "$($Plugin.Name).7z"
            $ExtractDir = Join-Path $TempDir "$($Plugin.Name)-extract"

            Download-File -Url $Plugin.Url -OutFile $ArchiveFile
            & $7zPath x $ArchiveFile -o"$ExtractDir" -y | Out-Null

            # Prefer 64-bit DLLs when the archive ships per-arch folders (e.g.
            # neo_f3kdb_r10.7z ships x86\ + x64\). Get-ChildItem -Recurse copies
            # last-write-wins, and x86 sorts after x64, so without this the 32-bit
            # DLL clobbers the x64 one and fails to load with GetLastError 193
            # (ERROR_BAD_EXE_FORMAT). Same logic as the zip loop below.
            $Dlls = Get-ChildItem -Path $ExtractDir -Recurse -Filter "*.dll"
            $Win64 = $Dlls | Where-Object { $_.DirectoryName -match '(?i)win64|x64|amd64|x86_64' }
            if ($Win64) { $Dlls = $Win64 }
            $Dlls | ForEach-Object {
                Copy-Item $_.FullName $PluginsDir -Force
                Write-Host "    Copied: $($_.Name)" -ForegroundColor Gray
            }
            # Also copy nnedi3_weights.bin if present
            Get-ChildItem -Path $ExtractDir -Recurse -Filter "*.bin" | ForEach-Object {
                Copy-Item $_.FullName $PluginsDir -Force
                Write-Host "    Copied: $($_.Name)" -ForegroundColor Gray
            }

            Remove-Item $ArchiveFile -Force -ErrorAction SilentlyContinue
            Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Host "    Failed: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  $($Plugin.Name) already installed" -ForegroundColor Gray
    }
}

foreach ($Plugin in $PluginsZip) {
    if (-not (Test-Path "$PluginsDir\$($Plugin.Check)")) {
        Write-Host "  Downloading $($Plugin.Name)..." -ForegroundColor Gray

        try {
            $ArchiveFile = Join-Path $TempDir "$($Plugin.Name).zip"
            $ExtractDir = Join-Path $TempDir "$($Plugin.Name)-extract"

            Download-File -Url $Plugin.Url -OutFile $ArchiveFile
            Expand-Archive -Path $ArchiveFile -DestinationPath $ExtractDir -Force

            # Prefer 64-bit DLLs when the archive ships per-arch folders (e.g.
            # fmtconv: win32/ + win64/) so a 32-bit DLL never clobbers the x64 one.
            $Dlls = Get-ChildItem -Path $ExtractDir -Recurse -Filter "*.dll"
            $Win64 = $Dlls | Where-Object { $_.DirectoryName -match '(?i)win64|x64|amd64|x86_64' }
            if ($Win64) { $Dlls = $Win64 }
            $Dlls | ForEach-Object {
                Copy-Item $_.FullName $PluginsDir -Force
                Write-Host "    Copied: $($_.Name)" -ForegroundColor Gray
            }

            Remove-Item $ArchiveFile -Force -ErrorAction SilentlyContinue
            Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Host "    Failed: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  $($Plugin.Name) already installed" -ForegroundColor Gray
    }
}

Write-Host "  Plugins installed" -ForegroundColor Green

# Verify every plugin DLL is 64-bit. A 32-bit DLL (e.g. when an archive ships
# x86\ + x64\ and the wrong one is picked) loads with GetLastError 193
# (ERROR_BAD_EXE_FORMAT) at VapourSynth autoload time — only a *warning*, so the
# VSPipe smoke test below won't catch it. Read the PE header machine field
# (0x8664 = AMD64, 0x14C = i386) and fail the build on any non-AMD64 DLL.
Write-Host "  Verifying plugin architectures (must be x64)..." -ForegroundColor Gray
$BadArch = @()
Get-ChildItem -Path $PluginsDir -Filter "*.dll" | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    # e_lfanew at 0x3C points to the PE signature; machine is 4 bytes past it.
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    $machine = [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
    if ($machine -ne 0x8664) {
        $BadArch += ("{0} (machine 0x{1:X})" -f $_.Name, $machine)
    }
}
if ($BadArch.Count -gt 0) {
    throw "Non-x64 plugin DLL(s) detected - bundle would fail to load them: $($BadArch -join ', ')"
}
Write-Host "  All plugin DLLs are x64" -ForegroundColor Green

# =============================================================================
# 4b. FFTW Library (required by DFTTest)
# =============================================================================
Write-Host ""
Write-Host "[4b/8] Downloading FFTW library..." -ForegroundColor Yellow

$FFTWPath = "$FullTargetDir\vapoursynth\libfftw3f-3.dll"
if (-not (Test-Path $FFTWPath)) {
    Write-Host "  Downloading FFTW 3.3.5..." -ForegroundColor Gray
    $FFTWZip = Join-Path $TempDir "fftw.zip"
    $FFTWUrl = "https://fftw.org/pub/fftw/fftw-3.3.5-dll64.zip"

    try {
        Download-File -Url $FFTWUrl -OutFile $FFTWZip
        $FFTWExtractDir = Join-Path $TempDir "fftw-extract"
        Expand-Archive -Path $FFTWZip -DestinationPath $FFTWExtractDir -Force

        # Copy the single-precision float DLL (required by DFTTest)
        Copy-Item "$FFTWExtractDir\libfftw3f-3.dll" "$FullTargetDir\vapoursynth\" -Force
        Write-Host "    Copied: libfftw3f-3.dll" -ForegroundColor Gray

        Remove-Item $FFTWZip -Force -ErrorAction SilentlyContinue
        Remove-Item $FFTWExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  FFTW library installed" -ForegroundColor Green
    } catch {
        Write-Host "    Failed: $_" -ForegroundColor Red
    }
} else {
    Write-Host "  FFTW library already installed" -ForegroundColor Gray
}

# =============================================================================
# 4c. libdvdread (required for DVD disc import)
# =============================================================================
Write-Host ""
Write-Host "[4c/8] Downloading libdvdread..." -ForegroundColor Yellow

$LibDir = "$FullTargetDir\lib"
if (-not (Test-Path $LibDir)) {
    New-Item -ItemType Directory -Force -Path $LibDir | Out-Null
}

$DvdReadPath = "$LibDir\dvdread.dll"
if (-not (Test-Path $DvdReadPath)) {
    Write-Host "  Downloading libdvdread 6.1.3 (ShiftMediaProject MSVC build)..." -ForegroundColor Gray
    $DvdReadZip = Join-Path $TempDir "libdvdread.zip"
    $DvdReadUrl = "https://github.com/ShiftMediaProject/libdvdread/releases/download/6.1.3-1/libdvdread_6.1.3-1_msvc17.zip"

    try {
        Download-File -Url $DvdReadUrl -OutFile $DvdReadZip
        $DvdReadExtractDir = Join-Path $TempDir "libdvdread-extract"
        Expand-Archive -Path $DvdReadZip -DestinationPath $DvdReadExtractDir -Force

        # Find the x64 shared DLL
        $DvdReadDll = Get-ChildItem -Path $DvdReadExtractDir -Recurse -Filter "dvdread.dll" |
            Where-Object { $_.FullName -match "x64" -and $_.FullName -match "shared" } |
            Select-Object -First 1
        if (-not $DvdReadDll) {
            # Fallback: any x64 DLL
            $DvdReadDll = Get-ChildItem -Path $DvdReadExtractDir -Recurse -Filter "dvdread.dll" |
                Where-Object { $_.FullName -match "x64" } |
                Select-Object -First 1
        }
        if ($DvdReadDll) {
            Copy-Item $DvdReadDll.FullName $DvdReadPath -Force
            Write-Host "    Copied: dvdread.dll" -ForegroundColor Gray
        } else {
            Write-Host "    WARNING: dvdread.dll not found in archive" -ForegroundColor Yellow
        }

        Remove-Item $DvdReadZip -Force -ErrorAction SilentlyContinue
        Remove-Item $DvdReadExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  libdvdread installed (CSS decryption via optional libdvdcss-2.dll)" -ForegroundColor Green
    } catch {
        Write-Host "    Failed: $_" -ForegroundColor Red
    }
} else {
    Write-Host "  libdvdread already installed" -ForegroundColor Gray
}

# =============================================================================
# akarin - LLVM JIT for std.Expr
# =============================================================================
# VapourSynth's own Expr JIT is x86-only (#ifdef VS_TARGET_CPU_X86), so ARM runs
# a scalar per-pixel interpreter. Windows x64 already has that JIT, so it gains
# far less than arm64 does -- but the routing shim is arch-neutral and shipping
# akarin everywhere it exists keeps the same job from producing different output
# per OS, which is the rule the havsfunc patches already follow.
#
# akarin is bit-identical to std.Expr on 45 of the 46 expressions havsfunc
# generates; the one exception rounds a single .5 tie down instead of to even.
$AkarinVersion = "1.4.1"
Write-Host ""
Write-Host "Downloading akarin $AkarinVersion (LLVM JIT for std.Expr)..." -ForegroundColor Yellow
if (-not (Test-Path "$PluginsDir\libakarin.dll")) {
    try {
        $AkMeta = Invoke-RestMethod -Uri "https://pypi.org/pypi/vapoursynth-akarin/$AkarinVersion/json"
        $AkUrl = ($AkMeta.urls | Where-Object { $_.filename -like "*win_amd64.whl" } |
                  Select-Object -First 1).url
        if (-not $AkUrl) { throw "no win_amd64 wheel for akarin $AkarinVersion" }

        $AkWhl = Join-Path $TempDir "akarin.whl"
        $AkZip = Join-Path $TempDir "akarin-wheel.zip"
        $AkOut = Join-Path $TempDir "akarin-extract"
        Invoke-WebRequest -Uri $AkUrl -OutFile $AkWhl -UseBasicParsing
        # A wheel is a zip, but Expand-Archive validates the *extension* and
        # refuses .whl outright -- same trap as the VapourSynth wheel above.
        Copy-Item $AkWhl $AkZip -Force
        Remove-Item $AkOut -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $AkZip -DestinationPath $AkOut -Force

        # libzstd.dll sits beside the plugin, which is how the wheel ships it and
        # how Windows resolves a plugin's own dependencies. VapourSynth will probe
        # it during autoload and skip it (no VapourSynthPluginInit2); that is
        # noise in the log, not a failure.
        $AkSrc = Join-Path $AkOut "vapoursynth\plugins\akarin"
        foreach ($dll in @("libakarin.dll", "libzstd.dll")) {
            $p = Join-Path $AkSrc $dll
            if (-not (Test-Path $p)) { throw "$dll missing from the akarin wheel" }
            Copy-Item $p (Join-Path $PluginsDir $dll) -Force
            Write-Host "    Copied: $dll" -ForegroundColor Gray
        }
        Remove-Item $AkWhl, $AkZip -Force -ErrorAction SilentlyContinue
        Remove-Item $AkOut -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  akarin installed" -ForegroundColor Green
    } catch {
        Write-Host "    Failed: $_" -ForegroundColor Red
    }
} else {
    Write-Host "  akarin already installed" -ForegroundColor Gray
}

# =============================================================================
# 5. Python Packages (havsfunc, mvsfunc, adjust)
# =============================================================================
Write-Host ""
Write-Host "[4/7] Downloading Python packages..." -ForegroundColor Yellow

$SitePackagesDir = "$FullTargetDir\vapoursynth\Lib\site-packages"

# havsfunc r31
if (-not (Test-Path "$SitePackagesDir\havsfunc.py")) {
    Write-Host "  Downloading havsfunc r31..." -ForegroundColor Gray
    $HavsfuncUrl = "https://github.com/HomeOfVapourSynthEvolution/havsfunc/archive/refs/tags/r31.tar.gz"
    $HavsfuncTar = Join-Path $TempDir "havsfunc.tar.gz"

    Download-File -Url $HavsfuncUrl -OutFile $HavsfuncTar
    # Use Windows' own bsdtar by full path. Bare `tar` picks up whatever is first
    # on PATH, and Git for Windows ships GNU tar, which reads the drive letter in
    # "C:\..." as a remote host: "tar (child): Cannot connect to C: resolve failed".
    $SystemTar = Join-Path $env:SystemRoot "System32\tar.exe"
    if (-not (Test-Path $SystemTar)) { $SystemTar = "tar" }
    & $SystemTar -xzf $HavsfuncTar -C $TempDir
    if ($LASTEXITCODE -ne 0) { throw "tar failed to extract $HavsfuncTar (exit $LASTEXITCODE)" }

    $HavsfuncPy = Get-ChildItem -Path $TempDir -Recurse -Filter "havsfunc.py" | Select-Object -First 1
    if ($HavsfuncPy) {
        Copy-Item $HavsfuncPy.FullName $SitePackagesDir -Force
        Write-Host "    Copied: havsfunc.py" -ForegroundColor Gray
    }

    Remove-Item $HavsfuncTar -Force -ErrorAction SilentlyContinue
    Remove-Item "$TempDir\havsfunc-*" -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  havsfunc.py already installed" -ForegroundColor Gray
}

# mvsfunc
if (-not (Test-Path "$SitePackagesDir\mvsfunc")) {
    Write-Host "  Downloading mvsfunc..." -ForegroundColor Gray
    $MvsfuncUrl = "https://github.com/HomeOfVapourSynthEvolution/mvsfunc/archive/refs/heads/master.zip"
    $MvsfuncZip = Join-Path $TempDir "mvsfunc.zip"

    Download-File -Url $MvsfuncUrl -OutFile $MvsfuncZip
    Expand-Archive -Path $MvsfuncZip -DestinationPath $TempDir -Force

    $MvsfuncDir = Get-ChildItem -Path $TempDir -Directory -Filter "mvsfunc-*" | Select-Object -First 1
    if ($MvsfuncDir) {
        Copy-Item "$($MvsfuncDir.FullName)\mvsfunc" $SitePackagesDir -Recurse -Force
        Write-Host "    Copied: mvsfunc/" -ForegroundColor Gray
    }

    Remove-Item $MvsfuncZip -Force -ErrorAction SilentlyContinue
    Remove-Item "$TempDir\mvsfunc-*" -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  mvsfunc already installed" -ForegroundColor Gray
}

# adjust
if (-not (Test-Path "$SitePackagesDir\adjust.py")) {
    Write-Host "  Downloading adjust..." -ForegroundColor Gray
    $AdjustUrl = "https://raw.githubusercontent.com/dubhater/vapoursynth-adjust/master/adjust.py"
    Download-File -Url $AdjustUrl -OutFile "$SitePackagesDir\adjust.py"
    Write-Host "    Copied: adjust.py" -ForegroundColor Gray
} else {
    Write-Host "  adjust.py already installed" -ForegroundColor Gray
}

Write-Host "  Python packages installed" -ForegroundColor Green

# =============================================================================
# 6. Patch havsfunc for API compatibility
# =============================================================================
Write-Host ""
Write-Host "[5/7] Patching havsfunc for API compatibility..." -ForegroundColor Yellow

$HavsfuncPath = "$SitePackagesDir\havsfunc.py"
if (Test-Path $HavsfuncPath) {
    $Content = Get-Content $HavsfuncPath -Raw
    $PatchesApplied = @()

    # Patch 1: mvtools API (renamed _lambda/_global to lambda/global)
    if ($Content -notmatch "_fix_mv_args") {
        Write-Host "  Applying mvtools API compatibility patch..." -ForegroundColor Gray

        # Add helper function after imports
        $PatchFunction = @"

# Compatibility patch for mvtools API (renamed _lambda/_global to lambda/global)
def _fix_mv_args(args):
    result = {}
    for k, v in args.items():
        if k == '_lambda':
            result['lambda'] = v
        elif k == '_global':
            result['global'] = v
        else:
            result[k] = v
    return result

"@
        # Insert after "import math" line
        $Content = $Content -replace "(import math\r?\n)", "`$1$PatchFunction"

        # Replace analyse_args and recalculate_args calls
        $Content = $Content -replace "\*\*analyse_args\)", "**_fix_mv_args(analyse_args))"
        $Content = $Content -replace "\*\*recalculate_args\)", "**_fix_mv_args(recalculate_args))"
        $PatchesApplied += "mvtools API"
    }

    # Patch 2: DFTTest API (sstring parameter removed in newer versions)
    if ($Content -match "sstring='0.0:4.0 0.2:9.0 1.0:15.0'") {
        Write-Host "  Applying DFTTest API compatibility patch..." -ForegroundColor Gray
        # Replace sstring parameter with sigma (approximate equivalent)
        $Content = $Content -replace "sstring='0.0:4.0 0.2:9.0 1.0:15.0'", "sigma=10.0"
        $PatchesApplied += "DFTTest API"
    }

    # Patch 3: VapourSynth YCOCG removal (no longer exists in newer VS)
    if ($Content -match "vs\.YCOCG") {
        Write-Host "  Applying YCOCG compatibility patch..." -ForegroundColor Gray
        # Remove YCOCG from color family checks (it's deprecated/removed)
        $Content = $Content -replace "input\.format\.color_family not in \[vs\.YUV, vs\.YCOCG\]", "input.format.color_family != vs.YUV"
        $Content = $Content -replace "'LUTDeCrawl: This is not an 8-10 bit YUV or YCoCg clip'", "'LUTDeCrawl: This is not an 8-10 bit YUV clip'"
        $PatchesApplied += "YCOCG removal"
    }

    # Patch 4: EEDI3CL fallback — modern eedi3m plugin removed EEDI3CL (OpenCL).
    # When opencl=True, havsfunc tries core.eedi3m.EEDI3CL which doesn't exist.
    # Fall back to CPU EEDI3 so opencl mode works (NNEDI3CL still uses GPU).
    # Two locations: santiag_stronger (12-space indent) and QTGMC_Interpolate (8-space indent).
    # Must patch deeper indent first to avoid substring matches with .Replace().
    $PatchedEedi3cl = $false

    # 4a: santiag_stronger (12-space indent, uses mdis=mdis)
    $OldSantiag = "            myEEDI3 = core.eedi3m.EEDI3CL`n"
    if ($Content.Contains($OldSantiag)) {
        Write-Host "  Applying EEDI3CL fallback patch (santiag_stronger)..." -ForegroundColor Gray
        $NewSantiag = "            has_eedi3cl = hasattr(core, 'eedi3m') and hasattr(core.eedi3m, 'EEDI3CL')`n            myEEDI3 = core.eedi3m.EEDI3CL if has_eedi3cl else (core.eedi3m.EEDI3 if hasattr(core, 'eedi3m') else core.eedi3.eedi3)`n"
        $Content = $Content.Replace($OldSantiag, $NewSantiag)

        $OldSantiagArgs = "            eedi3_args = dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=mdis, vcheck=vcheck, device=device)`n"
        $NewSantiagArgs = "            eedi3_args = dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=mdis, vcheck=vcheck, device=device) if has_eedi3cl else dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=mdis, vcheck=vcheck)`n"
        $Content = $Content.Replace($OldSantiagArgs, $NewSantiagArgs)
        $PatchedEedi3cl = $true
    }

    # 4b: QTGMC_Interpolate (8-space indent, uses mdis=EdiMaxD)
    $OldQtgmc = "        myEEDI3 = core.eedi3m.EEDI3CL`n"
    if ($Content.Contains($OldQtgmc)) {
        Write-Host "  Applying EEDI3CL fallback patch (QTGMC_Interpolate)..." -ForegroundColor Gray
        $NewQtgmc = "        has_eedi3cl = hasattr(core, 'eedi3m') and hasattr(core.eedi3m, 'EEDI3CL')`n        myEEDI3 = core.eedi3m.EEDI3CL if has_eedi3cl else (core.eedi3m.EEDI3 if hasattr(core, 'eedi3m') else core.eedi3.eedi3)`n"
        $Content = $Content.Replace($OldQtgmc, $NewQtgmc)

        $OldQtgmcArgs = "        eedi3_args = dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=EdiMaxD, vcheck=vcheck, device=device)`n"
        $NewQtgmcArgs = "        eedi3_args = dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=EdiMaxD, vcheck=vcheck, device=device) if has_eedi3cl else dict(alpha=alpha, beta=beta, gamma=gamma, nrad=nrad, mdis=EdiMaxD, vcheck=vcheck)`n"
        $Content = $Content.Replace($OldQtgmcArgs, $NewQtgmcArgs)
        $PatchedEedi3cl = $true
    }

    if ($PatchedEedi3cl) {
        $PatchesApplied += "EEDI3CL fallback"
    }

    # Patch 5: Bob() bit depth - fmtconv's generic (non-x86-SIMD) VERTICAL
    # resampler returns black for any input below 16-bit, and havsfunc's Bob()
    # bobs fields with fmtc.resample(scalev=2, ...). Windows x64 is NOT affected
    # (its SSE2/AVX2 scalers override the broken generic path) - this is applied
    # here purely so every platform generates identical output from an identical
    # havsfunc. On arm64 it is a real fix: it repaired QTGMC's Placebo/Very Slow
    # presets (the only ones defaulting NoiseProcess=2, whose noise pass calls
    # Bob) and the Draft preset (EdiMode='bob'). Promoting to 16-bit is a no-op
    # for quality here because fmtc.resample already outputs 16-bit from 8-bit
    # input, and Bob()'s existing tail dithers back to the source depth.
    $OldBob = "    clip = core.std.SeparateFields(clip, tff).fmtc.resample(scalev=2, kernel='bicubic', a1=b, a2=c, interlaced=1, interlacedd=0)`n"
    if ($Content.Contains($OldBob)) {
        Write-Host "  Applying Bob 16-bit resample patch..." -ForegroundColor Gray
        $NewBob = "    _bob_fields = core.std.SeparateFields(clip, tff)`n" +
                  "    if bits < 16:`n" +
                  "        _bob_fields = core.fmtc.bitdepth(_bob_fields, bits=16)`n" +
                  "    clip = _bob_fields.fmtc.resample(scalev=2, kernel='bicubic', a1=b, a2=c, interlaced=1, interlacedd=0)`n"
        $Content = $Content.Replace($OldBob, $NewBob)
        $PatchesApplied += "Bob 16-bit resample"
    }

    # Patch 6: prefer the NEON nnedi3 over the scalar znedi3 on ARM.
    # znedi3's SIMD kernels are x86-only, so the ARM bundles build it with X86=0
    # and it runs fully scalar; the bundled dubhater nnedi3 ships real NEON
    # kernels and is 6.3x faster for the same call (measured on an M1, QTGMC
    # Slow: 37.8s vs 5.95s of CPU). havsfunc hardcodes znedi3 whenever it is
    # present, so without this every ARM deinterlace pays that cost.
    # Windows x64 is NOT affected - the runtime check below keeps it on znedi3
    # exactly as before. This is applied here purely so every platform generates
    # identical output from an identical havsfunc, same as patch 5.
    $OldEdi = "myNNEDI3 = core.znedi3.nnedi3 if hasattr(core, 'znedi3') else core.nnedi3.nnedi3"
    if ($Content -notmatch "_nnedi3_impl" -and $Content.Contains($OldEdi)) {
        Write-Host "  Applying ARM nnedi3 preference patch..." -ForegroundColor Gray
        # Leading whitespace is untouched, so this covers all three call sites
        # (daa, santiag, QTGMC) despite their differing indentation.
        $Content = $Content.Replace($OldEdi, "myNNEDI3 = _nnedi3_impl()")
        $PatchFunction = @"

# Prefer the NEON nnedi3 over the scalar znedi3 on ARM (see download-deps-*).
def _nnedi3_impl():
    import platform
    if platform.machine().lower() in ('arm64', 'aarch64') and hasattr(core, 'nnedi3'):
        return core.nnedi3.nnedi3
    return core.znedi3.nnedi3 if hasattr(core, 'znedi3') else core.nnedi3.nnedi3

"@
        $Content = $Content -replace "(import math\r?\n)", "`$1$PatchFunction"
        $PatchesApplied += "ARM nnedi3 preference"
    }

    # Patch 7: route std.Expr through akarin's LLVM JIT.
    # VapourSynth's own Expr JIT is x86-only, so ARM walks the whole bytecode
    # program once per pixel. Windows x64 already has that JIT and gains far
    # less, but this is applied here so every platform generates identical
    # output from an identical havsfunc - the same reasoning as patches 5 and 6.
    # havsfunc has 116 core.std.Expr sites, so rebind the module's `core` to a
    # proxy that swaps only .std.Expr and forwards everything else untouched.
    # The shim installs only when akarin is present; where it is absent `core`
    # stays the real core, with no wrapper and no behaviour change.
    if ($Content -notmatch "_akarin_expr") {
        Write-Host "  Applying akarin Expr routing patch..." -ForegroundColor Gray
        $PatchFunction = @"

# Route std.Expr through akarin's LLVM JIT where present (see download-deps-*).
_akarin_expr = getattr(getattr(core, 'akarin', None), 'Expr', None)
if _akarin_expr is not None:
    class _ExprStd:
        __slots__ = ('_std',)
        def __init__(self, std):
            self._std = std
        def __getattr__(self, name):
            return _akarin_expr if name == 'Expr' else getattr(self._std, name)

    class _ExprCore:
        __slots__ = ('_core', '_std')
        def __init__(self, c):
            self._core = c
            self._std = _ExprStd(c.std)
        def __getattr__(self, name):
            return self._std if name == 'std' else getattr(self._core, name)

    core = _ExprCore(core)

"@
        $Content = $Content -replace "(import math\r?\n)", "`$1$PatchFunction"
        $PatchesApplied += "akarin Expr routing"
    }

    if ($PatchesApplied.Count -gt 0) {
        Set-Content $HavsfuncPath $Content -NoNewline
        Write-Host "  havsfunc patched ($($PatchesApplied -join ', '))" -ForegroundColor Green
    } else {
        Write-Host "  havsfunc already patched" -ForegroundColor Gray
    }
} else {
    Write-Host "  havsfunc.py not found, skipping patch" -ForegroundColor Yellow
}

# =============================================================================
# 7. NNEDI3 Weights (if not already copied with znedi3)
# =============================================================================
Write-Host ""
Write-Host "[6/7] Verifying NNEDI3 weights..." -ForegroundColor Yellow

$WeightsPath = "$PluginsDir\nnedi3_weights.bin"
if (-not (Test-Path $WeightsPath)) {
    Write-Host "  Downloading nnedi3_weights.bin..." -ForegroundColor Gray
    $WeightsUrl = "https://github.com/sekrit-twc/znedi3/raw/master/znedi3/nnedi3_weights.bin"
    Download-File -Url $WeightsUrl -OutFile $WeightsPath
    Write-Host "  NNEDI3 weights installed" -ForegroundColor Green
} else {
    Write-Host "  NNEDI3 weights already installed" -ForegroundColor Gray
}

# =============================================================================
# 7.5 VSScript smoke test
# =============================================================================
# Run VSPipe --version with the same environment the worker uses. This forces
# VSScript to spin up its embedded Python and import vapoursynth, which fails
# ("Failed to initialize VSScript") if the core vapoursynth.dll isn't sitting
# next to vapoursynth.pyd, python is mis-wired, etc. Catching it here turns a
# silently-broken bundle into a red build instead of a runtime failure that
# only the preview integration test would surface.
Write-Host ""
Write-Host "[7.5/8] Verifying VSScript initializes..." -ForegroundColor Yellow
$VSPipeExe = "$VSDir\Lib\site-packages\vapoursynth\vspipe.exe"
if (Test-Path $VSPipeExe) {
    $env:PYTHONNOUSERSITE = "1"
    $env:PYTHONHOME = $VSDir
    $env:PYTHONPATH = "$VSDir\Lib\site-packages"
    $env:VAPOURSYNTH_EXTRA_PLUGIN_PATH = $PluginsDir
    $env:PATH = "$FullTargetDir\ffmpeg;$VSDir;$env:PATH"
    $VsVersion = & $VSPipeExe --version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $VsVersion -notmatch "Core R") {
        throw "VSScript smoke test failed (exit $LASTEXITCODE). VSPipe --version output:`n$VsVersion"
    }
    Write-Host "  VSScript OK: $(($VsVersion -split "`n" | Where-Object { $_ -match 'Core R' } | Select-Object -First 1).Trim())" -ForegroundColor Green
} else {
    throw "VSPipe.exe not found at $VSPipeExe"
}

# =============================================================================
# 7.6 Version file
# =============================================================================
# Without this the app considers a locally-built deps tree "missing" on startup
# ("DependencyManager: Version file missing") and downloads the published bundle
# straight over the top of it. That is destructive whenever the local tree is
# ahead of the release - building R78 here and then launching the app silently
# restored the R73 bundle. Stamp the version the app expects so a freshly built
# tree reads as current. macOS and Linux already write this file.
Write-Host ""
Write-Host "[7.6/8] Writing version file..." -ForegroundColor Yellow
$DepsVersionJson = Join-Path $ProjectRoot "app\assets\deps-version.json"
$ExpectedVersion = (Get-Content $DepsVersionJson -Raw | ConvertFrom-Json).version
[ordered]@{
    version     = $ExpectedVersion
    installedAt = (Get-Date).ToUniversalTime().ToString("o")
    platform    = "windows-x64"
    buildType   = "source"
} | ConvertTo-Json | Set-Content -Path "$FullTargetDir\version.json" -Encoding utf8
Write-Host "  version.json written ($ExpectedVersion)" -ForegroundColor Green

# =============================================================================
# 8. Cleanup
# =============================================================================
Write-Host ""
Write-Host "[7/7] Cleaning up..." -ForegroundColor Yellow

Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  Cleanup complete" -ForegroundColor Green

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "=== Installation Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Dependencies installed to: $FullTargetDir" -ForegroundColor White
Write-Host ""
Write-Host "Directory structure:" -ForegroundColor White
Write-Host "  $FullTargetDir\"
Write-Host "    vapoursynth\           - VapourSynth + Python 3.12 + vspipe.exe"
Write-Host "      vs-plugins\          - VS plugins (.dll)"
Write-Host "      Lib\site-packages\   - Python packages (havsfunc, mvsfunc, etc.)"
Write-Host "    ffmpeg\                - FFmpeg binaries"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Build the Rust worker: cd worker && cargo build --release"
Write-Host "  2. Build the Flutter app: cd app && flutter build windows"
Write-Host ""
