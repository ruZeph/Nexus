param(
    [switch]$Silent,
    [switch]$TestMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$defaultLauncher = Join-Path (Split-Path -Parent $PSScriptRoot) 'Launch-LiveBackup.ps1'
$launcher = [Environment]::GetEnvironmentVariable('BACKREST_TRIGGER_LAUNCHER', 'User')

if ([string]::IsNullOrWhiteSpace($launcher)) {
    $launcher = $defaultLauncher
}

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher script not found: $launcher"
}

& $launcher -Mode monitor -TaskScheduler -Silent:$Silent -TestMode:$TestMode
