<#
Task #122: why vspipe hangs in ExitProcess after a Stabilize pitch-auto
preview on Windows, measured by running the worker's preview directly in a
loop (a few seconds a run, against ~3 min a run through flutter test).

Each arm changes one thing about the machine or the job and runs the same
preview -Iterations times, one at a time, each with a -TimeoutSec limit.
Every run's stderr is kept (the worker echoes vspipe's lines as they
arrive, with a timestamp). A run still going at the limit is a hang, and is
examined before anything touches it:

  1. the process tree, and vspipe's last lines;
  2. vspipe's threads as the kernel sees them (state, wait reason) and
     whether the process has exited;
  3. Windows Error Reporting: WerFault processes, and Application events
     1000/1001/1005 since the run started;
  4. cdb's stacks of vspipe (non-invasive);
  5. experiment a: resume every thread of vspipe (NtResumeProcess), and
     see whether it exits within 10 s;
  6. experiment b: if not, TerminateProcess it, and see whether it exits
     within 10 s and whether the worker then returns.

Arms (comma-separated in -Arms; each restores what it changed):
  baseline      the pitch-auto job, the guard off (grace 0 = wait forever)
  localdumps    + WER LocalDumps for vspipe.exe (full dumps into -OutDir)
  weroff        + WER disabled (Disabled=1, DontShowUI=1)
  defenderoff   + Defender real-time monitoring off
  wheelvspipe   + the VapourSynth R78 wheel's own vspipe.exe instead of
                  the bundle's Zig build (task #68), via VAPOURBOX_VSPIPE
  weave         the weave-only job (pitch off), guard off
  passthrough   no pass at all, guard off
  guard         the pitch-auto job with the guard at its default (30 s):
                a hang becomes a stopped vspipe, counted from the log

