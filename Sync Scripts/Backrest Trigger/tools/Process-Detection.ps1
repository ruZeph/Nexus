# ==========================================
# Process Detection Utility Module
# Layered detection strategy: process table + command line + heartbeat + mutex + scheduler state
# ==========================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProcessCommandLine {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        return ''
    }
    
    return [string]$proc.CommandLine
}

function Get-ProcessStartTime {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $proc -or [string]::IsNullOrWhiteSpace([string]$proc.CreationDate)) {
        return $null
    }
    
    try {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime($proc.CreationDate).ToLocalTime()
    }
    catch {
        return $null
    }
}

function Get-WatcherProcesses {
    param(
        [string]$ScriptName = 'Start-LiveBackup.ps1',
        [string]$WrapperName = 'Start-BackrestMonitor.ps1'
    )
    
    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $watcherProcesses = @(
        $allProcesses |
        Where-Object {
            $_.Name -in @('powershell.exe', 'pwsh.exe') -and
            [int]$_.ProcessId -ne [int]$PID -and  # Exclude current process
            (
                $_.CommandLine -match [regex]::Escape($ScriptName) -or
                $_.CommandLine -match [regex]::Escape($WrapperName)
            )
        }
    )
    
    $entries = @()
    foreach ($watcher in $watcherProcesses) {
        $entries += [PSCustomObject]@{
            ProcessId = [int]$watcher.ProcessId
            ParentProcessId = [int]$watcher.ParentProcessId
            Name = [string]$watcher.Name
            CommandLine = [string]$watcher.CommandLine
            StartTime = Get-ProcessStartTime -ProcessId $watcher.ProcessId
        }
    }
    
    return $entries | Sort-Object ProcessId
}

function Get-MutexState {
    param([string]$MutexName = 'Global\BackrestLiveMonitor_')
    
    # Preserve fully-qualified mutex names used by the daemon. Legacy callers can still
    # pass the old prefix and let us append the username.
    if (
        -not ($MutexName -match '^(Global|Local)\\') -and
        -not $MutexName.Contains($env:USERNAME)
    ) {
        $MutexName = "$MutexName$env:USERNAME"
    }
    
    $result = [PSCustomObject]@{
        IsBusy = $false
        AccessDenied = $false
        Message = 'Mutex is free (no active instance).'
    }
    
    $mutex = $null
    $ownsMutex = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $MutexName)
        try {
            $ownsMutex = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            # Treat abandoned mutex as recoverable/free for liveness probing.
            $ownsMutex = $true
            $result.Message = 'Mutex was abandoned by a previous instance; considered recoverable/free.'
        }

        if (-not $ownsMutex) {
            $result.IsBusy = $true
            $result.Message = 'Mutex is owned by another active instance.'
            return $result
        }

        return $result
    }
    catch [System.UnauthorizedAccessException] {
        $result.IsBusy = $true
        $result.AccessDenied = $true
        $result.Message = 'Mutex exists but not accessible from this session (different security context).'
        return $result
    }
    catch {
        $result.Message = "Unable to check mutex state: $($_.Exception.Message)"
        return $result
    }
    finally {
        if ($ownsMutex -and $null -ne $mutex) {
            try {
                $mutex.ReleaseMutex() | Out-Null
            }
            catch {
            }
        }

        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Get-RuntimeStateStatus {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeStateFile,
        [int]$FreshWithinSeconds = 180
    )

    $result = [PSCustomObject]@{
        Found = $false
        IsFresh = $false
        Status = $null
        Timestamp = $null
        ProcessId = $null
        InstanceId = $null
    }

    if (-not (Test-Path -LiteralPath $RuntimeStateFile)) {
        return $result
    }

    try {
        $payload = Get-Content -LiteralPath $RuntimeStateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $result.Found = $true
        $result.Status = [string]$payload.Status
        $result.ProcessId = if ($null -ne $payload.ProcessId) { [int]$payload.ProcessId } else { $null }
        $result.InstanceId = [string]$payload.InstanceId

        if ($null -ne $payload.UpdatedAt -and -not [string]::IsNullOrWhiteSpace([string]$payload.UpdatedAt)) {
            $parsed = $null
            if ([datetime]::TryParse([string]$payload.UpdatedAt, [ref]$parsed)) {
                $result.Timestamp = $parsed
                $ageSeconds = ((Get-Date) - $parsed).TotalSeconds
                $result.IsFresh = ($result.Status -eq 'running' -and $ageSeconds -ge 0 -and $ageSeconds -le $FreshWithinSeconds)
            }
        }
    }
    catch {
    }

    return $result
}

