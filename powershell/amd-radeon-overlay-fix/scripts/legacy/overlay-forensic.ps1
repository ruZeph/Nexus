# amd-overlay-forensic.ps1
# Captures the EXACT moment the AMD overlay dies, so the culprit process can be identified.
# Logs: %LOCALAPPDATA%\AMD-Overlay-Watchdog\forensic.log
# Runs for -Minutes (default 90) then exits.
[CmdletBinding()]
param(
    [int]$Minutes = 90,
    [int]$PollSec = 2,
    # Churn-only mode: log process churn but do NOT probe Alt+R.
    # The 2-second RegisterHotKey probe can win a race against AMD's own
    # registration and kill the overlay it is trying to measure, so keep at
    # most ONE prober alive (the 60s watchdog).
    [switch]$NoProbe
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$LogDir  = Join-Path $env:LOCALAPPDATA 'AMD-Overlay-Watchdog'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'forensic.log'

$sig = @"
using System; using System.Runtime.InteropServices;
public class FZ {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint m, uint vk);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr h, int id);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetWindowTextW")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
"@
Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue

$idSeq = 0
function Get-AltRState {
    # NOTE: keep the id inside 0x0000-0xBFFF (the documented range for
    # application-registered hotkeys) or RegisterHotKey fails with error 87
    # and we would wrongly report "overlay alive".
    $script:idSeq++
    $hkid = 0x9000 + ($script:idSeq % 0x0FFF)
    $ok = [FZ]::RegisterHotKey([IntPtr]::Zero, $hkid, 0x0001, [int][char]'R')
    if ($ok) { [FZ]::UnregisterHotKey([IntPtr]::Zero, $hkid) | Out-Null; return $false }
    return ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -eq 1409)
}
function Get-Foreground {
    $h = [FZ]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return '(none)' }
    $sb = New-Object System.Text.StringBuilder 512
    [FZ]::GetWindowText($h, $sb, 512) | Out-Null
    $pid2 = 0; [FZ]::GetWindowThreadProcessId($h, [ref]$pid2) | Out-Null
    $pn = (Get-Process -Id $pid2 -ErrorAction SilentlyContinue).ProcessName
    return ("$pn :: " + $sb.ToString())
}
function Write-FLog { param([string]$m) Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8 }

$amdName = 'RadeonSoftware|amdow|cncmd|AMDRSServ|AMDRSSrcExt|RSServCmd|CPUMetricsServer|AMDADLXServ'
$watchName = 'Cyberpunk2077|BBQ-Win64-Shipping|eldenring|RDR2|LOTF2|b1-Win64-Shipping|CapFrameX|PresentMon|FanControl|RadeonSoftware|AMDRSServ|amdow'

Write-FLog "================ FORENSIC START (pid $PID, $Minutes min, poll ${PollSec}s) ================"
Write-FLog ("boot time: " + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime)

$prevAltR   = $false
if (-not $NoProbe) { $prevAltR = Get-AltRState }
$knownPids  = @{}
foreach ($p in Get-Process) { $knownPids[[int]$p.Id] = $p.ProcessName }
Write-FLog ("initial Alt+R held = $prevAltR ; processes tracked = $($knownPids.Count)")

$deadline  = (Get-Date).AddMinutes($Minutes)
$lastBeat  = Get-Date
$events    = New-Object System.Collections.Generic.List[string]   # recent process churn for context

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollSec

    # --- new / dead processes ---
    $now = @{}
    foreach ($p in Get-Process) {
        $now[[int]$p.Id] = $p.ProcessName
        if (-not $knownPids.ContainsKey([int]$p.Id)) {
            $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").ParentProcessId
            $ppn  = (Get-Process -Id $ppid -ErrorAction SilentlyContinue).ProcessName
            $st   = $p.StartTime
            $line = ("NEW   {0,-26} pid={1,-6} ppid={2,-6}({3}) started={4}" -f $p.ProcessName, $p.Id, $ppid, $ppn, $st)
            Write-FLog $line
            $events.Add(("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $line))
            if ($events.Count -gt 120) { $events.RemoveAt(0) }
        }
    }
    foreach ($k in $knownPids.Keys) {
        if (-not $now.ContainsKey($k)) {
            $line = ("EXIT  {0,-26} pid={1}" -f $knownPids[$k], $k)
            Write-FLog $line
            $events.Add(("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $line))
            if ($events.Count -gt 120) { $events.RemoveAt(0) }
        }
    }
    $knownPids = $now

    # --- overlay state (only when probing is enabled) ---
    $altR = $prevAltR
    if (-not $NoProbe) { $altR = Get-AltRState }
    if ($altR -ne $prevAltR) {
        Write-FLog ""
        Write-FLog "################################################################"
        if ($prevAltR -and -not $altR) {
            Write-FLog "### !!! OVERLAY DIED (Alt+R went held -> FREE) at $(Get-Date -Format 'HH:mm:ss.fff')"
        } else {
            Write-FLog "### !!! OVERLAY CAME BACK (Alt+R free -> held) at $(Get-Date -Format 'HH:mm:ss.fff')"
        }
        Write-FLog ("### foreground window: " + (Get-Foreground))
        Write-FLog "### AMD processes:"
        Get-Process | Where-Object { $_.Name -match $amdName } | Sort-Object Name | ForEach-Object {
            $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").ParentProcessId
            $ppn = (Get-Process -Id $ppid -ErrorAction SilentlyContinue).ProcessName
            Write-FLog ("      {0,-20} pid={1,-6} ppid={2,-6}({3}) started={4}" -f $_.Name, $_.Id, $ppid, $ppn, $_.StartTime)
        }
        Write-FLog "### watched apps running:"
        Get-Process | Where-Object { $_.Name -match $watchName } | Sort-Object Name | ForEach-Object {
            Write-FLog ("      {0,-26} pid={1,-6} started={2}" -f $_.Name, $_.Id, $_.StartTime)
        }
        Write-FLog "### process churn in the preceding window (most recent last):"
        $events | Select-Object -Last 45 | ForEach-Object { Write-FLog ("      " + $_) }
        Write-FLog "################################################################"
        Write-FLog ""
        $prevAltR = $altR
    }

    # --- heartbeat ---
    if (((Get-Date) - $lastBeat).TotalSeconds -ge 60) {
        $lastBeat = Get-Date
        $n = (Get-Process | Where-Object { $_.Name -match $amdName } | Measure-Object).Count
        Write-FLog ("beat  altR=$altR  amdProcs=$n  fg=" + (Get-Foreground))
    }
}
Write-FLog "================ FORENSIC END ================"
