param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'backup-jobs.json'),
    [string]$JobName,
    [string]$SourceFolder,
    [switch]$Monitor,
    [int]$IdleTimeSeconds = 60,
    [switch]$DryRun,
    [switch]$FailFast,
    [switch]$Silent,
    [switch]$WaitForNetwork,
    [switch]$NotifyOnEvents,
    [switch]$HealthCheck,
    [switch]$InitialSync,
    [int]$JobTimeoutSeconds = 0,
    [ValidateSet('copy', 'sync')][string]$Operation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

$currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$safeUserSid = $currentUserSid -replace '[^A-Za-z0-9_-]', '_'
$projectDiscriminator = [System.IO.Path]::GetFileName($projectRoot)
$mutexName = "Local\RcloneBackupRunner_${safeUserSid}_$projectDiscriminator"
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$ownsMutex = $false

function Write-BatchedJobLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string[]]$Messages,
        [switch]$IsResultLog
    )

    if ($Messages.Count -eq 0) {
        return
    }

    $targetLog = if ($IsResultLog) { 
        Join-Path $LogDir 'runner-results.log' 
    } else { 
        Join-Path $LogDir 'runner.log' 
    }

    try {
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $batchContent = @()
        $batchContent += "[$ts] [BATCH START] $($Messages.Count) entries"
        
        foreach ($msg in $Messages) {
            $batchContent += "[$ts] $msg"
        }
        
        $batchContent += "[$ts] [BATCH END]"
        
        [System.IO.File]::AppendAllLines($targetLog, $batchContent)
    }
    catch {
        # If batch logging fails, fall back to individual logging
        foreach ($msg in $Messages) {
            Write-RunnerLog -LogDir $LogDir -Message $msg
        }
    }
}

function Write-JobLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogFile,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $logDir = Split-Path -Path $LogFile -Parent
    if (-not [string]::IsNullOrWhiteSpace($logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Message"
    $maxAttempts = 4

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine)
            return
        }
        catch {
            if ($attempt -ge $maxAttempts) {
                # Logging failures should not kill monitor/run flow.
                try {
                    Write-Host "[WARN] Failed to write log file '$LogFile': $($_.Exception.Message)" -ForegroundColor Yellow
                }
                catch {
                }
                return
            }

            Start-Sleep -Milliseconds (60 * $attempt)
        }
    }
}

function Write-RunnerLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $runnerLog = Join-Path $LogDir 'runner.log'
    Write-JobLog -LogFile $runnerLog -Message $Message
}

function Write-RunnerErrorLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $runnerErrorLog = Join-Path $LogDir 'runner-error.log'
    Write-JobLog -LogFile $runnerErrorLog -Message $Message
}

function Get-StopRequestPath {
    param([Parameter(Mandatory = $true)][string]$LogDir)

    return (Join-Path $LogDir 'stop-request.txt')
}

function Test-StopRequested {
    param([Parameter(Mandatory = $true)][string]$LogDir)

    return (Test-Path -LiteralPath (Get-StopRequestPath -LogDir $LogDir))
}

function Clear-StopRequest {
    param([Parameter(Mandatory = $true)][string]$LogDir)

    $requestPath = Get-StopRequestPath -LogDir $LogDir
    if (Test-Path -LiteralPath $requestPath) {
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    }
}

function Read-StopRequestMessage {
    param([Parameter(Mandatory = $true)][string]$LogDir)

    $requestPath = Get-StopRequestPath -LogDir $LogDir
    if (-not (Test-Path -LiteralPath $requestPath)) {
        return 'Stop requested.'
    }

    try {
        $content = Get-Content -LiteralPath $requestPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) {
            return 'Stop requested.'
        }

        return $content.Trim()
    }
    catch {
        return 'Stop requested.'
    }
}

function Save-RunnerLogsToArchive {
    param([Parameter(Mandatory = $true)][string]$LogDir)

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $archiveRoot = Join-Path $LogDir 'old_logs'
    $archiveDate = Get-Date -Format 'yyyy-MM-dd'
    $archiveDir = Join-Path $archiveRoot $archiveDate
    New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

    $archiveStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($logName in @('runner.log', 'runner-error.log')) {
        $logPath = Join-Path $LogDir $logName
        if (Test-Path -LiteralPath $logPath) {
            $archiveName = "{0}_{1}.log" -f ([System.IO.Path]::GetFileNameWithoutExtension($logName)), $archiveStamp
            Move-Item -LiteralPath $logPath -Destination (Join-Path $archiveDir $archiveName) -Force
        }
    }

    Remove-OldArchivedRunnerLogs -ArchiveRoot $archiveRoot
}

function Remove-OldArchivedRunnerLogs {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [int]$RetentionDays = 7
    )

    if (-not (Test-Path -LiteralPath $ArchiveRoot)) {
        return
    }

    $cutoffDate = (Get-Date).Date.AddDays(-$RetentionDays)
    foreach ($child in @(Get-ChildItem -LiteralPath $ArchiveRoot -Directory -ErrorAction SilentlyContinue)) {
        try {
            $folderDate = [datetime]::ParseExact($child.Name, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            if ($folderDate -lt $cutoffDate) {
                Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
    }
}

function Write-RunnerSessionSeparator {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir
    )

    $separator = '............................................................'
    Write-JobLog -LogFile (Join-Path $LogDir 'runner.log') -Message $separator
    Write-JobLog -LogFile (Join-Path $LogDir 'runner-error.log') -Message $separator
}

function Write-RunnerResourceLog {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [string]$Context = 'monitor-loop'
    )

    try {
        $proc = Get-Process -Id $PID -ErrorAction Stop
        $now = Get-Date
        $cpuTotalSec = $proc.TotalProcessorTime.TotalSeconds
        $cpuPct = 0.0

        if ($State.ContainsKey('LastSampleTime') -and $State.ContainsKey('LastCpuSeconds')) {
            $elapsedSec = ($now - $State.LastSampleTime).TotalSeconds
            if ($elapsedSec -gt 0) {
                $deltaCpuSec = $cpuTotalSec - [double]$State.LastCpuSeconds
                $cores = [math]::Max([Environment]::ProcessorCount, 1)
                $cpuPct = [math]::Round((($deltaCpuSec / ($elapsedSec * $cores)) * 100), 2)
            }
        }

        $workingMb = [math]::Round($proc.WorkingSet64 / 1MB, 2)
        $privateMb = [math]::Round($proc.PrivateMemorySize64 / 1MB, 2)
        $threads = $proc.Threads.Count
        $handles = $proc.HandleCount

        Write-RunnerLog -LogDir $LogDir -Message "[RESOURCE] context=$Context pid=$PID cpu_pct=$cpuPct working_set_mb=$workingMb private_mb=$privateMb handles=$handles threads=$threads"

        $privateWarnMb = 250
        $workingWarnMb = 220
        $handleWarn = 2000
        $threadWarn = 100
        $cpuWarn = 80

        $warnings = @()
        if ($cpuPct -ge $cpuWarn) { $warnings += "cpu_pct=$cpuPct>=$cpuWarn" }
        if ($workingMb -ge $workingWarnMb) { $warnings += "working_set_mb=$workingMb>=$workingWarnMb" }
        if ($privateMb -ge $privateWarnMb) { $warnings += "private_mb=$privateMb>=$privateWarnMb" }
        if ($handles -ge $handleWarn) { $warnings += "handles=$handles>=$handleWarn" }
        if ($threads -ge $threadWarn) { $warnings += "threads=$threads>=$threadWarn" }

        if ($warnings.Count -gt 0) {
            $warnMsg = "[RESOURCE WARN] context=$Context $($warnings -join ' ')"
            Write-RunnerLog -LogDir $LogDir -Message $warnMsg
            Write-RunnerErrorLog -LogDir $LogDir -Message $warnMsg
        }

        $State['LastSampleTime'] = $now
        $State['LastCpuSeconds'] = $cpuTotalSec
    }
    catch {
        Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to collect resource metrics ($Context): $_"
    }
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

function Test-InternetConnectivity {
    param(
        [Parameter(Mandatory = $false)][string]$HostName = '8.8.8.8',
        [Parameter(Mandatory = $false)][int]$TimeoutMilliseconds = 5000
    )

    try {
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $result = $ping.Send($HostName, $TimeoutMilliseconds)
        return $result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
    }
    catch {
        return $false
    }
}

function ConvertTo-CmdSafeText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    return ($Text -replace '[\r\n]+', ' ' -replace '[&|<>^]', ' ').Trim()
}

function Show-EventNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$VisibleSeconds = 12,
        [switch]$Enabled
    )

    if (-not $Enabled) {
        return
    }

    if ($VisibleSeconds -lt 4) {
        $VisibleSeconds = 4
    }

    $safeTitle = ConvertTo-CmdSafeText -Text $Title
    $safeMessage = ConvertTo-CmdSafeText -Text $Message

    try {
        # Keep notifications parser-safe by avoiding shell command construction.
        Write-Host "[NOTICE][$safeTitle] $safeMessage" -ForegroundColor Cyan
    }
    catch {
        # Notification failures should never break sync execution.
    }
}

function Recover-StaleMutexLock {
    param(
        [Parameter(Mandatory = $true)][System.Threading.Mutex]$Mutex,
        [Parameter(Mandatory = $true)][string]$MutexName,
        [Parameter(Mandatory = $true)][string]$LogDir
    )

    <#
    .SYNOPSIS
    Attempts to recover from a stale mutex lock left by a crashed previous instance.
    Task Scheduler forcefully terminates the monitor, so mutex may be left locked.
    #>
    
    try {
        # If mutex is already owned by another process (locked), we can't acquire it immediately
        # Try to detect if it's stale and force recovery
        $msg = "Detected stale mutex lock (previous instance may have crashed). Attempting recovery..."
        Write-Host "[WARN] $msg" -ForegroundColor Yellow
        Write-RunnerLog -LogDir $LogDir -Message $msg
        
        # For named mutexes, we can't force release - the OS will auto-cleanup when process dies
        # However, in rare cases where process hung without cleanup, we log and continue
        return $false  # Unable to force recovery; caller should exit and retry
    }
    catch {
        Write-RunnerLog -LogDir $LogDir -Message "Error during mutex recovery attempt: $_"
        return $false
    }
}

