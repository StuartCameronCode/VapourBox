# VirtualDub 1.10.4 and VirtualDub2 over the AVI fixtures (F6 of ../../index.html).
#
#   pwsh virtualdub.ps1 -Work <scratch> -Tools <dir with vd1104\ and vd2\ unpacked>
#
# For each fixture and each VirtualDub: open it, save its audio with "Direct
# stream copy" and again with "Full processing mode" (no conversion asked for),
# via the command-line driver (vdub64.exe /s script /x). Writes
# $Work\vdub\<tool>_<mode>_<fixture>.wav and a .status file saying how the run
# ended. A run that does not finish in 90 s is killed after a screenshot of the
# desktop ($Work\vdub\<...>.png): VirtualDub reports errors in modal dialogs.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Tools)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$out = Join-Path $Work 'vdub'
New-Item -ItemType Directory -Force $out | Out-Null

function Screenshot([string]$path) {
  try {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  } catch { "screenshot failed: $_" | Write-Host }
}

function Esc([string]$p) { $p.Replace('\', '\\') }

$exes = @{ vd1104 = (Join-Path $Tools 'vd1104\vdub64.exe'); vd2 = (Join-Path $Tools 'vd2\vdub64.exe') }
foreach ($fx in 'ffv1_s24', 'huffyuv_s24', 'h264_s24', 'ffv1_s16') {
  $avi = Join-Path $Work "avi\$fx.avi"
  foreach ($tool in 'vd1104', 'vd2') {
    foreach ($mode in 'direct', 'full') {
      $stem = Join-Path $out "${tool}_${mode}_$fx"
      $wav = "$stem.wav"
      $m = if ($mode -eq 'direct') { 0 } else { 1 }
      $script = @"
VirtualDub.Open("$(Esc $avi)");
VirtualDub.audio.SetSource(1);
VirtualDub.audio.SetMode($m);
VirtualDub.audio.SetConversion(0, 0, 0, 0, 0);
VirtualDub.SaveWAV("$(Esc $wav)");
"@
      Set-Content -Path "$stem.vdscript" -Value $script -Encoding ascii
      $p = Start-Process -FilePath $exes[$tool] -ArgumentList '/s', "`"$stem.vdscript`"", '/x' `
             -RedirectStandardOutput "$stem.log" -RedirectStandardError "$stem.err" -PassThru -WindowStyle Normal
      if ($p.WaitForExit(90000)) {
        $status = "exit $($p.ExitCode)"
      } else {
        Screenshot "$stem.png"
        Get-Process | Where-Object { $_.ProcessName -match '^(vdub|Veedub|VirtualDub)' } | Stop-Process -Force
        $status = 'timed out (killed; see screenshot)'
      }
      if (-not (Test-Path $wav)) { $status += '; no WAV written' }
      Set-Content -Path "$stem.status" -Value $status
      Write-Host "$tool $mode $fx : $status"
    }
  }
}
