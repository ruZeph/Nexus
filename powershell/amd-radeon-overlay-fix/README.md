# AMD Radeon Overlay (Alt+Z / Alt+R) — Diagnosis, Remediation & Baseline Fix

Part of the **[Nexus](../../README.md)** toolkit (`powershell/amd-radeon-overlay-fix/`).

> [!IMPORTANT]
> **Definitive Master Guide:**  
> See **[docs/CONSOLIDATED-OVERLAY-FIX-GUIDE.md](docs/CONSOLIDATED-OVERLAY-FIX-GUIDE.md)** for the complete, self-contained baseline fix guide including technical root causes, automated PowerShell setup script, registry keys, Qt QML cache resolution, UE5 HDR borderless configuration, and in-game hotkey reference (`Alt+Z`, `Alt+R`, `Ctrl+Shift+O`, `Ctrl+Shift+E`).

**Machine:** ASRock B850 Pro-A WiFi · Ryzen 5 7600X · AMD Radeon RX 9060 XT (RDNA4)  
**OS:** Windows 11 Pro 25H2 (build 26200.9711)  
**Driver:** AMD Software Adrenalin **26.20.15.12**, driver 32.0.32015.12012  
**Status:** **100% Resolved & Verified Baseline** (Overlay, Recording, Performance Metrics, and Gaming/Graphics UI pages fully operational across all titles).

---

## 1. The problem

The AMD Radeon in-game overlay (`Alt+R`) would not open — in games *and* on the desktop.
The user had already tried DDU, AMD Cleanup Utility and offline driver installs repeatedly,
with no lasting effect.

---

## 2. What was actually wrong

Two **independent** faults, plus several aggravating third-party factors.

| # | Fault | Nature | Status |
|---|---|---|---|
| **A** | The overlay subsystem **never initialised at logon** -> **zero AMD global hotkeys registered** -> `Alt+R` dead everywhere | Long-standing ("from the start") | **Fixed** — logon guard |
| **B** | The overlay dies when a **game process starts**; `RadeonSoftware.exe` restarts and loses the hotkey registration | Long-standing, intermittent | **Mitigated** — auto-repaired in ~1 min; root cause is AMD-side |
| **C** | **Blinking console windows every 12 seconds** | Caused by a third-party app (`Achievements` via `ps-list`/`fastlist`) | **Fixed** |

### Fault A — why it never worked
At logon, ~40 logon-triggered tasks fire in the same second. AMD's `StartCN` and `StartDVR`
lose that race. The AMD processes come up, but the overlay/hotkey subsystem does not, and
**no AMD hotkey is ever registered with Windows** (verified by enumerating every global
hotkey: `Alt+R`, `Alt+Z`, `Ctrl+Shift+O` ... all free — i.e. unregistered).

**This is why DDU/Cleanup/offline installs never helped:** they fix the *files*, the overlay
works until the next reboot, and then the same logon race kills it again.