function Get-HeartbeatStatus {
    param(
        [Parameter(Mandatory = $true)][string]$LogFile,
        [int]$FreshWithinSeconds = 180
    )
    
    $result = [PSCustomObject]@{
        Found = $false
        IsFresh = $false
        Timestamp = $null
        Line = $null
        ProcessId = $null
    }
    
    if (-not (Test-Path -LiteralPath $LogFile)) {
        return $result
    }
    
    $lines = @(Get-Content -LiteralPath $LogFile -Tail 300 -ErrorAction SilentlyContinue)
    
    # Look for heartbeat patterns: [RESOURCE] context=monitor-loop or file change events
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = [string]$lines[$i]
        if ($line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\].*\[PID:(\s*\d+)\]') {
            $result.Found = $true
            $result.Line = $line
            $result.ProcessId = [int]::Parse($Matches[2].Trim())
            
            try {
                $result.Timestamp = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                $ageSeconds = ((Get-Date) - $result.Timestamp).TotalSeconds
                $result.IsFresh = ($ageSeconds -ge 0 -and $ageSeconds -le $FreshWithinSeconds)
            }
            catch {
            }
            break
        }
    }
    
    return $result
}

function Resolve-LiveWatcherPid {
    param([Parameter(Mandatory = $true)][string]$LogFile)
    
    if (-not (Test-Path -LiteralPath $LogFile)) {
        return $null
    }
    
    $lines = @(Get-Content -LiteralPath $LogFile -Tail 500 -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) {
        return $null
    }
    
    $candidatePids = New-Object System.Collections.Generic.List[int]
    
    # Look for recent log lines with PID information
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = [string]$lines[$i]
        if ($line -match '\[PID:(\s*\d+)\]') {
            $pidCandidate = [int]::Parse($Matches[1].Trim())
            if (-not $candidatePids.Contains($pidCandidate)) {
                [void]$candidatePids.Add($pidCandidate)
            }
        }
    }
    
    # Validate each candidate against the process table
    foreach ($candidatePid in $candidatePids) {
        try {
            $proc = Get-Process -Id $candidatePid -ErrorAction Stop
            if ($null -ne $proc -and $proc.ProcessName -in @('powershell', 'pwsh')) {
                return $candidatePid
            }
        }
        catch {
        }
    }
    
    return $null
}

function Get-WatcherProcessDetails {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        if ($null -eq $proc) {
            return $null
        }
        
        return [PSCustomObject]@{
            ProcessId = [int]$proc.ProcessId
            ParentProcessId = [int]$proc.ParentProcessId
            Name = [string]$proc.Name
            CommandLine = [string]$proc.CommandLine
            StartTime = Get-ProcessStartTime -ProcessId $ProcessId
        }
    }
    catch {
        return $null
    }
}

