# register-watchdog.ps1 - registers the AMD overlay self-healing logon task
$ErrorActionPreference = 'Stop'

$taskName = 'AMD-Overlay-Watchdog'
$script   = 'C:\Users\Avisek\amd-overlay-watchdog.ps1'
$user     = "$env:USERDOMAIN\$env:USERNAME"

if (-not (Test-Path $script)) { throw "Watchdog script not found: $script" }

# Remove any previous copy so we start clean
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Write-Host "removing existing task '$taskName'"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $script)
# Trigger 1: 90 seconds after THIS user logs on
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$logonTrigger.Delay = 'PT90S'

# Trigger 2: repeat every 3 minutes, because the overlay can also die
# MID-SESSION (observed: launching Cyberpunk 2077 wedged an AMD overlay
# command, RadeonSoftware.exe crashed and the Alt+R registration died with it).
# The probe is ~50ms and exits immediately when healthy, so this is cheap.
# NOTE: [TimeSpan]::MaxValue is REJECTED by the Task Scheduler schema
#   ("Duration: P99999999DT23H59M59S ... out of range").
# 3650 days (10 years) is accepted and is effectively permanent.
$repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

# Must run in the USER'S interactive session:
#   - RegisterHotKey probes are per-session, so a SYSTEM/session-0 task could
#     not see whether Alt+R is held.
#   - RunLevel = Highest is REQUIRED, not optional:
#     AMD's amdow.exe / AMDRSServ.exe / CPUMetricsServer.exe are spawned by
#     AMD's own services and run at HIGH integrity. A Limited watchdog cannot
#     terminate them -- Stop-Process fails silently, the stack is only
#     half-killed and the overlay never returns. (Learned the hard way.)
#     This does NOT make AMD elevated: AMD is relaunched through the separate
#     LIMITED task 'AMD-Overlay-Relay', so RadeonSoftware stays Medium.
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 6)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logonTrigger, $repeatTrigger) `
    -Principal $principal -Settings $settings `
    -Description 'Revives the AMD Radeon overlay (Alt+R) if the logon task race prevents the overlay stack from initialising.' | Out-Null

Write-Host ""
Write-Host "Registered '$taskName':" -ForegroundColor Green
$t = Get-ScheduledTask -TaskName $taskName
$t | Select-Object TaskName, State, @{n='RunAs';e={$_.Principal.UserId}}, @{n='RunLevel';e={$_.Principal.RunLevel}}, @{n='LogonType';e={$_.Principal.LogonType}} | Format-List
Write-Host "  Triggers ($($t.Triggers.Count)):"
foreach ($tr in $t.Triggers) {
    if ($tr.CimClass.CimClassName -match 'Logon') {
        Write-Host ("    - AtLogOn, delay " + $tr.Delay)
    } else {
        $rep = $tr.Repetition
        Write-Host ("    - Repeat every " + $rep.Interval + " for " + $rep.Duration)
    }
}
$t.Actions | ForEach-Object { Write-Host ("  Action : " + $_.Execute + ' ' + $_.Arguments) }
$i = Get-ScheduledTaskInfo -TaskName $taskName
Write-Host ("  NextRunTime : " + $i.NextRunTime)
