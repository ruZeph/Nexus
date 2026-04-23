param (
    [switch]$TestMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BasePath              = $PSScriptRoot
$LogDir                = Join-Path $BasePath 'logs'
$ArchiveRoot           = Join-Path $LogDir 'old_logs'
$ArchiveDir            = Join-Path $ArchiveRoot (Get-Date -Format 'yyyy-MM-dd')
$LogFile               = Join-Path $LogDir 'runner.log'
$ErrorLogFile          = Join-Path $LogDir 'runner-error.log'
$StateDir              = Join-Path $BasePath '.state'
$StateFile             = Join-Path $StateDir 'trigger-state.json'
$RuntimeStateFile      = Join-Path $StateDir 'runtime-state.json'
$EnvFilePath           = Join-Path $BasePath '.env'
$StopSignalFile        = Join-Path $BasePath '.stop-livebackup'
$ToolsDir              = Join-Path $BasePath 'tools'
$DetectionModule       = Join-Path $ToolsDir 'Process-Detection.ps1'
$OperationModule       = Join-Path $ToolsDir 'Backrest-Operation.ps1'
$BackrestConfigPath    = Join-Path $env:APPDATA 'backrest\config.json'
$BackrestEndpoint      = if ($env:BACKREST_ENDPOINT) { $env:BACKREST_ENDPOINT } else { 'http://localhost:9900/v1.Backrest/Backup' }
$MaxLogSizeMB          = 5
$ArchiveDays           = 30
$IdleTimeSeconds       = if ($TestMode) { 10 } else { 30000 }
$LoopSleepMilliseconds = if ($TestMode) { 1000 } else { 2000 }
$ResourceLogInterval   = 60
$StateFlushInterval    = 2
$RuntimeFlushInterval  = 5

$global:IsTestMode = [bool]$TestMode
$global:IdleTimeSeconds = $IdleTimeSeconds
$global:MonitorStartedAt = Get-Date
$global:PlanState = [hashtable]::Synchronized(@{})
$global:ResourceState = @{}
$global:MonitorControl = [hashtable]::Synchronized(@{
    InstanceId             = [guid]::NewGuid().ToString()
    StateDirty             = $false
    RuntimeDirty           = $true
    LastStateFlush         = [datetime]::MinValue
    LastRuntimeFlush       = [datetime]::MinValue
    LastSuccessfulDispatch = $null
    ShutdownRequested      = $false
    MutexName              = $null
})

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

function Invoke-LogRotation {
    if ($global:IsTestMode) { return }
    if (-not (Test-Path -LiteralPath $LogFile)) { return }

    try {
        $logFileInfo = Get-Item -LiteralPath $LogFile -ErrorAction Stop
        if (($logFileInfo.Length / 1MB) -le $MaxLogSizeMB) { return }

        $timestamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
        $archivePath = Join-Path $ArchiveDir "runner_$timestamp.log"
        Move-Item -LiteralPath $LogFile -Destination $archivePath -Force

        Get-ChildItem -LiteralPath $ArchiveDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$ArchiveDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [WARN] Failed to rotate log file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Invoke-StartupLogArchive {
    if (-not (Test-Path -LiteralPath $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }

    $timestamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
    foreach ($path in @($LogFile, $ErrorLogFile)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }

        try {
            $info = Get-Item -LiteralPath $path -ErrorAction Stop
            if ($info.Length -gt 0) {
                $baseName = [IO.Path]::GetFileNameWithoutExtension($path)
                Move-Item -LiteralPath $path -Destination (Join-Path $ArchiveDir "$baseName`_$timestamp.log") -Force
            }
            else {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [WARN] Failed to archive old logs: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    try {
        Get-ChildItem -LiteralPath $ArchiveDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$ArchiveDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [WARN] Failed archive retention cleanup: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-SessionSeparator {
    $separator = '............................................................'
    foreach ($path in @($LogFile, $ErrorLogFile)) {
        try {
            [System.IO.File]::AppendAllText($path, "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $separator`n")
        }
        catch {
        }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [ConsoleColor]$Color = 'White',
        [string]$Component = 'System'
    )

    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $pidPad = $PID.ToString().PadRight(5)
    $logLine = "[$ts] [PID:$pidPad] [$Level] [$Component] $Message"

    Write-Host $logLine -ForegroundColor $(if ($global:IsTestMode) { 'Gray' } else { $Color })

    $attempts = 0
    while ($attempts -lt 3) {
        try {
            [System.IO.File]::AppendAllText($LogFile, "$logLine`n")
            if ($Level -match '^(ERROR|WARN)$') {
                [System.IO.File]::AppendAllText($ErrorLogFile, "$logLine`n")
            }
            return
        }
        catch {
            $attempts++
            if ($attempts -lt 3) {
                Start-Sleep -Milliseconds (50 * $attempts)
            }
        }
    }
}

function Write-ResourceLog {
    param(
        [hashtable]$State = @{},
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

        Write-Log "[RESOURCE] context=$Context pid=$PID cpu_pct=$cpuPct working_set_mb=$workingMb private_mb=$privateMb handles=$handles threads=$threads" 'INFO' 'DarkGray' 'Resources'

        $warnings = @()
        if ($cpuPct -ge 80) { $warnings += "cpu_pct=$cpuPct>=80" }
        if ($privateMb -ge 250) { $warnings += "private_mb=$privateMb>=250" }
        if ($workingMb -ge 220) { $warnings += "working_set_mb=$workingMb>=220" }
        if ($handles -ge 2000) { $warnings += "handles=$handles>=2000" }
        if ($threads -ge 100) { $warnings += "threads=$threads>=100" }

        if ($warnings.Count -gt 0) {
            Write-Log "[RESOURCE WARN] context=$Context $($warnings -join ' ')" 'WARN' 'Yellow' 'Resources'
        }

        $State.LastSampleTime = $now
        $State.LastCpuSeconds = $cpuTotalSec
    }
    catch {
    }
}

function ConvertTo-IsoString {
    param($Value)
    if ($null -eq $Value) { return $null }
    if (-not ($Value -is [datetime])) { return [string]$Value }
    return $Value.ToString('o')
}

function ConvertFrom-DateValue {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }

    $parsed = $null
    if ([datetime]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data,
        [int]$Depth = 8
    )

    $json = $Data | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-PendingEventTypeSnapshot {
    param([hashtable]$EventTypes)

    $copy = @{}
    foreach ($key in @($EventTypes.Keys | Sort-Object)) {
        $copy[$key] = [int]$EventTypes[$key]
    }
    return $copy
}

function Get-PersistedPlanStateSnapshot {
    $plans = @{}

    foreach ($planId in @($global:PlanState.Keys | Sort-Object)) {
        $state = $global:PlanState[$planId]
        $plans[$planId] = @{
            Name                = $state.Name
            LastChange          = ConvertTo-IsoString $state.LastChange
            EventCount          = [int]$state.EventCount
            BatchNumber         = [int]$state.BatchNumber
            CurrentBatchId      = $state.CurrentBatchId
            QueueLogged         = [bool]$state.QueueLogged
            LastRun             = $state.LastRun
            LastQueuedAt        = ConvertTo-IsoString $state.LastQueuedAt
            LastBatchId         = $state.LastBatchId
            LastBatchEventCount = [int]$state.LastBatchEventCount
            LastDispatchStatus  = $state.LastDispatchStatus
            PendingPaths        = @($state.PendingPaths)
            PendingEventTypes   = Get-PendingEventTypeSnapshot -EventTypes $state.PendingEventTypes
        }
    }

    return @{
        Metadata = @{
            UpdatedAt  = (Get-Date).ToString('o')
            InstanceId = $global:MonitorControl.InstanceId
            ProcessId  = $PID
            TestMode   = $global:IsTestMode
        }
        Plans = $plans
    }
}

function Save-TriggerState {
    try {
        Write-JsonFile -Path $StateFile -Data (Get-PersistedPlanStateSnapshot) -Depth 8
        $global:MonitorControl.StateDirty = $false
        $global:MonitorControl.LastStateFlush = Get-Date
    }
    catch {
        Write-Log "Failed to flush state to disk: $($_.Exception.Message)" 'WARN' 'Yellow' 'State'
    }
}

function Save-RuntimeState {
    param(
        [string]$Status = 'running',
        [switch]$Force
    )

    try {
        $payload = @{
            InstanceId             = $global:MonitorControl.InstanceId
            ProcessId              = $PID
            Status                 = $Status
            StartedAt              = $global:MonitorStartedAt.ToString('o')
            UpdatedAt              = (Get-Date).ToString('o')
            TestMode               = $global:IsTestMode
            MutexName              = $global:MonitorControl.MutexName
            LogFile                = $LogFile
            StateFile              = $StateFile
            StopSignalFile         = $StopSignalFile
            Plans                  = @($global:PlanState.Keys | Sort-Object)
            LastSuccessfulDispatch = $global:MonitorControl.LastSuccessfulDispatch
            ComputerName           = $env:COMPUTERNAME
            UserName               = $env:USERNAME
        }

        Write-JsonFile -Path $RuntimeStateFile -Data $payload -Depth 6
        $global:MonitorControl.RuntimeDirty = $false
        $global:MonitorControl.LastRuntimeFlush = Get-Date
    }
    catch {
        if ($Force) {
            Write-Log "Failed to write runtime heartbeat: $($_.Exception.Message)" 'WARN' 'Yellow' 'State'
        }
    }
}

function Set-StateDirty {
    $global:MonitorControl.StateDirty = $true
    $global:MonitorControl.RuntimeDirty = $true
}

function New-PlanRuntimeState {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [hashtable]$SavedState = @{}
    )

    $savedPlan = $null
    if ($SavedState.ContainsKey($Plan.id)) {
        $savedPlan = $SavedState[$Plan.id]
    }

    $pendingTypes = [hashtable]::Synchronized(@{})
    if ($null -ne $savedPlan -and $savedPlan.PendingEventTypes) {
        foreach ($key in @($savedPlan.PendingEventTypes.Keys)) {
            $pendingTypes[$key] = [int]$savedPlan.PendingEventTypes[$key]
        }
    }

    return [hashtable]::Synchronized(@{
        Name                = $Plan.name
        LastChange          = if ($null -ne $savedPlan) { ConvertFrom-DateValue $savedPlan.LastChange } else { $null }
        EventCount          = if ($null -ne $savedPlan -and $null -ne $savedPlan.EventCount) { [int]$savedPlan.EventCount } else { 0 }
        BatchNumber         = if ($null -ne $savedPlan -and $null -ne $savedPlan.BatchNumber) { [int]$savedPlan.BatchNumber } else { 0 }
        CurrentBatchId      = if ($null -ne $savedPlan) { $savedPlan.CurrentBatchId } else { $null }
        QueueLogged         = $false
        LastRun             = if ($null -ne $savedPlan) { $savedPlan.LastRun } else { $null }
        LastQueuedAt        = if ($null -ne $savedPlan) { ConvertFrom-DateValue $savedPlan.LastQueuedAt } else { $null }
        LastBatchId         = if ($null -ne $savedPlan) { $savedPlan.LastBatchId } else { $null }
        LastBatchEventCount = if ($null -ne $savedPlan -and $null -ne $savedPlan.LastBatchEventCount) { [int]$savedPlan.LastBatchEventCount } else { 0 }
        LastDispatchStatus  = if ($null -ne $savedPlan) { $savedPlan.LastDispatchStatus } else { $null }
        PendingPaths        = if ($null -ne $savedPlan -and $savedPlan.PendingPaths) { @($savedPlan.PendingPaths) } else { @() }
        PendingEventTypes   = $pendingTypes
    })
}

function Test-ShouldIgnorePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }

    $name = [IO.Path]::GetFileName($Path)
    if ([string]::IsNullOrWhiteSpace($name)) { return $true }

    if ($name -match '^(~|\.~)' -or $name -match '(?i)^(thumbs\.db|desktop\.ini|\.ds_store)$') { return $true }
    if ($name -match '(?i)\.(tmp|temp|bak|swp|swo|lock|part|partial|crdownload|download)$') { return $true }
    if ($Path -match '(?i)[\\/](\.git|node_modules\\\.cache|\$RECYCLE\.BIN)[\\/]') { return $true }

    return $false
}

function Get-SavedPlanState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return @{} }

    try {
        $savedPayload = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json -AsHashtable
        if ($savedPayload.ContainsKey('Plans')) {
            Write-Log 'Loaded previous trigger state from disk.' 'INFO' 'DarkGray' 'State'
            return $savedPayload.Plans
        }

        Write-Log 'Loaded legacy trigger state from disk.' 'INFO' 'DarkGray' 'State'
        return $savedPayload
    }
    catch {
        Write-Log 'Failed to parse state file. Starting fresh.' 'WARN' 'Yellow' 'State'
        return @{}
    }
}

function Read-StopSignalReason {
    if (-not (Test-Path -LiteralPath $StopSignalFile)) {
        return 'stop requested'
    }

    try {
        $content = Get-Content -LiteralPath $StopSignalFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) {
            return 'stop requested'
        }
        return ($content -replace '[\r\n]+', ' ').Trim()
    }
    catch {
        return 'stop requested'
    }
}

function ConvertFrom-UnixMilliseconds {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Value).ToLocalTime().DateTime
    }
    catch {
        return $null
    }
}

