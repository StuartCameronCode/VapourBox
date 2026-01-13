# Package iDeinterlace for Windows
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
$AppName = "iDeinterlace"
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

Write-Host "=== Packaging iDeinterlace for Windows ===" -ForegroundColor Cyan
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
$WorkerExe = Join-Path $ProjectRoot "worker\target\release\ideinterlace-worker.exe"
if (-not (Test-Path $WorkerExe)) {
    Write-Host "ERROR: Worker executable not found at $WorkerExe" -ForegroundColor Red
    exit 1
}
Copy-Item $WorkerExe "$PackageDir\"

# Copy VapourSynth script templates
Copy-Item (Join-Path $ProjectRoot "worker\templates\qtgmc_template.vpy") "$PackageDir\templates\"
Copy-Item (Join-Path $ProjectRoot "worker\templates\pipeline_template.vpy") "$PackageDir\templates\"

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

# FFmpeg
Write-Host "    Copying FFmpeg..."
Copy-Item (Join-Path $DepsDir "ffmpeg\ffmpeg.exe") "$PackageDir\deps\windows-x64\ffmpeg\"
Copy-Item (Join-Path $DepsDir "ffmpeg\ffprobe.exe") "$PackageDir\deps\windows-x64\ffmpeg\" -ErrorAction SilentlyContinue

# Create launcher batch file
Write-Host "    Creating launcher..."
$LauncherContent = @"
@echo off
cd /d "%~dp0"
start "" "%~dp0ideinterlace.exe"
"@
Set-Content -Path "$PackageDir\Launch iDeinterlace.bat" -Value $LauncherContent

# Create README
$ReadmeContent = @"
iDeinterlace v$Version for Windows
==================================

A video deinterlacing application using QTGMC via VapourSynth.

Getting Started
---------------
1. Double-click "Launch iDeinterlace.bat" or "ideinterlace.exe"
2. Drag and drop an interlaced video file onto the window
3. Click "Process" to start deinterlacing
4. The output will be saved with "_deinterlaced" suffix

Requirements
------------
- Windows 10 or later (64-bit)
- No additional software required - all dependencies are bundled

Contents
--------
- ideinterlace.exe       : Main application
- ideinterlace-worker.exe: Processing worker
- deps/windows-x64/      : Bundled dependencies (VapourSynth, FFmpeg, etc.)
- templates/             : VapourSynth script templates

For more information, visit:
https://github.com/stuartcameron/iDeinterlace
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