function Wait-ForInternetConnectivity {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [int]$RetryIntervalSeconds = 30,
        [int]$MaxRetries = 24,
        [switch]$NoTimeout
    )

    $retryCount = 0
    $baseInterval = $RetryIntervalSeconds
    $currentInterval = $baseInterval

    while (-not (Test-InternetConnectivity)) {
        if (-not $NoTimeout -and $retryCount -ge $MaxRetries) {
            $totalWaitSec = $retryCount * $baseInterval
            $msg = "Failed to restore internet connectivity after $retryCount retries (~${totalWaitSec}s). Proceeding anyway."
            Write-RunnerLog -LogDir $LogDir -Message $msg
            Write-Host "[WARN] $msg" -ForegroundColor Yellow
            return
        }

        $retryCount++
        $msg = "No internet connectivity. Retry $retryCount/$MaxRetries in ${currentInterval}s..."
        Write-RunnerLog -LogDir $LogDir -Message $msg
        Write-Host "[INFO] $msg" -ForegroundColor Cyan
        Start-Sleep -Seconds $currentInterval

        # Exponential backoff: increase interval by 50% each retry, cap at 120s
        $currentInterval = [int]([math]::Min($currentInterval * 1.5, 120))
    }

    $msg = "Internet connectivity restored after $retryCount retry(ies). Continuing."
    Write-RunnerLog -LogDir $LogDir -Message $msg
    Write-Host "[OK] $msg" -ForegroundColor Green
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
    
    # Create job log directory - ensure it exists without throwing errors
    try {
        $null = New-Item -ItemType Directory -Force -Path $jobLogDir -ErrorAction Stop | Out-Null
    }
    catch {
        # If creation fails, log but don't crash - logs can still be written to root LogDir
        Write-Host "[WARNING] Failed to create job log directory: $_" -ForegroundColor Yellow
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return Join-Path $jobLogDir "$stamp.log"
}

function Remove-OldJobLog {
    param(
        [Parameter(Mandatory = $true)][string]$JobLogDir,
        [int]$KeepCount = 10
    )

    if (-not (Test-Path -LiteralPath $JobLogDir)) {
        return
    }

    if ($KeepCount -gt 10) {
        $KeepCount = 10
    }

    $logFiles = @(Get-ChildItem -LiteralPath $JobLogDir -Filter '*.log' -File | Sort-Object LastWriteTime -Descending)
    
    if ($logFiles.Count -le $KeepCount) {
        return
    }

    $toRemove = $logFiles[$KeepCount..($logFiles.Count - 1)]
    
    foreach ($stale in $toRemove) {
        Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue
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

function Test-RateLimitError {
    param(
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    if (-not (Test-Path -LiteralPath $LogFile)) {
        return $false
    }

    $content = Get-Content -Raw -LiteralPath $LogFile
    return $content -match '(403|429|TooManyRequests|rate limit|Rate limit exceeded|Throttled)'
}

function Test-NetworkInterruptionError {
    param(
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    if (-not (Test-Path -LiteralPath $LogFile)) {
        return $false
    }

    $content = Get-Content -Raw -LiteralPath $LogFile
    return $content -match '(i/o timeout|TLS handshake timeout|connection reset by peer|connection refused|network is unreachable|no route to host|temporary failure in name resolution|lookup .* no such host|dial tcp.*timeout|context deadline exceeded|use of closed network connection)'
}

function Invoke-RcloneLive {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogFile,
        [bool]$IsSilent = $false,
        [int]$TimeoutSeconds = 0
    )

    try {
        $ErrorActionPreference = 'Continue'
        
        if ($TimeoutSeconds -le 0) {
            # No timeout - original behavior
            if ($IsSilent) {
                $output = & $ExePath $Arguments 2>&1
                $output | ForEach-Object {
                    $line = [string]$_
                    if ($line.Trim()) { Add-Content -Path $LogFile -Value $line }
                }
            }
            else {
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
        else {
            # With timeout - run as job
            $job = Start-Job -ScriptBlock {
                param($exe, $arguments, $log, $silent)
                $ErrorActionPreference = 'Continue'
                if ($silent) {
                    $output = & $exe $arguments 2>&1
                    $output | ForEach-Object {
                        $line = [string]$_
                        if ($line.Trim()) { Add-Content -Path $log -Value $line }
                    }
                } else {
                    $output = & $exe $arguments 2>&1
                    $output | ForEach-Object {
                        $line = [string]$_
                        if ($line.Trim()) { Add-Content -Path $log -Value $line }
                    }
                }
                return $LASTEXITCODE
            } -ArgumentList $ExePath, $Arguments, $LogFile, $IsSilent

            $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
            
            if ($null -eq $completed) {
                # Job timed out
                Stop-Job -Job $job -Force
                Remove-Job -Job $job -Force
                Add-Content -Path $LogFile -Value "[TIMEOUT] Job exceeded timeout of ${TimeoutSeconds}s"
                return 124  # Standard timeout exit code
            }
            
            $result = Receive-Job -Job $job
            $exitCode = $job.ExitCode
            Remove-Job -Job $job -Force
            
            if (-not $IsSilent -and $result) {
                $result | ForEach-Object { Write-Host $_ }
            }
            
            return $exitCode
        }
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

function Get-FolderSnapshotSignature {
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath
    )

    if (-not (Test-Path -LiteralPath $FolderPath)) {
        return ''
    }

    try {
        # Use only top-level items for faster comparison (low CPU/memory)
        $items = @(Get-ChildItem -LiteralPath $FolderPath -Force -ErrorAction Stop | 
            Select-Object -Property Name, LastWriteTimeUtc | 
            Sort-Object -Property Name)

        if ($items.Count -eq 0) {
            return 'EMPTY'
        }

        # Quick signature: file count + sum of timestamps + first/last filename
        # This catches 99% of changes without full hash computation
        # Use [long] to avoid integer overflow with large timestamp sums (timestamps can exceed int.MaxValue)
        $timestampSum = [long]($items | Measure-Object -Property LastWriteTimeUtc -Sum).Sum
        $quickSig = "$($items.Count)|$($items[0].Name)|$($items[-1].Name)|$timestampSum"
        
        # Return quick signature if it's sufficient; only compute full hash if needed
        # For large folders, quick signature is fast and accurate
        if ($items.Count -gt 500) {
            return $quickSig
        }

        # For smaller folders, compute full hash for better collision resistance
        $signatureData = ($items | ForEach-Object { "$($_.Name)|$($_.LastWriteTimeUtc.Ticks)" }) -join '|'
        $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($signatureData))
        return [System.BitConverter]::ToString($hash) -replace '-', ''
    }
    catch [System.UnauthorizedAccessException] {
        return 'ERROR_ACCESS'
    }
    catch {
        return 'ERROR_READ'
    }
}

function Update-FolderJobMapping {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [bool]$IsSilent = $false,
        [hashtable]$ExistingMap = @{}
    )

    $folderJobMap = @{}
    $watchedFolders = @()
    
    if ($null -eq $Config -or $null -eq $Config.jobs) {
        return @{ JobMap = $ExistingMap; Folders = @() }
    }
    
    foreach ($job in $Config.jobs | Where-Object { $_.enabled -ne $false }) {
        $source = [string](Get-ConfigProperty -Object $job -Name 'source')
        $jobName = [string](Get-ConfigProperty -Object $job -Name 'name')
        
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($jobName)) { 
            continue 
        }
        
        # Security: Validate job name
        if ($jobName -match '[<>:"|?*\\]') {
            Write-RunnerLog -LogDir $LogDir -Message "Warning: Invalid job name: $jobName"
            continue
        }
        
        try {
            $resolvedPath = (Resolve-Path -Path $source -ErrorAction SilentlyContinue).ProviderPath
            if (-not [string]::IsNullOrWhiteSpace($resolvedPath)) {
                if (-not $folderJobMap.ContainsKey($resolvedPath)) {
                    $folderJobMap[$resolvedPath] = @()
                    $watchedFolders += $resolvedPath
                    
                    if (-not $ExistingMap.ContainsKey($resolvedPath)) {
                        Write-RunnerLog -LogDir $LogDir -Message "[NEW JOB] Monitoring: $resolvedPath"
                        Write-ShellMessage -Message "[NEW] Monitoring: $resolvedPath" -IsSilent $IsSilent
                    }
                }
                $folderJobMap[$resolvedPath] += $jobName
            }
        }
        catch {
            Write-RunnerLog -LogDir $LogDir -Message "Warning: Cannot monitor '$source': $_"
        }
    }
    
    return @{ JobMap = $folderJobMap; Folders = $watchedFolders }
}

function Add-FolderWatcher {
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][hashtable]$Watchers,
        [Parameter(Mandatory = $true)][hashtable]$WatcherSync,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [bool]$IsSilent = $false
    )

    if ($Watchers.ContainsKey($FolderPath)) {
        return
    }

    try {
        $watcher = [System.IO.FileSystemWatcher]::new($FolderPath)
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor
            [System.IO.NotifyFilters]::DirectoryName -bor
            [System.IO.NotifyFilters]::LastWrite -bor
            [System.IO.NotifyFilters]::Size -bor
            [System.IO.NotifyFilters]::CreationTime

        $eventData = @{
            FolderPath = $FolderPath
            WatcherSync = $WatcherSync
        }

        # Consolidated event handler that uses queue instead of overwriting
        # IMPORTANT: Filter out temp/lock/swap files at source to prevent queue pollution
        $eventHandler = {
            $sync = $event.MessageData.WatcherSync
            $folder = [string]$event.MessageData.FolderPath
            $fileEvent = $event.SourceEventArgs
            
            if ($null -eq $sync -or [string]::IsNullOrWhiteSpace($folder)) {
                return
            }
            
            $fullPath = [string]$fileEvent.FullPath
            
            # ==============================================================
            # FILTER: Skip temp, lock, swap, and system files immediately
            # ==============================================================
            # These patterns should be ignored (not queued, not logged):
            $tempPatterns = @(
                '~$*'                    # Word temp files
                '*.tmp'                  # Temporary files
                '*.temp'                 # Temporary files
                '*.bak'                  # Backup files
                '*.swp'                  # Vim swap
                '*.swo'                  # Vim swap
                '*.lock'                 # Lock files
                '*.lck'                  # Lock files
                'Thumbs.db'              # Windows thumbnail cache
                '.DS_Store'              # macOS metadata
                '*.crdownload'           # Chrome download
                '*.part'                 # Partial download
                '*.tmp.*'                # Various temp variants
                '._*'                    # macOS resource forks
                'desktop.ini'            # Windows folder config
            )
            
            $fileName = [System.IO.Path]::GetFileName($fullPath)
            $shouldSkip = $false
            
            # Check against known temp patterns
            foreach ($pattern in $tempPatterns) {
                if ($fileName -like $pattern) {
                    $shouldSkip = $true
                    break
                }
            }
            
            # Skip files starting with a dot (hidden files like .git, .lock)
            if (-not $shouldSkip -and $fileName.StartsWith('.')) {
                $shouldSkip = $true
            }
            
            # Skip Office/system random hex temp files (8 hex chars, often all-caps or mixed)
            # Examples: 99E2D000, FB1C78DF, FF000000 from Office save process
            # Use atomic grouping pattern to prevent ReDoS: match exactly 8 hex chars followed by end-of-string or dot+anything
            if (-not $shouldSkip -and $fileName -match '^[A-F0-9]{8}(?:\..+)?$') {
                $shouldSkip = $true
            }
            
            if ($shouldSkip) {
                # Silently skip - don't queue, don't log (prevent noise)
                return
            }
            
            # ==============================================================
            # ONLY ROOT FILES: Queue this change
            # ==============================================================
            $eventRecord = [pscustomobject]@{
                Time = Get-Date
                ChangeType = [string]$fileEvent.ChangeType
                FullPath = $fullPath
                OldFullPath = [string]$fileEvent.OldFullPath
            }
            
            # Add to queue (only root files reach here) - atomic check-and-create with lock
            if (-not $sync.EventQueue.ContainsKey($folder)) {
                try {
                    # Use try/catch to handle race where another thread creates the queue
                    $sync.EventQueue[$folder] = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
                } catch { }
            }
            if ($sync.EventQueue.ContainsKey($folder)) {
                $sync.EventQueue[$folder].Enqueue($eventRecord)
            }
            
            # Mark folder as having pending changes
            $sync.ChangedFolders[$folder] = $true
        }

        $subs = @(
            (Register-ObjectEvent -InputObject $watcher -EventName Changed -MessageData $eventData -Action $eventHandler)
            (Register-ObjectEvent -InputObject $watcher -EventName Created -MessageData $eventData -Action $eventHandler)
            (Register-ObjectEvent -InputObject $watcher -EventName Deleted -MessageData $eventData -Action $eventHandler)
            (Register-ObjectEvent -InputObject $watcher -EventName Renamed -MessageData $eventData -Action $eventHandler)
        )

        $watcher.EnableRaisingEvents = $true
        $Watchers[$FolderPath] = [pscustomobject]@{
            Watcher = $watcher
            Subscriptions = $subs
        }

        $msg = "FileSystemWatcher enabled: $FolderPath"
        Write-RunnerLog -LogDir $LogDir -Message $msg
        Write-ShellMessage -Message $msg -IsSilent $IsSilent
    }
    catch {
        Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to enable FileSystemWatcher for '$FolderPath': $_"
    }
}

function Remove-FolderWatcher {
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][hashtable]$Watchers,
        [Parameter(Mandatory = $true)][string]$LogDir
    )

    if (-not $Watchers.ContainsKey($FolderPath)) {
        return
    }

    $entry = $Watchers[$FolderPath]

    foreach ($subscription in @($entry.Subscriptions)) {
        try {
            if ($subscription.PSObject.Properties.Name -contains 'SourceIdentifier' -and $subscription.SourceIdentifier) {
                Unregister-Event -SourceIdentifier $subscription.SourceIdentifier -ErrorAction SilentlyContinue
                Get-Job -Name $subscription.SourceIdentifier -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
            }
            elseif ($subscription.PSObject.Properties.Name -contains 'SubscriptionId' -and $null -ne $subscription.SubscriptionId) {
                Unregister-Event -SubscriptionId $subscription.SubscriptionId -ErrorAction SilentlyContinue
            }

            if ($subscription.PSObject.Properties.Name -contains 'Id' -and $null -ne $subscription.Id) {
                Remove-Job -Id $subscription.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to remove watcher subscription for '$FolderPath': $_"
        }
    }

    try {
        $entry.Watcher.EnableRaisingEvents = $false
        $entry.Watcher.Dispose()
    }
    catch {
        Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to dispose watcher for '$FolderPath': $_"
    }

    $Watchers.Remove($FolderPath) | Out-Null
}

