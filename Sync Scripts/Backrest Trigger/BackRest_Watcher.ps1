param (
    [switch]$TestMode
)

# ==========================================
# 1. Structured Observability & Setup
# ==========================================
function Write-Log {
    param([string]$Message, [string]$Level="INFO", [ConsoleColor]$Color="White")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $pidPad = $PID.ToString().PadRight(5)
    Write-Host "[$ts] [PID:$pidPad] [$Level] $Message" -ForegroundColor $Color
}

$BasePath           = $PSScriptRoot
$EnvFilePath        = Join-Path $BasePath ".env"
$StateDir           = Join-Path $BasePath ".state"
$StateFile          = Join-Path $StateDir "trigger-state.json"
$BackrestConfigPath = "$env:APPDATA\backrest\config.json"
$BackrestEndpoint   = "http://localhost:9898/v1.Backrest/Backup"
$StopSignalFile     = Join-Path $BasePath ".stop-livebackup"
$IdleTimeSeconds    = if ($TestMode) { 10 } else { 120 }
$global:IsTestMode  = $TestMode

if ($TestMode) {
    Write-Log "TEST MODE ENABLED - Idle timeout: $IdleTimeSeconds sec. API calls MOCKED." "INFO" "Magenta"
}

# Ensure state directory exists
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
if (Test-Path $StopSignalFile) { Remove-Item $StopSignalFile -ErrorAction SilentlyContinue }

# ==========================================
# 2. Mutex / Ownership Guard
# ==========================================
$mutexName = "Global\BackrestLiveMonitor_$env:USERNAME"
$mutexCreated = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$mutexCreated)

if (-not $mutexCreated) {
    Write-Log "Another instance is already running. Exiting to prevent overlapping watchers." "WARN" "Yellow"
    exit 0
}

