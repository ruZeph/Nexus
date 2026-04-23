param(
    [ValidateSet('monitor')]
    [string]$Mode = 'monitor',
    [switch]$TaskScheduler,
    [switch]$Silent,
    [switch]$Interactive,
    [switch]$PreviewOnly,
    [switch]$TestMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-LauncherStatusLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$WriteFailure
    )

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$stamp] [LAUNCHER] $Message"
    $targetPath = Join-Path $LogDir $(if ($WriteFailure) { 'manager-error.log' } else { 'manager.log' })
    Add-Content -LiteralPath $targetPath -Value $entry -Encoding UTF8
}

function Remove-OldLauncherLogs {
    param(
        [Parameter(Mandatory = $true)][string]$LauncherLogDir,
        [int]$KeepCount = 10
    )

    if (-not (Test-Path -LiteralPath $LauncherLogDir)) {
        return
    }

    $logFiles = @(Get-ChildItem -LiteralPath $LauncherLogDir -Filter 'detached-start-*.log' -File | Sort-Object LastWriteTime -Descending)
    if ($logFiles.Count -le $KeepCount) {
        return
    }

    foreach ($stale in $logFiles[$KeepCount..($logFiles.Count - 1)]) {
        Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-PowerShellArgument {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "''"
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function Read-Choice {
    param(
        [string]$Prompt,
        [string[]]$Allowed,
        [string]$Default
    )

    while ($true) {
        $value = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $Default
        }

        $normalized = $value.Trim().ToLowerInvariant()
        if ($Allowed -contains $normalized) {
            return $normalized
        }

        Write-Warn "Invalid value '$value'. Allowed: $($Allowed -join ', ')"
    }
}

function Start-ScheduledMonitorProcess {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][bool]$RunInTestMode,
        [Parameter(Mandatory = $true)][string]$StartupStdOutPath,
        [Parameter(Mandatory = $true)][string]$StartupStdErrPath
    )

    $runnerPathToken = ConvertTo-PowerShellArgument -Value $RunnerPath
    $commandText = "& $runnerPathToken"
    if ($RunInTestMode) {
        $commandText += ' -TestMode'
    }

    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $commandText)
    return Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -WindowStyle Hidden -PassThru -RedirectStandardOutput $StartupStdOutPath -RedirectStandardError $StartupStdErrPath
}

