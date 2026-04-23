# Running Process Detection Matrix

**Purpose**: Determine if the Backrest Live Backup watcher is actively running, and whether it's safe to stop/restart it.

**Why layered detection?**
- One signal alone can be misleading (stale mutex, orphaned process, etc.)
- Multiple signals together give high confidence
- Different detection methods work in different contexts (direct launch vs. scheduled task vs. wrapper)

---

## Detection Signals

| Signal | Detection Method | When It Works | When It Fails | Weight |
|--------|------------------|---------------|---------------|--------|
| **Process Table** | `Get-Process` or WMI query for `Start-LiveBackup.ps1` in command line | Process is running directly in current session | Process is hidden, running under different session/context, or in a wrapper | High |
| **Command Line** | Extract command line from process CIM instance, match against script path | Confirms we found the RIGHT PowerShell process, not just any pwsh instance | Command line truncated (rare), different path separator (unlikely) | High |
| **Heartbeat Log** | Parse recent entries in runner.log for `[PID:N]` lines within 180 seconds | Process is actively working and writing logs | Process hung, stalled, or stopped after last write | High |
| **Mutex State** | Try to acquire `Global\BackrestLiveMonitor_{USERNAME}` mutex | Indicates ownership even if process is hidden in another session | Stale mutex from hard crash, false positive if mutex not released on exit | Medium |
| **Process Start Time** | Extract creation date from CIM instance, compare to current time | Useful for distinguishing fresh instances from stale processes | Start time can be altered, less useful without other signals | Low |
| **Heartbeat Age** | Calculate seconds since last log line with PID | Tells us if process is ACTIVELY working vs. just running idle | Process may be busy without logging activity | Medium |

---

## Detection Confidence Levels

### High Confidence (3+ signals active)
- **Signals**: Process table + Command line valid + Heartbeat fresh
- **Interpretation**: Process definitely running and actively working
- **Safe to act**: YES - can safely request stop signal
- **Example**: Watcher found in process list, log shows recent activity within 180s

