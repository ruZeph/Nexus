# ==========================================
# Comprehensive Test Suite for Start-LiveBackup.ps1
# ==========================================

$ErrorActionPreference = "Stop"
$ScriptToTest = Join-Path $PSScriptRoot "Start-LiveBackup.ps1"

# Fallback in case the script is named BackRest_Watcher.ps1
if (-not (Test-Path $ScriptToTest)) {
    $ScriptToTest = Join-Path $PSScriptRoot "BackRest_Watcher.ps1"
}

if (-not (Test-Path $ScriptToTest)) {
    Write-Host "[FAIL] Could not find the LiveBackup script in the current directory." -ForegroundColor Red
    exit 1
}

# ==========================================
# 1. Workspace Setup
# ==========================================
$TestWorkspace = Join-Path $env:TEMP "BackrestLiveMonitorTest_$(Get-Random)"
$MockAppData   = Join-Path $TestWorkspace "AppData"
$MockConfigDir = Join-Path $MockAppData "backrest"
$MockConfig    = Join-Path $MockConfigDir "config.json"
$TargetFolder1 = Join-Path $TestWorkspace "Target_Folder_A"
$StdoutLog     = Join-Path $TestWorkspace "runner-stdout.log"
$ServiceLog    = Join-Path $PSScriptRoot "logs\runner.log"
$ServiceErrorLog = Join-Path $PSScriptRoot "logs\runner-error.log"
$StateFile     = Join-Path $PSScriptRoot ".state\trigger-state.json"
$RuntimeStateFile = Join-Path $PSScriptRoot ".state\runtime-state.json"
$TestUsername  = "TestUser_$(Get-Random)"

Write-Host "Setting up test workspace at $TestWorkspace..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $MockConfigDir -Force | Out-Null
New-Item -ItemType Directory -Path $TargetFolder1 -Force | Out-Null

# Create Mock Backrest Config
$mockJson = @"
{
  "plans": [
    {
      "id": "Test-Plan-A",
      "name": "Mock Database Backup",
      "paths": [ "$($TargetFolder1.Replace('\', '\\'))" ]
    }
  ]
}
"@
Set-Content -Path $MockConfig -Value $mockJson

