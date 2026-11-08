# CHANGELOG — every change made to this system

Date: **2026-10-10**. All commands assume an **elevated** PowerShell.
Section root: `C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix`
Rollback lines are the exact reversal.

---

## A. Scheduled tasks

### A1. `AMD-Overlay-Guard` — CREATED (active)
Long-lived hidden process: probes `Alt+R` every 60 s, repairs on death, logs process churn.
```powershell
# created by:
& "C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix\scripts\install\register-guard.ps1"
# action : wscript.exe "...\scripts\run-hidden.vbs" "...\scripts\overlay-guard.ps1"
# RunLevel=Highest, LogonType=Interactive, trigger=AtLogOn+20s
```
**Rollback:** `Unregister-ScheduledTask -TaskName 'AMD-Overlay-Guard' -Confirm:$false`

### A2. `AMD-Overlay-Relay` — CREATED (active)
On-demand. Runs `C:\Program Files\AMD\CNext\CNext\cncmd.exe startwithdelay` at **RunLevel=Limited**
so AMD Software relaunches at normal integrity.
```powershell
& "C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix\scripts\install\register-relay.ps1"
```
**Rollback:** `Unregister-ScheduledTask -TaskName 'AMD-Overlay-Relay' -Confirm:$false`

### A3. `AMD-Overlay-Watchdog` — DISABLED (legacy)
Per-minute watchdog (launched `powershell.exe` directly -> caused a **console flash every minute**).
Superseded by the guard.
**Rollback:** `Enable-ScheduledTask -TaskName 'AMD-Overlay-Watchdog'` *(not recommended — flashes)*

### A4. `AMD-Overlay-Forensic` — DISABLED (legacy)
2-second `Alt+R` prober. Superseded; **removed because its probe could beat AMD's own
registration and cause deaths** (observer effect — see `FINDINGS.md` section 4).
**Rollback:** `Enable-ScheduledTask -TaskName 'AMD-Overlay-Forensic'` *(not recommended)*

### A5. `AchievementsAutoStart` — DISABLED
Was spawning `fastlist-0.3.0-x64.exe` + `conhost.exe` **every 12 seconds** (console flash).
```powershell
Disable-ScheduledTask -TaskName 'AchievementsAutoStart'
```
**Rollback:** `Enable-ScheduledTask -TaskName 'AchievementsAutoStart'`

### A6. `CapFrameX` — re-ENABLED (was temporarily disabled during testing)
Ruled innocent; restored to its original state.
```powershell
Enable-ScheduledTask -TaskName 'CapFrameX'; Start-ScheduledTask -TaskName 'CapFrameX'
```

---

## B. Services

| Service | From | To | Reason |
|---|---|---|---|
| `GameInputRedistService` | Auto / Running | **Disabled** | Xbox input stack; part of the Game Bar presence activation path |
| `GameInputSvc` | Manual | **Disabled** | ditto |
| `XblAuthManager` | Manual / Running | **Disabled** | Xbox gaming stack |
| `XblGameSave` | Manual | **Disabled** | ditto |
| `XboxGipSvc` | Manual | **Disabled** | Xbox Accessory Management |
| `XboxNetApiSvc` | Manual | **Disabled** | ditto |
| `ppbwd` | Auto / Running | **Disabled** | CyberPower PowerPanel Watchdog — spawned `cmd.exe` every ~60 s (console flash) |
| `PresentMonSharedService` | Auto | Auto | **unchanged** — disabled during testing, then restored (innocent) |

```powershell
# rollback for the Xbox/GameInput set:
foreach ($s in 'GameInputRedistService','GameInputSvc','XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc') {
    Set-Service $s -StartupType Manual
}
# rollback for CyberPower:
Set-Service ppbwd -StartupType Automatic; Start-Service ppbwd
```

---

## C. Files renamed (Game Bar binaries — reversible rename, NOT deletion)

| File | Renamed to |
|---|---|
| `C:\Windows\System32\GameBarPresenceWriter.exe` | `...exe.disabled` |
| `C:\Windows\System32\GameBarPresenceWriter.proxy.dll` | `...dll.disabled` |
| `C:\Windows\SysWOW64\GameBarPresenceWriter.exe` | `...exe.disabled` |
| `C:\Windows\SysWOW64\GameBarPresenceWriter.proxy.dll` | `...dll.disabled` |

Took ownership first: `takeown /f <file> /a` + `icacls <file> /grant *S-1-5-32-544:F`.
Effect confirmed: Windows now logs
`DCOM 10000: Unable to start a DCOM Server: Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter`
— i.e. it can no longer start.

