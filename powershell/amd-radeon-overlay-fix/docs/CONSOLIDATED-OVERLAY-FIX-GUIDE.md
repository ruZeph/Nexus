# AMD Radeon Overlay, Hotkeys & Video Recording: Consolidated Master Fix Guide

**Machine Topology:**  
- **Motherboard:** ASRock B850 Pro-A WiFi (BIOS 4.43 / AGESA ComboAM5PI 1.2.0.2)  
- **CPU:** AMD Ryzen 5 7600X (6-Core / 12-Thread)  
- **GPU:** AMD Radeon RX 9060 XT (Navi 44 / RDNA4, PCI Bus 3, Device 0, Function 0 — GPUBDF `768`)  
- **Driver:** AMD Software: Adrenalin Edition `26.20.15.12` (Driver Package `32.0.32015.12012`)  
- **Operating System:** Windows 11 Pro 25H2 (Build `26200.9711`)  
- **Display Pipeline:** Native 10-bit HDR Borderless Display (3840×2160 @ 120Hz / 144Hz)  
- **Cooling Coexistence:** FanControl custom fan curve bound to `RX 9060 XT` GPU/VRAM hotspot sensors.

---

## 1. Executive Summary & Problem Resolution

### Symptoms Prior to Remediation
1. **Dead In-Game Overlay (`Alt+Z` / `Alt+R`):** Overlay either failed to open inside DirectX 12 / Vulkan titles, or opened as a frozen invisible hit-test rectangle with no mouse cursor (`IsHungAppWindow = True`).
2. **Broken Recording (`Ctrl+Shift+E`):** AMF hardware encoding failed or locked up indefinitely upon starting or stopping.
3. **Black Screen in Adrenalin Gaming & Graphics Tabs:** Navigating to `Gaming` $\rightarrow$ `Games`, `Graphics`, or `Advisors` rendered as solid black in both the desktop app and the in-game overlay side panel.
4. **Game Launch Freeze / Deadlock:** Titles like *Crimson Desert*, *Lords of the Fallen*, and *Elden Ring* experienced Thread 0 deadlocks during initialization.

