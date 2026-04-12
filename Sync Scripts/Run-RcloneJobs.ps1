param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'backup-jobs.json'),
    [string]$JobName,
    [switch]$DryRun,
    [switch]$FailFast,
    [switch]$Silent,
    [ValidateSet('copy', 'sync')][string]$Operation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mutex = [System.Threading.Mutex]::new($false, 'Global\RcloneBackupRunner')
$ownsMutex = $false

function Write-JobLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogFile,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $LogFile -Value "[$ts] $Message"
}

function Write-RunnerLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $runnerLog = Join-Path $LogDir 'runner.log'
    Write-JobLog -LogFile $runnerLog -Message $Message
}

function Write-ShellMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [bool]$IsSilent = $false
    )

    if (-not $IsSilent) {
        Write-Output $Message
    }
}

function Resolve-RcloneExe {
    $cmd = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    }

    if (-not $cmd) {
        throw 'rclone was not found in PATH. Add it to PATH and try again.'
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

function New-JobLogFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][string]$RootLogDir,
        [Parameter(Mandatory = $true)][string]$JobSafeName
    )

    $jobLogDir = Join-Path $RootLogDir $JobSafeName
    if ($PSCmdlet.ShouldProcess($jobLogDir, 'Create job log directory')) {
        New-Item -ItemType Directory -Force -Path $jobLogDir | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return Join-Path $jobLogDir "$stamp.log"
}

function Remove-OldJobLog {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][string]$JobLogDir,
        [int]$KeepCount = 10
    )

    if (-not (Test-Path -LiteralPath $JobLogDir)) {
        return
    }

    $logFiles = @(Get-ChildItem -LiteralPath $JobLogDir -Filter '*.log' -File | Sort-Object LastWriteTime -Descending)
    if ($logFiles.Count -le $KeepCount) {
        return
    }

    foreach ($stale in $logFiles[$KeepCount..($logFiles.Count - 1)]) {
        if ($PSCmdlet.ShouldProcess($stale.FullName, 'Remove old job log file')) {
            Remove-Item -LiteralPath $stale.FullName -Force
        }
    }
}

function Get-ConfigProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function ConvertTo-StringArray {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @([string]$Value)
    }

    $list = @()
    foreach ($item in @($Value)) {
        $list += [string]$item
    }

    if ($list.Count -eq 0) {
        throw "$FieldName must be a string or a non-empty array when provided."
    }

    return $list
}

function Get-NamedObjectProperty {
    param(
        [AllowNull()][object]$Container,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ContainerName
    )

    if ($null -eq $Container) {
        throw "$ContainerName section is missing from config."
    }

    $prop = $Container.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        throw "$ContainerName entry '$Name' was not found in config."
    }

    return $prop.Value
}

function Get-NormalizedOperation {
    param(
        [AllowNull()][object]$Job,
        [AllowNull()][object]$JobProfile,
        [AllowNull()][object]$Settings,
        [AllowNull()][string]$OverrideOperation,
        [Parameter(Mandatory = $true)][string]$CurrentJobName
    )

    $operation = $OverrideOperation
    if ([string]::IsNullOrWhiteSpace([string]$operation)) {
        $operation = Get-ConfigProperty -Object $Job -Name 'operation'
    }
    if ([string]::IsNullOrWhiteSpace([string]$operation)) {
        $operation = Get-ConfigProperty -Object $JobProfile -Name 'operation'
    }
    if ([string]::IsNullOrWhiteSpace([string]$operation)) {
        $operation = Get-ConfigProperty -Object $Settings -Name 'defaultOperation'
    }
    if ([string]::IsNullOrWhiteSpace([string]$operation)) {
        $operation = 'sync'
    }

    $normalized = ([string]$operation).Trim().ToLowerInvariant()
    if ($normalized -notin @('copy', 'sync')) {
        throw "Job '$CurrentJobName' has invalid operation '$normalized'. Allowed values: copy, sync."
    }

    return $normalized
}

function Test-RcloneDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Destination
    )

    return $Destination -match '^[^:]+:.+'
}

