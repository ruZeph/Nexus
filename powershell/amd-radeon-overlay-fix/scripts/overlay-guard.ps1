#Requires -Version 5.1
<#
    overlay-guard.ps1
    ------------------------------------------------------------------
    Single long-lived, fully hidden process that protects the AMD
    Radeon in-game overlay (Alt+R) and records process churn.

    WHY A LONG-LIVED PROCESS:
      A scheduled task that launches powershell.exe every minute creates a
      conhost.exe, which flashes a console window on screen (that was a real
      bug we shipped at one point). One long-lived process spawns NOTHING
      after startup, so it cannot flash.

    WHAT IT DOES, every $PollSec seconds (default 60):
      1. Probe: try RegisterHotKey(Alt+R).
           - succeeds  -> Alt+R was free -> the overlay is DEAD
           - fails 1409-> somebody (AMD) holds Alt+R -> overlay ALIVE
      2. If dead: repair = kill AMD user-mode processes + trigger the
         LIMITED relay task 'AMD-Overlay-Relay' (keeps AMD non-elevated),
         then poll until Alt+R is held again.
      3. Continuously logs process churn (NEW/EXIT with parent) for forensics.

    Launched at logon by scheduled task 'AMD-Overlay-Guard' through
    run-hidden.vbs (WshShell.Run window style 0 => SW_HIDE, no console).

    Exit: it never exits on its own; wrap-around try/catch keeps it alive.
#>
[CmdletBinding()]
param(
    [int]$PollSec     = 60,
    [int]$ChurnPollMs = 2000,
    # Opt-in: also bounce the 'AMD External Events Utility' service.
    # Not required (kill + relay is enough) and needs elevation.
    [switch]$ServiceRestart
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ------------------------------------------------------------------ config
$LogDir  = Join-Path $env:LOCALAPPDATA 'AMD-Overlay-Watchdog'
$LogFile = Join-Path $LogDir 'guard.log'
$CNext   = 'C:\Program Files\AMD\CNext\CNext'
$RelayTask = 'AMD-Overlay-Relay'
$ErrHotkeyTaken = 1409
$MaxRepairWaitSec = 150

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# ------------------------------------------------------------------ logging
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  [{1}]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
    # rotate at ~2 MB
    try {
        $fi = Get-Item $LogFile
        if ($fi.Length -gt 2MB) {
            Move-Item $LogFile "$LogFile.1" -Force
            Add-Content -Path $LogFile -Value ("$line") -Encoding UTF8
        }
    } catch { }
}

