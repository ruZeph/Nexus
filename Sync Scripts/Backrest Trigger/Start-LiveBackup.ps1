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
$PlanStateFile         = Join-Path $StateDir 'plan-dispatch-state.json'   # persisted dispatch outcomes for restart detection
$EnvFilePath           = Join-Path $BasePath '.env'
$StopSignalFile        = Join-Path $BasePath '.stop-livebackup'
$ToolsDir              = Join-Path $BasePath 'tools'
$DetectionModule       = Join-Path $ToolsDir 'Process-Detection.ps1'
$OperationModule       = Join-Path $ToolsDir 'Backrest-Operation.ps1'
$BackrestConfigPath    = Join-Path $env:APPDATA 'backrest\config.json'
$BackrestEndpoint      = if ($env:BACKREST_ENDPOINT) { $env:BACKREST_ENDPOINT } else { 'http://localhost:9900/v1.Backrest/Backup' }
$MaxLogSizeMB          = 5
$ArchiveDays           = 30
$IdleTimeSeconds       = if ($TestMode) { 10 } else { 300 }
$LoopSleepMilliseconds = if ($TestMode) { 1000 } else { 2000 }
$ResourceLogInterval   = 60
$StateFlushInterval    = 2
$RuntimeFlushInterval  = 5

# Shared timestamp format used across all log and state writers in this script.
$global:TsFmt = 'yyyy-MM-dd HH:mm:ss'

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

foreach ($dir in @($LogDir, $ArchiveDir, $StateDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

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
        Write-Host "[$((Get-Date).ToString($global:TsFmt))] [WARN] Failed to rotate log file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Invoke-StartupLogArchive {
    # $ArchiveDir is guaranteed to exist from startup directory initialisation above.
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
            Write-Host "[$((Get-Date).ToString($global:TsFmt))] [WARN] Failed to archive old logs: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    try {
        Get-ChildItem -LiteralPath $ArchiveDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$ArchiveDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "[$((Get-Date).ToString($global:TsFmt))] [WARN] Failed archive retention cleanup: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-SessionSeparator {
    $separator = '............................................................'
    foreach ($path in @($LogFile, $ErrorLogFile)) {
        try {
            [System.IO.File]::AppendAllText($path, "[$((Get-Date).ToString($global:TsFmt))] $separator`n")
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

    $ts = (Get-Date).ToString($global:TsFmt)
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

function Resolve-StatusString {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        $s = $Value.Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        return $s
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @('LastDispatchStatus', 'status', 'Status', 'value', 'Value', 'RawStatus')) {
            if ($Value.Contains($key)) {
                $resolved = Resolve-StatusString -Value $Value[$key]
                if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                    return $resolved
                }
            }
        }

        return $null
    }

    try {
        foreach ($propertyName in @('LastDispatchStatus', 'status', 'Status', 'value', 'Value', 'RawStatus')) {
            $prop = $Value.PSObject.Properties[$propertyName]
            if ($null -eq $prop) { continue }

            $resolved = Resolve-StatusString -Value $prop.Value
            if (-not [string]::IsNullOrWhiteSpace([string]$resolved)) {
                return $resolved
            }
        }
    }
    catch {
    }

    return $null
}

function Get-SafeProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $Default
    }

    try {
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -ne $prop) {
            return $prop.Value
        }
    }
    catch {
    }

    return $Default
}