function ConvertTo-ProcessArgumentString {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $escaped = foreach ($arg in $Arguments) {
        if ($arg -match '[\s"]') {
            '"' + ($arg -replace '"', '""') + '"'
        }
        else {
            $arg
        }
    }

    return [string]::Join(' ', $escaped)
}

function Invoke-RcloneLive {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogFile,
        [bool]$IsSilent = $false
    )

    try {
        $ErrorActionPreference = 'Continue'
        
        if ($IsSilent) {
            # Silent: capture and log only (no console)
            $output = & $ExePath $Arguments 2>&1
            $output | ForEach-Object {
                $line = [string]$_
                if ($line.Trim()) { Add-Content -Path $LogFile -Value $line }
            }
        }
        else {
            # Live: stream to console and log
            $output = & $ExePath $Arguments 2>&1
            $output | ForEach-Object {
                $line = [string]$_
                if ($line.Trim()) {
                    Write-Host $line
                    Add-Content -Path $LogFile -Value $line
                }
            }
        }
        
        return $LASTEXITCODE
    }
    catch {
        Write-Error "Rclone execution error: $_"
        return 1
    }
    finally {
        $ErrorActionPreference = 'Stop'
    }
}

function ConvertTo-PositiveInt {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [int]$DefaultValue = 10
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $DefaultValue
    }

    $parsed = 0
    if (-not [int]::TryParse([string]$Value, [ref]$parsed)) {
        throw "$FieldName must be a positive integer."
    }

    if ($parsed -lt 1) {
        throw "$FieldName must be greater than or equal to 1."
    }

    return $parsed
}