```powershell
& "...\scripts\maintenance\rollback-gamebar.ps1"
```
> A Windows cumulative update may restore these files. If flashing or overlay deaths return
> after a Windows update, re-run `scripts\maintenance\neuter-gamebar-all.ps1`.

---

## D. Appx packages

| Package | Action | Reason | Rollback |
|---|---|---|---|
| `Microsoft.XboxGamingOverlay` | Removed + deprovisioned | Xbox Game Bar (created the presence writer) | Install "Xbox Game Bar" from Microsoft Store |
| `AdvancedMicroDevicesInc-RSXCM` | Removed | Was the stale **22.10.0.0 / Oct 2022** build vs a 26.9.2 app; suspected cause of the `_from_rsx` deadlock | Re-created automatically by the next AMD driver install |

---

## E. Registry

### E1. GameDVR / Game Bar lockdown
```
HKCU\System\GameConfigStore\GameDVR_Enabled                        = 0   (was 1)
HKCU\System\GameConfigStore\GameDVR_FSEBehaviorMode                = 0
HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR\AppCaptureEnabled        = 0   (was 1)
HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR\HistoricalCaptureEnabled = 0
HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR\AudioCaptureEnabled      = 0
HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR\CursorCaptureEnabled     = 0
HKCU\Software\Microsoft\GameBar\AutoGameModeEnabled                = 0
HKCU\Software\Microsoft\GameBar\UseNexusForGameBarEnabled          = 0
HKCU\Software\Microsoft\GameBar\ShowStartupPanel                   = 0
HKCU\Software\Microsoft\GameBar\GamepadNexusChordEnabled           = 0
HKCU\Software\Microsoft\GameBar\AllowAutoGameMode                  = 0
HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR\AllowGameDVR      = 0   (created)
```
Backup of the original values: `%LOCALAPPDATA%\AMD-Overlay-Watchdog\gamebar-backup.txt`

### E2. Driver class key
```
HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000
  AllowRSOverlay        = true     (unchanged - was already correct)
  RSXBrowserUnavailable = <DELETED so AMD re-evaluates it on start>
```

---

## F. Steam

```
C:\Program Files (x86)\Steam\userdata\1141202464\config\localconfig.vdf
  "EnableGameOverlay"  "0"
```
Changed via the Steam UI (Settings -> In Game). **Rollback:** re-tick the box in the UI.
(Change this via the UI only — Steam overwrites the file on exit.)

---

## G. Software removed

| Software | Action |
|---|---|
| **RivaTuner Statistics Server 7.3.7** | Uninstalled (its Global profile had `EnableOSD=1`, `EnableHooking=1`, `HookDXGI/D3D12/Vulkan=1`, `UseDetours=1`) |

Verified gone: HKLM/HKCU `Unwinder` keys, `C:\Program Files (x86)\RivaTuner Statistics Server`,
uninstall entry, processes, and no `RTSSHooks64.dll` injected anywhere.

---

## H. Log / disk housekeeping