function ConvertTo-PrettyJsonString {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [int]$IndentSize = 2
    )

    $sb = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $escaping = $false

    for ($i = 0; $i -lt $Json.Length; $i++) {
        $ch = [string]$Json[$i]

        if ($inString) {
            [void]$sb.Append($ch)

            if ($escaping) {
                $escaping = $false
                continue
            }

            if ($ch -eq '\\') {
                $escaping = $true
            }
            elseif ($ch -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($ch -match '\s') {
            continue
        }

        switch ($ch) {
            '"' {
                $inString = $true
                [void]$sb.Append($ch)
            }
            '{' {
                if (($i + 1) -lt $Json.Length -and [string]$Json[$i + 1] -eq '}') {
                    [void]$sb.Append('{}')
                    $i++
                    continue
                }

                [void]$sb.Append('{')
                [void]$sb.AppendLine()
                $indent++
                [void]$sb.Append((' ' * ($indent * $IndentSize)))
            }
            '[' {
                if (($i + 1) -lt $Json.Length -and [string]$Json[$i + 1] -eq ']') {
                    [void]$sb.Append('[]')
                    $i++
                    continue
                }

                [void]$sb.Append('[')
                [void]$sb.AppendLine()
                $indent++
                [void]$sb.Append((' ' * ($indent * $IndentSize)))
            }
            '}' {
                [void]$sb.AppendLine()
                $indent = [Math]::Max(0, $indent - 1)
                [void]$sb.Append((' ' * ($indent * $IndentSize)))
                [void]$sb.Append('}')
            }
            ']' {
                [void]$sb.AppendLine()
                $indent = [Math]::Max(0, $indent - 1)
                [void]$sb.Append((' ' * ($indent * $IndentSize)))
                [void]$sb.Append(']')
            }
            ',' {
                [void]$sb.Append(',')
                [void]$sb.AppendLine()
                [void]$sb.Append((' ' * ($indent * $IndentSize)))
            }
            ':' {
                [void]$sb.Append(': ')
            }
            default {
                [void]$sb.Append($ch)
            }
        }
    }

    return ($sb.ToString().TrimEnd())
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data,
        [int]$Depth = 8
    )

    $compactJson = $Data | ConvertTo-Json -Depth $Depth -Compress
    $json = ConvertTo-PrettyJsonString -Json $compactJson -IndentSize 2
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $tempPath = "$Path.tmp"
    $backupPath = "$Path.bak"

    [System.IO.File]::WriteAllText($tempPath, $json, $encoding)
    if (Test-Path -LiteralPath $Path) {
        [System.IO.File]::Replace($tempPath, $Path, $backupPath, $true)
    }
    else {
        [System.IO.File]::Move($tempPath, $Path)
    }
}

function ConvertTo-HashtableDeep {
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($key in $InputObject.Keys) {
            $ht[[string]$key] = ConvertTo-HashtableDeep -InputObject $InputObject[$key]
        }
        return $ht
    }

    if ($InputObject -is [string] -or
        $InputObject -is [bool]   -or
        $InputObject -is [int]    -or $InputObject -is [long]   -or
        $InputObject -is [double] -or $InputObject -is [float]  -or
        $InputObject -is [decimal]-or
        $InputObject -is [datetime] -or $InputObject -is [DateTimeOffset] -or
        $InputObject.GetType().IsEnum) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-HashtableDeep -InputObject $item)
        }
        return $items
    }

    $properties = @()
    try {
        $properties = @($InputObject.PSObject.Properties)
    }
    catch {
        $properties = @()
    }

    if ($properties.Count -gt 0) {
        $ht = @{}
        foreach ($property in $properties) {
            if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Name)) {
                continue
            }

            if ($property.MemberType -notin @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty')) {
                continue
            }

            $ht[$property.Name] = ConvertTo-HashtableDeep -InputObject $property.Value
        }

        if ($ht.Count -gt 0) {
            return $ht
        }
    }

    return $InputObject
}

