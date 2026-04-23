param (
    [switch]$TestMode
)

# ==========================================
# 1. Configuration & Auth Setup
# ==========================================
$BasePath           = $PSScriptRoot
$EnvFilePath        = Join-Path $BasePath ".env"
$BackrestConfigPath = "$env:APPDATA\backrest\config.json"
$BackrestEndpoint   = "http://localhost:9090/v1.Backrest/Backup"
$IdleTimeSeconds    = if ($TestMode) { 10 } else { 120 }
$global:IsTestMode  = $TestMode

if ($TestMode) {
    Write-Host "==========================================" -ForegroundColor Magenta
    Write-Host " TEST MODE ENABLED" -ForegroundColor Magenta
    Write-Host " - Idle timeout reduced to $IdleTimeSeconds seconds." -ForegroundColor Magenta
    Write-Host " - API calls will be MOCKED (No backups triggered)." -ForegroundColor Magenta
    Write-Host "==========================================" -ForegroundColor Magenta
}

$AuthHeader = @{}

# Load Auth from .env if it exists (Default is no auth)
if (Test-Path $EnvFilePath) {
    Get-Content $EnvFilePath | Where-Object { $_ -match "^[^#]" -and $_ -match "=" } | ForEach-Object {
        $name, $value = $_ -split '=', 2
        Set-Item -Path "env:\$($name.Trim())" -Value $value.Trim()
    }
    
    if ($env:BACKREST_USER -and $env:BACKREST_PASS) {
        $AuthBytes = [System.Text.Encoding]::UTF8.GetBytes("$($env:BACKREST_USER):$($env:BACKREST_PASS)")
        $AuthHeader = @{ Authorization = "Basic $([Convert]::ToBase64String($AuthBytes))" }
        Write-Host "Authentication loaded from .env" -ForegroundColor Cyan
    }
} else {
    Write-Host "No .env file found. Proceeding without authentication." -ForegroundColor DarkGray
}

# ==========================================
# 2. Parse Backrest Config Dynamically
# ==========================================
if (-not (Test-Path $BackrestConfigPath)) {
    Write-Error "CRITICAL: Backrest config not found at $BackrestConfigPath. Is Backrest installed?"
    exit 1
}

$config = Get-Content -Raw $BackrestConfigPath | ConvertFrom-Json
$plans  = $config.plans

if (-not $plans) {
    Write-Warning "No plans found in Backrest configuration."
    exit 0
}

# ==========================================
# 3. Intelligent Watcher Setup (Per Plan)
# ==========================================
# Dictionary to track independent idle timers for each Plan ID
$global:PlanLastChange = @{}
$watchers = @()

foreach ($plan in $plans) {
    $planId   = $plan.id
    $planName = $plan.name
    $paths    = $plan.paths
    
    if (-not $paths) { continue }
    
    foreach ($folder in $paths) {
        if (Test-Path -LiteralPath $folder) {
            $watcher = New-Object IO.FileSystemWatcher -ArgumentList $folder
            $watcher.IncludeSubdirectories = $true
            $watcher.NotifyFilter = [IO.NotifyFilters]::LastWrite, [IO.NotifyFilters]::FileName, [IO.NotifyFilters]::DirectoryName
            
            # Action uses the specific Plan ID passed via MessageData
            $action = {
                $triggeredPlanId = $Event.MessageData
                $global:PlanLastChange[$triggeredPlanId] = [DateTime]::Now
                if ($global:IsTestMode) {
                    Write-Host "[TEST MODE] File change detected. Timer reset." -ForegroundColor DarkGray
                }
            }
            
            # Pass the Plan ID natively into the event so it knows exactly which plan to trigger
            Register-ObjectEvent $watcher 'Changed' -Action $action -MessageData $planId | Out-Null
            Register-ObjectEvent $watcher 'Renamed' -Action $action -MessageData $planId | Out-Null
            Register-ObjectEvent $watcher 'Created' -Action $action -MessageData $planId | Out-Null
            Register-ObjectEvent $watcher 'Deleted' -Action $action -MessageData $planId | Out-Null
            
            $watcher.EnableRaisingEvents = $true
            $watchers += $watcher
            
            Write-Host "Monitoring [$planName]: $folder" -ForegroundColor Cyan
        } else {
            Write-Warning "Path not found in plan '$planName': $folder"
        }
    }
}

Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Dynamic Tripwire active. Waiting for file changes..." -ForegroundColor Green

# ==========================================
# 4. Independent Execution Loop
# ==========================================
try {
    while ($true) {
        Start-Sleep -Seconds 5
        $now = [DateTime]::Now
        
        # Copy keys to a local array to prevent collection modification errors during the loop
        $activePlans = @($global:PlanLastChange.Keys)
        
        foreach ($planId in $activePlans) {
            $lastChange = $global:PlanLastChange[$planId]
            
            # If this specific plan has changes AND has passed the idle timeout
            if ($null -ne $lastChange -and ($now - $lastChange).TotalSeconds -ge $IdleTimeSeconds) {
                
                # Retrieve plan name just for logging
                $targetPlan = $plans | Where-Object { $_.id -eq $planId }
                Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Idle timeout reached for [$($targetPlan.name)]. Signaling Backrest API..." -ForegroundColor Yellow
                
                $JsonPayload = @{ value = $planId } | ConvertTo-Json -Compress
                
                if ($global:IsTestMode) {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [TEST MODE] API call mocked for [$($targetPlan.name)]. Backup NOT actually triggered." -ForegroundColor Magenta
                } else {
                    # Splatting parameters to handle optional Auth Headers cleanly
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
                            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Background backup successfully triggered for [$($targetPlan.name)]." -ForegroundColor Green
                        } else {
                            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] API call failed for [$($targetPlan.name)]: $($_.Exception.Message)"
                        }
                    }
                }
                
                # Clear the timer for this specific plan
                $global:PlanLastChange[$planId] = $null
            }
        }
    }
}
finally {
    $watchers | ForEach-Object { 
        $_.EnableRaisingEvents = $false
        $_.Dispose() 
    }
}