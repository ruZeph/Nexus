# Rclone Backup Job Runner

A PowerShell-based rclone backup runner with two execution modes: **scheduled/manual run** and **real-time monitor mode** triggered by folder changes.

## Features

- **Internet Connectivity Check** — Validates connection before sync operations
- **Global Mutex Lock** — Prevents overlapping runs from multiple instances
- **Rate Limit Detection** — Automatic backoff when providers throttle requests
- **Config-Driven Jobs** — Interval-based scheduling without hardcoded values
- **Structured Logging** — Separate operational, error, resource, and outcome logs
- **Snapshot-Based Detection** — Reliable change detection across restarts
- **Task Scheduler Integration** — Native Windows scheduling support

---

## Table of Contents

- [Rclone Backup Job Runner](#rclone-backup-job-runner)
  - [Features](#features)
  - [Table of Contents](#table-of-contents)
  - [Quick Start](#quick-start)
    - [Option A: One-Command Setup](#option-a-one-command-setup)
    - [Option B: Manual Setup](#option-b-manual-setup)
    - [First Run](#first-run)
  - [Installation](#installation)
    - [Project Layout](#project-layout)
  - [Configuration](#configuration)
    - [Configuration Helper](#configuration-helper)
    - [Configuration Schema](#configuration-schema)
      - [Minimal Example](#minimal-example)
      - [Settings](#settings)
      - [Profiles](#profiles)
      - [Jobs](#jobs)
      - [Full Example](#full-example)
  - [Monitor Mode](#monitor-mode)
  - [Snapshot System](#snapshot-system)
    - [Fresh Instance Behavior](#fresh-instance-behavior)
    - [Scenarios](#scenarios)
      - [Normal operation](#normal-operation)
      - [Failed sync](#failed-sync)
      - [External changes](#external-changes)
    - [Snapshot Update Strategy](#snapshot-update-strategy)
  - [Execution Flow](#execution-flow)
  - [Logging](#logging)
  - [Task Scheduler Setup](#task-scheduler-setup)
  - [CLI Reference](#cli-reference)
    - [Exit Codes](#exit-codes)
  - [Testing](#testing)
  - [Troubleshooting](#troubleshooting)
  - [Implementation Notes](#implementation-notes)

---

## Quick Start

### Option A: One-Command Setup

```powershell
irm https://raw.githubusercontent.com/ruZeph/Nexus/main/Sync%20Scripts/quick-start.ps1 | iex
```

The setup script will validate PowerShell version and rclone installation, download all runner files with retries, generate a blank `backup-jobs.json` (won't overwrite existing), verify your rclone remote, and launch the interactive job configuration helper.

### Option B: Manual Setup

1. Install **PowerShell 5.1+** or **PowerShell 7+**
2. Install **rclone** and add to PATH
3. Configure a remote: `rclone config`
4. Edit `backup-jobs.json` (see [Configuration](#configuration))

> Substitute example paths, remotes, and intervals with your own values.

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

- `logs/` — Operational logs (tracked in git)
- `.state/` — Runtime state files (not tracked in git)

---

## Configuration

Jobs are defined in `backup-jobs.json`. Use the helper tool or edit manually.

### Configuration Helper

```powershell
# Interactive (recommended)
.\tools\New-RcloneJobConfig.ps1 -ConfigPath .\backup-jobs.json -Interactive

# Non-interactive
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
| ----- | ---- | ------- | ----------- |
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
| ----- | ---- | -------- | ------- | ----------- |
| `name` | string | Yes | — | Unique job name |
| `source` | string | Yes | — | Local source directory |
| `dest` | string | Yes | — | `remote:path` format |
| `enabled` | boolean | No | `true` | Include in runs |
| `profile` | string | No | — | Must exist in profiles |
| `operation` | string | No | resolved | Override `copy`/`sync` |
| `interval` | integer | No | `jobIntervalSeconds` | Seconds before next run |
| `extraArgs` | string[] | No | — | Extra rclone arguments |

#### Full Example

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

Monitor mode keeps a persistent process running and syncs when files actually change.

**How it works:**

1. `FileSystemWatcher` streams change events from each job's source folder
2. Changes are debounced by `-IdleTimeSeconds` (waits for this duration of inactivity before triggering)
3. Mapped jobs are deduplicated and executed
4. `backup-jobs.json` is reloaded periodically — no restart required for config changes
5. A polling snapshot fallback catches any events the watcher misses

```powershell
.\Launch-Runner.ps1 -Mode monitor -IdleTimeSeconds 10
```

---

## Snapshot System

Snapshots track folder state and sync status across restarts to ensure reliable change detection.

**Storage:** `.state/folder-snapshots.json` (not version-controlled). Created automatically on first run; updated after successful jobs, every 15 minutes idle, and on graceful shutdown.

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

On monitor startup, current state is compared against saved snapshots. Sync is triggered if any of these conditions apply:

1. No snapshot exists (first run)
2. Last sync status was not `success`
3. Folder contents have changed (hash mismatch)

### Scenarios

#### Normal operation

```text
Session 1: Files sync → snapshot saved (status=success) → shutdown
Session 2: Snapshot matches → SKIP SYNC
```

#### Failed sync

```text
Session 1: Sync fails → snapshot saved (status=failed) → shutdown
Session 2: status=failed → FORCE SYNC
```

#### External changes

```text
Session 1: Snapshot saved (hash=ABC123) → shutdown
Files modified externally
Session 2: Current hash=XYZ789 ≠ ABC123 → FORCE SYNC
```

### Snapshot Update Strategy

| Trigger | Save? | Status | Purpose |
| ------- | ----- | ------ | ------- |
| Monitor starts | ✅ | `null` | Initial baseline |
| Job succeeds | ✅ | `success` | Mark as synced |
| Job fails | ✅ | `failed` | Flag for retry |
| 15 min idle | ✅ | unchanged | Periodic checkpoint |
| Graceful stop | ✅ | unchanged | Final state |

---

## Execution Flow

1. Check internet connectivity
2. Acquire global mutex lock (exit if another instance is active)
3. Load and validate `backup-jobs.json`
4. Select eligible jobs based on interval/schedule
5. Execute rclone with retry/backoff policy
6. Update snapshots after successful jobs
7. Write summary and telemetry to logs

---

## Logging

| File | Purpose |
| ---- | ------- |
| `runner.log` | Lifecycle events, monitor activity, resource telemetry, job results |
| `runner-error.log` | Runtime errors and warnings |
| `<job-name>/<timestamp>.log` | Raw rclone output per job run |

```powershell
# Tail recent activity
Get-Content logs/runner.log -Tail 100

# Filter by category
Select-String -Path logs/runner.log -Pattern "\[JOB RESULT\]"
Select-String -Path logs/runner.log -Pattern "\[RESOURCE\]"
```

---

## Task Scheduler Setup

Create one task pointing to the monitor. Add new backup targets to `backup-jobs.json` — do not create separate tasks per job.

```powershell
schtasks /create `
  /tn "Rclone Monitor Runner" `
  /sc onlogon `
  /ru "$env:USERNAME" `
  /rl HIGHEST `
  /it `
  /f `
  /tr 'powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "<INSTALLATION PATH>\Nexus\Sync Scripts\Launch-Runner.ps1" -Mode monitor -TaskScheduler -Silent -IdleTimeSeconds 60'
```

IMP: Replace `<INSTALLATION PATH>` with Script installtion root.

Flags: logon-triggered · hidden window · `-TaskScheduler` for scheduler-specific behavior · `-Silent` for minimal console output · 60-second idle debounce.

```powershell
# Verify
schtasks /query /tn "Rclone Monitor Runner" /v /fo list
```

To add new jobs, edit `backup-jobs.json`. The running monitor picks them up without a restart.

---

## CLI Reference

| Task | Command |
| ---- | ------- |
| Dry run (no transfer) | `.\Launch-Runner.ps1 -Mode dryrun` |
| Run eligible jobs | `.\Launch-Runner.ps1 -Mode run` |
| Force all jobs | `.\Launch-Runner.ps1 -Mode run -Force` |
| Silent mode | `.\Launch-Runner.ps1 -Mode run -Silent` |
| Monitor mode | `.\Launch-Runner.ps1 -Mode monitor -IdleTimeSeconds 10` |
| Custom config | `.\Launch-Runner.ps1 -Mode run -ConfigPath ./custom.json` |

### Exit Codes

| Code | Meaning |
| ---- | ------- |
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

Coverage: config parsing/validation · dry-run and logging · mutex safety · change detection · file-level worker pool.

---

## Troubleshooting

| Issue | Check | Fix |
| ----- | ----- | --- |
| Internet check fails | ICMP to 8.8.8.8 blocked? | Allow ping in firewall |
| Monitor not triggering | Source paths exist? `-Mode monitor` set? | Confirm paths in `logs/runner.log` |
| Frequent rate limits | `--transfers`/`--checkers` too high? | Lower values in profile |
| No job result in log | `logs/<job-name>/` directory present? | Check file creation and rclone output |
| "Another instance active" | Scheduler firing too often? | Increase trigger interval |
| Snapshots not saving | `.state/` directory writable? | Check file permissions |

---

## Implementation Notes

**Correctness:** Global named mutex prevents concurrent runs · atomic HashSet deduplication · snapshot comparison on every restart · graceful handling of forceful Task Scheduler termination.

**Performance:** Batched log writes · configurable idle debounce · file-level worker deduplication · rate-limit backoff.

**Security:** User-scoped mutex · absolute path resolution · config validation enforces job names and remote format · per-job error isolation.

---
