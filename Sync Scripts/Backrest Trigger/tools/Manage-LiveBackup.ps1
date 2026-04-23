param(
    [string]$LogsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'),
    [string]$TaskName = 'Backrest Live Backup Monitor'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$runtimeStatePath = Join-Path $projectRoot '.state\runtime-state.json'
$stopSignalPath = Join-Path $projectRoot '.stop-livebackup'
$detectionModule = Join-Path $PSScriptRoot 'Process-Detection.ps1'

. $detectionModule

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-ManagerStatusLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogsPath,
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$WriteFailure
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$stamp] [MANAGER] $Message"
    $targetName = if ($WriteFailure) { 'manager-error.log' } else { 'manager.log' }
    $targetPath = Join-Path $LogsPath $targetName

    New-Item -ItemType Directory -Force -Path $LogsPath | Out-Null
    Add-Content -LiteralPath $targetPath -Value $entry -Encoding UTF8
}

function Get-TaskSchedulerStatus {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
        return [pscustomobject]@{
            Found = $true
            State = [string]$task.State
            LastRunTime = $taskInfo.LastRunTime
            LastTaskResult = [string]$taskInfo.LastTaskResult
            NextRunTime = $taskInfo.NextRunTime
        }
    }
    catch {
        return [pscustomobject]@{
            Found = $false
            State = 'Unknown'
            LastRunTime = $null
            LastTaskResult = 'Unknown'
            NextRunTime = $null
        }
    }
}

function Get-TaskSchedulerActionDetails {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $execAction = $task.Actions | Select-Object -First 1

        if ($null -eq $execAction) {
            throw 'No scheduled task action found.'
        }

        $actionPath = [string]$execAction.Execute
        $actionArgs = [string]$execAction.Arguments
        $actionLine = if ([string]::IsNullOrWhiteSpace($actionArgs)) { $actionPath } else { "$actionPath $actionArgs" }

        return [pscustomobject]@{
            Path = $actionPath
            Arguments = $actionArgs
            CommandLine = $actionLine
        }
    }
    catch {
        return $null
    }
}

function Get-TaskSchedulerEvent {
    param([Parameter(Mandatory = $true)][string]$TaskName)

    $logName = 'Microsoft-Windows-TaskScheduler/Operational'
    $fullTaskPath = '\' + $TaskName

    try {
        $taskRecords = @(Get-WinEvent -LogName $logName -MaxEvents 200 -ErrorAction Stop)
        foreach ($taskRecord in $taskRecords) {
            if ([string]$taskRecord.Message -match [regex]::Escape($fullTaskPath)) {
                return [pscustomobject]@{
                    TimeCreated = $taskRecord.TimeCreated
                    Id = [int]$taskRecord.Id
                    LevelDisplayName = [string]$taskRecord.LevelDisplayName
                    Message = [string]$taskRecord.Message
                }
            }
        }
    }
    catch {
    }

    return $null
}

function Get-LiveMonitorDetails {
    $runtimeState = $null
    if (Test-Path -LiteralPath $runtimeStatePath) {
        try {
            $runtimeState = Get-Content -LiteralPath $runtimeStatePath -Raw | ConvertFrom-Json
        }
        catch {
        }
    }

    $pid = $null
    if ($null -ne $runtimeState -and $null -ne $runtimeState.ProcessId) {
        $pid = [int]$runtimeState.ProcessId
    }
    else {
        $resolvedPid = Resolve-LiveWatcherPid -LogFile (Join-Path $LogsPath 'runner.log')
        if ($null -ne $resolvedPid) {
            $pid = [int]$resolvedPid
        }
    }

    $processDetails = $null
    if ($null -ne $pid) {
        $processDetails = Get-WatcherProcessDetails -ProcessId $pid
    }

    return [pscustomobject]@{
        RuntimeState = $runtimeState
        ProcessDetails = $processDetails
    }
}

function Request-SafeStop {
    param([Parameter(Mandatory = $true)][string]$Reason)

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Set-Content -LiteralPath $stopSignalPath -Value "[$stamp] $Reason" -Encoding UTF8
    Write-ManagerStatusLog -LogsPath $LogsPath -Message "Safe stop requested. Reason: $Reason"
    Write-Ok "Stop signal written to $stopSignalPath"
}

function Stop-ProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    try {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            try {
                Stop-Process -Id [int]$child.ProcessId -Force -ErrorAction SilentlyContinue
            }
            catch {
            }
        }

        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Write-Ok "Stopped process tree rooted at PID $ProcessId"
        Write-ManagerStatusLog -LogsPath $LogsPath -Message "Force stopped process tree rooted at PID $ProcessId"
    }
    catch {
        Write-Warn ("Failed to stop process tree {0}: {1}" -f $ProcessId, $_.Exception.Message)
        Write-ManagerStatusLog -LogsPath $LogsPath -Message ("Failed to stop process tree rooted at PID {0}: {1}" -f $ProcessId, $_.Exception.Message) -WriteFailure
    }
}

