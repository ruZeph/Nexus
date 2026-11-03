# remove-gamebar.ps1 - definitively eliminate Xbox Game Bar (reversible via Store)
$ErrorActionPreference = 'SilentlyContinue'

Write-Host "########## 1. Remove the Xbox Game Bar package ##########"
$pkg = Get-AppxPackage -AllUsers Microsoft.XboxGamingOverlay
if ($pkg) {
    foreach ($p in $pkg) {
        Write-Host ("  found (user): {0} v{1}" -f $p.PackageFullName, $p.Version)
        Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }
} else { Write-Host "  (not installed for any user)" }

$prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'Microsoft.XboxGamingOverlay' }
if ($prov) {
    Write-Host ("  removing provisioned package so it does not return: " + $prov.PackageName)
    Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction SilentlyContinue | Out-Null
}

Write-Host ""
Write-Host "########## 2. Kill remaining Game Bar processes ##########"
foreach ($n in 'GameBar','GameBarFTServer','GameBarPresenceWriter','XboxGameBarWidgets') {
    $p = Get-Process $n -ErrorAction SilentlyContinue
    if ($p) { Write-Host "  killing $n (pid $($p.Id -join ','))"; $p | Stop-Process -Force }
    else    { Write-Host "  $n not running" }
}

Write-Host ""
Write-Host "########## 3. Verify removal ##########"
$still = Get-AppxPackage -AllUsers Microsoft.XboxGamingOverlay
if ($still) { Write-Host ("  STILL PRESENT: " + $still.PackageFullName) -ForegroundColor Yellow }
else        { Write-Host "  Xbox Game Bar package removed" -ForegroundColor Green }
Write-Host ("  GameBar processes running: " + ((Get-Process GameBar,XboxGameBarWidgets,GameBarFTServer,GameBarPresenceWriter -ErrorAction SilentlyContinue | Measure-Object).Count))
Write-Host ""
Write-Host "  (rollback: install 'Xbox Game Bar' from the Microsoft Store)"