function Read-JsonHashtableWithBackup {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Component = 'State'
    )

    $candidates = @($Path, "$Path.bak")
    $parseErrors = @()

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        try {
            $rawPayload = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
            $payload = ConvertTo-HashtableDeep -InputObject $rawPayload
            if ($candidate -ne $Path) {
                Write-Log "Primary state file parse failed earlier. Recovered from backup: $candidate" 'WARN' 'Yellow' $Component
            }
            return $payload
        }
        catch {
            $parseErrors += "$candidate => $($_.Exception.Message)"
        }
    }

    if ($parseErrors.Count -gt 0) {
        Write-Log "Failed to parse state payload(s). Details: $($parseErrors -join ' | ')" 'WARN' 'Yellow' $Component
    }

    return $null
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
            Snapshot            = $state.Snapshot
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
    $savedPendingTypes = Get-SafeProperty -Object $savedPlan -Name 'PendingEventTypes'
    
    if ($null -ne $savedPendingTypes) {
        if ($savedPendingTypes -is [System.Collections.IDictionary]) {
            foreach ($key in @($savedPendingTypes.Keys)) {
                $pendingTypes[[string]$key] = [int]$savedPendingTypes[$key]
            }
        }
        else {
            foreach ($prop in @($savedPendingTypes.PSObject.Properties)) {
                if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Name)) { continue }
                if ($prop.MemberType -notin @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty')) { continue }
                $pendingTypes[[string]$prop.Name] = [int]$prop.Value
            }
        }
    }

    return [hashtable]::Synchronized(@{
        Name                = $Plan.name
        LastChange          = ConvertFrom-DateValue (Get-SafeProperty -Object $savedPlan -Name 'LastChange')
        EventCount          = [int](Get-SafeProperty -Object $savedPlan -Name 'EventCount' -Default 0)
        BatchNumber         = [int](Get-SafeProperty -Object $savedPlan -Name 'BatchNumber' -Default 0)
        CurrentBatchId      = Get-SafeProperty -Object $savedPlan -Name 'CurrentBatchId'
        QueueLogged         = $false
        LastRun             = Get-SafeProperty -Object $savedPlan -Name 'LastRun'
        LastQueuedAt        = ConvertFrom-DateValue (Get-SafeProperty -Object $savedPlan -Name 'LastQueuedAt')
        LastBatchId         = Get-SafeProperty -Object $savedPlan -Name 'LastBatchId'
        LastBatchEventCount = [int](Get-SafeProperty -Object $savedPlan -Name 'LastBatchEventCount' -Default 0)
        LastDispatchStatus  = Resolve-StatusString -Value (Get-SafeProperty -Object $savedPlan -Name 'LastDispatchStatus')
        Snapshot            = Get-SafeProperty -Object $savedPlan -Name 'Snapshot' -Default ''
        PendingPaths        = @(Get-SafeProperty -Object $savedPlan -Name 'PendingPaths' -Default @())
        PendingEventTypes   = $pendingTypes
    })
}

# IMPORTANT: Defined in global scope so event watchers can access it.
function global:Test-ShouldIgnorePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }

    $name = [IO.Path]::GetFileName($Path)
    if ([string]::IsNullOrWhiteSpace($name)) { return $true }

    if ($name -match '^(~|\.~)' -or $name -match '(?i)^(thumbs\.db|desktop\.ini|\.ds_store)$') { return $true }
    if ($name -match '(?i)\.(tmp|temp|bak|swp|swo|lock|part|partial|crdownload|download)$') { return $true }
    if ($Path -match '(?i)[\\/](\.git|node_modules\\\.cache|\$RECYCLE\.BIN)[\\/]') { return $true }

    return $false
}

# ---------------------------------------------------------------------------
# Plan dispatch-state persistence (restart-resilience / missed-change detection)
#
# Mirrors the RClone snapshot pattern: after each successful dispatch we write
# a lightweight record per plan.  On the next startup we compare that record
# against current conditions and re-trigger any plan that:
#   (a) had a non-success LastDispatchStatus (failed / dispatched-but-unknown), or
#   (b) is brand-new (no record at all).
#   (c) folder signature changed while offline
# ---------------------------------------------------------------------------

