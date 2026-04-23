param(
    [ValidateSet('run', 'dryrun', 'monitor')]
    [string]$Mode = 'monitor',
    [int]$IdleTimeSeconds = 60,
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcher = [Environment]::GetEnvironmentVariable('RCLONE_SYNC_LAUNCHER', 'User')
$configPath = [Environment]::GetEnvironmentVariable('RCLONE_SYNC_CONFIG_PATH', 'User')

if ([string]::IsNullOrWhiteSpace($launcher)) {
    throw 'Missing RCLONE_SYNC_LAUNCHER user environment variable.'
}

if ([string]::IsNullOrWhiteSpace($configPath)) {
    throw 'Missing RCLONE_SYNC_CONFIG_PATH user environment variable.'
}

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher script not found: $launcher"
}

if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Config file not found: $configPath"
}

& $launcher -ConfigPath $configPath -Mode $Mode -TaskScheduler -Silent:$Silent -IdleTimeSeconds $IdleTimeSeconds