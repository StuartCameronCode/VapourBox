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

if (-not (Test-Path (Join-Path $DepsDir "vapoursynth\VSPipe.exe"))) {
    Write-Host "ERROR: VapourSynth not found in dependencies" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path (Join-Path $DepsDir "ffmpeg\ffmpeg.exe"))) {
    Write-Host "ERROR: FFmpeg not found in dependencies" -ForegroundColor Red
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

# Remove development files from site-packages
$DevDirs = @("cython", "vsscript")
foreach ($dir in $DevDirs) {
    $path = Join-Path "$PackageDir\vapoursynth\Lib\site-packages" $dir
    if (Test-Path $path) { Remove-Item -Recurse -Force $path }
}

# Remove temporary files
Get-ChildItem -Path "$PackageDir\vapoursynth" -Recurse -Filter "tmpclaude-*" | Remove-Item -Force

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

Write-Host ""
Write-Host "=== Packaging Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Zip file: $ZipFile" -ForegroundColor Green
Write-Host "Size: $ZipSizeMB MB"
Write-Host "SHA256: $Sha256"
Write-Host ""
Write-Host "Update deps-version.json with:" -ForegroundColor Yellow
Write-Host @"
{
  "version": "$Version",
  "platforms": {
    "windows-x64": {
      "filename": "$PackageName.zip",
      "sha256": "$Sha256",
      "size": $ZipSize
    }
  }
}
"@
Write-Host ""

# Cleanup package directory (keep just the zip)
Remove-Item -Recurse -Force $PackageDir

Write-Host "Done. Upload $ZipFile to GitHub release." -ForegroundColor Green