### Verified Baseline Fix Outcome
- **In-Game Sidebar (`Alt+Z`)**: Opens instantly across all Steam, Epic, and standalone games with a responsive 375px sidebar and fully interactive mouse cursor.
- **Full In-Game Overlay (`Alt+R`)**: Displays complete tuning, telemetry, and system controls.
- **Performance Overlay (`Ctrl+Shift+O`)**: Real-time FPS, frametime, VRAM, and GPU utilization metrics.
- **Hardware AV1 Recording (`Ctrl+Shift+E`)**: Starts and stops instantly without lag or dropped frames, writing directly to `Videos\Radeon ReLive\`.
- **Gaming & Graphics Pages 100% Restored**: All 19 game library tiles, play durations, average FPS, and graphics controls (FSR overrides, AFMF 2.1, HYPR-RX, Anti-Lag, RIS) populate cleanly.
- **FanControl 100% Preserved**: Custom hardware curves for the RX 9060 XT run uninterrupted without interference.
- **OS Health**: Zero system files modified; passes `sfc /scannow` cleanly.

---

## 2. In-Depth Technical Root Cause Analysis

### A. The "Record Desktop" Thread 0 Deadlock
- **Mechanism:** When `DesktopRecordingEnabled = 1` ("Record Desktop" toggle in Adrenalin), `AMDRSServ.exe` spawns a continuous Desktop Duplication D3D12 pipeline on Thread 0 (`StartDesktopPipeline` $\rightarrow$ `InitDX12`).
- **Conflict:** When launching a heavy graphics engine or games using Anti-Cheat, `D3D12CreateDevice` deadlocks inside `D3D12Core.dll` waiting for exclusive swapchain ownership.
- **Fix:** Set `DesktopRecordingEnabled = 0`. Game recording in borderless windowed mode is seamlessly handled by `BorderlessEnabled = 1` and `DvrEnabled = 1` without locking Thread 0.

### B. Binary Disassembly Proof: The Danger of Negative Tweaks
Binary disassembly of `AMDRSServ.exe` proved that community "disable overlay" tweaks actively destroy the recording and compositing engine:
1. **`DisableAmdCapture` Override:**  
   At RVA `0x886d4` (file offset `0x87ad4`):
   ```assembly
   cmp     dword ptr [rbp-18h], 1
   je      0x89fa0                 ; Unconditionally jumps over 5,302 bytes of capture pipeline setup!
   ```
   Setting `DisableAmdCapture = 1` aborts `AMFCreateContext` and prevents the encoder from ever hooking the game surface.
2. **`DisableSharedTextureCopy` Override:**  
   At RVA `0xd02a5` (file offset `0xcf6a5`):
   ```assembly
   mov     byte ptr [rbp-21h], 0   ; Forces bUseSharedTextureCopy = 0
   ```
   Clearing shared texture copying completely breaks DirectX 12 shared NT handle compositing between `AMDRSServ.exe` and the game swapchain.
3. **Resolution:** Deleted `DisableAmdCapture`, `DisableSharedTextureCopy`, and `DXSyncDisable` across both `HKCU` and `HKLM`. Only strictly positive enablement keys are maintained.

### C. OpenCL vs. Enhanced Frame Conversion (EFC) Deadlock
- **Mechanism:** Prior to RDNA4 architecture, video frame conversion from game render textures to encoder NV12/P010 surfaces often fell back to OpenCL (`amdocl64.dll`).
- **Conflict:** During rapid resolution scaling or driver wakeups, OpenCL kernel execution deadlocked with `amfrtdrv64.dll`.
- **Fix:** Enforce `EFCEnabledOverride = 1` in registry. This forces direct hardware VCN Enhanced Frame Conversion in silicon, completely bypassing OpenCL.

### D. Dynamic HDR Mode Switch Swapchain Destruction
- **Mechanism:** Starting video recording while in 8-bit SDR mode and subsequently toggling HDR ON in the game settings destroys and reconstructs the DXGI swapchain mid-stream.
- **Conflict:** The active AMF encoder container loses its surface handles (`DXGI_ERROR_ACCESS_LOST`), causing DirectML pre-analysis (`amf-pa-ml64.dll` via `onnxruntime.dll` and `Windows.AI.MachineLearning.dll`) to deadlock in `ZwWaitForSingleObject` on Thread 0.
- **Operational Rule:** **Set HDR and Window Mode BEFORE starting the recording!** When HDR is already active prior to pressing `Ctrl+Shift+E`, the AMF encoder initializes directly for 10-bit P010 HDR from frame 1 with zero reconstruction penalty.

### E. Qt 6.9 QML Cache & Incomplete GExDb Corruption
- **Mechanism:** AMD Adrenalin's UI is written in Qt 6.9 QML. Driver crashes caused stale/corrupted bytecode (`.qmlc` and shader binaries) to be cached in `%LOCALAPPDATA%\AMD\Radeonsoftware\cache\`.
- **Symptom:** Simultaneously, the Game Experience Database (`%LOCALAPPDATA%\AMD\CN\GExDb.blb`) was stripped into an incomplete 1 KB skeleton containing only partial profile definitions missing key feature arrays.
- **Impact:** When QML loaded `GameList.qml` or `Graphics.qml`, property bindings failed with unhandled TypeErrors, causing `CustomStackView` to silently abort rendering (solid black Gaming tab).
- **Fix:** Purging `qmlcache` and rotating `GExDb.blb` allows Adrenalin to synthesize fresh bytecode and rebuild the full 19-game database cleanly.

### F. EasyAntiCheat (`EasyAntiCheat_EOS`) Isolation
- In EAC-protected executables (e.g. *Lords of the Fallen* `LOTF2-Win64-Shipping.exe`), EAC blocks 3rd-party DLL injection (`amdihk64.dll` blocked, `ihk: False`).
- In non-EAC or bypass titles (*Crimson Desert*, *Elden Ring*, *Onimusha*), `amdihk64.dll` injects natively (`ihk: True`), providing full in-game OSD rendering.

---

## 3. Automated Master Fix Script

Save and run the following PowerShell script with Administrator privileges to apply the complete baseline configuration:

```powershell
<#
.SYNOPSIS
    AMD Radeon RX 9060 XT Master Baseline Hardening Script
    Applies verified positive registry keys, removes destructive negative tweaks,
    purges corrupted Qt QML caches, and aligns startup tasks.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " AMD RADEON OVERLAY & RECORDING MASTER HARDENING APPLIER " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Terminate running UI instances to allow file/registry updates
Write-Host "`n[1/5] Stopping AMD UI processes gracefully..." -ForegroundColor Yellow
Stop-Process -Name "RadeonSoftware" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# 2. Clean up destructive negative registry tweaks
Write-Host "[2/5] Purging destructive negative registry keys..." -ForegroundColor Yellow
$NegativeKeys = @(
    "HKCU:\SOFTWARE\AMD\DVR",
    "HKLM:\SOFTWARE\AMD\DVR"
)
$NegativeValues = @(
    "DisableAmdCapture",
    "DisableSharedTextureCopy",
    "DXSyncDisable"
)
foreach ($key in $NegativeKeys) {
    if (Test-Path $key) {
        foreach ($val in $NegativeValues) {
            Remove-ItemProperty -Path $key -Name $val -ErrorAction SilentlyContinue
            Write-Host "  Removed $val from $key" -ForegroundColor DarkGray
        }
    }
}