function Test-WatcherIsRunning {
    param(
        [Parameter(Mandatory = $true)][string]$LogFile,
        [string]$MutexName = 'Global\BackrestLiveMonitor_',
        [int]$HeartbeatFreshSeconds = 180,
        [string]$RuntimeStateFile = $null,
        [string]$ResourceLogDir = $null,
        [hashtable]$ResourceState = @{}
    )
    
    <#
    .SYNOPSIS
    Layered detection: determines if the watcher is actively running.
    
    .DESCRIPTION
    Uses multiple signals to determine runner state:
    1. Process table lookup (direct detection)
    2. Command line validation (confirm it's the right process)
    3. Heartbeat log check (recent activity)
    4. Mutex state (ownership indicator)
    
    Optionally logs resource metrics for health monitoring.
    
    .PARAMETER LogFile
    Path to the runner log file for heartbeat validation.
    
    .PARAMETER MutexName
    Name of the mutex to check. Defaults to Global\BackrestLiveMonitor_{USERNAME}
    
    .PARAMETER HeartbeatFreshSeconds
    How recent a log entry must be to count as a heartbeat. Default 180 seconds.
    
    .PARAMETER ResourceLogDir
    Optional: Path to log resource metrics (detection-resource.log)
    
    .PARAMETER ResourceState
    Optional: Hashtable to track CPU/memory deltas between calls
    
    .OUTPUTS
    [PSCustomObject] with properties:
    - IsRunning: bool - Whether watcher appears to be actively running
    - Confidence: string - 'high', 'medium', 'low'
    - ProcessId: int or $null - The detected PID if found
    - StartTime: datetime or $null - When the process started
    - HeartbeatAge: int or $null - Age of heartbeat in seconds
    - Signals: hashtable - Breakdown of all signal states
    #>
    
    $signals = @{
        ProcessTableMatch = $false
        HeartbeatFresh = $false
        RuntimeFresh = $false
        MutexBusy = $false
        CommandLineValid = $false
    }
    
    $detectedPid = $null
    $detectedStartTime = $null
    $heartbeatAge = $null
    
    # Signal 1: Process table
    $tableEntries = @(Get-WatcherProcesses)
    if ($tableEntries.Count -gt 0) {
        $signals.ProcessTableMatch = $true
        $detectedPid = $tableEntries[0].ProcessId
        $detectedStartTime = $tableEntries[0].StartTime
    }
    
    # Signal 2: Heartbeat from logs
    $heartbeat = Get-HeartbeatStatus -LogFile $LogFile -FreshWithinSeconds $HeartbeatFreshSeconds
    if ($heartbeat.Found -and $heartbeat.IsFresh) {
        $signals.HeartbeatFresh = $true
        $heartbeatAge = [int]((Get-Date) - $heartbeat.Timestamp).TotalSeconds
        
        # If we didn't find it in process table, use heartbeat PID
        if ($null -eq $detectedPid -and $null -ne $heartbeat.ProcessId) {
            $detectedPid = $heartbeat.ProcessId
        }
    }

    # Signal 2.5: runtime heartbeat/state file
    if (-not [string]::IsNullOrWhiteSpace($RuntimeStateFile)) {
        $runtimeState = Get-RuntimeStateStatus -RuntimeStateFile $RuntimeStateFile -FreshWithinSeconds $HeartbeatFreshSeconds
        if ($runtimeState.Found -and $runtimeState.IsFresh) {
            $signals.RuntimeFresh = $true

            if ($null -eq $detectedPid -and $null -ne $runtimeState.ProcessId) {
                $detectedPid = $runtimeState.ProcessId
            }

            if ($null -eq $heartbeatAge -and $null -ne $runtimeState.Timestamp) {
                $heartbeatAge = [int]((Get-Date) - $runtimeState.Timestamp).TotalSeconds
            }
        }
    }
    
    # Signal 3: Mutex state
    $mutexState = Get-MutexState -MutexName $MutexName
    if ($mutexState.IsBusy) {
        $signals.MutexBusy = $true
    }
    
    # Signal 4: Command line validation (if we have a PID)
    if ($null -ne $detectedPid) {
        $cmdLine = Get-ProcessCommandLine -ProcessId $detectedPid
        if ($cmdLine -match 'Start-LiveBackup\.ps1') {
            $signals.CommandLineValid = $true
        }
    }
    
    # Decision logic: count the signals
    $signalCount = @($signals.Values | Where-Object { $_ -eq $true }).Count
    
    $isRunning = $false
    $confidence = 'low'
    
    # At least 2 corroborating signals = likely running.
    # RuntimeFresh is treated similarly to HeartbeatFresh because it is an explicit
    # persisted daemon heartbeat written outside the event callbacks.
    if ($signalCount -ge 3) {
        $isRunning = $true
        $confidence = 'high'
    }
    elseif ($signalCount -eq 2) {
        if (($signals.HeartbeatFresh -or $signals.RuntimeFresh) -and ($signals.ProcessTableMatch -or $signals.MutexBusy)) {
            $isRunning = $true
            $confidence = 'medium'
        }
        elseif ($signals.ProcessTableMatch -and $signals.CommandLineValid) {
            $isRunning = $true
            $confidence = 'high'
        }
        elseif ($signals.RuntimeFresh -and $signals.MutexBusy) {
            $isRunning = $true
            $confidence = 'high'
        }
    }
    
    # Optional: Log resource metrics for health monitoring
    if (-not [string]::IsNullOrWhiteSpace($ResourceLogDir)) {
        Write-DetectionResourceLog -LogDir $ResourceLogDir -State $ResourceState -Context "detection-$confidence"
    }
    
    return [PSCustomObject]@{
        IsRunning = $isRunning
        Confidence = $confidence
        ProcessId = $detectedPid
        StartTime = $detectedStartTime
        HeartbeatAge = $heartbeatAge
        Signals = $signals
    }
}

function Request-SafeStop {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $stopSignalFile = Join-Path $LogDir '.stop-livebackup'
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Set-Content -LiteralPath $stopSignalFile -Value "[$stamp] $Reason" -Encoding UTF8
    
    return $stopSignalFile
}

function Write-DetectionResourceLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [hashtable]$State = @{},
        [string]$Context = 'detection-check'
    )
    
    <#
    .SYNOPSIS
    Log resource metrics for the detection utility.
    
    .DESCRIPTION
    Records CPU, memory, handle, and thread metrics using RClone-inspired patterns.
    Tracks resource usage over time and warns on thresholds.
    #>
    
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
        
        $logMsg = "[RESOURCE] context=$Context pid=$PID cpu_pct=$cpuPct working_set_mb=$workingMb private_mb=$privateMb handles=$handles threads=$threads"
        
        if (-not (Test-Path $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        
        $resourceLog = Join-Path $LogDir 'detection-resource.log'
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = "[$ts] $logMsg"
        
        [System.IO.File]::AppendAllText($resourceLog, $line + [Environment]::NewLine)
        
        # Check for warning conditions (adapted thresholds for detection utility)
        $warnings = @()
        if ($cpuPct -ge 75) { $warnings += "cpu_pct=$cpuPct>=75" }
        if ($privateMb -ge 100) { $warnings += "private_mb=$privateMb>=100" }
        if ($handles -ge 1500) { $warnings += "handles=$handles>=1500" }
        if ($threads -ge 80) { $warnings += "threads=$threads>=80" }
        
        if ($warnings.Count -gt 0) {
            $warnMsg = "[RESOURCE WARN] context=$Context $($warnings -join ' ')"
            $warnLine = "[$ts] $warnMsg"
            [System.IO.File]::AppendAllText($resourceLog, $warnLine + [Environment]::NewLine)
        }
        
        $State['LastSampleTime'] = $now
        $State['LastCpuSeconds'] = $cpuTotalSec
    }
    catch {
        # Silently fail - detection resource logging should not block detection itself
    }
}

