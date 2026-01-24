# Package VapourBox App for Windows (without dependencies)
# Creates a standalone zip file with the app only
# Dependencies are packaged separately with package-deps-windows.ps1
#
# Prerequisites:
# - Flutter SDK installed
# - Rust toolchain installed
#
# Usage: .\Scripts\package-windows.ps1 -Version "0.1.0"

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
Write-Host "[1/5] Checking prerequisites..." -ForegroundColor Yellow
Write-Host "    Prerequisites OK" -ForegroundColor Green

# Build Rust worker
if (-not $SkipBuild) {
    Write-Host "[2/5] Building Rust worker..." -ForegroundColor Yellow
    Push-Location (Join-Path $ProjectRoot "worker")
    try {
        cargo build --release
        if ($LASTEXITCODE -ne 0) { throw "Rust build failed" }
    } finally {
        Pop-Location
    }
    Write-Host "    Rust worker built" -ForegroundColor Green

    # Build Flutter app
    Write-Host "[3/5] Building Flutter app..." -ForegroundColor Yellow
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
    Write-Host "[2/5] Skipping Rust build (--SkipBuild)" -ForegroundColor Gray
    Write-Host "[3/5] Skipping Flutter build (--SkipBuild)" -ForegroundColor Gray
}

# Create package directory structure
Write-Host "[4/5] Creating package structure..." -ForegroundColor Yellow
if (Test-Path $PackageDir) {
    Remove-Item -Recurse -Force $PackageDir
}
New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
New-Item -ItemType Directory -Force -Path "$PackageDir\templates" | Out-Null

# Copy Flutter app
Write-Host "    Copying Flutter app..." -ForegroundColor Yellow
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
2. On first launch, required components will be downloaded automatically
3. Drag and drop a video file onto the window
4. Configure restoration passes as needed
5. Click "Go" to start processing

Requirements
------------
- Windows 10 or later (64-bit)
- Internet connection for first-time setup (~185 MB download)

Contents
--------
- vapourbox.exe       : Main application
- vapourbox-worker.exe: Processing worker
- templates/          : VapourSynth script templates

For more information, visit:
https://github.com/StuartCameronCode/VapourBox
"@
Set-Content -Path "$PackageDir\README.txt" -Value $ReadmeContent

# Create zip file
Write-Host "[5/5] Creating zip archive..." -ForegroundColor Yellow
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
