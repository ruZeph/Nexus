param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'backup-jobs.json'),
    [string]$JobName,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mutex = [System.Threading.Mutex]::new($false, 'Global\RcloneBackupRunner')

function Write-JobLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogFile,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $LogFile -Value "[$ts] $Message"
}

function Resolve-RcloneExe {
    $cmd = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    }

    if (-not $cmd) {
        throw "rclone was not found in PATH. Add it to PATH and try again."
    }

    if ($cmd.PSObject.Properties.Name -contains 'Source' -and $cmd.Source) {
        return $cmd.Source
    }

    if ($cmd.PSObject.Properties.Name -contains 'Path' -and $cmd.Path) {
        return $cmd.Path
    }

    return $cmd.Definition
}

function Get-SafeLogName {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    $safe = $Name
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace($c, '_')
    }

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'job'
    }

    return $safe
}

try {
    if (-not $mutex.WaitOne(0)) {
        exit 0
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    $cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    if (-not $cfg.jobs) {
        throw "No jobs found in config."
    }

    $rcloneExe = Resolve-RcloneExe
    $logDir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    $jobs = @($cfg.jobs | Where-Object { $_.enabled -ne $false })
    if ($JobName) {
        $jobs = @($jobs | Where-Object { $_.name -eq $JobName })
    }

    if ($jobs.Count -eq 0) {
        $runnerLog = Join-Path $logDir 'runner.log'
        Write-JobLog -LogFile $runnerLog -Message "No enabled jobs matched filter JobName='$JobName'."
        exit 0
    }

    foreach ($job in $jobs) {
        $name = [string]$job.name
        $source = [string]$job.source
        $dest = [string]$job.dest
        $operation = if ($job.operation) { [string]$job.operation } else { 'copy' }
        $operation = $operation.ToLowerInvariant()

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "A job is missing a name."
        }

        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($dest)) {
            throw "Job '$name' is missing source or dest."
        }

        if ($operation -notin @('copy', 'sync')) {
            throw "Job '$name' has invalid operation '$operation'. Allowed values: copy, sync."
        }

        $safeName = Get-SafeLogName -Name $name
        $jobLog = Join-Path $logDir "$safeName.log"

        if (-not (Test-Path -LiteralPath $source)) {
            Write-JobLog -LogFile $jobLog -Message "SKIP source missing: $source"
            continue
        }

        Write-JobLog -LogFile $jobLog -Message "START operation=$operation source=$source dest=$dest dryrun=$DryRun"

        $args = @(
            $operation,
            $source,
            $dest,
            '--log-level', 'INFO',
            '--log-file', $jobLog,
            '--stats', '30s',
            '--stats-one-line'
        )

        if ($null -ne $job.extraArgs) {
            foreach ($a in $job.extraArgs) {
                $args += [string]$a
            }
        }

        if ($DryRun) {
            $args += '--dry-run'
        }

        & $rcloneExe @args
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-JobLog -LogFile $jobLog -Message "DONE exitcode=0"
        }
        else {
            Write-JobLog -LogFile $jobLog -Message "FAILED exitcode=$exitCode"
        }
    }
}
catch {
    $errLogDir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Force -Path $errLogDir | Out-Null
    $errLog = Join-Path $errLogDir 'runner-error.log'
    Add-Content -LiteralPath $errLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $($_.Exception.Message)"
    throw
}
finally {
    try { $mutex.ReleaseMutex() | Out-Null } catch { }
    $mutex.Dispose()
}