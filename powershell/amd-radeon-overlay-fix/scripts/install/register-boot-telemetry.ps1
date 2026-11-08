<#
.SYNOPSIS
    Registers the boot and logon telemetry tasks to comprehensively record system startup.
#>

$root = Split-Path -Parent $PSScriptRoot
$vbs = "$root\scripts\run-hidden.vbs"
$sysScript = "$root\scripts\diagnostics\boot-system-trace.ps1"
$userScript = "$root\scripts\diagnostics\boot-user-trace.ps1"

# 1. System Boot Task (Runs at machine startup as SYSTEM)
$taskSysName = "Boot-Telemetry-System"
Unregister-ScheduledTask -TaskName $taskSysName -Confirm:$false -ErrorAction SilentlyContinue

$sysAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sysScript`""
$sysTrigger = New-ScheduledTaskTrigger -AtStartup
$sysPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $taskSysName -Action $sysAction -Trigger $sysTrigger -Principal $sysPrincipal | Out-Null
Write-Output "[OK] Registered $taskSysName (Trigger: AtStartup, RunLevel: Highest, User: SYSTEM)"

# 2. User Logon Task (Runs at user logon as Interactive User)
$taskUserName = "Boot-Telemetry-User"
Unregister-ScheduledTask -TaskName $taskUserName -Confirm:$false -ErrorAction SilentlyContinue

$userAction = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbs`" `"$userScript`""
$userTrigger = New-ScheduledTaskTrigger -AtLogOn
$userPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $taskUserName -Action $userAction -Trigger $userTrigger -Principal $userPrincipal | Out-Null
Write-Output "[OK] Registered $taskUserName (Trigger: AtLogOn, RunLevel: Highest, User: $env:USERNAME)"

Write-Output "`nBoth telemetry tasks are primed and ready for your reboot."
