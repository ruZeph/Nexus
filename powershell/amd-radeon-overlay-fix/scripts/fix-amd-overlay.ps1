# fix-amd-overlay.ps1
# Revives the AMD Radeon Software in-game overlay (Alt+R) when the AMD overlay
# stack has failed to initialise -- the logon race between StartCN / StartDVR
# and ~40 other logon tasks.
#
# Run as Administrator:
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Avisek\fix-amd-overlay.ps1

$ErrorActionPreference = 'SilentlyContinue'
$CNext = 'C:\Program Files\AMD\CNext\CNext'

# ---- helper: is Alt+R currently held by AMD? ----
$sig = @"
using System; using System.Runtime.InteropServices;
public class HotkeyProbe {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint m, uint vk);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr h, int id);
}
"@
Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue

function Test-AltR {
  # If we CAN register Alt+R, nobody (incl. AMD) holds it -> overlay is dead.
  $ok = [HotkeyProbe]::RegisterHotKey([IntPtr]::Zero, 9800, 0x0001, [int][char]'R')
  if ($ok) { [HotkeyProbe]::UnregisterHotKey([IntPtr]::Zero, 9800) | Out-Null; return $false }
  return $true
}

Write-Host ""
Write-Host "=== AMD overlay recovery ===" -ForegroundColor Cyan

if (Test-AltR) {
  Write-Host "Alt+R is already held by AMD - overlay is ALIVE. Nothing to do." -ForegroundColor Green
  exit 0
}

Write-Host "Alt+R is NOT registered - overlay stack is dead. Restarting it..." -ForegroundColor Yellow

Write-Host "  stopping AMD External Events Utility"
Stop-Service 'AMD External Events Utility' -Force
Start-Sleep -Seconds 3

foreach ($n in 'RadeonSoftware','amdow','cncmd','AMDRSServ','AMDRSSrcExt','RSServCmd','CPUMetricsServer') {
  $p = Get-Process $n
  if ($p) { Write-Host "  killing $n"; $p | Stop-Process -Force }
}
Start-Sleep -Seconds 6

Write-Host "  starting AMD External Events Utility"
Start-Service 'AMD External Events Utility'
Start-Sleep -Seconds 3

Write-Host "  launching AMD Software (cncmd startwithdelay)"
Start-Process -FilePath (Join-Path $CNext 'cncmd.exe') -ArgumentList 'startwithdelay' -WorkingDirectory $CNext -WindowStyle Hidden

Write-Host "  waiting up to 90s for the overlay subsystem to initialise..."
$deadline = (Get-Date).AddSeconds(90)
$ok = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  if (Test-AltR) { $ok = $true; break }
}

Write-Host ""
if ($ok) {
  Write-Host "SUCCESS - Alt+R is now registered by AMD. Overlay is available." -ForegroundColor Green
  Write-Host "Test with Alt+R (Radeon overlay) and Ctrl+Shift+O (metrics overlay)."
  exit 0
} else {
  Write-Host "FAILED - the overlay still did not initialise." -ForegroundColor Red
  Write-Host "Next steps (in order):"
  Write-Host "  1. Remove the stale RSX component:"
  Write-Host "     Get-AppxPackage -AllUsers AdvancedMicroDevicesInc-RSXCM | Remove-AppxPackage -AllUsers"
  Write-Host "  2. Pause Kaspersky protection + self-defence, then re-run this script."
  Write-Host "  3. Move off the Optional 26.9.2 driver to 26.8.1 WHQL:"
  Write-Host "     https://www.amd.com/en/support/download/drivers.html"
  Write-Host "  4. Reduce logon-task contention (see notes) and reboot."
  exit 1
}
