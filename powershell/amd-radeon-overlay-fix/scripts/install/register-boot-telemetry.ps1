<#
.SYNOPSIS
    Registers the boot and logon telemetry tasks to comprehensively record system startup.
#>

# $PSScriptRoot is ...\powershell\amd-radeon-overlay-fix\scripts\install
# We need the section root: ...\powershell\amd-radeon-overlay-fix
$sectionRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$vbs = "$sectionRoot\scripts\run-hidden.vbs"
$sysScript = "$sectionRoot\scripts\diagnostics\boot-system-trace.ps1"
$userScript = "$sectionRoot\scripts\diagnostics\boot-user-trace.ps1"

# 1. System Boot Task (Runs at machine startup as SYSTEM)
$taskSysName = "Boot-Telemetry-System"
Unregister-ScheduledTask -TaskName $taskSysName -Confirm:$false -ErrorAction SilentlyContinue

$sysAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sysScript`""
$sysTrigger = New-ScheduledTaskTrigger -AtStartup
$sysPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $taskSysName -Action $sysAction -Trigger $sysTrigger -Principal $sysPrincipal | Out-Null
Write-Output "[OK] Registered $taskSysName -> $sysScript"

# 2. User Logon Task (Runs at user logon as Interactive User)
$taskUserName = "Boot-Telemetry-User"
Unregister-ScheduledTask -TaskName $taskUserName -Confirm:$false -ErrorAction SilentlyContinue

$userAction = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbs`" `"$userScript`""
$userTrigger = New-ScheduledTaskTrigger -AtLogOn
$userPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $taskUserName -Action $userAction -Trigger $userTrigger -Principal $userPrincipal | Out-Null
Write-Output "[OK] Registered $taskUserName -> $vbs $userScript"