function Get-HealthCheckStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$LogDir
    )

    $status = @{
        timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        version = '1.0'
        status = 'healthy'
        details = @{}
    }

    # Check if config exists and is valid
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $status.status = 'unhealthy'
        $status.details.config = 'missing'
        return $status
    }

    try {
        $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
        $status.details.config = 'valid'
        $status.details.jobCount = $config.jobs.Count
        $status.details.enabledJobs = @($config.jobs | Where-Object { $_.enabled -ne $false }).Count
    }
    catch {
        $status.status = 'unhealthy'
        $status.details.config = "invalid: $_"
        return $status
    }

    # Check runner log health
    $runnerLog = Join-Path $LogDir 'runner.log'
    if (Test-Path -LiteralPath $runnerLog) {
        $lastLine = Get-Content -LiteralPath $runnerLog -Tail 1
        $status.details.lastLogEntry = $lastLine
        $status.details.hasRecentActivity = $lastLine -match '\[.*\]'
    }

    # Check for heartbeat
    $heartbeatPath = Join-Path $LogDir 'heartbeat.txt'
    if (Test-Path -LiteralPath $heartbeatPath) {
        $hbContent = Get-Content -LiteralPath $heartbeatPath
        $status.details.lastHeartbeat = $hbContent
        $status.details.hasHeartbeat = $true
    }

    # Check for stop request
    if (Test-StopRequested -LogDir $LogDir) {
        $status.details.stopRequested = $true
        $status.status = 'stopping'
    }

    return $status
}

function Save-FolderSnapshots {
    param(
        [Parameter(Mandatory = $true)][hashtable]$FolderState,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $false)][hashtable]$SyncStatus = @{}
    )

    try {
        $stateDir = Join-Path $ProjectRoot '.state'
        
        try {
            $null = New-Item -ItemType Directory -Force -Path $stateDir -ErrorAction Stop | Out-Null
        }
        catch {
            Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to create .state directory for snapshots: $_"
            return
        }
        
        $stateFile = Join-Path $stateDir 'folder-snapshots.json'
        $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        
        # Build clean JSON object using PSCustomObject for better serialization
        $folderSnapshots = @{}
        foreach ($folder in $FolderState.Keys) {
            $lastSyncStatus = if ($SyncStatus.ContainsKey($folder)) { $SyncStatus[$folder] } else { $null }
            $lastSyncTime = if ($lastSyncStatus -eq 'success') { $now } else { $null }
            $lastChangeTime = if ($null -ne $FolderState[$folder].LastChange) { $FolderState[$folder].LastChange.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
            
            $folderSnapshots[$folder] = [PSCustomObject]@{
                snapshot = [string]$FolderState[$folder].Snapshot
                lastChange = $lastChangeTime
                lastSyncStatus = $lastSyncStatus
                lastSuccessfulSync = $lastSyncTime
                lastSaved = $now
            }
        }
        
        # Build root object with proper structure
        $rootObject = [PSCustomObject]@{
            timestamp = $now
            folders = $folderSnapshots
        } | ConvertTo-Json -Depth 3 -Compress:$false
        
        $rootObject | Set-Content -Path $stateFile -Force -Encoding UTF8
        Write-RunnerLog -LogDir $LogDir -Message "Snapshots saved successfully to $stateFile"
    }
    catch {
        Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to save folder snapshots: $_"
    }
}

function Get-FolderSnapshots {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$LogDir
    )

    try {
        # Snapshots stored in .state/ directory (not in logs/)
        $stateDir = Join-Path $ProjectRoot '.state'
        $stateFile = Join-Path $stateDir 'folder-snapshots.json'
        
        if (-not (Test-Path -LiteralPath $stateFile)) {
            return @{}
        }
        
        $state = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
        $result = @{}
        
        if ($state.folders) {
            foreach ($folder in $state.folders.PSObject.Properties.Name) {
                $result[$folder] = $state.folders.$folder
            }
        }
        
        return $result
    }
    catch {
        Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to load folder snapshots: $_"
        return @{}
    }
}

