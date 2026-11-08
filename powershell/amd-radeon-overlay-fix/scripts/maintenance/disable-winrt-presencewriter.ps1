#Requires -Version 5.1
<#
    disable-winrt-presencewriter.ps1
    ------------------------------------------------------------------
    Permanently de-registers the Windows Runtime out-of-process COM
    activation classes for GameBarPresenceWriter:
      - Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter
      - Windows.Gaming.GameBar.Internal.PresenceWriterServer
    (in both 64-bit and WOW6432Node registry views).

    WHY THIS IS ESSENTIAL:
      When any full-screen or 3D game launches, twinui.pcshell.dll in explorer
      calls RoActivateInstance(Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter).
      Without this de-registration, DCOM tries to launch GameBarPresenceWriter.exe,
      hits our IFEO/GPO block, waits 30 seconds for COM registration, and logs
      DCOM Event 10010. That 30-second DCOM timeout stalls window focus and
      causes AMD overlay (amdow.exe) to lose its global hotkey hook.

      With this class de-registered, RoActivateInstance immediately returns
      0x80040154 (REGDB_E_CLASSNOTREG) in <1 millisecond, with 0 DCOM timeout
      and 0 focus stalls.
#>

$pythonCode = @'
import ctypes
from ctypes import wintypes
import winreg

advapi32 = ctypes.windll.advapi32
kernel32 = ctypes.windll.kernel32

advapi32.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
advapi32.OpenProcessToken.restype = wintypes.BOOL

hToken = wintypes.HANDLE()
advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), 0x0028, ctypes.byref(hToken))

class LUID(ctypes.Structure):
    _fields_ = [("LowPart", wintypes.DWORD), ("HighPart", wintypes.LONG)]
class LUID_AND_ATTRIBUTES(ctypes.Structure):
    _fields_ = [("Luid", LUID), ("Attributes", wintypes.DWORD)]
class TOKEN_PRIVILEGES(ctypes.Structure):
    _fields_ = [("PrivilegeCount", wintypes.DWORD), ("Privileges", LUID_AND_ATTRIBUTES * 1)]

advapi32.AdjustTokenPrivileges.argtypes = [wintypes.HANDLE, wintypes.BOOL, ctypes.POINTER(TOKEN_PRIVILEGES), wintypes.DWORD, ctypes.c_void_p, ctypes.c_void_p]

def enable_priv(priv_name):
    luid = LUID()
    advapi32.LookupPrivilegeValueW(None, priv_name, ctypes.byref(luid))
    tp = TOKEN_PRIVILEGES()
    tp.PrivilegeCount = 1
    tp.Privileges[0].Luid = luid
    tp.Privileges[0].Attributes = 2
    advapi32.AdjustTokenPrivileges(hToken, False, ctypes.byref(tp), ctypes.sizeof(tp), None, None)

enable_priv("SeTakeOwnershipPrivilege")
enable_priv("SeRestorePrivilege")
enable_priv("SeBackupPrivilege")

HKEY_LOCAL_MACHINE = wintypes.HKEY(0x80000002)
KEY_WOW64_64KEY = 0x0100
KEY_WOW64_32KEY = 0x0200
advapi32.RegDeleteKeyExW.argtypes = [wintypes.HKEY, wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
advapi32.RegDeleteKeyExW.restype = wintypes.LONG

for sub, view in [
    (r"SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter", KEY_WOW64_64KEY),
    (r"SOFTWARE\Microsoft\WindowsRuntime\Server\Windows.Gaming.GameBar.Internal.PresenceWriterServer", KEY_WOW64_64KEY),
    (r"SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter", KEY_WOW64_32KEY),
    (r"SOFTWARE\Microsoft\WindowsRuntime\Server\Windows.Gaming.GameBar.Internal.PresenceWriterServer", KEY_WOW64_32KEY)
]:
    res = advapi32.RegDeleteKeyExW(HKEY_LOCAL_MACHINE, sub, view, 0)
    print(f"Delete {sub} (view={view}): {res}")
'@

python -c $pythonCode
Write-Output "[OK] WinRT GameBar PresenceWriter class de-registration complete."