function Start-TaskSchedulerWindow {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [switch]$RunInTestMode
    )

    $startStamp = Get-Date -Format 'yyyy-MM-dd ddd HH:mm:ss'
    $lines = @(
        "[STEP] Backrest live backup monitor started at $startStamp",
        "[INFO] Logs: $LogDir",
        '[INFO] This window is only a notification. Close it anytime; the monitor keeps running.',
        "[INFO] Runner: $RunnerPath",
        "[INFO] Mode: monitor"
    )

    if ($RunInTestMode) {
        $lines += '[INFO] Test mode: enabled'
    }

    $encodedLines = @($lines | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
    $notificationScript = @"
`$Host.UI.RawUI.WindowTitle = 'Backrest Live Backup Monitor'
`$items = @($encodedLines)
foreach (`$item in `$items) {
    Write-Host `$item -ForegroundColor Cyan
}
Write-Host ''
Write-Host 'Press Enter to close this notification window.' -ForegroundColor Gray
[void](Read-Host)
"@

    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-Command', $notificationScript) | Out-Null
}

try {
    $runnerPath = Join-Path $PSScriptRoot 'Start-LiveBackup.ps1'
    if (-not (Test-Path -LiteralPath $runnerPath)) {
        throw "Runner script not found: $runnerPath"
    }

    if ($Interactive) {
        $taskText = Read-Choice -Prompt 'Launch detached for Task Scheduler (yes|no)' -Allowed @('yes', 'no') -Default ($(if ($TaskScheduler) { 'yes' } else { 'no' }))
        $TaskScheduler = ($taskText -eq 'yes')

        $silentText = Read-Choice -Prompt 'Silent console mode (yes|no)' -Allowed @('yes', 'no') -Default ($(if ($Silent) { 'yes' } else { 'no' }))
        $Silent = ($silentText -eq 'yes')

        $testText = Read-Choice -Prompt 'Test mode (yes|no)' -Allowed @('yes', 'no') -Default ($(if ($TestMode) { 'yes' } else { 'no' }))
        $TestMode = ($testText -eq 'yes')
    }

    Write-Info "Runner: $runnerPath"
    Write-Info "Mode: $Mode"
    Write-Info "TaskScheduler: $TaskScheduler"
    Write-Info "TestMode: $TestMode"

    if ($TaskScheduler) {
        $logDir = Join-Path $PSScriptRoot 'logs'
        $launcherLogDir = Join-Path $logDir 'launcher'
        $launcherStartDir = Join-Path $launcherLogDir 'start'
        New-Item -ItemType Directory -Force -Path $launcherStartDir | Out-Null

        $launchStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $startupStdOutPath = Join-Path $launcherStartDir ("detached-start-$launchStamp-stdout.log")
        $startupStdErrPath = Join-Path $launcherStartDir ("detached-start-$launchStamp-stderr.log")
        Remove-OldLauncherLogs -LauncherLogDir $launcherStartDir -KeepCount 10

        Write-LauncherStatusLog -LogDir $logDir -Message "Detached monitor launch requested mode=$Mode runner=$runnerPath testmode=$TestMode"
        Write-LauncherStatusLog -LogDir $logDir -Message "Launcher stdout log file: $startupStdOutPath"
        Write-LauncherStatusLog -LogDir $logDir -Message "Launcher stderr log file: $startupStdErrPath"

        if (-not $Silent) {
            Write-Info "Launcher stdout log file: $startupStdOutPath"
            Write-Info "Launcher stderr log file: $startupStdErrPath"
        }

        if ($PreviewOnly) {
            Write-Info 'PreviewOnly enabled; detached launch not executed.'
            exit 0
        }

        try {
            $runnerProcess = Start-ScheduledMonitorProcess -RunnerPath $runnerPath -RunInTestMode:$TestMode -StartupStdOutPath $startupStdOutPath -StartupStdErrPath $startupStdErrPath
            $launchPid = if ($null -eq $runnerProcess) { 'unknown' } else { [string]$runnerProcess.Id }
            $showSchedulerWindow = $false

            Write-LauncherStatusLog -LogDir $logDir -Message "Detached monitor process started pid=$launchPid mode=$Mode"

            if ($null -ne $runnerProcess) {
                Start-Sleep -Milliseconds 2600
                $stillRunning = Get-Process -Id $runnerProcess.Id -ErrorAction SilentlyContinue
                if ($null -eq $stillRunning) {
                    $exitCode = 'unknown'
                    try {
                        $runnerProcess.WaitForExit(2000) | Out-Null
                        $exitCode = [string]$runnerProcess.ExitCode
                    }
                    catch {
                    }

                    $stderrSnippet = if (Test-Path -LiteralPath $startupStdErrPath) { (Get-Content -LiteralPath $startupStdErrPath -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
                    $stdoutSnippet = if (Test-Path -LiteralPath $startupStdOutPath) { (Get-Content -LiteralPath $startupStdOutPath -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }

                    $detailMessage = "Detached monitor exited early pid=$launchPid mode=$Mode exitcode=$exitCode"
                    if (-not [string]::IsNullOrWhiteSpace($stderrSnippet)) {
                        $detailMessage += " | stderr=$(($stderrSnippet -replace '[\r\n]+', ' '))"
                    }
                    if (-not [string]::IsNullOrWhiteSpace($stdoutSnippet)) {
                        $detailMessage += " | stdout=$(($stdoutSnippet -replace '[\r\n]+', ' '))"
                    }

                    $isDuplicateInstanceExit = $detailMessage -match 'Another instance is already running'
                    if ($exitCode -eq '0' -or $isDuplicateInstanceExit) {
                        Write-LauncherStatusLog -LogDir $logDir -Message "$detailMessage | note=monitor exited normally (often already-running instance)."
                    }
                    else {
                        Write-LauncherStatusLog -LogDir $logDir -Message $detailMessage -WriteFailure
                    }
                }
                else {
                    Write-LauncherStatusLog -LogDir $logDir -Message "Detached monitor confirmed alive pid=$launchPid mode=$Mode"
                    $showSchedulerWindow = $true
                }
            }

            if ($showSchedulerWindow -and -not $Silent) {
                Start-TaskSchedulerWindow -RunnerPath $runnerPath -LogDir $logDir -RunInTestMode:$TestMode
            }
        }
        catch {
            Write-LauncherStatusLog -LogDir $logDir -Message "Detached monitor process failed to start mode=$Mode error=$($_.Exception.Message)" -WriteFailure
            throw
        }

        exit 0
    }

    if ($PreviewOnly) {
        Write-Info 'PreviewOnly enabled; monitor not executed.'
        exit 0
    }

    & $runnerPath -TestMode:$TestMode
    exit 0
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