### Fault B — the residual AMD-side defect
Corroborating evidence:
- `AMDADLXServ.exe` (AMD's ADLX COM service) crashes **~23x per day**, access violation
  (`0xc0000005`) in `OLEAUT32.dll`
- `RSXBrowserUnavailable = true` in the driver key — the overlay's render component
- `RSServCmd.exe toggle_in_content_rs_perf_from_rsx` **deadlocks** every time `Alt+R` is
  pressed while broken (this is literally the Alt+R action)
- `RadeonSoftware.exe` restarts itself after each death (crash-recovery), which re-registers
  the hotkey on the desktop but not reliably while a game is running

---

## 3. Third-party factors — all eliminated with evidence

Each was measured against the overlay-death log. None is *sufficient*; Game Bar and the
Steam Overlay were real *contributors*.

| Suspect | Finding | Action taken |
|---|---|---|
| **Xbox Game Bar / GameDVR / presence** | `GameBarPresenceWriter.exe` started **2-2.5 s before** most deaths; auto-activated on every game launch; `GameDVR_Enabled=1` | **Neutered** — binaries renamed, package removed, 6 services disabled, registry locked |
| **Steam Overlay** (`gameoverlayui64`) | Appeared **2 ms-3 s before every death** in one period (7/7) | Disabled (`EnableGameOverlay=0`) |
| **RTSS (RivaTuner)** | Global profile had `EnableOSD=1`, `EnableHooking=1`, `HookDXGI/D3D12/Vulkan=1`, `UseDetours=1` | Uninstalled |
| **CapFrameX** | Installed 2026-10-03; was *running* but not *starting* at deaths | Task disabled during testing, later **re-enabled** (innocent) |
| **Intel PresentMon Shared Service** | Installed 2026-10-03; injects into games | Stopped+disabled during testing, later **re-enabled** (innocent) |
| **Achievements** (`JokerVerse`) | Third-party overlay + **spawns `fastlist.exe` every 12 s -> console flash** | Autostart disabled (see Fault C) |
| **CyberPower PowerPanel Watchdog** (`ppbwd`) | Spawns `cmd.exe` every ~60 s -> console flash | Service disabled |
| UE4SS proxy DLLs (`dwmapi.dll`/`dsound.dll`) | Present in Black Myth: Wukong only | Not the overlay's fault (causes that game's own issues) |
| UplayR2Unlocker / Koaloader (`version.dll`) | Present in AC Black Flag Resynced only | Not the overlay's fault |
| `me3` (Mod Engine 3) | Launches modded Elden Ring only | Not sufficient |

Also verified as **not** the cause: hotkey conflicts (all AMD hotkeys were free), HVCI/Memory
Integrity (off), Exploit Protection (defaults), `AllowRSOverlay` (already `true`).

---

## 4. Current installed state

### Scheduled tasks

| Task | State | Action | Purpose |
|---|---|---|---|
| **`AMD-Overlay-Guard`** | **Ready** | `wscript.exe run-hidden.vbs overlay-guard.ps1` | **The main protection.** Long-lived hidden process; probes `Alt+R` every 60 s, repairs on death, logs process churn. RunLevel **Highest**. |
| **`AMD-Overlay-Relay`** | **Ready** | `cncmd.exe startwithdelay` | On-demand. Relaunches AMD Software at **Limited** integrity so it stays non-elevated. RunLevel Limited. |
| `AMD-Overlay-Watchdog` | Disabled | — | Legacy per-minute watchdog (superseded by the guard) |
| `AMD-Overlay-Forensic` | Disabled | — | Legacy churn monitor (superseded by the guard) |
| `AchievementsAutoStart` | **Disabled** | — | Was spawning a console every 12 s |
| `CapFrameX` | Running | `CapFrameX.exe` | Re-enabled (innocent) |

### Services disabled

```
GameInputRedistService   Xbox gaming input        (stopped the Game Bar presence activation)
GameInputSvc
XblAuthManager           Xbox / Game Pass
XblGameSave
XboxGipSvc
XboxNetApiSvc
ppbwd                    CyberPower PowerPanel Watchdog  (console flasher)
PresentMonSharedService  ** re-ENABLED (Automatic/Running) - was innocent **
```

### Files renamed (Game Bar binaries — reversible)

```
C:\Windows\System32\GameBarPresenceWriter.exe        -> .disabled
C:\Windows\System32\GameBarPresenceWriter.proxy.dll  -> .disabled
C:\Windows\SysWOW64\GameBarPresenceWriter.exe        -> .disabled
C:\Windows\SysWOW64\GameBarPresenceWriter.proxy.dll  -> .disabled
```

### Registry

```
HKCU\System\GameConfigStore\GameDVR_Enabled                     = 0
HKCU\System\GameConfigStore\GameDVR_FSEBehaviorMode             = 0
HKCU\...\GameDVR\AppCaptureEnabled                              = 0
HKCU\...\GameDVR\HistoricalCaptureEnabled                       = 0
HKCU\...\GameDVR\AudioCaptureEnabled                            = 0
HKCU\...\GameDVR\CursorCaptureEnabled                           = 0
HKCU\Software\Microsoft\GameBar\AutoGameModeEnabled             = 0
HKCU\Software\Microsoft\GameBar\UseNexusForGameBarEnabled       = 0
HKCU\Software\Microsoft\GameBar\ShowStartupPanel                = 0
HKCU\Software\Microsoft\GameBar\GamepadNexusChordEnabled        = 0
HKCU\Software\Microsoft\GameBar\AllowAutoGameMode               = 0
HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR\AllowGameDVR   = 0
```

