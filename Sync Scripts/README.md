# Rclone Backup Job Runner

A PowerShell-based rclone backup runner with two execution modes: **scheduled/manual run** and **real-time monitor mode** triggered by folder changes.

**Features:** Internet check before sync · Global mutex to prevent overlapping runs · Rate-limit detection with backoff · Config-driven jobs with per-job intervals · Structured logging for operations, errors, resources, and outcomes · Snapshot-based change detection · Task Scheduler integration

---

## Table of Contents

- [Quick Start](#quick-start)
- [Installation](#installation)
- [Configuration](#configuration)
- [Monitor Mode](#monitor-mode)
- [Snapshot System](#snapshot-system)
- [Execution Flow](#execution-flow)
- [Logging](#logging)
- [Task Scheduler Setup](#task-scheduler-setup)
- [CLI Reference](#cli-reference)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

### Option A: One-Command Setup

```powershell
irm https://raw.githubusercontent.com/ruZeph/Nexus/main/Sync%20Scripts/quick-start.ps1 | iex
```

The setup script will:

- Validate PowerShell version and rclone installation
- Download all runner files with retries
- Generate a blank `backup-jobs.json` (won't overwrite existing)
- Verify your rclone remote exists
- Launch the interactive job configuration helper

### Option B: Manual Setup

1. Install **PowerShell 5.1+** or **PowerShell 7+**
2. Install **rclone** and add to PATH
3. Configure a remote: `rclone config`
4. Edit `backup-jobs.json` (see [Configuration](#configuration))

### First Run

```powershell
# Validate config and preview commands (no files transferred)
.\Launch-Runner.ps1 -Mode dryrun

# Run jobs once
.\Launch-Runner.ps1 -Mode run

# Start real-time monitor
.\Launch-Runner.ps1 -Mode monitor -IdleTimeSeconds 10
```

---

## Installation

### Project Layout

```text
<install-path>/
├── Launch-Runner.ps1
├── backup-jobs.json
├── README.md
├── src/
│   └── Run-RcloneJobs.ps1
├── tools/
│   ├── New-RcloneJobConfig.ps1
│   └── Test-RcloneJobs.ps1
├── logs/
│   ├── runner.log
│   ├── runner-error.log
│   └── <job-name>/
│       └── <timestamp>.log
└── .state/
    └── folder-snapshots.json
```

**Key directories:**

- `logs/` — Operational logs (tracked in git)
- `.state/` — Runtime state files (not tracked in git)

---

## Configuration

Jobs are defined in `backup-jobs.json`. Use the helper tool or edit manually.

### Configuration Helper

**Interactive (recommended):**

```powershell
.\tools\New-RcloneJobConfig.ps1 -ConfigPath .\backup-jobs.json -Interactive
```

**Non-interactive:**

```powershell
.\tools\New-RcloneJobConfig.ps1 `
  -ConfigPath .\backup-jobs.json `
  -JobName    documents-backup `
  -Source     C:/path/to/documents `
  -Dest       remote:backup/documents `
  -PresetName default `
  -Interval   60
```

### Configuration Schema

#### Minimal Example

```json
{
  "settings": {
    "continueOnJobError": true,
    "defaultOperation": "sync",
    "logRetentionCount": 10,
    "jobIntervalSeconds": 30,
    "defaultExtraArgs": ["--retries", "15", "--retries-sleep", "30s"]
  },
  "profiles": {
    "default": {
      "operation": "sync",
      "extraArgs": ["--fast-list", "--transfers", "8"]
    }
  },
  "jobs": [
    {
      "name": "documents-backup",
      "enabled": true,
      "source": "C:/path/to/local/folder",
      "dest": "remote:backup/documents",
      "profile": "default",
      "interval": 60
    }
  ]
}
```

#### Settings

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `continueOnJobError` | boolean | `true` | Continue if a job fails |
| `defaultOperation` | string | `sync` | `copy` or `sync` |
| `logRetentionCount` | integer | `10` | Logs retained per job (max 10) |
| `jobIntervalSeconds` | integer | `0` | Delay between jobs in run mode |
| `defaultExtraArgs` | string[] | — | Appended to every rclone call |

#### Profiles

Named presets for reusable rclone argument sets:

```json
"profiles": {
  "small-files": {
    "operation": "sync",
    "extraArgs": ["--transfers", "6", "--checkers", "12"]
  },
  "large-files": {
    "operation": "sync",
    "extraArgs": ["--transfers", "8", "--checkers", "4", "--checksum"]
  }
}
```

#### Jobs

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | Yes | — | Unique job name |
| `source` | string | Yes | — | Local source directory |
| `dest` | string | Yes | — | `remote:path` format |
| `enabled` | boolean | No | `true` | Include in runs |
| `profile` | string | No | — | Must exist in profiles |
| `operation` | string | No | resolved | Override `copy`/`sync` |
| `interval` | integer | No | `jobIntervalSeconds` | Seconds before next run |
| `extraArgs` | string[] | No | — | Extra rclone arguments |

#### Full Configuration Example

```json
{
  "settings": {
    "continueOnJobError": true,
    "defaultOperation": "sync",
    "logRetentionCount": 10,
    "jobIntervalSeconds": 30,
    "defaultExtraArgs": [
      "--retries", "15",
      "--retries-sleep", "30s",
      "--timeout", "10m"
    ]
  },
  "profiles": {
    "standard": {
      "operation": "sync",
      "extraArgs": ["--transfers", "8", "--fast-list"]
    }
  },
  "jobs": [
    {
      "name": "documents-backup",
      "enabled": true,
      "profile": "standard",
      "source": "C:/Users/user/Documents",
      "dest": "remote:backup/documents"
    },
    {
      "name": "archive-backup",
      "enabled": true,
      "source": "C:/Users/user/Archives",
      "dest": "remote:backup/archives",
      "interval": 60
    }
  ]
}
```

---

## Monitor Mode

Monitor mode keeps a persistent process running and syncs when files actually change — no polling interval needed.

**How it works:**

1. `FileSystemWatcher` streams change events from each job's source folder
2. Changes are debounced by `-IdleTimeSeconds` (waits for this duration of inactivity)
3. Once idle time elapses, mapped jobs are deduplicated and executed
4. `backup-jobs.json` is reloaded periodically (no restart required for config changes)
5. A polling snapshot fallback catches any events the watcher misses

### Starting Monitor

```powershell
.\Launch-Runner.ps1 -Mode monitor -IdleTimeSeconds 10
```

### Monitor Features

- **Real-time responsiveness:** Detects file changes immediately
- **Change deduplication:** Multiple changes map to single sync job
- **Graceful config updates:** Reload config without restart
- **Snapshot-based fallback:** Polling detects missed events
- **Safe stops:** Stop after current transfer finishes

---

## Snapshot System

The snapshot system ensures reliable change detection across restarts by tracking folder state and sync status.

### How Snapshots Work

**Storage:**

- Location: `.state/folder-snapshots.json` (not version-controlled)
- Created: Automatically on first run
- Updated: After successful job · 15-minute fallback · On graceful shutdown

**Contents:**

```json
{
  "timestamp": "2026-04-19 14:30:45",
  "folders": {
    "C:\\source\\folder": {
      "snapshot": "MD5HASH_OF_FILES",
      "lastSyncStatus": "success",
      "lastSuccessfulSync": "2026-04-19 14:30:00",
      "lastChange": "2026-04-19 14:28:15"
    }
  }
}
```

### Fresh Instance Behavior

On monitor startup, the script **always** compares current state vs saved snapshots.

**Triggers sync if ANY of these conditions:**

1. **No snapshot exists** (first sync)
2. **Last sync was not successful** (failed or incomplete)
3. **Folder contents changed** (snapshot mismatch)

This ensures both remote and local are always in sync after restart.

### Three Scenarios

#### Scenario 1: Normal Operation

```text
Session 1:
├─ Files sync successfully
├─ Snapshot saved: status='success'
└─ Laptop shuts down

Session 2 (Restart):
├─ Load snapshot: status='success', files match
└─ Decision: SKIP SYNC (already up-to-date)
```

#### Scenario 2: Failed Sync Detection

```text
Session 1:
├─ Job attempts sync
├─ FAILS (network error, timeout)
├─ Snapshot status marked: 'failed'
└─ Laptop shuts down

Session 2 (Restart):
├─ Load snapshot: status='failed'
└─ Decision: FORCE SYNC (retry)
```

#### Scenario 3: External Changes

```text
Session 1:
├─ Snapshot saved: hash="ABC123"
└─ Laptop shuts down

External:
└─ Files modified

Session 2 (Restart):
├─ Load snapshot: hash="ABC123"
├─ Current hash: "XYZ789" (mismatch!)
└─ Decision: FORCE SYNC
```

### Snapshot Update Strategy

| Trigger | Save? | Status | Purpose |
|---------|-------|--------|---------|
| Monitor starts | ✅ | `null` | Initial baseline |
| Job succeeds | ✅ | `success` | Mark as synced |
| Job fails | ✅ | `failed` | Flag for retry |
| 15 min idle | ✅ | unchanged | Periodic checkpoint |
| Graceful stop | ✅ | unchanged | Final state |

---

## Execution Flow

Each run cycle follows this order:

1. Check internet connectivity
2. Acquire global mutex lock (exit if another instance is active)
3. Load and validate `backup-jobs.json`
4. Select eligible jobs based on interval/schedule
5. Execute rclone with retry/backoff policy
6. Update snapshots after successful jobs
7. Write summary and telemetry to logs

---

## Logging

Log files are written to the `logs/` directory.

| File | Purpose |
|------|---------|
| `runner.log` | Lifecycle events, monitor activity, resource telemetry, job results |
| `runner-error.log` | Runtime errors and warnings |
| `<job-name>/<timestamp>.log` | Raw rclone output per job run |

### Log Queries

```powershell
# Tail recent activity
Get-Content logs/runner.log -Tail 100

# Filter by category
Select-String -Path logs/runner.log -Pattern "\[JOB RESULT\]"
Select-String -Path logs/runner.log -Pattern "\[RESOURCE\]"
```

---

## Task Scheduler Setup

Use Task Scheduler to start the monitor process. Do not create one task per job — add jobs to `backup-jobs.json` instead.

### One-Time Task Creation

```powershell
schtasks /create `
  /tn "Rclone Monitor Runner" `
  /sc onlogon `
  /ru "$env:USERNAME" `
  /rl HIGHEST `
  /it `
  /f `
  /tr 'powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Launch-Runner.ps1" -Mode monitor -TaskScheduler -Silent -IdleTimeSeconds 60'
```

**What this does:**

- Creates logon-triggered task
- Launches monitor in hidden mode
- Passes `-TaskScheduler` for scheduler-specific behavior
- Uses `-Silent` for minimal console output
- Waits 60 seconds of inactivity before syncing

### Verify Task

```powershell
schtasks /query /tn "Rclone Monitor Runner" /v /fo list
```

### Add New Jobs

Edit `backup-jobs.json` and add to `jobs[]`. The monitor will pick up all enabled jobs without restarting the Task Scheduler task.

---

## CLI Reference

All commands use `Launch-Runner.ps1` as the entry point.

| Task | Command |
|------|---------|
| Dry run (no transfer) | `.\Launch-Runner.ps1 -Mode dryrun` |
| Run eligible jobs | `.\Launch-Runner.ps1 -Mode run` |
| Force all jobs | `.\Launch-Runner.ps1 -Mode run -Force` |
| Silent mode | `.\Launch-Runner.ps1 -Mode run -Silent` |
| Monitor mode | `.\Launch-Runner.ps1 -Mode monitor -IdleTimeSeconds 10` |
| Custom config | `.\Launch-Runner.ps1 -Mode run -ConfigPath ./custom.json` |

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Runtime failure |
| `2` | Configuration/validation failure |

---

## Testing

```powershell
# Full test suite (130+ tests)
.\tools\Test-RcloneJobs.ps1

# Quick smoke tests
.\tools\Test-RcloneJobs.ps1 -Quick
```

**Test Coverage:**

- Unit tests for config parsing and validation
- Integration tests for dry-run and logging
- Robustness tests for mutex safety and change detection
- File-level worker pool tests

---

## Troubleshooting

| Issue | Check | Fix |
|-------|-------|-----|
| Internet check fails | ICMP to 8.8.8.8 blocked? | Allow ping in firewall |
| Monitor not triggering | Source paths exist? `-Mode monitor` set? | Confirm paths in logs/runner.log |
| Frequent rate limits | `-transfers`/`-checkers` too high? | Lower values in profile |
| No job result in log | Log files in `logs/<job-name>/`? | Check file creation and rclone output |
| "Another instance active" | Scheduler firing too often? | Increase trigger interval |
| Snapshots not saving | .state directory writable? | Check file permissions |

---

## Key Implementation Details

### Defensive Programming

- **Directory creation:** Auto-creates `logs/` and `.state/` with error handling
- **Mutex safety:** Global named mutex prevents duplicate runs
- **Atomic operations:** Check-and-add deduplication in HashSet
- **Task Scheduler resilience:** Handles forceful process termination gracefully
- **Change detection:** Snapshot comparison on every restart

### Performance

- **Batched logging:** Groups log writes for I/O efficiency
- **Smart intervals:** Configurable idle time for change debouncing
- **File-level workers:** Deduplicates changes to prevent duplicate syncs
- **Rate limiting:** Detects and backs off on provider limits

### Security

- **User-scoped mutex:** Prevents cross-user interference
- **Resolved paths:** Uses absolute paths for consistency
- **Config validation:** Enforces job names and remote format
- **Error isolation:** One job failure doesn't crash others

---

> Substitute example paths, remotes, and intervals with your own configuration.