function Find-ChangedFoldersOnRestart {
    param(
        [Parameter(Mandatory = $true)][string[]]$WatchedFolders,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$LogDir
    )

    $savedSnapshots = Get-FolderSnapshots -ProjectRoot $ProjectRoot -LogDir $LogDir
    $changedFolders = @()
    
    foreach ($folder in $WatchedFolders) {
        $reasons = @()
        
        # Case 1: No snapshot exists (first time monitoring this folder)
        if (-not $savedSnapshots.ContainsKey($folder)) {
            $reasons += "No previous snapshot (first sync)"
        } else {
            $savedData = $savedSnapshots[$folder]
            $currentSnapshot = Get-FolderSnapshotSignature -FolderPath $folder
            $savedSnapshot = $savedData.snapshot
            $lastSyncStatus = if ($savedData.PSObject.Properties.Name -contains 'lastSyncStatus') { $savedData.lastSyncStatus } else { $null }
            
            # Case 2: Last sync failed or never completed
            if ($lastSyncStatus -ne 'success') {
                $reasons += "Last sync was not successful (status: $lastSyncStatus)"
            }
            
            # Case 3: Folder contents changed while monitor was stopped
            if ($currentSnapshot -notin @('ERROR_ACCESS', 'ERROR_READ') -and $currentSnapshot -ne $savedSnapshot) {
                $reasons += "Folder contents changed (snapshot mismatch)"
            }
        }
        
        # If ANY reason exists, mark folder for sync
        if ($reasons.Count -gt 0) {
            $changedFolders += $folder
            $msg = "[RESTART CHANGE DETECTION] $folder | Reasons: $(($reasons -join '; '))"
            Write-RunnerLog -LogDir $LogDir -Message $msg
            Write-Host "[INFO] $msg" -ForegroundColor Cyan
        }
    }
    
    return $changedFolders
}

<#
.SYNOPSIS
Validates critical runtime requirements before starting monitoring or jobs
.DESCRIPTION
Checks: rclone executable, source folders, remote paths, and remote connectivity
Returns: $true if all validations pass; throws on critical failures
#>
function Test-PreflightRequirements {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $false)][bool]$IsSilent = $false,
        [Parameter(Mandatory = $false)][bool]$NotifyOnEvents = $false
    )

    $rcloneExe = Resolve-RcloneExe
    $allValid = $true
    $errorMessages = @()

    # 1. Validate rclone is executable
    try {
        $rcloneVersion = & $rcloneExe --version 2>&1 | Select-Object -First 1
        Write-RunnerLog -LogDir $LogDir -Message "Rclone executable verified: $rcloneVersion"
    }
    catch {
        $msg = "CRITICAL: Rclone not found or not executable at '$rcloneExe'"
        Write-RunnerLog -LogDir $LogDir -Message $msg
        Write-ShellMessage -Message $msg -IsSilent $IsSilent
        throw $msg
    }

    # 2. Validate source folders exist and are accessible
    if ($Config.jobs) {
        $jobs = @($Config.jobs | Where-Object { $_.enabled -ne $false })
        foreach ($job in $jobs) {
            $jobName = [string](Get-ConfigProperty -Object $job -Name 'name')
            $source = [string](Get-ConfigProperty -Object $job -Name 'source')
            
            if ([string]::IsNullOrWhiteSpace($source)) {
                $msg = "CRITICAL: Job '$jobName' has empty source path"
                $errorMessages += $msg
                $allValid = $false
                continue
            }

            if (-not (Test-Path -LiteralPath $source)) {
                $msg = "CRITICAL: Job '$jobName' source folder not found: $source"
                Write-RunnerLog -LogDir $LogDir -Message $msg
                Write-ShellMessage -Message $msg -IsSilent $IsSilent
                $errorMessages += $msg
                $allValid = $false
                continue
            }

            try {
                $items = @(Get-ChildItem -LiteralPath $source -ErrorAction Stop | Measure-Object | Select-Object -ExpandProperty Count)
                Write-RunnerLog -LogDir $LogDir -Message "Job '$jobName' source validated: $source ($items items)"
            }
            catch {
                $msg = "CRITICAL: Job '$jobName' source not accessible: $source - $_"
                Write-RunnerLog -LogDir $LogDir -Message $msg
                Write-ShellMessage -Message $msg -IsSilent $IsSilent
                $errorMessages += $msg
                $allValid = $false
            }
        }
    }

    # 3. Validate rclone remotes exist and are accessible
    if ($Config.jobs) {
        $jobs = @($Config.jobs | Where-Object { $_.enabled -ne $false })
        $remoteNames = @{}
        
        foreach ($job in $jobs) {
            $jobName = [string](Get-ConfigProperty -Object $job -Name 'name')
            $dest = [string](Get-ConfigProperty -Object $job -Name 'dest')
            
            if ([string]::IsNullOrWhiteSpace($dest)) {
                $msg = "CRITICAL: Job '$jobName' has empty destination path"
                Write-RunnerLog -LogDir $LogDir -Message $msg
                Write-ShellMessage -Message $msg -IsSilent $IsSilent
                $errorMessages += $msg
                $allValid = $false
                continue
            }

            # Extract remote name (format: RemoteName:path or RemoteName:/path)
            if ($dest -match '^([^:]+):') {
                $remoteName = $matches[1]
                
                # Only test each remote once
                if (-not $remoteNames.ContainsKey($remoteName)) {
                    # Test remote connectivity with lsf command (lists files, minimal output)
                    try {
                        $remotePath = "$remoteName`:"  # Escape colon to avoid PowerShell variable reference
                        $testOutput = & $rcloneExe lsf $remotePath --max-depth 0 2>&1
                        $lastExitCode = $LASTEXITCODE
                        
                        if ($lastExitCode -eq 0) {
                            Write-RunnerLog -LogDir $LogDir -Message "Remote '$remoteName' validated successfully"
                            $remoteNames[$remoteName] = $true
                        } else {
                            $errorMsg = $testOutput -join "`n"
                            Write-RunnerLog -LogDir $LogDir -Message "CRITICAL: Remote '$remoteName' failed: $errorMsg"
                            Write-ShellMessage -Message "CRITICAL: Remote '$remoteName' test failed. Error: $errorMsg" -IsSilent $IsSilent
                            $errorMessages += "Remote '$remoteName' failed: $errorMsg"
                            $remoteNames[$remoteName] = $false
                            $allValid = $false
                        }
                    }
                    catch {
                        $msg = "CRITICAL: Failed to test remote '$remoteName': $_"
                        Write-RunnerLog -LogDir $LogDir -Message $msg
                        Write-ShellMessage -Message $msg -IsSilent $IsSilent
                        $errorMessages += $msg
                        $remoteNames[$remoteName] = $false
                        $allValid = $false
                    }
                }
            } else {
                # Local path in destination (valid but unusual)
                if (-not (Test-Path -LiteralPath $dest)) {
                    Write-RunnerLog -LogDir $LogDir -Message "Warning: Job '$jobName' destination local path not found (will be created): $dest"
                }
            }
        }
    }

    if (-not $allValid) {
        $summary = $errorMessages -join "; "
        $msg = "CRITICAL: Preflight validation failed. Cannot proceed with jobs: $summary"
        Write-RunnerLog -LogDir $LogDir -Message $msg
        Write-ShellMessage -Message $msg -IsSilent $IsSilent
        
        # Show UI notification about the failure before exiting
        $notificationTitle = "[Nexus Sync] Configuration Invalid"
        $notificationMsg = "Preflight validation failed. Check logs for details. Common issues: expired rclone token, missing remote paths, inaccessible folders."
        Show-EventNotification -Title $notificationTitle -Message $notificationMsg -VisibleSeconds 15 -Enabled:$NotifyOnEvents
        
        throw $msg
    }

    Write-RunnerLog -LogDir $LogDir -Message "All preflight validation checks passed"
    return $true
}

