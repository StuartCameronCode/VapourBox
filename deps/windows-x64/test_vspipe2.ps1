$env:PATH = "C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\python;C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\vapoursynth;C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\ffmpeg;" + $env:PATH
$env:PYTHONHOME = "C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\python"
$env:VAPOURSYNTH_PLUGIN_PATH = "C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\vapoursynth\vs-plugins"

$scriptPath = "C:\Users\dooze\AppData\Local\Temp\550e8400-e29b-41d4-a716-446655440000.vpy"
if (Test-Path $scriptPath) {
    Write-Host "=== Script contents ==="
    Get-Content $scriptPath
    Write-Host ""
    Write-Host "=== Running vspipe ==="
    & C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\vapoursynth\VSPipe.exe --info $scriptPath -
} else {
    Write-Host "Script not found at $scriptPath"
}