function Get-PlanSnapshotSignature {
    param([string[]]$Paths)

    if ($null -eq $Paths -or $Paths.Count -eq 0) { return 'EMPTY' }
    
    $signatures = @()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }

        try {
            $items = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | 
                Select-Object -Property Name, @{ Name = 'LastWriteTicks'; Expression = { $_.LastWriteTimeUtc.Ticks } } | 
                Sort-Object -Property Name)

            if ($items.Count -eq 0) { 
                $signatures += 'EMPTY'
                continue 
            }

            # Use [long] to prevent integer overflow with massive timestamps sums
            $timestampSum = [long]($items | Measure-Object -Property LastWriteTicks -Sum).Sum
            $quickSig = "$($items.Count)|$($items[0].Name)|$($items[-1].Name)|$timestampSum"
            
            if ($items.Count -gt 500) {
                $signatures += $quickSig
            } else {
                $signatureData = ($items | ForEach-Object { "$($_.Name)|$($_.LastWriteTicks)" }) -join '|'
                $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($signatureData))
                $signatures += ([System.BitConverter]::ToString($hash) -replace '-', '')
            }
        }
        catch [System.UnauthorizedAccessException] {
            $signatures += 'ERROR_ACCESS'
        }
        catch {
            $signatures += 'ERROR_READ'
        }
    }

    if ($signatures.Count -eq 0) { return 'ERROR_ALL' }
    $finalData = $signatures -join '||'
    $finalHash = [System.Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($finalData))
    return ([System.BitConverter]::ToString($finalHash) -replace '-', '')
}

function Save-PlanDispatchState {
    try {
        $records = [ordered]@{}
        foreach ($planId in @($global:PlanState.Keys | Sort-Object)) {
            $s = $global:PlanState[$planId]
            $records[$planId] = [ordered]@{
                Name               = $s.Name
                LastRun            = $s.LastRun
                LastBatchId        = $s.LastBatchId
                LastDispatchStatus = $s.LastDispatchStatus
                Snapshot           = $s.Snapshot
                SavedAt            = (Get-Date).ToString('o')
            }
        }

        $payload = [ordered]@{
            Metadata = [ordered]@{
                UpdatedAt  = (Get-Date).ToString('o')
                InstanceId = $global:MonitorControl.InstanceId
                ProcessId  = $PID
            }
            Plans = $records
        }

        Write-JsonFile -Path $PlanStateFile -Data $payload -Depth 8
    }
    catch {
        Write-Log "Failed to save plan dispatch state: $($_.Exception.Message)" 'WARN' 'Yellow' 'State'
    }
}

function Get-SavedPlanDispatchState {
    if (-not (Test-Path -LiteralPath $PlanStateFile) -and -not (Test-Path -LiteralPath "$PlanStateFile.bak")) {
        return @{}
    }

    $payload = Read-JsonHashtableWithBackup -Path $PlanStateFile -Component 'State'
    if ($null -eq $payload) { return @{} }

    $plansObj = Get-SafeProperty -Object $payload -Name 'Plans'
    if ($null -ne $plansObj) {
        $planCount = 0
        if ($plansObj -is [System.Collections.IDictionary] -or $plansObj -is [array]) { 
            $planCount = $plansObj.Count 
        } else {
            try { $planCount = @($plansObj.PSObject.Properties).Count } catch {}
        }

        $metaObj = Get-SafeProperty -Object $payload -Name 'Metadata'
        $updatedAt = Get-SafeProperty -Object $metaObj -Name 'UpdatedAt' -Default 'unknown'

        Write-Log "Loaded plan dispatch snapshot from disk. Recovered $planCount record(s) saved at $updatedAt." 'INFO' 'DarkGray' 'State'
        return $plansObj
    }

    return @{}
}

