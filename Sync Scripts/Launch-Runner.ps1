param(
    [ValidateSet('run', 'dryrun', 'monitor')]
    [string]$Mode = 'run',
    [string]$ConfigPath,
    [string]$JobName,
    [string]$SourceFolder,
    [ValidateRange(5, 3600)]
    [int]$IdleTimeSeconds = 60,
    [ValidateSet('copy', 'sync')]
    [string]$Operation,
    [switch]$FailFast,
    [switch]$Silent,
    [switch]$Interactive,
    [switch]$PreviewOnly,
    [switch]$TaskScheduler
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

function Write-LauncherLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$Message
    )

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $runnerLog = Join-Path $LogDir 'runner.log'
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $runnerLog -Value "[$stamp] $Message"
}

function Write-LauncherErrorLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$Message
    )

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $errorLog = Join-Path $LogDir 'runner-error.log'
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $errorLog -Value "[$stamp] $Message"
}

function Resolve-ConfigPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return (Join-Path $PSScriptRoot 'backup-jobs.json')
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $PSScriptRoot $Path)
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

function Build-RunnerArgs {
    param(
        [string]$SelectedMode,
        [string]$ResolvedConfigPath,
        [string]$SelectedJobName,
        [string]$SelectedSourceFolder,
        [int]$SelectedIdle,
        [string]$SelectedOperation,
        [bool]$SelectedFailFast,
        [bool]$SelectedSilent,
        [bool]$SelectedWaitForNetwork,
        [bool]$SelectedNotifyOnEvents
    )

    $argsList = @('-ConfigPath', $ResolvedConfigPath)

    if ($SelectedMode -eq 'monitor') {
        $argsList += @('-Monitor', '-IdleTimeSeconds', [string]$SelectedIdle)
        if (-not [string]::IsNullOrWhiteSpace($SelectedJobName) -or -not [string]::IsNullOrWhiteSpace($SelectedSourceFolder)) {
            Write-Warn 'JobName/SourceFolder filters are ignored in monitor mode and will not be passed.'
        }
    }
    elseif ($SelectedMode -eq 'dryrun') {
        $argsList += '-DryRun'
        if (-not [string]::IsNullOrWhiteSpace($SelectedJobName)) {
            $argsList += @('-JobName', $SelectedJobName)
        }
        if (-not [string]::IsNullOrWhiteSpace($SelectedSourceFolder)) {
            $argsList += @('-SourceFolder', $SelectedSourceFolder)
        }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($SelectedJobName)) {
            $argsList += @('-JobName', $SelectedJobName)
        }
        if (-not [string]::IsNullOrWhiteSpace($SelectedSourceFolder)) {
            $argsList += @('-SourceFolder', $SelectedSourceFolder)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SelectedOperation)) {
        $argsList += @('-Operation', $SelectedOperation)
    }

    if ($SelectedFailFast) {
        $argsList += '-FailFast'
    }

    if ($SelectedSilent) {
        $argsList += '-Silent'
    }

    if ($SelectedWaitForNetwork) {
        $argsList += '-WaitForNetwork'
    }

    if ($SelectedNotifyOnEvents) {
        $argsList += '-NotifyOnEvents'
    }

    return $argsList
}

function Build-RunnerParameters {
    param(
        [string]$SelectedMode,
        [string]$ResolvedConfigPath,
        [string]$SelectedJobName,
        [string]$SelectedSourceFolder,
        [int]$SelectedIdle,
        [string]$SelectedOperation,
        [bool]$SelectedFailFast,
        [bool]$SelectedSilent,
        [bool]$SelectedWaitForNetwork,
        [bool]$SelectedNotifyOnEvents
    )

    $parameters = @{ ConfigPath = $ResolvedConfigPath }

    if ($SelectedMode -eq 'monitor') {
        $parameters.Monitor = $true
        $parameters.IdleTimeSeconds = $SelectedIdle
    }
    elseif ($SelectedMode -eq 'dryrun') {
        $parameters.DryRun = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($SelectedJobName)) {
        $parameters.JobName = $SelectedJobName
    }

    if (-not [string]::IsNullOrWhiteSpace($SelectedSourceFolder)) {
        $parameters.SourceFolder = $SelectedSourceFolder
    }

    if (-not [string]::IsNullOrWhiteSpace($SelectedOperation)) {
        $parameters.Operation = $SelectedOperation
    }

    if ($SelectedFailFast) {
        $parameters.FailFast = $true
    }

    if ($SelectedSilent) {
        $parameters.Silent = $true
    }

    if ($SelectedWaitForNetwork) {
        $parameters.WaitForNetwork = $true
    }

    if ($SelectedNotifyOnEvents) {
        $parameters.NotifyOnEvents = $true
    }

    return $parameters
}

