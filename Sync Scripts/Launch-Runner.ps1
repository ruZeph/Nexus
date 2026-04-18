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
        [Parameter(Mandatory = $true)][hashtable]$RunnerParams
    )

    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $RunnerPath)
    foreach ($key in $RunnerParams.Keys) {
        $value = $RunnerParams[$key]
        if ($value -is [bool]) {
            if ($value) {
                $argumentList += "-$key"
            }
            continue
        }

        $argumentList += "-$key"
        $argumentList += [string]$value
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList | Out-Null
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
    $detailLines = @(
        "echo [INFO] Mode: $Mode",
        "echo [INFO] Config: $ResolvedConfigPath"
    )

    if (-not [string]::IsNullOrWhiteSpace($JobName)) {
        $detailLines += "echo [INFO] JobName: $JobName"
    }

    if (-not [string]::IsNullOrWhiteSpace($SourceFolder)) {
        $detailLines += "echo [INFO] SourceFolder: $SourceFolder"
    }

    if (-not [string]::IsNullOrWhiteSpace($Operation)) {
        $detailLines += "echo [INFO] Operation: $Operation"
    }

    $statusLines = @(
        'title Nexus Sync Job Scheduler',
        "echo [STEP] Sync job started at $startStamp",
        "echo [INFO] Logs: $LogDir",
        'echo [INFO] This window is only a notification. Close it anytime; the job keeps running.'
    )

    $commandLine = ($statusLines + $detailLines) -join ' & '
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', $commandLine) | Out-Null
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
        Write-Info 'TaskScheduler mode enabled; starting the job in a detached process.'
        Start-ScheduledRunnerProcess -RunnerPath $runnerPath -RunnerParams $runnerParams
        Start-TaskSchedulerWindow -RunnerPath $runnerPath -Mode $Mode -ResolvedConfigPath $resolvedConfigPath -JobName $JobName -SourceFolder $SourceFolder -Operation $Operation -LogDir (Join-Path $PSScriptRoot 'logs')
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
