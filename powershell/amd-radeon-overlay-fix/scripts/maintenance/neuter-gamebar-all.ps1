# neuter-gamebar-all.ps1 - fully eliminate Game Bar / GameDVR / presence / Xbox gaming overlay stack
# Writes a rollback script to %LOCALAPPDATA%\AMD-Overlay-Watchdog\rollback-gamebar.ps1
$ErrorActionPreference = 'SilentlyContinue'
$rbDir = Join-Path $env:LOCALAPPDATA 'AMD-Overlay-Watchdog'
New-Item -ItemType Directory -Path $rbDir -Force | Out-Null
$rb = Join-Path $rbDir 'rollback-gamebar.ps1'
$rbLines = @('# Rollback for neuter-gamebar-all.ps1 - run as Administrator', '')

function H($t) { Write-Host ""; Write-Host "===== $t =====" -ForegroundColor Cyan }

H '1. INVENTORY - Appx packages'
foreach ($n in 'Microsoft.XboxGamingOverlay','Microsoft.GamingApp','Microsoft.XboxIdentityProvider','Microsoft.Xbox.TCUI','Microsoft.XboxSpeechToTextOverlay') {
    $p = Get-AppxPackage -AllUsers $n
    if ($p) { $p | ForEach-Object { Write-Host ("  pkg  {0}  v{1}" -f $_.Name, $_.Version) } } else { Write-Host "  pkg  $n  (absent)" }
}
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match 'Xbox|Gaming' } | ForEach-Object { Write-Host ("  prov {0}" -f $_.DisplayName) }

H '2. INVENTORY - services'
$svcs = Get-Service | Where-Object { $_.Name -match '^(Xbl|Xbox|GameInput|Gaming)' -or $_.DisplayName -match 'Xbox|Game Bar|GameInput' }
$svcs | Select-Object Name,DisplayName,Status,StartType | Format-Table -AutoSize | Out-String -Width 160 | Write-Host

H '3. INVENTORY - scheduled tasks'
$tasks = Get-ScheduledTask | Where-Object { $_.TaskName -match 'Xbox|GameDVR|Game Bar|GameBar|Gaming' }
if ($tasks) { $tasks | Select-Object TaskName,State,TaskPath | Format-Table -AutoSize | Out-String -Width 160 | Write-Host } else { Write-Host '  (none)' }

H '4. INVENTORY - Game Bar binaries'
$bins = @()
foreach ($d in 'C:\Windows\System32','C:\Windows\SysWOW64') {
    $bins += Get-ChildItem $d -Filter 'GameBar*' -File -ErrorAction SilentlyContinue
    $bins += Get-ChildItem $d -Filter 'XboxGame*' -File -ErrorAction SilentlyContinue
}
$bins | Select-Object FullName,Length | Format-Table -AutoSize | Out-String -Width 160 | Write-Host
Write-Host "  WindowsApps copies:"
Get-ChildItem 'C:\Program Files\WindowsApps' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'XboxGamingOverlay|GamingApp' } | ForEach-Object { Write-Host ("    " + $_.Name) }

H '5. INVENTORY - GameDVR/GameBar registry'
foreach ($q in @(
  @('HKCU:\System\GameConfigStore','GameDVR_Enabled'),
  @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR','AppCaptureEnabled'),
  @('HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR','HistoricalCaptureEnabled'),
  @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR','AllowGameDVR'),
  @('HKCU:\Software\Microsoft\GameBar','AutoGameModeEnabled'),
  @('HKCU:\Software\Microsoft\GameBar','UseNexusForGameBarEnabled'),
  @('HKCU:\Software\Microsoft\GameBar','ShowStartupPanel')
)) {
    Write-Host ("  {0} :: {1} = {2}" -f $q[0], $q[1], (Get-ItemProperty $q[0] -Name $q[1] -EA SilentlyContinue).($q[1]))
}

# ------------------------------------------------------------------ APPLY
H '6. APPLY - kill running Game Bar processes'
foreach ($n in 'GameBar','GameBarFTServer','GameBarPresenceWriter','XboxGameBarWidgets','XboxPcAppFT','GameInputRedistService','GameInputSvc') {
    $p = Get-Process $n -ErrorAction SilentlyContinue
    if ($p) { Write-Host "  killing $n (pid $($p.Id -join ','))"; $p | Stop-Process -Force }
}

