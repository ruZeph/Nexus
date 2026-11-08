$events = Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddMinutes(-30)} -ErrorAction SilentlyContinue | 
  Where-Object { $_.Level -le 3 } | 
  Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message

if ($events) {
    Write-Output "=== APPLICATION WARNINGS/ERRORS (LAST 30 MIN) ==="
    $events | Format-Table -Wrap
} else {
    Write-Output "=== APPLICATION WARNINGS/ERRORS (LAST 30 MIN): NONE ==="
}

$crashes = Get-ChildItem -Path "C:\Users\Avisek\AppData\Local\CrashDumps" -Filter "*.dmp" | 
  Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) } | 
  Select-Object Name, LastWriteTime, Length

if ($crashes) {
    Write-Output "=== NEW CRASH DUMPS (LAST 30 MIN) ==="
    $crashes | Format-Table
} else {
    Write-Output "=== NEW CRASH DUMPS (LAST 30 MIN): 0 (NONE) ==="
}

$ubiCrashes = Get-ChildItem -Path "C:\Users\Avisek\AppData\Local\Ubisoft" -Recurse -Filter "*crash*" -ErrorAction SilentlyContinue | 
  Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) } | 
  Select-Object FullName, LastWriteTime, Length

if ($ubiCrashes) {
    Write-Output "=== UBISOFT CRASH ARTIFACTS (LAST 30 MIN) ==="
    $ubiCrashes | Format-Table
} else {
    Write-Output "=== UBISOFT CRASH ARTIFACTS (LAST 30 MIN): 0 (NONE) ==="
}

Write-Output "=== AMD OVERLAY CURRENT STATUS ==="
& 'C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix\scripts\diagnostics\test-hotkey.ps1'