function Repair-PlanDispatchSnapshot {
    param([hashtable]$SavedDispatch = @{})

    $repaired = @{}
    foreach ($existingPlanId in @($SavedDispatch.Keys)) {
        $repaired[$existingPlanId] = $SavedDispatch[$existingPlanId]
    }

    $added = 0
    $updated = 0

    foreach ($planId in @($global:PlanState.Keys)) {
        $state = $global:PlanState[$planId]
        if ($null -eq $state) { continue }

        $candidate = [ordered]@{
            Name               = $state.Name
            LastRun            = $state.LastRun
            LastBatchId        = $state.LastBatchId
            LastDispatchStatus = $state.LastDispatchStatus
            Snapshot           = $state.Snapshot
            SavedAt            = (Get-Date).ToString('o')
        }

        if (-not $repaired.ContainsKey($planId)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$state.LastDispatchStatus) -or -not [string]::IsNullOrWhiteSpace([string]$state.LastRun)) {
                $repaired[$planId] = $candidate
                $added++
            }
            continue
        }

        $existing = $repaired[$planId]
        $existingStatus = if ($null -ne $existing) { [string]$existing.LastDispatchStatus } else { '' }
        if ([string]::IsNullOrWhiteSpace($existingStatus) -and -not [string]::IsNullOrWhiteSpace([string]$state.LastDispatchStatus)) {
            $repaired[$planId] = $candidate
            $updated++
        }
    }

    if ($added -gt 0 -or $updated -gt 0) {
        Write-Log "Dispatch snapshot repair applied: added=$added updated=$updated" 'INFO' 'DarkGray' 'State'
        Save-PlanDispatchState
    }

    return $repaired
}

function Find-PlansNeedingRetrigger {
    param(
        [hashtable]$SavedDispatch,
        [array]$ConfigPlans
    )

    $needsRetrigger = @()
    foreach ($planId in @($global:PlanState.Keys)) {
        $state = $global:PlanState[$planId]
        $runtimeLastStatus = Resolve-StatusString -Value $state.LastDispatchStatus
        $runtimeHasRun = -not [string]::IsNullOrWhiteSpace([string]$state.LastRun)
        
        $planConfig = $ConfigPlans | Where-Object { $_.id -eq $planId } | Select-Object -First 1
        $currentSnapshot = if ($null -ne $planConfig) { Get-PlanSnapshotSignature -Paths @($planConfig.paths) } else { 'ERROR' }
        
        $snapshotChanged = $false
        $savedSnapshot = ''
        
        if ($SavedDispatch.ContainsKey($planId)) {
            $record = $SavedDispatch[$planId]
            $savedSnapshot = Get-SafeProperty -Object $record -Name 'Snapshot' -Default ''
            
            $lastStatus = Resolve-StatusString -Value $record
            if ([string]::IsNullOrWhiteSpace($lastStatus) -and $runtimeHasRun) {
                $lastStatus = $runtimeLastStatus
            }
        } else {
            $lastStatus = $runtimeLastStatus
        }
        
        if ($currentSnapshot -notin @('ERROR_ACCESS', 'ERROR_READ', 'ERROR_ALL', '') -and -not [string]::IsNullOrWhiteSpace($savedSnapshot) -and $currentSnapshot -ne $savedSnapshot) {
            $snapshotChanged = $true
        }

        if (-not $SavedDispatch.ContainsKey($planId)) {
            if ($runtimeHasRun -and $runtimeLastStatus -in @('success', 'mocked')) {
                Write-Log "Plan [$($state.Name)] dispatch snapshot missing, but runtime reports success. Skipping startup re-trigger." 'INFO' 'DarkGray' $state.Name
                continue
            }
            Write-Log "Plan [$($state.Name)] has no prior dispatch record. Queuing for re-trigger." 'INFO' 'Cyan' $state.Name
            $needsRetrigger += $planId
            continue
        }

        if ($lastStatus -notin @('success', 'mocked')) {
            $reason = if ([string]::IsNullOrWhiteSpace($lastStatus)) { 'no status recorded' } else { "last status was '$lastStatus'" }
            Write-Log "Plan [$($state.Name)] queued for startup re-trigger: $reason." 'INFO' 'Cyan' $state.Name
            $needsRetrigger += $planId
            continue
        }
        
        if ($snapshotChanged) {
            Write-Log "Plan [$($state.Name)] queued for startup re-trigger: Folder contents changed while offline (snapshot mismatch)." 'INFO' 'Cyan' $state.Name
            $needsRetrigger += $planId
            continue
        }
        
        if ([string]::IsNullOrWhiteSpace($state.Snapshot) -and $currentSnapshot -notmatch 'ERROR') {
            $state.Snapshot = $currentSnapshot
        }
    }
    return $needsRetrigger
}

