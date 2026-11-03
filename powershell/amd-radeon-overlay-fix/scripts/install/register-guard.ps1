# register-guard.ps1
# Installs the long-lived overlay guard and retires the older per-minute tasks.
# Run as Administrator.
$ErrorActionPreference = 'Stop'

# resolve the tool root from this script's location: <tool>\scripts\install\register-guard.ps1
$Repo   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Vbs    = Join-Path $Repo 'scripts\run-hidden.vbs'
$Guard  = Join-Path $Repo 'scripts\overlay-guard.ps1'
$user   = '{0}\{1}' -f $env:COMPUTERNAME, $env:USERNAME

Write-Host "=== 1. sanity ==="
foreach ($f in @($Vbs, $Guard)) {
    if (-not (Test-Path $f)) { throw "missing: $f" }
    Write-Host "  ok  $f"
}

Write-Host ""
Write-Host "=== 2. register AMD-Overlay-Guard (logon, hidden, long-lived) ==="
Unregister-ScheduledTask -TaskName 'AMD-Overlay-Guard' -Confirm:$false -ErrorAction SilentlyContinue
$arg = '"{0}" "{1}"' -f $Vbs, $Guard
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $arg
$trig   = New-ScheduledTaskTrigger -AtLogOn -User $user
$trig.Delay = 'PT20S'
$prin   = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$set    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'AMD-Overlay-Guard' -Action $action -Trigger $trig `
  -Principal $prin -Settings $set `
  -Description 'Long-lived hidden guard for the AMD Radeon overlay (Alt+R). Single process, no console windows.' | Out-Null
$x = Get-ScheduledTask -TaskName 'AMD-Overlay-Guard'
Write-Host ("  {0}  state={1}  runLevel={2}" -f $x.TaskName, $x.State, $x.Principal.RunLevel)
Write-Host ("  action: " + $x.Actions[0].Execute + ' ' + $x.Actions[0].Arguments)

Write-Host ""
Write-Host "=== 3. retire the older overlay tasks (superseded by the guard) ==="
foreach ($n in 'AMD-Overlay-Watchdog','AMD-Overlay-Forensic') {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if ($t) {
        Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        Disable-ScheduledTask -TaskName $n | Out-Null
        Write-Host ("  {0,-24} -> Disabled" -f $n)
    }
}
# kill any survivors of the old tasks so only the guard probes Alt+R
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'amd-overlay-(watchdog|forensic)' -and $_.ProcessId -ne $PID } |
  ForEach-Object { Write-Host ("  killing old helper pid " + $_.ProcessId); Stop-Process -Id $_.ProcessId -Force }

Write-Host ""
Write-Host "=== 4. stop the CyberPower PowerPanel Watchdog console flash ==="
$ppb = Get-Service ppbwd -ErrorAction SilentlyContinue
if ($ppb) {
    Stop-Service ppbwd -Force -ErrorAction SilentlyContinue
    Set-Service  ppbwd -StartupType Disabled
    $ppb = Get-Service ppbwd
    Write-Host ("  ppbwd (PowerPanel Business Service Watchdog) : " + $ppb.Status + " / " + $ppb.StartType)
    Write-Host "  (rollback: Set-Service ppbwd -StartupType Automatic; Start-Service ppbwd)"
} else { Write-Host "  ppbwd service not present" }

Write-Host ""
Write-Host "=== 5. start the guard now ==="
Start-ScheduledTask -TaskName 'AMD-Overlay-Guard'
Start-Sleep -Seconds 8
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'overlay-guard' } |
  ForEach-Object { Write-Host ("  guard running pid " + $_.ProcessId) }
Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" |
  Where-Object { $_.CommandLine -match 'run-hidden' } |
  ForEach-Object { Write-Host ("  (launcher wscript pid " + $_.ProcessId + " - exits immediately)") }

Write-Host ""
Write-Host "=== 6. FINAL TASK STATE ==="
foreach ($n in 'AMD-Overlay-Guard','AMD-Overlay-Relay','AMD-Overlay-Watchdog','AMD-Overlay-Forensic','AchievementsAutoStart','CapFrameX') {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if ($t) { Write-Host ("  {0,-24} {1,-9} action={2}" -f $t.TaskName, $t.State, (Split-Path $t.Actions[0].Execute -Leaf)) }
}