# ------------------------------------------------------------------ probe
$probeSrc = @"
using System;
using System.Runtime.InteropServices;
public class OGProbe {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
"@
Add-Type -TypeDefinition $probeSrc -ErrorAction SilentlyContinue

$script:probeSeq = 0
function Test-OverlayAlive {
    # Keep the id inside 0x0000-0xBFFF: the documented range for application hotkeys.
    $script:probeSeq++
    $hkid = 0x9000 + ($script:probeSeq % 0x0FFF)
    $ok = [OGProbe]::RegisterHotKey([IntPtr]::Zero, $hkid, 0x0001, [int][char]'R')  # MOD_ALT + R
    if ($ok) {
        [OGProbe]::UnregisterHotKey([IntPtr]::Zero, $hkid) | Out-Null
        return $false          # we got it => nobody holds Alt+R => overlay dead
    }
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($err -eq $ErrHotkeyTaken) { return $true }
    Write-Log "probe returned unexpected Win32 error $err - assuming overlay alive" 'WARN'
    return $true
}

function Get-AmdProcesses {
    Get-Process | Where-Object {
        $_.Name -match '^(RadeonSoftware|amdow|cncmd|AMDRSServ|AMDRSSrcExt|RSServCmd|CPUMetricsServer)$'
    }
}

function Invoke-Repair {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
                [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

    Write-Log 'overlay is DEAD - repairing' 'WARN'

    # 0) clear hung RSServCmd overlay commands (normally exit in ~40ms; >60s = wedged)
    foreach ($s in (Get-Process RSServCmd -ErrorAction SilentlyContinue |
                    Where-Object { ((Get-Date) - $_.StartTime).TotalSeconds -gt 60 })) {
        Write-Log "killing hung RSServCmd (pid $($s.Id))"
        Stop-Process -Id $s.Id -Force
    }

    # 1) optional service bounce
    if ($ServiceRestart -and $isAdmin) {
        try {
            Stop-Service 'AMD External Events Utility' -Force -ErrorAction Stop
            Write-Log 'stopped AMD External Events Utility'
            Start-Sleep -Seconds 3
        } catch { Write-Log "could not stop AMD External Events Utility: $($_.Exception.Message)" 'WARN' }
    }

    # 2) kill the AMD user-mode stack
    $killFailed = @()
    foreach ($p in Get-AmdProcesses) {
        $n = $p.Name; $procid = $p.Id
        Stop-Process -Id $procid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 150
        if (Get-Process -Id $procid -ErrorAction SilentlyContinue) {
            Write-Log "FAILED to kill $n (pid $procid) - higher integrity than this guard (elevated=$isAdmin)" 'ERROR'
            $killFailed += $n
        } else { Write-Log "killing $n (pid $procid)" }
    }
    if ($killFailed.Count -gt 0) {
        Write-Log ("could not kill: " + ($killFailed -join ', ')) 'ERROR'
        Write-Log 'hint: the guard task must run with RunLevel=Highest' 'ERROR'
    }
    Start-Sleep -Seconds 6

    # 3) service back up
    if ($ServiceRestart -and $isAdmin) {
        try {
            Start-Service 'AMD External Events Utility' -ErrorAction Stop
            Write-Log 'started AMD External Events Utility'
            Start-Sleep -Seconds 3
        } catch { Write-Log "could not start AMD External Events Utility: $($_.Exception.Message)" 'WARN' }
    }

    # 4) relaunch AMD through the LIMITED relay so it stays non-elevated
    if (Get-ScheduledTask -TaskName $RelayTask -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName $RelayTask
        Write-Log "relaunched AMD Software via LIMITED relay task $RelayTask"
    } else {
        Write-Log "relay task $RelayTask missing - falling back to cncmd startwithdelay" 'WARN'
        if (Test-Path (Join-Path $CNext 'cncmd.exe')) {
            Start-Process -FilePath (Join-Path $CNext 'cncmd.exe') -ArgumentList 'startwithdelay' `
                          -WorkingDirectory $CNext -WindowStyle Hidden
        }
    }

    # 5) wait for recovery
    $deadline = (Get-Date).AddSeconds($MaxRepairWaitSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Test-OverlayAlive) { Write-Log 'SUCCESS - Alt+R registered again' 'OK'; return $true }
    }
    Write-Log "FAILED - overlay did not return within ${MaxRepairWaitSec}s" 'ERROR'
    Write-Log 'fallbacks: (1) remove stale RSX pkg  (2) pause Kaspersky  (3) install Adrenalin 26.8.1 WHQL' 'ERROR'
    return $false
}

# ================================================================== main
Write-Log "=== guard started (pid $PID, poll ${PollSec}s, churn ${ChurnPollMs}ms, ServiceRestart=$ServiceRestart) ==="

$amdName = 'RadeonSoftware|amdow|cncmd|AMDRSServ|AMDRSSrcExt|RSServCmd|CPUMetricsServer|AMDADLXServ'
$churnBuf = New-Object System.Collections.Generic.List[string]

$known = @{}
foreach ($p in Get-Process) { $known[[int]$p.Id] = $p.ProcessName }

$lastProbe = [DateTime]::MinValue
$lastBeat  = [DateTime]::MinValue
$alive     = $true

while ($true) {
    try {
        # ---------------- churn tracking ----------------
        $now = @{}
        foreach ($p in Get-Process) {
            $now[[int]$p.Id] = $p.ProcessName
            if (-not $known.ContainsKey([int]$p.Id)) {
                $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
                $ppid = 0; if ($ci) { $ppid = [int]$ci.ParentProcessId }
                $ppn = (Get-Process -Id $ppid -ErrorAction SilentlyContinue).ProcessName
                $line = ("NEW   {0,-26} pid={1,-6} ppid={2,-6}({3}) started={4}" -f $p.ProcessName, $p.Id, $ppid, $ppn, $p.StartTime)
                Write-Log $line 'CHURN'
                $churnBuf.Add($line); if ($churnBuf.Count -gt 200) { $churnBuf.RemoveAt(0) }
            }
        }
        foreach ($k in @($known.Keys)) {
            if (-not $now.ContainsKey($k)) {
                $line = ("EXIT  {0,-26} pid={1}" -f $known[$k], $k)
                Write-Log $line 'CHURN'
                $churnBuf.Add($line); if ($churnBuf.Count -gt 200) { $churnBuf.RemoveAt(0) }
            }
        }
        $known = $now

        # ---------------- probe + repair ----------------
        if (((Get-Date) - $lastProbe).TotalSeconds -ge $PollSec) {
            $lastProbe = Get-Date
            $alive = Test-OverlayAlive
            if (-not $alive) {
                Write-Log '----------------------------------------------------------------'
                Write-Log ("### OVERLAY DEAD at " + (Get-Date -Format 'HH:mm:ss.fff'))
                $fgp = (Get-Process -Id ([OGProbe]::GetForegroundWindow()) -ErrorAction SilentlyContinue).ProcessName
                Write-Log ("### foreground app: " + (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1).ProcessName)
                Write-Log '### last 30 churn events:'
                $churnBuf | Select-Object -Last 30 | ForEach-Object { Write-Log ("    " + $_) 'CHURN' }
                Invoke-Repair | Out-Null
                Write-Log '----------------------------------------------------------------'
                $lastProbe = Get-Date
            }
        }

        # ---------------- heartbeat ----------------
        if (((Get-Date) - $lastBeat).TotalSeconds -ge 300) {
            $lastBeat = Get-Date
            $n = (Get-AmdProcesses | Measure-Object).Count
            Write-Log "beat  altRAlive=$alive  amdProcs=$n"
        }
    }
    catch {
        Write-Log ("guard loop error: " + $_.Exception.Message) 'ERROR'
    }
    Start-Sleep -Milliseconds $ChurnPollMs
}
