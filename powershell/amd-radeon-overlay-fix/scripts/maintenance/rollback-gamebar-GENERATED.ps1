# Rollback for neuter-gamebar-all.ps1 - run as Administrator

Get-AppxPackage Microsoft.XboxGamingOverlay | ForEach-Object { $loc = $_.InstallLocation; Add-AppxPackage -Register (Join-Path $loc 'AppxManifest.xml') -DisableDevelopmentMode -EA SilentlyContinue }
Move-Item -LiteralPath 'C:\Windows\System32\GameBarPresenceWriter.exe.disabled' -Destination 'C:\Windows\System32\GameBarPresenceWriter.exe' -Force
Move-Item -LiteralPath 'C:\Windows\System32\GameBarPresenceWriter.proxy.dll.disabled' -Destination 'C:\Windows\System32\GameBarPresenceWriter.proxy.dll' -Force
Move-Item -LiteralPath 'C:\Windows\SysWOW64\GameBarPresenceWriter.exe.disabled' -Destination 'C:\Windows\SysWOW64\GameBarPresenceWriter.exe' -Force
Move-Item -LiteralPath 'C:\Windows\SysWOW64\GameBarPresenceWriter.proxy.dll.disabled' -Destination 'C:\Windows\SysWOW64\GameBarPresenceWriter.proxy.dll' -Force
Set-Service XblGameSave -StartupType Manual
Set-Service XboxGipSvc -StartupType Manual
Set-Service XboxNetApiSvc -StartupType Manual
Set-Service XblAuthManager -StartupType Manual
Set-Service GameInputRedistService -StartupType Auto
Set-Service GameInputSvc -StartupType Manual

Write-Host 'Rollback complete. Reboot recommended.'