# ==========================================
# 2. Helper Functions
# ==========================================
function Assert-LogContains {
    param(
        [string]$Pattern,
        [int]$TimeoutSeconds = 15,
        [string]$LogPath = $ServiceLog
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path $LogPath) {
            $logs = Get-Content $LogPath -ErrorAction SilentlyContinue
            if ($logs -match $Pattern) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-LogMatchCount {
    param(
        [string]$Pattern,
        [string]$LogPath = $ServiceLog
    )

    if (-not (Test-Path $LogPath)) { return 0 }
    return @((Get-Content $LogPath -ErrorAction SilentlyContinue) | Select-String -Pattern $Pattern).Count
}

# ==========================================
# 3. Launch the Monitor in a Sandbox
# ==========================================
Write-Host "Launching script in background test mode..." -ForegroundColor Cyan

# We use Start-Process to run it in a completely isolated environment,
# redirecting APPDATA so it reads our mock config without touching your real Backrest setup.
# NOTE: *>&1 is required to capture Write-Host (Stream 6) into Out-File
$psArgs = "-NoProfile -ExecutionPolicy Bypass -Command `" `
    `$env:APPDATA = '$MockAppData'; `
    `$env:USERNAME = '$TestUsername'; `
    & '$ScriptToTest' -TestMode *>&1 | Out-File -FilePath '$StdoutLog' -Encoding UTF8 `" "

$process = Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -PassThru -WindowStyle Hidden

# Wait for startup
if (-not (Assert-LogContains "Waiting for idle bounds" 20 $ServiceLog)) {
    Write-Host "[FAIL] Script failed to initialize or start watchers. Check $ServiceLog for details." -ForegroundColor Red
    Stop-Process -Id $process.Id -Force
    exit 1
}
Write-Host "[PASS] Script initialized and watching folders." -ForegroundColor Green

# ==========================================
# 4. Execute Test Cases
# ==========================================
$TestsPassed = 0
$TestsFailed = 0

try {
    # ---------------------------------------------------------
    # TEST 1: Mutex Lock (Double-Run Prevention)
    # ---------------------------------------------------------
    Write-Host "`nRunning Test 1: Mutex Ownership Guard..."
    $secondProcArgs = "-NoProfile -ExecutionPolicy Bypass -Command `" `
        `$env:APPDATA = '$MockAppData'; `
        `$env:USERNAME = '$TestUsername'; `
        & '$ScriptToTest' -TestMode *>&1 | Out-File -FilePath '$TestWorkspace\runner2.log' -Encoding UTF8 `" "
    $proc2 = Start-Process -FilePath "powershell.exe" -ArgumentList $secondProcArgs -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $proc2Log = Get-Content "$TestWorkspace\runner2.log" -ErrorAction SilentlyContinue
    if ($proc2Log -match "Another instance is already running") {
        Write-Host "[PASS] Second instance correctly blocked by Mutex." -ForegroundColor Green
        $TestsPassed++
    } else {
        Write-Host "[FAIL] Mutex did not block second instance." -ForegroundColor Red
        $TestsFailed++
    }
    if (-not $proc2.HasExited) { Stop-Process -Id $proc2.Id -Force }

    # ---------------------------------------------------------
    # TEST 2: Noise Filtering
    # ---------------------------------------------------------
    Write-Host "`nRunning Test 2: Noise Filtering (.tmp files)..."
    $queueCountBeforeNoise = Get-LogMatchCount "Coalesced events queued for \[Test-Plan-A\]" $ServiceLog
    New-Item -ItemType File -Path (Join-Path $TargetFolder1 "ignore_me.tmp") | Out-Null
    Start-Sleep -Seconds 3
    $queueCountAfterNoise = Get-LogMatchCount "Coalesced events queued for \[Test-Plan-A\]" $ServiceLog
    if ($queueCountAfterNoise -eq $queueCountBeforeNoise) {
        Write-Host "[PASS] .tmp file was successfully ignored." -ForegroundColor Green
        $TestsPassed++
    } else {
        Write-Host "[FAIL] Watcher queued an event for a .tmp file." -ForegroundColor Red
        $TestsFailed++
    }

    # ---------------------------------------------------------
    # TEST 3: Event Coalescing
    # ---------------------------------------------------------
    Write-Host "`nRunning Test 3: Event Coalescing..."
    $queueCountBeforeBurst = Get-LogMatchCount "Coalesced events queued for \[Test-Plan-A\]" $ServiceLog
    $dataPath = Join-Path $TargetFolder1 "data.txt"
    for ($i=1; $i -le 15; $i++) {
        $written = $false
        for ($attempt=1; $attempt -le 5 -and -not $written; $attempt++) {
            try {
                Set-Content -Path $dataPath -Value "Line $i" -ErrorAction Stop
                $written = $true
            } catch {
                if ($attempt -eq 5) { throw }
                Start-Sleep -Milliseconds (40 * $attempt)
            }
        }
    }
    $queueLogged = Assert-LogContains "Coalesced events queued for \[Test-Plan-A\]" 8 $ServiceLog
    $queueCountAfterBurst = Get-LogMatchCount "Coalesced events queued for \[Test-Plan-A\]" $ServiceLog
    if ($queueLogged -and $queueCountAfterBurst -gt $queueCountBeforeBurst) {
        Write-Host "[PASS] Multiple file changes successfully coalesced into queue." -ForegroundColor Green
        $TestsPassed++
    } else {
        Write-Host "[FAIL] Events were not queued." -ForegroundColor Red
        $TestsFailed++
    }

    # ---------------------------------------------------------
    # TEST 4: Debounce Timeout & API Trigger
    # ---------------------------------------------------------
    Write-Host "`nRunning Test 4: Idle Debounce & API Trigger..."
    Write-Host "Waiting up to 25s for the 10-second idle debounce to elapse..." -ForegroundColor DarkGray
    if (Assert-LogContains "Batch flush: Triggering \[Mock Database Backup\] covering .* coalesced event" 25 $ServiceLog) {
        Write-Host "[PASS] Batch successfully flushed after idle debounce." -ForegroundColor Green
        $TestsPassed++
    } else {
        Write-Host "[FAIL] Batch flush did not occur within timeout." -ForegroundColor Red
        $TestsFailed++
    }

    # ---------------------------------------------------------
    # TEST 5: Idempotent State Persistence
    # ---------------------------------------------------------
    Write-Host "`nRunning Test 5: Idempotent State Verification..."
    if (Test-Path $StateFile) {
        $stateContent = Get-Content $StateFile -Raw | ConvertFrom-Json
        if ($null -ne $stateContent.Plans."Test-Plan-A".LastRun -and (Test-Path $RuntimeStateFile)) {
            Write-Host "[PASS] State file created and LastRun timestamp recorded." -ForegroundColor Green
            $TestsPassed++
        } else {
            Write-Host "[FAIL] State file exists but missing LastRun data." -ForegroundColor Red
            $TestsFailed++
        }
    } else {
        Write-Host "[FAIL] State file was not created on disk." -ForegroundColor Red
        $TestsFailed++
    }

    # ---------------------------------------------------------
    # TEST 6: Safe Stop Signaling
    # ---------------------------------------------------------
    Write-Host "`nRunning Test 6: Safe-Stop Signaling..."
    $StopFile = Join-Path $PSScriptRoot ".stop-livebackup"
    New-Item -ItemType File -Path $StopFile -Force | Out-Null
    if (Assert-LogContains "Safe stop signal detected.*Shutting down cleanly" 15 $ServiceLog) {
        Write-Host "[PASS] Script detected stop signal and shut down gracefully." -ForegroundColor Green
        $TestsPassed++
    } else {
        Write-Host "[FAIL] Script ignored stop signal." -ForegroundColor Red
        $TestsFailed++
    }

} finally {
    # ==========================================
    # 5. Cleanup
    # ==========================================
    Write-Host "`nCleaning up test environment..." -ForegroundColor Cyan
    if (-not $process.HasExited) { 
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue 
    }
    if (Test-Path $TestWorkspace) { Remove-Item -Path $TestWorkspace -Recurse -Force -ErrorAction SilentlyContinue }
    
    # Do not delete the user's real state dir, but clean up the mocked test entry if possible
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $RuntimeStateFile) { Remove-Item $RuntimeStateFile -Force -ErrorAction SilentlyContinue }
    
    $StopFile = Join-Path $PSScriptRoot ".stop-livebackup"
    if (Test-Path $StopFile) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue }

    Write-Host "`n=========================================="
    Write-Host " Test Summary"
    Write-Host " Passed: $TestsPassed" -ForegroundColor Green
    Write-Host " Failed: $TestsFailed" -ForegroundColor $(if ($TestsFailed -gt 0) { "Red" } else { "Green" })
    Write-Host "=========================================="
}
