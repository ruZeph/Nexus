# fix-rsx.ps1 - repair the RSX (overlay render) component
# Rationale: Alt+R -> RSServCmd toggle_in_content_rs_perf_FROM_RSX deadlocks, and the
# driver key reports RSXBrowserUnavailable=true. The RSXCM package is a stale
# 22.10.0.0 (Oct 2022) build against a 26.9.2 app. Removing it forces AMD Software
# to re-register a fresh RSX component on next start.
$ErrorActionPreference = 'SilentlyContinue'

Write-Host "########## 1. BEFORE ##########"
Write-Output ('  RSXCM: ' + (Get-AppxPackage -AllUsers AdvancedMicroDevicesInc-RSXCM | ForEach-Object { $_.PackageFullName }))
$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000'
Write-Output ('  RSXBrowserUnavailable = ' + (Get-ItemProperty $k -Name RSXBrowserUnavailable).RSXBrowserUnavailable)
Write-Output ('  AllowRSOverlay        = ' + (Get-ItemProperty $k -Name AllowRSOverlay).AllowRSOverlay)

Write-Host ""
Write-Host "########## 2. Stop AMD Software ##########"
Get-Process | Where-Object { $_.Name -match '^(RadeonSoftware|amdow|cncmd|AMDRSServ|AMDRSSrcExt|RSServCmd|CPUMetricsServer)$' } |
  ForEach-Object { Write-Host "  killing $($_.Name) (pid $($_.Id))"; Stop-Process -Id $_.Id -Force }
Start-Sleep -Seconds 5

Write-Host ""
Write-Host "########## 3. Remove the stale RSXCM package ##########"
foreach ($p in (Get-AppxPackage -AllUsers AdvancedMicroDevicesInc-RSXCM)) {
    Write-Host ("  removing: " + $p.PackageFullName)
    Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
}
$prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'AdvancedMicroDevicesInc-RSXCM' }
if ($prov) {
    Write-Host ("  removing provisioned: " + $prov.PackageName)
    Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction SilentlyContinue | Out-Null
}
# also clear the RSX install staging so a fresh copy is laid down
Remove-Item 'C:\Program Files\AMD\CNext\CNBranding' -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "########## 4. Clear the RSX 'unavailable' flag so it re-evaluates ##########"
# Only remove the flag; AMD re-writes it based on its own health check on start.
Remove-ItemProperty -Path $k -Name 'RSXBrowserUnavailable' -Force -ErrorAction SilentlyContinue
Write-Output ('  RSXBrowserUnavailable now = ' + (Get-ItemProperty $k -Name RSXBrowserUnavailable).RSXBrowserUnavailable + ' (blank = re-evaluated on start)')

Write-Host ""
Write-Host "########## 5. Relaunch AMD Software + repair ##########"
Start-ScheduledTask -TaskName 'AMD-Overlay-Relay'
Start-Sleep -Seconds 10
& powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\Users\Avisek\amd-overlay-watchdog.ps1' -Force

Write-Host ""
Write-Host "########## 6. VERIFY ##########"
$src = @"
using System; using System.Runtime.InteropServices;
public class RX {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint m, uint vk);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr h, int id);
}
"@
Add-Type -TypeDefinition $src -ErrorAction SilentlyContinue
$ok = [RX]::RegisterHotKey([IntPtr]::Zero, 37030, 0x0001, [int][char]'R')
if ($ok) { [RX]::UnregisterHotKey([IntPtr]::Zero, 37030) | Out-Null; $r='FREE (dead)' } else { $r='HELD by AMD (alive)' }
Write-Output "  Alt+R : $r"
Write-Output ('  RSXCM present : ' + [bool](Get-AppxPackage -AllUsers AdvancedMicroDevicesInc-RSXCM))
Write-Output ('  RSXBrowserUnavailable = ' + (Get-ItemProperty $k -Name RSXBrowserUnavailable).RSXBrowserUnavailable)
Add-Content "$env:LOCALAPPDATA\AMD-Overlay-Watchdog\forensic.log" -Value ((Get-Date -Format 'HH:mm:ss.fff') + '  ==================== RSX COMPONENT RESET (RSXCM removed, RSXBrowserUnavailable cleared) - VALIDATION 3 STARTS HERE ====================') -Encoding UTF8
Write-Output '  validation-3 marker written to forensic.log'
