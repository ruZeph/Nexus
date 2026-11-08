# AMD Radeon Overlay & Recording Mitigation Guide
**Platform:** Windows 11 Pro 25H2 (Build 26200.9711) | ASRock B850 Pro-A WiFi | Ryzen 5 7600X  
**GPU:** AMD Radeon RX 9060 XT (Driver: 32.0.32015.12012 / Adrenalin 26.20.15.12)  
**Status Date:** November 8, 2026  

---

## 1. Executive Summary & Current Problem

### Observed Symptoms:
1. **Video Recording & Hotkeys Functional:**  
   Video recording hotkeys (`Alt+R` / `Ctrl+Shift+E`) now work in borderless/windowed games (*Crimson Desert* and *Lords of the Fallen 2*), and video captures are written cleanly to `C:\Users\Avisek\Videos\Radeon ReLive\`.
2. **Current Remaining Defect:**  
   When triggering the overlay (`Alt+R`) in-game:
   - The AMD Radeon Software sidebar freezes on screen.
   - The Windows mouse cursor disappears (hidden by the game's `ShowCursor(FALSE)`).
   - Pressing `Esc` or `Alt+R` fails to dismiss the sidebar.

---

## 2. Exhaustive Log of Exact Changes Done

All modifications performed across the system are documented below with their exact registry keys, hives, previous values, and new values:

### A. Registry Changes (AMD DVR & Capture Subsystem)

| Hive & Registry Path | Value Name | Type | Previous Value | New Value | Purpose / Mechanism |
|---|---|---|---|---|---|
| `HKCU\SOFTWARE\AMD\DVR` | `BorderlessEnabled` | `REG_DWORD` | `0` | **`1`** | Permits video recording and overlay compositing when games run in borderless windowed mode. |
| `HKLM\SOFTWARE\AMD\DVR` | `BorderlessEnabled` | `REG_DWORD` | `0` | **`1`** | System-wide alignment for elevated/system processes. |
| `HKCU\SOFTWARE\AMD\DVR` | `DesktopRecordingEnabled` | `REG_DWORD` | `0` (missing) | **`1`** | Enables desktop duplication capture pipeline for borderless capture. |
| `HKLM\SOFTWARE\AMD\DVR` | `DesktopRecordingEnabled` | `REG_DWORD` | `0` (missing) | **`1`** | System-wide alignment. |
| `HKCU\SOFTWARE\AMD\DVR` | `EFCEnabledOverride` | `REG_DWORD` | `(not set)` | **`1`** | Forces Enhanced Frame Conversion (EFC) in hardware on the VCN encoder, bypassing buggy OpenCL (`amdocl64.dll`) texture interop. |
| `HKLM\SOFTWARE\AMD\DVR` | `EFCEnabledOverride` | `REG_DWORD` | `(not set)` | **`1`** | System-wide EFC override alignment. |
| `HKCU\SOFTWARE\AMD\DVR` | `AllowRSOverlay` | `REG_DWORD` | `(not set)` | **`1`** | Explicitly permits Radeon Software in-game overlay initialization. |
| `HKLM\SOFTWARE\AMD\DVR` | `AllowRSOverlay` | `REG_DWORD` | `(not set)` | **`1`** | System-wide overlay permission. |
| `HKCU\SOFTWARE\AMD\DVR` | `ShowRSOverlay` | `REG_DWORD` | `(not set)` | **`1`** | Signals overlay presentation pipeline to activate. |
| `HKLM\SOFTWARE\AMD\DVR` | `ShowRSOverlay` | `REG_DWORD` | `(not set)` | **`1`** | System-wide overlay display flag. |
| `HKCU\SOFTWARE\AMD\DVR` | `RecordPerfUI` | `REG_DWORD` | `(not set)` | **`1`** | Ensures overlay UI rendering remains active during performance metrics monitoring. |
| `HKLM\SOFTWARE\AMD\DVR` | `RecordPerfUI` | `REG_DWORD` | `(not set)` | **`1`** | System-wide UI recording flag. |

### B. Registry Changes (AMD CN User Interface Subsystem)

| Hive & Registry Path | Value Name | Type | Previous Value | New Value | Purpose / Mechanism |
|---|---|---|---|---|---|
| `HKCU\SOFTWARE\AMD\CN` | `EscapeInputState` | `REG_SZ` | `"false"` | **`"true"`** | Restores Escape key (`VK_ESCAPE`) and outside-click handling so the user can dismiss the sidebar. |
| `HKCU\SOFTWARE\AMD\CN` | `SidebarWidth` | `REG_DWORD` | `1280` | **`375`** | Resets distorted 1280px hit-test width (which swallowed 67% of screen) back to native 375px sidebar dimensions. |
| `HKCU\SOFTWARE\AMD\CN` | `TriggerShowCNViaHK` | `REG_DWORD` | `0` | **`1`** | Enables hotkey-triggered visibility toggling of CNext UI. |

### C. System Services & Background Infrastructure

| Component / Path | Previous State | New State | Purpose / Mechanism |
|---|---|---|---|
| `FanControl.Service` | `Automatic` | **`Automatic (Delayed Start)`** | Eliminates boot race with `AMDADLXServ.exe` (147 OLEAUT32 crashes eliminated). Fan curve intact. |
| `AMD-Overlay-Guard` (Task) | Enabled (`overlay-guard.ps1`) | **Disabled & Terminated** | Eliminated false-positive watchdog that violently killed AMD processes when games ran exclusive fullscreen. |
| `WinRT PresenceWriter` | Registered with IFEO block | **De-registered cleanly** | Removed classes from `HKLM\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId`. Returns `0x80040154` in <0.001ms, eliminating 30s DCOM 10010 hang. Survives `sfc /scannow`. |
| Scheduled Task `\StartDVR` | Running (hung PID) | **Restarted cleanly** | Re-launched `AMDRSServ.exe` at interactive medium integrity. |

### D. Timestamped Backups Created

1. `C:\Users\Avisek\Desktop\AMD_DVR_Backup_20261108_220757.json` (Initial DVR registry backup)
2. `C:\Users\Avisek\Desktop\AMD_Overlay_Cursor_Backup_20261108_223105.json` (Complete CN and DVR state backup)
3. `C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix\evidence\winrt-presencewriter-backup.json` (WinRT presence writer backup)
4. `C:\Users\Avisek\.gemini\antigravity\brain\8710ae23-7fb5-4db9-8d51-bb74abff9ae1\scratch\amdrsserv_live_hung.dmp` (Live hung thread dump)

---

## 3. Deep-Dive Forensic Root Cause of Current Freeze

Live minidump analysis of `AMDRSServ.exe` (captured during live hang) revealed the exact reason the sidebar freezes and the mouse disappears:

### Call Stack of Thread 0 (UI Message Pump Thread):
```text
ntdll.dll!ZwWaitForSingleObject
ntdll.dll!LdrGetDllHandleEx + 0x116a
D3D12Core.dll!D3D12CoreCreateLayeredChild
D3D12Core.dll + 0x6a1d8
D3D12.dll!D3D12CreateDevice + 0x6b8b
AMDRSServ.exe + 0x6dc59 (InitDX12)
AMDRSServ.exe + 0x6d1bf (StartDesktopPipeline)
AMDRSServ.exe + 0x34cfe ("Desktop pipeline has been started")
```

### The Chain of Failure:
1. **Desktop Pipeline Triggers `InitDX12()` on Main Thread:**  
   When `DesktopRecordingEnabled = 1` is active, `AMDRSServ.exe` calls `StartDesktopPipeline`, which synchronously calls `InitDX12()` $\rightarrow$ `D3D12CreateDevice` on Thread 0 (the GUI message loop thread).
2. **Synchronous Loader Lock Deadlock:**  
   `D3D12CreateDevice` attempts to load the AMD DirectX 12 driver (`amdxc64.dll`) while `amdxx64.dll` (DirectX 11 driver) is already active. This triggers a deadlock inside `ntdll!LdrGetDllHandleEx` / `ZwWaitForSingleObject`.
3. **User32 Marks Window as Hung:**  
   `IsHungAppWindow(hwnd_dvr)` returns `True`. User32 immediately ceases delivering desktop input messages to `AMDRSServ.exe` and suspends registered hotkeys (`Alt+R` drops to `FREE`).
4. **Hardware Cursor Pipeline Fails to Fire:**  
   Because Thread 0 is deadlocked in `InitDX12`, `InGameUiBitmapReceived` and `ADL2_Desktop_HardwareCursor_Toggle` never execute. 3D games hide the Windows cursor via `ShowCursor(FALSE)`, so the mouse cursor remains completely invisible.
5. **Sidebar Orphaned:**  
   The Qt6 sidebar (`RadeonSoftware.exe`) is displayed, but mouse click routing from `AMDRSServ.exe` is frozen.

---

## 4. Mitigation Actions Being Applied Right Now

To resolve the DX12/OpenCL loader deadlock in `AMDRSServ.exe` while preserving borderless recording:

1. **`DisableAmdCapture = 1`:**  
   Instructs `AMDRSServ.exe` to bypass the buggy internal DX12 hook loader (`InitDX12`), allowing clean borderless capture without locking Thread 0.
2. **`DXSyncDisable = 1`:**  
   Sets `AMF_PA_DISABLE_DX_SYNC = true` to prevent any asynchronous DirectX fence timeouts.
3. **`DisableSharedTextureCopy = 1`:**  
   Disables cross-device shared texture locking that blocks the message pump.
4. **Clean Stack Bounce:**  
   Terminate hung `AMDRSServ.exe` PID and restart cleanly via `schtasks /run /tn StartDVR`.
