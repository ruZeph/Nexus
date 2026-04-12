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
    [switch]$PreviewOnly
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
        [bool]$SelectedSilent
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

    return $argsList
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

    $runnerArgs = Build-RunnerArgs -SelectedMode $Mode -ResolvedConfigPath $resolvedConfigPath -SelectedJobName $JobName -SelectedSourceFolder $SourceFolder -SelectedIdle $IdleTimeSeconds -SelectedOperation $Operation -SelectedFailFast:$FailFast -SelectedSilent:$Silent

    Write-Info "Runner: $runnerPath"
    Write-Info "Mode: $Mode"
    Write-Info ("Args: {0}" -f ($runnerArgs -join ' '))

    if ($PreviewOnly) {
        Write-Info 'PreviewOnly enabled; command not executed.'
        exit 0
    }

    & $runnerPath @runnerArgs
    exit $LASTEXITCODE
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