### Medium Confidence (2 signals active, with good combination)
- **Signals**: Heartbeat fresh + Mutex busy (no process table match)
- **Interpretation**: Process likely running but hidden from this session (different context)
- **Safe to act**: YES - request safe stop via signal file (can't kill hidden process directly)
- **Example**: Task scheduler runs watcher under SYSTEM, logged into user session

### Low Confidence (1 signal or weak combination)
- **Signals**: Only Mutex busy (no process, no heartbeat)
- **Interpretation**: May be stale mutex, process exited without cleanup, or really slow startup
- **Safe to act**: MAYBE - wait and recheck, then consider force stop if mutex doesn't clear
- **Example**: Watcher crashed, mutex stuck

### Not Running (0 signals)
- **Signals**: All signals absent
- **Interpretation**: Definitely not running
- **Safe to act**: YES - safe to start new instance
- **Example**: All process checks empty, mutex free, log file stale

---

## Usage: Test-WatcherIsRunning

```powershell
Import-Module (Join-Path $PSScriptRoot 'tools\Process-Detection.ps1')

$detection = Test-WatcherIsRunning `
    -LogFile 'C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\logs\runner.log' `
    -MutexName 'Global\BackrestLiveMonitor_' `
    -HeartbeatFreshSeconds 180

# Result:
# - IsRunning: boolean
# - Confidence: 'high' | 'medium' | 'low'
# - ProcessId: detected PID or $null
# - StartTime: when process started
# - HeartbeatAge: seconds since last log entry
# - Signals: @{ ProcessTableMatch=$false; HeartbeatFresh=$true; ... }
```

---

## Decision Tree: Should I start a new watcher?

```
START: Is watcher running?
├─ High confidence YES
│  └─ EXIT: Don't start (already running)
├─ Medium confidence YES
│  └─ REQUEST SAFE STOP: Write .stop-livebackup signal
│     └─ WAIT 30 seconds for graceful exit
│        └─ Still running? Force stop (if high confidence with fresh heartbeat)
│        └─ Not running? START new instance
├─ Low confidence YES
│  └─ WAIT 10 seconds and RECHECK
│     └─ High confidence YES? EXIT: Don't start
│     └─ Not running? START new instance
└─ NO (all signals absent)
   └─ START new instance
```

---

## Decision Tree: Should I stop the watcher?

```
START: Is watcher running?
├─ High or Medium confidence YES
│  ├─ REQUEST SAFE STOP first (write .stop-livebackup)
│  └─ WAIT 30 seconds
│     ├─ Still running after wait?
│     │  └─ FORCE STOP (Process tree kill)
│     └─ Stopped gracefully? SUCCESS
├─ Low confidence YES
│  └─ WAIT 10s, RECHECK
│     ├─ Still low confidence?
│     │  └─ TRY FORCE STOP (but log warning)
│     └─ Not running? SUCCESS
└─ NO (not running)
   └─ SUCCESS (already stopped)
```

---

## Implementation in Start-LiveBackup.ps1

**Early detection** (before mutex guard):
- Prevents accidental double-run
- Allows graceful restart

**Pattern**:
```powershell
# At script startup, before Mutex check:
$detection = Test-WatcherIsRunning -LogFile $LogFile -MutexName $mutexName

if ($detection.IsRunning -and $detection.Confidence -in @('high', 'medium')) {
    Write-Log "Watcher already running (PID: $($detection.ProcessId), confidence: $($detection.Confidence))" "WARN"
    exit 0
}
```

---

## Real-World Scenarios

### Scenario 1: Normal Start → Task Scheduler
1. Task Scheduler starts `Start-RcloneMonitor.ps1` (wrapper)
2. Wrapper calls `Launch-Runner.ps1` (launcher)
3. Launcher starts actual watcher in background
4. Watcher holds Mutex, writes heartbeat logs
5. **Detection**: High confidence (process table + heartbeat + mutex)

### Scenario 2: User tries to start while already running
1. User runs `Start-LiveBackup.ps1` in terminal
2. Another instance already running via Task Scheduler
3. **Detection**: High confidence (mutex busy + heartbeat fresh) → EXIT gracefully
4. User doesn't get duplicate watcher

### Scenario 3: Watcher crashes, leaves stale mutex
1. Watcher crashes before releasing mutex
2. Mutex still held, but process is gone
3. Heartbeat log stale (>180s old)
4. **Detection**: Low confidence (mutex busy, but no process/heartbeat)
5. **Action**: Wait 10s, recheck → if still low confidence, force stop

### Scenario 4: Hidden watcher (running under SYSTEM via scheduler, viewing from user context)
1. Watcher running under SYSTEM account (Task Scheduler)
2. User logged in as regular account
3. Process not visible in user's process list
4. But heartbeat logs are accessible
5. **Detection**: Medium confidence (heartbeat fresh + mutex busy, no process table)
6. **Action**: Request safe stop via signal file (can't force kill)

### Scenario 5: Scheduled task runs, but launcher takes time to exec
1. Task Scheduler triggers at 9:00 AM
2. Takes 2 seconds for wrapper + launcher to run actual watcher
3. Manager checks between wrapper start and watcher actual start
4. Process table: launcher visible, watcher PID not yet in table
5. Heartbeat: still empty (just starting)
6. Mutex: transitioning
7. **Detection**: Low confidence → Wait, recheck
8. After 2s: watcher now has mutex + heartbeat → High confidence ✓

---

## Performance Notes

- **Get-WatcherProcesses**: ~100-200ms (WMI query)
- **Get-HeartbeatStatus**: ~10-50ms (file tail read)
- **Get-MutexState**: ~5-20ms (mutex check)
- **Total Test-WatcherIsRunning**: ~200-300ms worst case

For manager scripts running repeatedly, cache the result and only recheck every 5-10 seconds.

---

## Extending Detection

To add new signals:
1. Create a new `Get-*` function
2. Add signal to `Test-WatcherIsRunning` logic
3. Update decision matrix
4. Document failure mode

Example new signals to consider:
- **Task Scheduler state** (for wrapper launchers)
- **File locks** (check if process has logs open)
- **Network activity** (if watcher uses REST API)
- **Registry activity** (Windows Event Trace)
