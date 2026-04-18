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
    [ValidateSet('copy', 'sync')][string]$Operation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

$mutex = [System.Threading.Mutex]::new($false, 'Global\RcloneBackupRunner')
$ownsMutex = $false

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

function Write-RunnerErrorLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $runnerErrorLog = Join-Path $LogDir 'runner-error.log'
    Write-JobLog -LogFile $runnerErrorLog -Message $Message
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

        Write-RunnerLog -LogDir $LogDir -Message "[RESOURCE] context=$Context cpu_pct=$cpuPct working_set_mb=$workingMb private_mb=$privateMb handles=$handles threads=$threads"

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

function Wait-ForInternetConnectivity {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [int]$RetryIntervalSeconds = 30
    )

    while (-not (Test-InternetConnectivity)) {
        $msg = "No internet connectivity detected. Waiting $RetryIntervalSeconds seconds before retrying."
        Write-RunnerLog -LogDir $LogDir -Message $msg
        Write-Host "[INFO] $msg" -ForegroundColor Cyan
        Start-Sleep -Seconds $RetryIntervalSeconds
    }

    Write-RunnerLog -LogDir $LogDir -Message 'Internet connectivity detected. Continuing scheduled run.'
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

        # Fast hash: concatenate names and timestamps
        $signatureData = ($items | ForEach-Object { "$($_.Name)|$($_.LastWriteTimeUtc.Ticks)" }) -join '|'
        $hash = [System.Security.Cryptography.HashAlgorithm]::Create('MD5').ComputeHash([Text.Encoding]::UTF8.GetBytes($signatureData))
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

        $subs = @(
            (Register-ObjectEvent -InputObject $watcher -EventName Changed -MessageData $eventData -Action {
                $sync = $event.MessageData.WatcherSync
                $folder = [string]$event.MessageData.FolderPath
                $fileEvent = $event.SourceEventArgs
                if ($null -ne $sync -and -not [string]::IsNullOrWhiteSpace($folder)) {
                    $sync.ChangedFolders[$folder] = [pscustomobject]@{
                        Time = Get-Date
                        ChangeType = [string]$fileEvent.ChangeType
                        FullPath = [string]$fileEvent.FullPath
                        OldFullPath = ''
                    }
                }
            })
            (Register-ObjectEvent -InputObject $watcher -EventName Created -MessageData $eventData -Action {
                $sync = $event.MessageData.WatcherSync
                $folder = [string]$event.MessageData.FolderPath
                $fileEvent = $event.SourceEventArgs
                if ($null -ne $sync -and -not [string]::IsNullOrWhiteSpace($folder)) {
                    $sync.ChangedFolders[$folder] = [pscustomobject]@{
                        Time = Get-Date
                        ChangeType = [string]$fileEvent.ChangeType
                        FullPath = [string]$fileEvent.FullPath
                        OldFullPath = ''
                    }
                }
            })
            (Register-ObjectEvent -InputObject $watcher -EventName Deleted -MessageData $eventData -Action {
                $sync = $event.MessageData.WatcherSync
                $folder = [string]$event.MessageData.FolderPath
                $fileEvent = $event.SourceEventArgs
                if ($null -ne $sync -and -not [string]::IsNullOrWhiteSpace($folder)) {
                    $sync.ChangedFolders[$folder] = [pscustomobject]@{
                        Time = Get-Date
                        ChangeType = [string]$fileEvent.ChangeType
                        FullPath = [string]$fileEvent.FullPath
                        OldFullPath = ''
                    }
                }
            })
            (Register-ObjectEvent -InputObject $watcher -EventName Renamed -MessageData $eventData -Action {
                $sync = $event.MessageData.WatcherSync
                $folder = [string]$event.MessageData.FolderPath
                $fileEvent = $event.SourceEventArgs
                if ($null -ne $sync -and -not [string]::IsNullOrWhiteSpace($folder)) {
                    $sync.ChangedFolders[$folder] = [pscustomobject]@{
                        Time = Get-Date
                        ChangeType = [string]$fileEvent.ChangeType
                        FullPath = [string]$fileEvent.FullPath
                        OldFullPath = [string]$fileEvent.OldFullPath
                    }
                }
            })
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

function Start-FolderMonitoring {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [bool]$IsSilent = $false,
        [string]$ConfigPath = "",
        [bool]$DryRun = $false,
        [int]$IdleTimeSeconds = 60,
        [System.Threading.Mutex]$Mutex = $null
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
    $watcherSync = [hashtable]::Synchronized(@{ ChangedFolders = [hashtable]::Synchronized(@{}) })
    $resourceState = @{}
    $resourceLogInterval = 60
    $resourceLastLog = Get-Date

    # Track folder snapshots so only real content changes trigger jobs
    $folderState = @{}
    $configLastCheck = Get-Date
    $configCheckInterval = 30  # Check config every 30 seconds for changes
    $lastConfigModTime = (Get-Item -LiteralPath $ConfigPath -ErrorAction SilentlyContinue).LastWriteTime

    # Initialize baseline snapshots without triggering jobs on startup
    foreach ($folder in $watchedFolders) {
        $snapshot = Get-FolderSnapshotSignature -FolderPath $folder
        if ($snapshot -notin @('ERROR_ACCESS', 'ERROR_READ')) {
            $folderState[$folder] = [pscustomobject]@{
                Snapshot = $snapshot
                LastChange = $null
                PendingChange = $false
                ErrorCount = 0
            }
            Add-FolderWatcher -FolderPath $folder -Watchers $watchers -WatcherSync $watcherSync -LogDir $LogDir -IsSilent $IsSilent
        } else {
            Write-RunnerLog -LogDir $LogDir -Message "Warning: Cannot access folder initially: $folder"
        }
    }

    $msg = "Folder monitoring started. Watching $($watchedFolders.Count) folder(s) with ${IdleTimeSeconds}s idle time."
    Write-RunnerLog -LogDir $LogDir -Message $msg
    Write-ShellMessage -Message $msg -IsSilent $IsSilent
    Write-RunnerResourceLog -State $resourceState -LogDir $LogDir -Context 'monitor-start'

    try {
        while ($true) {
            Start-Sleep -Seconds 5
            $now = Get-Date

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
                        $lastConfigModTime = $currentModTime
                        $newConfig = Get-Content -Raw -LiteralPath $ConfigPath -ErrorAction Stop | ConvertFrom-Json
                        $mapping = @(
                            Update-FolderJobMapping -Config $newConfig -LogDir $LogDir -IsSilent $IsSilent -ExistingMap $folderJobMap
                        ) | Where-Object {
                            $_ -is [hashtable] -and $_.ContainsKey('JobMap') -and $_.ContainsKey('Folders')
                        } | Select-Object -Last 1

                        if ($null -eq $mapping) {
                            throw 'Failed to rebuild folder-job mapping from reloaded config.'
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
                if (-not (Test-Path -LiteralPath $folder -ErrorAction SilentlyContinue)) {
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
                    $watcherEvent = $watcherSync.ChangedFolders[$folder]
                    $state.LastChange = $now
                    $state.PendingChange = $true
                    $watcherSync.ChangedFolders.Remove($folder) | Out-Null

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

                    Write-RunnerLog -LogDir $LogDir -Message $msg
                    Write-ShellMessage -Message $msg -IsSilent $IsSilent
                }

                $currentSnapshot = Get-FolderSnapshotSignature -FolderPath $folder
                
                if ($currentSnapshot -in @('ERROR_ACCESS', 'ERROR_READ')) {
                    $state.ErrorCount++
                    if ($state.ErrorCount -ge 3) {
                        Write-RunnerLog -LogDir $LogDir -Message "Warning: Persistent access error: $folder"
                    }
                    continue
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

                    # Temporarily release mutex so job can acquire it
                    if ($null -ne $Mutex) {
                        try {
                            $Mutex.ReleaseMutex() | Out-Null
                        }
                        catch {
                            Write-RunnerLog -LogDir $LogDir -Message "Warning: Failed to release mutex: $_"
                        }
                    }
                    
                    try {
                        # Run job via recursive call
                        & $PSCommandPath -JobName $jobName -ConfigPath $ConfigPath -DryRun:$DryRun -Silent:$IsSilent -ErrorAction SilentlyContinue
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
                        }

                        # Re-acquire mutex for continued monitoring
                        if ($null -ne $Mutex) {
                            try {
                                $Mutex.WaitOne() | Out-Null
                            }
                            catch {
                                Write-RunnerLog -LogDir $LogDir -Message "Error: Failed to re-acquire mutex: $_"
                                throw "Critical: Lost mutex lock during monitoring"
                            }
                        }
                    }
                }
            }
        }
    }
    finally {
        foreach ($folderPath in @($watchers.Keys)) {
            Remove-FolderWatcher -FolderPath $folderPath -Watchers $watchers -LogDir $LogDir
        }

        $msg = "Folder monitoring stopped."
        Write-RunnerLog -LogDir $LogDir -Message $msg
    }
}

try {
    $logDir = Join-Path $projectRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

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
        Write-RunnerLog -LogDir $logDir -Message 'Another runner instance is already active. Exiting.'
        exit 0
    }
    $ownsMutex = $true
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

    # Check if Monitor mode is enabled
    if ($Monitor) {
        Write-ShellMessage -Message "Starting folder monitoring mode..." -IsSilent $Silent
        Start-FolderMonitoring -Config $cfg -LogDir $logDir -IsSilent $Silent -ConfigPath $ConfigPath -DryRun $DryRun -IdleTimeSeconds $IdleTimeSeconds -Mutex $mutex
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
            
            $isRateLimited = Test-RateLimitError -LogFile $jobLog

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
    throw
}
finally {
    if ($ownsMutex) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}