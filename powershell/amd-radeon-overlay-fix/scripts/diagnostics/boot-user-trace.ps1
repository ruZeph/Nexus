# User Logon Telemetry Trace (Runs at User Logon with Highest privileges)
# Probes Win32 Hotkeys (Alt+R) every 2 seconds to pinpoint the exact second AMD registers hooks.

$ErrorActionPreference = 'SilentlyContinue'

$outDir = "C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix\evidence\boot-traces"
if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = "$outDir\user-logon-$timestamp.log"

function Write-UserLog([string]$msg, [string]$lvl = "INFO") {
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "$now  [$lvl]  $msg"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

Write-UserLog "=== USER LOGON TELEMETRY STARTED ==="

# Compile Hotkey Prober
$probeSrc = @'
using System;
using System.Runtime.InteropServices;
public class UserLogonProbe {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public static bool CheckAltR() {
        bool ok = RegisterHotKey(IntPtr.Zero, 8888, 1 /*MOD_ALT*/, 0x52 /*R*/);
        if (ok) {
            UnregisterHotKey(IntPtr.Zero, 8888);
            return false; // FREE (overlay not registered yet)
        }
        return true; // HELD (overlay is ALIVE!)
    }
}
'@
Add-Type -TypeDefinition $probeSrc

$durationSec = 240
$stopTime = (Get-Date).AddSeconds($durationSec)
$lastAlive = $null

Write-UserLog "Beginning 2-second hotkey and process sampling for $durationSec seconds..."

while ((Get-Date) -lt $stopTime) {
    $alive = [UserLogonProbe]::CheckAltR()
    
    # Check AMD processes
    $amdProcs = Get-Process -Name 'RadeonSoftware', 'amdow', 'AMDRSServ', 'cncmd', 'AMDADLXServ' -ErrorAction SilentlyContinue
    $procSummary = ($amdProcs | ForEach-Object { "$($_.Name)(pid=$($_.Id))" }) -join ", "
    if (!$procSummary) { $procSummary = "(No AMD user-mode processes yet)" }
    
    if ($alive -ne $lastAlive) {
        $stateStr = if ($alive) { "HELD [ONLINE]" } else { "FREE [OFFLINE]" }
        Write-UserLog ">>> STATE CHANGE: Alt+R is now $stateStr | Procs: $procSummary" "STATUS"
        $lastAlive = $alive
    } else {
        # Heartbeat every 10 seconds or state report
        if ((Get-Date).Second % 10 -eq 0) {
            $stateStr = if ($alive) { "ONLINE" } else { "WAITING" }
            Write-UserLog "Beat (Overlay $stateStr) | $procSummary"
        }
    }
    
    # Check if GameBar tried to execute
    $gb = Get-Process GameBarPresenceWriter -ErrorAction SilentlyContinue
    if ($gb) {
        Write-UserLog "ALERT: GameBarPresenceWriter detected running! PID=$($gb.Id)" "WARN"
    }
    
    Start-Sleep -Seconds 2
}

Write-UserLog "=== 240-SECOND LOGON MONITORING COMPLETE ==="

# Final snapshot
$finalAlive = [UserLogonProbe]::CheckAltR()
Write-UserLog "FINAL RESULT: Overlay Alt+R is $(if ($finalAlive) { 'HELD (SUCCESSFUL STARTUP)' } else { 'FREE (FAILED)' })"

# Check FanControl
$fcLog = "C:\Program Files (x86)\FanControl\service_log.txt"
if (Test-Path $fcLog) {
    $recentFc = Get-Content $fcLog -Tail 10
    Write-UserLog "Recent FanControl Service log:`n$($recentFc -join "`n")"
}

Write-UserLog "=== USER LOGON TELEMETRY FINISHED ==="
