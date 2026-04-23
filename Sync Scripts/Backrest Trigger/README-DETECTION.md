# Process Detection Quick Reference

## What Was Implemented

A **layered process detection system** for the Backrest Live Backup watcher that combines multiple signals to reliably determine:
- Whether the watcher is actively running
- Whether it's safe to start a new instance
- Whether it's safe to stop the current instance
- How confident the detection is

## Key Components

### 1. Process-Detection.ps1 Module
Located in `tools/Process-Detection.ps1`, provides these functions:

```powershell
# Low-level detection signals
Get-ProcessCommandLine -ProcessId <int>         # Extract process command line
Get-ProcessStartTime -ProcessId <int>           # Get process creation time
Get-WatcherProcesses                             # Find all watcher processes
Get-MutexState -MutexName <string>              # Check mutex ownership
Get-HeartbeatStatus -LogFile <path>             # Check recent log activity
Resolve-LiveWatcherPid -LogFile <path>          # Extract PID from logs

# High-level detection
Test-WatcherIsRunning -LogFile <path> `
    -MutexName <string> `
    -HeartbeatFreshSeconds <int>                # Master detection function
    
# Process control
Request-SafeStop -LogDir <path> -Reason <string> # Write stop signal
Stop-WatcherProcess -ProcessId <int>            # Force stop process tree
```

### 2. Detection Confidence Levels

| Confidence | Signals | Meaning | Action |
|-----------|---------|---------|--------|
| **HIGH** | 3+ signals active (process + heartbeat + command line) | Definitely running and working | Safe to exit immediately or request stop |
| **MEDIUM** | 2 signals (heartbeat + mutex, no process table) | Likely running but hidden | Request safe stop, wait 30s, then decide |
| **LOW** | 1 signal (mutex only, stale logs) | Maybe running, maybe stale | Wait 10s, recheck, then act |
| **NOT RUNNING** | 0 signals | Definitely not running | Safe to start new instance |

### 3. Detection Signals (in priority order)

| Signal | Detects | Latency | Reliability |
|--------|---------|---------|-------------|
| Heartbeat (log file) | Active logging, recent work | ~10ms | High if process working |
| Process Table | Direct process existence | ~100ms | High unless hidden |
| Command Line | Correct process, not accidental | ~100ms | High, very specific |
| Mutex | Instance ownership | ~5ms | Medium, can be stale |
| Start Time | Process age | ~100ms | Low, needs other signals |

## Usage Examples

### Example 1: Check if Watcher is Running

```powershell
Import-Module (Join-Path $PSScriptRoot 'tools\Process-Detection.ps1')

$detection = Test-WatcherIsRunning `
    -LogFile 'logs\runner.log' `
    -MutexName 'Global\BackrestLiveMonitor_'

if ($detection.IsRunning -and $detection.Confidence -in @('high', 'medium')) {
    Write-Host "Watcher is running (PID: $($detection.ProcessId))"
    Write-Host "Confidence: $($detection.Confidence)"
    Write-Host "Heartbeat age: $($detection.HeartbeatAge) seconds"
} else {
    Write-Host "Watcher is NOT running (safe to start)"
}
```

### Example 2: Graceful Shutdown

```powershell
# Step 1: Request safe stop
$stopFile = Request-SafeStop -LogDir 'logs' -Reason 'User requested restart'

# Step 2: Wait for graceful exit
Start-Sleep -Seconds 30

# Step 3: Check if stopped
$detection = Test-WatcherIsRunning -LogFile 'logs\runner.log'

if ($detection.IsRunning -and $detection.Confidence -in @('high', 'medium')) {
    # Still running after 30s, force stop
    Stop-WatcherProcess -ProcessId $detection.ProcessId
} else {
    Write-Host "Process stopped gracefully"
}
```

### Example 3: Prevent Accidental Double-Run

```powershell
# This is what Start-LiveBackup.ps1 does internally:

$detection = Test-WatcherIsRunning `
    -LogFile $LogFile `
    -MutexName "Global\BackrestLiveMonitor_" `
    -HeartbeatFreshSeconds 180

