# register-relay.ps1 - a LIMITED task whose only job is to launch AMD Software
# at normal (non-elevated) integrity. The elevated watchdog triggers this.
$ErrorActionPreference = 'Stop'
$relay = 'AMD-Overlay-Relay'
$user  = "$env:USERDOMAIN\$env:USERNAME"

if (Get-ScheduledTask -TaskName $relay -ErrorAction SilentlyContinue) {
    Write-Host "removing existing '$relay'"
    Unregister-ScheduledTask -TaskName $relay -Confirm:$false
}

$action  = New-ScheduledTaskAction -Execute 'C:\Program Files\AMD\CNext\CNext\cncmd.exe' `
                                   -Argument 'startwithdelay' `
                                   -WorkingDirectory 'C:\Program Files\AMD\CNext\CNext'
# No trigger: this task is only ever started on demand by the watchdog.
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                          -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)

Register-ScheduledTask -TaskName $relay -Action $action -Principal $principal -Settings $settings `
    -Description 'Launches AMD Software (cncmd startwithdelay) at normal integrity. Triggered on demand by AMD-Overlay-Watchdog.' | Out-Null

$t = Get-ScheduledTask -TaskName $relay
Write-Host "Registered '$relay':" -ForegroundColor Green
$t | Select-Object TaskName, State, @{n='RunAs';e={$_.Principal.UserId}}, @{n='RunLevel';e={$_.Principal.RunLevel}}, @{n='LogonType';e={$_.Principal.LogonType}} | Format-List
$t.Actions | ForEach-Object { Write-Host ("  Action : " + $_.Execute + ' ' + $_.Arguments) }
Write-Host ("  Triggers: " + $t.Triggers.Count + " (on-demand only)")