function ConvertTo-CmdArgument {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return '""'
    }

    return '"' + ($Value -replace '"', '""') + '"'
}

function ConvertTo-PowerShellArgument {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "''"
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function Start-ScheduledRunnerProcess {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][hashtable]$RunnerParams,
        [Parameter(Mandatory = $true)][string]$StartupStdOutPath,
        [Parameter(Mandatory = $true)][string]$StartupStdErrPath
    )

    $paramTokens = @()
    foreach ($key in $RunnerParams.Keys) {
        $value = $RunnerParams[$key]
        if ($value -is [bool]) {
            if ($value) {
                $paramTokens += "-$key"
            }
            continue
        }

        $paramTokens += "-$key"
        $paramTokens += (ConvertTo-PowerShellArgument -Value ([string]$value))
    }

    $runnerPathToken = ConvertTo-PowerShellArgument -Value $RunnerPath
    $commandText = "& $runnerPathToken $($paramTokens -join ' ')"
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $commandText)

    return Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -WindowStyle Hidden -PassThru -RedirectStandardOutput $StartupStdOutPath -RedirectStandardError $StartupStdErrPath
}

function Start-TaskSchedulerWindow {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ResolvedConfigPath,
        [AllowNull()][string]$JobName,
        [AllowNull()][string]$SourceFolder,
        [AllowNull()][string]$Operation,
        [Parameter(Mandatory = $true)][string]$LogDir
    )

    $startStamp = Get-Date -Format 'yyyy-MM-dd ddd HH:mm:ss'
    $lines = @(
        "[STEP] Sync job started at $startStamp",
        "[INFO] Logs: $LogDir",
        '[INFO] This window is only a notification. Close it anytime; the job keeps running.',
        "[INFO] Mode: $Mode",
        "[INFO] Config: $ResolvedConfigPath"
    )

    if (-not [string]::IsNullOrWhiteSpace($JobName)) {
        $lines += "[INFO] JobName: $JobName"
    }

    if (-not [string]::IsNullOrWhiteSpace($SourceFolder)) {
        $lines += "[INFO] SourceFolder: $SourceFolder"
    }

    if (-not [string]::IsNullOrWhiteSpace($Operation)) {
        $lines += "[INFO] Operation: $Operation"
    }

    $encodedLines = @($lines | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
    $notificationScript = @"
`$Host.UI.RawUI.WindowTitle = 'Nexus Sync Job Scheduler'
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
    $runnerPath = Join-Path $PSScriptRoot 'src/Run-RcloneJobs.ps1'
    if (-not (Test-Path -LiteralPath $runnerPath)) {
        throw "Runner script not found: $runnerPath"
    }

    $resolvedConfigPath = Resolve-ConfigPath -Path $ConfigPath
    if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
        throw "Config file not found: $resolvedConfigPath"
    }

    if (-not [string]::IsNullOrWhiteSpace($JobName) -and -not [string]::IsNullOrWhiteSpace($SourceFolder)) {
        throw 'Use either -JobName or -SourceFolder, not both.'
    }

    if ($Interactive) {
        $Mode = Read-Choice -Prompt 'Mode (run|dryrun|monitor)' -Allowed @('run', 'dryrun', 'monitor') -Default $Mode

        if ($Mode -ne 'monitor') {
            $filterMode = Read-Choice -Prompt 'Filter (none|job|source)' -Allowed @('none', 'job', 'source') -Default 'none'
            if ($filterMode -eq 'job') {
                $JobName = Read-Host 'Job name'
                $SourceFolder = $null
            }
            elseif ($filterMode -eq 'source') {
                $SourceFolder = Read-Host 'Source folder path'
                $JobName = $null
            }
        }

        $silentText = Read-Choice -Prompt 'Silent mode (yes|no)' -Allowed @('yes', 'no') -Default ($(if ($Silent) { 'yes' } else { 'no' }))
        $Silent = ($silentText -eq 'yes')

        if ($Mode -ne 'monitor') {
            $dryOp = Read-Choice -Prompt 'Operation override (none|copy|sync)' -Allowed @('none', 'copy', 'sync') -Default ($(if ([string]::IsNullOrWhiteSpace($Operation)) { 'none' } else { $Operation }))
            if ($dryOp -eq 'none') {
                $Operation = $null
            }
            else {
                $Operation = $dryOp
            }
        }

        if ($Mode -eq 'monitor') {
            $idleInput = Read-Host "IdleTimeSeconds [$IdleTimeSeconds]"
            if (-not [string]::IsNullOrWhiteSpace($idleInput)) {
                $parsedIdle = 0
                if (-not [int]::TryParse($idleInput, [ref]$parsedIdle)) {
                    throw 'IdleTimeSeconds must be an integer.'
                }
                if ($parsedIdle -lt 5 -or $parsedIdle -gt 3600) {
                    throw 'IdleTimeSeconds must be between 5 and 3600.'
                }
                $IdleTimeSeconds = $parsedIdle
            }
        }
    }

    $waitForNetwork = [bool]$TaskScheduler
    $notifyOnEvents = [bool]$TaskScheduler
    $runnerParams = Build-RunnerParameters -SelectedMode $Mode -ResolvedConfigPath $resolvedConfigPath -SelectedJobName $JobName -SelectedSourceFolder $SourceFolder -SelectedIdle $IdleTimeSeconds -SelectedOperation $Operation -SelectedFailFast:$FailFast -SelectedSilent:$Silent -SelectedWaitForNetwork:$waitForNetwork -SelectedNotifyOnEvents:$notifyOnEvents
    $runnerArgs = Build-RunnerArgs -SelectedMode $Mode -ResolvedConfigPath $resolvedConfigPath -SelectedJobName $JobName -SelectedSourceFolder $SourceFolder -SelectedIdle $IdleTimeSeconds -SelectedOperation $Operation -SelectedFailFast:$FailFast -SelectedSilent:$Silent -SelectedWaitForNetwork:$waitForNetwork -SelectedNotifyOnEvents:$notifyOnEvents

    Write-Info "Runner: $runnerPath"
    Write-Info "Mode: $Mode"
    Write-Info ("Args: {0}" -f ($runnerArgs -join ' '))

    if ($TaskScheduler) {
        $schedulerLogDir = Join-Path $PSScriptRoot 'logs'
        $launcherTempDir = Join-Path $schedulerLogDir 'launcher'
        New-Item -ItemType Directory -Force -Path $launcherTempDir | Out-Null
        $launchStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $startupStdOutPath = Join-Path $launcherTempDir ("detached-start-$launchStamp-stdout.log")
        $startupStdErrPath = Join-Path $launcherTempDir ("detached-start-$launchStamp-stderr.log")
        Write-LauncherLog -LogDir $schedulerLogDir -Message "[LAUNCHER] Detached runner launch requested mode=$Mode config=$resolvedConfigPath"
        Write-LauncherLog -LogDir $schedulerLogDir -Message "[LAUNCHER] Launcher log folder: $launcherTempDir"
        Write-LauncherLog -LogDir $schedulerLogDir -Message "[LAUNCHER] Launcher stdout log file: $startupStdOutPath"
        Write-LauncherLog -LogDir $schedulerLogDir -Message "[LAUNCHER] Launcher stderr log file: $startupStdErrPath"
        Write-Info "Launcher log folder: $launcherTempDir"
        Write-Info "Launcher stdout log file: $startupStdOutPath"
        Write-Info "Launcher stderr log file: $startupStdErrPath"
        Write-Info 'TaskScheduler mode enabled; starting the job in a detached process.'
        try {
            $runnerProcess = Start-ScheduledRunnerProcess -RunnerPath $runnerPath -RunnerParams $runnerParams -StartupStdOutPath $startupStdOutPath -StartupStdErrPath $startupStdErrPath
            $launchPid = if ($null -eq $runnerProcess) { 'unknown' } else { [string]$runnerProcess.Id }
            $showSchedulerWindow = $false
            Write-LauncherLog -LogDir $schedulerLogDir -Message "[LAUNCHER] Detached runner process started pid=$launchPid mode=$Mode"

            if ($null -ne $runnerProcess) {
                # Give detached runner enough time to hit duplicate-instance exit paths
                # so we do not log false 'started successfully' entries.
                Start-Sleep -Milliseconds 2600
                $stillRunning = Get-Process -Id $runnerProcess.Id -ErrorAction SilentlyContinue
                if ($null -eq $stillRunning) {
                    Write-LauncherLog -LogDir $schedulerLogDir -Message "[LAUNCHER] Detached runner process exited immediately pid=$launchPid mode=$Mode"
                    $exitCode = 'unknown'
                    try {
                        $runnerProcess.WaitForExit(2000) | Out-Null
                        $exitCode = [string]$runnerProcess.ExitCode
                    }
                    catch {
                    }

                    $stderrSnippet = ''
                    if (Test-Path -LiteralPath $startupStdErrPath) {
                        try {
                            $stderrSnippet = (Get-Content -LiteralPath $startupStdErrPath -Raw -ErrorAction Stop).Trim()
                        }
                        catch {
                        }
                    }

                    $stdoutSnippet = ''
                    if (Test-Path -LiteralPath $startupStdOutPath) {
                        try {
                            $stdoutSnippet = (Get-Content -LiteralPath $startupStdOutPath -Raw -ErrorAction Stop).Trim()
                        }
                        catch {
                        }
                    }

                    $detailMessage = "[LAUNCHER] Detached runner exited early pid=$launchPid mode=$Mode exitcode=$exitCode"

                    if (-not [string]::IsNullOrWhiteSpace($stderrSnippet)) {
                        $safeStderr = ($stderrSnippet -replace '[\r\n]+', ' ')
                        $detailMessage = "$detailMessage | stderr=$safeStderr"
                    }

                    if (-not [string]::IsNullOrWhiteSpace($stdoutSnippet)) {
                        $safeStdout = ($stdoutSnippet -replace '[\r\n]+', ' ')
                        $detailMessage = "$detailMessage | stdout=$safeStdout"
                    }

                    $isDuplicateInstanceExit = $false

                    if (-not [string]::IsNullOrWhiteSpace($stderrSnippet) -and $stderrSnippet -match 'Another runner instance is already active') {
                        $isDuplicateInstanceExit = $true
                    }
                    if (-not [string]::IsNullOrWhiteSpace($stdoutSnippet) -and $stdoutSnippet -match 'Another runner instance is already active') {
                        $isDuplicateInstanceExit = $true
                    }

                    if (-not $isDuplicateInstanceExit) {
                        $recentRunnerLines = @()
                        $runnerLogPath = Join-Path $schedulerLogDir 'runner.log'
                        if (Test-Path -LiteralPath $runnerLogPath) {
                            try {
                                $recentRunnerLines = @(Get-Content -LiteralPath $runnerLogPath -Tail 40 -ErrorAction Stop)
                            }
                            catch {
                                $recentRunnerLines = @()
                            }
                        }

                        if (($recentRunnerLines -join "`n") -match 'Another runner instance is already active\. Exiting\.') {
                            $isDuplicateInstanceExit = $true
                        }
                    }

                    if ($exitCode -eq '0' -or $isDuplicateInstanceExit) {
                        Write-LauncherLog -LogDir $schedulerLogDir -Message "$detailMessage | note=detached runner exited normally (often already-running instance)."
                    }
                    else {
                        Write-LauncherErrorLog -LogDir $schedulerLogDir -Message $detailMessage
                    }
                }
                else {
                    Write-LauncherLog -LogDir $schedulerLogDir -Message "[LAUNCHER] Detached scheduler job started successfully pid=$launchPid mode=$Mode"
                    Write-LauncherLog -LogDir $schedulerLogDir -Message "[LAUNCHER] Detached runner process confirmed alive pid=$launchPid mode=$Mode"
                    $showSchedulerWindow = $true
                }
            }

            if ($showSchedulerWindow) {
                Start-TaskSchedulerWindow -RunnerPath $runnerPath -Mode $Mode -ResolvedConfigPath $resolvedConfigPath -JobName $JobName -SourceFolder $SourceFolder -Operation $Operation -LogDir $schedulerLogDir
            }
        }
        catch {
            Write-LauncherLog -LogDir $schedulerLogDir -Message "[LAUNCHER] Detached runner process failed to start mode=$Mode error=$($_.Exception.Message)"
            Write-LauncherErrorLog -LogDir $schedulerLogDir -Message "[LAUNCHER] Detached runner process failed to start mode=$Mode error=$($_.Exception.Message)"
            throw
        }
        exit 0
    }

    if ($PreviewOnly) {
        Write-Info 'PreviewOnly enabled; command not executed.'
        exit 0
    }

    & $runnerPath @runnerParams
    exit $LASTEXITCODE
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