if ($detection.IsRunning -and $detection.Confidence -in @('high', 'medium')) {
    Write-Log "Watcher already running. Exiting to prevent overlap." "WARN"
    exit 0
} elseif ($detection.IsRunning -and $detection.Confidence -eq 'low') {
    # Uncertain state - wait and recheck
    Start-Sleep -Seconds 3
    $recheck = Test-WatcherIsRunning -LogFile $LogFile
    if ($recheck.IsRunning -and $recheck.Confidence -in @('high', 'medium')) {
        Write-Log "Watcher confirmed running on recheck. Exiting." "WARN"
        exit 0
    }
}

# If we get here, safe to proceed
Write-Log "Layered detection confirms watcher is not running." "INFO"
```

## Integration Points

### Start-LiveBackup.ps1
- Loads detection module at startup
- Runs layered detection BEFORE mutex guard
- Falls back to mutex-only if detection module unavailable
- Logs detection results with signal breakdown

### Manage-RunningJobs.ps1 (Future)
Can be enhanced to use these functions instead of reimplementing similar logic

### External Monitors
Can import and use detection module to:
- Health check the watcher
- Decide when to request restart
- Plan maintenance windows

## Real-World Scenarios

### Scenario A: Normal Operation
```
Timeline:
09:00 - Task Scheduler starts watcher via wrapper
09:00:01 - Process table: ✓ (Start-LiveBackup.ps1 in cmd line)
09:00:01 - Command line: ✓ (matches expected path)
09:00:05 - Heartbeat: ✓ (recent [PID:NNNNN] log lines)
09:00:05 - Mutex: ✓ (owned)

Result: HIGH confidence (4 signals active)
Action: Can safely detect running, can request stop
```

### Scenario B: Hidden Watcher (Task Scheduler)
```
Timeline:
09:00 - Task Scheduler starts watcher under SYSTEM account
09:00:01 - User logs in to regular account, runs manager
09:00:02 - Manager checks from user context:
09:00:02 - Process table: ✗ (not visible, different session)
09:00:02 - Command line: ✗ (can't query SYSTEM process)
09:00:02 - Heartbeat: ✓ (logs are accessible)
09:00:02 - Mutex: ✓ (owned by SYSTEM process)

Result: MEDIUM confidence (2 signals: heartbeat + mutex)
Action: Can request safe stop (via signal file), cannot force kill
```

### Scenario C: Crashed Watcher
```
Timeline:
08:00 - Watcher was running
08:15 - Process crashed without releasing mutex
08:20 - Admin checks status:
08:20 - Process table: ✗ (process gone)
08:20 - Command line: ✗ (no process)
08:20 - Heartbeat: ✗ (last entry at 08:15, >180s old)
08:20 - Mutex: ✓ (still held)

Result: LOW confidence (1 signal: stale mutex)
Action: Wait 10s, recheck → if still low, can force cleanup
```

## Performance

- `Test-WatcherIsRunning`: ~200-300ms total (WMI + file I/O + mutex)
- Safe for periodic checks every 5-10 seconds
- Can run in parallel with watcher (non-blocking)

## Testing

All 6 regression tests pass with detection layer integrated:
1. ✓ Mutex guard (double-run prevention)
2. ✓ Noise filtering (.tmp files ignored)
3. ✓ Event coalescing (batch messages)
4. ✓ Idle debounce & API trigger
5. ✓ State persistence
6. ✓ Safe-stop signaling

## Troubleshooting

**Q: Detection says "NOT running" but I know it's running**
- Check if heartbeat log is recent (within 180s)
- Check if command line matches (try Get-WatcherProcesses manually)
- Try increasing HeartbeatFreshSeconds parameter

**Q: Detection stuck on LOW confidence, won't start new instance**
- Process is likely in limbo (crashed, hung, or stale mutex)
- Wait 10 seconds and let the automatic recheck happen
- Or manually run Stop-WatcherProcess if you're sure

**Q: Mutex locked but process can't be found**
- Process likely running under different session (Task Scheduler)
- Use Request-SafeStop instead of killing (write .stop-livebackup file)
- Run manager under same account/session as scheduler

## See Also

- [DETECTION-MATRIX.md](../docs/DETECTION-MATRIX.md) - Detailed signal matrix and decision trees
- [Start-LiveBackup.ps1](../Start-LiveBackup.ps1) - Integration example
- [Manage-RunningJobs.ps1](../../../RClone Sync/tools/Manage-RunningJobs.ps1) - Similar pattern in RClone sync
