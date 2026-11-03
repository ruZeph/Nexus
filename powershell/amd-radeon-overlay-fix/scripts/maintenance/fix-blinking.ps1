# fix-blinking.ps1 - stop the Achievements app's 12-second console flashing
$ErrorActionPreference = 'SilentlyContinue'

Write-Host "########## 1. Disable the Achievements autostart ##########"
$t = Get-ScheduledTask -TaskName 'AchievementsAutoStart' -ErrorAction SilentlyContinue
if ($t) {
    Stop-ScheduledTask -TaskName 'AchievementsAutoStart' -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName 'AchievementsAutoStart' | Out-Null
    Write-Host ("  AchievementsAutoStart : " + (Get-ScheduledTask -TaskName 'AchievementsAutoStart').State)
} else { Write-Host "  (task not found)" }

Write-Host ""
Write-Host "########## 2. Kill every Achievements process (it spawns ~6) ##########"
$procs = Get-Process Achievements -ErrorAction SilentlyContinue
Write-Host ("  running: " + ($procs | Measure-Object).Count)
$procs | ForEach-Object { Write-Host ("    pid=" + $_.Id); Stop-Process -Id $_.Id -Force }
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "########## 3. Also check for the other flasher (CyberPower java -> cmd) ##########"
Get-CimInstance Win32_Process -Filter "Name='java.exe'" | ForEach-Object {
    Write-Host ("  java pid=" + $_.ProcessId + "  " + $_.CommandLine)
}
$ppb = Get-Service | Where-Object { $_.Name -match 'PowerPanel|ppb' }
$ppb | Select-Object Name,DisplayName,Status,StartType | Format-Table -AutoSize | Out-String -Width 140 | Write-Host

Write-Host "########## 4. Verify with event capture (60s) ##########"
$q = "SELECT * FROM Win32_ProcessStartTrace"
Register-CimIndicationEvent -Query $q -SourceIdentifier 'BK' -ErrorAction SilentlyContinue | Out-Null
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt 60) { Start-Sleep -Seconds 1 }
$evts = Get-Event -SourceIdentifier 'BK' -ErrorAction SilentlyContinue
Unregister-Event -SourceIdentifier 'BK' -ErrorAction SilentlyContinue
Remove-Event -SourceIdentifier 'BK' -ErrorAction SilentlyContinue

$all = foreach ($e in $evts) {
    $n = $e.SourceEventArgs.NewEvent.ProcessName
    $ppid = $e.SourceEventArgs.NewEvent.ParentProcessID
    [PSCustomObject]@{ N=$n; Par=(Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction SilentlyContinue).Name }
}
Write-Host ("  process creations in 60s: " + ($all | Measure-Object).Count)
Write-Host "  --- all of them ---"
$all | Group-Object N,Par | Sort-Object Count -Descending | ForEach-Object {
    $mark = ''
    if ($_.Name -match 'fastlist|conhost|cmd') { $mark = '   <-- console flash' }
    Write-Host ("    {0,-46} {1,4}{2}" -f $_.Name, $_.Count, $mark)
}
$flashes = ($all | Where-Object { $_.N -match 'fastlist|conhost|cmd' } | Measure-Object).Count
Write-Host ""
if ($flashes -eq 0) { Write-Host "  => NO console-flash processes in 60s. Blinking should be gone." -ForegroundColor Green }
else { Write-Host ("  => still " + $flashes + " console-flash process(es) in 60s") -ForegroundColor Yellow }
