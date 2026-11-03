# SESSION NOTES — narrative, dead ends, lessons

2026-10-10. One long debugging session on "the AMD overlay doesn't open in game".

---

## What the user believed at the start

> "The AMD overlay is not opening in game — I think it may not be detecting it. I've tried all
> the fixes (DDU, cleanup utility, offline install) and it's still the same."

Two of those three beliefs turned out to be wrong:

1. **"It's not detecting the game"** — false. `gmdb.blb` contains every title with the correct
   `exe_path`, and `HKIDs` shows the game hooked as DirectX 12 with FSR4 active. Detection was
   never broken.
2. **"I've tried all the fixes"** — true but irrelevant: every attempt used the *same*
   `26.9.2 Optional` driver package, so the driver branch never changed. DDU fixes files; it
   does not fix a logon-order race or an AMD-side hotkey/hook defect.

---

## Dead ends (recorded so they aren't re-explored)

| Hypothesis | Why it looked right | Why it was wrong |
|---|---|---|
| **Hotkey conflict** — another app stole `Alt+R` | Classic cause; the user presses Alt+R and "nothing happens" | Full enumeration showed `Alt+R` was registered by **nobody** |
| **`StartCN`/`StartDVR` exit code 1 = failure** | Both AMD logon tasks reported `LastTaskResult=1` | `cncmd.exe` returns 1 **even on success** — the relay task proved it |
| **`RSXBrowserUnavailable = true` is the smoking gun** | Suspicious driver-key flag next to `AllowRSOverlay` | Not publicly documented; unverifiable. It was *consistent* with a broken RSX render component but never proven causal on its own |
| **Game Bar was the culprit** | `GameBarPresenceWriter` started 2–2.5 s before most deaths | Death #2 (Cyberpunk) had **zero** Game Bar references |
| **Steam Overlay was the culprit** | 7/7 deaths within 2 ms–3 s of `gameoverlayui64` — an extremely tight correlation | Deaths continued after disabling it (BMW ×2, Elden Ring) with **zero** Steam Overlay refs |
| **PresentMon / CapFrameX were the culprit** | Present in every death block; both installed 2026-10-03, matching the onset | Disabled for three consecutive deaths (#5–#7) and the deaths continued. **Re-enabled — innocent** |
| **The games crashed because of AMD's overlay** | Game crashes followed overlay deaths by ~30 s | `eldenring.exe` fault is `STATUS_BREAKPOINT` in `eldenring.exe` itself (modded v2.7.1.0 via `me3`); BMW/AC folders contain their own DLL-hijack injectors (UE4SS; UplayR2Unlocker) |
| **Elevated AMD processes are bad** | `AMDRSServ`/`amdow` came back at High integrity when the watchdog ran elevated | Test 6 proved their parents are `cmd.exe` and `svchost.exe` — **AMD's own services spawn them that way**, independent of us |

---

## Mistakes made during the session (and the fixes)

1. **Changed the watchdog to `RunLevel=Limited`** to keep AMD non-elevated — which meant it
   could no longer kill AMD's High-integrity processes. `Stop-Process` failed **silently**, the
   stack was only half-killed, and repairs stopped working while still logging success-ish
   progress. → Reverted to **Highest**, and added explicit `FAILED to kill … higher integrity`
   logging so a silent kill failure can never hide again.

2. **A scheduled task launching `powershell.exe` every 60 s flashes a console window.**
   `-WindowStyle Hidden` does not prevent it: `conhost.exe` is created first. This added a
   once-a-minute blink on top of the user's existing problem. → Moved to `wscript.exe` +
   `WshShell.Run(..., 0, False)` (SW_HIDE), then to a **single long-lived process** that
   spawns nothing at all.

3. **The 2-second forensic probe could cause the deaths it was measuring.** `RegisterHotKey`
   fails when another thread already owns the combination, so a probe landing in the
   microsecond window in which AMD tried to register could make **AMD's registration fail**.
   → Reduced to exactly **one prober at 60 s**; the monitor now logs churn only.

4. **Deleting crash dumps during "log cleanup"** — the dump list included two *game* crash
   dumps (`eldenring.exe` 70.9 MB, `b1-Win64-Shipping.exe` 31 MB) that were the most
   interesting artefacts in the pile. They should have been flagged before removal.
   → Rule now recorded in the RUNBOOK: always inspect `%LOCALAPPDATA%\CrashDumps` before any
   cleanup.

5. **Asserted a culprit three times before the evidence supported it** (Game Bar → Steam
   Overlay → PresentMon). Each time a subsequent measurement disproved it. The honest
   sequence is: Game Bar and the Steam Overlay are real *contributors*; neither is
   *sufficient*; the base cause is AMD-side.

---

## The two techniques that actually produced answers

**1. Enumerate global hotkeys.** Brute-force `RegisterHotKey` across 8 modifier sets × ~90 keys.
This turned "the overlay doesn't open" into a hard fact: *zero AMD hotkeys registered* — the
hotkey handler was not running at all.

**2. Event-based process capture.** `Win32_ProcessStartTrace` fires for every process *creation*,
including ones that live 1 ms. Polling `Get-Process` every 200 ms had already **missed** the
console flashes entirely. The event capture immediately named the culprit, its parent, and its
exact 12-second cadence.

And the meta-lesson: **when a measurement disagrees between two instruments, suspect the
instrument.** The contradiction between the 60 s watchdog ("healthy") and the 2 s monitor
("dead since 22:41:18") is what exposed the observer effect.

---

## Timeline (condensed)

| Time | Event |
|---|---|
| ~20:25 | First inspection. Game detected fine; **0 AMD hotkeys registered** → Fault A found |
| 20:32 | Manual stack restart → 8 hotkeys appear. Fault A confirmed |
| 20:39–20:49 | Built + tested the watchdog (tests 1–3). Found the elevated-AMD issue |
| ~20:53 | User rebooted. **Logon fix worked** — overlay worked on desktop and in Khazan |
| 21:00–21:37 | User reported overlay dying on game switch. Built the forensic monitor |
| 21:22 | First captured death. Game Bar auto-started 1.6 s before. (Later disproved as sole cause) |
| 21:46 | User disabled the Steam Overlay |
| 21:52 | Watchdog bug found (Limited vs High integrity) and fixed |
| 22:18 | Reboot. Game Bar stack neutered |
| 22:32–22:35 | Deaths continued with Game Bar **and** Steam Overlay absent → AMD-side confirmed |
| 22:40–22:44 | `eldenring.exe` crash analysed → `STATUS_BREAKPOINT`, game/mod-side |
| 22:45 | Monitor switched to churn-only (observer effect removed) |
| 22:47–22:56 | **Console blinking traced to `Achievements.exe` + `ps-list`/`fastlist`, every 12 s** |
| 23:00 | Guard (long-lived) installed; CyberPower watchdog disabled; **0 console flashes in 90 s** |

---

## Open item

The AMD-side residue — `AMDADLXServ.exe` crashing ~23×/day, `RSXBrowserUnavailable`,
`RSServCmd …_from_rsx` deadlock, `RadeonSoftware` self-restarting — is **mitigated** (auto-repair
in ~1 min) but **not cured**. The outstanding action is a clean install of
**Adrenalin 26.8.1 WHQL** (a genuinely different driver branch). See `README.md` §8 and
`docs/RUNBOOK.md` §8.
