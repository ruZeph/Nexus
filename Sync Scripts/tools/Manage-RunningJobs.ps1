param(
    [string]$LogsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'logs')
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

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-ManagerEventLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogsPath,
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$Error
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$stamp] [MANAGER] $Message"
    $targetName = if ($Error) { 'manager-error.log' } else { 'manager.log' }
    $targetPath = Join-Path $LogsPath $targetName

    New-Item -ItemType Directory -Force -Path $LogsPath | Out-Null
    Add-Content -LiteralPath $targetPath -Value $entry -Encoding UTF8
}

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

function Get-RcloneJobProcesses {
    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $runnerProcesses = @(
        $allProcesses |
        Where-Object {
            $_.Name -in @('powershell.exe', 'pwsh.exe') -and
            $_.CommandLine -match 'Run-RcloneJobs\.ps1' -and
            $_.CommandLine -match '-JobName|-SourceFolder|-Monitor'
        }
    )

    $rcloneProcesses = @(
        $allProcesses |
        Where-Object {
            $_.Name -eq 'rclone.exe' -and
            $runnerProcesses.ProcessId -contains $_.ParentProcessId
        }
    )

    $entries = @()

    foreach ($runner in $runnerProcesses) {
        $entries += [pscustomobject]@{
            Kind = 'runner'
            ProcessId = [int]$runner.ProcessId
            ParentProcessId = [int]$runner.ParentProcessId
            Name = [string]$runner.Name
            CommandLine = [string]$runner.CommandLine
            StartTime = $null
        }
    }

    foreach ($rclone in $rcloneProcesses) {
        $entries += [pscustomobject]@{
            Kind = 'rclone'
            ProcessId = [int]$rclone.ProcessId
            ParentProcessId = [int]$rclone.ParentProcessId
            Name = [string]$rclone.Name
            CommandLine = [string]$rclone.CommandLine
            StartTime = $null
        }
    }

    foreach ($entry in $entries) {
        $entry | Add-Member -NotePropertyName StartTime -NotePropertyValue (Get-ProcessStartTime -ProcessId $entry.ProcessId) -Force
    }

    return $entries | Sort-Object Kind, ProcessId
}

function Get-RunnerMutexState {
    param([string]$MutexName = 'Global\RcloneBackupRunner')

    $result = [pscustomobject]@{
        IsBusy = $false
        AccessDenied = $false
        Message = 'Runner mutex is free.'
    }

    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::new($false, $MutexName)
        if (-not $mutex.WaitOne(0)) {
            $result.IsBusy = $true
            $result.Message = 'Runner mutex is owned by another active instance.'
            return $result
        }

        $mutex.ReleaseMutex() | Out-Null
        return $result
    }
    catch [System.UnauthorizedAccessException] {
        $result.IsBusy = $true
        $result.AccessDenied = $true
        $result.Message = 'Runner mutex exists but is not accessible from this session (another instance likely running under a different security context).'
        return $result
    }
    catch {
        $result.Message = "Unable to check runner mutex state: $($_.Exception.Message)"
        return $result
    }
    finally {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Get-LatestJobLogPath {
    param([Parameter(Mandatory = $true)][string]$LogFile)

    if (-not (Test-Path -LiteralPath $LogFile)) {
        return $null
    }

    $lines = @(Get-Content -LiteralPath $LogFile -Tail 200 -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match 'Job log file:\s*(.+)$') {
            return $Matches[1].Trim()
        }
    }

    return $null
}

