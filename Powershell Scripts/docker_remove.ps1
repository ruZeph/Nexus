# 1. Stop any potentially lingering Docker services or processes
Write-Host "Stopping Docker services and processes..." -ForegroundColor Cyan
Stop-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
Stop-Process -Name "Docker Desktop" -Force -ErrorAction SilentlyContinue

# 2. Targeted deletion of Core Docker Installation & Staging paths
$TargetPaths = @(
    "C:\Program Files\Docker",
    "$env:PROGRAMDATA\DockerDesktop",
    "$env:APPDATA\Docker",
    "$env:LOCALAPPDATA\Docker",
    "$env:LOCALAPPDATA\DockerDesktopInstallers"
)

Write-Host "Purging Docker directories..." -ForegroundColor Cyan
foreach ($Path in $TargetPaths) {
    if (Test-Path $Path) {
        Write-Host "Removing: $Path" -ForegroundColor Yellow
        # Fixed the typo here: changed '-Recurlet' to just '-Recurse -Force'
        Remove-Item -Path $Path -Force -Recurse -ErrorAction SilentlyContinue
    }
}

# 3. Remove Windows Service Entry if left over
Write-Host "Cleaning up Windows registry service entries..." -ForegroundColor Cyan
if (Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue) {
    sc.exe delete com.docker.service
}

Write-Host "Cleanup complete! Please reboot your machine before reinstalling." -ForegroundColor Green
