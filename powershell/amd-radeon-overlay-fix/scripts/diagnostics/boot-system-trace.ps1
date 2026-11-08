# System Boot Telemetry Trace (Runs at Machine Startup as SYSTEM)
# Captures kernel startup, early service initialization, drivers, and all process creations for 300 seconds.

$ErrorActionPreference = 'SilentlyContinue'

$outDir = "C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix\evidence\boot-traces"
if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = "$outDir\system-boot-$timestamp.log"

function Write-TraceLog([string]$msg, [string]$lvl = "INFO") {
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "$now  [$lvl]  $msg"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

Write-TraceLog "=== SYSTEM BOOT TELEMETRY STARTED (KERNEL UP) ==="
$os = Get-CimInstance Win32_OperatingSystem
Write-TraceLog "LastBootUpTime : $($os.LastBootUpTime)"
Write-TraceLog "Windows Build  : $($os.Version) (Build $($os.BuildNumber))"
Write-TraceLog "System Uptime  : $((Get-Date) - $os.LastBootUpTime)"

# Log initial system services status
$services = Get-Service -Name 'AMD*', 'FanControl*', 'ppbwd', 'PresentMon*'
foreach ($s in $services) {
    Write-TraceLog "Service Initial State: $($s.Name) = $($s.Status) ($($s.StartType))"
}

# Register WMI Event for Process Creations
$query = "SELECT * FROM Win32_ProcessStartTrace"
$eventSub = Register-CimIndicationEvent -Query $query -SourceIdentifier "BootProcessTrace"

$durationSec = 300
$stopTime = (Get-Date).AddSeconds($durationSec)
Write-TraceLog "Capturing all process start traces for $durationSec seconds..."

while ((Get-Date) -lt $stopTime) {
    $ev = Get-Event -SourceIdentifier "BootProcessTrace" -ErrorAction SilentlyContinue
    if ($ev) {
        foreach ($e in $ev) {
            $pName = $e.SourceEventArgs.NewEvent.ProcessName
            $pid_ = $e.SourceEventArgs.NewEvent.ProcessID
            $ppid_ = $e.SourceEventArgs.NewEvent.ParentProcessID
            Write-TraceLog "[PROC NEW]  $($pName.PadRight(25)) PID=$pid_  PPID=$ppid_"
        }
        $ev | Remove-Event
    }
    Start-Sleep -Milliseconds 250
}

Unregister-Event -SourceIdentifier "BootProcessTrace" -ErrorAction SilentlyContinue

Write-TraceLog "=== 300-SECOND CAPTURE COMPLETE. EXTRACTING EVENT LOGS ==="

# Extract any system or application errors during the window
$startTime = $os.LastBootUpTime
$appErrors = Get-WinEvent -FilterHashtable @{LogName='Application'; Level=1,2; StartTime=$startTime} -ErrorAction SilentlyContinue
foreach ($err in $appErrors) {
    Write-TraceLog "[EVENT APP ERROR] $($err.TimeCreated.ToString('HH:mm:ss.fff')) Provider=$($err.ProviderName) Id=$($err.Id) : $($err.Message.Split("`n")[0].Trim())" "WARN"
}

$sysErrors = Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=$startTime} -ErrorAction SilentlyContinue
foreach ($err in $sysErrors) {
    Write-TraceLog "[EVENT SYS ERROR] $($err.TimeCreated.ToString('HH:mm:ss.fff')) Provider=$($err.ProviderName) Id=$($err.Id) : $($err.Message.Split("`n")[0].Trim())" "WARN"
}

Write-TraceLog "=== SYSTEM BOOT TELEMETRY FINISHED ==="