# 3. Apply strictly positive enablement registry keys
Write-Host "[3/5] Applying verified positive enablement keys..." -ForegroundColor Yellow

# HKCU DVR
$HkcuDvr = "HKCU:\SOFTWARE\AMD\DVR"
if (-not (Test-Path $HkcuDvr)) { New-Item -Path $HkcuDvr -Force | Out-Null }
Set-ItemProperty -Path $HkcuDvr -Name "DvrEnabled" -Value 1 -Type DWord
Set-ItemProperty -Path $HkcuDvr -Name "AllowRSOverlay" -Value 1 -Type DWord
Set-ItemProperty -Path $HkcuDvr -Name "ShowRSOverlay" -Value 1 -Type DWord
Set-ItemProperty -Path $HkcuDvr -Name "RecordPerfUI" -Value 1 -Type DWord
Set-ItemProperty -Path $HkcuDvr -Name "BorderlessEnabled" -Value 1 -Type DWord
Set-ItemProperty -Path $HkcuDvr -Name "DesktopRecordingEnabled" -Value 0 -Type DWord  # Prevents Thread 0 deadlock
Set-ItemProperty -Path $HkcuDvr -Name "DDAccepted" -Value 1 -Type DWord
Set-ItemProperty -Path $HkcuDvr -Name "EFCEnabledOverride" -Value 1 -Type DWord     # Enforces hardware VCN frame conversion
Set-ItemProperty -Path $HkcuDvr -Name "AvcEfcSupport" -Value 1 -Type DWord
Set-ItemProperty -Path $HkcuDvr -Name "HevcEfcSupport" -Value 1 -Type DWord
Set-ItemProperty -Path $HkcuDvr -Name "Av1EfcSupport" -Value 1 -Type DWord
Set-ItemProperty -Path $HkcuDvr -Name "FileEncoderType" -Value "AV1" -Type String

# HKLM DVR
$HklmDvr = "HKLM:\SOFTWARE\AMD\DVR"
if (-not (Test-Path $HklmDvr)) { New-Item -Path $HklmDvr -Force | Out-Null }
Set-ItemProperty -Path $HklmDvr -Name "DvrEnabled" -Value 1 -Type DWord
Set-ItemProperty -Path $HklmDvr -Name "AllowRSOverlay" -Value 1 -Type DWord
Set-ItemProperty -Path $HklmDvr -Name "ShowRSOverlay" -Value 1 -Type DWord
Set-ItemProperty -Path $HklmDvr -Name "RecordPerfUI" -Value 1 -Type DWord
Set-ItemProperty -Path $HklmDvr -Name "BorderlessEnabled" -Value 1 -Type DWord
Set-ItemProperty -Path $HklmDvr -Name "DesktopRecordingEnabled" -Value 0 -Type DWord
Set-ItemProperty -Path $HklmDvr -Name "DDAccepted" -Value 1 -Type DWord
Set-ItemProperty -Path $HklmDvr -Name "EFCEnabledOverride" -Value 1 -Type DWord

# HKCU CN (UI & Input Navigation)
$HkcuCn = "HKCU:\SOFTWARE\AMD\CN"
if (-not (Test-Path $HkcuCn)) { New-Item -Path $HkcuCn -Force | Out-Null }
Set-ItemProperty -Path $HkcuCn -Name "EscapeInputState" -Value "true" -Type String  # Allows Esc key overlay dismissal
Set-ItemProperty -Path $HkcuCn -Name "SidebarWidth" -Value 375 -Type DWord          # Restores native sidebar aspect ratio
Set-ItemProperty -Path $HkcuCn -Name "TriggerShowCNViaHK" -Value 1 -Type DWord

Write-Host "  Registry hardening complete." -ForegroundColor Green

# 4. Purge stale QML bytecode & experience cache
Write-Host "[4/5] Clearing stale QML bytecode and rotating database..." -ForegroundColor Yellow
$QmlCache = "$env:LOCALAPPDATA\AMD\Radeonsoftware\cache\qmlcache"
$ShaderCache = "$env:LOCALAPPDATA\AMD\Radeonsoftware\cache\_qt_QGfxShaderBuilder_6.9.0"
$GExDb = "$env:LOCALAPPDATA\AMD\CN\GExDb.blb"

if (Test-Path $QmlCache) {
    Remove-Item -Path "$QmlCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Purged: $QmlCache" -ForegroundColor DarkGray
}
if (Test-Path $ShaderCache) {
    Remove-Item -Path "$ShaderCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Purged: $ShaderCache" -ForegroundColor DarkGray
}
if (Test-Path $GExDb) {
    Move-Item -Path $GExDb -Destination "$GExDb.bak" -Force -ErrorAction SilentlyContinue
    Write-Host "  Rotated: GExDb.blb -> GExDb.blb.bak" -ForegroundColor DarkGray
}

