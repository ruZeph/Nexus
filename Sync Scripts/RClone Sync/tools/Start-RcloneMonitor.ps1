param(
    [ValidateSet('run', 'dryrun', 'monitor')]
    [string]$Mode = 'monitor',
    [int]$IdleTimeSeconds = 60,
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

function Show-ErrorDialog {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Nexus Sync — Startup Error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

$launcher = [Environment]::GetEnvironmentVariable('RCLONE_SYNC_LAUNCHER', 'User')
$configPath = [Environment]::GetEnvironmentVariable('RCLONE_SYNC_CONFIG_PATH', 'User')

if ([string]::IsNullOrWhiteSpace($launcher)) {
    $msg = 'Missing RCLONE_SYNC_LAUNCHER user environment variable.'
    Show-ErrorDialog $msg
    throw $msg
}

if ([string]::IsNullOrWhiteSpace($configPath)) {
    $msg = 'Missing RCLONE_SYNC_CONFIG_PATH user environment variable.'
    Show-ErrorDialog $msg
    throw $msg
}

if (-not (Test-Path -LiteralPath $launcher)) {
    $msg = "Launcher script not found:`n$launcher"
    Show-ErrorDialog $msg
    throw $msg
}

if (-not (Test-Path -LiteralPath $configPath)) {
    $msg = "Config file not found:`n$configPath"
    Show-ErrorDialog $msg
    throw $msg
}

& $launcher -ConfigPath $configPath -Mode $Mode -TaskScheduler -Silent:$Silent -IdleTimeSeconds $IdleTimeSeconds