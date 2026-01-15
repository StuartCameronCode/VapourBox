# Package VapourBox for Windows
# Creates a standalone zip file with all dependencies
#
# Prerequisites:
# - Flutter SDK installed
# - Rust toolchain installed
# - Dependencies downloaded (run download-deps-windows.ps1 first)
#
# Usage: .\Scripts\package-windows.ps1

param(
    [string]$Version = "1.0.0",
    [switch]$SkipBuild = $false
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$DistDir = Join-Path $ProjectRoot "dist"
$AppName = "VapourBox"
$PackageDir = Join-Path $DistDir "$AppName-$Version-windows-x64"

# Find and add Flutter to PATH if not already available
$FlutterPaths = @(
    "C:\dev\flutter\bin",
    "C:\flutter\bin",
    "C:\tools\flutter\bin",
    "C:\Users\$env:USERNAME\flutter\bin",
    "$env:LOCALAPPDATA\flutter\bin"
)
foreach ($fp in $FlutterPaths) {
    if (Test-Path "$fp\flutter.bat") {
        $env:PATH = "$fp;$env:PATH"
        break
    }
}

Write-Host "=== Packaging VapourBox for Windows ===" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
Write-Host "[1/7] Checking prerequisites..." -ForegroundColor Yellow

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

# Build Rust worker
if (-not $SkipBuild) {
    Write-Host "[2/7] Building Rust worker..." -ForegroundColor Yellow
    Push-Location (Join-Path $ProjectRoot "worker")
    try {
        cargo build --release
        if ($LASTEXITCODE -ne 0) { throw "Rust build failed" }
    } finally {
        Pop-Location
    }
    Write-Host "    Rust worker built" -ForegroundColor Green

    # Build Flutter app
    Write-Host "[3/7] Building Flutter app..." -ForegroundColor Yellow
    Push-Location (Join-Path $ProjectRoot "app")
    try {
        flutter pub get
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "Flutter build failed" }
    } finally {
        Pop-Location
    }
    Write-Host "    Flutter app built" -ForegroundColor Green
} else {
    Write-Host "[2/7] Skipping Rust build (--SkipBuild)" -ForegroundColor Gray
    Write-Host "[3/7] Skipping Flutter build (--SkipBuild)" -ForegroundColor Gray
}

# Create package directory structure
Write-Host "[4/7] Creating package structure..." -ForegroundColor Yellow
if (Test-Path $PackageDir) {
    Remove-Item -Recurse -Force $PackageDir
}
New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
New-Item -ItemType Directory -Force -Path "$PackageDir\deps\windows-x64\ffmpeg" | Out-Null
New-Item -ItemType Directory -Force -Path "$PackageDir\templates" | Out-Null

# Copy Flutter app
Write-Host "[5/7] Copying Flutter app..." -ForegroundColor Yellow
$FlutterBuildDir = Join-Path $ProjectRoot "app\build\windows\x64\runner\Release"
if (-not (Test-Path $FlutterBuildDir)) {
    Write-Host "ERROR: Flutter release build not found at $FlutterBuildDir" -ForegroundColor Red
    exit 1
}
Copy-Item -Recurse -Force "$FlutterBuildDir\*" "$PackageDir\"

# Copy Rust worker
Write-Host "    Copying Rust worker..."
$WorkerExe = Join-Path $ProjectRoot "worker\target\release\vapourbox-worker.exe"
if (-not (Test-Path $WorkerExe)) {
    Write-Host "ERROR: Worker executable not found at $WorkerExe" -ForegroundColor Red
    exit 1
}
Copy-Item $WorkerExe "$PackageDir\"

# Copy VapourSynth script templates
Copy-Item (Join-Path $ProjectRoot "worker\templates\pipeline_template.vpy") "$PackageDir\templates\"
Copy-Item (Join-Path $ProjectRoot "worker\templates\preview_template.vpy") "$PackageDir\templates\"

# Copy dependencies
Write-Host "[6/7] Copying dependencies..." -ForegroundColor Yellow

# VapourSynth - copy entire directory
Write-Host "    Copying VapourSynth..."
$VSDir = Join-Path $DepsDir "vapoursynth"

# Remove the pre-created directory and copy the whole thing
Remove-Item -Recurse -Force "$PackageDir\deps\windows-x64\vapoursynth" -ErrorAction SilentlyContinue
Copy-Item -Recurse -Force $VSDir "$PackageDir\deps\windows-x64\vapoursynth"

