<#
.SYNOPSIS
    Applies permanent immunization against GameBarPresenceWriter and configures AMD logon task delays.
    Survives 'sfc /scannow', DISM, and Windows Cumulative Updates.
#>

# 1. Group Policy: GameDVR
$gpoKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'
if (!(Test-Path $gpoKey)) { New-Item -Path $gpoKey -Force | Out-Null }
Set-ItemProperty -Path $gpoKey -Name 'AllowGameDVR' -Value 0 -Type DWord
Set-ItemProperty -Path $gpoKey -Name 'AllowGameStream' -Value 0 -Type DWord

$cuGpoKey = 'HKCU:\Software\Policies\Microsoft\Windows\GameDVR'
if (!(Test-Path $cuGpoKey)) { New-Item -Path $cuGpoKey -Force | Out-Null }
Set-ItemProperty -Path $cuGpoKey -Name 'AllowGameDVR' -Value 0 -Type DWord
Set-ItemProperty -Path $cuGpoKey -Name 'AllowGameStream' -Value 0 -Type DWord

# 2. Group Policy: DisallowRun
$disallowRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
)
foreach ($root in $disallowRoots) {
    if (!(Test-Path $root)) { New-Item -Path $root -Force | Out-Null }
    Set-ItemProperty -Path $root -Name 'DisallowRun' -Value 1 -Type DWord
    $sub = "$root\DisallowRun"
    if (!(Test-Path $sub)) { New-Item -Path $sub -Force | Out-Null }
    Set-ItemProperty -Path $sub -Name 'GameBarPresenceWriter' -Value 'GameBarPresenceWriter.exe' -Type String
    Set-ItemProperty -Path $sub -Name 'GameBarFTServer' -Value 'GameBarFTServer.exe' -Type String
}

# 3. IFEO: Execution Trap (Intercepts even if sfc /scannow or Windows Update restores files)
$ifeoTargets = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\GameBarPresenceWriter.exe',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\GameBarPresenceWriter.exe',
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\GameBarFTServer.exe',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\GameBarFTServer.exe'
)
foreach ($target in $ifeoTargets) {
    if (!(Test-Path $target)) { New-Item -Path $target -Force | Out-Null }
    Set-ItemProperty -Path $target -Name 'Debugger' -Value 'systray.exe' -Type String
}

# 4. AMD Scheduled Tasks: 15-second logon delay
$tasks = @('StartCN', 'StartDVR')
foreach ($name in $tasks) {
    try {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        $trigger = New-ScheduledTaskTrigger -AtLogOn -RandomDelay (New-TimeSpan -Seconds 0)
        $trigger.Delay = 'PT15S'
        Set-ScheduledTask -TaskName $name -Trigger $trigger | Out-Null
        Write-Output "Configured 15s delay on $name"
    } catch {
        Write-Output "Warning on $name : $_"
    }
}

Write-Output "Permanent immunization applied successfully."
