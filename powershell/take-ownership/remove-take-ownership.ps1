# remove-take-ownership.ps1 - unregisters the "Take ownership" right-click entry.

$keys = @(
    'HKCU:\Software\Classes\*\shell\TakeOwnership',
    'HKCU:\Software\Classes\Directory\shell\TakeOwnership',
    'HKCU:\Software\Classes\Drive\shell\TakeOwnership',
    'HKCU:\Software\Classes\Directory\Background\shell\TakeOwnership'
)

foreach ($k in $keys) {
    if (Test-Path $k) {
        Remove-Item -Path $k -Recurse -Force
        Write-Output ('removed: ' + $k)
    }
    else {
        Write-Output ('not present: ' + $k)
    }
}