try {
    # ==========================================
    # 3. Preflight: Auth & Environment
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
            Write-Log "Authentication loaded from .env" "INFO" "Cyan"
        }
    } else {
        Write-Log "No .env file found. Proceeding without authentication." "INFO" "DarkGray"
    }

    # ==========================================
    # 4. Preflight: Parse Backrest Config
    # ==========================================
    if (-not (Test-Path $BackrestConfigPath)) {
        Write-Log "CRITICAL: Backrest config not found at $BackrestConfigPath. Is Backrest installed?" "ERROR" "Red"
        exit 1
    }

    $config = Get-Content -Raw $BackrestConfigPath | ConvertFrom-Json
    $plansRaw  = $config.plans

    if (-not $plansRaw) {
        Write-Log "No plans found in Backrest configuration." "WARN" "Yellow"
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
    # 5. Idempotent State Loading
    # ==========================================
    $global:PlanState = @{}
    $savedState = @{}
    if (Test-Path $StateFile) {
        try {
            $savedState = Get-Content -Raw $StateFile | ConvertFrom-Json -AsHashtable
            Write-Log "Loaded previous trigger state from disk." "INFO" "DarkGray"
        } catch {
            Write-Log "Failed to parse state file. Starting fresh." "WARN" "Yellow"
        }
    }

    # ==========================================
    # 6. Intelligent Watcher Setup & Noise Filter
    # ==========================================
    $watchers = @()

    foreach ($plan in $plans) {
        $planId   = $plan.id
        $planName = $plan.name
        $paths    = $plan.paths
        
        if (-not $paths -or $paths.Count -eq 0) { continue }
        
        # Initialize state per entity (Queue)
        $global:PlanState[$planId] = @{
            Name       = $planName
            LastChange = $null
            EventCount = 0
            LastRun    = if ($savedState[$planId]) { $savedState[$planId].LastRun } else { $null }
        }
        
        foreach ($folder in $paths) {
            if (Test-Path -LiteralPath $folder) {
                $watcher = New-Object IO.FileSystemWatcher -ArgumentList $folder
                $watcher.IncludeSubdirectories = $true
                $watcher.NotifyFilter = [IO.NotifyFilters]::LastWrite, [IO.NotifyFilters]::FileName, [IO.NotifyFilters]::DirectoryName
                
                # Action: Filter noise, then Queue
                $action = {
                    $fileName = $Event.SourceEventArgs.Name
                    # Ignore noise: temp files, swap files, lock files, and ~ backups
                    if ($fileName -match '(?i)\.(tmp|temp|bak|swp|lock|log)$|^\~') { return }

                    $triggeredPlanId = $Event.MessageData
                    $global:PlanState[$triggeredPlanId].LastChange = [DateTime]::Now
                    $global:PlanState[$triggeredPlanId].EventCount++
                    
                    if ($global:IsTestMode -and ($global:PlanState[$triggeredPlanId].EventCount % 10 -eq 1)) {
                        Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [PID:$($PID.ToString().PadRight(5))] [TEST] Coalesced events queued for [$triggeredPlanId]." -ForegroundColor DarkGray
                    }
                }

                # Fallback detection for Buffer Overflows
                $errorAction = {
                    $faultedPlanId = $Event.MessageData
                    Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [PID:$($PID.ToString().PadRight(5))] [WARN] Buffer overflow for [$faultedPlanId]. Forcing queue update." -ForegroundColor Red
                    $global:PlanState[$faultedPlanId].LastChange = [DateTime]::Now
                    $global:PlanState[$faultedPlanId].EventCount += 100 # Arbitrary bump to indicate mass change
                }
                
                Register-ObjectEvent $watcher 'Changed' -Action $action -MessageData $planId | Out-Null
                Register-ObjectEvent $watcher 'Renamed' -Action $action -MessageData $planId | Out-Null
                Register-ObjectEvent $watcher 'Created' -Action $action -MessageData $planId | Out-Null
                Register-ObjectEvent $watcher 'Deleted' -Action $action -MessageData $planId | Out-Null
                Register-ObjectEvent $watcher 'Error'   -Action $errorAction -MessageData $planId | Out-Null
                
                $watcher.EnableRaisingEvents = $true
                $watchers += $watcher
                
                Write-Log "Watching [$planName]: $folder" "INFO" "Cyan"
            } else {
                Write-Log "Path not found in plan '$planName': $folder" "WARN" "Yellow"
            }
        }
    }

    Write-Log "Dynamic Tripwire active. Coalescing events and waiting for idle bounds..." "INFO" "Green"

    # ==========================================
    # 7. Queue Processing & Batch Execution
    # ==========================================
    $stateChanged = $false

    while ($true) {
        # Safe-stop signaling
        if (Test-Path $StopSignalFile) {
            Write-Log "Safe stop signal detected ($StopSignalFile). Shutting down cleanly." "INFO" "Magenta"
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
            
            # Dequeue condition: Queued events exist AND debounce timeout has passed
            if ($null -ne $lastChange -and $events -gt 0 -and ($now - $lastChange).TotalSeconds -ge $IdleTimeSeconds) {
                
                # Batch Summary Log
                Write-Log "Batch flush: Triggering [$planName] covering $events coalesced event(s)." "INFO" "Yellow"
                
                $JsonPayload = @{ value = $planId } | ConvertTo-Json -Compress
                $apiSuccess = $false
                
                if ($global:IsTestMode) {
                    Write-Log "API call mocked for [$planName]. Backup NOT actually triggered." "TEST" "Magenta"
                    $apiSuccess = $true
                } else {
                    $RestParams = @{
                        Uri         = $BackrestEndpoint
                        Method      = 'Post'
                        Body        = $JsonPayload
                        ContentType = 'application/json'
                        TimeoutSec  = 1
                    }
                    if ($AuthHeader.Count -gt 0) { $RestParams.Headers = $AuthHeader }
                    
                    try {
                        Invoke-RestMethod @RestParams | Out-Null
                    } 
                    catch {
                        if ($_.Exception.GetType().Name -eq "WebException" -and $_.Exception.Status -eq "Timeout") {
                            Write-Log "Background backup successfully dispatched for [$planName]." "SUCCESS" "Green"
                            $apiSuccess = $true
                        } else {
                            Write-Log "API call failed for [$planName]: $($_.Exception.Message)" "ERROR" "Red"
                        }
                    }
                }
                
                # On success, clear the queue and update state
                if ($apiSuccess) {
                    $global:PlanState[$planId].LastChange = $null
                    $global:PlanState[$planId].EventCount = 0
                    $global:PlanState[$planId].LastRun    = $now.ToString("o")
                    $stateChanged = $true
                }
            }
        }

        # Save Idempotent State only if a batch was processed
        if ($stateChanged -and -not $global:IsTestMode) {
            try {
                $global:PlanState | ConvertTo-Json -Depth 3 -Compress | Set-Content $StateFile
                $stateChanged = $false
            } catch {
                Write-Log "Failed to write state file: $($_.Exception.Message)" "WARN" "Yellow"
            }
        }
    }
}
finally {
    # Clean up gracefully
    Write-Log "Releasing resources and stopping watchers..." "INFO" "DarkGray"
    
    if (-not $global:IsTestMode) {
        try { $global:PlanState | ConvertTo-Json -Depth 3 -Compress | Set-Content $StateFile } catch {}
    }

    $watchers | ForEach-Object { 
        $_.EnableRaisingEvents = $false
        $_.Dispose() 
    }
    if ($null -ne $mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}