try {
    New-Item -ItemType Directory -Force -Path $LogsPath | Out-Null

    while ($true) {
        Clear-Host
        Write-Host 'Backrest Live Backup Manager' -ForegroundColor White
        Write-Host "Logs: $LogsPath" -ForegroundColor DarkGray
        Write-Host ''

        $runnerLog = Join-Path $LogsPath 'runner.log'
        $detection = Test-WatcherIsRunning -LogFile $runnerLog -RuntimeStateFile $runtimeStatePath -MutexName 'Local\BackrestLiveMonitor_'
        $liveMonitor = Get-LiveMonitorDetails
        $taskStatus = Get-TaskSchedulerStatus -TaskName $TaskName
        $taskAction = Get-TaskSchedulerActionDetails -TaskName $TaskName
        $latestTaskEvent = Get-TaskSchedulerEvent -TaskName $TaskName

        if ($taskStatus.Found) {
            $lastRunText = if ($taskStatus.LastRunTime) { $taskStatus.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'n/a' }
            $nextRunText = if ($taskStatus.NextRunTime) { $taskStatus.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'n/a' }
            Write-Info ("Task Scheduler: state={0} lastRun={1} lastResult={2} nextRun={3}" -f $taskStatus.State, $lastRunText, $taskStatus.LastTaskResult, $nextRunText)
        }
        else {
            Write-Warn "Scheduled task '$TaskName' was not found."
        }

        if ($null -ne $taskAction) {
            Write-Info ("Task Scheduler action: {0}" -f $taskAction.CommandLine)
        }

        if ($null -ne $latestTaskEvent) {
            $summary = $latestTaskEvent.Message
            if ($summary.Length -gt 140) {
                $summary = $summary.Substring(0, 137) + '...'
            }
            Write-Info ("Latest Windows scheduler event: id={0} level={1} time={2} msg={3}" -f $latestTaskEvent.Id, $latestTaskEvent.LevelDisplayName, $latestTaskEvent.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $summary)
        }

        Write-Info ("Watcher detection: running={0} confidence={1} pid={2}" -f $detection.IsRunning, $detection.Confidence, $(if ($null -ne $detection.ProcessId) { $detection.ProcessId } else { 'n/a' }))

        if ($null -ne $liveMonitor.RuntimeState) {
            Write-Info ("Runtime heartbeat: status={0} updated={1}" -f $liveMonitor.RuntimeState.Status, $liveMonitor.RuntimeState.UpdatedAt)
        }

        if ($null -ne $liveMonitor.ProcessDetails) {
            Write-Host ''
            $liveMonitor.ProcessDetails |
                Select-Object ProcessId, ParentProcessId, Name, StartTime, @{Name='CommandLine';Expression={
                    $line = [string]$_.CommandLine
                    if ([string]::IsNullOrWhiteSpace($line)) { return '(not visible from Windows process table)' }
                    if ($line.Length -gt 120) { return $line.Substring(0, 117) + '...' }
                    return $line
                }} |
                Format-Table -AutoSize
        }
        else {
            Write-Warn 'No live monitor process details found.'
        }

        Write-Host ''
        Write-Host '1) Request safe stop' -ForegroundColor Gray
        Write-Host '2) Force stop live process' -ForegroundColor Gray
        Write-Host '3) Refresh' -ForegroundColor Gray
        Write-Host '0) Exit' -ForegroundColor Gray

        $choice = Read-Host 'Choose option'
        switch ($choice) {
            '1' {
                $reason = Read-Host 'Reason for stop (optional)'
                if ([string]::IsNullOrWhiteSpace($reason)) {
                    $reason = 'Stop requested from live backup manager.'
                }
                Request-SafeStop -Reason $reason
                Read-Host 'Press Enter to refresh'
            }
            '2' {
                if ($null -eq $liveMonitor.ProcessDetails) {
                    Write-Warn 'No live monitor process found.'
                    Read-Host 'Press Enter to refresh'
                    continue
                }

                Stop-ProcessTree -ProcessId $liveMonitor.ProcessDetails.ProcessId
                Read-Host 'Press Enter to refresh'
            }
            '3' {
                continue
            }
            '0' {
                Write-ManagerStatusLog -LogsPath $LogsPath -Message 'Operator exited the live backup manager.'
                Write-Info 'Exiting live backup manager.'
                return
            }
            default {
                Write-Warn 'Invalid choice.'
                Start-Sleep -Seconds 1
            }
        }
    }
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