try {
    $logDir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    if (-not $mutex.WaitOne(0)) {
        Write-RunnerLog -LogDir $logDir -Message 'Another runner instance is already active. Exiting.'
        exit 0
    }
    $ownsMutex = $true

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    try {
        $cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    }
    catch {
        throw "Config file is not valid JSON: $ConfigPath"
    }

    if (-not $cfg.jobs) {
        throw 'No jobs found in config.'
    }

    $rcloneExe = Resolve-RcloneExe
    $settings = Get-ConfigProperty -Object $cfg -Name 'settings'
    $profiles = Get-ConfigProperty -Object $cfg -Name 'profiles'
    $defaultExtraArgs = ConvertTo-StringArray -Value (Get-ConfigProperty -Object $settings -Name 'defaultExtraArgs') -FieldName 'settings.defaultExtraArgs'
    $defaultLogRetentionCount = ConvertTo-PositiveInt -Value (Get-ConfigProperty -Object $settings -Name 'logRetentionCount') -FieldName 'settings.logRetentionCount' -DefaultValue 10

    $continueOnJobError = $true
    $cfgContinueOnJobError = Get-ConfigProperty -Object $settings -Name 'continueOnJobError'
    if ($cfgContinueOnJobError -is [bool]) {
        $continueOnJobError = $cfgContinueOnJobError
    }

    $jobs = @($cfg.jobs | Where-Object { $_.enabled -ne $false })
    if ($JobName) {
        $jobs = @($jobs | Where-Object { $_.name -eq $JobName })
    }

    $duplicateNames = @(
        $jobs |
        Group-Object -Property name |
        Where-Object { $_.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace([string]$_.Name) }
    )
    if ($duplicateNames.Count -gt 0) {
        $dupeList = ($duplicateNames | ForEach-Object { $_.Name }) -join ', '
        throw "Duplicate job names detected: $dupeList"
    }

    if ($jobs.Count -eq 0) {
        Write-RunnerLog -LogDir $logDir -Message "No enabled jobs matched filter JobName='$JobName'."
        exit 0
    }

    foreach ($job in $jobs) {
        $name = [string](Get-ConfigProperty -Object $job -Name 'name')
        $jobLog = $null

        try {
            if ([string]::IsNullOrWhiteSpace($name)) {
                throw 'A job is missing a name.'
            }

            $safeName = Get-SafeLogName -Name $name
            $jobLog = New-JobLogFile -RootLogDir $logDir -JobSafeName $safeName
            $jobLogDir = Split-Path -Path $jobLog -Parent
            $jobLogRetentionCount = ConvertTo-PositiveInt -Value (Get-ConfigProperty -Object $job -Name 'logRetentionCount') -FieldName "jobs.$name.logRetentionCount" -DefaultValue $defaultLogRetentionCount
            Remove-OldJobLog -JobLogDir $jobLogDir -KeepCount $jobLogRetentionCount

            $source = [string](Get-ConfigProperty -Object $job -Name 'source')
            $dest = [string](Get-ConfigProperty -Object $job -Name 'dest')

            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($dest)) {
                throw "Job '$name' is missing source or dest."
            }

            if (-not (Test-RcloneDestination -Destination $dest)) {
                throw "Job '$name' has invalid destination '$dest'. Expected format remote:path"
            }

            $profileName = [string](Get-ConfigProperty -Object $job -Name 'profile')
            $jobProfile = $null
            if (-not [string]::IsNullOrWhiteSpace($profileName)) {
                $jobProfile = Get-NamedObjectProperty -Container $profiles -Name $profileName -ContainerName 'profiles'
            }

            $operation = Get-NormalizedOperation -Job $job -JobProfile $jobProfile -Settings $settings -OverrideOperation $Operation -CurrentJobName $name
            $profileExtraArgs = ConvertTo-StringArray -Value (Get-ConfigProperty -Object $jobProfile -Name 'extraArgs') -FieldName "profiles.$profileName.extraArgs"
            $jobExtraArgs = ConvertTo-StringArray -Value (Get-ConfigProperty -Object $job -Name 'extraArgs') -FieldName "jobs.$name.extraArgs"

            if (-not (Test-Path -LiteralPath $source)) {
                Write-JobLog -LogFile $jobLog -Message "SKIP source missing: $source"
                Write-ShellMessage -Message "[$name] SKIP source missing: $source" -IsSilent $Silent
                continue
            }

            Write-JobLog -LogFile $jobLog -Message "START operation=$operation source=$source dest=$dest profile=$profileName dryrun=$DryRun"
            Write-ShellMessage -Message "[$name] START operation=$operation dryrun=$DryRun" -IsSilent $Silent

            $rcloneArgs = @(
                $operation,
                $source,
                $dest,
                '--log-level', 'INFO',
                '--stats', '30s',
                '--stats-one-line'
            )

            foreach ($arg in $defaultExtraArgs) {
                $rcloneArgs += $arg
            }
            foreach ($arg in $profileExtraArgs) {
                $rcloneArgs += $arg
            }
            foreach ($arg in $jobExtraArgs) {
                $rcloneArgs += $arg
            }

            if ($DryRun) {
                $rcloneArgs += '--dry-run'
            }

            $exitCode = Invoke-RcloneLive -ExePath $rcloneExe -Arguments $rcloneArgs -LogFile $jobLog -IsSilent $Silent

            if ($exitCode -eq 0) {
                Write-JobLog -LogFile $jobLog -Message 'DONE exitcode=0'
                Write-ShellMessage -Message "[$name] DONE exitcode=0" -IsSilent $Silent
            }
            else {
                Write-JobLog -LogFile $jobLog -Message "FAILED exitcode=$exitCode"
                Write-ShellMessage -Message "[$name] FAILED exitcode=$exitCode" -IsSilent $Silent
                if ($FailFast -or (-not $continueOnJobError)) {
                    throw "Job '$name' failed with exit code $exitCode."
                }
            }
        }
        catch {
            if ($null -eq $jobLog) {
                $fallbackBaseName = if ([string]::IsNullOrWhiteSpace($name)) { 'job' } else { $name }
                $fallbackName = Get-SafeLogName -Name $fallbackBaseName
                $jobLog = New-JobLogFile -RootLogDir $logDir -JobSafeName $fallbackName
            }

            Write-JobLog -LogFile $jobLog -Message "ERROR $($_.Exception.Message)"
            Write-RunnerLog -LogDir $logDir -Message "Job '$name' error: $($_.Exception.Message)"
            Write-ShellMessage -Message "[$name] ERROR $($_.Exception.Message)" -IsSilent $Silent
            if ($FailFast -or (-not $continueOnJobError)) {
                throw
            }
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
    if ($ownsMutex) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}