function Invoke-SyntheticRetrigger {
    param([string]$PlanId)

    $state = $global:PlanState[$planId]
    if ($null -eq $state) { return }

    if ([int]$state.EventCount -gt 0) { return }

    $state.BatchNumber    = [int]$state.BatchNumber + 1
    $state.CurrentBatchId = '{0}-B{1:D4}-RESTART' -f $PlanId, [int]$state.BatchNumber
    $state.EventCount     = 1
    $state.LastChange     = [datetime]::Now.AddSeconds(-$global:IdleTimeSeconds)
    $state.LastQueuedAt   = [datetime]::Now
    $state.QueueLogged    = $false
    if (-not $state.PendingEventTypes.ContainsKey('Synthetic')) {
        $state.PendingEventTypes['Synthetic'] = 0
    }
    $state.PendingEventTypes['Synthetic'] = 1
    $state.PendingPaths = @('[restart-retrigger]')
    Set-StateDirty

    Write-Log "Synthetic restart retrigger injected for [$($state.Name)]. Debounce bypassed intentionally — backup was missed while daemon was stopped. BatchId=[$($state.CurrentBatchId)]" 'INFO' 'Cyan' $state.Name
}

function Get-SavedPlanState {
    if (-not (Test-Path -LiteralPath $StateFile) -and -not (Test-Path -LiteralPath "$StateFile.bak")) {
        return @{}
    }

    $savedPayload = Read-JsonHashtableWithBackup -Path $StateFile -Component 'State'
    if ($null -eq $savedPayload) {
        Write-Log 'Failed to parse state file and backup. Starting fresh.' 'WARN' 'Yellow' 'State'
        return @{}
    }

    $plansObj = Get-SafeProperty -Object $savedPayload -Name 'Plans'
    if ($null -ne $plansObj) {
        $planCount = 0
        if ($plansObj -is [System.Collections.IDictionary] -or $plansObj -is [array]) { 
            $planCount = $plansObj.Count 
        } else {
            try { $planCount = @($plansObj.PSObject.Properties).Count } catch {}
        }

        $metaObj = Get-SafeProperty -Object $savedPayload -Name 'Metadata'
        $updatedAt = Get-SafeProperty -Object $metaObj -Name 'UpdatedAt' -Default 'unknown'

        Write-Log "Loaded previous trigger state from disk. Recovered $planCount plan(s) saved at $updatedAt." 'INFO' 'DarkGray' 'State'
        return $plansObj
    }

    Write-Log 'Loaded legacy trigger state from disk.' 'INFO' 'DarkGray' 'State'
    return $savedPayload
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

            $shouldEarlyExit = $false
            if ($detection.IsRunning -and $detection.Confidence -eq 'high') {
                $shouldEarlyExit = $true
            }
            elseif (
                $detection.IsRunning -and
                $detection.Confidence -eq 'medium' -and
                $null -ne $detection.Signals -and
                $detection.Signals.ProcessTableMatch
            ) {
                $shouldEarlyExit = $true
            }

            if ($shouldEarlyExit) {
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
    $mutex = [System.Threading.Mutex]::new($false, $mutexName, [ref]$mutexCreated)

    try {
        $mutexOwned = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        # Previous owner was terminated abruptly (e.g. force stop). Recover ownership and continue.
        $mutexOwned = $true
        Write-Log 'Recovered abandoned monitor mutex after abrupt previous termination.' 'WARN' 'Yellow' 'Preflight'
    }

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

                    if (Test-ShouldIgnorePath -Path ([string]$fullPath)) { return }

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

                    # Write to log dynamically for overflows
                    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    $pidPad = $PID.ToString().PadRight(5)
                    $msg = "[$ts] [PID:$pidPad] [WARN] [$($planState.Name)] Watcher buffer overflow detected. Forcing queue update.`n"
                    [System.IO.File]::AppendAllText([string]$Event.MessageData.ErrorLog, $msg)

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

    # --- Restart-resilience: check for plans that need re-triggering on startup ---
    $savedDispatch = Get-SavedPlanDispatchState
    $savedDispatch = Repair-PlanDispatchSnapshot -SavedDispatch $savedDispatch
    
    $retriggerIds  = @(Find-PlansNeedingRetrigger -SavedDispatch $savedDispatch -ConfigPlans $plans)
    
    foreach ($rid in $retriggerIds) {
        Invoke-SyntheticRetrigger -PlanId $rid
    }
    if ($retriggerIds.Count -gt 0) {
        Write-Log "Startup re-trigger injected for $($retriggerIds.Count) plan(s): $($retriggerIds -join ', ')" 'INFO' 'Cyan' 'System'
    }

    Write-Log 'Waiting for idle bounds...' 'INFO' 'Green' 'System'

    $lastResourceLogTime = Get-Date
    $lastSnapshotEvalTime = Get-Date

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

        # --- 15-Minute Periodic Snapshot Baseline Save ---
        if (($now - $lastSnapshotEvalTime).TotalSeconds -ge 900) {
            $lastSnapshotEvalTime = $now
            $snapshotSaved = $false
            
            foreach ($planId in @($global:PlanState.Keys)) {
                $state = $global:PlanState[$planId]
                $planConfig = $plans | Where-Object { $_.id -eq $planId } | Select-Object -First 1
                if ($null -ne $planConfig) {
                    $currentSnapshot = Get-PlanSnapshotSignature -Paths @($planConfig.paths)
                    
                    if ($currentSnapshot -notmatch 'ERROR') {
                        if ([string]::IsNullOrWhiteSpace($state.Snapshot) -or ($state.EventCount -eq 0 -and $state.LastDispatchStatus -in @('success', 'mocked'))) {
                            if ($state.Snapshot -ne $currentSnapshot) {
                                Write-Log "Updating 15-minute baseline snapshot for [$planId]. New Signature=[$currentSnapshot]" 'INFO' 'Cyan' 'System'
                                $state.Snapshot = $currentSnapshot
                                $snapshotSaved = $true
                            }
                        }
                    }
                }
            }
            
            if ($snapshotSaved) {
                Save-PlanDispatchState
                Write-Log "Periodic 15-minute snapshot records synced to disk." 'INFO' 'DarkGray' 'System'
            }
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

            $state.LastBatchId = $batchId
            $state.LastBatchEventCount = $events
            $state.LastDispatchStatus = 'dispatched'
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

            Set-StateDirty
            Save-TriggerState
            Save-RuntimeState -Status 'running'

            if ($global:IsTestMode) {
                Write-Log "Backrest terminal wait skipped in test mode for batch [$batchId]." 'TEST' 'Magenta' $state.Name
            }
            else {
                $observeScript = {
                    param($PlanId, $BatchId, $PlanName, $RequestStartedAt, $Endpoint, $AuthHeader,
                          $OperationModulePath, $LogFile, $ErrorLogFile)

                    function Write-ObserveLog {
                        param([string]$Message, [string]$Level = 'INFO', [string]$Component = 'Observe')
                        $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        $pid_ = $PID.ToString().PadRight(5)
                        $line = "[$ts] [PID:$pid_] [$Level] [$Component] $Message"
                        try { [System.IO.File]::AppendAllText($LogFile, "$line`n") } catch {}
                        if ($Level -match '^(ERROR|WARN)$') {
                            try { [System.IO.File]::AppendAllText($ErrorLogFile, "$line`n") } catch {}
                        }
                    }

                    if (Test-Path -LiteralPath $OperationModulePath) {
                        try { . $OperationModulePath } catch {}
                    }

                    Write-ObserveLog "Background observation started for batch [$BatchId]." 'INFO' $PlanName

                    $outcome = $null
                    try {
                        $outcome = Wait-BackrestOperationFinalStatus `
                            -OperationFetcher {
                                param([string]$PlanId, [string]$Endpoint, [hashtable]$Headers)
                                $uriRoot = $Endpoint -replace '/v1\.Backrest/Backup$', ''
                                $body    = @{ selector = @{ planId = $PlanId } } | ConvertTo-Json -Compress
                                $rp      = @{ Uri = "$uriRoot/v1.Backrest/GetOperations"; Method = 'Post'; Body = $body; ContentType = 'application/json'; TimeoutSec = 5 }
                                if ($Headers.Count -gt 0) { $rp.Headers = $Headers }
                                try {
                                    $resp = Invoke-RestMethod @rp
                                    $ops  = @($resp.operations)
                                    if ($ops.Count -eq 0) { return $null }
                                    return ($ops | Sort-Object {
                                        $t = $null
                                        if ([datetime]::TryParse([string]$_.unixTimeStartMs, [ref]$t)) { return $t }
                                        try { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$_.unixTimeStartMs).LocalDateTime } catch { return [datetime]::MinValue }
                                    } -Descending | Select-Object -First 1)
                                } catch { return $null }
                            } `
                            -PlanId $PlanId `
                            -Since $RequestStartedAt `
                            -Endpoint $Endpoint `
                            -Headers $AuthHeader `
                            -TimeoutSeconds 1800 `
                            -PollIntervalSeconds 5
                    }
                    catch {
                        Write-ObserveLog "Observation error for batch [$BatchId]: $($_.Exception.Message)" 'WARN' $PlanName
                    }

                    if ($null -ne $outcome) {
                        $opId   = if ($null -ne $outcome.Operation.id)     { $outcome.Operation.id }     else { 'unknown' }
                        $flowId = if ($null -ne $outcome.Operation.flowId) { $outcome.Operation.flowId } else { 'unknown' }
                        $status = if ($null -ne $outcome.RawStatus)        { $outcome.RawStatus }        else { 'unknown' }
                        Write-ObserveLog "Backrest operation reached terminal status for batch [$BatchId]. OperationId=[$opId] FlowId=[$flowId] Status=[$status] Outcome=[$($outcome.Outcome)]" 'INFO' $PlanName
                    }
                    else {
                        Write-ObserveLog "No terminal operation status observed within wait window for batch [$BatchId]." 'WARN' $PlanName
                    }
                }

                $capturedPlanId     = $planId
                $capturedBatchId    = $batchId
                $capturedPlanName   = $state.Name
                $capturedStartedAt  = $requestStartedAt
                $capturedEndpoint   = $BackrestEndpoint
                $capturedAuth       = $AuthHeader
                $capturedOpModule   = $OperationModule
                $capturedLogFile    = $LogFile
                $capturedErrLog     = $ErrorLogFile

                Start-Job -ScriptBlock $observeScript -ArgumentList `
                    $capturedPlanId, $capturedBatchId, $capturedPlanName, $capturedStartedAt,
                    $capturedEndpoint, $capturedAuth, $capturedOpModule,
                    $capturedLogFile, $capturedErrLog | Out-Null
            }

            if ($state.LastDispatchStatus -eq 'dispatched') {
                $state.LastDispatchStatus = 'success'
                $global:MonitorControl.LastSuccessfulDispatch = $state.LastRun
                
                $planConfig = $plans | Where-Object { $_.id -eq $planId } | Select-Object -First 1
                if ($null -ne $planConfig) {
                    $newSnapshot = Get-PlanSnapshotSignature -Paths @($planConfig.paths)
                    if ($newSnapshot -notmatch 'ERROR') {
                        Write-Log "Updating baseline snapshot for [$planId] post-dispatch. Signature=[$newSnapshot]" 'INFO' 'Cyan' 'System'
                        $state.Snapshot = $newSnapshot
                    }
                }
            }
            Set-StateDirty
            Save-TriggerState
            Save-PlanDispatchState
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
        Save-PlanDispatchState
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