# Remove unnecessary files to reduce size (keep portable.vs - required for portable mode!)
$UnnecessaryFiles = @(
    "7z.exe", "7z.dll", "AVFS.exe", "VSVFW.dll",
    "pfm-192-vapoursynth-win.exe", "vsrepo.py", "vsgenstubs.py",
    "MANIFEST.in"
)
foreach ($file in $UnnecessaryFiles) {
    $path = Join-Path "$PackageDir\deps\windows-x64\vapoursynth" $file
    if (Test-Path $path) { Remove-Item $path -Force }
}

# Remove unnecessary directories (keep vs-coreplugins to avoid warning)
$UnnecessaryDirs = @("doc", "sdk", "vsgenstubs4", "wheel")
foreach ($dir in $UnnecessaryDirs) {
    $path = Join-Path "$PackageDir\deps\windows-x64\vapoursynth" $dir
    if (Test-Path $path) { Remove-Item -Recurse -Force $path }
}

# Remove __pycache__ directories recursively
Get-ChildItem -Path "$PackageDir\deps\windows-x64\vapoursynth" -Directory -Recurse -Filter "__pycache__" | Remove-Item -Recurse -Force

# Remove development files from site-packages
$DevDirs = @("cython", "vsscript")
foreach ($dir in $DevDirs) {
    $path = Join-Path "$PackageDir\deps\windows-x64\vapoursynth\Lib\site-packages" $dir
    if (Test-Path $path) { Remove-Item -Recurse -Force $path }
}

# Remove temporary files (tmpclaude-*, etc.)
Get-ChildItem -Path "$PackageDir\deps\windows-x64\vapoursynth" -Recurse -Filter "tmpclaude-*" | Remove-Item -Force

# FFmpeg
Write-Host "    Copying FFmpeg..."
Copy-Item (Join-Path $DepsDir "ffmpeg\ffmpeg.exe") "$PackageDir\deps\windows-x64\ffmpeg\"
Copy-Item (Join-Path $DepsDir "ffmpeg\ffprobe.exe") "$PackageDir\deps\windows-x64\ffmpeg\" -ErrorAction SilentlyContinue

# Copy licenses
Write-Host "    Copying licenses..."
Copy-Item -Path "$ProjectRoot\licenses" -Destination "$PackageDir\licenses" -Recurse
Copy-Item -Path "$ProjectRoot\LICENSE" -Destination "$PackageDir\LICENSE"

# Create launcher batch file
Write-Host "    Creating launcher..."
$LauncherContent = @"
@echo off
cd /d "%~dp0"
start "" "%~dp0vapourbox.exe"
"@
Set-Content -Path "$PackageDir\Launch VapourBox.bat" -Value $LauncherContent

# Create README
$ReadmeContent = @"
VapourBox v$Version for Windows
===============================

Video restoration and cleanup powered by VapourSynth.
By Stuart Cameron - https://stuart-cameron.com

Getting Started
---------------
1. Double-click "Launch VapourBox.bat" or "vapourbox.exe"
2. Drag and drop a video file onto the window
3. Configure restoration passes as needed
4. Click "Go" to start processing

Requirements
------------
- Windows 10 or later (64-bit)
- No additional software required - all dependencies are bundled

Contents
--------
- vapourbox.exe       : Main application
- vapourbox-worker.exe: Processing worker
- deps/windows-x64/   : Bundled dependencies (VapourSynth, FFmpeg, etc.)
- templates/          : VapourSynth script templates

For more information, visit:
https://github.com/stuartcameron/VapourBox
"@
Set-Content -Path "$PackageDir\README.txt" -Value $ReadmeContent

# Create zip file
Write-Host "[7/7] Creating zip archive..." -ForegroundColor Yellow
$ZipFile = Join-Path $DistDir "$AppName-$Version-windows-x64.zip"
if (Test-Path $ZipFile) {
    Remove-Item $ZipFile
}
Compress-Archive -Path "$PackageDir\*" -DestinationPath $ZipFile -CompressionLevel Optimal

# Calculate sizes
$PackageSize = (Get-ChildItem -Recurse $PackageDir | Measure-Object -Property Length -Sum).Sum / 1MB
$ZipSize = (Get-Item $ZipFile).Length / 1MB

Write-Host ""
Write-Host "=== Packaging Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Package directory: $PackageDir" -ForegroundColor Green
Write-Host "Zip file: $ZipFile" -ForegroundColor Green
Write-Host ""
Write-Host "Package size: $([math]::Round($PackageSize, 1)) MB"
Write-Host "Zip size: $([math]::Round($ZipSize, 1)) MB"
Write-Host ""
Write-Host "To distribute, share the zip file:"
Write-Host "  $ZipFile"
