# Build the VapourBox Windows installer (Inno Setup) from an assembled package
# directory - the same tree the .zip is made from.
#
# Called by package-windows.ps1 and by build-windows.yml, so there is one
# definition of the installer however the package directory was assembled.
#
# Prerequisites:
# - Inno Setup 6 (https://jrsoftware.org/isdl.php). ISCC.exe is found on PATH,
#   in the default install locations, or via $env:ISCC.
#
# Usage: .\Scripts\build-windows-installer.ps1 -Version "0.1.0" -SourceDir dist\VapourBox-0.1.0-windows-x64

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$IssFile = Join-Path $ProjectRoot "packaging\windows\vapourbox.iss"
if (-not $OutputDir) { $OutputDir = Join-Path $ProjectRoot "dist" }

if (-not (Test-Path $SourceDir)) { throw "Package directory not found: $SourceDir" }
$SourceDir = (Resolve-Path $SourceDir).Path
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path

# An installer built from an incomplete tree installs cleanly and then fails
# on the first video dropped, so check for the pieces before compiling.
foreach ($required in @(
        "vapourbox.exe",
        "vapourbox-worker.exe",
        "templates\pipeline_template.vpy",
        "templates\preview_template.vpy",
        "templates\pipe_source.py",
        "data\flutter_assets")) {
    if (-not (Test-Path (Join-Path $SourceDir $required))) {
        throw "Package directory is incomplete: $required is missing from $SourceDir"
    }
}

$Iscc = $null
$Candidates = @(
    $env:ISCC,
    (Get-Command "ISCC.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
)
foreach ($candidate in $Candidates) {
    if ($candidate -and (Test-Path $candidate)) { $Iscc = $candidate; break }
}
if (-not $Iscc) {
    throw "Inno Setup 6 (ISCC.exe) not found. Install it from https://jrsoftware.org/isdl.php, or set `$env:ISCC to its path."
}

$Installer = Join-Path $OutputDir "VapourBox-$Version-windows-x64-setup.exe"
if (Test-Path $Installer) { Remove-Item $Installer }

Write-Host "Building installer with $Iscc" -ForegroundColor Yellow
& $Iscc /Qp "/DAppVersion=$Version" "/DSourceDir=$SourceDir" "/DOutputDir=$OutputDir" $IssFile
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }
if (-not (Test-Path $Installer)) { throw "Inno Setup reported success but $Installer was not created" }

$SizeMb = [math]::Round((Get-Item $Installer).Length / 1MB, 1)
$Sha256 = (Get-FileHash -Algorithm SHA256 $Installer).Hash.ToLower()
Write-Host "Installer: $Installer" -ForegroundColor Green
Write-Host "Size:      $SizeMb MB"
Write-Host "SHA256:    $Sha256"