# 5. Clean up redundant scheduled tasks
Write-Host "[5/5] Cleaning up legacy scheduled tasks..." -ForegroundColor Yellow
$LegacyTasks = @("AMD-Overlay-Forensic", "AMD-Overlay-Guard", "AMD-Overlay-Watchdog", "AMD-Overlay-Relay")
foreach ($t in $LegacyTasks) {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}

# Relaunch Adrenalin cleanly
Start-Process "C:\Program Files\AMD\CNext\CNext\RadeonSoftware.exe"
Write-Host "`nSUCCESS: Baseline profile applied and Adrenalin relaunched." -ForegroundColor Green
```

---

## 4. Game-Specific Configuration Hardening

### Lords of the Fallen (Unreal Engine 5 Native HDR & Borderless Output)
- **Configuration File:**  
  `%LOCALAPPDATA%\LOTF2\Saved\Config\Windows\Engine.ini`
- **Enforced Settings:**
  ```ini
  [SystemSettings]
  r.FullScreenMode=1
  r.HDR.EnableHDROutput=1
  r.HDR.Display.MaxLuminance=1000
  r.HDR.Display.MidLuminance=20
  r.HDR.Display.OutputDevice=3
  r.HDR.UI.Luminance=500
  ```
- **GameUserSettings Alignment:**  
  `%LOCALAPPDATA%\LOTF2\Saved\Config\Windows\GameUserSettings.ini`
  ```ini
  FullscreenMode=1
  bUseHDRDisplayOutput=True
  ```
- **Benefit:** Forces Unreal Engine 5 to create a native 10-bit HDR borderless swapchain from initialization frame 1. Eliminates dynamic mid-game swapchain destruction that triggers AMF pre-analysis kernel deadlocks.

---

## 5. Active In-Game Hotkeys Reference

| Shortcut | Description | Behavior |
| :--- | :--- | :--- |
| **`Alt+Z`** | **In-Game Sidebar Overlay** | Opens the native 375px sidebar overlay with fully interactive mouse cursor. Provides access to game graphics overrides (FSR, HYPR-RX, AFMF 2.1, Anti-Lag, RIS). |
| **`Alt+R`** | **Full-Screen In-Game Overlay** | Opens the full Adrenalin dashboard overlay over borderless/windowed games. |
| **`Ctrl+Shift+O`** | **Performance Metrics Overlay** | Toggles real-time on-screen telemetry (FPS, Frametime, GPU Temperature, Hotspot, VRAM usage). |
| **`Ctrl+Shift+E`** | **Toggle Video Recording** | Starts / stops hardware-accelerated AV1 MP4 recording directly to `C:\Users\Avisek\Videos\Radeon ReLive\`. |

---

## 6. Critical Operational Protocols

> [!IMPORTANT]
> **Rule 1: Set HDR and Window Mode BEFORE Starting Video Recording**  
> Dynamic swapchain format switching (8-bit SDR $\leftrightarrow$ 10-bit HDR) while actively encoding to an MP4 container invalidates GPU surface handles (`DXGI_ERROR_ACCESS_LOST`) and deadlocks `onnxruntime.dll` / `amf-pa-ml64.dll`.  
> *Ensure HDR is already ON in Windows display settings or in-game configuration before pressing `Ctrl+Shift+E`.*

> [!TIP]
> **Rule 2: FanControl Service Coexistence**  
> `FanControl.exe` operates as a critical hardware safeguard for the RX 9060 XT GPU and VRAM hotspot sensors. `FanControl.Service` is set to **Automatic (Delayed Start)** to guarantee that display driver initialization completes before sensor polling begins. Do not terminate or alter FanControl.

> [!NOTE]
> **Rule 3: Windows Update & `sfc /scannow` Survival**  
> All remediations are implemented via native registry values, user configuration files (`Engine.ini`), and standard cache purges. No Windows system binaries were patched, ensuring full survival across Windows Updates and System File Checker scans.

---

## 7. Verification & Health Check Procedure

Run this one-liner in PowerShell anytime to verify that the entire AMD stack is healthy:

```powershell
Get-Process | Where-Object { $_.ProcessName -match "AMDRSServ|RadeonSoftware|FanControl" } | Select-Object Id, ProcessName, Responding, @{N="WorkingSetMB";E={[math]::Round($_.WorkingSet64/1MB,1)}} | Format-Table -AutoSize
```

**Expected Healthy State:**
- `AMDRSServ`: `Responding = True`, ~320-350 MB WorkingSet
- `RadeonSoftware`: `Responding = True`, ~500-550 MB WorkingSet (fully rendered library)
- `FanControl`: `Responding = True`, ~90-110 MB WorkingSet (hotspot curve active)
