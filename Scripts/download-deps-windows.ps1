<#
.SYNOPSIS
    Downloads all dependencies for iDeinterlace on Windows x64.

.DESCRIPTION
    This script downloads and sets up:
    - VapourSynth R73 (portable, includes Python 3.8)
    - Python 3.8 embeddable (for VSScript)
    - FFmpeg (latest GPL build)
    - VapourSynth plugins (mvtools, nnedi3cl, znedi3, eedi3m, fmtconv, ffms2, miscfilters, dfttest, neo_f3kdb, cas)
    - FFTW library (required by dfttest)
    - Python packages (havsfunc, mvsfunc, adjust)
    - NNEDI3 weights
    - Patches havsfunc for API compatibility (mvtools, DFTTest, YCOCG)

.PARAMETER TargetDir
    The target directory for dependencies. Default: deps/windows-x64

.EXAMPLE
    .\download-deps-windows.ps1
    .\download-deps-windows.ps1 -TargetDir "C:\ideinterlace\deps\windows-x64"
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

Write-Host "=== iDeinterlace Windows Dependency Downloader ===" -ForegroundColor Cyan
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
$TempDir = Join-Path $env:TEMP "ideinterlace-deps"
if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
}

function Download-File {
    param([string]$Url, [string]$OutFile)
    Write-Host "  Downloading: $Url" -ForegroundColor Gray
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

# =============================================================================
# 1. VapourSynth R73 Portable
# =============================================================================
Write-Host ""
Write-Host "[1/8] Downloading VapourSynth R73 Portable..." -ForegroundColor Yellow

$VSZip = Join-Path $TempDir "vapoursynth.zip"
$VSUrl = "https://github.com/vapoursynth/vapoursynth/releases/download/R73/VapourSynth64-Portable-R73.zip"

if (-not (Test-Path "$FullTargetDir\vapoursynth\VSPipe.exe")) {
    Download-File -Url $VSUrl -OutFile $VSZip
    Expand-Archive -Path $VSZip -DestinationPath "$FullTargetDir\vapoursynth" -Force
    Remove-Item $VSZip -Force
    Write-Host "  VapourSynth R73 installed" -ForegroundColor Green
} else {
    Write-Host "  VapourSynth R73 already installed" -ForegroundColor Gray
}

# =============================================================================
# 2. Python 3.8 Embeddable (for VSScriptPython38.dll)
# =============================================================================
Write-Host ""
Write-Host "[2/8] Downloading Python 3.8.10 embeddable..." -ForegroundColor Yellow

$PythonZip = Join-Path $TempDir "python38.zip"
$PythonUrl = "https://www.python.org/ftp/python/3.8.10/python-3.8.10-embed-amd64.zip"
$VSDir = "$FullTargetDir\vapoursynth"

if (-not (Test-Path "$VSDir\python38.dll")) {
    Download-File -Url $PythonUrl -OutFile $PythonZip

    $PythonTempDir = Join-Path $TempDir "python38-extract"
    Expand-Archive -Path $PythonZip -DestinationPath $PythonTempDir -Force

    # Copy Python files to VapourSynth directory
    Copy-Item "$PythonTempDir\python38.dll" $VSDir -Force
    Copy-Item "$PythonTempDir\python3.dll" $VSDir -Force
    Copy-Item "$PythonTempDir\python38.zip" $VSDir -Force
    Copy-Item "$PythonTempDir\*.pyd" $VSDir -Force
    Copy-Item "$PythonTempDir\libffi-7.dll" $VSDir -Force
    Copy-Item "$PythonTempDir\libcrypto-1_1.dll" $VSDir -Force
    Copy-Item "$PythonTempDir\libssl-1_1.dll" $VSDir -Force

    # Create python38._pth file
    @"
python38.zip
.
Lib\site-packages
import site
"@ | Set-Content "$VSDir\python38._pth"

    Remove-Item $PythonZip -Force
    Remove-Item $PythonTempDir -Recurse -Force
    Write-Host "  Python 3.8.10 installed" -ForegroundColor Green
} else {
    Write-Host "  Python 3.8.10 already installed" -ForegroundColor Gray
}

# Install VapourSynth Python 3.8 wheel
Write-Host "  Installing VapourSynth Python wheel..." -ForegroundColor Gray
$WheelPath = "$VSDir\wheel\vapoursynth-73-cp38-cp38-win_amd64.whl"
if (Test-Path $WheelPath) {
    Expand-Archive -Path $WheelPath -DestinationPath "$VSDir\Lib\site-packages" -Force
    # Copy .pyd with simple name
    if (Test-Path "$VSDir\Lib\site-packages\vapoursynth.cp38-win_amd64.pyd") {
        Copy-Item "$VSDir\Lib\site-packages\vapoursynth.cp38-win_amd64.pyd" "$VSDir\Lib\site-packages\vapoursynth.pyd" -Force
    }
    Write-Host "  VapourSynth wheel installed" -ForegroundColor Green
}

# =============================================================================
# 3. FFmpeg
# =============================================================================
Write-Host ""
Write-Host "[3/8] Downloading FFmpeg..." -ForegroundColor Yellow

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
Write-Host "[4/8] Downloading VapourSynth plugins..." -ForegroundColor Yellow

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
        Name = "ffms2"
        Url = "https://github.com/FFMS/ffms2/releases/download/2.40/ffms2-2.40-msvc.7z"
        Check = "ffms2.dll"
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
        Name = "removegrain"
        Url = "https://github.com/vapoursynth/vs-removegrain/releases/download/R1/removegrain-r1.7z"
        Check = "RemoveGrainVS.dll"
    },
    @{
        Name = "ctmf"
        Url = "https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CTMF/releases/download/r5/CTMF-r5.7z"
        Check = "CTMF.dll"
    }
)