function Get-RunnerHeartbeatStatus {
    param(
        [Parameter(Mandatory = $true)][string]$LogFile,
        [int]$FreshWithinSeconds = 180
    )

    $result = [pscustomobject]@{
        Found = $false
        IsFresh = $false
        Timestamp = $null
        Line = $null
    }

    if (-not (Test-Path -LiteralPath $LogFile)) {
        return $result
    }

    $lines = @(Get-Content -LiteralPath $LogFile -Tail 300 -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = [string]$lines[$i]
        if ($line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\].*(\[RESOURCE\] context=monitor-loop|Folder monitoring started\.)') {
            $result.Found = $true
            $result.Line = $line
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

function Show-Processes {
    param([object[]]$Entries)

    if ($Entries.Count -eq 0) {
        Write-Info 'No active runner/job processes found.'
        return
    }

    $Entries |
        Select-Object Kind, ProcessId, ParentProcessId, StartTime, @{Name='CommandLine';Expression={
            $line = [string]$_.CommandLine
            if ($line.Length -gt 120) { return $line.Substring(0, 117) + '...' }
            return $line
        }} |
        Format-Table -AutoSize
}

function Request-SafeStop {
    param(
        [Parameter(Mandatory = $true)][string]$LogDir,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $requestPath = Join-Path $LogDir 'stop-request.txt'
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Set-Content -LiteralPath $requestPath -Value "[$stamp] $Reason" -Encoding UTF8
    Write-ManagerEventLog -LogsPath $LogDir -Message "Safe stop requested. Reason: $Reason"
    Write-Ok "Stop request written to $requestPath"
    Write-Warn 'The runner will stop after the current job finishes. This avoids stopping mid-transfer.'
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
        Write-Ok "Stopped process $ProcessId"
        Write-ManagerEventLog -LogsPath $LogsPath -Message "Force stopped process tree rooted at PID $ProcessId"
    }
    catch {
        Write-Warn ("Failed to stop process {0}: {1}" -f $ProcessId, $_.Exception.Message)
        Write-ManagerEventLog -LogsPath $LogsPath -Message ("Failed to stop process tree rooted at PID {0}: {1}" -f $ProcessId, $_.Exception.Message) -Error
    }
}

try {
    if (-not (Test-Path -LiteralPath $LogsPath)) {
        throw "Logs path not found: $LogsPath"
    }

    $previousActiveProcessCount = 0

    while ($true) {
        Clear-Host
        Write-Host 'Nexus Running Job Manager' -ForegroundColor White
        Write-Host "Logs: $LogsPath" -ForegroundColor DarkGray
        Write-Host ''

        $runnerLog = Join-Path $LogsPath 'runner.log'
        if (-not (Test-Path -LiteralPath $runnerLog)) {
            Write-Warn "Runner log not found: $runnerLog"
            Write-ManagerEventLog -LogsPath $LogsPath -Message "Runner log missing: $runnerLog" -Error
        }

        $latestJobLog = Get-LatestJobLogPath -LogFile $runnerLog
        if (-not [string]::IsNullOrWhiteSpace($latestJobLog)) {
            Write-Info "Latest job log: $latestJobLog"
        }

        $entries = @(Get-RcloneJobProcesses)
        $mutexState = Get-RunnerMutexState
        $heartbeat = Get-RunnerHeartbeatStatus -LogFile $runnerLog

        if ($mutexState.IsBusy) {
            Write-Warn $mutexState.Message
        }

        if ($previousActiveProcessCount -gt 0 -and $entries.Count -eq 0) {
            Write-Warn 'No active runner/job processes found. The process may have stopped, crashed, or been killed.'
            Write-ManagerEventLog -LogsPath $LogsPath -Message 'Active runner/job processes disappeared. This may indicate stop, crash, or kill.' -Error
        }

        if ($entries.Count -eq 0 -and $mutexState.IsBusy) {
            Write-Info 'No visible runner process details in this session, but mutex indicates an active instance.'
            if ($mutexState.AccessDenied) {
                Write-Info 'Tip: launch the manager under the same account/session as Task Scheduler to view process details.'
            }

            if ($heartbeat.Found -and $heartbeat.IsFresh) {
                Write-Info ("Runner heartbeat is recent ({0}). Monitor appears healthy." -f $heartbeat.Timestamp.ToString('yyyy-MM-dd HH:mm:ss'))
            }
            elseif ($heartbeat.Found -and -not $heartbeat.IsFresh) {
                Write-Warn ("Last runner heartbeat seen at {0}. It may have stopped." -f $heartbeat.Timestamp.ToString('yyyy-MM-dd HH:mm:ss'))
            }
        }

        $previousActiveProcessCount = $entries.Count

        Show-Processes -Entries $entries

        Write-Host ''
        Write-Host '1) Request safe stop for active monitor/job' -ForegroundColor Gray
        Write-Host '2) Force stop selected process' -ForegroundColor Gray
        Write-Host '3) Refresh' -ForegroundColor Gray
        Write-Host '0) Exit' -ForegroundColor Gray

        $choice = Read-Host 'Choose option'
        switch ($choice) {
            '1' {
                $reason = Read-Host 'Reason for stop (optional)'
                if ([string]::IsNullOrWhiteSpace($reason)) {
                    $reason = 'Stop requested from interactive job manager.'
                }
                Request-SafeStop -LogDir $LogsPath -Reason $reason
                Read-Host 'Press Enter to refresh'
            }
            '2' {
                if ($entries.Count -eq 0) {
                    Write-Warn 'No active processes to stop.'
                    Read-Host 'Press Enter to refresh'
                    continue
                }

                $indexedEntries = for ($i = 0; $i -lt $entries.Count; $i++) {
                    [pscustomobject]@{
                        Index = $i + 1
                        Kind = $entries[$i].Kind
                        ProcessId = $entries[$i].ProcessId
                        CommandLine = $entries[$i].CommandLine
                    }
                }

                $indexedEntries | Select-Object Index, Kind, ProcessId, @{Name='CommandLine';Expression={
                    $line = [string]$_.CommandLine
                    if ($line.Length -gt 110) { return $line.Substring(0, 107) + '...' }
                    return $line
                }} | Format-Table -AutoSize

                $selection = Read-Host 'Enter process number to force stop'
                $selectedIndex = 0
                if (-not [int]::TryParse($selection, [ref]$selectedIndex) -or $selectedIndex -lt 1 -or $selectedIndex -gt $indexedEntries.Count) {
                    Write-Warn 'Invalid selection.'
                    Read-Host 'Press Enter to refresh'
                    continue
                }

                Stop-ProcessTree -ProcessId $indexedEntries[$selectedIndex - 1].ProcessId
                Read-Host 'Press Enter to refresh'
            }
            '3' {
                continue
            }
            '0' {
                Write-ManagerEventLog -LogsPath $LogsPath -Message 'Operator exited the running job manager.'
                Write-Info 'Exiting running job manager.'
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
    if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) {
        Write-Info 'Interrupted by Ctrl+C. Exiting manager.'
        exit 0
    }

    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