```powershell
& "...\scripts\maintenance\cleanup-logs.ps1"
```
- Archived + reset `forensic.log` (316 KB) and `watchdog.log` to `%LOCALAPPDATA%\AMD-Overlay-Watchdog\archive\`
- Deleted 10 crash dumps from `%LOCALAPPDATA%\CrashDumps` — **139.5 MB reclaimed**
  *(WARNING: this included two game crash dumps — `eldenring.exe.23680.dmp` 70.9 MB and
  `b1-Win64-Shipping.exe.23960.dmp` 31 MB — which should have been preserved and analysed.
  They were inspected by name/size first; see `FINDINGS.md` section 5.)*
- Trimmed old WER `AMDADLXServ` reports (kept newest 3, removed 54)

---

## I. Files added to the system

```
C:\Users\Avisek\run-hidden.vbs                        (original hidden launcher; canonical copy is in this section)
powershell\amd-radeon-overlay-fix\scripts\run-hidden.vbs      *** ACTIVE ***
powershell\amd-radeon-overlay-fix\scripts\overlay-guard.ps1   *** ACTIVE ***
powershell\amd-radeon-overlay-fix\...                          (all tooling, see README section 6)
%LOCALAPPDATA%\AMD-Overlay-Watchdog\                                  logs + archive + rollback-gamebar.ps1
```

**Rollback for everything:** run `scripts\maintenance\rollback-gamebar.ps1`, then re-enable the
services in section B, then delete the two tasks in section A1/A2 — or simply use a System
Restore point.

---

## J. Test log (validation performed during this work)

| # | Test | Result |
|---|---|---|
| 1 | Guard run while healthy | OK - no-op |
| 2 | Break overlay -> script repair | OK - repaired in 37 s |
| 3 | Real task path, elevated | OK - exit 0, **but revealed elevated-AMD defect** |
| 4 | Non-elevated guard -> `StartCN` | FAILED - Limited cannot launch `StartCN` -> **led to the Limited relay design** |
| 5 | Elevated + relay | OK - repair works; integrity flagged |
| 6 | Who elevates `AMDRSServ`? | OK - parents are `cmd.exe`/`svchost.exe` -> **AMD's own services**, not us |
| 7 | Final design (Limited watchdog + relay) | OK - repaired in 43 s |
| 7b | *(regression found)* Limited watchdog **cannot kill High-integrity AMD processes** | FAILED -> RunLevel set back to **Highest**; silent-kill-failure logging added |
| 8 | Periodic trigger auto-repair | OK - scheduler fired, repaired in 40 s |
| 9 | Real reboot validation | OK - logon succeeded; overlay worked on desktop + in Khazan |
| 10 | Eliminate Game Bar | OK - verified by DCOM "Unable to start ...PresenceWriter" errors; death rate ~1/min -> ~1/10min |
| 11 | Console-flash elimination | OK - **0** console-capable process creations in 90 s |

---

## K. 2026-11-08 — RECURRENCE and fixes

The overlay broke again, and the guard had silently stopped working. Four separate causes.

### K1. GUARD BUG (critical — our fault)
`overlay-guard.ps1` had a diagnostic line calling `[OGProbe]::GetForegroundWindow()` — a method
that did not exist on the class. It threw, the outer `try/catch` swallowed it, and
**`Invoke-Repair` was never reached.**

Result: between 2026-10-25 and 2026-10-28 the guard logged **305 `OVERLAY DEAD` events and
performed ZERO repairs** (0 SUCCESS, 0 FAILED lines). The fault was never exercised during the
original install — only the healthy path was tested.

Fix:
- added `GetForegroundWindow` / `GetWindowThreadProcessId` to the `OGProbe` class
- replaced the broken diagnostic with a `Get-ForegroundApp` helper that cannot throw
- wrapped the diagnostic block in its own `try/catch`, so a logging failure can never block a
  repair again

Verified: deliberately broke the overlay -> guard repaired in **58 s**; a second death was then
repaired in **32 s**. `### foreground app:` now logs correctly.

### K2. REPO REORGANISATION broke the task path
The Nexus repo was restructured on 2026-11-03 to lowercase/kebab-case:

```
OLD  C:\Custom User\Nexus\Powershell Scripts\AMD Radeon Overlay Fix
NEW  C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix
```

The `AMD-Overlay-Guard` task was missing and the guard was not running.
Fix: `scripts/install/register-guard.ps1` is now **self-locating** (derives the path from
`$PSScriptRoot`), re-registered -> task `Ready`, guard running.

### K3. Windows update undid parts of the Game Bar elimination
Windows UBR moved 9445 -> 9711. It restored:
- `GameBarPresenceWriter.exe` + `.proxy.dll` in System32 **and** SysWOW64 (live copies beside the
  `.disabled` ones)
- `GameInputRedistService` back to Automatic / Running

Re-applied: all four binaries renamed to `.disabled` again; `GameInputRedistService` stopped and
set to Disabled. Active Game Bar binaries: **0**.

> Expect this after every Windows cumulative update. Re-run
> `scripts/maintenance/neuter-gamebar-all.ps1` (or just repeat these two steps).

### K4. AMD driver changed
```
was : 26.9.2    driver 32.0.32015.2008
now : 26.10.2   driver 32.0.32015.12012   (build 261023a1, 2026-10-23)
RSXBrowserUnavailable = true            (unchanged)
```
Overlay deaths first appear in the guard log on **2026-10-25** — i.e. after this driver landed.
The AMD-side defect therefore persists across driver versions; the **26.8.1 WHQL** clean install
recommended in README section 8 has still not been tried.

### K5. Deliberately NOT changed
`AchievementsAutoStart` / `Achievements.exe` — confirmed **not** an issue; left alone as requested.
(Note: it does still spawn `fastlist.exe` + `conhost` every 12 s, which can flash a console.)
