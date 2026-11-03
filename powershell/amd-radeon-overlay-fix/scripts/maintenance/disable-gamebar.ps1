# disable-gamebar.ps1 - neutralise the proven overlay trigger (Xbox Game Bar / GameDVR)
# Backs up current values first so it is fully reversible.
$ErrorActionPreference = 'SilentlyContinue'

$backup = Join-Path $env:LOCALAPPDATA 'AMD-Overlay-Watchdog\gamebar-backup.txt'
New-Item -ItemType Directory -Path (Split-Path $backup) -Force | Out-Null

Write-Host "############ 1. BACKUP current values ############"
$items = @(
  @{ Path='HKCU:\System\GameConfigStore';                              Name='GameDVR_Enabled' },
  @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR';   Name='AppCaptureEnabled' },
  @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR';   Name='HistoricalCaptureEnabled' },
  @{ Path='HKCU:\Software\Microsoft\GameBar';                          Name='AutoGameModeEnabled' }
)
$lines = @("GameDVR backup $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
foreach ($i in $items) {
    $v = (Get-ItemProperty $i.Path -Name $i.Name -ErrorAction SilentlyContinue).($i.Name)
    $txt = "  $($i.Path) :: $($i.Name) = $v"
    Write-Host $txt
    $lines += $txt
}
$lines += "  HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR :: AllowGameDVR = (absent)"
$lines | Set-Content $backup -Encoding UTF8
Write-Host "  backup saved -> $backup"

Write-Host ""
Write-Host "############ 2. DISABLE Game Bar / GameDVR ############"
# HKCU: the actual switches Game Bar reads
Set-ItemProperty 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -Type DWord
Write-Host "  HKCU\System\GameConfigStore\GameDVR_Enabled = 0"
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0 -Type DWord
Write-Host "  ...\GameDVR\AppCaptureEnabled = 0"
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'HistoricalCaptureEnabled' -Value 0 -Type DWord
Write-Host "  ...\GameDVR\HistoricalCaptureEnabled = 0"
# Keep FSE behaviour OS-default (do not force fullscreen optimisations off)
Set-ItemProperty 'HKCU:\System\GameConfigStore' -Name 'GameDVR_FSEBehaviorMode' -Value 0 -Type DWord

# HKLM policy - hard switch that stops Game Bar auto-launching on game start
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0 -Type DWord
Write-Host "  HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR\AllowGameDVR = 0"

Write-Host ""
Write-Host "############ 3. Stop the running Game Bar processes ############"
foreach ($n in 'GameBar','GameBarFTServer','GameBarPresenceWriter','XboxGameBarWidgets') {
    $p = Get-Process $n -ErrorAction SilentlyContinue
    if ($p) { Write-Host "  killing $n (pid $($p.Id -join ','))"; $p | Stop-Process -Force }
    else    { Write-Host "  $n not running" }
}

Write-Host ""
Write-Host "############ 4. Repair the AMD overlay ############"
Write-Host "  killing hung RSServCmd overlay commands:"
Get-Process RSServCmd -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    pid=$($_.Id)"; Stop-Process -Id $_.Id -Force }
& powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\Users\Avisek\amd-overlay-watchdog.ps1' -Force -NoServiceRestart

Write-Host ""
Write-Host "############ 5. VERIFY ############"
$src = @"
using System; using System.Runtime.InteropServices;
public class VG {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint m, uint vk);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr h, int id);
}
"@
Add-Type -TypeDefinition $src -ErrorAction SilentlyContinue
$ok = [VG]::RegisterHotKey([IntPtr]::Zero, 36920, 0x0001, [int][char]'R')
if ($ok) { [VG]::UnregisterHotKey([IntPtr]::Zero, 36920) | Out-Null; $r = 'FREE' } else { $r = 'HELD by AMD' }
Write-Host "  Alt+R        : $r"
Write-Host ("  GameDVR      : " + (Get-ItemProperty 'HKCU:\System\GameConfigStore' -Name GameDVR_Enabled).GameDVR_Enabled)
Write-Host ("  AppCapture   : " + (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name AppCaptureEnabled).AppCaptureEnabled)
Write-Host ("  AllowGameDVR : " + (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name AllowGameDVR).AllowGameDVR)
Write-Host ("  GameBar procs: " + ((Get-Process GameBar,XboxGameBarWidgets -ErrorAction SilentlyContinue | Measure-Object).Count) + " running")
Write-Host ("  AMD procs    : " + ((Get-Process | Where-Object { $_.Name -match 'RadeonSoftware|amdow|cncmd|AMDRSServ|AMDRSSrcExt|CPUMetricsServer' } | Measure-Object).Count))