function Stop-WatcherProcess {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$LogDir
    )
    
    try {
        # Stop child processes first
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            try {
                Stop-Process -Id [int]$child.ProcessId -Force -ErrorAction SilentlyContinue
            }
            catch {
            }
        }
        
        # Stop the main process
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        
        if ($LogDir -and (Test-Path $LogDir)) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $message = "[$timestamp] [MANAGER] Force stopped process tree rooted at PID $ProcessId"
            [System.IO.File]::AppendAllText((Join-Path $LogDir 'manager.log'), "$message`n")
        }
        
        return $true
    }
    catch {
        if ($LogDir -and (Test-Path $LogDir)) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $message = "[$timestamp] [MANAGER] Failed to stop process tree rooted at PID ${ProcessId}: $($_.Exception.Message)"
            [System.IO.File]::AppendAllText((Join-Path $LogDir 'manager-error.log'), "$message`n")
        }
        
        return $false
    }
}

function Write-ProcessDetectionSummary {
    param(
        [string]$LogFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'logs\runner.log'),
        [string]$RuntimeStateFile = (Join-Path (Split-Path -Parent $PSScriptRoot) '.state\runtime-state.json')
    )

    $watcherProcesses = @(Get-WatcherProcesses)
    $detection = $null
    if (Test-Path -LiteralPath $LogFile) {
        try {
            $detection = Test-WatcherIsRunning -LogFile $LogFile -RuntimeStateFile $RuntimeStateFile -MutexName 'Local\BackrestLiveMonitor_'
        }
        catch {
        }
    }

    Write-Output 'Backrest Process Detection Utility'
    Write-Output ("Log file: {0}" -f $LogFile)
    Write-Output ("Runtime state: {0}" -f $RuntimeStateFile)
    Write-Output ("Matching watcher processes: {0}" -f $watcherProcesses.Count)

    if ($null -ne $detection) {
        Write-Output ("Watcher running: {0}" -f $detection.IsRunning)
        Write-Output ("Confidence: {0}" -f $detection.Confidence)
        Write-Output ("Detected PID: {0}" -f $(if ($null -ne $detection.ProcessId) { $detection.ProcessId } else { 'n/a' }))

        $signalSummary = @($detection.Signals.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }) -join ', '
        if (-not [string]::IsNullOrWhiteSpace($signalSummary)) {
            Write-Output ("Signals: {0}" -f $signalSummary)
        }
    }
    else {
        Write-Output 'Watcher detection: no active monitor could be confirmed.'
    }

    foreach ($entry in $watcherProcesses) {
        Write-Output ("PID {0} | {1}" -f $entry.ProcessId, $entry.CommandLine)
    }
}

# Export public functions (only when run as a module)
try {
    Export-ModuleMember -Function @(
        'Get-ProcessCommandLine',
        'Get-ProcessStartTime',
        'Get-WatcherProcesses',
        'Get-MutexState',
        'Get-RuntimeStateStatus',
        'Get-HeartbeatStatus',
        'Resolve-LiveWatcherPid',
        'Get-WatcherProcessDetails',
        'Test-WatcherIsRunning',
        'Request-SafeStop',
        'Stop-WatcherProcess',
        'Write-DetectionResourceLog'
    )
}
catch {
    # Export-ModuleMember only works when script is imported as a module
    # If dot-sourced, this will fail silently and functions are still available
}

if ($MyInvocation.InvocationName -ne '.') {
    Write-ProcessDetectionSummary
}
