# who-flashes.ps1 - identify processes being created every few seconds (console popups)
$ErrorActionPreference = 'SilentlyContinue'

Write-Host "########## 1. Process births in the last 6 minutes (from the churn log) ##########"
$lf = "$env:LOCALAPPDATA\AMD-Overlay-Watchdog\forensic.log"
$lines = Get-Content $lf
# churn lines look like:  22:41:02.123  NEW   name   pid=.. ppid=..
$births = @()
foreach ($l in $lines) {
    if ($l -match '\sNEW\s+(\S+)\s+pid=(\d+)\s+ppid=(\d+)\s+\(([^)]*)\)') {
        $ts = ($l -split '\s+')[0]
        # only recent (last 6 min of log content)
        $births += [PSCustomObject]@{ T=$ts; Name=$matches[1]; Pid=$matches[2]; PPid=$matches[3]; Parent=$matches[4] }
    }
}
$last = $births | Select-Object -Last 1
Write-Host ("  total birth records in log: " + $births.Count)
$cut = ($births | Select-Object -Last 400)
Write-Host ""
Write-Host "  --- process name frequency (last 400 births) ---"
$cut | Group-Object Name | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
    Write-Host ("    {0,-28} {1,5}" -f $_.Name, $_.Count)
}
Write-Host ""
Write-Host "  --- console-ish processes (conhost/OpenConsole/cmd/powershell/WindowsTerminal/ludusavi) with parents ---"
$cut | Where-Object { $_.Name -match 'conhost|OpenConsole|cmd|powershell|WindowsTerminal|ludusavi|Playnite|pwsh' } |
  Group-Object Name,Parent | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
    Write-Host ("    {0,-50} {1,5}" -f $_.Name, $_.Count)
}

Write-Host ""
Write-Host "########## 2. Scheduled tasks with a SHORT repetition interval (<= 5 min) ##########"
Get-ScheduledTask | ForEach-Object {
    $t = $_
    foreach ($tr in $t.Triggers) {
        $rep = $tr.Repetition
        if ($rep -and $rep.Interval) {
            $iv = $rep.Interval
            # PT1M / PT30S / PT5M
            if ($iv -match '^PT(\d+)([SM])$') {
                $n = [int]$matches[1]; $u = $matches[2]
                $mins = if ($u -eq 'S') { $n / 60.0 } else { $n }
                if ($mins -le 5) {
                    Write-Host ("  {0,-26} every {1}   state={2}" -f $t.TaskName, $iv, $t.State)
                }
            }
        }
    }
}

Write-Host ""
Write-Host "########## 3. Is anything NOT mine spawning repeatedly? ##########"
Write-Host "  my tasks: AMD-Overlay-Watchdog (60s), AMD-Overlay-Relay (on-demand), AMD-Overlay-Forensic (single long-lived process)"
$myProcs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'amd-overlay|AMD-Overlay' }
Write-Host ("  processes matching my tasks right now: " + ($myProcs | Measure-Object).Count)
$myProcs | ForEach-Object { Write-Host ("    pid=" + $_.ProcessId + "  " + $_.Name + "  " + $_.CommandLine.Substring(0,[Math]::Min(110,$_.CommandLine.Length))) }

Write-Host ""
Write-Host "########## 4. Currently running Cua / hermes / agent-ish things ##########"
Get-Process | Where-Object { $_.Path -match 'Cua|hermes|nodejs|uv\\\\python|Programs\\\\uv' } | Select-Object ProcessName,Id,Path,StartTime | Format-Table -AutoSize | Out-String -Width 180 | Write-Host
