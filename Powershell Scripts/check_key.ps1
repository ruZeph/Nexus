$suspects = @(
    "Rainmeter",
    "AutoHotkeyUX",
    "TwinkleTray",
    "HDSentinel",
    "MailClient",
    "HotKeysList",
    "avpui"
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class HotkeyTest {
    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
"@

function Test-HotKey {
    $free = [HotkeyTest]::RegisterHotKey([IntPtr]::Zero, 9999, 0x0001, 0x20)
    if ($free) { [HotkeyTest]::UnregisterHotKey([IntPtr]::Zero, 9999) }
    return $free
}

Write-Host "`n=== Alt+Space Hotkey Hunter ===" -ForegroundColor Cyan

foreach ($name in $suspects) {
    $proc = Get-Process -Name $name -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Host "[$name] Not running — skip" -ForegroundColor DarkGray
        continue
    }

    Write-Host "`n[KILLING] $name (PID $($proc.Id))..." -ForegroundColor Yellow
    Stop-Process -Name $name -Force
    Start-Sleep -Milliseconds 800

    if (Test-HotKey) {
        Write-Host "[FOUND] $name was holding Alt+Space!" -ForegroundColor Green
        break
    } else {
        Write-Host "[NOT IT] Alt+Space still taken after killing $name" -ForegroundColor Red
    }
}

if (-not (Test-HotKey)) {
    Write-Host "`n[UNRESOLVED] Alt+Space still taken — culprit may be a windowless/system process" -ForegroundColor Magenta
}
