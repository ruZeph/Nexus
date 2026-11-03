# install-take-ownership.ps1 - registers a "Take ownership" right-click entry (per-user, no admin needed).
# Entry appears in Directory Opus and in Explorer. Remove with remove-take-ownership.ps1

$script = Join-Path $PSScriptRoot 'take-ownership.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "Missing helper: $script" }

$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" "%1"' -f $script
$cmdBg = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" "%V"' -f $script

$entries = @(
    @{ Key = 'HKCU:\Software\Classes\*\shell\TakeOwnership';                    Label = 'Take ownership';                Command = $cmd;   Multi = $true },
    @{ Key = 'HKCU:\Software\Classes\Directory\shell\TakeOwnership';            Label = 'Take ownership';                Command = $cmd;   Multi = $true },
    @{ Key = 'HKCU:\Software\Classes\Drive\shell\TakeOwnership';                Label = 'Take ownership';                Command = $cmd;   Multi = $false },
    @{ Key = 'HKCU:\Software\Classes\Directory\Background\shell\TakeOwnership'; Label = 'Take ownership of this folder'; Command = $cmdBg; Multi = $false }
)

foreach ($e in $entries) {
    New-Item -Path $e.Key -Force | Out-Null
    Set-ItemProperty -Path $e.Key -Name '(default)' -Value $e.Label
    Set-ItemProperty -Path $e.Key -Name 'Icon' -Value '%SystemRoot%\System32\imageres.dll,-78'
    if ($e.Multi) { Set-ItemProperty -Path $e.Key -Name 'MultiSelectModel' -Value 'Player' }
    New-Item -Path ($e.Key + '\command') -Force | Out-Null
    Set-ItemProperty -Path ($e.Key + '\command') -Name '(default)' -Value $e.Command
    Write-Output ('registered: ' + $e.Key + '  ->  ' + $e.Label)
}

Write-Output ''
Write-Output 'Done. Right-click a file or folder -> "Take ownership".'
Write-Output 'Restart Explorer or a Lister if the entry does not appear immediately.'
