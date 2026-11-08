Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class HotkeyTest {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
"@ -ErrorAction SilentlyContinue

$success = [HotkeyTest]::RegisterHotKey([IntPtr]::Zero, 9999, 0x0001, 0x52)
$err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
if ($success) {
    [HotkeyTest]::UnregisterHotKey([IntPtr]::Zero, 9999) | Out-Null
    Write-Output "HOTKEY_FREE (Alt+R not registered by overlay)"
} else {
    Write-Output "HOTKEY_HELD (Win32 Error: $err - 1409 ERROR_HOTKEY_ALREADY_REGISTERED)"
}
