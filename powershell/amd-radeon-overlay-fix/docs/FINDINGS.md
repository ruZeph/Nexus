# FINDINGS — full investigation record

Date: **2026-10-10** · Machine: ASRock B850 Pro-A WiFi / Ryzen 5 7600X / RX 9060 XT
Windows 11 Pro 25H2 (26200.9445) · Adrenalin 26.9.2 (Optional), driver 32.0.32015.2008

---

## 0. Method

Everything below is measurement-based, not guesswork. The techniques that produced
decisive answers:

| Technique | What it proved |
|---|---|
| **Global hotkey enumeration** — brute-force `RegisterHotKey` over 8 modifier sets × ~90 keys | `Alt+R` was registered by **nobody** → the overlay hotkey handler was not running |
| **Programmatic integrity-level probe** — `OpenProcess` + `OpenProcessToken` + `TokenIntegrityLevel` | Which AMD processes run High vs Medium |
| **`Win32_ProcessStartTrace` event capture** (not polling) | Caught **1 ms** console windows that 200 ms polling missed |
| **Forensic churn monitor** — logs every process NEW/EXIT with parent, plus a snapshot at each state change | Identified what starts milliseconds before each overlay death |
| **Logon/startup task analysis** — `Get-ScheduledTaskInfo` + all logon-triggered tasks | The ~40-task logon stampede |
| **WER report parsing** — `Report.wer` `Sig[]` fields | Faulting module + exception code for every crash |

---

## 1. Fault A — the overlay never initialises at logon

### Evidence
- At first inspection (boot 19:56:48), **all AMD processes were running**, `AllowRSOverlay=true`,
  `DvrEnabled=1` — yet a full `RegisterHotKey` sweep found **0 AMD hotkeys registered**.
  A healthy Adrenalin registers `Alt+R`, `Alt+Z`, `Ctrl+Shift+O`, `Ctrl+Shift+I`,
  `Ctrl+Shift+S`, `Ctrl+Shift+E`, `Ctrl+Shift+G`, `Ctrl+Shift+C`.
- After a manual full stack restart (kill all AMD user-mode processes → relaunch), **8 hotkeys
  appeared**. Reproduced repeatedly (see `docs/CHANGELOG.md`, tests 1–8).
- `Get-ScheduledTaskInfo` showed `StartCN` and `StartDVR` — AMD's two logon launchers —
  both with `LastTaskResult = 1`. **Note:** this turned out to be a *red herring*; `cncmd.exe`
  returns 1 even on success. The reliable signal was the missing hotkeys.

### Root cause
At logon, ~40 logon-triggered tasks execute within the same second. AMD's overlay/hotkey
subsystem loses the race and silently fails to initialise. The processes still start, which
is why the UI appears to work while the overlay is dead.

### Why previous fixes failed
DDU / AMD Cleanup Utility / offline install all replace the *files*. The overlay then works
**until the next reboot**, when the same logon race recurs. The driver package
(`26.9.2 Optional`) was never changed in any attempt.

### Fix
Long-lived guard process (`scripts/overlay-guard.ps1`) that probes `Alt+R` every 60 s and
repairs on death. Verified across real reboots.

---

## 2. Fault B — the overlay dies when a game starts

### Evidence (all from the guard/monitor logs)

| Death | Game | GameBar refs | SteamOverlay refs | PresentMon | CapFrameX |
|---|---|---|---|---|---|
| #1 | Khazan | 4 | 1 | running | running |
| #2 | Cyberpunk | **0** | **0** | running | running |
| #3 | Khazan | 3 | 2 | running | running |
| #4 | AC Black Flag | 2 | 1 | running | running |
| #5 | Cyberpunk | 1 | 0 | **disabled** | **disabled** |
| #6 | Khazan | 2 | 2 | disabled | disabled |
| #7 | AC Black Flag | 4 | 2 | disabled | disabled |
| #8 | Cyberpunk | **0** | **0** | disabled | disabled |
| #9 | AC Black Flag | 3 | 0 | disabled | disabled |
| #10 | AC Black Flag | 2 | 0 | disabled | disabled |
| afterwards | BMW ×2, Elden Ring | **0** | **0** | disabled | disabled |

**No third-party factor is present at every death.** The only constant is *a game process
starting*. Death #2 and #8 (both Cyberpunk) had neither Game Bar nor the Steam Overlay.

### Corroborating AMD-side evidence
- `AMDADLXServ.exe` — **23 crashes in 24 h**, `c0000005` access violation in `OLEAUT32.dll`
  (dumped in `%LOCALAPPDATA%\CrashDumps`, signature
  `d3e930fb…_989727c7`, `AppName=ADLX Service`)
- `RSXBrowserUnavailable = true` in
  `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-…}\0000`
