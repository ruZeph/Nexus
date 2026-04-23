param (
    [switch]$TestMode
)

# ==========================================
# 1. Enterprise Logging Engine
# ==========================================
$BasePath       = $PSScriptRoot
$LogDir         = Join-Path $BasePath "logs"
$ArchiveDir     = Join-Path $LogDir "archive"
$LogFile        = Join-Path $LogDir "runner.log"
$ErrorLogFile   = Join-Path $LogDir "runner-error.log"
$MaxLogSizeMB   = 5
$ArchiveDays    = 30

$global:IsTestMode = $TestMode

# Always keep logs inside this script folder (including test mode)
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }

function Invoke-LogRotation {
    if ($global:IsTestMode) { return }
    if (-not (Test-Path $LogFile)) { return }

    $logFileInfo = Get-Item $LogFile
    if ($logFileInfo.Length / 1MB -gt $MaxLogSizeMB) {
        if (-not (Test-Path $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }
        
        $timestamp = (Get-Date).ToString("yyyy-MM-dd_HHmmss")
        $archivePath = Join-Path $ArchiveDir "runner_$timestamp.log"
        
        try {
            Move-Item -Path $LogFile -Destination $archivePath -Force
            # Clean old archives
            Get-ChildItem -Path $ArchiveDir -Filter "*.log" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$ArchiveDays) } | Remove-Item -Force
        } catch {
            Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [WARN] Failed to rotate log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Invoke-StartupLogArchive {
    if (-not (Test-Path $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }

    $timestamp = (Get-Date).ToString("yyyy-MM-dd_HHmmss")
    foreach ($path in @($LogFile, $ErrorLogFile)) {
        if (-not (Test-Path $path)) { continue }

        try {
            $baseName = [IO.Path]::GetFileNameWithoutExtension($path)
            $info = Get-Item $path -ErrorAction Stop
            if ($info.Length -gt 0) {
                Move-Item -Path $path -Destination (Join-Path $ArchiveDir "$baseName`_$timestamp.log") -Force
            } else {
                Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [WARN] Failed to archive old logs: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    try {
        Get-ChildItem -Path $ArchiveDir -Filter "*.log" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$ArchiveDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [WARN] Failed archive retention cleanup: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-Log {
    param(
        [string]$Message, 
        [string]$Level="INFO", 
        [ConsoleColor]$Color="White",
        [string]$Component="System"
    )
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $pidPad = $PID.ToString().PadRight(5)
    $logLine = "[$ts] [PID:$pidPad] [$Level] [$Component] $Message"
    
    # For test mode, use stdout for test harness capture; normal mode keeps colored host output
    if ($global:IsTestMode) {
        Write-Output $logLine
    } else {
        Write-Host $logLine -ForegroundColor $Color
    }

    $attempts = 0
    $success = $false
    
    # Safe Append with Retry for concurrency locks
    while ($attempts -lt 3 -and -not $success) {
        try {
            $logLine | Out-File -FilePath $LogFile -Append -Encoding UTF8 -ErrorAction Stop
            
            # Dual-write failures to the segregated error log
            if ($Level -match "^(ERROR|WARN)$") {
                $logLine | Out-File -FilePath $ErrorLogFile -Append -Encoding UTF8 -ErrorAction Stop
            }
            $success = $true
        } catch {
            $attempts++
            Start-Sleep -Milliseconds 200
        }
    }
}

if ($TestMode) {
    Write-Log "TEST MODE ENABLED - API calls MOCKED. Idle timeout reduced." "INFO" "Magenta" "Preflight"
}

# ==========================================
# 1.5. Layered Process Detection Module
# ==========================================
$ToolsDir = Join-Path $PSScriptRoot "tools"
$DetectionModule = Join-Path $ToolsDir "Process-Detection.ps1"

# Attempt to load detection module if available
$DetectionLoaded = $false
if (Test-Path $DetectionModule) {
    try {
        . $DetectionModule
        $DetectionLoaded = $true
    }
    catch {
        # Detection module failed to load, will use fallback Mutex guard only
    }
}

# ==========================================
# 2. Configuration & State Paths
# ==========================================
$EnvFilePath        = Join-Path $BasePath ".env"
$StateDir           = Join-Path $BasePath ".state"
$StateFile          = Join-Path $StateDir "trigger-state.json"
$BackrestConfigPath = "$env:APPDATA\backrest\config.json"
$BackrestEndpoint   = if ($env:BACKREST_ENDPOINT) { $env:BACKREST_ENDPOINT } else { "http://localhost:9900/v1.Backrest/Backup" }
$StopSignalFile     = Join-Path $BasePath ".stop-livebackup"
$IdleTimeSeconds    = if ($TestMode) { 10 } else { 15 }
$global:IdleTimeSeconds = $IdleTimeSeconds

# Ensure state directory exists lazily
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
if (Test-Path $StopSignalFile) { Remove-Item $StopSignalFile -ErrorAction SilentlyContinue }

# Archive old logs BEFORE any new logging (every run gets a clean log)
Invoke-StartupLogArchive
Invoke-LogRotation

# ==========================================
# 4. Layered Detection: Is watcher already running?
# ==========================================
if ($DetectionLoaded -and (Get-Command 'Test-WatcherIsRunning' -ErrorAction SilentlyContinue)) {
    try {
        $detection = Test-WatcherIsRunning -LogFile $LogFile -MutexName "Global\BackrestLiveMonitor_" -HeartbeatFreshSeconds 180
        
        if ($detection.IsRunning -and $detection.Confidence -in @('high', 'medium')) {
            $pidStr = if ($null -ne $detection.ProcessId) { $detection.ProcessId } else { 'unknown' }
            $ageStr = if ($null -ne $detection.HeartbeatAge) { "$($detection.HeartbeatAge)s" } else { 'N/A' }
            Write-Log "Watcher already running (PID: $pidStr, confidence: $($detection.Confidence)). Heartbeat age: $ageStr. Signals: $($detection.Signals.Values -join ', ')" "WARN" "Yellow" "Detection"
            Write-Log "To stop the watcher, create a file named '.stop-livebackup' in $BasePath or use 'Stop-Process -Id $pidStr'" "INFO" "Cyan" "Detection"
            exit 0
        } elseif ($detection.IsRunning -and $detection.Confidence -eq 'low') {
            Write-Log "Uncertain watcher state detected (low confidence). Waiting 3 seconds and rechecking..." "WARN" "Yellow" "Detection"
            Start-Sleep -Seconds 3
            $detectionRecheck = Test-WatcherIsRunning -LogFile $LogFile -MutexName "Global\BackrestLiveMonitor_" -HeartbeatFreshSeconds 180
            if ($detectionRecheck.IsRunning -and $detectionRecheck.Confidence -in @('high', 'medium')) {
                Write-Log "Watcher confirmed running on recheck (confidence: $($detectionRecheck.Confidence)). Exiting." "WARN" "Yellow" "Detection"
                exit 0
            } else {
                Write-Log "Recheck shows watcher not running (confidence: $($detectionRecheck.Confidence)). Proceeding with startup." "INFO" "Cyan" "Detection"
            }
        } else {
            Write-Log "Layered detection confirms watcher is not running. Safe to proceed." "INFO" "DarkGray" "Detection"
        }
    }
    catch {
        Write-Log "Detection layer encountered an error: $($_.Exception.Message). Falling back to Mutex guard." "WARN" "Yellow" "Detection"
    }
}

# ==========================================
# 5. Mutex / Ownership Guard (Fallback)
# ==========================================
$mutexName = "Global\BackrestLiveMonitor_$env:USERNAME"
$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)

if (-not $mutexCreated) {
    Write-Log "Another instance is already running (Mutex held). Exiting to prevent overlapping watchers." "WARN" "Yellow" "Preflight"
    exit 0
}

try {
    # ==========================================
    # 6. Preflight: Auth & Environment
    # ==========================================
    $AuthHeader = @{}
    if (Test-Path $EnvFilePath) {
        Get-Content $EnvFilePath | Where-Object { $_ -match "^[^#]" -and $_ -match "=" } | ForEach-Object {
            $name, $value = $_ -split '=', 2
            Set-Item -Path "env:\$($name.Trim())" -Value $value.Trim()
        }
        
        if ($env:BACKREST_USER -and $env:BACKREST_PASS) {
            $AuthBytes = [System.Text.Encoding]::UTF8.GetBytes("$($env:BACKREST_USER):$($env:BACKREST_PASS)")
            $AuthHeader = @{ Authorization = "Basic $([Convert]::ToBase64String($AuthBytes))" }
            Write-Log "Basic Authentication loaded from .env" "INFO" "Cyan" "Preflight"
        }
    } else {
        Write-Log "No .env file found. Proceeding without authentication." "INFO" "DarkGray" "Preflight"
    }

    # ==========================================
    # 5. Preflight: Parse Backrest Config
    # ==========================================
    if (-not (Test-Path $BackrestConfigPath)) {
        Write-Log "Backrest config not found at $BackrestConfigPath. Is Backrest installed?" "ERROR" "Red" "Preflight"
        exit 1
    }
    
    $config = Get-Content -Raw $BackrestConfigPath | ConvertFrom-Json
    $plansRaw  = $config.plans

    if (-not $plansRaw) {
        Write-Log "No plans found in Backrest configuration." "WARN" "Yellow" "Preflight"
        exit 0
    }

    $plans = @()
    foreach ($p in @($plansRaw)) {
        if (-not $p.id) { continue }
        $plans += [PSCustomObject]@{
            id    = $p.id
            name  = if ($null -ne $p.name) { $p.name } else { $p.id }
            paths = if ($null -ne $p.paths) { @($p.paths) } else { @() }
        }
    }

    # ==========================================
    # 6. Idempotent State Loading
    # ==========================================
    $global:PlanState = @{}
    $savedState = @{}
    if (Test-Path $StateFile) {
        try {
            $savedState = Get-Content -Raw $StateFile | ConvertFrom-Json -AsHashtable
            Write-Log "Loaded previous trigger state from disk." "INFO" "DarkGray" "State"
        } catch {
            Write-Log "Failed to parse state file. Starting fresh." "WARN" "Yellow" "State"
        }
    }

    # ==========================================
    # 7. Watcher Setup & Noise Filter
    # ==========================================
    $watchers = @()

    foreach ($plan in $plans) {
        $planId   = $plan.id
        $planName = $plan.name
        $paths    = $plan.paths
        
        if (-not $paths -or $paths.Count -eq 0) { continue }
        
        $global:PlanState[$planId] = @{
            Name          = $planName
            LastChange    = $null
            EventCount    = 0
            BatchNumber   = if ($savedState[$planId] -and $savedState[$planId].BatchNumber) { [int]$savedState[$planId].BatchNumber } else { 0 }
            CurrentBatchId = if ($savedState[$planId] -and $savedState[$planId].CurrentBatchId) { $savedState[$planId].CurrentBatchId } else { $null }
            QueueLogged = $false
            LastRun       = if ($savedState[$planId]) { $savedState[$planId].LastRun } else { $null }
        }
        
        foreach ($folder in $paths) {
            if (Test-Path -LiteralPath $folder) {
                $watcher = New-Object IO.FileSystemWatcher -ArgumentList $folder
                $watcher.IncludeSubdirectories = $true
                $watcher.NotifyFilter = [IO.NotifyFilters]::LastWrite, [IO.NotifyFilters]::FileName, [IO.NotifyFilters]::DirectoryName
                
                # Action: Filter noise, coalesce to Queue
                $action = {
                    $fileName = $Event.SourceEventArgs.Name
                    # Drop temp files, locks, swaps, and temp-backups before entering queue
                    if ($fileName -match '(?i)\.(tmp|temp|bak|swp|lock|log)$|^\~') { return }

                    $triggeredPlanId = $Event.MessageData
                    if ($global:PlanState[$triggeredPlanId].EventCount -eq 0) {
                        $global:PlanState[$triggeredPlanId].BatchNumber++
                        $global:PlanState[$triggeredPlanId].CurrentBatchId = "{0}-B{1:D4}" -f $triggeredPlanId, $global:PlanState[$triggeredPlanId].BatchNumber
                    }

                    $global:PlanState[$triggeredPlanId].LastChange = [DateTime]::Now
                    $global:PlanState[$triggeredPlanId].EventCount++
                    $batchId = $global:PlanState[$triggeredPlanId].CurrentBatchId

                    if ($global:PlanState[$triggeredPlanId].EventCount -eq 1) {
                        Write-Log "Change detected. Waiting $($global:IdleTimeSeconds)s of inactivity before dispatch for batch [$batchId]." "INFO" "DarkGray" $global:PlanState[$triggeredPlanId].Name
                    }
                    
                    if ($global:IsTestMode) {
                        Write-Log "Coalesced events queued for [$triggeredPlanId]" "TEST" "DarkGray" $global:PlanState[$triggeredPlanId].Name
                    }
                }

                # Fallback: Buffer Overflow Protection
                $errorAction = {
                    $faultedPlanId = $Event.MessageData
                    Write-Log "Watcher buffer overflow detected. Forcing queue update." "WARN" "Red" $global:PlanState[$faultedPlanId].Name
                    $global:PlanState[$faultedPlanId].LastChange = [DateTime]::Now
                    $global:PlanState[$faultedPlanId].EventCount += 100
                }
                
                Register-ObjectEvent $watcher 'Changed' -Action $action -MessageData $planId | Out-Null
                Register-ObjectEvent $watcher 'Renamed' -Action $action -MessageData $planId | Out-Null
                Register-ObjectEvent $watcher 'Created' -Action $action -MessageData $planId | Out-Null
                Register-ObjectEvent $watcher 'Deleted' -Action $action -MessageData $planId | Out-Null
                Register-ObjectEvent $watcher 'Error'   -Action $errorAction -MessageData $planId | Out-Null
                
                $watcher.EnableRaisingEvents = $true
                $watchers += $watcher
                
                Write-Log "Attached FileSystemWatcher: $folder" "INFO" "Cyan" $planName
            } else {
                Write-Log "Path not found, bypassing: $folder" "WARN" "Yellow" $planName
            }
        }
    }

    Write-Log "Waiting for idle bounds..." "INFO" "Green" "System"

    # ==========================================
    # 8. Queue Processing & Batch Execution
    # ==========================================
    $stateChanged = $false

    while ($true) {
        # Safe-stop boundary check
        if (Test-Path $StopSignalFile) {
            Write-Log "Safe stop signal detected. Shutting down cleanly..." "INFO" "Magenta" "Manager"
            Remove-Item $StopSignalFile -Force -ErrorAction SilentlyContinue
            break
        }

        Start-Sleep -Seconds 5
        $now = [DateTime]::Now
        $activePlans = @($global:PlanState.Keys)
        
        foreach ($planId in $activePlans) {
            $state      = $global:PlanState[$planId]
            $lastChange = $state.LastChange
            $events     = $state.EventCount
            $planName   = $state.Name
            $batchId    = if ($state.CurrentBatchId) { $state.CurrentBatchId } else { "${planId}-B0000" }
            
            # Dequeue condition: Events exist AND debounce window satisfied
            if ($global:IsTestMode -and $events -gt 0 -and -not $state.QueueLogged) {
                Write-Log "Coalesced events queued for [$planId]" "TEST" "DarkGray" $planName
                $global:PlanState[$planId].QueueLogged = $true
            }

            if ($null -ne $lastChange -and $events -gt 0 -and ($now - $lastChange).TotalSeconds -ge $IdleTimeSeconds) {
                
                Write-Log "Batch flush: Triggering [$planName] covering $events coalesced event(s). BatchId=[$batchId]" "INFO" "Yellow" $planName
                
                $JsonPayload = @{ value = $planId } | ConvertTo-Json -Compress
                $apiSuccess = $false
                if ($global:IsTestMode) {
                    Write-Log "API call MOCKED. Job skipped for batch [$batchId]." "TEST" "Magenta" $planName
                    $apiSuccess = $true
                } else {
                    $RestParams = @{
                        Uri         = $BackrestEndpoint
                        Method      = 'Post'
                        Body        = $JsonPayload
                        ContentType = 'application/json'
                        TimeoutSec  = 2
                    }
                    if ($AuthHeader.Count -gt 0) { $RestParams.Headers = $AuthHeader }
                    
                    try {
                        Invoke-RestMethod @RestParams | Out-Null
                        Write-Log "Job successfully dispatched to background processor for batch [$batchId]." "SUCCESS" "Green" $planName
                        $apiSuccess = $true
                    } 
                    catch {
                        $exceptionType = $_.Exception.GetType().Name
                        $exceptionMessage = $_.Exception.Message
                        $isTimeoutAccepted = ($exceptionType -eq "WebException" -and $_.Exception.Status -eq "Timeout") -or
                                             ($exceptionType -eq "TaskCanceledException") -or
                                             ($exceptionType -eq "HttpRequestException" -and $exceptionMessage -match "Timeout")

                        if ($isTimeoutAccepted) {
                            Write-Log "Job successfully dispatched to background processor for batch [$batchId]." "SUCCESS" "Green" $planName
                            $apiSuccess = $true
                        } else {
                            Write-Log "API dispatch failed for batch [$batchId]: $exceptionMessage" "ERROR" "Red" $planName
                        }
                    }
                }
                
                # Update queue state
                if ($apiSuccess) {
                    $global:PlanState[$planId].LastChange = $null
                    $global:PlanState[$planId].EventCount = 0
                    $global:PlanState[$planId].QueueLogged = $false
                    $global:PlanState[$planId].LastRun    = $now.ToString("o")
                    $stateChanged = $true
                }
            }
        }

        # Flush idempotent state boundaries
        if ($stateChanged) {
            try {
                $global:PlanState | ConvertTo-Json -Depth 3 -Compress | Set-Content $StateFile
                $stateChanged = $false
            } catch {
                Write-Log "Failed to flush state to disk: $($_.Exception.Message)" "WARN" "Yellow" "State"
            }
        }
    }
}
finally {
    Write-Log "Releasing resources and unbinding watcher pool..." "INFO" "DarkGray" "System"
    
    try { $global:PlanState | ConvertTo-Json -Depth 3 -Compress | Set-Content $StateFile } catch {}

    $watchers | ForEach-Object { 
        $_.EnableRaisingEvents = $false
        $_.Dispose() 
    }
    if ($null -ne $mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
    
    Write-Log "Shutdown complete." "INFO" "DarkGray" "System"
}