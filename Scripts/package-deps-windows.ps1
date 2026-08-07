# Package VapourBox Dependencies for Windows
# Creates a standalone dependencies zip file
#
# Prerequisites:
# - Dependencies downloaded (run download-deps-windows.ps1 first)
#
# Usage: .\Scripts\package-deps-windows.ps1 -Version "1.0.0"

param(
    [Parameter(Mandatory=$true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$DistDir = Join-Path $ProjectRoot "dist"
$AppName = "VapourBox"
$PackageName = "$AppName-deps-$Version-windows-x64"
$PackageDir = Join-Path $DistDir $PackageName

Write-Host "=== Packaging VapourBox Dependencies for Windows ===" -ForegroundColor Cyan
Write-Host "Version: $Version"
Write-Host ""

# Check prerequisites
Write-Host "[1/5] Checking prerequisites..." -ForegroundColor Yellow

$DepsDir = Join-Path $ProjectRoot "deps\windows-x64"
if (-not (Test-Path $DepsDir)) {
    Write-Host "ERROR: Dependencies not found at $DepsDir" -ForegroundColor Red
    Write-Host "Run '.\Scripts\download-deps-windows.ps1' first" -ForegroundColor Red
    exit 1
}

# R78 ships Windows as a Python wheel, so vspipe.exe lives inside the installed
# package next to libvapoursynth.dll rather than at the root of the portable dir.
if (-not (Test-Path (Join-Path $DepsDir "vapoursynth\Lib\site-packages\vapoursynth\vspipe.exe"))) {
    Write-Host "ERROR: VapourSynth not found in dependencies" -ForegroundColor Red
    exit 1
}

# R78 moved every core filter (std, resize, ...) out of libvapoursynth into
# libvapoursynthfilters.dll. Without it the bundle loads but every job dies at
# script evaluation with missing namespaces.
if (-not (Test-Path (Join-Path $DepsDir "vapoursynth\Lib\site-packages\vapoursynth\libvapoursynthfilters.dll"))) {
    Write-Host "ERROR: libvapoursynthfilters.dll (R78 core filters) missing" -ForegroundColor Red
    Write-Host "Every job would fail at script evaluation with missing namespaces (std, resize, ...)" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path (Join-Path $DepsDir "ffmpeg\ffmpeg.exe"))) {
    Write-Host "ERROR: FFmpeg not found in dependencies" -ForegroundColor Red
    exit 1
}

# python312.zip is the Python 3.12 stdlib (contains the `encodings` module). It is
# *.zip-gitignored, so it is easy to ship a bundle without it when building from a
# checked-out deps tree. Without it the app crashes at runtime with:
#   ModuleNotFoundError: No module named 'encodings'
$PythonStdlibZip = Join-Path $DepsDir "vapoursynth\python312.zip"
if (-not (Test-Path $PythonStdlibZip) -or (Get-Item $PythonStdlibZip).Length -lt 1MB) {
    Write-Host "ERROR: vapoursynth\python312.zip (Python 3.12 stdlib) missing or too small" -ForegroundColor Red
    Write-Host "The packaged bundle would crash with: ModuleNotFoundError: No module named 'encodings'" -ForegroundColor Red
    Write-Host "Run '.\Scripts\download-deps-windows.ps1' to fetch it, then re-package" -ForegroundColor Red
    exit 1
}

Write-Host "    Prerequisites OK" -ForegroundColor Green

# Create package directory
Write-Host "[2/5] Creating package structure..." -ForegroundColor Yellow
if (Test-Path $PackageDir) {
    Remove-Item -Recurse -Force $PackageDir
}
New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
New-Item -ItemType Directory -Force -Path "$PackageDir\ffmpeg" | Out-Null

# Copy VapourSynth
Write-Host "[3/5] Copying VapourSynth..." -ForegroundColor Yellow
$VSDir = Join-Path $DepsDir "vapoursynth"
Copy-Item -Recurse -Force $VSDir "$PackageDir\vapoursynth"

# Remove unnecessary files to reduce size (keep portable.vs - required for portable mode!)
$UnnecessaryFiles = @(
    "7z.exe", "7z.dll", "AVFS.exe", "VSVFW.dll",
    "pfm-192-vapoursynth-win.exe", "vsrepo.py", "vsgenstubs.py",
    "MANIFEST.in"
)
foreach ($file in $UnnecessaryFiles) {
    $path = Join-Path "$PackageDir\vapoursynth" $file
    if (Test-Path $path) { Remove-Item $path -Force }
}

# Remove unnecessary directories (keep vs-coreplugins to avoid warning)
$UnnecessaryDirs = @("doc", "sdk", "vsgenstubs4", "wheel")
foreach ($dir in $UnnecessaryDirs) {
    $path = Join-Path "$PackageDir\vapoursynth" $dir
    if (Test-Path $path) { Remove-Item -Recurse -Force $path }
}

# Remove __pycache__ directories recursively
Get-ChildItem -Path "$PackageDir\vapoursynth" -Directory -Recurse -Filter "__pycache__" | Remove-Item -Recurse -Force

# R78's wheel ships debug symbols beside every DLL (libvapoursynth.pdb,
# libvapoursynthfilters*.pdb, vsscript.pdb) - ~49 MB of them, unused at runtime.
Get-ChildItem -Path "$PackageDir\vapoursynth" -Recurse -File -Filter "*.pdb" | Remove-Item -Force

# The wheel's SDK payload: C headers and pkg-config files for building plugins
# against VapourSynth. The R73 layout kept the same thing in an "sdk" directory,
# already pruned above.
foreach ($dir in @("include", "pkgconfig")) {
    $path = Join-Path "$PackageDir\vapoursynth\Lib\site-packages\vapoursynth" $dir
    if (Test-Path $path) { Remove-Item -Recurse -Force $path }
}

# Remove development files from site-packages
$DevDirs = @("cython", "vsscript")
foreach ($dir in $DevDirs) {
    $path = Join-Path "$PackageDir\vapoursynth\Lib\site-packages" $dir
    if (Test-Path $path) { Remove-Item -Recurse -Force $path }
}

# Remove temporary files
Get-ChildItem -Path "$PackageDir\vapoursynth" -Recurse -Filter "tmpclaude-*" | Remove-Item -Force

# Copy support libraries (dvdread, etc.)
$LibDir = Join-Path $DepsDir "lib"
if (Test-Path $LibDir) {
    Write-Host "    Copying support libraries..." -ForegroundColor Gray
    Copy-Item -Recurse -Force $LibDir "$PackageDir\lib"
}

# Copy FFmpeg
Write-Host "[4/5] Copying FFmpeg..." -ForegroundColor Yellow
Copy-Item (Join-Path $DepsDir "ffmpeg\ffmpeg.exe") "$PackageDir\ffmpeg\"
Copy-Item (Join-Path $DepsDir "ffmpeg\ffprobe.exe") "$PackageDir\ffmpeg\" -ErrorAction SilentlyContinue

# Create version file
Write-Host "    Creating version file..."
$VersionInfo = @{
    version = $Version
    installedAt = (Get-Date).ToString("o")
} | ConvertTo-Json -Depth 10
Set-Content -Path "$PackageDir\version.json" -Value $VersionInfo

# Completeness guard: every required plugin must be present in the staged bundle
# before we zip. A silently-failed download (e.g. a dead upstream URL) would
# otherwise ship an incomplete bundle. Contract: Scripts/deps-expected-plugins.json.
Write-Host "[4b/5] Verifying required plugins..." -ForegroundColor Yellow
$ManifestPath = Join-Path $ProjectRoot "Scripts\deps-expected-plugins.json"
$ExpectedPlugins = (Get-Content $ManifestPath -Raw | ConvertFrom-Json)."windows-x64"
$StagedPluginDir = Join-Path "$PackageDir\vapoursynth" "vs-plugins"
$MissingPlugins = @($ExpectedPlugins | Where-Object { -not (Test-Path (Join-Path $StagedPluginDir $_)) })
if ($MissingPlugins.Count -gt 0) {
    Write-Host "ERROR: bundle is missing $($MissingPlugins.Count) required plugin(s):" -ForegroundColor Red
    $MissingPlugins | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "A plugin download likely failed - check the download-deps-windows.ps1 output above." -ForegroundColor Red
    exit 1
}
Write-Host "    All $($ExpectedPlugins.Count) required plugins present" -ForegroundColor Green

# Create zip file
Write-Host "[5/5] Creating zip archive..." -ForegroundColor Yellow
$ZipFile = Join-Path $DistDir "$PackageName.zip"
if (Test-Path $ZipFile) {
    Remove-Item $ZipFile
}
Compress-Archive -Path "$PackageDir\*" -DestinationPath $ZipFile -CompressionLevel Optimal

# Calculate sizes and SHA256
$ZipSize = (Get-Item $ZipFile).Length
$ZipSizeMB = [math]::Round($ZipSize / 1MB, 1)
$Sha256 = (Get-FileHash -Path $ZipFile -Algorithm SHA256).Hash.ToLower()

# Integrity sidecar: uploaded next to the zip. The app fetches this to verify
# the download, so sha256/size no longer need to be baked into deps-version.json
# (and re-filled on every rebuild). Keep this next to the zip with a .sha256.json
# suffix so the app can derive its URL from the zip URL.
$SidecarFile = "$ZipFile.sha256.json"
[ordered]@{
    filename = "$PackageName.zip"
    sha256   = $Sha256
    size     = $ZipSize
    version  = $Version
} | ConvertTo-Json | Set-Content -Path $SidecarFile -Encoding utf8

Write-Host ""
Write-Host "=== Packaging Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Zip file: $ZipFile" -ForegroundColor Green
Write-Host "Size: $ZipSizeMB MB"
Write-Host "SHA256: $Sha256"
Write-Host "Sidecar: $SidecarFile" -ForegroundColor Green
Write-Host ""
Write-Host "Upload BOTH the zip and its .sha256.json to the release." -ForegroundColor Yellow
Write-Host "deps-version.json only needs version/releaseTag (no sha256/size)." -ForegroundColor Yellow
Write-Host ""

# Cleanup package directory (keep just the zip)
Remove-Item -Recurse -Force $PackageDir

Write-Host "Done. Upload $ZipFile to GitHub release." -ForegroundColor Green