function Start-FolderMonitoring {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [bool]$IsSilent = $false,
        [string]$ConfigPath = "",
        [bool]$DryRun = $false,
        [int]$IdleTimeSeconds = 60,
        [System.Threading.Mutex]$Mutex = $null,
        [bool]$InitialSync = $false
    )

    # Build initial folder-to-jobs mapping
    $mapping = @(
        Update-FolderJobMapping -Config $Config -LogDir $LogDir -IsSilent $IsSilent
    ) | Where-Object {
        $_ -is [hashtable] -and $_.ContainsKey('JobMap') -and $_.ContainsKey('Folders')
    } | Select-Object -Last 1

    if ($null -eq $mapping) {
        throw 'Failed to build folder-job mapping for monitor mode.'
    }

    $folderJobMap = $mapping.JobMap
    $watchedFolders = $mapping.Folders
    
    foreach ($job in $Config.jobs | Where-Object { $_.enabled -ne $false }) {
        $source = [string](Get-ConfigProperty -Object $job -Name 'source')
        $jobName = [string](Get-ConfigProperty -Object $job -Name 'name')
        
        if ([string]::IsNullOrWhiteSpace($source)) { continue }
        
        try {
            $resolvedPath = (Resolve-Path -Path $source -ErrorAction SilentlyContinue).ProviderPath
            if (-not [string]::IsNullOrWhiteSpace($resolvedPath)) {
                if (-not $folderJobMap.ContainsKey($resolvedPath)) {
                    $folderJobMap[$resolvedPath] = @()
                    $watchedFolders += $resolvedPath
                }
                if ($jobName -notin @($folderJobMap[$resolvedPath])) {
                    $folderJobMap[$resolvedPath] += $jobName
                }
                $msg = "Monitoring folder: $resolvedPath -> job: $jobName"
                Write-RunnerLog -LogDir $LogDir -Message $msg
                Write-ShellMessage -Message $msg -IsSilent $IsSilent
            }
        }
        catch {
            Write-RunnerLog -LogDir $LogDir -Message "Warning: Cannot monitor folder '$source' for job '$jobName': $_"
        }
    }

    if ($watchedFolders.Count -eq 0) {
        throw "No valid source folders found to monitor."
    }

    # Hybrid mode: FileSystemWatcher gives low-latency signals, polling snapshot remains a reliability fallback.
    $watchers = @{}
    $watcherSync = [hashtable]::Synchronized(@{ 
        ChangedFolders = [hashtable]::Synchronized(@{})
        EventQueue = [hashtable]::Synchronized(@{})
        FileJobQueue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
        FileJobQueues = [hashtable]::Synchronized(@{})
        ProcessingFiles = [System.Collections.Generic.HashSet[string]]::new()
        ProcessingFilesLock = [System.Threading.ReaderWriterLockSlim]::new()
    })
    $resourceState = @{}
    $resourceLogInterval = 60
    $resourceLastLog = Get-Date

    # Track folder snapshots so only real content changes trigger jobs
    $folderState = @{}
    $lastSnapshotCheck = @{}  # Cache last snapshot check time per folder to avoid excessive polling
    $processingFilesCleanupCounter = 0  # Memory leak prevention: Track cycles to monitor HashSet growth
    $configLastCheck = Get-Date
    $configCheckInterval = 30  # Check config every 30 seconds for changes
    $lastConfigModTime = (Get-Item -LiteralPath $ConfigPath -ErrorAction SilentlyContinue).LastWriteTime

    # Initialize baseline snapshots without triggering jobs on startup
    foreach ($folder in $watchedFolders) {
        $snapshot = Get-FolderSnapshotSignature -FolderPath $folder
        if ($snapshot -notin @('ERROR_ACCESS', 'ERROR_READ')) {
            # Successful snapshot - use it as baseline
            $folderState[$folder] = [pscustomobject]@{
                Snapshot = $snapshot
                LastChange = $null
                PendingChange = $false
                ErrorCount = 0
                InitialAccessFailed = $false
            }
        } else {
            # Access failed initially - use empty baseline for change detection once accessible
            Write-RunnerLog -LogDir $LogDir -Message "Info: Folder not immediately accessible, monitoring for changes once available: $folder"
            $folderState[$folder] = [pscustomobject]@{
                Snapshot = ''  # Empty baseline allows first change detection
                LastChange = $null
                PendingChange = $false
                ErrorCount = 0
                InitialAccessFailed = $true
            }
        }
        # Always add the watcher, regardless of initial access success
        Add-FolderWatcher -FolderPath $folder -Watchers $watchers -WatcherSync $watcherSync -LogDir $LogDir -IsSilent $IsSilent
        
        # Pre-allocate folder queue to avoid on-demand initialization latency
        try {
            if (-not $watcherSync.FileJobQueues.ContainsKey($folder)) {
                $watcherSync.FileJobQueues[$folder] = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
            }
        }
        catch {
            Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to pre-allocate queue for folder '$folder': $_"
        }
    }

    $msg = "Folder monitoring started. Watching $($watchedFolders.Count) folder(s) with ${IdleTimeSeconds}s idle time."
    Write-RunnerLog -LogDir $LogDir -Message $msg
    Write-ShellMessage -Message $msg -IsSilent $IsSilent
    Write-RunnerResourceLog -State $resourceState -LogDir $LogDir -Context 'monitor-start'

    # Detect changes that occurred while monitor was stopped (including previous failed syncs)
    # This ensures fresh instance starts with sync comparison
    $changedFolders = Find-ChangedFoldersOnRestart -WatchedFolders $watchedFolders -ProjectRoot $ProjectRoot -LogDir $LogDir
    if ($changedFolders.Count -gt 0) {
        $msg = "Detected $($changedFolders.Count) folder(s) with changes while monitor was stopped. Will process on next idle cycle."
        Write-RunnerLog -LogDir $LogDir -Message $msg
        Write-ShellMessage -Message $msg -IsSilent $IsSilent
    }

    # If InitialSync requested, mark all folders as changed to trigger sync jobs
    if ($InitialSync) {
        $changedFolders = @($watchedFolders)
        $msg = "InitialSync enabled: Marking all $($watchedFolders.Count) folders for immediate sync"
        Write-RunnerLog -LogDir $LogDir -Message $msg
        Write-ShellMessage -Message $msg -IsSilent $IsSilent
    }

    # Mark changed folders to trigger job execution on next idle cycle
    foreach ($folder in $changedFolders) {
        if ($folderState.ContainsKey($folder)) {
            $folderState[$folder].PendingChange = $true
            $folderState[$folder].LastChange = Get-Date
            
            # Recompute snapshot for changed folders if it was empty (access failed at startup)
            # This ensures fresh hash comparison for idle-triggered execution
            if ([string]::IsNullOrWhiteSpace($folderState[$folder].Snapshot)) {
                $freshSnapshot = Get-FolderSnapshotSignature -FolderPath $folder
                if ($freshSnapshot -notin @('ERROR_ACCESS', 'ERROR_READ')) {
                    $folderState[$folder].Snapshot = $freshSnapshot
                }
            }
        }
    }

    # ===================================================================
    # SNAPSHOT PERSISTENCE STRATEGY
    # ===================================================================
    # Save snapshots on: (1) after first accessible check, (2) after job success, (3) 15-min fallback
    # This balances reliable change detection with minimal I/O
    # Don't save empty/error snapshots - wait until folders are accessible
    # ===================================================================
    $lastSuccessfulSnapshotTime = Get-Date
    $snapshotIntervalSeconds = 900  # 15 minutes as fallback
    $folderSyncStatus = @{}  # Track sync status per folder (success|failed|$null)
    
    # Only save initial snapshot if all folders have valid hashes (not empty or ERROR_*)
    $hasValidSnapshots = $folderState.Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Snapshot) -and $_.Snapshot -notmatch 'ERROR_' }
    if ($hasValidSnapshots) {
        Save-FolderSnapshots -FolderState $folderState -ProjectRoot $ProjectRoot -LogDir $LogDir -SyncStatus $folderSyncStatus
        Write-RunnerLog -LogDir $LogDir -Message "Initial snapshot saved on startup for change detection on next restart"
    } else {
        Write-RunnerLog -LogDir $LogDir -Message "Deferring initial snapshot save: waiting for all folders to become accessible"
    }

    try {
        while ($true) {
            Start-Sleep -Seconds 2
            $now = Get-Date
            
            # Periodically check for memory leaks and 15-minute snapshot fallback
            $processingFilesCleanupCounter++
            if ($processingFilesCleanupCounter -ge 450) {  # Every 900 seconds = 15 minutes (450 x 2 second cycles)
                $processingFilesCleanupCounter = 0
                
                # Check if we need to save deferred initial snapshot (for inaccessible folders that now have real hashes)
                $hasValidSnapshots = $folderState.Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Snapshot) -and $_.Snapshot -notmatch 'ERROR_' } | Measure-Object | Select-Object -ExpandProperty Count
                if ($hasValidSnapshots -gt 0) {
                    Save-FolderSnapshots -FolderState $folderState -ProjectRoot $ProjectRoot -LogDir $LogDir -SyncStatus $folderSyncStatus
                    $lastSuccessfulSnapshotTime = $now
                    Write-RunnerLog -LogDir $LogDir -Message "Snapshot saved (periodic 15-minute interval, valid snapshots: $hasValidSnapshots)"
                }
                
                $watcherSync.ProcessingFilesLock.EnterReadLock()
                try {
                    if ($watcherSync.ProcessingFiles.Count -gt 1000) {
                        Write-RunnerLog -LogDir $LogDir -Message "Warning: ProcessingFiles HashSet elevated at $($watcherSync.ProcessingFiles.Count) entries (threshold: 1000). Possible file removal failures."
                    }
                } finally {
                    $watcherSync.ProcessingFilesLock.ExitReadLock()
                }
            }

            if (Test-StopRequested -LogDir $LogDir) {
                $stopMessage = Read-StopRequestMessage -LogDir $LogDir
                Write-RunnerLog -LogDir $LogDir -Message "Stop request detected. Exiting monitor loop gracefully. Reason: $stopMessage"
                
                # Save final snapshot before graceful shutdown
                Save-FolderSnapshots -FolderState $folderState -ProjectRoot $ProjectRoot -LogDir $LogDir -SyncStatus $folderSyncStatus
                Write-RunnerLog -LogDir $LogDir -Message "Final snapshot saved on graceful shutdown"
                
                Clear-StopRequest -LogDir $LogDir
                return
            }

            if ((($now - $resourceLastLog).TotalSeconds) -ge $resourceLogInterval) {
                Write-RunnerResourceLog -State $resourceState -LogDir $LogDir -Context 'monitor-loop'
                $resourceLastLog = $now
            }
            
            # Dynamic config reload: Check if config changed
            $timeSinceLastCheck = ($now - $configLastCheck).TotalSeconds
            if ($timeSinceLastCheck -ge $configCheckInterval) {
                $configLastCheck = $now
                try {
                    $currentModTime = (Get-Item -LiteralPath $ConfigPath -ErrorAction SilentlyContinue).LastWriteTime
                    if ($null -ne $currentModTime -and $currentModTime -gt $lastConfigModTime) {
                        $tempConfig = $null
                        # Validate JSON before applying
                        try {
                            $tempConfig = Get-Content -Raw -LiteralPath $ConfigPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        }
                        catch {
                            Write-RunnerLog -LogDir $LogDir -Message "CRITICAL: Config file could not be read or has invalid JSON format: $_. Continuing with current config. Will retry on next change."
                            Write-RunnerErrorLog -LogDir $LogDir -Message "Config reload failed: $_"
                            continue
                        }
                        
                        $lastConfigModTime = $currentModTime
                        $newConfig = $tempConfig
                        
                        # Validate config has required sections
                        if ($null -eq $newConfig -or $null -eq $newConfig.jobs) {
                            Write-RunnerLog -LogDir $LogDir -Message "Warning: Reloaded config missing 'jobs' section. Continuing with current config."
                            continue
                        }
                        
                        $mapping = @(
                            Update-FolderJobMapping -Config $newConfig -LogDir $LogDir -IsSilent $IsSilent -ExistingMap $folderJobMap
                        ) | Where-Object {
                            $_ -is [hashtable] -and $_.ContainsKey('JobMap') -and $_.ContainsKey('Folders')
                        } | Select-Object -Last 1

                        if ($null -eq $mapping) {
                            Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to rebuild folder-job mapping from reloaded config. Continuing with current config."
                            continue
                        }

                        $folderJobMap = $mapping.JobMap
                        $watchedFolders = $mapping.Folders

                        # Add state/watchers for newly introduced folders.
                        foreach ($newFolder in @($watchedFolders | Where-Object { -not $folderState.ContainsKey($_) })) {
                            $newSnapshot = Get-FolderSnapshotSignature -FolderPath $newFolder
                            if ($newSnapshot -in @('ERROR_ACCESS', 'ERROR_READ')) {
                                Write-RunnerLog -LogDir $LogDir -Message "Warning: Cannot access newly added folder: $newFolder"
                                continue
                            }

                            $folderState[$newFolder] = [pscustomobject]@{
                                Snapshot = $newSnapshot
                                LastChange = $null
                                PendingChange = $false
                                ErrorCount = 0
                            }
                            Add-FolderWatcher -FolderPath $newFolder -Watchers $watchers -WatcherSync $watcherSync -LogDir $LogDir -IsSilent $IsSilent
                        }

                        # Remove state/watchers for folders no longer configured.
                        foreach ($removedFolder in @($folderState.Keys | Where-Object { $_ -notin $watchedFolders })) {
                            Remove-FolderWatcher -FolderPath $removedFolder -Watchers $watchers -LogDir $LogDir
                            $folderState.Remove($removedFolder) | Out-Null
                            if ($watcherSync.ChangedFolders.ContainsKey($removedFolder)) {
                                $watcherSync.ChangedFolders.Remove($removedFolder) | Out-Null
                            }
                            if ($watcherSync.EventQueue.ContainsKey($removedFolder)) {
                                $watcherSync.EventQueue.Remove($removedFolder) | Out-Null
                            }
                        }
                    }
                }
                catch {
                    Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to reload config: $_"
                }
            }

            foreach ($folder in $watchedFolders) {
                $state = $folderState[$folder]
                if ($null -eq $state) {
                    continue
                }

                $watcherEvent = $null

                # Check if folder still exists and is accessible
                # Use try/catch to handle TOCTOU (time-of-check-time-of-use) race between check and access
                $folderAccessible = $false
                try {
                    $folderAccessible = (Test-Path -LiteralPath $folder -ErrorAction Stop)
                } catch {
                    $folderAccessible = $false
                }
                
                if (-not $folderAccessible) {
                    if ($state.ErrorCount -ge 2) {
                        Write-RunnerLog -LogDir $LogDir -Message "Warning: Folder no longer accessible: $folder"
                        $folderState.Remove($folder) | Out-Null
                        $watchedFolders = @($watchedFolders | Where-Object { $_ -ne $folder })
                    } else {
                        $state.ErrorCount++
                    }
                    continue
                }
                
                $state.ErrorCount = 0

                if ($watcherSync.ChangedFolders.ContainsKey($folder)) {
                    # Process queued events for this folder (up to 5 per cycle for efficiency)
                    $eventQueue = $watcherSync.EventQueue[$folder]
                    if ($null -ne $eventQueue -and $eventQueue.Count -gt 0) {
                        $eventsProcessed = 0
                        $maxEventsPerCycle = 1000
                        $queueCountBefore = $eventQueue.Count
                        
                        while ($eventQueue.Count -gt 0 -and $eventsProcessed -lt $maxEventsPerCycle) {
                            # Dequeue and process event
                            $watcherEvent = $eventQueue.Dequeue()
                            $eventsProcessed++
                            $state.LastChange = $now
                            $state.PendingChange = $true
                            
                            $changeType = [string](Get-ConfigProperty -Object $watcherEvent -Name 'ChangeType')
                            $fullPath = [string](Get-ConfigProperty -Object $watcherEvent -Name 'FullPath')
                            $oldFullPath = [string](Get-ConfigProperty -Object $watcherEvent -Name 'OldFullPath')

                            if ([string]::IsNullOrWhiteSpace($changeType)) { $changeType = 'Changed' }
                            if ([string]::IsNullOrWhiteSpace($fullPath)) { $fullPath = $folder }

                            if ($changeType -eq 'Renamed' -and -not [string]::IsNullOrWhiteSpace($oldFullPath)) {
                                $msg = "Change detected by watcher: $folder [$changeType] $oldFullPath -> $fullPath"
                            } else {
                                $msg = "Change detected by watcher: $folder [$changeType] $fullPath"
                            }
                            
                            # Append remaining queue count for batch processing
                            if ($eventsProcessed -eq 1 -and $eventQueue.Count -gt 0) {
                                $msg += " (batch: $eventsProcessed/$maxEventsPerCycle, $($eventQueue.Count) remaining)"
                            } elseif ($eventsProcessed -gt 1) {
                                $msg += " (event $eventsProcessed of batch)"
                            }
                            
                            Write-RunnerLog -LogDir $LogDir -Message $msg
                            Write-ShellMessage -Message $msg -IsSilent $IsSilent
                            
                            # ==============================================================
                            # FILE-LEVEL WORKER POOL: Queue file changes immediately
                            # ==============================================================
                            # Instead of waiting for idle time, queue each file change
                            # for immediate processing by file-level workers
                            $jobs = @($folderJobMap[$folder] | Select-Object -Unique)
                            foreach ($jobName in $jobs) {
                                # Atomic deduplication: check-and-add in a single write lock.
                                $shouldQueue = $false
                                $watcherSync.ProcessingFilesLock.EnterWriteLock()
                                try {
                                    if (-not $watcherSync.ProcessingFiles.Contains($fullPath)) {
                                        $watcherSync.ProcessingFiles.Add($fullPath) | Out-Null
                                        $shouldQueue = $true
                                    }
                                }
                                finally {
                                    $watcherSync.ProcessingFilesLock.ExitWriteLock()
                                }

                                if (-not $shouldQueue) {
                                    continue
                                }
                                
                                # Queue file-level job
                                $fileJob = [pscustomobject]@{
                                    JobName = $jobName
                                    FolderPath = $folder
                                    FilePath = $fullPath
                                    ChangeType = $changeType
                                    QueueTime = $now
                                }

                                if (-not $watcherSync.FileJobQueues.ContainsKey($folder)) {
                                    try {
                                        $watcherSync.FileJobQueues[$folder] = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
                                    } catch { }
                                }

                                if ($watcherSync.FileJobQueues.ContainsKey($folder)) {
                                    try {
                                        $watcherSync.FileJobQueues[$folder].Enqueue($fileJob)
                                        # Keep global queue for compatibility/observability.
                                        $watcherSync.FileJobQueue.Enqueue($fileJob)
                                    }
                                    catch {
                                        # Roll back dedup marker if queueing failed.
                                        $watcherSync.ProcessingFilesLock.EnterWriteLock()
                                        try {
                                            $watcherSync.ProcessingFiles.Remove($fullPath) | Out-Null
                                        }
                                        finally {
                                            $watcherSync.ProcessingFilesLock.ExitWriteLock()
                                        }
                                        Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to queue file job for '$fullPath': $_"
                                        continue
                                    }
                                }
                                
                                Write-RunnerLog -LogDir $LogDir -Message "Queued file job: $fullPath for $jobName"
                            }
                        }
                        
                        # Clear the changed folder flag when queue is empty
                        if ($eventQueue.Count -eq 0) {
                            $watcherSync.ChangedFolders.Remove($folder) | Out-Null
                        }
                        
                        # Log queue depth if it was large (helps monitor performance)
                        if ($queueCountBefore -ge 10) {
                            Write-RunnerLog -LogDir $LogDir -Message "Queue monitoring: $folder - started: $queueCountBefore events, processed: $eventsProcessed, remaining: $($eventQueue.Count)"
                        }
                    }
                }

                # Optimization: Skip snapshot check if folder is idle and no pending changes
                # This prevents expensive re-hashing on every 2-second monitor cycle
                $shouldCheckSnapshot = $state.PendingChange -or ($null -eq $lastSnapshotCheck[$folder]) -or ((Get-Date) - $lastSnapshotCheck[$folder]).TotalSeconds -ge 15
                
                if (-not $shouldCheckSnapshot) {
                    # Still pending but snapshot wasn't checked recently enough - continue to next folder
                    continue
                }
                
                $lastSnapshotCheck[$folder] = Get-Date
                $currentSnapshot = Get-FolderSnapshotSignature -FolderPath $folder
                
                # If snapshot computation failed BUT folder is pending change, allow execution to proceed
                # This ensures startup syncs work even if snapshot hashing fails temporarily
                if ($currentSnapshot -in @('ERROR_ACCESS', 'ERROR_READ')) {
                    $state.ErrorCount++
                    if ($state.ErrorCount -ge 3) {
                        Write-RunnerLog -LogDir $LogDir -Message "Warning: Persistent access error: $folder"
                    }
                    # If folder is marked pending from startup change detection, don't skip - allow idle timeout to work
                    if (-not $state.PendingChange) {
                        continue
                    }
                }
                
                if ($currentSnapshot -ne $state.Snapshot) {
                    $state.Snapshot = $currentSnapshot
                    if ($null -eq $watcherEvent) {
                        $state.LastChange = $now
                        $state.PendingChange = $true

                        $msg = "Change detected in folder: $folder [snapshot-diff]"
                        Write-RunnerLog -LogDir $LogDir -Message $msg
                        Write-ShellMessage -Message $msg -IsSilent $IsSilent
                    }
                }

                if (-not $state.PendingChange) {
                    continue
                }

                $secsIdle = ($now - $state.LastChange).TotalSeconds
                if ($secsIdle -lt $IdleTimeSeconds) {
                    continue
                }

                # ==============================================================
                # IDLE TIME REACHED: Process queued file jobs NOW
                # ==============================================================
                # Files were queued immediately when detected, but jobs execute here
                # This keeps responsiveness (files queued fast) but prevents constant triggering
                
                $jobsProcessed = 0
                $folderQueue = $null
                if ($watcherSync.FileJobQueues.ContainsKey($folder)) {
                    $folderQueue = $watcherSync.FileJobQueues[$folder]
                }

                # Optimisation: Batch file job executions by jobName to prevent N full-folder syncs
                $batchedFileJobs = @{}
                while ($null -ne $folderQueue -and $folderQueue.Count -gt 0) {
                    $fileJob = $folderQueue.Dequeue()
                    if ($null -eq $fileJob) { break }
                    
                    $jobName = $fileJob.JobName
                    if ([string]::IsNullOrWhiteSpace($jobName) -or $jobName -match '[<>:"|?*\\]') {
                        $watcherSync.ProcessingFilesLock.EnterWriteLock()
                        try { $watcherSync.ProcessingFiles.Remove($fileJob.FilePath) | Out-Null }
                        finally { $watcherSync.ProcessingFilesLock.ExitWriteLock() }
                        continue
                    }
                    if ($null -eq $batchedFileJobs[$jobName]) { 
                        $batchedFileJobs[$jobName] = [System.Collections.Generic.List[object]]::new()
                    }
                    $batchedFileJobs[$jobName].Add($fileJob)
                }

                foreach ($jobName in $batchedFileJobs.Keys) {
                    $fileJobs = $batchedFileJobs[$jobName]
                    Write-RunnerLog -LogDir $LogDir -Message "Processing $($fileJobs.Count) file jobs for $jobName (idle-triggered)"
                    
                    $jobStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $jobExitCode = $null
                    $jobResult = 'unknown'
                    $jobError = ''
                    
                    try {
                        & $PSCommandPath -JobName $jobName -ConfigPath $ConfigPath -DryRun:$DryRun -Silent:$IsSilent -WaitForNetwork:$WaitForNetwork -NotifyOnEvents:$NotifyOnEvents -ErrorAction SilentlyContinue
                        $jobExitCode = $LASTEXITCODE
                        if ($null -eq $jobExitCode) { $jobExitCode = if ($?) { 0 } else { 1 } }
                        $jobResult = if ($jobExitCode -eq 0) { 'success' } else { 'failed' }
                    }
                    catch {
                        $jobResult = 'error'
                        $jobExitCode = 1
                        $jobError = $_.Exception.Message
                        Write-RunnerLog -LogDir $LogDir -Message "Error batch-executing file jobs for '$jobName': $_"
                        Write-RunnerErrorLog -LogDir $LogDir -Message "Error batch-executing file jobs for '$jobName': $_"
                    }
                    finally {
                        $jobStopwatch.Stop()
                        $avgDurationSec = [math]::Round($jobStopwatch.Elapsed.TotalSeconds / $fileJobs.Count, 2)
                        
                        foreach ($fj in $fileJobs) {
                            $jobsProcessed++
                            $fp = $fj.FilePath
                            
                            $resultMsg = "[FILE JOB RESULT] name=$jobName filepath=$fp result=$jobResult exitcode=$jobExitCode duration_sec=$avgDurationSec"
                            if (-not [string]::IsNullOrWhiteSpace($jobError)) { $resultMsg += " error=$jobError" }
                            Write-RunnerLog -LogDir $LogDir -Message $resultMsg
                            
                            $watcherSync.ProcessingFilesLock.EnterWriteLock()
                            try { $watcherSync.ProcessingFiles.Remove($fp) | Out-Null }
                            finally { $watcherSync.ProcessingFilesLock.ExitWriteLock() }
                        }
                    }
                }
                
                # Log if file jobs were processed
                if ($jobsProcessed -gt 0) {
                    Write-RunnerLog -LogDir $LogDir -Message "Processed $jobsProcessed file job(s) after reaching idle time"
                }

                $jobs = @($folderJobMap[$folder] | Select-Object -Unique)
                if ($jobs.Count -eq 0) {
                    continue
                }
                
                $msg = "Idle time reached for changed folder: $folder. Triggering jobs: $($jobs -join ', ')"
                Write-RunnerLog -LogDir $LogDir -Message $msg
                Write-ShellMessage -Message $msg -IsSilent $IsSilent

                # Prevent repeat triggers until a new change is detected
                $state.PendingChange = $false
                $state.LastChange = $now

                foreach ($jobName in $jobs) {
                    # Security: Validate job name
                    if ([string]::IsNullOrWhiteSpace($jobName) -or $jobName -match '[<>:"|?*\\]') {
                        Write-RunnerLog -LogDir $LogDir -Message "Warning: Invalid job name: $jobName"
                        continue
                    }
                    
                    $msg = "Executing job: $jobName (triggered by folder: $folder)"
                    Write-RunnerLog -LogDir $LogDir -Message $msg
                    Write-ShellMessage -Message $msg -IsSilent $IsSilent

                    $jobStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $jobExitCode = $null
                    $jobResult = 'unknown'
                    $jobError = ''

                    # Set job execution marker (instead of releasing mutex)
                    $jobExecutionMarker = Join-Path $logDir ".job_execution_$jobName"
                    try {
                        $null = New-Item -ItemType File -Path $jobExecutionMarker -Force
                    }
                    catch {
                        Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to create job execution marker: $_"
                    }
                    
                    try {
                        # Run job via recursive call (mutex stays held to prevent duplicate monitors)
                        & $PSCommandPath -JobName $jobName -ConfigPath $ConfigPath -DryRun:$DryRun -Silent:$IsSilent -WaitForNetwork:$WaitForNetwork -NotifyOnEvents:$NotifyOnEvents -ErrorAction SilentlyContinue
                        $jobExitCode = $LASTEXITCODE
                        if ($null -eq $jobExitCode) {
                            $jobExitCode = if ($?) { 0 } else { 1 }
                        }
                        $jobResult = if ($jobExitCode -eq 0) { 'success' } else { 'failed' }
                    }
                    catch {
                        $jobResult = 'error'
                        $jobExitCode = 1
                        $jobError = $_.Exception.Message
                        Write-RunnerLog -LogDir $LogDir -Message "Error executing job '$jobName': $_"
                        Write-RunnerErrorLog -LogDir $LogDir -Message "Error executing job '$jobName': $_"
                    }
                    finally {
                        $jobStopwatch.Stop()
                        $jobDurationSec = [math]::Round($jobStopwatch.Elapsed.TotalSeconds, 2)
                        $resultMsg = "[JOB RESULT] name=$jobName result=$jobResult exitcode=$jobExitCode duration_sec=$jobDurationSec trigger_folder=$folder"
                        if (-not [string]::IsNullOrWhiteSpace($jobError)) {
                            $resultMsg = "$resultMsg error=$jobError"
                        }
                        Write-RunnerLog -LogDir $LogDir -Message $resultMsg
                        if ($jobResult -ne 'success') {
                            Write-RunnerErrorLog -LogDir $LogDir -Message $resultMsg
                            # Mark folder as failed sync for restart detection
                            foreach ($j in $jobs) {
                                $folderSyncStatus[$j] = 'failed'
                            }
                        } else {
                            # Save snapshot after successful job execution
                            # This ensures change detection works reliably on restart
                            # Critical for Task Scheduler's forceful termination scenario
                            # Track sync success status per folder for restart detection
                            foreach ($j in $jobs) {
                                $folderSyncStatus[$j] = 'success'
                            }
                            Save-FolderSnapshots -FolderState $folderState -ProjectRoot $ProjectRoot -LogDir $LogDir -SyncStatus $folderSyncStatus
                            $lastSuccessfulSnapshotTime = Get-Date
                            Write-RunnerLog -LogDir $LogDir -Message "Snapshot saved after successful job execution (folder marked as synced)"
                        }

                        # Clean up job execution marker
                        try {
                            Remove-Item -LiteralPath $jobExecutionMarker -Force -ErrorAction SilentlyContinue
                        }
                        catch {
                            Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to remove job execution marker: $_"
                        }
                    }
                }
            }
        }
    }
    finally {
        # Save final snapshots before stopping
        Save-FolderSnapshots -FolderState $folderState -ProjectRoot $ProjectRoot -LogDir $LogDir -SyncStatus $folderSyncStatus
        
        foreach ($folderPath in @($watchers.Keys)) {
            Remove-FolderWatcher -FolderPath $folderPath -Watchers $watchers -LogDir $LogDir
        }

        $msg = "Folder monitoring stopped. Final snapshots saved for change detection on next start."
        Write-RunnerLog -LogDir $LogDir -Message $msg
    }
}

