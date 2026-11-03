# event-capture.ps1 - event-based (WMI) capture of EVERY process creation for 90s
$ErrorActionPreference = 'SilentlyContinue'

$src = @"
using System; using System.Runtime.InteropServices;
public class EC { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); }
"@
Add-Type -TypeDefinition $src -ErrorAction SilentlyContinue

Write-Host "registering Win32_ProcessStartTrace ..." -ForegroundColor Cyan
$q = "SELECT * FROM Win32_ProcessStartTrace"
Register-CimIndicationEvent -Query $q -SourceIdentifier 'ECProc' -ErrorAction Stop | Out-Null
Write-Host "capturing 90s (event-based - catches even 1ms processes)..." -ForegroundColor Cyan

$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt 90) {
    Start-Sleep -Seconds 2
}

$evts = Get-Event -SourceIdentifier 'ECProc' -ErrorAction SilentlyContinue
Unregister-Event -SourceIdentifier 'ECProc' -ErrorAction SilentlyContinue
Remove-Event -SourceIdentifier 'ECProc' -ErrorAction SilentlyContinue

$rows = foreach ($e in $evts) {
    $pn = $e.SourceEventArgs.NewEvent.ProcessName
    $pid2 = $e.SourceEventArgs.NewEvent.ProcessID
    $ppid = $e.SourceEventArgs.NewEvent.ParentProcessID
    $par = (Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction SilentlyContinue).Name
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$pid2" -ErrorAction SilentlyContinue).CommandLine
    [PSCustomObject]@{ T=$e.TimeGenerated.ToString('HH:mm:ss.fff'); Name=$pn; Pid=$pid2; PPid=$ppid; Par=$par; Cmd=[string]$cmd }
}

Write-Host ""
Write-Host ("TOTAL process creations in 90s: " + $rows.Count)
Write-Host ""
Write-Host "===== frequency by name ====="
$rows | Group-Object Name | Sort-Object Count -Descending | Select-Object -First 25 | ForEach-Object {
    Write-Host ("  {0,-30} {1,4}" -f $_.Name, $_.Count)
}
Write-Host ""
Write-Host "===== CONSOLE-CAPABLE (can flash a window) with parent ====="
$rows | Where-Object { $_.Name -match 'console|powershell|pwsh|cmd|clinfo|wscript|cscript|bash|terminal|wsl|conhost|WmiPrvSE|taskhostw|OpenConsole' } |
  Group-Object Name,Par | Sort-Object Count -Descending | ForEach-Object { Write-Host ("  {0,-46} {1,4}" -f $_.Name, $_.Count) }
Write-Host ""
Write-Host "===== chronological console-capable ====="
$rows | Where-Object { $_.Name -match 'console|powershell|pwsh|cmd|clinfo|wscript|cscript|terminal|OpenConsole' } |
  ForEach-Object { Write-Host ("  {0}  {1,-14} parent={2,-18} {3}" -f $_.T,$_.Name,$_.Par, ($_.Cmd -replace '\s+',' ').Substring(0,[Math]::Min(100,($_.Cmd -replace '\s+',' ').Length))) }