- `RSServCmd.exe toggle_in_content_rs_perf_from_rsx` **deadlocks** — this *is* the Alt+R action
  chain: `Alt+R` → RadeonSoftware (low-level keyboard hook) → `RSServCmd …_from_rsx` →
  requires the RSX browser → deadlock → no overlay + **system beep** + one permanently hung
  `RSServCmd.exe` per keypress
- `AdvancedMicroDevicesInc-RSXCM` was version **22.10.0.0 (Oct 2022)** against a 26.9.2 app
- `RadeonSoftware.exe` logged `winsrvext 100` "delaying system shutdown" ~5 s, 8×
- `HKCU\Software\AMD\CN\LastRecoveryCount = 1` (the app crashed and self-recovered)

### Important correction
`Alt+R` is **not** tracked via `RegisterHotKey` by AMD — it is handled by a **low-level
keyboard hook** inside `RadeonSoftware.exe`. This is why the `RegisterHotKey` probe reports
"FREE" while AMD still receives the key (evidenced by the hung `RSServCmd …_from_rsx`
processes parented to `RadeonSoftware.exe`, one per keypress). The "overlay alive" test is
still a valid proxy — AMD registers the hotkey when the overlay is healthy — but it is a
proxy, not the mechanism.

### Status
Mitigated by the guard (~1 min recovery). Root cause is AMD-side and needs the driver change
(`README.md` §8).

---

## 3. Fault C — blinking console windows every 12 seconds

### Symptom
A console window flashing open/closed every few seconds, interrupting the user.

### Evidence — event-based capture (`Win32_ProcessStartTrace`), 90 s
```
TOTAL process creations in 90s: 25
  conhost.exe                    10
  fastlist-0.3.0-x64.exe          8
  cmd.exe                         1
  ...
```
Focused capture, 45 s:
```
22:55:47.206  fastlist-0.3.0-x64.exe  parent=Achievements.exe
22:55:47.207  conhost.exe
22:55:59.265  fastlist-0.3.0-x64.exe  parent=Achievements.exe
22:55:59.266  conhost.exe
22:56:11.362  fastlist-0.3.0-x64.exe  parent=Achievements.exe
22:56:11.363  conhost.exe
22:56:23.474  fastlist-0.3.0-x64.exe  parent=Achievements.exe
22:56:23.475  conhost.exe
```
Exactly **12-second** period, always a `conhost.exe` immediately after.

### Root cause
`Achievements.exe` (`C:\Program Files\Achievements`, publisher *JokerVerse*, v1.3.0.0,
245 MB Electron app, 6 processes) uses the npm **`ps-list`** package, which ships
**`fastlist-0.3.0-x64.exe`** and **shells out to it to enumerate processes**. Every call
allocates a console → visible flash.

### Secondary flashers found
- `java.exe` (CyberPower PowerPanel Business) → `cmd.exe` every ~60 s → `conhost.exe`
- `RadeonSoftware.exe` → `powershell.exe /C "Get-AppxPackage | Select Name"` — **4 in 400 ms**,
  AMD Software's own component/store check (not suppressible; bursty not continuous)
- `clinfo` (spawned by RadeonSoftware) → `conhost.exe`

### OUR OWN contribution — important
The first watchdog implementation was a **scheduled task launching `powershell.exe` every
60 s**, which creates a `conhost.exe` even with `-WindowStyle Hidden` → one flash per minute.
Fixed by (a) launching through `wscript.exe` with `WshShell.Run(..., 0, False)` (SW_HIDE), and
(b) ultimately replacing it with a **single long-lived process** (`overlay-guard.ps1`) that
spawns nothing at all after startup.

### Fix
`AchievementsAutoStart` disabled + processes killed; `ppbwd` disabled; watchdog converted to a
long-lived process. Verified: **0 console-capable process creations in 90 s**.

---

## 4. Observer effect — a mistake worth recording

The forensic monitor probed `Alt+R` via `RegisterHotKey` **every 2 seconds**. Because
`RegisterHotKey` fails when another thread already owns the combination, a probe landing in
the microsecond window in which AMD tried to (re)register could **make AMD's registration
fail** — i.e. the instrument was capable of injecting the very deaths it was counting.

Symptoms of this: contradictory readings (the 60 s watchdog reported "healthy" at 22:42:16 and
22:43:16 while the 2 s monitor reported the overlay dead from 22:41:18 with no recovery), and
implausible 2-second die/revive cycles.

**Fix:** exactly **one** prober. The guard probes once per 60 s and also logs churn, so the
separate 2 s monitor is no longer needed.

**Caveat:** this cannot be the whole story — the overlay was already dead at first inspection
*before* any monitoring existed, and there was a 9-minute healthy stretch with the 2 s probe
running. Treat it as a contributing artefact, not the root cause.