function Get-LatestBackrestOperation {
    param(
        [Parameter(Mandatory = $true)][string]$PlanId,
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [hashtable]$Headers = @{}
    )

    try {
        $uriRoot = $Endpoint -replace '/v1\.Backrest/Backup$', ''
        $selectorPayload = @{ selector = @{ planId = $PlanId } } | ConvertTo-Json -Compress
        $restParams = @{
            Uri         = "$uriRoot/v1.Backrest/GetOperations"
            Method      = 'Post'
            Body        = $selectorPayload
            ContentType = 'application/json'
            TimeoutSec  = 5
        }

        if ($Headers.Count -gt 0) {
            $restParams.Headers = $Headers
        }

        $response = Invoke-RestMethod @restParams
        $operations = @($response.operations)
        if ($operations.Count -eq 0) {
            return $null
        }

        return ($operations | Sort-Object {
            $startTime = ConvertFrom-UnixMilliseconds $_.unixTimeStartMs
            if ($null -eq $startTime) { return [datetime]::MinValue }
            return $startTime
        } -Descending | Select-Object -First 1)
    }
    catch {
        return $null
    }
}

function Wait-BackrestOperationObservation {
    param(
        [Parameter(Mandatory = $true)][string]$PlanId,
        [Parameter(Mandatory = $true)][datetime]$Since,
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [hashtable]$Headers = @{},
        [int]$TimeoutSeconds = 1800,
        [int]$PollIntervalSeconds = 5
    )

    return Wait-BackrestOperationFinalStatus `
        -OperationFetcher {
            param(
                [Parameter(Mandatory = $true)][string]$PlanId,
                [Parameter(Mandatory = $true)][string]$Endpoint,
                [hashtable]$Headers = @{}
            )

            Get-LatestBackrestOperation -PlanId $PlanId -Endpoint $Endpoint -Headers $Headers
        } `
        -PlanId $PlanId `
        -Since $Since `
        -Endpoint $Endpoint `
        -Headers $Headers `
        -TimeoutSeconds $TimeoutSeconds `
        -PollIntervalSeconds $PollIntervalSeconds
}

if ($TestMode) {
    Write-Log 'TEST MODE ENABLED - API calls MOCKED. Idle timeout reduced.' 'INFO' 'Magenta' 'Preflight'
}

$DetectionLoaded = $false
if (Test-Path -LiteralPath $DetectionModule) {
    try {
        . $DetectionModule
        $DetectionLoaded = $true
    }
    catch {
    }
}

if (Test-Path -LiteralPath $OperationModule) {
    . $OperationModule
}

if (Test-Path -LiteralPath $StopSignalFile) {
    Remove-Item -LiteralPath $StopSignalFile -Force -ErrorAction SilentlyContinue
}

Invoke-StartupLogArchive
Invoke-LogRotation
Write-SessionSeparator

$watchers = @()
$subscriptions = @()
$mutex = $null
$mutexOwned = $false
$currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$safeUserSid = $currentUserSid -replace '[^A-Za-z0-9_-]', '_'
$projectDiscriminator = [System.IO.Path]::GetFileName($BasePath)
$mutexName = "Local\BackrestLiveMonitor_${safeUserSid}_$projectDiscriminator"
$global:MonitorControl.MutexName = $mutexName

try {
    if ($DetectionLoaded -and (Get-Command 'Test-WatcherIsRunning' -ErrorAction SilentlyContinue)) {
        try {
            $detection = Test-WatcherIsRunning `
                -LogFile $LogFile `
                -MutexName $mutexName `
                -HeartbeatFreshSeconds 180 `
                -RuntimeStateFile $RuntimeStateFile

            if ($detection.IsRunning -and $detection.Confidence -in @('high', 'medium')) {
                $pidStr = if ($null -ne $detection.ProcessId) { $detection.ProcessId } else { 'unknown' }
                $ageStr = if ($null -ne $detection.HeartbeatAge) { "$($detection.HeartbeatAge)s" } else { 'N/A' }
                Write-Log 'Another instance is already running (layered detection). Exiting to prevent overlapping watchers.' 'WARN' 'Yellow' 'Preflight'
                Write-Log "Watcher already running (PID: $pidStr, confidence: $($detection.Confidence)). Heartbeat age: $ageStr. Signals: $($detection.Signals.Values -join ', ')" 'WARN' 'Yellow' 'Detection'
                exit 0
            }

            Write-Log 'Layered detection confirms watcher is not running. Safe to proceed.' 'INFO' 'DarkGray' 'Detection'
        }
        catch {
            Write-Log "Detection layer encountered an error: $($_.Exception.Message). Falling back to Mutex guard." 'WARN' 'Yellow' 'Detection'
        }
    }

    $mutexCreated = $false
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)
    $mutexOwned = [bool]$mutexCreated

    if (-not $mutexOwned) {
        Write-Log 'Another instance is already running (Mutex held). Exiting to prevent overlapping watchers.' 'WARN' 'Yellow' 'Preflight'
        exit 0
    }

    $AuthHeader = @{}
    if (Test-Path -LiteralPath $EnvFilePath) {
        Get-Content -LiteralPath $EnvFilePath |
            Where-Object { $_ -match '^[^#]' -and $_ -match '=' } |
            ForEach-Object {
                $name, $value = $_ -split '=', 2
                Set-Item -Path "env:\$($name.Trim())" -Value $value.Trim()
            }

        if ($env:BACKREST_USER -and $env:BACKREST_PASS) {
            $authBytes = [System.Text.Encoding]::UTF8.GetBytes("$($env:BACKREST_USER):$($env:BACKREST_PASS)")
            $AuthHeader = @{ Authorization = "Basic $([Convert]::ToBase64String($authBytes))" }
            Write-Log 'Basic Authentication loaded from .env' 'INFO' 'Cyan' 'Preflight'
        }
    }
    else {
        Write-Log 'No .env file found. Proceeding without authentication.' 'INFO' 'DarkGray' 'Preflight'
    }

    if (-not (Test-Path -LiteralPath $BackrestConfigPath)) {
        Write-Log "Backrest config not found at $BackrestConfigPath. Is Backrest installed?" 'ERROR' 'Red' 'Preflight'
        exit 1
    }

    $config = Get-Content -LiteralPath $BackrestConfigPath -Raw | ConvertFrom-Json
    $plansRaw = $config.plans
    if (-not $plansRaw) {
        Write-Log 'No plans found in Backrest configuration.' 'WARN' 'Yellow' 'Preflight'
        exit 0
    }

    $plans = foreach ($p in @($plansRaw)) {
        if (-not $p.id) { continue }
        $hasName = $p.PSObject.Properties.Name -contains 'name'
        $hasPaths = $p.PSObject.Properties.Name -contains 'paths'
        [pscustomobject]@{
            id    = $p.id
            name  = if ($hasName -and -not [string]::IsNullOrWhiteSpace([string]$p.name)) { $p.name } else { $p.id }
            paths = if ($hasPaths -and $null -ne $p.paths) { @($p.paths) } else { @() }
        }
    }

    $savedState = Get-SavedPlanState

    foreach ($plan in $plans) {
        if (-not $plan.paths -or @($plan.paths).Count -eq 0) {
            Write-Log "Plan [$($plan.name)] has no source paths configured. Skipping." 'WARN' 'Yellow' $plan.name
            continue
        }

        $global:PlanState[$plan.id] = New-PlanRuntimeState -Plan $plan -SavedState $savedState

        if ($global:PlanState[$plan.id].EventCount -gt 0 -and $null -ne $global:PlanState[$plan.id].LastChange) {
            Write-Log "Recovered pending batch state for plan [$($plan.name)] with $($global:PlanState[$plan.id].EventCount) queued event(s)." 'INFO' 'DarkGray' $plan.name
        }

        foreach ($folder in $plan.paths) {
            if (-not (Test-Path -LiteralPath $folder)) {
                Write-Log "Path not found, bypassing: $folder" 'WARN' 'Yellow' $plan.name
                continue
            }

            $watcher = New-Object IO.FileSystemWatcher -ArgumentList $folder, '*'
            $watcher.IncludeSubdirectories = $true
            $watcher.InternalBufferSize = 65536
            $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, CreationTime, Size'

            $messageData = [pscustomobject]@{
                PlanId   = $plan.id
                PlanName = $plan.name
                ErrorLog = $ErrorLogFile
            }

            $action = {
                try {
                    $pfEventArgs = $Event.SourceEventArgs
                    $planId = [string]$Event.MessageData.PlanId
                    $planState = $global:PlanState[$planId]
                    if ($null -eq $planState) { return }

                    $fullPath = $pfEventArgs.FullPath
                    if ([string]::IsNullOrWhiteSpace([string]$fullPath)) {
                        $fullPath = $pfEventArgs.Name
                    }

                    $name = [IO.Path]::GetFileName([string]$fullPath)
                    if (
                        [string]::IsNullOrWhiteSpace([string]$name) -or
                        $name -match '^(~|\.~)' -or
                        $name -match '(?i)^(thumbs\.db|desktop\.ini|\.ds_store)$' -or
                        $name -match '(?i)\.(tmp|temp|bak|swp|swo|lock|part|partial|crdownload|download)$' -or
                        [string]$fullPath -match '(?i)[\\/](\.git|node_modules\\\.cache|\$RECYCLE\.BIN)[\\/]'
                    ) {
                        return
                    }

                    $eventTime = [datetime]::Now
                    if ([int]$planState.EventCount -eq 0) {
                        $planState.BatchNumber = [int]$planState.BatchNumber + 1
                        $planState.CurrentBatchId = '{0}-B{1:D4}' -f $planId, [int]$planState.BatchNumber
                        $planState.LastQueuedAt = $eventTime
                        $planState.QueueLogged = $false
                    }

                    $eventType = [string]$pfEventArgs.ChangeType
                    if ([string]::IsNullOrWhiteSpace($eventType)) { $eventType = 'Changed' }

                    $pendingPaths = @($planState.PendingPaths)
                    if ($pendingPaths -notcontains $fullPath -and $pendingPaths.Count -lt 10) {
                        $pendingPaths += $fullPath
                        $planState.PendingPaths = $pendingPaths
                    }

                    if (-not $planState.PendingEventTypes.ContainsKey($eventType)) {
                        $planState.PendingEventTypes[$eventType] = 0
                    }

                    $planState.PendingEventTypes[$eventType] = [int]$planState.PendingEventTypes[$eventType] + 1
                    $planState.LastChange = $eventTime
                    $planState.EventCount = [int]$planState.EventCount + 1
                    $global:MonitorControl.StateDirty = $true
                    $global:MonitorControl.RuntimeDirty = $true
                }
                catch {
                    try {
                        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        [System.IO.File]::AppendAllText([string]$Event.MessageData.ErrorLog, "[$ts] [EVENT ERROR] $($_.Exception.Message)`n")
                    }
                    catch {
                    }
                }
            }

            $errorAction = {
                try {
                    $planId = [string]$Event.MessageData.PlanId
                    $planState = $global:PlanState[$planId]
                    if ($null -eq $planState) { return }

                    $planState.LastChange = [datetime]::Now
                    $planState.EventCount = [int]$planState.EventCount + 100
                    $planState.LastDispatchStatus = 'buffer-overflow'
                    if ([int]$planState.EventCount -gt 0 -and [string]::IsNullOrWhiteSpace([string]$planState.CurrentBatchId)) {
                        $planState.BatchNumber = [int]$planState.BatchNumber + 1
                        $planState.CurrentBatchId = '{0}-B{1:D4}' -f $planId, [int]$planState.BatchNumber
                    }

                    Write-Log 'Watcher buffer overflow detected. Forcing queue update.' 'WARN' 'Red' $planState.Name
                    $global:MonitorControl.StateDirty = $true
                    $global:MonitorControl.RuntimeDirty = $true
                }
                catch {
                    try {
                        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        [System.IO.File]::AppendAllText([string]$Event.MessageData.ErrorLog, "[$ts] [EVENT ERROR] $($_.Exception.Message)`n")
                    }
                    catch {
                    }
                }
            }

            $subscriptions += Register-ObjectEvent -InputObject $watcher -EventName 'Changed' -Action $action -MessageData $messageData
            $subscriptions += Register-ObjectEvent -InputObject $watcher -EventName 'Created' -Action $action -MessageData $messageData
            $subscriptions += Register-ObjectEvent -InputObject $watcher -EventName 'Deleted' -Action $action -MessageData $messageData
            $subscriptions += Register-ObjectEvent -InputObject $watcher -EventName 'Renamed' -Action $action -MessageData $messageData
            $subscriptions += Register-ObjectEvent -InputObject $watcher -EventName 'Error'   -Action $errorAction -MessageData $messageData

            $watcher.EnableRaisingEvents = $true
            $watchers += $watcher
            Write-Log "Attached FileSystemWatcher: $folder" 'INFO' 'Cyan' $plan.name
        }
    }

    if ($watchers.Count -eq 0) {
        Write-Log 'No valid watcher paths were attached. Exiting.' 'WARN' 'Yellow' 'Preflight'
        exit 0
    }

    Save-TriggerState
    Save-RuntimeState -Status 'running' -Force
    Write-Log "[SESSION] instance=$($global:MonitorControl.InstanceId) mutex=$mutexName plans=$($global:PlanState.Count) loop_ms=$LoopSleepMilliseconds idle_s=$IdleTimeSeconds test_mode=$global:IsTestMode" 'INFO' 'DarkGray' 'System'
    Write-Log 'Waiting for idle bounds...' 'INFO' 'Green' 'System'

    $lastResourceLogTime = Get-Date

    while ($true) {
        if (Test-Path -LiteralPath $StopSignalFile) {
            $stopReason = Read-StopSignalReason
            Write-Log "Safe stop signal detected. Shutting down cleanly... Reason=[$stopReason]" 'INFO' 'Magenta' 'Manager'
            $global:MonitorControl.ShutdownRequested = $true
            Remove-Item -LiteralPath $StopSignalFile -Force -ErrorAction SilentlyContinue
            Set-StateDirty
            Save-TriggerState
            Save-RuntimeState -Status 'stopping' -Force
            break
        }

        Start-Sleep -Milliseconds $LoopSleepMilliseconds
        $now = Get-Date

        if (($now - $lastResourceLogTime).TotalSeconds -ge $ResourceLogInterval) {
            Write-ResourceLog -State $global:ResourceState -Context 'monitor-loop'
            $lastResourceLogTime = $now
        }

        foreach ($planId in @($global:PlanState.Keys)) {
            $state = $global:PlanState[$planId]
            $events = [int]$state.EventCount
            $lastChange = ConvertFrom-DateValue $state.LastChange
            $batchId = if ([string]::IsNullOrWhiteSpace([string]$state.CurrentBatchId)) { "${planId}-B0000" } else { $state.CurrentBatchId }

            if ($events -gt 0 -and -not [bool]$state.QueueLogged) {
                $eventTypeSummary = @($state.PendingEventTypes.Keys | Sort-Object | ForEach-Object { "$_=$($state.PendingEventTypes[$_])" }) -join ', '
                $pathSummary = if (@($state.PendingPaths).Count -gt 0) { @($state.PendingPaths) -join '; ' } else { 'path sample unavailable' }
                Write-Log "Coalesced events queued for [$planId]. BatchId=[$batchId] Count=$events Types=[$eventTypeSummary] Paths=[$pathSummary]" 'INFO' 'DarkGray' $state.Name
                $state.QueueLogged = $true
                Set-StateDirty
            }

            if ($null -eq $lastChange -or $events -le 0) { continue }
            if (($now - $lastChange).TotalSeconds -lt $IdleTimeSeconds) { continue }

            Write-Log "Batch flush: Triggering [$($state.Name)] covering $events coalesced event(s). BatchId=[$batchId]" 'INFO' 'Yellow' $state.Name

            $payload = @{ value = $planId } | ConvertTo-Json -Compress
            $apiSuccess = $false
            $requestStartedAt = Get-Date
            if ($global:IsTestMode) {
                Write-Log "API call MOCKED. Job skipped for batch [$batchId]." 'TEST' 'Magenta' $state.Name
                $apiSuccess = $true
            }
            else {
                $restParams = @{
                    Uri         = $BackrestEndpoint
                    Method      = 'Post'
                    Body        = $payload
                    ContentType = 'application/json'
                    TimeoutSec  = 600000
                }

                if ($AuthHeader.Count -gt 0) {
                    $restParams.Headers = $AuthHeader
                }

                try {
                    $apiResponse = Invoke-RestMethod @restParams
                    $responseJson = try { $apiResponse | ConvertTo-Json -Compress -Depth 5 } catch { '{}' }
                    Write-Log "Backrest accepted trigger request for batch [$batchId]. Response=[$responseJson]" 'INFO' 'Green' $state.Name
                    $apiSuccess = $true
                }
                catch {
                    $exceptionType = $_.Exception.GetType().Name
                    $exceptionMessage = $_.Exception.Message
                    $isTimeoutAccepted = ($exceptionType -eq 'WebException' -and $_.Exception.Status -eq 'Timeout') -or
                        ($exceptionType -eq 'TaskCanceledException') -or
                        ($exceptionType -eq 'HttpRequestException' -and $exceptionMessage -match 'Timeout')

                    if ($isTimeoutAccepted) {
                        Write-Log "Backrest trigger request timed out for batch [$batchId], but Backrest may continue it in the background." 'WARN' 'Yellow' $state.Name
                        $apiSuccess = $true
                    }
                    else {
                        $state.LastDispatchStatus = 'failed'
                        Write-Log "API dispatch failed for batch [$batchId]: $exceptionMessage" 'ERROR' 'Red' $state.Name
                        Set-StateDirty
                    }
                }
            }

            if (-not $apiSuccess) { continue }

            $dispatchOutcome = [pscustomobject]@{
                Operation = $null
                RawStatus = 'mocked'
                NormalizedStatus = 'mocked'
                Outcome = 'success'
            }

            if (-not $global:IsTestMode) {
                $dispatchOutcome = Wait-BackrestOperationObservation `
                    -PlanId $planId `
                    -Since $requestStartedAt `
                    -Endpoint $BackrestEndpoint `
                    -Headers $AuthHeader `
                    -TimeoutSeconds 1800 `
                    -PollIntervalSeconds 5

                if ($null -ne $dispatchOutcome) {
                    $operationId = if ($null -ne $dispatchOutcome.Operation.id) { $dispatchOutcome.Operation.id } else { 'unknown' }
                    $flowId = if ($null -ne $dispatchOutcome.Operation.flowId) { $dispatchOutcome.Operation.flowId } else { 'unknown' }
                    $operationStatus = if ($null -ne $dispatchOutcome.RawStatus) { $dispatchOutcome.RawStatus } else { 'unknown' }
                    Write-Log "Backrest operation reached terminal status for batch [$batchId]. OperationId=[$operationId] FlowId=[$flowId] Status=[$operationStatus] Outcome=[$($dispatchOutcome.Outcome)]" 'SUCCESS' 'Green' $state.Name
                }
                else {
                    Write-Log "Backrest accepted batch [$batchId], but no terminal operation status was observed within the wait window." 'WARN' 'Yellow' $state.Name
                }
            }
            else {
                Write-Log "Backrest terminal wait skipped in test mode for batch [$batchId]." 'TEST' 'Magenta' $state.Name
            }

            $state.LastBatchId = $batchId
            $state.LastBatchEventCount = $events
            $state.LastDispatchStatus = if ($null -eq $dispatchOutcome) { 'timeout' } elseif ($dispatchOutcome.Outcome -eq 'failed') { 'failed' } else { 'success' }
            $state.LastRun = $now.ToString('o')
            $state.LastChange = $null
            $state.LastQueuedAt = $null
            $state.EventCount = 0
            $state.CurrentBatchId = $null
            $state.QueueLogged = $false
            $state.PendingPaths = @()

            foreach ($key in @($state.PendingEventTypes.Keys)) {
                $state.PendingEventTypes.Remove($key)
            }

            if ($state.LastDispatchStatus -eq 'success') {
                $global:MonitorControl.LastSuccessfulDispatch = $state.LastRun
            }
            Set-StateDirty
            Save-TriggerState
            Save-RuntimeState -Status 'running'
        }

        if ($global:MonitorControl.StateDirty -and (($now - $global:MonitorControl.LastStateFlush).TotalSeconds -ge $StateFlushInterval)) {
            Save-TriggerState
        }

        if ($global:MonitorControl.RuntimeDirty -or (($now - $global:MonitorControl.LastRuntimeFlush).TotalSeconds -ge $RuntimeFlushInterval)) {
            Save-RuntimeState -Status 'running'
        }
    }
}
finally {
    Write-Log 'Releasing resources and unbinding watcher pool...' 'INFO' 'DarkGray' 'System'

    try {
        Set-StateDirty
        Save-TriggerState
    }
    catch {
    }

    try {
        Save-RuntimeState -Status 'stopped' -Force
    }
    catch {
    }

    foreach ($subscriber in @($subscriptions)) {
        try {
            Unregister-Event -SubscriptionId $subscriber.Id -ErrorAction SilentlyContinue
        }
        catch {
        }
    }

    foreach ($watcher in @($watchers)) {
        try {
            $watcher.EnableRaisingEvents = $false
            $watcher.Dispose()
        }
        catch {
        }
    }

    if ($null -ne $mutex -and $mutexOwned) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
        }
    }

    if ($null -ne $mutex) {
        try {
            $mutex.Dispose()
        }
        catch {
        }
    }

    Write-Log 'Shutdown complete.' 'INFO' 'DarkGray' 'System'
}
