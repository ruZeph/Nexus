# enable-capframex.ps1 - restore CapFrameX + Intel PresentMon Shared Service
$ErrorActionPreference = 'SilentlyContinue'

Write-Host "########## BEFORE ##########"
$t = Get-ScheduledTask -TaskName 'CapFrameX' -ErrorAction SilentlyContinue
if ($t) { Write-Host ("  CapFrameX task        : " + $t.State) } else { Write-Host "  CapFrameX task        : (not found)" }
Write-Host ("  PresentMonSharedSvc   : " + (Get-Service PresentMonSharedService).Status + " / " + (Get-Service PresentMonSharedService).StartType)
Write-Host ("  CapFrameX proc        : " + ((Get-Process CapFrameX -EA SilentlyContinue | Measure-Object).Count))
Write-Host ("  PresentMon proc       : " + ((Get-Process PresentMon-2.6.0-x64 -EA SilentlyContinue | Measure-Object).Count))

Write-Host ""
Write-Host "########## 1. Enable the CapFrameX autostart task ##########"
if ($t) {
    Enable-ScheduledTask -TaskName 'CapFrameX' | Out-Null
    Write-Host ("  state now : " + (Get-ScheduledTask -TaskName 'CapFrameX').State)
}

Write-Host ""
Write-Host "########## 2. Restore Intel PresentMon Shared Service to Automatic ##########"
Set-Service PresentMonSharedService -StartupType Automatic
Start-Service PresentMonSharedService
Start-Sleep -Seconds 3
Write-Host ("  now : " + (Get-Service PresentMonSharedService).Status + " / " + (Get-Service PresentMonSharedService).StartType)

Write-Host ""
Write-Host "########## 3. Launch CapFrameX now ##########"
if (Get-ScheduledTask -TaskName 'CapFrameX' -ErrorAction SilentlyContinue) {
    Start-ScheduledTask -TaskName 'CapFrameX'
    Write-Host "  started via scheduled task"
} else {
    Start-Process 'C:\Program Files (x86)\CapFrameX\CapFrameX.exe'
    Write-Host "  started directly"
}
Start-Sleep -Seconds 12

Write-Host ""
Write-Host "########## AFTER ##########"
Write-Host ("  CapFrameX task        : " + (Get-ScheduledTask -TaskName 'CapFrameX').State)
Write-Host ("  PresentMonSharedSvc   : " + (Get-Service PresentMonSharedService).Status + " / " + (Get-Service PresentMonSharedService).StartType)
Get-Process CapFrameX,PresentMon-2.6.0-x64,PresentMonService -ErrorAction SilentlyContinue |
  Select-Object ProcessName,Id,StartTime | Format-Table -AutoSize | Out-String -Width 120 | Write-Host

Write-Host "########## overlay state ##########"
$src = @"
using System; using System.Runtime.InteropServices;
public class CF {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint m, uint vk);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr h, int id);
}
"@
Add-Type -TypeDefinition $src -ErrorAction SilentlyContinue
$ok = [CF]::RegisterHotKey([IntPtr]::Zero, 37070, 0x0001, [int][char]'R')
if ($ok) { [CF]::UnregisterHotKey([IntPtr]::Zero, 37070) | Out-Null; Write-Host "  Alt+R : FREE (overlay dead)" } else { Write-Host "  Alt+R : HELD by AMD (alive)" }

# marker so we can measure the impact of re-enabling these on the overlay death rate
Add-Content "$env:LOCALAPPDATA\AMD-Overlay-Watchdog\forensic.log" -Value ((Get-Date -Format 'HH:mm:ss.fff') + '  ==================== CAPFRAMEX + PRESENTMON SHARED SERVICE RE-ENABLED - MEASUREMENT STARTS HERE ====================') -Encoding UTF8
Write-Host ""
Write-Host "  marker written to forensic.log"
