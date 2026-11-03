#Requires -Version 5.1
<#
    amd-overlay-watchdog.ps1
    ----------------------------------------------------------------------
    Revives the AMD Radeon Software in-game overlay (Alt+R) when the AMD
    overlay stack has failed to initialise at logon.

    Root cause it defends against:
      At logon ~40 tasks fire in the same second. AMD's own launchers
      'StartCN' (cncmd.exe startwithdelay) and 'StartDVR' (RSServCmd.exe)
      exit with code 1, so the overlay/hotkey subsystem never comes up and
      NO AMD global hotkey is ever registered -- Alt+R then does nothing on
      the desktop and in every game.

    How it detects the failure:
      It tries to RegisterHotKey(Alt+R). If Windows LETS it register, then
      nobody holds Alt+R -> including AMD -> the overlay is dead.
      If registration FAILS with ERROR_HOTKEY_ALREADY_REGISTERED (1409),
      AMD holds it -> overlay is alive.

    Usage:
      powershell -ExecutionPolicy Bypass -File amd-overlay-watchdog.ps1
      (add -Force to skip the "AMD still starting up" grace period)
#>
[CmdletBinding()]
param(
    [switch]$Force,
    # Opt-in only: also bounce the 'AMD External Events Utility' service.
    # Testing proved this is NOT required -- kill + LIMITED relay is enough to
    # revive the overlay. Leaving it off keeps the watchdog non-elevated and
    # non-invasive, so AMD comes back in its natural state.
    [switch]$ServiceRestart
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ----------------------------------------------------------------- config
$AdminProbeKeys = @(0x0001)          # MOD_ALT
$AltRvk         = [int][char]'R'
$ErrHotkeyTaken = 1409               # ERROR_HOTKEY_ALREADY_REGISTERED
$YoungProcessSec = 90                # grace period if AMD just started
$MaxRepairWaitSec = 150              # how long to wait for recovery
$LogDir  = Join-Path $env:LOCALAPPDATA 'AMD-Overlay-Watchdog'
$LogFile = Join-Path $LogDir 'watchdog.log'
$CNext   = 'C:\Program Files\AMD\CNext\CNext'

# ----------------------------------------------------------------- logging
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  [{1}]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

# ----------------------------------------------------------------- probe
$probeSrc = @"
using System;
using System.Runtime.InteropServices;
public class OverlayProbe {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
"@
Add-Type -TypeDefinition $probeSrc -ErrorAction SilentlyContinue

function Test-OverlayAlive {
    <#  Returns $true if Alt+R is held by somebody (AMD), $false if it is free. #>
    $ok = [OverlayProbe]::RegisterHotKey([IntPtr]::Zero, 9801, $AdminProbeKeys[0], $AltRvk)
    if ($ok) {
        # We got it -> it was free -> AMD does NOT hold it.
        [OverlayProbe]::UnregisterHotKey([IntPtr]::Zero, 9801) | Out-Null
        return $false
    }
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($err -eq $ErrHotkeyTaken) { return $true }
    # Any other error (e.g. access denied in odd contexts) - treat as alive
    # so we never fight a working overlay.
    Write-Log "probe returned unexpected Win32 error $err - assuming overlay alive" 'WARN'
    return $true
}

function Get-AmdProcesses {
    Get-Process | Where-Object {
        $_.Name -match '^(RadeonSoftware|amdow|cncmd|AMDRSServ|AMDRSSrcExt|RSServCmd|CPUMetricsServer)$'
    }
}

function Get-OldestAmdAgeSec {
    $p = Get-AmdProcesses
    if (-not $p) { return [int]::MaxValue }
    $oldest = ($p | Sort-Object StartTime | Select-Object -First 1).StartTime
    return [int]((Get-Date) - $oldest).TotalSeconds
}

# ================================================================== main
Write-Log '--- watchdog run ---'

if (Test-OverlayAlive) {
    Write-Log 'Alt+R is held by AMD - overlay healthy, nothing to do.' 'OK'
    exit 0
}

# Alt+R looks free. But AMD may simply still be starting up after logon.
$amdAge = Get-OldestAmdAgeSec
if (-not $Force -and $amdAge -lt $YoungProcessSec) {
    Write-Log "Alt+R free but oldest AMD process is only ${amdAge}s old - waiting 45s for startup to finish..." 'WARN'
    Start-Sleep -Seconds 45
    if (Test-OverlayAlive) {
        Write-Log 'overlay came up on its own after the grace period.' 'OK'
        exit 0
    }
}

# Confirm with a second probe so we never act on a fluke.
Start-Sleep -Seconds 8
if (Test-OverlayAlive) {
    Write-Log 'second probe says overlay is alive - not acting.' 'OK'
    exit 0
}

Write-Log 'CONFIRMED: Alt+R is unregistered - the AMD overlay stack is dead. Repairing...' 'WARN'

# 0) Report/clear hung RSServCmd overlay commands. They normally exit in ~40ms;
#    anything still alive after 60s is wedged. (Observed when launching
#    Cyberpunk 2077: several piled up, then RadeonSoftware crashed and took
#    the Alt+R registration down with it.)
$stale = Get-Process RSServCmd -ErrorAction SilentlyContinue |
         Where-Object { ((Get-Date) - $_.StartTime).TotalSeconds -gt 60 }
foreach ($s in $stale) {
    Write-Log "killing hung RSServCmd (pid $($s.Id), age $([int]((Get-Date) - $s.StartTime).TotalSeconds)s)"
    Stop-Process -Id $s.Id -Force
}

$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

# 1) AMD External Events Utility -- opt-in only
if ($ServiceRestart -and $isAdmin) {
    try {
        Stop-Service 'AMD External Events Utility' -Force -ErrorAction Stop
        Write-Log 'stopped AMD External Events Utility'
        Start-Sleep -Seconds 3
    } catch {
        Write-Log "could not stop AMD External Events Utility: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-Log 'leaving AMD services untouched (default behaviour)'
}

# 2) kill the AMD user-mode stack
$killFailed = @()
foreach ($p in Get-AmdProcesses) {
    $name = $p.Name; $procid = $p.Id
    Stop-Process -Id $procid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 150
    if (Get-Process -Id $procid -ErrorAction SilentlyContinue) {
        Write-Log "FAILED to kill $name (pid $procid) - likely running at higher integrity than this watchdog (elevated=$isAdmin)" 'ERROR'
        $killFailed += $name
    } else {
        Write-Log "killing $name (pid $procid)"
    }
}
if ($killFailed.Count -gt 0) {
    Write-Log ("could not kill: " + ($killFailed -join ', ')) 'ERROR'
    Write-Log 'hint: the watchdog task must run with RunLevel=Highest to terminate High-integrity AMD processes' 'ERROR'
}
Start-Sleep -Seconds 6

# 3) service back up (only if we stopped it)
if ($ServiceRestart -and $isAdmin) {
    try {
        Start-Service 'AMD External Events Utility' -ErrorAction Stop
        Write-Log 'started AMD External Events Utility'
        Start-Sleep -Seconds 3
    } catch {
        Write-Log "could not start AMD External Events Utility: $($_.Exception.Message)" 'WARN'
    }
}

# 4) relaunch AMD Software.
#    Preferred: the dedicated LIMITED relay task, so AMD comes back at normal
#    (non-elevated) integrity even though this watchdog itself is elevated.
#    TESTING SHOWED: launching StartCN directly from an elevated context can
#    leave AMDRSServ.exe / amdow.exe at High integrity, and a Limited context
#    cannot launch StartCN at all -- hence the relay.
$relaunched = $false

if (Get-ScheduledTask -TaskName 'AMD-Overlay-Relay' -ErrorAction SilentlyContinue) {
    try {
        Start-ScheduledTask -TaskName 'AMD-Overlay-Relay' -ErrorAction Stop
        Write-Log 'relaunched AMD Software via LIMITED relay task AMD-Overlay-Relay'
        $relaunched = $true
    } catch {
        Write-Log "relay task failed: $($_.Exception.Message)" 'WARN'
    }
}

if (-not $relaunched -and (Get-ScheduledTask -TaskName 'StartCN' -ErrorAction SilentlyContinue)) {
    try {
        Start-ScheduledTask -TaskName 'StartCN' -ErrorAction Stop
        Write-Log 'relaunched AMD Software via scheduled task StartCN'
        $relaunched = $true
    } catch {
        Write-Log "StartCN task failed: $($_.Exception.Message)" 'WARN'
    }
}

if (-not $relaunched -and (Test-Path (Join-Path $CNext 'cncmd.exe'))) {
    Start-Process -FilePath (Join-Path $CNext 'cncmd.exe') -ArgumentList 'startwithdelay' `
                  -WorkingDirectory $CNext -WindowStyle Hidden
    Write-Log 'relaunched AMD Software via cncmd.exe startwithdelay (fallback)'
    $relaunched = $true
}
if (-not $relaunched) {
    Write-Log 'could not find a way to relaunch AMD Software' 'ERROR'
    exit 1
}

# 5) wait for the hotkey to come back
$deadline = (Get-Date).AddSeconds($MaxRepairWaitSec)
$recovered = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (Test-OverlayAlive) { $recovered = $true; break }
}

if ($recovered) {
    Write-Log 'SUCCESS - Alt+R is registered by AMD again. Overlay repaired.' 'OK'
    exit 0
}

Write-Log "FAILED - overlay did not come back within ${MaxRepairWaitSec}s." 'ERROR'
Write-Log 'Fallbacks: (1) remove stale RSX package: Get-AppxPackage -AllUsers AdvancedMicroDevicesInc-RSXCM | Remove-AppxPackage -AllUsers' 'ERROR'
Write-Log '           (2) pause Kaspersky protection + self-defence and retry' 'ERROR'
Write-Log '           (3) install Adrenalin 26.8.1 WHQL instead of 26.9.2 Optional' 'ERROR'
exit 1
