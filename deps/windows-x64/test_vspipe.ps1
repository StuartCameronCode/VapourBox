$env:PATH = "C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\python;C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\vapoursynth;" + $env:PATH
$env:PYTHONHOME = "C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\python"
$env:VAPOURSYNTH_PLUGIN_PATH = "C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\vapoursynth\vs-plugins"

Write-Host "Testing VSPipe..."
& C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\vapoursynth\VSPipe.exe --version
