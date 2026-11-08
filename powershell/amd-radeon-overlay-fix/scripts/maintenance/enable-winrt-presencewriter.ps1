#Requires -Version 5.1
<#
    enable-winrt-presencewriter.ps1
    ------------------------------------------------------------------
    Rollback utility: restores the default Windows Runtime out-of-process
    COM activation classes for GameBarPresenceWriter from backup.
#>

$backupJson = "C:\Custom User\Nexus\powershell\amd-radeon-overlay-fix\evidence\winrt-presencewriter-backup.json"
if (-not (Test-Path $backupJson)) {
    Write-Error "Backup file not found at $backupJson"
    return
}

$pythonCode = @"
import winreg, json

with open(r'$backupJson', 'r') as f:
    backup = json.load(f)

for path, vals in backup.items():
    with winreg.CreateKey(winreg.HKEY_LOCAL_MACHINE, path) as k:
        for val_name, d in vals.items():
            winreg.SetValueEx(k, val_name, 0, d['type'], d['val'])
        print(f'Restored {path}')
"@

python -c $pythonCode
Write-Output "[OK] WinRT GameBar PresenceWriter class restoration complete."