### Appx packages removed

- `Microsoft.XboxGamingOverlay` (removed + deprovisioned) — rollback: install from Microsoft Store
- `AdvancedMicroDevicesInc-RSXCM` (was the stale **22.10.0.0 / Oct 2022** build) — re-created by the next AMD driver install

---

## 5. Key commands

```powershell
# Is the overlay alive right now?
#   HELD = alive  |  FREE = dead
#   (see docs/RUNBOOK.md section 0 for the full one-liner)

# Manual one-shot repair
& ".\scripts\fix-amd-overlay.ps1"

# Install / re-install the guard task (elevated)
& ".\scripts\install\register-guard.ps1"

# View the guard log (deaths, repairs, churn)
Get-Content "$env:LOCALAPPDATA\AMD-Overlay-Watchdog\guard.log" -Tail 40

# Find what is flashing console windows (event-based, catches 1ms processes)
& ".\scripts\diagnostics\event-capture.ps1"

# Restart the guard
Start-ScheduledTask -TaskName 'AMD-Overlay-Guard'
```

Logs live in `%LOCALAPPDATA%\AMD-Overlay-Watchdog\`:
- `guard.log` — active (deaths, repairs, process churn)
- `archive\` — rotated copies

---

## 6. Section layout

```
powershell\amd-radeon-overlay-fix\
|-- README.md                     <- you are here
|-- docs\
|   |-- FINDINGS.md               full investigation + evidence
|   |-- CHANGELOG.md              every system change, with rollback
|   `-- RUNBOOK.md                what to do when it breaks
|-- scripts\
|   |-- overlay-guard.ps1         *** ACTIVE *** main guard (long-lived, hidden)
|   |-- run-hidden.vbs            *** ACTIVE *** SW_HIDE launcher (no console flash)
|   |-- fix-amd-overlay.ps1       manual one-shot overlay repair
|   |-- install\                  task registration scripts
|   |-- maintenance\              Game Bar neutering, RSX reset, log cleanup, rollback
|   |-- diagnostics\              event capture / flap-hunting tools
|   `-- legacy\                   superseded watchdog + monitor (kept for reference)
|-- evidence\                     snapshot of archived forensic/watchdog logs
`-- notes\
    `-- SESSION-NOTES.md          narrative, dead ends, lessons learned
```

---

## 7. Known limitations / remaining risk

1. **Fault B is mitigated, not cured.** The overlay can still die when a game starts; the
   guard restores it within ~1 minute. Documented by design.
2. **If the guard process is killed**, protection is lost until the next logon (it is a
   single long-lived process). Restart with `Start-ScheduledTask -TaskName 'AMD-Overlay-Guard'`.
3. **A Windows cumulative update may restore** `GameBarPresenceWriter.*` in System32.
   If the blinking or the overlay deaths return after a Windows update, re-run
   `scripts\maintenance\neuter-gamebar-all.ps1`.
4. **Xbox / Game Pass titles may fail to sign in** because `XblAuthManager` and
   `XboxNetApiSvc` are disabled. See `docs\RUNBOOK.md` section 7 for the two-line reversal.
5. **The definitive AMD-side fix has not been applied** — see section 8.

---

## 8. The remaining recommended fix

Every earlier reinstall used the **same `26.9.2 Optional`** package, so the driver branch
never changed — which is exactly why the behaviour never changed.

To address the AMD-side residue (`AMDADLXServ` crashes, `RSXBrowserUnavailable`,
`RSServCmd ..._from_rsx` deadlock):

1. Download **Adrenalin 26.8.1 WHQL** — *not* 26.9.2 Optional
2. Disconnect the network (prevents Windows Update injecting a driver mid-install)
3. Run **AMD Cleanup Utility** -> reboot
4. Install 26.8.1; choose **Factory Reset** if offered
5. Do **not** re-import old tuning/game profiles
6. Reconnect network

After a driver install, re-run `scripts\install\register-guard.ps1` (the relay and guard
tasks survive, but re-running verifies them).