try {
    $logDir = Join-Path $projectRoot 'logs'
    
    # Create logs directory - ensure it exists without throwing errors
    try {
        $null = New-Item -ItemType Directory -Force -Path $logDir -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "[ERROR] Failed to create logs directory at $logDir : $_" -ForegroundColor Red
        Write-Host "[ERROR] Cannot proceed without logs directory. Exiting." -ForegroundColor Red
        exit 1
    }

    # Check internet connectivity first
    if ($WaitForNetwork) {
        Write-RunnerLog -LogDir $logDir -Message 'WaitForNetwork enabled. Polling until internet connectivity is available.'
        Write-Host '[INFO] Waiting for internet connectivity before starting run...' -ForegroundColor Cyan
        Wait-ForInternetConnectivity -LogDir $logDir
    }
    elseif (-not (Test-InternetConnectivity)) {
        $msg = 'No internet connectivity detected. Backup operations require internet access. Exiting.'
        Write-RunnerLog -LogDir $logDir -Message $msg
        Write-Host "[ERROR] $msg" -ForegroundColor Red
        exit 1
    }

    if (-not $mutex.WaitOne(0)) {
        $activeMsg = 'Another runner instance is already active. Exiting.'
        Write-RunnerLog -LogDir $logDir -Message $activeMsg
        Write-ShellMessage -Message $activeMsg -IsSilent $Silent
        Show-EventNotification -Title 'Nexus Sync' -Message $activeMsg -Enabled:$NotifyOnEvents
        
        # Check if this might be a stale lock from a crashed instance
        # If the other instance appears to be hung, Task Scheduler will eventually timeout and retry
        Write-RunnerLog -LogDir $logDir -Message 'Duplicate launch detected. This is normal if another instance is running. Exiting in 1 second.'
        Start-Sleep -Seconds 1
        exit 0
    }
    $ownsMutex = $true

    $isRootMonitorLaunch = ($Monitor -and [string]::IsNullOrWhiteSpace($JobName) -and [string]::IsNullOrWhiteSpace($SourceFolder))
    if ($isRootMonitorLaunch) {
        Save-RunnerLogsToArchive -LogDir $logDir
    }
    Write-RunnerSessionSeparator -LogDir $logDir

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    try {
        $cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
    }
    catch {
        throw "Config file is not valid JSON: $ConfigPath"
    }

    # Check if HealthCheck mode is enabled
    if ($HealthCheck) {
        $healthStatus = Get-HealthCheckStatus -ConfigPath $ConfigPath -LogDir $logDir
        $jsonOutput = $healthStatus | ConvertTo-Json
        Write-Host $jsonOutput
        exit 0
    }

    # Check if Monitor mode is enabled
    if ($Monitor) {
        Write-ShellMessage -Message "Starting folder monitoring mode..." -IsSilent $Silent
        Write-ShellMessage -Message "Running preflight validation..." -IsSilent $Silent
        
        try {
            Test-PreflightRequirements -Config $cfg -LogDir $logDir -IsSilent $Silent -NotifyOnEvents $NotifyOnEvents
        }
        catch {
            $msg = "Preflight validation failed: $_"
            Write-RunnerLog -LogDir $logDir -Message $msg
            Write-Host "[ERROR] $msg" -ForegroundColor Red
            exit 1
        }
        
        Start-FolderMonitoring -Config $cfg -ProjectRoot $projectRoot -LogDir $logDir -IsSilent $Silent -ConfigPath $ConfigPath -DryRun $DryRun -IdleTimeSeconds $IdleTimeSeconds -Mutex $mutex -InitialSync $InitialSync
        exit 0
    }

    if (-not $cfg.jobs) {
        throw 'No jobs found in config.'
    }

    $rcloneExe = Resolve-RcloneExe
    $settings = Get-ConfigProperty -Object $cfg -Name 'settings'
    $profiles = Get-ConfigProperty -Object $cfg -Name 'profiles'
    $defaultExtraArgs = ConvertTo-StringArray -Value (Get-ConfigProperty -Object $settings -Name 'defaultExtraArgs') -FieldName 'settings.defaultExtraArgs'
    $defaultLogRetentionCount = ConvertTo-PositiveInt -Value (Get-ConfigProperty -Object $settings -Name 'logRetentionCount') -FieldName 'settings.logRetentionCount' -DefaultValue 10
    $globalJobInterval = ConvertTo-PositiveInt -Value (Get-ConfigProperty -Object $settings -Name 'jobIntervalSeconds') -FieldName 'settings.jobIntervalSeconds' -DefaultValue 0

    $continueOnJobError = $true
    $cfgContinueOnJobError = Get-ConfigProperty -Object $settings -Name 'continueOnJobError'
    if ($cfgContinueOnJobError -is [bool]) {
        $continueOnJobError = $cfgContinueOnJobError
    }

    $jobs = @($cfg.jobs | Where-Object { $_.enabled -ne $false })
    if ($JobName) {
        $jobs = @($jobs | Where-Object { $_.name -eq $JobName })
    }
    elseif ($SourceFolder) {
        # Resolve full path for comparison (handles relative paths and symlinks)
        $resolvedSourceFolder = (Resolve-Path -Path $SourceFolder -ErrorAction SilentlyContinue).ProviderPath
        if ([string]::IsNullOrWhiteSpace($resolvedSourceFolder)) {
            throw "Source folder '$SourceFolder' not found or not accessible."
        }
        $jobs = @($jobs | Where-Object { 
            $jobSource = [string](Get-ConfigProperty -Object $_ -Name 'source')
            if ([string]::IsNullOrWhiteSpace($jobSource)) { return $false }
            $resolvedJobSource = (Resolve-Path -Path $jobSource -ErrorAction SilentlyContinue).ProviderPath
            $resolvedSourceFolder -eq $resolvedJobSource
        })
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
        $allJobNames = @($cfg.jobs | Where-Object { $_.enabled -ne $false } | ForEach-Object { $_.name })
        if ($JobName) {
            $jobList = $allJobNames -join ', '
            $msg = "Job '$JobName' not found. Available jobs: $jobList"
        }
        elseif ($SourceFolder) {
            $msg = "No enabled jobs matched source folder '$SourceFolder'."
        }
        else {
            $msg = "No enabled jobs found in configuration."
        }
        Write-RunnerLog -LogDir $logDir -Message $msg
        Write-Host "[ERROR] $msg" -ForegroundColor Red
        exit 1
    }

    # Preflight validation before executing jobs
    Write-ShellMessage -Message "Validating job configuration and remote connectivity..." -IsSilent $Silent
    try {
        Test-PreflightRequirements -Config $cfg -LogDir $logDir -IsSilent $Silent -NotifyOnEvents $NotifyOnEvents
    }
    catch {
        $msg = "Job execution aborted - Preflight validation failed: $_"
        Write-RunnerLog -LogDir $logDir -Message $msg
        Write-Host "[ERROR] $msg" -ForegroundColor Red
        exit 1
    }

    for ($jobIndex = 0; $jobIndex -lt $jobs.Count; $jobIndex++) {
        $job = $jobs[$jobIndex]
        
        # Add interval between jobs (except before the first job)
        if ($jobIndex -gt 0) {
            $prevJob = $jobs[$jobIndex - 1]
            $prevJobName = [string](Get-ConfigProperty -Object $prevJob -Name 'name')
            $jobInterval = ConvertTo-PositiveInt -Value (Get-ConfigProperty -Object $prevJob -Name 'interval') -FieldName "jobs.$prevJobName.interval" -DefaultValue $globalJobInterval
            if ($jobInterval -gt 0) {
                $msg = "Waiting ${jobInterval}s before next job..."
                Write-RunnerLog -LogDir $logDir -Message $msg
                Write-ShellMessage -Message $msg -IsSilent $Silent
                Start-Sleep -Seconds $jobInterval
            }
        }
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
            if ($jobLogRetentionCount -gt 10) {
                $jobLogRetentionCount = 10
            }
            Remove-OldJobLog -JobLogDir $jobLogDir -KeepCount $jobLogRetentionCount
            $logMsg = "Job log file: $jobLog"
            Write-RunnerLog -LogDir $LogDir -Message $logMsg
            Write-ShellMessage -Message $logMsg -IsSilent $IsSilent

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

            $isRateLimited = Test-RateLimitError -LogFile $jobLog
            $isNetworkInterrupted = ((-not (Test-InternetConnectivity)) -or (Test-NetworkInterruptionError -LogFile $jobLog))

            if ($exitCode -ne 0 -and $isNetworkInterrupted -and -not $DryRun) {
                $netMsg = "[$name] Network interruption detected mid-sync. Waiting for reconnection and retrying once."
                Write-JobLog -LogFile $jobLog -Message $netMsg
                Write-RunnerLog -LogDir $logDir -Message $netMsg
                Write-ShellMessage -Message $netMsg -IsSilent $Silent
                Show-EventNotification -Title 'Nexus Sync Network Interrupt' -Message "$name lost connectivity during sync. Waiting to retry." -Enabled:$NotifyOnEvents

                Wait-ForInternetConnectivity -LogDir $logDir -RetryIntervalSeconds 20

                Write-JobLog -LogFile $jobLog -Message 'RETRY after connectivity restored'
                $exitCode = Invoke-RcloneLive -ExePath $rcloneExe -Arguments $rcloneArgs -LogFile $jobLog -IsSilent $Silent
                $isRateLimited = Test-RateLimitError -LogFile $jobLog

                if ($exitCode -eq 0) {
                    $recoveredMsg = "[$name] Sync recovered successfully after network interruption."
                    Write-JobLog -LogFile $jobLog -Message $recoveredMsg
                    Write-RunnerLog -LogDir $logDir -Message $recoveredMsg
                    Write-ShellMessage -Message $recoveredMsg -IsSilent $Silent
                    Show-EventNotification -Title 'Nexus Sync Recovered' -Message "$name resumed after reconnecting to network." -Enabled:$NotifyOnEvents
                }
            }

            if ($exitCode -eq 0) {
                Write-JobLog -LogFile $jobLog -Message 'DONE exitcode=0'
                Write-ShellMessage -Message "[$name] DONE exitcode=0" -IsSilent $Silent
            }
            else {
                $rateLimitMsg = if ($isRateLimited) { ' (rate limited)' } else { '' }
                Write-JobLog -LogFile $jobLog -Message "FAILED exitcode=$exitCode$rateLimitMsg"
                Write-ShellMessage -Message "[$name] FAILED exitcode=$exitCode$rateLimitMsg" -IsSilent $Silent
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
                $fallbackMsg = "Job log file: $jobLog"
                Write-RunnerLog -LogDir $LogDir -Message $fallbackMsg
                Write-ShellMessage -Message $fallbackMsg -IsSilent $IsSilent
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
    $errLogDir = Join-Path $projectRoot 'logs'
    New-Item -ItemType Directory -Force -Path $errLogDir | Out-Null
    $errLog = Join-Path $errLogDir 'runner-error.log'
    Add-Content -LiteralPath $errLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $($_.Exception.Message)"
    Write-Host "ERROR CAUGHT: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Exiting with code 1" -ForegroundColor Red
    exit 1
}
finally {
    # Clean up threading resources
    try {
        if ($ownsMutex) {
            $mutex.ReleaseMutex() | Out-Null
        }
    } catch { }
    finally {
        try { $mutex.Dispose() } catch { }
    }
    
    # Dispose ReaderWriterLockSlim if it was created
    try { $watcherSync.ProcessingFilesLock.Dispose() } catch { }
}