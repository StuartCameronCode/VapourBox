# VirtualDub 1.10.4 and VirtualDub2 over the AVI fixtures (F6 of ../../index.html).
#
#   pwsh virtualdub.ps1 -Work <scratch> -Tools <dir with vd1104\ and vd2\ unpacked>
#
# For each fixture and each VirtualDub: open it, save its audio with "Direct
# stream copy" and again with "Full processing mode" (no conversion asked for),
# by running the GUI executable with a script (/s script /x). Writes
# $Work\vdub\<tool>_<mode>_<fixture>.wav and a .status file saying how the run
# ended. A run that does not finish in 60 s is killed after a screenshot of the
# desktop ($Work\vdub\<...>.png) and a list of the process's windows, visible
# or not: VirtualDub reports errors in modal dialogs.
#
# Each VirtualDub shows its GPL licence on first run, recording that it did
# before the dialog opens (license.cpp), so one warm-up run per tool, killed,
# gets it out of the way.
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

Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class Win {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  static string Text(IntPtr h) { var t = new StringBuilder(2048); GetWindowText(h, t, 2048); return t.ToString(); }
  // Every top-level window of these processes, with the text of its controls:
  // what a modal dialog says.
  public static string Titles(HashSet<uint> pids) {
    var sb = new StringBuilder();
    EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid);
      string t = Text(h);
      if (pids.Contains(pid) && t.Length > 0 && t != "Default IME" && t != "MSCTFIME UI") {
        sb.Append((IsWindowVisible(h) ? "[visible] " : "[hidden] ") + t + " {");
        EnumChildWindows(h, (c, l2) => { string ct = Text(c).Replace("\r", " ").Replace("\n", " ");
          if (ct.Length > 0 && ct.Length < 600) sb.Append(" | " + ct); return true; }, IntPtr.Zero);
        sb.Append(" }; "); }
      return true; }, IntPtr.Zero);
    return sb.ToString();
  }
  // First-run dialogs: press the button that carries on. Returns what it clicked.
  public static string Dismiss(HashSet<uint> pids, string[] buttons) {
    string done = "";
    EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid);
      if (!pids.Contains(pid) || !IsWindowVisible(h)) return true;
      string title = Text(h);
      EnumChildWindows(h, (c, l2) => { var cls = new StringBuilder(64); GetClassName(c, cls, 64);
        string ct = Text(c).Replace("&", "");
        if (cls.ToString() == "Button" && Array.IndexOf(buttons, ct) >= 0) {
          SendMessage(c, 0x00F5 /* BM_CLICK */, IntPtr.Zero, IntPtr.Zero);
          done += title + " -> " + ct + "; "; return false; }
        return true; }, IntPtr.Zero);
      return true; }, IntPtr.Zero);
    return done;
  }
}
'@

function VdProcs { Get-Process | Where-Object { $_.ProcessName -match '^(vdub|Veedub|VirtualDub)' } }

function Esc([string]$p) { $p.Replace('\', '\\') }

$exes = @{ vd1104 = (Join-Path $Tools 'vd1104\Veedub64.exe'); vd2 = (Join-Path $Tools 'vd2\VirtualDub64.exe') }

# Run one script; returns how it ended.
function RunVd([string]$tool, [string]$stem, [int]$timeoutMs) {
  $p = Start-Process -FilePath $exes[$tool] -ArgumentList '/s', "`"$stem.vdscript`"", '/x' -PassThru
  if ($p.WaitForExit($timeoutMs)) { return "exit $($p.ExitCode)" }
  Screenshot "$stem.png"
  $pids = New-Object 'System.Collections.Generic.HashSet[uint32]'
  VdProcs | ForEach-Object { [void]$pids.Add([uint32]$_.Id) }
  $titles = [Win]::Titles($pids)
  VdProcs | Stop-Process -Force
  Start-Sleep -Seconds 1
  return "timed out (killed); windows: $titles"
}

# Warm-up: open the control file, clicking through the first-run dialogs
# (1.10.4's "Before we start..." welcome, either one's licence), so the
# measured runs start as an established install would.
$carryOn = @('Start VirtualDub', 'I agree', 'Agree', 'Accept', 'OK')
foreach ($tool in 'vd1104', 'vd2') {
  $stem = Join-Path $out "${tool}_warmup"
  Set-Content -Path "$stem.vdscript" -Value "VirtualDub.Open(`"$(Esc (Join-Path $Work 'avi\ffv1_s16.avi'))`");" -Encoding ascii
  $p = Start-Process -FilePath $exes[$tool] -ArgumentList '/s', "`"$stem.vdscript`"", '/x' -PassThru
  $clicked = ''
  for ($i = 0; $i -lt 30 -and -not $p.HasExited; $i++) {
    Start-Sleep -Seconds 2
    $pids = New-Object 'System.Collections.Generic.HashSet[uint32]'
    VdProcs | ForEach-Object { [void]$pids.Add([uint32]$_.Id) }
    $clicked += [Win]::Dismiss($pids, $carryOn)
  }
  if ($p.HasExited) { $status = "exit $($p.ExitCode)" } else {
    Screenshot "$stem.png"; $status = 'still running after 60 s (killed)'; VdProcs | Stop-Process -Force; Start-Sleep 1 }
  Set-Content -Path "$stem.status" -Value "$status; clicked: $clicked"
  Write-Host "$tool warm-up : $status; clicked: $clicked"
}
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
      $status = RunVd $tool $stem 60000
      if (-not (Test-Path $wav)) { $status += '; no WAV written' }
      Set-Content -Path "$stem.status" -Value $status
      Write-Host "$tool $mode $fx : $status"
    }
  }
}
