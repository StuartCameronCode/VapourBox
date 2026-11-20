# Run one of this report's scripts with the Windows deps bundle's Python:
#   run.ps1 <deps dir> <script.py> [args...]
param([Parameter(Mandatory)][string]$Deps, [Parameter(Mandatory)][string]$Script,
      [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
$D = (Resolve-Path $Deps).Path
$vs = Join-Path $D 'vapoursynth'
$env:PYTHONHOME = $vs
$env:PYTHONPATH = Join-Path $vs 'Lib\site-packages'
$env:VAPOURSYNTH_EXTRA_PLUGIN_PATH = Join-Path $vs 'vs-plugins'
$env:PYTHONNOUSERSITE = '1'
$env:VAPOURBOX_FFMPEG = Join-Path $D 'ffmpeg\ffmpeg.exe'
if (-not $env:SCRATCH) { $env:SCRATCH = Join-Path ([IO.Path]::GetTempPath()) 'task80' }
New-Item -ItemType Directory -Force -Path $env:SCRATCH | Out-Null
Push-Location $PSScriptRoot
try { & (Join-Path $vs 'python.exe') $Script @Rest; exit $LASTEXITCODE } finally { Pop-Location }
