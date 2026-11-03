# cleanup-logs.ps1 - archive + reset the overlay logs, clear AMD crash dumps
$ErrorActionPreference = 'SilentlyContinue'

$logDir = Join-Path $env:LOCALAPPDATA 'AMD-Overlay-Watchdog'
$arch   = Join-Path $logDir 'archive'
New-Item -ItemType Directory -Path $arch -Force | Out-Null
$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'

Write-Host "########## 1. Archive + reset the active logs ##########"
foreach ($f in 'forensic.log','watchdog.log') {
    $p = Join-Path $logDir $f
    if (Test-Path $p) {
        $sz = (Get-Item $p).Length
        $dest = Join-Path $arch ("{0}_{1}" -f $stamp, $f)
        Move-Item -LiteralPath $p -Destination $dest -Force
        Write-Host ("  {0,-14} {1,10:N0} bytes  ->  archive\{2}" -f $f, $sz, (Split-Path $dest -Leaf))
    }
}
# fresh headers
$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Add-Content (Join-Path $logDir 'forensic.log') -Value ("{0}  ==================== NEW SESSION (logs cleaned) ====================" -f (Get-Date -Format 'HH:mm:ss.fff')) -Encoding UTF8
Add-Content (Join-Path $logDir 'watchdog.log') -Value ("$now  [INFO]  ==================== NEW SESSION (logs cleaned) ====================") -Encoding UTF8
Write-Host "  fresh forensic.log + watchdog.log created"

Write-Host ""
Write-Host "########## 2. Clear AMD crash dumps ##########"
$cd = Join-Path $env:LOCALAPPDATA 'CrashDumps'
if (Test-Path $cd) {
    $dumps = Get-ChildItem $cd -Filter '*.dmp' -File
    $tot = ($dumps | Measure-Object -Property Length -Sum).Sum
    Write-Host ("  found " + $dumps.Count + " dump(s), " + [math]::Round($tot/1MB,1) + " MB")
    $dumps | ForEach-Object { Write-Host ("    " + $_.Name + "  " + [math]::Round($_.Length/1MB,1) + " MB") }
    $dumps | Remove-Item -Force
    Write-Host ("  removed -> reclaimed " + [math]::Round($tot/1MB,1) + " MB")
} else { Write-Host "  (no CrashDumps folder)" }

Write-Host ""
Write-Host "########## 3. Trim old WER AMDADLXServ reports (keep newest 3) ##########"
$werKept = 0; $werDel = 0
foreach ($d in 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive','C:\ProgramData\Microsoft\Windows\WER\ReportQueue') {
    if (-not (Test-Path $d)) { continue }
    $reps = Get-ChildItem $d -Directory | Where-Object { $_.Name -match 'AMDADLXServ' } | Sort-Object LastWriteTime -Descending
    for ($i = 0; $i -lt $reps.Count; $i++) {
        if ($i -lt 3) { $werKept++ }
        else { Remove-Item $reps[$i].FullName -Recurse -Force; $werDel++ }
    }
}
Write-Host ("  kept $werKept, removed $werDel")

Write-Host ""
Write-Host "########## 4. Archive folder size ##########"
$asz = (Get-ChildItem $arch -File | Measure-Object -Property Length -Sum).Sum
Write-Host ("  " + $arch)
Write-Host ("  " + (Get-ChildItem $arch -File | Measure-Object).Count + " archived file(s), " + [math]::Round($asz/1MB,2) + " MB")

Write-Host ""
Write-Host "########## 5. Verify monitor + overlay still fine ##########"
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'amd-overlay-forensic' } | ForEach-Object { Write-Host ("  monitor running, pid " + $_.ProcessId) }
$src = @"
using System; using System.Runtime.InteropServices;
public class CL {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint m, uint vk);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr h, int id);
}
"@
Add-Type -TypeDefinition $src -ErrorAction SilentlyContinue
$ok = [CL]::RegisterHotKey([IntPtr]::Zero, 37080, 0x0001, [int][char]'R')
if ($ok) { [CL]::UnregisterHotKey([IntPtr]::Zero, 37080) | Out-Null; Write-Host "  Alt+R : FREE (overlay dead)" } else { Write-Host "  Alt+R : HELD by AMD (alive)" }
Write-Host ""
Write-Host "  Task states:"
foreach ($n in 'AMD-Overlay-Watchdog','AMD-Overlay-Relay','AMD-Overlay-Forensic','CapFrameX') {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if ($t) { Write-Host ("    {0,-24} {1}" -f $t.TaskName, $t.State) }
}
