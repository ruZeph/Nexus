# AMD Radeon Overlay & Recording Mitigation Guide
**Platform:** Windows 11 Pro 25H2 (Build 26200.9711) | ASRock B850 Pro-A WiFi | Ryzen 5 7600X  
**GPU:** AMD Radeon RX 9060 XT (Driver: 32.0.32015.12012 / Adrenalin 26.20.15.12)  
**Status Date:** November 8, 2026  
**Document Version:** 3.0 (Negative Tweaks Reverted; Positive Enablement Keys Hardened)

---

## 1. Executive Summary

Following live testing and binary disassembly of `AMDRSServ.exe`, all negative tweaks (`Disable*` and sync disable flags) have been **completely reverted/deleted**. Disassembly of `AMDRSServ.exe` confirmed that:
- `DisableAmdCapture = 1` caused an unconditional jump (`je 0x89fa0`) that completely bypassed 5,302 bytes of AMD in-game capture and hook initialization.
- `DisableSharedTextureCopy = 1` cleared the `bUseSharedTextureCopy` flag, preventing the DirectX 12 shared surface compositing required for the in-game overlay.

**All negative keys have been deleted.** The system now strictly retains only the **positive enablement and layout fix keys**.

---

## 2. Active Configuration: Retained Positive Keys Only

### Table 1: Current User Settings (`HKCU\SOFTWARE\AMD\DVR`)

| Value Name | Type | Value | Engineering Purpose |
|---|---|---|---|
| `BorderlessEnabled` | `REG_DWORD` | **`1`** | Permits video recording and overlay compositing when games run in borderless windowed mode. |
| `DesktopRecordingEnabled` | `REG_DWORD` | **`1`** | Enables desktop duplication capture pipeline for borderless capture. |
| `DDAccepted` | `REG_DWORD` | **`1`** | Pre-accepts Desktop Duplication API permissions silently. |
| `EFCEnabledOverride` | `REG_DWORD` | **`1`** | Forces hardware VCN Enhanced Frame Conversion, bypassing the OpenCL (`amdocl64.dll`) texture interop deadlock. |
| `AllowRSOverlay` | `REG_DWORD` | **`1`** | Explicitly permits in-game overlay initialization. |
| `ShowRSOverlay` | `REG_DWORD` | **`1`** | Signals overlay presentation pipeline to activate. |
| `RecordPerfUI` | `REG_DWORD` | **`1`** | Keeps overlay UI alive during performance metrics monitoring. |
| `DvrEnabled` | `REG_DWORD` | **`1`** | Enables Radeon ReLive DVR recording subsystem. |

### Table 2: System-Wide Settings (`HKLM\SOFTWARE\AMD\DVR`)

| Value Name | Type | Value | Engineering Purpose |
|---|---|---|---|
| `BorderlessEnabled` | `REG_DWORD` | **`1`** | System-wide borderless capture enablement. |
| `DesktopRecordingEnabled` | `REG_DWORD` | **`1`** | System-wide desktop duplication enablement for elevated game processes. |
| `DDAccepted` | `REG_DWORD` | **`1`** | System-wide desktop duplication pre-authorization. |
| `EFCEnabledOverride` | `REG_DWORD` | **`1`** | System-wide hardware EFC frame conversion override. |
| `AllowRSOverlay` | `REG_DWORD` | **`1`** | System-wide overlay authorization. |
| `ShowRSOverlay` | `REG_DWORD` | **`1`** | System-wide overlay display flag. |
| `RecordPerfUI` | `REG_DWORD` | **`1`** | System-wide UI recording flag. |
| `DvrEnabled` | `REG_DWORD` | **`1`** | Master system-wide ReLive DVR subsystem activation flag. |

### Table 3: User Interface & Sidebar Dimensions (`HKCU\SOFTWARE\AMD\CN`)

| Value Name | Type | Value | Engineering Purpose |
|---|---|---|---|
| `EscapeInputState` | `REG_SZ` | **`"true"`** | Restores Escape key (`VK_ESCAPE`) & outside-click dismissal handling. |
| `SidebarWidth` | `REG_DWORD` | **`375`** | Resets corrupted 1280px hit-test width back to native 375px sidebar dimensions. |
| `TriggerShowCNViaHK` | `REG_DWORD` | **`1`** | Enables hotkey-triggered visibility toggling of CNext UI. |

---

## 3. Reverted Negative Keys (Deleted Across HKCU and HKLM)

| Registry Key Name | Hive(s) | Original Action | Reason for Reversion / Binary Forensic Finding |
|---|---|---|---|
| `DisableAmdCapture` | HKCU & HKLM | Deleted | Disassembly at `0x87ad4` revealed `cmp [rbp-18h], 1; je 0x89fa0`, which completely aborted all capture setup. |
| `DisableSharedTextureCopy` | HKCU & HKLM | Deleted | Disassembly at `0xd02a5` showed it cleared `bUseSharedTextureCopy`, preventing D3D12 shared surface compositing. |
| `DXSyncDisable` | HKCU & HKLM | Deleted | Reverted to default AMD DirectX synchronization fence behavior. |

---

## 4. Background Services & System Infrastructure

| Component | Active State | Purpose |
|---|---|---|
| `FanControl.Service` | **`Automatic (Delayed Start)`** | Eliminates boot race with `AMDADLXServ.exe` (147 OLEAUT32 crashes eliminated). **Custom fan curve for RX 9060 XT hotspot sensor is 100% intact.** |
| `WinRT PresenceWriter` | **Cleanly De-registered** | Returns `0x80040154` in <0.001ms, eliminating 30s DCOM 10010 hang. **100% survives `sfc /scannow`.** |
| `AMD-Overlay-Guard` (Task) | **Disabled & Terminated** | Eliminated false-positive watchdog that aggressively killed AMD processes. |


---

## 5. Game-Specific Configuration Hardening

### A. Lords of the Fallen (UE5 Native HDR & Borderless Output)
- **Path:** `C:\Users\Avisek\AppData\Local\LOTF2\Saved\Config\Windows\Engine.ini`
- **Applied Configuration:**
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
  `bUseHDRDisplayOutput=True` and `FullscreenMode=1` (Borderless Windowed).
- **Benefit:** The game launches directly in 10-bit HDR borderless mode from frame 1, avoiding mid-game swapchain format changes that previously caused AMF DirectML/ONNX deadlocks.

---

## 6. Critical Operational Protocol: Recording & HDR

> [!IMPORTANT]
> **Set HDR and Window Mode BEFORE starting the recording!**  
> Dynamic swapchain destruction mid-recording (switching 8-bit SDR $\leftrightarrow$ 10-bit HDR while actively writing to an MP4 container) causes capture pipelines to lose surface handles (`DXGI_ERROR_ACCESS_LOST`).
> 
> If HDR is already turned ON in Windows or game settings before you press `Ctrl+Shift+E`, the AMF encoder initializes directly for 10-bit HDR from frame 1 with no mid-stream reconstruction, and recording works seamlessly.
