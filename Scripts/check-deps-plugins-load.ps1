# Check that every plugin a Windows deps bundle ships loads in the bundle's
# vspipe.exe, with the environment the worker gives it (task #116).
#
# A file being present proves nothing. deps-v1.18.0-rc3 shipped DCTFilter,
# DFTTest and FFT3DFilter in vs-plugins\ with their FFTW only in vapoursynth\.
# A plugin finds its DLLs in its own directory and the default directories:
# the directory of the *executable*, but not PATH. Under vspipe.exe (in
# Lib\site-packages\vapoursynth\) all three failed with GetLastError 126. The
# v2 CPU gate loads plugins through vapoursynth\python.exe, beside FFTW, and
# passed. So this check runs vspipe.exe, as the worker does.
#
# Fails (exit 1) when vspipe exits non-zero, when it prints any
# "Failed to load" line while autoloading, or when a file in
# deps-expected-plugins.json (and _extraFiles under vapoursynth\) is neither a
# loaded plugin nor a support DLL with no plugin entry point
# (Scripts/check-plugins-load.py).
#
# Usage: .\Scripts\check-deps-plugins-load.ps1 -DepsDir <bundle root> [-PlatformKey windows-x64]
# Called by package-deps-windows.ps1 on the staged tree before it is zipped.

param(
    [Parameter(Mandatory=$true)]
    [string]$DepsDir,
    [string]$PlatformKey = "windows-x64"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DepsDir = (Resolve-Path $DepsDir).Path
$VSDir = Join-Path $DepsDir "vapoursynth"
$PluginDir = Join-Path $VSDir "vs-plugins"
$VSPipe = Join-Path $VSDir "Lib\site-packages\vapoursynth\vspipe.exe"
if (-not (Test-Path $VSPipe)) {
    Write-Host "ERROR: vspipe.exe not found at $VSPipe" -ForegroundColor Red
    exit 1
}

$Manifest = Get-Content (Join-Path $ScriptDir "deps-expected-plugins.json") -Raw | ConvertFrom-Json
$Files = @($Manifest.$PlatformKey | ForEach-Object { Join-Path $PluginDir $_ })
# Plugins outside vs-plugins (RIFE, VSNCNN): loaded by LoadPlugin in the
# template, so the same fault would fail every job that uses them.
$Files += @($Manifest._extraFiles.$PlatformKey |
    Where-Object { $_ -and $_ -like "vapoursynth/*" -and $_ -like "*.dll" } |
    ForEach-Object { Join-Path $DepsDir ($_ -replace '/', '\') })
if ($Files.Count -eq 0) {
    Write-Host "ERROR: no $PlatformKey entry in deps-expected-plugins.json" -ForegroundColor Red
    exit 1
}

# The worker's Windows environment (DependencyLocator::build_environment,
# bin_path, python_path): nothing from the caller's Python leaks in.
$ChildEnv = @{
    "PYTHONNOUSERSITE" = "1"
    "PYTHONHOME" = $VSDir
    "PYTHONPATH" = (Join-Path $VSDir "Lib\site-packages")
    "VAPOURSYNTH_EXTRA_PLUGIN_PATH" = $PluginDir
    "PATH" = "$(Join-Path $DepsDir 'ffmpeg');$VSDir;$env:PATH"
    "VAPOURBOX_CHECK_PLUGINS" = ($Files -join ';')
}

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) "vapourbox-plugin-load-$PID"
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$OutFile = Join-Path $Tmp "stdout.txt"
$ErrFile = Join-Path $Tmp "stderr.txt"

# Start-Process inherits this process's environment; set it, run, restore.
$Saved = @{}
foreach ($k in $ChildEnv.Keys) {
    $Saved[$k] = [Environment]::GetEnvironmentVariable($k, "Process")
    [Environment]::SetEnvironmentVariable($k, $ChildEnv[$k], "Process")
}
try {
    $Proc = Start-Process -FilePath $VSPipe -NoNewWindow -Wait -PassThru `
        -ArgumentList @("-i", "`"$(Join-Path $ScriptDir 'check-plugins-load.py')`"", "-") `
        -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile
    $Code = $Proc.ExitCode
} finally {
    foreach ($k in $Saved.Keys) {
        [Environment]::SetEnvironmentVariable($k, $Saved[$k], "Process")
    }
}

$Stderr = @(Get-Content $ErrFile -ErrorAction SilentlyContinue)
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue

$Ok = @($Stderr | Where-Object { $_ -like "PLUGIN_LOAD_OK *" }).Count
$Support = @($Stderr | Where-Object { $_ -like "PLUGIN_LOAD_SUPPORT *" })
$Failed = @($Stderr | Where-Object { $_ -like "PLUGIN_LOAD_FAIL *" -or $_ -like "*Failed to load*" })

if ($Code -ne 0 -or $Failed.Count -gt 0) {
    Write-Host "ERROR: plugins do not load under vspipe.exe (exit $Code):" -ForegroundColor Red
    $Stderr | Where-Object { $_ -notlike "PLUGIN_LOAD_OK *" -and $_ -notlike "*is using API3 which is deprecated*" } |
        ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "A DLL such a plugin imports is probably not beside it in vs-plugins\ (tasks #90, #116)." -ForegroundColor Red
    exit 1
}
Write-Host "    $Ok plugin(s) load under vspipe.exe; support DLLs: $(($Support | ForEach-Object { Split-Path -Leaf ($_ -replace '^PLUGIN_LOAD_SUPPORT ', '') }) -join ', ')" -ForegroundColor Green
exit 0