# Plugins with zip format
$PluginsZip = @(
    @{
        Name = "fmtconv"
        Url = "https://github.com/EleonoreMizo/fmtconv/releases/download/r30/fmtconv-r30-win-x64.zip"
        Check = "fmtconv.dll"
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

            # Copy all DLL and bin files
            Get-ChildItem -Path $ExtractDir -Recurse -Filter "*.dll" | ForEach-Object {
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

            Get-ChildItem -Path $ExtractDir -Recurse -Filter "*.dll" | ForEach-Object {
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
# 5. Python Packages (havsfunc, mvsfunc, adjust)
# =============================================================================
Write-Host ""
Write-Host "[5/8] Downloading Python packages..." -ForegroundColor Yellow

$SitePackagesDir = "$FullTargetDir\vapoursynth\Lib\site-packages"

# havsfunc r31
if (-not (Test-Path "$SitePackagesDir\havsfunc.py")) {
    Write-Host "  Downloading havsfunc r31..." -ForegroundColor Gray
    $HavsfuncUrl = "https://github.com/HomeOfVapourSynthEvolution/havsfunc/archive/refs/tags/r31.tar.gz"
    $HavsfuncTar = Join-Path $TempDir "havsfunc.tar.gz"

    Download-File -Url $HavsfuncUrl -OutFile $HavsfuncTar
    & tar -xzf $HavsfuncTar -C $TempDir

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
Write-Host "[6/8] Patching havsfunc for API compatibility..." -ForegroundColor Yellow

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
Write-Host "[7/8] Verifying NNEDI3 weights..." -ForegroundColor Yellow

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
# 8. Cleanup
# =============================================================================
Write-Host ""
Write-Host "[8/8] Cleaning up..." -ForegroundColor Yellow

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
Write-Host "    vapoursynth\           - VapourSynth + Python 3.8 + vspipe.exe"
Write-Host "      vs-plugins\          - VS plugins (.dll)"
Write-Host "      Lib\site-packages\   - Python packages (havsfunc, mvsfunc, etc.)"
Write-Host "    ffmpeg\                - FFmpeg binaries"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Build the Rust worker: cd worker && cargo build --release"
Write-Host "  2. Build the Flutter app: cd app && flutter build windows"
Write-Host ""
