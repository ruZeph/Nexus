# Run-RcloneJobs Features

## Overview

`Run-RcloneJobs.ps1` is a PowerShell script that manages automated rclone backup jobs with rate limit protection, job scheduling, and comprehensive logging.

## Key Features

### 1. Rate Limit Detection

The script automatically detects rate limit errors (HTTP 403, 429 responses) in job logs:

- Monitors rclone output for rate limit indicators
- Logs rate limit status alongside exit codes
- Helps identify when jobs fail due to API throttling

**Detection patterns:**

- HTTP status codes: 403, 429
- Error messages: "TooManyRequests", "rate limit", "Rate limit exceeded", "Throttled"

**Usage:**
The script automatically flags rate-limited failures in logs:

```text
[timestamp] FAILED exitcode=1 (rate limited)
```

### 2. Job Intervals (Cooldown Between Jobs)

Prevents rate limiting by adding delays between sequential job executions:

**Global setting** (applies to all jobs by default):

```json
{
  "settings": {
    "jobIntervalSeconds": 30
  }
}
```

**Per-job override** (only affects this specific job):

```json
{
  "jobs": [
    {
      "name": "my-job",
      "enabled": true,
      "source": "path/to/source",
      "dest": "remote:path",
      "interval": 60
    }
  ]
}
```

**Behavior:**

- Global interval: 30 seconds (default)
- Interval applies **after** a job completes, before the next job starts
- Per-job interval value overrides the global setting
- Set to 0 to disable intervals

**Example execution timeline:**

```text
14:00:00 - Start job1
14:00:45 - job1 completes
14:01:45 - Wait 60s (job1.interval), then start job2
14:02:30 - job2 completes  
14:02:30 - Wait 30s (global jobIntervalSeconds, since job2 has no override), then start job3
14:03:00 - job3 starts
```

### 3. Mutex-based Process Lock

Prevents multiple instances from running simultaneously:

- Uses Windows global mutex: `Global\RcloneBackupRunner`
- Ensures only one script instance runs at a time
- Automatic cleanup on exit

**Behavior:**

- First instance acquires mutex and runs jobs
- Subsequent instances exit gracefully with message: "Another runner instance is already active"
- Prevents conflicting API calls and log corruption

### 4. Comprehensive Logging

- **Per-job logs**: Timestamped logs for each job in `logs/<job-name>/`
- **Runner logs**: `logs/runner.log` tracks overall execution
- **Error logs**: `logs/runner-error.log` for script errors
- Log retention: Configurable per-job (default: 10 files)

## Configuration

### settings

```json
{
  "settings": {
    "continueOnJobError": true,           // Continue running next job if one fails
    "defaultOperation": "sync",            // Default operation: sync or copy
    "logRetentionCount": 10,              // Keep last N log files per job
    "jobIntervalSeconds": 30,             // Default interval between jobs
    "defaultExtraArgs": [                 // Default rclone args for all jobs
      "--retries", "15",
      "--retries-sleep", "30s"
    ]
  }
}
```

### profiles

Reusable configurations for job types:

```json
{
  "profiles": {
    "profile-name": {
      "operation": "sync",
      "extraArgs": ["--transfers", "6", "--checkers", "12"]
    }
  }
}
```

### jobs

Individual backup job definitions:

```json
{
  "jobs": [
    {
      "name": "job-name",
      "enabled": true,
      "profile": "profile-name",          // Reference a profile (optional)
      "operation": "sync",                // Override profile operation (optional)
      "source": "C:\\local\\path",
      "dest": "remote:path",
      "interval": 60,                     // Override global interval (optional)
      "logRetentionCount": 5,             // Override global retention (optional)
      "extraArgs": ["--metadata"]         // Job-specific args (optional)
    }
  ]
}
```

## Command Line Usage

```powershell
# Run all enabled jobs
.\Run-RcloneJobs.ps1

# Run specific job
.\Run-RcloneJobs.ps1 -JobName "job-name"

# Dry-run mode
.\Run-RcloneJobs.ps1 -DryRun

# Override operation
.\Run-RcloneJobs.ps1 -Operation copy

# Stop on first failure
.\Run-RcloneJobs.ps1 -FailFast

# Silent mode (no console output)
.\Run-RcloneJobs.ps1 -Silent

# Custom config file
.\Run-RcloneJobs.ps1 -ConfigPath "C:\path\to\config.json"
```

## Rate Limit Handling Strategy

### Recommended Settings

```json
{
  "settings": {
    "jobIntervalSeconds": 30,
    "continueOnJobError": true,
    "defaultExtraArgs": [
      "--retries", "15",
      "--retries-sleep", "30s",
      "--drive-acknowledge-abuse",
      "--cutoff-mode", "cautious"
    ]
  }
}
```

### How It Works

1. **Retry logic**: Rclone's `--retries 15` automatically retries on rate limits
2. **Backoff**: `--retries-sleep 30s` adds delay between retries  
3. **Job intervals**: Script waits between jobs to reduce API pressure
4. **Detection**: Script logs rate limit failures for monitoring

### When Rate Limited

- Rclone will retry transfers automatically
- Script logs the failure with rate limit indicator
- Next job waits specified interval before starting
- Job marked as failed unless retries succeed

## Error Handling

### Scenarios

1. **Rate Limited**: Job fails, logged as "(rate limited)", continues to next job
2. **Source Missing**: Job skipped, logs "SKIP source missing"
3. **Invalid Config**: Script exits immediately with error log
4. **Next Instance Running**: Script exits gracefully with message

### Exit Codes

- `0`: Success or graceful exit (another instance running)
- `1`: Error or job failure (if FailFast enabled)

## Logging Examples

```text
[2024-01-15 14:00:00] START operation=sync source=C:\docs dest=remote:docs profile=my-profile dryrun=False
[2024-01-15 14:02:15] Waiting 60s before next job...
[2024-01-15 14:03:15] DONE exitcode=0
[2024-01-15 14:03:15] START operation=sync source=C:\backup dest=remote:backup profile=default dryrun=False
[2024-01-15 14:04:02] FAILED exitcode=1 (rate limited)
```

## Best Practices

1. **Set appropriate intervals**: 30-60s prevents most rate limiting issues
2. **Use profiles**: Keep configs DRY with reusable profile configurations  
3. **Monitor logs**: Check `logs/runner.log` regularly for issues
4. **Test dry-run first**: Use `-DryRun` before running actual jobs
5. **Handle rate limits**: If frequent, increase `jobIntervalSeconds` or reduce transfer concurrency
6. **Adjust retries**: Increase `--retries` value for unreliable connections

## Troubleshooting

### "Another runner instance is already active"

- Only one instance can run at a time
- Check Task Schedule or running processes for other instances
- Wait for previous instance to complete or kill it manually

### Frequent rate limits despite settings

- Increase `jobIntervalSeconds` to 60-120
- Reduce `--transfers` and `--checkers` in profiles
- Consider running jobs at different times

### Mutex lock stuck

- Kill PowerShell processes running the script
- Script cleanup will release the mutex on next run attempt

### High memory or CPU usage

- Reduce `--transfers` in profiles
- Reduce `--checkers` value
- Run with smaller `--drive-chunk-size`
