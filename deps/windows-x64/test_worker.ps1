$env:PATH = "C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\python;C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\vapoursynth;C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\ffmpeg;" + $env:PATH
$env:PYTHONHOME = "C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\python"
$env:VAPOURSYNTH_PLUGIN_PATH = "C:\Users\dooze\GitHub\iDeinterlace\deps\windows-x64\vapoursynth\vs-plugins"

& C:\Users\dooze\GitHub\iDeinterlace\worker\target\release\ideinterlace-worker.exe --config "C:\Users\dooze\AppData\Local\Temp\test_job.json"
