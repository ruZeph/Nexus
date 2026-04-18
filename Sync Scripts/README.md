# Rclone Backup Job Runner

A PowerShell-based rclone backup runner with two execution modes: **scheduled/manual run** and **real-time monitor mode** triggered by folder changes.

**Features at a glance:** internet check before sync · global mutex to prevent overlapping runs · rate-limit detection with backoff · config-driven jobs with per-job intervals · structured logging for operations, errors, resources, and outcomes

---

## Table of Contents

- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Monitor Mode](#monitor-mode)
- [Execution Flow](#execution-flow)
- [Logging](#logging)
- [CLI Reference](#cli-reference)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

### Option A — One-Command Setup

```powershell
irm https://raw.githubusercontent.com/ruZeph/Nexus/main/Sync%20Scripts/quick-start.ps1 | iex
```

The setup script will:

- Validate PowerShell version and rclone installation (installs via winget/choco if missing)
- Download all runner files with retries
- Generate a blank `backup-jobs.json` (won't overwrite an existing one unless you choose to)
- Verify your rclone remote exists
- Always launch the interactive job configuration helper (in interactive sessions)

**Setup menu options:**

| # | Option |
| --- | --- |
| 1 | Use the repository sample config (default is blank) |
| 2 | Overwrite existing setup files / config |

**Installed layout:**

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
└── logs/
```

### Option B — Manual Setup

1. Install **PowerShell 5.1+** or **PowerShell 7+**
2. Install **rclone** and add it to PATH
3. Configure a remote: `rclone config`
4. Verify: `rclone version`
5. Edit `backup-jobs.json` (see [Configuration](#configuration))

### First Run

```powershell
# Validate config and preview commands — no files transferred
.\Launch-Runner.ps1 -Mode dryrun

# Run jobs once
.\Launch-Runner.ps1 -Mode run

# Start real-time monitor
.\Launch-Runner.ps1 -Mode monitor -IdleTimeSeconds 10
```

---

## Configuration

Jobs are defined in `backup-jobs.json`. Use the helper tool or edit manually.

### Job Configuration Helper

**Interactive (recommended for first-time setup):**

```powershell
.\tools\New-RcloneJobConfig.ps1 -ConfigPath .\backup-jobs.json -Interactive
```

**Non-interactive (for scripting):**

```powershell
.\tools\New-RcloneJobConfig.ps1 `
  -ConfigPath .\backup-jobs.json `
  -JobName    documents-backup `
  -Source     C:/path/to/documents `
  -Dest       remote:backup/documents `
  -PresetName default `
  -Interval   60
```

**Helper arguments:**

| Argument | Required | Description |
| --- | --- | --- |
| `-ConfigPath` | No | Config file path (default: `./backup-jobs.json`) |
| `-JobName` | Yes* | Unique job name |
| `-Source` | Yes* | Local source folder (must exist) |
| `-Dest` | Yes* | rclone destination in `remote:path` format |
| `-PresetName` | No | Profile to assign or auto-create |
| `-Operation` | No | Override operation: `copy` or `sync` |
| `-Interval` | No | Seconds between runs |
| `-Disabled` | No | Create the job in disabled state |
| `-Force` | No | Overwrite an existing job with the same name |

*Required in non-interactive mode.

**Validation the helper enforces:**

- Source path must exist; stored as resolved absolute path
- Destination must be `remote:path` and remote must match `rclone listremotes` exactly (case-sensitive)
- Job name: letters, numbers, `.` `_` `-` only
- Interval must be a non-negative integer
- Duplicate names require `-Force`

**Interactive helper menus (multi-choice):**

- Select destination remote from detected remotes
- Select existing profile or create a new one
- Select operation behavior (resolve from config / copy / sync)
- Select job state (enabled / disabled)

**Running jobs manager:**

```powershell
.\tools\Manage-RunningJobs.ps1
```

Use this to inspect active monitor/job processes, review the latest job log path, request a safe stop after the current transfer completes, or force-stop a selected process tree if needed.

The manager also records its own activity in `logs/manager.log` and `logs/manager-error.log`, and it writes a stop request to `logs/stop-request.txt` when you choose a safe stop.

---

### Config Schema

#### Minimal example

```jsonjson
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

#### `settings`

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `continueOnJobError` | boolean | `true` | Keep running remaining jobs if one fails |
| `defaultOperation` | string | `sync` | `copy` or `sync` |
| `logRetentionCount` | integer | `10` | Log files retained per job |
| `jobIntervalSeconds` | integer | `0` | Global delay between jobs in run mode |
| `defaultExtraArgs` | string or string[] | — | Appended to every rclone call |

#### `profiles`

Named presets for reusable rclone argument sets:

```json
"profiles": {
  "docs-small-files": {
    "operation": "sync",
    "extraArgs": ["--transfers", "6", "--checkers", "12", "--drive-chunk-size", "16M"]
  },
  "large-backups": {
    "operation": "sync",
    "extraArgs": ["--transfers", "8", "--checkers", "4", "--drive-chunk-size", "32M", "--checksum"]
  }
}
```

#### `jobs[]`

| Field | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `name` | string | Yes | — | Must be unique among enabled jobs |
| `source` | string | Yes | — | Local source directory |
| `dest` | string | Yes | — | `remote:path` format |
| `enabled` | boolean | No | `true` | Disabled jobs are skipped |
| `profile` | string | No | — | Must exist in `profiles` if set |
| `operation` | string | No | resolved | Overrides profile/settings operation |
| `interval` | integer | No | `settings.jobIntervalSeconds` | Seconds before next job |
| `logRetentionCount` | integer | No | `settings.logRetentionCount` | Per-job log retention override |
| `extraArgs` | string or string[] | No | — | Appended after defaults and profile args |

#### Precedence rules

**Operation** (highest → lowest):

```text
CLI -Operation → jobs[].operation → profiles.<name>.operation → settings.defaultOperation → sync
```

**Extra arguments** (merged in order):

```text
settings.defaultExtraArgs → profiles.<name>.extraArgs → jobs[].extraArgs → --dry-run (if CLI flag set)
```

**Interval** (run mode): `jobs[].interval` → `settings.jobIntervalSeconds` → no delay

#### Validation rules

| Rule | Behavior |
| --- | --- |
| `jobs[]` must exist | Runner exits with config error |
| Enabled job names must be unique | Duplicates are rejected |
| `name`, `source`, `dest` required | Missing fields fail validation |
| `dest` must match `remote:path` | Invalid format fails validation |
| `operation` must be `copy` or `sync` | Other values fail validation |
| `profile` must exist if provided | Unknown profile name fails |
| `extraArgs` typing | Must be string or non-empty string array |

---

### Full Config Example

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
      "--contimeout", "30s",
      "--timeout", "10m"
    ]
  },
  "profiles": {
    "docs-small-files": {
      "operation": "sync",
      "extraArgs": ["--transfers", "6", "--checkers", "12", "--drive-chunk-size", "16M", "--fast-list"]
    },
    "large-backups": {
      "operation": "sync",
      "extraArgs": ["--transfers", "8", "--checkers", "4", "--drive-chunk-size", "32M", "--checksum"]
    }
  },
  "jobs": [
    {
      "name": "documents-backup",
      "enabled": true,
      "profile": "docs-small-files",
      "source": "C:/path/to/documents",
      "dest": "remote:backup/documents",
      "extraArgs": ["--metadata"]
    },
    {
      "name": "archive-backup",
      "enabled": true,
      "profile": "large-backups",
      "source": "C:/path/to/archives",
      "dest": "remote:backup/archives",
      "interval": 60,
      "logRetentionCount": 5
    }
  ]
}
```

---

## Monitor Mode

Monitor mode keeps a persistent process running and syncs only when files actually change — no polling interval needed.

**How it works:**

1. `FileSystemWatcher` streams change events from each job's `source` folder
2. Changes are grouped by source path and debounced by `-IdleTimeSeconds`
3. Once idle time elapses with no new changes, mapped jobs are deduplicated and executed
4. `backup-jobs.json` is reloaded periodically — no restart required for config changes
5. A polling snapshot fallback catches any events the watcher misses

```powershell
.\Launch-Runner.ps1 -Mode monitor -IdleTimeSeconds 10
```

**Config inputs used by monitor:**

| Input | Source |
| --- | --- |
| Watched folders | `jobs[].source` from enabled jobs |
| Triggered jobs | Folder-to-job mapping built from `jobs[]` |
| Debounce period | `-IdleTimeSeconds` CLI flag |
| Config refresh | Periodic reload of `backup-jobs.json` |

---

## Execution Flow

Each run cycle follows this order:

```text
1. Check internet connectivity
2. Acquire global mutex lock (exit if another instance is active)
3. Load and validate backup-jobs.json
4. Select eligible jobs
5. Execute rclone sync with retry/backoff policy
6. Write summary and telemetry to logs
```

---

## Logging

Log files are written to the `logs/` directory.

| File | Purpose |
| --- | --- |
| `logs/runner.log` | Lifecycle events, monitor activity, resource telemetry, job results |
| `logs/runner-error.log` | Runtime errors and warnings |
| `logs/<job-name>/<timestamp>.log` | Raw rclone output per job run |

**Useful queries:**

```powershellpowershell
# Tail recent activity
Get-Content logs/runner.log -Tail 100

# Filter by log category
Select-String -Path logs/runner.log -Pattern "\[RESOURCE\]"
Select-String -Path logs/runner.log -Pattern "\[RESOURCE WARN\]"
Select-String -Path logs/runner.log -Pattern "\[JOB RESULT\]"
```

---

## CLI Reference

All commands use `Launch-Runner.ps1` as the entry point.

| Task | Command |
| --- | --- |
| Dry run (no transfer) | `.\Launch-Runner.ps1 -Mode dryrun` |
| Run eligible jobs | `.\Launch-Runner.ps1 -Mode run` |
| Force all jobs | `.\Launch-Runner.ps1 -Mode run -Force` |
| Silent (for schedulers) | `.\Launch-Runner.ps1 -Mode run -Silent` |
| Task Scheduler monitor mode | `.\Launch-Runner.ps1 -Mode monitor -TaskScheduler -Silent -IdleTimeSeconds 60` |
| Custom config path | `.\Launch-Runner.ps1 -Mode run -ConfigPath .\backup-jobs.json` |
| Start monitor | `.\Launch-Runner.ps1 -Mode monitor -IdleTimeSeconds 10` |

**Exit codes:**

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Runtime failure |
| `2` | Configuration or validation failure |

**Task Scheduler mode:**

- Launches the runner in a detached PowerShell process and opens a small notification window
- Use `-Mode monitor` for folder-watcher scheduling so the script stays alive and responds to file changes
- Waits for network connectivity before starting the job run
- Shows short event notifications for important scheduler events (already-running instance, network interruption, and recovery)
- Writes startup and connectivity status into the normal runner logs under `logs/`
- Keeps scheduler startup logs in `logs/runner.log` and `logs/runner-error.log`
- Stores per-job logs under `logs/<job-name>/` and logs each job logfile path after it is created

**Monitor stop behavior:**

- A safe stop request is written to `logs/stop-request.txt`
- The monitor checks for that file between jobs and exits cleanly after the current transfer finishes
- If the runner is stopped or crashes for any other reason, review `logs/runner.log`, `logs/runner-error.log`, and `logs/manager*.log` for the latest event trail

---

## Testing

```powershellpowershell
# Full test suite
.\tools\Test-RcloneJobs.ps1

# Quick smoke tests only
.\tools\Test-RcloneJobs.ps1 -Quick
```

---

## Troubleshooting

| Symptom | Check first | Fix |
| --- | --- | --- |
| Internet check fails | ICMP to `8.8.8.8` blocked? | Allow ping in firewall, or modify the connectivity check in the script |
| Monitor not triggering | Source paths exist? `-Mode monitor` set? | Confirm paths, inspect `logs/runner.log` for watcher startup entries |
| Frequent rate limits | Transfer/checker counts too high? | Lower `--transfers`/`--checkers` in profile; increase `--retries-sleep` in `defaultExtraArgs` |
| No job result in log | rclone output not captured? | Ensure per-job log files under `logs/<job-name>/` exist and contain rclone output |
| "Another instance active" repeatedly | Scheduler firing too often? | Increase trigger interval or ensure runner exits promptly after monitor starts |

---

> Paths, remotes, and schedules in examples are illustrative — substitute your own values.

---
