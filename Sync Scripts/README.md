# Rclone Backup Job Runner

PowerShell-based backup runner for rclone with two execution modes:

- Scheduled or manual run mode
- Monitor mode for near real-time syncing based on folder changes

The runner provides:

- Internet availability check before sync execution
- Global process lock (mutex) to prevent overlapping runs
- Rate-limit detection and backoff handling
- Config-driven jobs with per-job intervals
- Structured logging for operations, errors, resources, and job outcomes

## Table of Contents

- [Quick Start](#quick-start)
- [One-Command Setup (iex irm)](#one-command-setup-iex-irm)
- [Configuration Guide](#configuration-guide)
- [Job Configuration Helper](#job-configuration-helper)
- [Monitor Mode (Real-Time Syncing)](#monitor-mode-real-time-syncing)
- [Execution Flow](#execution-flow)
- [Logging](#logging)
- [Usage](#usage)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Documentation References](#documentation-references)
- [Notes](#notes)

## Quick Start

### One-Command Setup (iex irm)

Run this in PowerShell to download dependencies, validate environment, and bootstrap setup:

```powershell
irm https://raw.githubusercontent.com/ruZeph/Nexus/main/Sync%20Scripts/quick-start.ps1 | iex
```

What the quick-start script handles:

- PowerShell version validation
- rclone presence check and installation attempt (winget/choco)
- setup file download with retries
- blank config generation by default (does not copy repository config)
- optional repository config copy via switch
- existing config protection (unless force overwrite)
- rclone remote existence check
- optional launch of interactive job configuration helper
- clear success/failure messages with non-zero exit on fatal errors

Install location behavior:

- asks for install path in interactive shells
- uses current folder as default when no path is provided
- accepts relative paths (resolved from current folder)
- creates and reuses a consistent layout in the selected folder

Folder layout created by setup:

```text
<install-path>
|-- src/
|   `-- Run-RcloneJobs.ps1
|-- tools/
|   |-- Test-RcloneJobs.ps1
|   `-- New-RcloneJobConfig.ps1
|-- backup-jobs.json
|-- README.md
`-- logs/
```

Create config from repository sample only when needed:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/ruZeph/Nexus/main/Sync%20Scripts/quick-start.ps1') } -CopyRepoConfig"
```

Optional direct invocation form:

```powershell
iex "& { $(irm 'https://raw.githubusercontent.com/ruZeph/Nexus/main/Sync%20Scripts/quick-start.ps1') }"
```

### 1. Install Requirements

1. Install PowerShell 5.1+ or PowerShell 7+.
2. Install rclone and ensure it is on PATH.
3. Configure at least one rclone remote:

   ```powershell
   rclone config
   ```

4. Verify installation:

   ```powershell
   rclone version
   ```

### 2. Configure Jobs

Edit backup-jobs.json.

Minimal example:

```json
{
  "settings": {
    "continueOnJobError": true,
    "defaultOperation": "sync",
    "logRetentionCount": 10,
    "jobIntervalSeconds": 30,
    "defaultExtraArgs": [
      "--retries", "15",
      "--retries-sleep", "30s"
    ]
  },
  "profiles": {
    "default": {
      "operation": "sync",
      "extraArgs": [
        "--fast-list",
        "--transfers", "8"
      ]
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

### 3. Dry Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 -DryRun
```

### 4. Run Once

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1
```

### 5. Start Monitor Mode

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 -Monitor -IdleTimeSeconds 10
```

## Configuration Guide

This section documents the configuration schema actually consumed by the runner.

### Job Configuration Helper

Use New-RcloneJobConfig.ps1 to create or update backup-jobs.json safely.

#### Interactive Mode

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\New-RcloneJobConfig.ps1 -ConfigPath .\backup-jobs.json -Interactive
```

Interactive mode includes:

- required input prompts for job name/source/dest
- source directory existence validation
- destination format validation (remote:path)
- operation validation (copy or sync)
- interval and enabled-state prompts
- auto-create missing profile with safe defaults
- replace protection unless force is provided

#### Non-Interactive Mode

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\New-RcloneJobConfig.ps1 `
  -ConfigPath .\backup-jobs.json `
  -JobName documents-backup `
  -Source C:/path/to/documents `
  -Dest remote:backup/documents `
  -PresetName default `
  -Interval 60
```

Non-interactive arguments:

| Argument | Required | Description |
| --- | --- | --- |
| -ConfigPath | No | Target config file path (default: ./backup-jobs.json) |
| -JobName | Yes* | Job name for add/update |
| -Source | Yes* | Existing local source folder |
| -Dest | Yes* | rclone destination in remote:path format |
| -PresetName | No | Profile name to assign/create |
| -Operation | No | copy or sync override |
| -Interval | No | Interval in seconds |
| -Disabled | No | Create/update job as disabled |
| -Force | No | Overwrite existing job with same name |

*Required in non-interactive mode.

#### How Quick Start Uses The Helper

- quick-start.ps1 downloads New-RcloneJobConfig.ps1 into tools/
- it can launch the helper interactively during setup
- this ensures first-run config is validated before execution

#### Validation Rules Enforced By Helper

- source path must exist and is stored as resolved absolute path
- destination must be remote:path and remote must exist in rclone listremotes
- job name allows only letters, numbers, dot, underscore, and hyphen
- interval must be a non-negative integer
- duplicate job names require -Force to replace

### Root Structure

| Key | Type | Description |
| --- | --- | --- |
| settings | object | Global runner behavior and defaults |
| profiles | object | Reusable rclone operation/argument presets |
| jobs | array | List of backup job definitions |

### settings

| Field | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| continueOnJobError | boolean | No | true | Continue processing remaining jobs when one fails |
| defaultOperation | string | No | sync | Allowed values: copy, sync |
| logRetentionCount | integer | No | 10 | Number of log files retained per job |
| jobIntervalSeconds | integer | No | 0 | Global delay between jobs in run mode |
| defaultExtraArgs | string or string[] | No | empty | Appended to every rclone invocation |

### profiles

Object keyed by profile name.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| operation | string | No | Allowed values: copy, sync |
| extraArgs | string or string[] | No | Profile-level additional rclone args |

Example:

```json
{
  "profiles": {
    "docs-small-files": {
      "operation": "sync",
      "extraArgs": [
        "--transfers", "6",
        "--checkers", "12",
        "--drive-chunk-size", "16M"
      ]
    }
  }
}
```

### jobs[]

| Field | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| name | string | Yes | n/a | Must be unique among enabled jobs |
| source | string | Yes | n/a | Local source directory |
| dest | string | Yes | n/a | Must match remote:path |
| enabled | boolean | No | true | Disabled jobs are skipped |
| profile | string | No | empty | Must exist in profiles if provided |
| operation | string | No | resolved | Overrides profile/settings operation |
| interval | integer | No | settings.jobIntervalSeconds | Seconds applied before next job |
| logRetentionCount | integer | No | settings.logRetentionCount | Per-job log retention override |
| extraArgs | string or string[] | No | empty | Appended after defaults/profile args |

### Field Behavior And Precedence

Operation resolution order:

1. CLI -Operation
2. jobs[].operation
3. profiles.<name>.operation
4. settings.defaultOperation
5. sync

Argument merge order:

1. settings.defaultExtraArgs
2. profiles.<name>.extraArgs
3. jobs[].extraArgs
4. --dry-run (when CLI switch is used)

Precedence summary:

| Concern | Highest Priority | Fallback Chain |
| --- | --- | --- |
| Operation | CLI -Operation | jobs[].operation -> profiles.<name>.operation -> settings.defaultOperation -> sync |
| Extra args | jobs[].extraArgs is appended last | settings.defaultExtraArgs -> profiles.<name>.extraArgs -> jobs[].extraArgs |
| Interval | jobs[].interval | settings.jobIntervalSeconds |

Interval behavior in run mode:

- The wait before a job is derived from the previous job interval.
- Per-job jobs[].interval is used first.
- If missing, settings.jobIntervalSeconds is used.
- If both are 0, no delay is inserted.

### Validation Rules

| Rule | Behavior |
| --- | --- |
| jobs[] must exist | Runner exits with configuration error |
| Enabled job names must be unique | Duplicate names are rejected |
| name/source/dest required per enabled job | Missing fields fail validation |
| dest format remote:path | Invalid format fails validation |
| operation values | Only copy or sync are allowed |
| profile existence | Unknown profile name fails validation |
| extraArgs typing | Must be string or non-empty string array when provided |

### Full Example

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
      "extraArgs": [
        "--transfers", "6",
        "--checkers", "12",
        "--drive-chunk-size", "16M",
        "--fast-list"
      ]
    },
    "large-backups": {
      "operation": "sync",
      "extraArgs": [
        "--transfers", "8",
        "--checkers", "4",
        "--drive-chunk-size", "32M",
        "--checksum"
      ]
    }
  },
  "jobs": [
    {
      "name": "documents-backup",
      "enabled": true,
      "profile": "docs-small-files",
      "source": "C:/path/to/documents",
      "dest": "remote:backup/documents",
      "extraArgs": [
        "--metadata"
      ]
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

### Monitor Mode And Configuration

- Monitor mode uses the same jobs[] definitions.
- Changes are grouped by source path and mapped to matching jobs.
- No separate monitor-only config block is required.
- Use the -IdleTimeSeconds CLI flag to tune trigger debounce.

| Monitor Input | Source |
| --- | --- |
| Watched folders | jobs[].source from enabled jobs |
| Triggered jobs | Folder-to-job mapping built from jobs[] |
| Debounce | -IdleTimeSeconds CLI flag |
| Config refresh | Periodic reload of backup-jobs.json |

## Monitor Mode (Real-Time Syncing)

Monitor mode uses a hybrid strategy:

- FileSystemWatcher event stream for immediate change detection
- Polling snapshot fallback to catch missed events

Trigger behavior:

- Changes are tracked by source folder
- Sync starts after idle time is reached (IdleTimeSeconds)
- Mapped jobs for the changed folder are deduplicated before execution
- Config updates are reloaded periodically without restarting the monitor

Monitor-specific command-line flags:

- -Monitor: enable monitor mode
- -IdleTimeSeconds: idle debounce period before running jobs

## Execution Flow

For each run cycle, the high-level order is:

1. Validate internet connectivity
2. Acquire global mutex lock
3. Load and validate configuration
4. Select eligible jobs
5. Execute sync with retry/backoff policy
6. Write summary and telemetry logs

## Logging

Default log directory is logs.

Primary logs:

- runner.log: lifecycle, monitor events, resource telemetry, job results
- runner-error.log: runtime errors and warnings
- <job-name>-<date>.log: per-job rclone output

| File | Purpose |
| --- | --- |
| logs/runner.log | Runner lifecycle, monitor events, resource and job result lines |
| logs/runner-error.log | Runner-level errors and warnings |
| logs/<job-name>/<timestamp>.log | Raw rclone output and job status |

Useful queries:

```powershell
Get-Content logs/runner.log -Tail 100
Select-String -Path logs/runner.log -Pattern "\[RESOURCE\]"
Select-String -Path logs/runner.log -Pattern "\[RESOURCE WARN\]"
Select-String -Path logs/runner.log -Pattern "\[JOB RESULT\]"
```

## Usage

### Common Commands

| Task | Command |
| --- | --- |
| Run eligible jobs | powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 |
| Force all jobs | powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 -Force |
| Dry-run validation | powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 -DryRun |
| Silent execution | powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 -Silent |
| Custom config path | powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 -ConfigPath .\backup-jobs.json |

```powershell
# Run all eligible jobs now
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1

# Force all jobs regardless of interval
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 -Force

# Validate config and command construction only
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 -DryRun

# Silent mode for schedulers
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 -Silent

# Custom configuration file
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Run-RcloneJobs.ps1 -ConfigPath .\backup-jobs.json
```

### Exit Codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Runtime failure |
| 2 | Configuration or validation failure |

## Testing

Run the test suite:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-RcloneJobs.ps1
```

Quick tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-RcloneJobs.ps1 -Quick
```

## Troubleshooting

### Internet Check Fails

- Verify network and DNS access.
- Verify ICMP ping to 8.8.8.8 is allowed in your environment.
- If your environment blocks ping, modify the connectivity check in the script.

### Monitor Mode Not Triggering

- Ensure job source paths exist and are accessible.
- Confirm the script is running with -Monitor.
- Check runner.log for watcher startup and change-detection entries.

### Frequent Rate Limits

- Reduce transfers/checkers in profile flags.
- Increase retries or sleep-related flags in settings.defaultExtraArgs.
- Stagger heavy jobs or run fewer concurrent syncs.

### Quick Reference

| Problem | Check First | Typical Fix |
| --- | --- | --- |
| Internet check fails | ICMP to 8.8.8.8 | Allow ping or adjust connectivity check implementation |
| Monitor not triggering | Source paths and -Monitor flag | Confirm paths, then inspect logs/runner.log |
| Frequent throttling | rclone transfer/checker values | Lower concurrency and increase retry/backoff args |

## Documentation References

- awesome-readme collection: [matiassingers/awesome-readme](https://github.com/matiassingers/awesome-readme)
- readme-best-practices: [jehna/readme-best-practices](https://github.com/jehna/readme-best-practices)

## Notes

This guide is intentionally generic and environment-agnostic. Use paths, remotes, and schedules that match your own setup.
