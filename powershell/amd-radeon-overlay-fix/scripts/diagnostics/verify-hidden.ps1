# verify-hidden.ps1 - (A) prove wscript/SW_HIDE spawns NO visible console
#                     (B) hunt for visible console windows caused by AMD Software
$ErrorActionPreference = 'SilentlyContinue'

$cs = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class WV {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetClassNameW")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetWindowTextW")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static List<string> VisibleConsoles() {
    var res = new List<string>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      string cls = c.ToString();
      if (cls.IndexOf("Console", StringComparison.OrdinalIgnoreCase) >= 0
       || cls.IndexOf("CASCADIA", StringComparison.OrdinalIgnoreCase) >= 0) {
        var t = new StringBuilder(256); GetWindowText(h, t, 256);
        uint pid; GetWindowThreadProcessId(h, out pid);
        res.Add(cls + " | pid=" + pid + " | title='" + t.ToString() + "'");
      }
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@
Add-Type -TypeDefinition $cs -ErrorAction SilentlyContinue

Write-Host "########## A. Does wscript + SW_HIDE show a console? ##########"
# a sleeper so we have time to catch any window
Set-Content 'C:\Users\Avisek\AppData\Local\Temp\sleeper.ps1' -Value 'Start-Sleep -Seconds 8' -Encoding UTF8
& wscript.exe 'C:\Users\Avisek\run-hidden.vbs' 'C:\Users\Avisek\AppData\Local\Temp\sleeper.ps1'
Start-Sleep -Milliseconds 1500
$hitsA = @()
for ($i = 0; $i -lt 25; $i++) {
    $hitsA += [WV]::VisibleConsoles()
    Start-Sleep -Milliseconds 200
}
$hitsA = $hitsA | Sort-Object -Unique
if ($hitsA) {
    Write-Host "  VISIBLE console window(s) detected -> SW_HIDE did NOT work:" -ForegroundColor Red
    $hitsA | ForEach-Object { Write-Host ("    " + $_) }
} else {
    Write-Host "  no visible console window during 5s of sampling -> SW_HIDE works" -ForegroundColor Green
}
Start-Sleep -Seconds 6

Write-Host ""
Write-Host "########## B. Watching 40s for visible console windows (AMD popups) ##########"
Write-Host "  (play a game / just wait - counting sightings, 200ms sampling)"
$seen = @{}
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt 40) {
    foreach ($w in [WV]::VisibleConsoles()) {
        if (-not $seen.ContainsKey($w)) {
            $seen[$w] = (Get-Date).ToString('HH:mm:ss')
            $pid = 0
            if ($w -match 'pid=(\d+)') { $pid = [int]$matches[1] }
            $pn = (Get-Process -Id $pid -ErrorAction SilentlyContinue).ProcessName
            $pp = (Get-CimInstance Win32_Process -Filter "ProcessId=$pid" -ErrorAction SilentlyContinue).ParentProcessId
            $ppn = (Get-Process -Id $pp -ErrorAction SilentlyContinue).ProcessName
            Write-Host ("    {0}  {1}  (owner={2}, parent={3})" -f (Get-Date -Format 'HH:mm:ss'), $w, $pn, $ppn) -ForegroundColor Yellow
        }
    }
    Start-Sleep -Milliseconds 200
}
if (-not $seen.Count) { Write-Host "    no visible console windows in this 40s window" }
