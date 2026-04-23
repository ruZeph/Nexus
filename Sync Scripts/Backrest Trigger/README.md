# Backrest Live Backup Trigger

This project turns Backrest plan watching into a long-running Windows-friendly daemon flow instead of a one-shot file watcher.

It watches the source folders defined in your Backrest config, filters noisy filesystem churn, batches bursty changes, waits for an idle window, and then triggers the matching Backrest plan through the HTTP API.

## What It Does

- Parses plans from `%APPDATA%\backrest\config.json`
- Attaches `FileSystemWatcher` instances to each configured plan path
- Ignores common noise such as `.tmp`, `.lock`, swap, backup, and download artifacts
- Coalesces rapid file changes into one logical batch per plan
- Debounces dispatch until the folder is idle
- Prevents duplicate monitor instances with layered detection plus mutex ownership
- Persists runtime and batch state under `.state`
- Supports safe shutdown through `.stop-livebackup`
- Logs daemon, launcher, and manager activity for long-lived operation
- Supports detached launch flows for Windows Task Scheduler

## Repo Layout

- [Start-LiveBackup.ps1](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/Start-LiveBackup.ps1>): core daemon runner
- [Launch-LiveBackup.ps1](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/Launch-LiveBackup.ps1>): launcher with detached Task Scheduler mode and optional notification window
- [Test-Suite.ps1](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/Test-Suite.ps1>): integration-style reliability harness
- [tools/Start-BackrestMonitor.ps1](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/tools/Start-BackrestMonitor.ps1>): thin scheduler-friendly wrapper
- [tools/Manage-LiveBackup.ps1](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/tools/Manage-LiveBackup.ps1>): interactive manager for status, safe stop, and forced stop
- [tools/Process-Detection.ps1](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/tools/Process-Detection.ps1>): layered detection helpers

## Runtime Flow

1. The runner loads Backrest plans from `config.json`.
2. Each valid plan path gets a recursive watcher.
3. Relevant file events update in-memory plan state and a persisted runtime heartbeat.
4. When a plan stays quiet for the debounce window, the runner calls `POST /v1.Backrest/Backup` on the configured Backrest endpoint.
5. After the trigger, the runner queries `GetOperations` to confirm that Backrest observed the plan.
6. State is flushed to `.state/trigger-state.json`, and clean shutdown writes final runtime metadata.

## Default Paths

- Backrest config: `%APPDATA%\backrest\config.json`
- Default API endpoint: `http://localhost:9900/v1.Backrest/Backup`
- Trigger state: [`.state/trigger-state.json`](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/.state/trigger-state.json>)
- Runtime heartbeat: [`.state/runtime-state.json`](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/.state/runtime-state.json>)
- Main logs: [`logs/runner.log`](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/logs/runner.log>) and [`logs/runner-error.log`](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/logs/runner-error.log>)
- Launcher and manager logs: [`logs/manager.log`](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/logs/manager.log>) and [`logs/manager-error.log`](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/logs/manager-error.log>)

## Manual Usage

Run the daemon in the foreground:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\Start-LiveBackup.ps1"
```

Run the launcher in the foreground:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\Launch-LiveBackup.ps1"
```

Run the detached launcher path without showing the notification window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\Launch-LiveBackup.ps1" -TaskScheduler -Silent
```

Run the integration suite:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\Test-Suite.ps1"
```

## Safe Stop

Request a clean shutdown by creating the stop file:

```powershell
Set-Content -LiteralPath "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\.stop-livebackup" -Value "Operator requested stop"
```

The runner will dispose watchers, flush state, and release the mutex before exiting.

## Task Scheduler Setup

The intended scheduler target is the wrapper script:

- Program/script: `powershell.exe`
- Add arguments:

```text
-NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\tools\Start-BackrestMonitor.ps1" -Silent
```

- Start in:

```text
C:\Custom User\Nexus\Sync Scripts\Backrest Trigger
```

Recommended trigger styles:

- At log on
- At startup
- On workstation unlock if you want the monitor re-asserted after long idle periods

Optional user environment variable:

- `BACKREST_TRIGGER_LAUNCHER`

If unset, the wrapper falls back to [Launch-LiveBackup.ps1](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/Launch-LiveBackup.ps1>) in this repo.

## Notification Behavior

- `Launch-LiveBackup.ps1 -TaskScheduler` can show a lightweight notification window once the detached monitor is confirmed alive.
- Add `-Silent` to suppress that window for quiet scheduled runs.
- Detached startup stdout and stderr are archived under `logs/launcher/start`.

## Monitoring and Recovery

Open the manager UI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Custom User\Nexus\Sync Scripts\Backrest Trigger\tools\Manage-LiveBackup.ps1"
```

The manager shows:

- current scheduler state
- latest scheduler action
- runtime heartbeat state
- detected live monitor process details
- safe-stop and forced-stop controls

## What To Look For In Logs

Healthy trigger flow for a plan should look like this:

1. `Attached FileSystemWatcher`
2. `Coalesced events queued`
3. `Batch flush: Triggering`
4. `Backrest accepted trigger request` or timeout warning
5. `Backrest operation observed`
6. `Shutdown complete` when stopped

## Notes

- Backrest plan `name` is treated as optional. If absent, the plan `id` is used.
- A timed-out `Backup` HTTP request is not automatically a failure. Backrest can continue the backup in the background.
- `.state/*` is ignored by git so local runtime metadata stays local.

## Verification Status

Validated in this repo with:

- the full integration harness in [Test-Suite.ps1](</C:/Custom User/Nexus/Sync Scripts/Backrest Trigger/Test-Suite.ps1>)
- detached launcher smoke testing in `-TaskScheduler -Silent -TestMode`
- live production verification against the `Windows-Icons` plan on port `9900`
