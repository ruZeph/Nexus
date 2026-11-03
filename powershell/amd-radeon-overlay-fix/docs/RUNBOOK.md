# RUNBOOK — what to do when something breaks

All commands: **elevated PowerShell**. Section root:
`C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix`

---

## 0. Is the overlay alive right now?

```powershell
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class P{[DllImport("user32.dll",SetLastError=true)]public static extern bool RegisterHotKey(IntPtr h,int i,uint m,uint v);[DllImport("user32.dll",SetLastError=true)]public static extern bool UnregisterHotKey(IntPtr h,int i);}'
if ([P]::RegisterHotKey([IntPtr]::Zero,39000,1,[int][char]'R')) { [P]::UnregisterHotKey([IntPtr]::Zero,39000)|Out-Null; 'FREE  -> overlay DEAD' } else { 'HELD  -> overlay ALIVE' }
```

> **Caveat:** this is a *proxy*. AMD handles `Alt+R` with a **low-level keyboard hook**, not
> `RegisterHotKey`, so a "FREE" reading means AMD did not register the hotkey — which
> correlates with a dead overlay, but is not literally the mechanism. Ground truth is:
> press `Alt+R` and see whether the panel opens.

---

## 1. The usual symptom: overlay dead, `Alt+R` does nothing (maybe a beep)

**Most likely it is already being fixed.** The guard probes every 60 s and repairs
automatically within ~1 minute.

```powershell
Get-Content "$env:LOCALAPPDATA\AMD-Overlay-Watchdog\guard.log" -Tail 40
```

Look for `### OVERLAY DEAD` followed by `SUCCESS - Alt+R registered again`.
If you see `FAILED - overlay did not return within 150s`, go to section 4.

---

## 2. Force an immediate repair

```powershell
& "C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix\scripts\fix-amd-overlay.ps1"
```
Equivalent to what the guard does: kills the AMD user-mode stack (and any hung `RSServCmd`)
and relaunches AMD Software through the **Limited** relay task. Takes ~35-50 s.

---

## 3. Is the guard actually running?

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'overlay-guard' } |
  Select-Object ProcessId, CreationDate

