<!-- markdownlint-disable MD013 -->

# Run-RcloneJobs - Automated Backup Orchestration

A PowerShell-based automation framework for managing rclone backup jobs with:

- Rate limit protection and intelligent job scheduling
- Process locking and comprehensive logging

**Status**: Production-ready | **Tests**: 50+ automated tests | **Coverage**: 100% pass rate

---

## Table of Contents

- [Quick Start](#quick-start)
- [Features](#features)
- [Installation](#installation)
- [Configuration](#configuration)
- [Real-Time Sync Configuration](#real-time-sync-configuration)
- [Usage Guide](#usage-guide)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

---

## Quick Start

### Prerequisites

- PowerShell 5.0+ (or PowerShell 7.x)
- rclone installed and in PATH
- rclone remote configured (e.g., `GDrive_Main`)
- `backup-jobs.json` config file

### Run Jobs Immediately

```powershell
# Run all enabled jobs
.\Run-RcloneJobs.ps1

# Run specific job
.\Run-RcloneJobs.ps1 -JobName "office-docs-backup"

# Dry-run mode (test without transferring)
.\Run-RcloneJobs.ps1 -DryRun

# Silent mode (no console output)
.\Run-RcloneJobs.ps1 -Silent
```

### Run Tests

```powershell
# Run all tests
.\Test-RcloneJobs.ps1

# Run unit tests only
.\Test-RcloneJobs.ps1 -TestSuite Unit

# Run with quick mode (fewer parallel instances)
.\Test-RcloneJobs.ps1 -QuickTest
```

### Schedule with Windows Task Scheduler

```powershell
# Create daily scheduled task at 2 AM
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\Path\To\Run-RcloneJobs.ps1 -Silent"
$trigger = New-ScheduledTaskTrigger -Daily -At 2am
Register-ScheduledTask -Action $action -Trigger $trigger `
  -TaskName "RcloneBackups" `
  -Description "Automated backup jobs"
```

---

## Features

### 1. Rate Limit Detection & Handling

Automatically detects and logs rate-limiting errors from rclone:

- **Detection**: HTTP 403/429 errors, "TooManyRequests", "Rate limit exceeded", "Throttled"
- **Logging**: Marks failures with `(rate limited)` indicator
- **Strategy**: Combines retries, backoff, and job intervals

**Example log output:**

```text
[2026-04-12 22:17:43] START operation=sync source=C:\docs dest=GDrive_Main:docs profile=docs-small-files
[2026-04-12 22:18:03] DONE exitcode=0
[2026-04-12 22:18:03] START operation=sync source=C:\backup dest=GDrive_Main:backup profile=backup-profile
[2026-04-12 22:19:45] FAILED exitcode=1 (rate limited)
```

### 2. Intelligent Job Intervals (Cooldown Between Jobs)

Prevents rate limiting by adding delays between sequential job executions.

**Global setting** (default for all jobs):

```json
{
  "settings": {
    "jobIntervalSeconds": 30
  }
}
```

**Per-job override**:

```json
{
  "jobs": [
    {
      "name": "playnite-backup",
      "interval": 60
    }
  ]
}
```

**Timeline example:**

```text
14:00:00 - Start job1 (office-docs-backup)
14:00:45 - job1 completes
14:01:45 - Wait 60s (job1.interval), then start job2
14:02:30 - job2 completes
14:03:00 - Wait 30s (global setting), then start job3
```

### 3. Mutex-Based Process Locking

Ensures only one script instance runs simultaneously using Windows global mutex.

**Behavior:**

- First instance acquires `Global\RcloneBackupRunner` mutex
- Subsequent instances exit gracefully with: "Another runner instance is already active"
- Automatic cleanup on exit
- Prevents conflicting API calls and log corruption

### 4. Internet Connectivity Check

Verifies internet connectivity before attempting backup operations.

- Pings Google DNS (8.8.8.8) at startup
- Exits gracefully with error if no connection
- Prevents failed backup attempts on disconnected systems

### 5. Comprehensive Logging System

**Log locations:**

- Per-job logs: `logs/<job-name>/YYYYMMDD-HHMMSS.log`
- Runner logs: `logs/runner.log` (overall execution)
- Error logs: `logs/runner-error.log` (script errors)

**Log retention:**

- Configurable per-job (default: 10 files)
- Automatically deletes oldest logs when limit exceeded
- Prevents disk space issues

### 6. Flexible Configuration System

- Global settings for all jobs
- Profile templates for reusable configurations
- Per-job overrides for fine-tuning
- JSON-based, human-readable format

### 7. Error Handling & Resilience

- **Continue on error**: Skip failed jobs, continue with next
- **Fail-fast mode**: Stop immediately on first error
- **Graceful degradation**: Handle missing configs, invalid JSON, missing sources
- **Automatic retry**: Built-in rclone retry logic with exponential backoff

---

## Installation

### 1. Clone or Download

```powershell
# Using git
git clone https://github.com/ruZeph/Nexus.git
cd "Nexus/Sync Scripts"

# Or download manually
# Download Run-RcloneJobs.ps1, backup-jobs.json, Test-RcloneJobs.ps1
```

### 2. Install rclone

```powershell
# Using chocolatey
choco install rclone

# Or download from https://rclone.org/downloads/
```

### 3. Configure rclone Remote

```powershell
# Launch rclone config wizard
rclone config

# Name it: GDrive_Main
# Type: Google Drive
# Follow authentication flow
```

### 4. Update Configuration

Edit `backup-jobs.json` with your backup jobs and sources.

### 5. Test Execution

```powershell
# Test with dry-run first
.\Run-RcloneJobs.ps1 -DryRun

# Run tests
.\Test-RcloneJobs.ps1 -TestSuite Unit
```

---

## Configuration

### Complete Configuration Example

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
      "--timeout", "10m",
      "--drive-acknowledge-abuse",
      "--cutoff-mode", "cautious",
      "--exclude", "*.ffs_db",
      "--exclude", "*.swp",
      "--exclude", "*.lock"
    ]
  },
  "profiles": {
    "docs-small-files": {
      "operation": "sync",
      "extraArgs": [
        "--transfers", "6",
        "--checkers", "12",
        "--drive-chunk-size", "16M",
        "--fast-list",
        "--exclude", "~$*"
      ]
    },
    "large-backups": {
      "operation": "sync",
      "extraArgs": [
        "--transfers", "8",
        "--checkers", "4",
        "--drive-chunk-size", "32M",
        "--no-update-modtime",
        "--fast-list",
        "--checksum"
      ]
    }
  },
  "jobs": [
    {
      "name": "office-docs-backup",
      "enabled": true,
      "profile": "docs-small-files",
      "source": "C:\\Users\\Avisek\\Documents\\Office Docs",
      "dest": "GDrive_Main:Documents/Office_Docs",
      "extraArgs": [
        "--metadata"
      ]
    },
    {
      "name": "playnite-backup",
      "enabled": true,
      "profile": "large-backups",
      "source": "C:\\Custom User\\Ludusavi\\PlayniteBackups",
      "dest": "GDrive_Main:Backups/playnite-restic",
      "interval": 60,
      "logRetentionCount": 5,
      "extraArgs": [
        "--update"
      ]
    }
  ]
}
```

### Settings Reference

| Setting | Type | Description |
| --------- | ------ | ------------- |
| `continueOnJobError` | boolean | Continue to next job if one fails (default: true) |
| `defaultOperation` | string | Operation for all jobs: `sync` or `copy` |
| `logRetentionCount` | number | Keep last N log files per job (default: 10) |
| `jobIntervalSeconds` | number | Seconds to wait between jobs (default: 30) |
| `defaultExtraArgs` | array | Default rclone arguments for all jobs |

### Profile Reference

Reusable configurations for common job types.

```json
{
  "profiles": {
    "profile-name": {
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

### Job Reference

Individual backup job definitions.

```json
{
  "jobs": [
    {
      "name": "unique-job-name",
      "enabled": true,
      "profile": "profile-name",
      "operation": "sync",
      "source": "C:\\local\\path",
      "dest": "remote:path/to/backup",
      "interval": 60,
      "logRetentionCount": 5,
      "extraArgs": ["--metadata"]
    }
  ]
}
```

| Job Property | Type | Required | Description |
| ------------- | ------ | ---------- | ------------- |
| `name` | string | Yes | Unique job identifier |
| `enabled` | boolean | No | Enable/disable job (default: true) |
| `profile` | string | No | Reference to profile (optional) |
| `operation` | string | No | Override profile operation |
| `source` | string | Yes | Local source path |
| `dest` | string | Yes | Destination in format `remote:path` |
| `interval` | number | No | Override global interval (seconds) |
| `logRetentionCount` | number | No | Override global retention count |
| `extraArgs` | array | No | Job-specific rclone arguments |

---

## Real-Time Sync Configuration

### Current Production Setup

The following is the active configuration currently running:

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
      "--timeout", "10m",
      "--drive-acknowledge-abuse",
      "--cutoff-mode", "cautious",
      "--exclude", "*.ffs_db",
      "--exclude", "*.swp",
      "--exclude", "*.lock"
    ]
  },
  "profiles": {
    "docs-small-files": {
      "operation": "sync",
      "extraArgs": [
        "--transfers", "6",
        "--checkers", "12",
        "--drive-chunk-size", "16M",
        "--fast-list",
        "--exclude", "~$*"
      ]
    },
    "playnite-restic": {
      "operation": "sync",
      "extraArgs": [
        "--transfers", "8",
        "--checkers", "4",
        "--drive-chunk-size", "32M",
        "--no-update-modtime",
        "--fast-list",
        "--checksum"
      ]
    }
  },
  "jobs": [
    {
      "name": "office-docs-backup",
      "enabled": true,
      "profile": "docs-small-files",
      "source": "C:\\Users\\Avisek\\Documents\\Office Docs",
      "dest": "GDrive_Main:Documents/Office_Docs",
      "extraArgs": ["--metadata"]
    },
    {
      "name": "playnite-backup",
      "enabled": true,
      "profile": "playnite-restic",
      "source": "C:\\Custom User\\Ludusavi\\PlayniteBackups",
      "dest": "GDrive_Main:Backups/playnite-restic",
      "interval": 60,
      "extraArgs": ["--update"]
    }
  ]
}
```

### Active Jobs

#### Job 1: office-docs-backup

- **Source**: `C:\Users\Avisek\Documents\Office Docs`
- **Destination**: `GDrive_Main:Documents/Office_Docs`
- **Operation**: Sync (bidirectional mirroring)
- **Profile**: docs-small-files
- **Schedule**: Every 30 seconds (global interval)
- **Chunk Size**: 16M (suitable for files < 100MB)
- **Parallelism**: 6 transfers, 12 checkers
- **Features**: Metadata preservation, fast-list, excludes temp files
- **Log Retention**: 10 files (global default)

#### Job 2: playnite-backup

- **Source**: `C:\Custom User\Ludusavi\PlayniteBackups`
- **Destination**: `GDrive_Main:Backups/playnite-restic`
- **Operation**: Sync
- **Profile**: playnite-restic
- **Schedule**: Every 60 seconds (job-specific interval)
- **Chunk Size**: 32M (suitable for larger archives)
- **Parallelism**: 8 transfers, 4 checkers
- **Features**: Checksum verification, preserves modification time, fast-list, update flag
- **Log Retention**: 10 files (global default)

### Global Settings Explained

| Setting | Current Value | Rationale |
| --------- | --- | --- |
| Retries | 15 | Handles temporary Google Drive rate limits |
| Retry Sleep | 30s | Exponential backoff with 30s base delay |
| Connection Timeout | 30s | Fails fast on network issues |
| Overall Timeout | 10m | Prevents hanging transfers |
| Drive Acknowledge Abuse | Enabled | Acknowledges files flagged by Google |
| Cutoff Mode | Cautious | Safer incomplete transfer handling |
| Job Interval | 30s | Prevents API rate limiting |

### Sync Operation Details

**What Sync Does:**

- Ensures destination mirrors source
- Deletes files from destination not in source (use `copy` to prevent this)
- Transfers new/modified files from source to destination
- Bidirectional safety checks

**Profile Tuning:**

| Profile | Use Case | Transfers | Checkers | Chunk Size |
| --------- | ---------- | ----------- | ---------- | ----------- |
| docs-small-files | 10-100 files | 6 | 12 | 16M |
| playnite-restic | Large files/archives | 8 | 4 | 32M |

**Chunk Size Notes:**

- Must be a power of 2: 1M, 2M, 4M, 8M, 16M, 32M, 64M, 128M, 256M
- Larger = better for large files, worse for small files
- Smaller = safer for unreliable connections

### Rate Limiting Protection

Active mechanisms preventing rate limit errors:

1. **Retry Logic**: 15 automatic retries with exponential backoff
2. **Job Intervals**: 30-60 second gaps between jobs
3. **Parallelism Limits**: Balanced transfers/checkers for API quotas
4. **Drive Acknowledge**: Handles abuse-flagged files gracefully
5. **Cutoff Mode**: Cautious approach to partial transfers

### RealTimeSync Integration

Trigger backups automatically when folder changes are detected using RealTimeSync.

**RealTimeSync Setup for Playnite Backups:**

1. **Open RealTimeSync 14.9+**
2. **Configure folder monitoring:**
   - Folders to watch: `C:\Custom User\Ludusavi\PlayniteBackups`
   - Idle time: `60` seconds (prevents repeated triggers during rapid changes)
3. **Set command line to trigger backup (with required `-Silent` flag):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Run-RcloneJobs.ps1" -JobName "playnite-backup" -Silent
```

**Command breakdown:**

- `powershell.exe` - PowerShell executable
- `-NoProfile` - Skip profile loading (faster execution)
- `-ExecutionPolicy Bypass` - Allow script execution
- `-File` - Path to Run-RcloneJobs.ps1
- `-JobName "playnite-backup"` - Run only playnite-backup job
- `-Silent` - **REQUIRED** - No console output (mandatory for RealTimeSync automated execution)

**How it works:**

1. RealTimeSync monitors folder for changes
2. When changes detected, waits 60 seconds (idle time)
3. If no more changes, triggers the PowerShell command
4. Script acquires mutex, checks internet, runs playnite-backup job
5. Files synced to `GDrive_Main:Backups/playnite-restic`
6. Job completes, waits 60 seconds before next job (interval)

**Alternative commands (all with `-Silent` for RealTimeSync):**

```powershell
# Run all enabled jobs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Run-RcloneJobs.ps1" -Silent

# Run with dry-run (preview only, no transfer)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Run-RcloneJobs.ps1" -JobName "playnite-backup" -DryRun -Silent

# Run different job
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Run-RcloneJobs.ps1" -JobName "office-docs-backup" -Silent
```

**Performance Tips:**

- **`-Silent` flag is MANDATORY for RealTimeSync** - reduces overhead and prevents console window spawning
- Set idle time to at least 30-60 seconds (prevents excessive triggers)
- Monitor logs in `logs/playnite-backup/` to verify triggers
- Check `logs/runner.log` for overall execution history

**Troubleshooting RealTimeSync integration:**

| Issue | Solution |
| ------- | ---------- |
| Command not executing | Verify PowerShell path: `where powershell.exe` |
| Script hangs or times out | Another instance running (mutex lock) - wait or stop it |
| No output visible | Use `-Silent` flag for background execution (normal) |
| Files not syncing | Check internet connection, verify source folder path |
| Frequent triggers | Increase idle time to 120+ seconds |

---

## Usage Guide

### Command Line Options

```powershell
.\Run-RcloneJobs.ps1 [options]
```

| Option | Type | Description |
| -------- | ------ | ------------- |
| `-ConfigPath` | string | Path to config JSON (default: ./backup-jobs.json) |
| `-JobName` | string | Run specific job by name |
| `-DryRun` | switch | Test mode, no transfers (use `--dry-run` in rclone) |
| `-Operation` | string | Override operation: `copy` or `sync` |
| `-FailFast` | switch | Exit immediately on first error |
| `-Silent` | switch | No console output |

### Usage Examples

```powershell
# Run all enabled jobs
.\Run-RcloneJobs.ps1

# Run specific job only
.\Run-RcloneJobs.ps1 -JobName "office-docs-backup"

# Dry-run mode (preview changes, no transfer)
.\Run-RcloneJobs.ps1 -DryRun

# Copy instead of sync (preserve destination files)
.\Run-RcloneJobs.ps1 -Operation copy

# Exit on first error
.\Run-RcloneJobs.ps1 -FailFast

# Silent background execution
.\Run-RcloneJobs.ps1 -Silent

# Custom config file
.\Run-RcloneJobs.ps1 -ConfigPath "C:\backup\prod-config.json"

# Combination
.\Run-RcloneJobs.ps1 -JobName "office-docs-backup" -DryRun -Silent
```

### Exit Codes

| Code | Meaning |
| ------ | --------- |
| 0 | Success or graceful exit (another instance running) |
| 1 | Error or job failure (with FailFast enabled) |

### Viewing Logs

```powershell
# View today's logs for a job
Get-ChildItem logs\office-docs-backup\*.log -Newer (Get-Date).AddHours(-24)

# View overall runner log
Get-Content logs\runner.log -Tail 50

# Search for errors
Select-String "ERROR" logs\runner.log

# Search for rate limit errors
Select-String "rate limited" logs\office-docs-backup\*.log
```

---

## Testing

### Test Suite Overview

**50+ automated tests** covering:

- Unit tests: Core functions and error handling
- Integration tests: Full script execution
- Parallel tests: Concurrency and mutex locking
- Failure tests: Error scenarios and recovery

### Running Tests

```powershell
# Run all tests (full suite)
.\Test-RcloneJobs.ps1

# Run specific test category
.\Test-RcloneJobs.ps1 -TestSuite Unit
.\Test-RcloneJobs.ps1 -TestSuite Integration
.\Test-RcloneJobs.ps1 -TestSuite Parallel

# Quick mode (fewer parallel instances)
.\Test-RcloneJobs.ps1 -TestSuite Parallel -QuickTest

# Keep test logs for inspection
.\Test-RcloneJobs.ps1 -Verbose
```

### Test Categories

#### Unit Tests (22 tests)

- Configuration parsing and validation
- JSON format checking
- Function structure verification
- Error handling for invalid inputs
- Special character sanitization
- Rate limit detection
- Timeout handling

**Run:** `.\Test-RcloneJobs.ps1 -TestSuite Unit`

#### Integration Tests (7+ tests)

- Dry-run execution
- Full script validation
- Log file structure
- Performance metrics
- Real dry-run with actual rclone
- Configuration consistency
- Chunk size validation

**Run:** `.\Test-RcloneJobs.ps1 -TestSuite Integration`

#### Parallel Tests (3+ test groups)

- Mutex locking verification
- 3 concurrent instances
- 5 concurrent load test (2 in quick mode)
- Process synchronization
- Race condition detection

**Run:** `.\Test-RcloneJobs.ps1 -TestSuite Parallel`

### Test Results Interpretation

✅ **All Pass (100% expected):**

```text
Passed:     50+
Failed:     0
Pass Rate:  100%

✓ All tests passed!
```

✗ **Some Fail:**

- Check specific failure messages
- Review configuration changes
- Verify rclone availability
- Check disk space and permissions

### Expected Performance

| Test Category | Expected Time | Max Acceptable |
| --------------- | --- | --- |
| Unit tests | 5-10s | 15s |
| Integration tests | 20-40s | 60s |
| Parallel tests | 15-30s | 45s |
| Full suite | 60-120s | 180s |
| Quick mode | 30-60s | 90s |

---

## Troubleshooting

### Problem: "Another runner instance is already active"

**Cause:** Multiple instances running simultaneously

**Solutions:**

1. Wait for previous instance to complete
2. Check Task Scheduler for running task
3. Check Process Explorer for PowerShell processes
4. Kill stuck processes: `Stop-Process -Name powershell -Force`

### Problem: Frequent rate limit errors

**Cause:** API quotas exceeded due to too many requests

**Solutions:**

1. Increase `jobIntervalSeconds`: `30` → `60` or `90`
2. Reduce `--transfers` in profiles: `6` → `4` or `3`
3. Reduce `--checkers`: `12` → `6` or `4`
4. Schedule jobs at different times
5. Contact rclone support for quota increases

**Example fix:**

```json
{
  "settings": {
    "jobIntervalSeconds": 60
  },
  "profiles": {
    "docs-small-files": {
      "extraArgs": ["--transfers", "3", "--checkers", "6"]
    }
  }
}
```

### Problem: "Invalid chunk size: 24M"

**Cause:** Chunk size must be a power of 2

**Solutions:**

- Valid: 1M, 2M, 4M, 8M, 16M, 32M, 64M, 128M, 256M
- Invalid: 3M, 5M, 24M, 48M

**Fix:**

```json
{
  "profiles": {
    "profile-name": {
      "extraArgs": ["--drive-chunk-size", "32M"]
    }
  }
}
```

### Problem: No internet connection detected

**Cause:** Script checks internet connectivity before running

**Solutions:**

1. Verify internet connection: `ping 8.8.8.8`
2. Check firewall rules allow ICMP
3. Verify DNS resolution works
4. For networks blocking ping, modify check in script

### Problem: Jobs not running on schedule

**Cause:** Task Scheduler issue or bad configuration

**Solutions:**

1. Verify Task Scheduler task exists: `Get-ScheduledTask -TaskName "RcloneBackups"`
2. Check task history for errors
3. Verify config file path in task action
4. Test manual execution: `.\Run-RcloneJobs.ps1`
5. Check log files for details

### Problem: Disk space exhausted by logs

**Cause:** Log retention not being applied

**Solutions:**

1. Check `logRetentionCount` setting (should be 10 or less)
2. Manually clean old logs: `Remove-Item logs\* -Recurse -Force`
3. Set more aggressive retention:

   ```json
   {"settings": {"logRetentionCount": 5}}
   ```

4. Verify script has write permissions to logs directory

### Problem: Rclone connection timeout

**Cause:** Network issue or slow Google Drive

**Solutions:**

1. Increase `--timeout`: `"10m"` → `"15m"`
2. Increase `--contimeout`: `"30s"` → `"60s"`
3. Verify internet speed and stability
4. Check rclone logs for specific errors
5. Try sync during off-peak hours

### Problem: Test suite hangs

**Cause:** Parallel tests or rclone process stuck

**Solutions:**

1. Kill hung processes: `Stop-Process -Name powershell -Force`
2. Run quick tests: `.\Test-RcloneJobs.ps1 -QuickTest`
3. Restart PowerShell
4. Check for resource exhaustion (CPU, memory)
5. Verify temp directory accessible

---

## Best Practices

### Configuration Management

1. **Use profiles** to reduce duplication
2. **Test with dry-run first** before production
3. **Set appropriate job intervals** (30-60+ seconds)
4. **Exclude temporary files** (lock files, cache, etc.)
5. **Use reasonable chunk sizes** (16M or 32M)
6. **Log retention** of 5-10 files
7. **Keep config in version control** (backup-jobs.json)

### Rate Limiting

1. **Start conservative**: Lower transfers/checkers, higher intervals
2. **Monitor logs** for rate limit indicators
3. **Gradually increase** parallelism as needed
4. **Use retries** (15 is good baseline)
5. **Acknowledge abuse** for Google Drive
6. **Add delays** between jobs (global + per-job)

### Monitoring & Maintenance

1. **Review logs regularly** for errors or warnings
2. **Test suite monthly** (`.\Test-RcloneJobs.ps1`)
3. **Monitor disk usage** (logs directory)
4. **Keep PowerShell updated**
5. **Keep rclone updated** (`rclone selfupdate`)
6. **Document changes** to configuration

### Scheduling

1. **Use Task Scheduler** for reliable automation
2. **Schedule during low-traffic hours** if possible
3. **Space jobs out** with appropriate intervals
4. **Avoid peak times** for cloud services
5. **Set appropriate job interval** (30-60+ seconds)
6. **Enable `-Silent` mode** for scheduled tasks

### Error Handling

1. **Set `continueOnJobError: true`** to skip failed jobs
2. **Use `FailFast` flag** only for critical jobs
3. **Monitor error logs** for patterns
4. **Implement alerting** on repeated failures
5. **Have manual intervention plan** for severe failures

---

## Architecture

### Components

- **Run-RcloneJobs.ps1**: Main orchestration script
- **Test-RcloneJobs.ps1**: Comprehensive test suite
- **backup-jobs.json**: Configuration file

### Key Functions

| Function | Purpose |
| ---------- | --------- |
| `Test-InternetConnectivity` | Verifies internet before running |
| `Test-RateLimitError` | Detects rate limit errors in logs |
| `Remove-OldJobLog` | Enforces log retention limits |
| `Invoke-RcloneLive` | Executes rclone with logging |
| `Get-ConfigProperty` | Safely retrieves config values |

### Process Flow

```text
1. Start Run-RcloneJobs.ps1
2. Acquire mutex lock (exit if already running)
3. Check internet connectivity (exit if no connection)
4. Load configuration from JSON
5. For each enabled job:
   a. Create log file
   b. Apply log retention
   c. Build rclone command
   d. Execute rclone with live output
   e. Detect rate limits in output
   f. Log status (DONE/FAILED)
   g. Wait for job interval before next job
6. Release mutex lock
7. Exit with appropriate code
```

---

## Support & Contribution

### Reporting Issues

1. Check [Troubleshooting](#troubleshooting) section
2. Run `.\Test-RcloneJobs.ps1` to identify issue area
3. Include relevant logs from `logs/` directory
4. Provide configuration (sanitized)

### Contributing

1. Fork repository
2. Create feature branch: `git checkout -b feature/name`
3. Make changes on dedicated branch
4. Run test suite: `.\Test-RcloneJobs.ps1`
5. Commit with clear messages
6. Push and create pull request

---

## License

Specify your license here (e.g., MIT, Apache 2.0)

---

## Changelog

### Version 1.0.0 (Latest)

**Features:**

- ✅ Rate limit detection
- ✅ Job intervals/cooldown
- ✅ Mutex process locking
- ✅ Internet connectivity check
- ✅ Comprehensive logging with retention
- ✅ Flexible configuration system
- ✅ 50+ automated tests
- ✅ Real dry-run integration tests
- ✅ Configuration consistency validation
- ✅ Chunk size power-of-2 validation

**Fixes:**

- ✅ Log retention now properly enforced
- ✅ Test suite no longer triggers accidental backups
- ✅ Internet connectivity check runs before operations

---

## Version Info

- **Script Version**: 1.0.0
- **PowerShell**: 5.0+
- **Rclone**: 1.50+
- **Last Updated**: April 12, 2026
- **Branch**: rclone-sync-jobs

---

**Questions?** Check logs in `logs/` directory or run tests with `-Verbose` flag.

**Ready to migrate to production?** Test with `-DryRun` first, then schedule with Task Scheduler.