---

## 5. Things that were NOT the problem (ruled out with evidence)

- **Game detection** — `gmdb.blb` contains the games with correct `exe_path`, `hidden=FALSE`;
  `HKIDs` shows the game hooked as DX12 with FSR4 active. The user's original hypothesis
  ("it's not detecting it") was wrong.
- **Hotkey conflict** — full enumeration; all AMD default hotkeys were free.
- **HVCI / Memory Integrity** — disabled. **Exploit Protection** — all system defaults.
- **`AllowRSOverlay`** — already `true` (so the widely-posted registry fix was a no-op here).
- **`StartCN`/`StartDVR` exit code 1** — red herring; `cncmd.exe` returns 1 even on success.
- **Fast Startup** — already disabled (`HiberbootEnabled=0`).
- **CapFrameX / Intel PresentMon** — disabled across three consecutive deaths (#5–#7) and the
  deaths continued → innocent. Both **re-enabled** afterwards.
- **Game crashes were not AMD's fault**:
  - `eldenring.exe` crashes: `Exception Code 80000003` = **`STATUS_BREAKPOINT`**, faulting
    module = `eldenring.exe` itself (v2.7.1.0, modded, launched via **`me3`** / Mod Engine 3).
    No AMD module in the chain.
  - `b1-Win64-Shipping.exe` (Black Myth: Wukong) — folder contains **UE4SS Injection Proxy**
    (`dwmapi.dll`, product string `"UE4SS Injection Proxy"`) plus `dsound.dll`, `wkmap.dll`,
    `wukong_minimap.dll` (16 MB) and `MonoPosixHelper.dll`; its own `wukong_crash.log` shows
    a third-party crash handler installed 18×.
  - `ACBlackFlag.exe` — folder contains **UplayR2Unlocker** (`Koaloader.json` →
    `UplayR2Unlocker.dll` via a hijacked `version.dll`); `UplayR2Unlocker.log` shows
    "Unlocker prepared 31 products".
  These are three separate **DLL-injection collisions** in the games' own folders, not AMD
  faults. AMD's official Elden Ring exe version is not "2.7.1.0".

---

## 6. Impact summary

| Metric | Before | After |
|---|---|---|
| AMD hotkeys registered at logon | **0** | 8 (and repaired automatically if lost) |
| Console flashes per 90 s | ~18 | **0** |
| Overlay deaths while gaming | ~1 / minute | ~1 / 10 min, auto-repaired in ~1 min |
| Longest healthy stretch observed | ~30 s | 9 min+ |


---

## 7. Session 2 (2026-11-08) — Permanent Root-Cause Eliminations

### 7.1 Elimination of 30-Second DCOM 10010 Timeout
- **Symptom:** Overlay dropped or froze for 30s during game launch transitions (e.g. AC Black Flag).
- **Mechanism:** `twinui.pcshell.dll` calls `RoActivateInstance(Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter)` on foreground 3D game focus. Because the exe was blocked via IFEO, DCOM stalled for 30 seconds waiting for class registration, logging Event 10010.
- **Remediation:** Acquired ownership and permanently de-registered `Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter` and `Windows.Gaming.GameBar.Internal.PresenceWriterServer` from `HKLM\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId` and `WOW6432Node`.
- **Verification:** `RoActivateInstance` returns `0x80040154 (REGDB_E_CLASSNOTREG)` in <0.001 ms. 0 DCOM events logged. Survives `sfc /scannow` and DISM repairs with 0 keys restored.

### 7.2 The False-Positive Watchdog Trap (`overlay-guard.ps1`)
- **Symptom:** Overlay was killed ~15-55 seconds after launching exclusive fullscreen 3D games (*AC Black Flag*, *Onimusha*).
- **Forensic Discovery:** `guard.log` proved that `overlay-guard.ps1` called `Stop-Process -Force` on healthy AMD processes. In exclusive fullscreen mode, Windows User32 suspends desktop hotkeys, allowing the watchdog's `RegisterHotKey(Alt+R)` probe to succeed. The watchdog erroneously deduced the overlay was dead and terminated healthy AMD processes mid-game.
- **Remediation:** Terminated `overlay-guard.ps1` and disabled `AMD-Overlay-Guard`. Restored standard logon execution via native AMD scheduled tasks `\StartCN` and `\StartDVR`.

### 7.3 FanControl ADLX Startup Race Elimination
- **Symptom:** 147 `AMDADLXServ.exe` crashes in `OLEAUT32.dll` at boot.
- **Remediation:** Set `FanControl.Service` startup type to `Automatic (Delayed Start)` (`sc.exe config FanControl.Service start= delayed-auto`). Allows the AMD display driver and ADLX COM server to initialize fully before FanControl begins sensor polling. Retains full custom fan curve (`"RX 9060 XT"`) mapped to ADLX Hotspot sensor.

### 7.4 In-Game Borderless Recording Fix
- **Symptom:** In-game hotkeys and recording failed when games ran in borderless or windowed mode.
- **Root Cause:** By default, AMD DVR had `BorderlessEnabled = 0` and `DesktopRecordingEnabled = 0` in `HKCU\SOFTWARE\AMD\DVR`, causing `AMDRSServ.exe` to reject capture requests whenever a game was not in exclusive fullscreen mode.
- **Remediation:** Enabled borderless and desktop recording via registry:
  - `HKCU\SOFTWARE\AMD\DVR\BorderlessEnabled = 1`
  - `HKCU\SOFTWARE\AMD\DVR\DesktopRecordingEnabled = 1`
  - Aligned in `HKLM\SOFTWARE\AMD\DVR`.
- **Verification:** User tested both *Crimson Desert* and *Lords of the Fallen 2*; recording captured complete 60 FPS video files directly to `C:\Users\Avisek\Videos\Radeon ReLive\` (`Crimson Desert_2026.11.08-22.11.mp4` [502 MB] and `Lords of the Fallen_2026.11.08-22.09.mp4` [20 MB]).

### 7.5 Resolution of Overlay Sidebar Freeze & Missing Mouse Cursor
- **Symptom:** When triggering the overlay (`Alt+R`) over games, the sidebar was frozen, pressing Escape or Alt+R did not dismiss it, and the mouse cursor disappeared.
- **Forensic Discovery & Call Stack Analysis:**
  - `AMDRSServ.exe` (PID 11856/2904) owns `AMD:DVR-CapturingWindow` (class `DVREventWindowClass`).
  - Probing the window with `IsHungAppWindow` returned **`True`**; `SendMessageTimeoutW` returned 0 (timeout).
  - Inspection of the captured minidump (`amdrsserv_hung.dmp`) revealed Thread 0 (the UI message pump thread) call stack:
    `ntdll.dll!ZwWaitForSingleObject` <- `KERNELBASE.dll!WaitForSingleObject` <- `amdocl64.dll+0x773fa` <- `amdocl64.dll` <- `OpenCL.dll` <- `AMDRSServ.exe+0x70805` <- `AMDRSServ.exe+0x70215`.
  - **Mechanism:** On RDNA 4 (gfx1200 / RX 9060 XT), `AMDRSServ.exe` fell back to OpenCL (`amdocl64.dll`) texture interop (`CaptureCopy` / `ColorSpaceConversion.cpp`) for D3D11 frame synchronization on the main thread. The interop wait deadlocked indefinitely.
  - Because Thread 0 was hung:
    1. User32 suspended hotkeys (`Alt+R` / `Ctrl+Shift+O` dropped to `FREE`).
    2. `InGameUiCursorOverlay` never initialized (`ADL2_Desktop_HardwareCursor_Toggle` and `Enable HW Cursor: set bitmap` were never called), leaving the cursor hidden by the game's `ShowCursor(FALSE)`.
    3. Input routing to `RadeonSoftware.exe` (Qt6 sidebar) was frozen.
    4. Registry check in `HKCU\SOFTWARE\AMD\CN` revealed `EscapeInputState = 'false'` (explicitly disallowing Esc dismissal) and `SidebarWidth = 1280` (distorting sidebar hit test across two-thirds of the display).
- **Remediation:**
  1. Set `HKCU\SOFTWARE\AMD\DVR\EFCEnabledOverride = 1` and `HKLM\SOFTWARE\AMD\DVR\EFCEnabledOverride = 1` (forces hardware Enhanced Frame Conversion on the VCN encoder, completely bypassing the buggy OpenCL texture interop deadlock).
  2. Set `HKCU\SOFTWARE\AMD\CN\EscapeInputState = 'true'` (allows Escape key and outside click to dismiss the overlay).
  3. Set `HKCU\SOFTWARE\AMD\CN\SidebarWidth = 375` (resets corrupted 1280px width to native 375px sidebar dimensions).
  4. Set `HKCU\SOFTWARE\AMD\CN\TriggerShowCNViaHK = 1`, `AllowRSOverlay = 1`, `ShowRSOverlay = 1`, and `RecordPerfUI = 1`.
  5. Restarted `AMDRSServ.exe` cleanly via `schtasks /run /tn StartDVR`.
- **Verification:**
  - `IsHungAppWindow(hwnd_dvr)` returns `False`.
  - Hotkeys `Alt+R: HELD` and `Ctrl+Shift+O: HELD` remain rock-solid.
  - Sidebar width normalized to 375px (`0, 0, 728, 1080` scaled).
  - FanControl ADLX curve and sensors remain 100% active.