Get-ScheduledTask -TaskName 'AMD-Overlay-Guard' | Select-Object TaskName, State
```

If nothing is running:

```powershell
Start-ScheduledTask -TaskName 'AMD-Overlay-Guard'
```

If the task itself is missing or damaged:

```powershell
& "C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix\scripts\install\register-guard.ps1"
```

> **Known limitation:** the guard is a *single long-lived process*. If it is killed, protection
> is lost until the next logon (or until you restart it). Its log rotates at 2 MB.

---

## 4. Guard reports `FAILED - overlay did not return within 150s`

Work down this list:

1. **Hung `RSServCmd` processes** (they deadlock and block the pipeline):
   ```powershell
   Get-CimInstance Win32_Process -Filter "Name='RSServCmd.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
   ```
2. **Kaspersky** — pause protection *and* self-defence, then retry (section 2). Its `klif` filter
   and self-defence are known to block overlay DLL injection. If this fixes it, add exclusions
   for `C:\Program Files\AMD\`.
3. **RSX component** — re-run the RSX reset:
   ```powershell
   & "...\scripts\maintenance\fix-rsx.ps1"
   ```
4. **AMD Software is wedged** — full manual restart, including the service:
   ```powershell
   Stop-Service 'AMD External Events Utility' -Force
   Get-Process | Where-Object { $_.Name -match '^(RadeonSoftware|amdow|cncmd|AMDRSServ|AMDRSSrcExt|RSServCmd|CPUMetricsServer)$' } | Stop-Process -Force
   Start-Service 'AMD External Events Utility'
   Start-ScheduledTask -TaskName 'AMD-Overlay-Relay'
   ```
5. **Then go to section 8 (driver change)** — this is the AMD-side root cause.

---

## 5. The console blinking returned

Identify what is flashing — use the event-based tool (**do not use polling**, it misses 1 ms windows):

```powershell
& "...\scripts\diagnostics\event-capture.ps1"
```

It reports every process creation for 90 s with parent. Look for `conhost.exe`, `cmd.exe`,
`powershell.exe`, `fastlist*.exe`.

Known sources and their fixes:

| What you see | Cause | Fix |
|---|---|---|
| `fastlist-0.3.0-x64.exe` + `conhost` every ~12 s | `Achievements.exe` (npm `ps-list` shells out) | `Disable-ScheduledTask -TaskName 'AchievementsAutoStart'` + kill `Achievements` processes |
| `cmd.exe` parent `java.exe` every ~60 s | CyberPower PowerPanel Watchdog | `Set-Service ppbwd -StartupType Disabled; Stop-Service ppbwd` |
| `powershell.exe -File overlay-guard.ps1` | the guard — **should not happen** (it is long-lived) | Verify `overlay-guard.ps1` is the running version; a *scheduled* per-minute PowerShell would flash |
| `powershell.exe /C "Get-AppxPackage \| Select Name"` bursts | **AMD Software's own component check** | Not suppressible. Bursty, not continuous. |
| `clinfo` + `conhost` | spawned by RadeonSoftware | ditto |

**Critical rule:** never launch PowerShell from a scheduled task directly. Always go through
`run-hidden.vbs` (`wscript.exe` + `WshShell.Run(..., 0, False)`), and prefer a long-lived
process that spawns nothing.

---

## 6. Re-enable the Game Bar stack (full rollback)

```powershell
& "...\scripts\maintenance\rollback-gamebar.ps1"
```
This renames the four `GameBarPresenceWriter.*` binaries back, re-enables the six services to
their previous start types, and re-registers the `Microsoft.XboxGamingOverlay` package.

Then, if a **Windows cumulative update restored** `GameBarPresenceWriter.*` in System32 and the
problems returned, re-apply:
```powershell
& "...\scripts\maintenance\neuter-gamebar-all.ps1"
```

---

## 7. I need Xbox / Game Pass working again

`XblAuthManager` and `XboxNetApiSvc` are disabled, which can break Xbox/Game Pass sign-in.
Re-enable just those two:

```powershell
Set-Service XblAuthManager -StartupType Manual; Start-Service XblAuthManager
Set-Service XboxNetApiSvc  -StartupType Manual
```

And if you use a controller with games that use the modern **GameInput** API:

```powershell
Set-Service GameInputRedistService -StartupType Automatic; Start-Service GameInputRedistService
Set-Service GameInputSvc -StartupType Manual
```

Then watch the overlay for regressions (`guard.log`).

---

## 8. Driver change — the outstanding AMD-side fix

Every previous reinstall used the **same `26.9.2 Optional`** package, so the driver branch never
changed — which is exactly why nothing ever stuck.

1. Download **Adrenalin 26.8.1 WHQL** from amd.com — *not* `26.9.2 Optional`
2. **Disconnect the network** (stops Windows Update injecting a driver mid-install)
3. Run **AMD Cleanup Utility** -> reboot
4. Install 26.8.1; choose **Factory Reset** if offered
5. Do **not** re-import old tuning / game profiles
6. Reconnect network
7. Verify:
   ```powershell
   & "...\scripts\install\register-guard.ps1"
   Get-Content "$env:LOCALAPPDATA\AMD-Overlay-Watchdog\guard.log" -Tail 20
   ```
8. Watch for new `AMDADLXServ.exe` crashes:
   ```powershell
   Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'; StartTime=(Get-Date).Date} |
     Where-Object { $_.Message -match 'AMDADLXServ' } | Measure-Object
   ```
   Before the fix this was **~23 per day**. It should drop sharply.

---

## 9. Useful one-liners

```powershell
# AMD stack inventory
Get-Process | Where-Object { $_.Name -match 'RadeonSoftware|amdow|cncmd|AMDRSServ|AMDRSSrcExt|RSServCmd|CPUMetricsServer' } | Select ProcessName,Id,StartTime

# Hung overlay commands (normally exit in ~40 ms)
Get-CimInstance Win32_Process -Filter "Name='RSServCmd.exe'" | Select ProcessId,CreationDate,CommandLine

# AMD per-game profiles (plain JSON)
(Get-Content "$env:LOCALAPPDATA\AMD\CN\gmdb.blb" -Raw | ConvertFrom-Json).games | Select title,exe_path,hidden,uninstalled

# Which processes hold amdadlx64.dll (AMD's ADLX clients)
tasklist /m amdadlx64.dll

# Clean up logs / free space (ALWAYS inspect %LOCALAPPDATA%\CrashDumps first)
& "...\scripts\maintenance\cleanup-logs.ps1"
```

---

## 10. Log locations

| Path | Contents |
|---|---|
| `%LOCALAPPDATA%\AMD-Overlay-Watchdog\guard.log` | **active** — deaths, repairs, process churn |
| `%LOCALAPPDATA%\AMD-Overlay-Watchdog\archive\` | rotated / archived logs |
| `%LOCALAPPDATA%\AMD-Overlay-Watchdog\gamebar-backup.txt` | original GameDVR registry values |
| `%LOCALAPPDATA%\AMD-Overlay-Watchdog\rollback-gamebar.ps1` | live rollback script |
| `%LOCALAPPDATA%\CrashDumps\` | process crash dumps (**check before deleting!**) |
| `C:\ProgramData\Microsoft\Windows\WER\ReportArchive\` | WER `Report.wer` — faulting module + exception code |
| `%LOCALAPPDATA%\AMD\CN\gmdb.blb` | AMD game database (plain JSON) |
| `%LOCALAPPDATA%\AMD\CN\RSX_Common.log*` | AMD RSX/ADDL component log |