Writes <OutDir>/summary.tsv, summary.md and a directory per hang.
#>
param(
    [Parameter(Mandatory)] [string] $Worker,
    [Parameter(Mandatory)] [string] $JobsDir,
    [Parameter(Mandatory)] [string] $OutDir,
    [string] $Arms = 'baseline,localdumps,weroff,defenderoff,wheelvspipe,weave,passthrough,guard',
    [int] $Iterations = 200,
    [int] $TimeoutSec = 60,
    [string] $WheelVspipe = ''
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$frame = (Get-Content (Join-Path $JobsDir 'frame.txt')).Trim()
$cdb = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Nt {
    [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@

function Get-Tree([int] $root) {
    $all = Get-CimInstance Win32_Process
    $ids = @($root)
    $added = $true
    while ($added) {
        $added = $false
        foreach ($p in $all) {
            if ($ids -contains $p.ParentProcessId -and -not ($ids -contains $p.ProcessId)) {
                $ids += $p.ProcessId; $added = $true
            }
        }
    }
    $all | Where-Object { $ids -contains $_.ProcessId }
}

function Stop-Tree([int] $root) {
    foreach ($p in (Get-Tree $root)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Wait-Gone([int] $id, [int] $seconds) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $seconds) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $p -or $p.HasExited) { return [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Threads([int] $id) {
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if (-not $p) { return 'process gone' }
    $p.Refresh()
    "HasExited=$($p.HasExited) Threads=$($p.Threads.Count)"
    $p.Threads | ForEach-Object {
        $wr = try { $_.WaitReason } catch { '-' }
        "  tid $($_.Id) state=$($_.ThreadState) wait=$wr"
    }
}

function Examine-Hang([int] $workerPid, [string] $errFile, [string] $dir, [datetime] $since) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $report = Join-Path $dir 'hang.txt'
    $tree = @(Get-Tree $workerPid)
    "== process tree" | Out-File $report
    $tree | ForEach-Object { "$($_.ProcessId) <- $($_.ParentProcessId)  $($_.Name)  $($_.CommandLine)" } | Out-File $report -Append
    "== worker stderr (vspipe lines are echoed as they arrive)" | Out-File $report -Append
    if (Test-Path $errFile) { Get-Content $errFile | Out-File $report -Append }
    $vspipe = $tree | Where-Object { $_.Name -like 'vspipe*' } | Select-Object -First 1
    $final = if (Test-Path $errFile) {
        Select-String -Path $errFile -Pattern 'vspipe: \+.*(Output \d+ (frames|samples) in|Script evaluation failed|Failed to retrieve output node|Error: )' |
            Select-Object -Last 1 | ForEach-Object { $_.Line }
    }
    $verdict = [ordered]@{ final_line = "$final"; vspipe = ''; resumed_exit_s = ''; killed_exit_s = ''; worker_after_kill = ''; wer = '' }
    if ($vspipe) {
        $id = [int]$vspipe.ProcessId
        $verdict.vspipe = "$id"
        "== vspipe $id threads (kernel view)" | Out-File $report -Append
        Threads $id | Out-File $report -Append
        "== WER processes" | Out-File $report -Append
        $wer = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^Wer' })
        $wer | ForEach-Object { "$($_.ProcessId) $($_.Name) $($_.CommandLine)" } | Out-File $report -Append
        $verdict.wer = ($wer | Where-Object { $_.CommandLine -match "-p $id\b" } | Measure-Object).Count
        "== Application events 1000/1001/1005 since the run started" | Out-File $report -Append
        try {
            Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1001, 1005; StartTime = $since } -ErrorAction Stop |
                ForEach-Object { "$($_.TimeCreated) $($_.Id) $($_.ProviderName)`n$($_.Message)" } | Out-File $report -Append
        } catch { "none ($($_.Exception.Message))" | Out-File $report -Append }
        if (Test-Path $cdb) {
            "== cdb -pv stacks of vspipe" | Out-File $report -Append
            $c = Start-Process -FilePath $cdb -ArgumentList @('-pv', '-p', "$id", '-c', '"~*kb 40; qd"') `
                -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $dir 'cdb.txt') -RedirectStandardError (Join-Path $dir 'cdb.err')
            if (-not $c.WaitForExit(60000)) { Stop-Process -Id $c.Id -Force -ErrorAction SilentlyContinue; "cdb timed out" | Out-File $report -Append }
            Get-Content (Join-Path $dir 'cdb.txt') -ErrorAction SilentlyContinue | Out-File $report -Append
        }
        "== experiment a: NtResumeProcess" | Out-File $report -Append
        $h = [Nt]::OpenProcess(0x1F0FFF, $false, $id)
        if ($h -ne [IntPtr]::Zero) {
            $st = [Nt]::NtResumeProcess($h)
            "NtResumeProcess status 0x{0:X8}" -f $st | Out-File $report -Append
            $verdict.resumed_exit_s = "$(Wait-Gone $id 10)"
            "exited after resume: '$($verdict.resumed_exit_s)' s (empty = still there)" | Out-File $report -Append
            if (-not $verdict.resumed_exit_s) {
                Threads $id | Out-File $report -Append
                "== experiment b: TerminateProcess" | Out-File $report -Append
                $ok = [Nt]::TerminateProcess($h, 1)
                "TerminateProcess returned $ok (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" | Out-File $report -Append
                $verdict.killed_exit_s = "$(Wait-Gone $id 10)"
                "exited after terminate: '$($verdict.killed_exit_s)' s" | Out-File $report -Append
                if (-not $verdict.killed_exit_s) { Threads $id | Out-File $report -Append }
            }
            [Nt]::CloseHandle($h) | Out-Null
        } else {
            "OpenProcess failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" | Out-File $report -Append
        }
        $w = Wait-Gone $workerPid 20
        $verdict.worker_after_kill = if ($w) { "returned after $w s" } else { 'still running' }
        "worker: $($verdict.worker_after_kill)" | Out-File $report -Append
    } else {
        "no vspipe in the tree" | Out-File $report -Append
    }
    Stop-Tree $workerPid
    "== verdict" | Out-File $report -Append
    ($verdict.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n" | Out-File $report -Append
    return $verdict
}

# --- arm set-up and tear-down -------------------------------------------------

$werKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
$dumpKey = "$werKey\LocalDumps\vspipe.exe"

function Arm-Setup([string] $arm) {
    $env:VAPOURBOX_VSPIPE = ''
    $env:VAPOURBOX_VSPIPE_EXIT_GRACE_SECS = '0'
    switch ($arm) {
        'localdumps' {
            $d = Join-Path $OutDir 'dumps'; New-Item -ItemType Directory -Force -Path $d | Out-Null
            New-Item -Force -Path $dumpKey | Out-Null
            Set-ItemProperty -Path $dumpKey -Name DumpFolder -Value $d -Type ExpandString
            Set-ItemProperty -Path $dumpKey -Name DumpType -Value 2 -Type DWord
            Set-ItemProperty -Path $dumpKey -Name DumpCount -Value 20 -Type DWord
        }
        'weroff' {
            Set-ItemProperty -Path $werKey -Name Disabled -Value 1 -Type DWord
            Set-ItemProperty -Path $werKey -Name DontShowUI -Value 1 -Type DWord
        }
        'defenderoff' {
            try { Set-MpPreference -DisableRealtimeMonitoring $true } catch { "Set-MpPreference failed: $_" }
        }
        'wheelvspipe' {
            if (-not $WheelVspipe -or -not (Test-Path $WheelVspipe)) { throw "wheelvspipe needs -WheelVspipe" }
            $env:VAPOURBOX_VSPIPE = $WheelVspipe
        }
        'guard' { Remove-Item Env:\VAPOURBOX_VSPIPE_EXIT_GRACE_SECS }
    }
}

function Arm-Teardown([string] $arm) {
    switch ($arm) {
        'localdumps' { Remove-Item -Force -Recurse -Path $dumpKey -ErrorAction SilentlyContinue }
        'weroff' {
            Remove-ItemProperty -Path $werKey -Name Disabled -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $werKey -Name DontShowUI -ErrorAction SilentlyContinue
        }
        'defenderoff' { try { Set-MpPreference -DisableRealtimeMonitoring $false } catch {} }
    }
}

function Arm-Job([string] $arm) {
    switch ($arm) {
        'weave' { return Join-Path $JobsDir 'weave.json' }
        'passthrough' { return Join-Path $JobsDir 'passthrough.json' }
        default { return Join-Path $JobsDir 'pitch.json' }
    }
}

# --- the loop -----------------------------------------------------------------

"arm`truns`tok`tfailed`thung`tguard_stops`tunkillable`tmedian_s`tmax_s" | Out-File (Join-Path $OutDir 'summary.tsv')
$md = @("| arm | runs | ok | failed | hung | guard stops | unkillable | median s | max s |", "|---|---|---|---|---|---|---|---|---|")
$hangRows = @()

foreach ($arm in ($Arms -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    Write-Host "=== arm $arm"
    Arm-Setup $arm
    "--- $arm`nDefender: $((Get-MpComputerStatus -ErrorAction SilentlyContinue | Select-Object RealTimeProtectionEnabled, AMRunningMode | Out-String).Trim())" |
        Out-File (Join-Path $OutDir 'arms.txt') -Append
    $armDir = Join-Path $OutDir $arm; New-Item -ItemType Directory -Force -Path $armDir | Out-Null
    $job = Arm-Job $arm
    $times = @(); $ok = 0; $failed = 0; $hung = 0; $stops = 0; $unkillable = 0
    try {
        for ($k = 1; $k -le $Iterations; $k++) {
            $err = Join-Path $armDir "run$k.err"
            $out = Join-Path $armDir "run$k.png"
            $since = Get-Date
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $p = Start-Process -FilePath $Worker -NoNewWindow -PassThru `
                -ArgumentList @('--config', $job, '--preview', '--frame', $frame, '--sub-frame', '0') `
                -RedirectStandardOutput $out -RedirectStandardError $err
            $null = $p.Handle  # keep the exit code readable after it exits
            if ($p.WaitForExit($TimeoutSec * 1000)) {
                $sw.Stop(); $times += $sw.Elapsed.TotalSeconds
                $said = Get-Content $err -Raw -ErrorAction SilentlyContinue
                if ($said -match 'had not exited') { $stops++ }
                if ($said -match 'could not end the process') { $unkillable++ }
                if ($p.ExitCode -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) {
                    $ok++
                    Remove-Item $err, $out -ErrorAction SilentlyContinue
                    if ($said -match 'had not exited') { Set-Content -Path $err -Value $said }
                } else {
                    $failed++
                    Write-Host "  run $k failed (exit $($p.ExitCode))"
                }
            } else {
                $hung++
                Write-Host "  run $k HUNG at $TimeoutSec s, examining"
                $v = Examine-Hang $p.Id $err (Join-Path $armDir "hang$k") $since
                $hangRows += "| $arm | $k | $($v.final_line -replace '\|', '/') | $($v.wer) | $($v.resumed_exit_s) | $($v.killed_exit_s) | $($v.worker_after_kill) |"
                Remove-Item $out -ErrorAction SilentlyContinue
            }
            if ($k % 25 -eq 0) { Write-Host "  $k runs: ok $ok, failed $failed, hung $hung, guard stops $stops" }
        }
    } finally {
        Arm-Teardown $arm
    }
    $sorted = $times | Sort-Object
    $median = if ($sorted.Count) { [math]::Round($sorted[[int][math]::Floor($sorted.Count / 2)], 2) } else { '' }
    $max = if ($sorted.Count) { [math]::Round($sorted[-1], 2) } else { '' }
    "$arm`t$Iterations`t$ok`t$failed`t$hung`t$stops`t$unkillable`t$median`t$max" | Out-File (Join-Path $OutDir 'summary.tsv') -Append
    $md += "| $arm | $Iterations | $ok | $failed | $hung | $stops | $unkillable | $median | $max |"
    Write-Host "  ${arm}: ok $ok, failed $failed, hung $hung, guard stops $stops, unkillable $unkillable"
}

if ($hangRows.Count) {
    $md += ''
    $md += '| arm | run | vspipe''s last final line | WerFault on it | exit after resume (s) | exit after terminate (s) | worker |'
    $md += '|---|---|---|---|---|---|---|'
    $md += $hangRows
}
$md -join "`n" | Out-File (Join-Path $OutDir 'summary.md')
Get-Content (Join-Path $OutDir 'summary.md')