H '7. APPLY - remove Game Bar Appx packages'
foreach ($n in 'Microsoft.XboxGamingOverlay') {
    foreach ($p in (Get-AppxPackage -AllUsers $n)) {
        Write-Host ("  removing " + $p.PackageFullName)
        Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }
}
foreach ($prov in (Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match 'XboxGamingOverlay' })) {
    Write-Host ("  deprovisioning " + $prov.PackageName)
    Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction SilentlyContinue | Out-Null
}
$rbLines += "Get-AppxPackage Microsoft.XboxGamingOverlay | ForEach-Object { `$loc = `$_.InstallLocation; Add-AppxPackage -Register (Join-Path `$loc 'AppxManifest.xml') -DisableDevelopmentMode -EA SilentlyContinue }"

H '8. APPLY - rename the System32 Game Bar binaries (ownership first)'
foreach ($f in $bins) {
    $fp = $f.FullName
    if ($fp -match '\.disabled$') { continue }
    Write-Host "  $fp"
    takeown /f $fp /a | Out-Null
    icacls $fp /grant "*S-1-5-32-544:F" | Out-Null   # Administrators
    $new = "$fp.disabled"
    try {
        Move-Item -LiteralPath $fp -Destination $new -Force -ErrorAction Stop
        Write-Host "    -> renamed to $new"
        $rbLines += "Move-Item -LiteralPath '$new' -Destination '$fp' -Force"
    } catch { Write-Host "    ! could not rename: $($_.Exception.Message)" }
}

H '9. APPLY - disable services'
foreach ($n in 'XblGameSave','XboxGipSvc','XboxNetApiSvc','XblAuthManager','GameInputRedistService','GameInputSvc') {
    $s = Get-Service $n -ErrorAction SilentlyContinue
    if ($s) {
        $old = (Get-CimInstance Win32_Service -Filter "Name='$n'").StartMode
        Stop-Service $n -Force -ErrorAction SilentlyContinue
        Set-Service $n -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host ("  {0,-24} {1} -> Disabled" -f $n, $old)
        $rbLines += "Set-Service $n -StartupType $old"
    }
}

H '10. APPLY - disable scheduled tasks'
foreach ($t in $tasks) {
    Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue | Out-Null
    Write-Host ("  disabled task: {0}{1}" -f $t.TaskPath, $t.TaskName)
    $rbLines += "Enable-ScheduledTask -TaskName '$($t.TaskName)' -TaskPath '$($t.TaskPath)'"
}

H '11. APPLY - registry lockdown'
function SetV($path,$name,$val,$type) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name $name -Value $val -Type $type
    Write-Host ("  {0}\{1} = {2}" -f $path,$name,$val)
}
SetV 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 DWord
SetV 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 0 DWord
SetV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 DWord
SetV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' 0 DWord
SetV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AudioCaptureEnabled' 0 DWord
SetV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'CursorCaptureEnabled' 0 DWord
SetV 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0 DWord
SetV 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0 DWord
SetV 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0 DWord
SetV 'HKCU:\Software\Microsoft\GameBar' 'GamepadNexusChordEnabled' 0 DWord
SetV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 DWord
# Also disable Game Mode entirely (it is part of the same Xbox gaming stack and is a
# known overlay/graphics-behaviour nuisance)
SetV 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 0 DWord

H '12. WRITE ROLLBACK'
$rbLines += ""
$rbLines += "Write-Host 'Rollback complete. Reboot recommended.'"
$rbLines | Set-Content $rb -Encoding UTF8
Write-Host "  rollback -> $rb"

H '13. VERIFY'
$stillPkg = Get-AppxPackage -AllUsers Microsoft.XboxGamingOverlay
$pkgState = 'REMOVED'
if ($stillPkg) { $pkgState = 'PRESENT' }
Write-Host ('  XboxGamingOverlay pkg : ' + $pkgState)
Write-Host ('  GameBar* files left   : ' + ((Get-ChildItem 'C:\Windows\System32' -Filter 'GameBar*' -File -EA SilentlyContinue | Measure-Object).Count))
Write-Host ('  GameBar processes     : ' + ((Get-Process GameBar,GameBarFTServer,GameBarPresenceWriter,XboxGameBarWidgets -EA SilentlyContinue | Measure-Object).Count))
Get-Service XblGameSave,XboxGipSvc,XboxNetApiSvc,XblAuthManager,GameInputRedistService,GameInputSvc -EA SilentlyContinue | Select-Object Name,Status,StartType | Format-Table -AutoSize | Out-String -Width 120 | Write-Host
