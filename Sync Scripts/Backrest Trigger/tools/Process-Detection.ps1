# ==========================================
# Process Detection Utility Module
# Layered detection strategy: process table + command line + heartbeat + mutex + scheduler state
# ==========================================

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
    
    # Append username if not already present
    if (-not $MutexName.Contains($env:USERNAME)) {
        $MutexName = "$MutexName$env:USERNAME"
    }
    
    $result = [PSCustomObject]@{
        IsBusy = $false
        AccessDenied = $false
        Message = 'Mutex is free (no active instance).'
    }
    
    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::new($false, $MutexName)
        if (-not $mutex.WaitOne(0)) {
            $result.IsBusy = $true
            $result.Message = 'Mutex is owned by another active instance.'
            return $result
        }
        
        $mutex.ReleaseMutex() | Out-Null
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
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
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
        [int]$HeartbeatFreshSeconds = 180
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
    
    .PARAMETER LogFile
    Path to the runner log file for heartbeat validation.
    
    .PARAMETER MutexName
    Name of the mutex to check. Defaults to Global\BackrestLiveMonitor_{USERNAME}
    
    .PARAMETER HeartbeatFreshSeconds
    How recent a log entry must be to count as a heartbeat. Default 180 seconds.
    
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
    
    # At least 2 signals = likely running
    # At least 3 signals = high confidence running
    if ($signalCount -ge 3) {
        $isRunning = $true
        $confidence = 'high'
    }
    elseif ($signalCount -eq 2) {
        # Two signals: if it includes heartbeat, more likely to be running
        if ($signals.HeartbeatFresh -and ($signals.ProcessTableMatch -or $signals.MutexBusy)) {
            $isRunning = $true
            $confidence = 'medium'
        }
        elseif ($signals.ProcessTableMatch -and $signals.CommandLineValid) {
            $isRunning = $true
            $confidence = 'high'
        }
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
            Add-Content -LiteralPath (Join-Path $LogDir 'manager.log') -Value $message -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        
        return $true
    }
    catch {
        if ($LogDir -and (Test-Path $LogDir)) {
            $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $message = "[$timestamp] [MANAGER] Failed to stop process tree rooted at PID ${ProcessId}: $($_.Exception.Message)"
            Add-Content -LiteralPath (Join-Path $LogDir 'manager-error.log') -Value $message -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        
        return $false
    }
}

# Export public functions
Export-ModuleMember -Function @(
    'Get-ProcessCommandLine',
    'Get-ProcessStartTime',
    'Get-WatcherProcesses',
    'Get-MutexState',
    'Get-HeartbeatStatus',
    'Resolve-LiveWatcherPid',
    'Get-WatcherProcessDetails',
    'Test-WatcherIsRunning',
    'Request-SafeStop',
    'Stop-WatcherProcess'
)
