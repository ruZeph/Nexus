# Backrest Live Backup Trigger

A long-running Windows daemon that watches your Backrest source folders in real time, filters filesystem noise, batches changes intelligently, and triggers backups through the Backrest HTTP API — automatically.

The key differentiator: **Offline Change Detection**. Files modified while the daemon was stopped or the PC was asleep are caught and backed up the moment the daemon restarts. Nothing slips through.

---

## ✨ Features

| Feature | What it does |
| --- | --- |
| **Real-Time Monitoring** | Attaches recursive `FileSystemWatcher` instances to each plan path, filtering `.tmp`, `.lock`, swap files, and other transient noise |
| **Intelligent Debouncing** | Coalesces bursty file events into a single logical batch, waiting for a configurable idle window before triggering |
| **Offline Change Detection** | Computes cryptographic folder signatures on shutdown and compares them on startup — any mismatch injects a synthetic retrigger immediately |
| **Restart Resilience** | Tracks every HTTP dispatch. If the daemon crashes mid-run or a backup times out, the missed backup is automatically queued on next launch |
| **15-Minute Periodic Baselines** | Continuously syncs folder state to disk during idle periods so the offline baseline stays accurate between restarts |
| **Process Safety** | Prevents duplicate monitor instances via layered process detection and strict Mutex ownership |
| **Detached Execution** | Designed to run silently in the background via Windows Task Scheduler |

---

## 📂 Repo Layout

```text
Backrest Trigger/
├── Start-LiveBackup.ps1          # Core daemon runner and watcher loop
├── Launch-LiveBackup.ps1         # Launcher with Task Scheduler mode and notification window
├── Test-Suite.ps1                # Integration-style reliability harness
└── tools/
    ├── Start-BackrestMonitor.ps1 # Thin, scheduler-friendly wrapper (the intended trigger target)
    ├── Manage-LiveBackup.ps1     # Interactive UI: status, safe stop, forced stop
    └── Process-Detection.ps1     # Layered detection helpers to prevent overlap
```

---

## ⚙️ Runtime Flow

```text
Startup
  └─ Load plans from %APPDATA%\backrest\config.json
  └─ Compare live folder signatures against .state/plan-dispatch-state.json
  └─ Queue synthetic retrigger for any plan that changed offline or failed last dispatch
        │
        ▼
Live Monitoring
  └─ Recursive FileSystemWatcher attached to each source folder
  └─ Relevant events update in-memory plan state
  └─ Plan stays quiet for debounce window
        │
        ▼
Trigger
  └─ POST /v1.Backrest/Backup → Backrest HTTP API
  └─ Background observer polls GetOperations for terminal status
  └─ On success: fresh folder signature saved to .state/plan-dispatch-state.json
        │
        ▼
Periodic Maintenance (every 15 min)
  └─ Baseline snapshots and runtime heartbeats flushed to disk
```

---

## 📁 Default Paths

| Purpose | Path |
| --- | --- |
| Backrest config | `%APPDATA%\backrest\config.json` |
| API endpoint | `http://localhost:9900/v1.Backrest/Backup` |
| Queued events / runtime data | `.state/trigger-state.json` |
| Folder signatures (offline detection) | `.state/plan-dispatch-state.json` |
| Runtime heartbeat | `.state/runtime-state.json` |
| Daemon logs | `logs/runner.log` · `logs/runner-error.log` |
| Launcher/manager logs | `logs/manager.log` · `logs/manager-error.log` |

> `.state/` is gitignored — local runtime metadata never leaves your machine.

---

## 🚀 Usage

**Run the daemon directly (foreground):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\Start-LiveBackup.ps1"
```

**Run the launcher (foreground):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\Launch-LiveBackup.ps1"
```

**Run detached / Task Scheduler mode (silent, no notification window):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\Launch-LiveBackup.ps1" -TaskScheduler -Silent
```

**Open the management UI:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\tools\Manage-LiveBackup.ps1"
```

**Run the integration test suite:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\Test-Suite.ps1"
```

---

## 🛑 Safe Stop

Request a clean shutdown by creating the stop file:

```powershell
Set-Content -LiteralPath "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\.stop-livebackup" -Value "Operator requested stop"
```

The runner will gracefully dispose all watchers, flush final snapshots to disk, and release the mutex before exiting.

You can also trigger a Safe Stop directly from `Manage-LiveBackup.ps1`.

---

## 📅 Task Scheduler Setup

The intended scheduler target is the thin wrapper script. Configure the task as follows:

| Field | Value |
| --- | --- |
| **Program/script** | `powershell.exe` |
| **Arguments** | `-NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\tools\Start-BackrestMonitor.ps1"` |
| **Start in** | `C:\Custom User\Nexus\Sync Scripts\Backrest Trigger` |

**Recommended triggers:**

- At log on
- At startup
- On workstation unlock *(re-asserts the monitor after sleep or long idle periods)*

**Register via PowerShell:**

```powershell
schtasks /Create /TN "Backrest Live Backup Monitor" /SC ONLOGON /RL HIGHEST /F /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\tools\Start-BackrestMonitor.ps1`""
```

**Optional environment variable:**

Set `BACKREST_TRIGGER_LAUNCHER` to point the wrapper at a custom launcher script. If unset, it falls back to `Launch-LiveBackup.ps1` in this repo.

---

## 🖥️ Management UI

`Manage-LiveBackup.ps1` provides an interactive dashboard showing:

- Current scheduler state and latest scheduler action
- Runtime heartbeat state
- Detected live monitor process details
- Safe-stop and forced-stop controls

---

## 📋 Reading the Logs

A healthy trigger flow produces this sequence:

**On startup (offline detection active):**

```text
Loaded plan dispatch snapshot from disk...
Folder contents changed while offline (snapshot mismatch).
Synthetic restart retrigger injected...
```

**During live operation:**

```text
Attached FileSystemWatcher
Coalesced events queued
Batch flush: Triggering
Backrest accepted trigger request
Updating baseline snapshot for [...] post-dispatch.
Background observation started... → Backrest operation reached terminal status
```

**On clean shutdown:**

```text
Shutdown complete
```

---

## 📝 Notes

- Backrest plan `name` is optional. If absent, the plan `id` is used as the identifier.
- A timed-out `Backup` HTTP request is **not** treated as a failure. Backrest frequently continues the job in the background. The background observer waits up to 30 minutes to confirm the final status.
- Detached launcher stdout/stderr is archived under `logs/launcher/start`.
- Launcher notifications (the confirmation window) can be suppressed with `-Silent`.

---
