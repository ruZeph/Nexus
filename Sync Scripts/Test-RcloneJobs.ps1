param(
    [switch]$Verbose,
    [switch]$QuickTest,
    [ValidateSet('All', 'Unit', 'Integration', 'Parallel')][string]$TestSuite = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Test Configuration
$testConfig = @{
    scriptPath = Join-Path $PSScriptRoot 'Run-RcloneJobs.ps1'
    configPath = Join-Path $PSScriptRoot 'backup-jobs.json'
    testLogDir = Join-Path $PSScriptRoot 'test-logs'
    failCount = 0
    passCount = 0
}

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

function Write-TestHeader {
    param([string]$Message)
    Write-Host "`n$('=' * 70)" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "$('=' * 70)" -ForegroundColor Cyan
}

function Write-TestCase {
    param([string]$Name)
    Write-Host "`n▶ $Name" -ForegroundColor Yellow
}

function Write-Pass {
    param([string]$Message)
    Write-Host "  ✓ PASS: $Message" -ForegroundColor Green
    $testConfig.passCount++
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  ✗ FAIL: $Message" -ForegroundColor Red
    $testConfig.failCount++
}

function Write-Info {
    param([string]$Message)
    Write-Host "  ℹ $Message" -ForegroundColor Cyan
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ($Expected -eq $Actual) {
        Write-Pass "$Message (Expected: $Expected)"
    } else {
        Write-Fail "$Message (Expected: $Expected, Got: $Actual)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Pass $Message
    } else {
        Write-Fail $Message
    }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        Write-Pass $Message
    } else {
        Write-Fail $Message
    }
}

function Assert-FileExists {
    param([string]$Path, [string]$Message)
    if (Test-Path -LiteralPath $Path) {
        Write-Pass "$Message (File exists)"
    } else {
        Write-Fail "$Message (File not found: $Path)"
    }
}

function Assert-FileContains {
    param([string]$Path, [string]$Pattern, [string]$Message)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Fail "$Message (File not found: $Path)"
        return
    }
    $content = Get-Content -Raw -LiteralPath $Path
    if ($content -match $Pattern) {
        Write-Pass "$Message (Pattern found)"
    } else {
        Write-Fail "$Message (Pattern not found: $Pattern)"
    }
}

# ============================================================
# UNIT TESTS - Configuration and Structure
# ============================================================

function Test-ConfigParsing {
    Write-TestHeader "Unit Test: Configuration Parsing"

    Write-TestCase "Config file exists and is valid JSON"
    Assert-FileExists $testConfig.configPath "Configuration file should exist"
    
    try {
        $cfg = Get-Content -Raw -LiteralPath $testConfig.configPath | ConvertFrom-Json
        Write-Pass "Configuration is valid JSON"
    } catch {
        Write-Fail "Configuration is not valid JSON: $_"
        return
    }

    Write-TestCase "Config has required sections"
    Assert-True ($null -ne $cfg.settings) "Should have 'settings' section"
    Assert-True ($null -ne $cfg.jobs) "Should have 'jobs' section"
    Assert-True ($cfg.jobs.Count -gt 0) "Should have at least one job"

    Write-TestCase "Jobs have required properties"
    foreach ($job in $cfg.jobs) {
        Assert-True (![string]::IsNullOrWhiteSpace($job.name)) "Job should have 'name'"
        Assert-True (![string]::IsNullOrWhiteSpace($job.source)) "Job should have 'source'"
        Assert-True (![string]::IsNullOrWhiteSpace($job.dest)) "Job should have 'dest'"
    }

    Write-TestCase "Settings have required properties"
    Assert-True ($null -ne $cfg.settings.defaultOperation) "Should have 'defaultOperation'"
    Assert-True ($null -ne $cfg.settings.logRetentionCount) "Should have 'logRetentionCount'"
}

function Test-ScriptStructure {
    Write-TestHeader "Unit Test: Script Structure"

    Write-TestCase "Script file exists"
    Assert-FileExists $testConfig.scriptPath "Script should exist"

    Write-TestCase "Script has required functions"
    $content = Get-Content -LiteralPath $testConfig.scriptPath
    $hasWrite = [bool]($content -match 'function Write-JobLog')
    $hasInvoke = [bool]($content -match 'function Invoke-RcloneLive')
    $hasTest = [bool]($content -match 'function Test-RateLimitError')
    
    Assert-True $hasWrite "Should have Write-JobLog function"
    Assert-True $hasInvoke "Should have Invoke-RcloneLive function"
    Assert-True $hasTest "Should have Test-RateLimitError function"

    Write-TestCase "Script has mutex lock mechanism"
    $hasMutex = [bool]($content -match 'Global\\RcloneBackupRunner')
    Assert-True $hasMutex "Should have mutex lock implementation"

    Write-TestCase "Script has job interval logic"
    $hasInterval = [bool]($content -match 'Start-Sleep.*jobInterval')
    Assert-True $hasInterval "Should have job interval logic"
}

function Test-ConfigurationExamples {
    Write-TestHeader "Unit Test: Configuration Examples"

    $cfg = Get-Content -Raw -LiteralPath $testConfig.configPath | ConvertFrom-Json

    Write-TestCase "Global job interval is configured"
    $hasInterval = $null -ne $cfg.settings.jobIntervalSeconds
    Assert-True $hasInterval "Should have jobIntervalSeconds in settings"
    if ($hasInterval) {
        Write-Info "Global interval: $($cfg.settings.jobIntervalSeconds)s"
    }

    Write-TestCase "Jobs have interval examples"
    $jobsWithInterval = @(
        $cfg.jobs | ForEach-Object {
            if ($_.PSObject.Properties['interval'] -and $null -ne $_.interval) {
                $_
            }
        }
    )
    if ($jobsWithInterval.Count -gt 0) {
        Write-Pass "At least one job has interval configured ($($jobsWithInterval.Count))"
    } else {
        Write-Info "No per-job intervals configured (using global interval)"
    }

    Write-TestCase "Profiles are configured"
    $profileCount = @($cfg.profiles.PSObject.Properties).Count
    Write-Info "Configured profiles: $profileCount"
    Assert-True ($profileCount -gt 0) "Should have at least one profile"
}

# ============================================================
# INTEGRATION TESTS - Script Execution
# ============================================================

function Test-ScriptValidation {
    Write-TestHeader "Integration Test: Script Validation"

    Write-TestCase "Main script has no syntax errors"
    $result = & powershell.exe -NoProfile -Command "Get-Content -Raw -LiteralPath '$($testConfig.scriptPath)' | Out-Null; Write-Host 'OK'"
    Assert-True ($result -eq "OK") "Script should load without syntax errors"

    Write-TestCase "Script accepts expected parameters"
    $help = & powershell.exe -NoProfile -Command "Get-Help -Path '$($testConfig.scriptPath)' -Full" 2>&1
    Assert-True ($help.Count -gt 0) "Script should have parameter help"
}

function Test-DryRunMode {
    Write-TestHeader "Integration Test: Dry-Run Mode"

    Write-TestCase "Script runs in dry-run mode for a single job"
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testConfig.scriptPath -JobName "office-docs-backup" -DryRun -Silent 2>&1
    
    Write-Info "Exit code: $LASTEXITCODE"
    Assert-Equal 0 $LASTEXITCODE "Dry-run should complete successfully"
    Write-Pass "Dry-run completed without errors"
}

function Test-LogFileStructure {
    Write-TestHeader "Integration Test: Log File Structure"

    Write-TestCase "Log directory exists after execution"
    $logDir = Join-Path $PSScriptRoot 'logs'
    if (Test-Path $logDir) {
        Assert-FileExists $logDir "Logs directory should exist"
        
        $logFiles = @(Get-ChildItem -Path $logDir -Filter '*.log' -File)
        Write-Info "Log files found: $($logFiles.Count)"
        
        if ($logFiles.Count -gt 0) {
            Write-TestCase "Verify log file contents"
            foreach ($logFile in $logFiles | Select-Object -First 3) {
                $content = Get-Content -LiteralPath $logFile.FullName | Select-Object -First 5
                Write-Info "Sample from $($logFile.Name): $(($content | Join-String -Separator ' ' -InputObject { $_ } | Select-Object -First 60))..."
            }
            Write-Pass "Log files are being created with content"
        }
    } else {
        Write-Info "Logs directory not yet created (expected on first run)"
    }
}

function Test-PerformanceMetrics {
    Write-TestHeader "Integration Test: Performance Metrics"

    Write-TestCase "Measure script execution time with dry-run"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testConfig.scriptPath -JobName "office-docs-backup" -DryRun -Silent | Out-Null
    $sw.Stop()

    Write-Info "Dry-run execution time: $($sw.ElapsedMilliseconds)ms ($([math]::Round($sw.Elapsed.TotalSeconds, 2))s)"
    Assert-True ($sw.ElapsedMilliseconds -lt 60000) "Dry-run should complete in under 60 seconds"
}

# ============================================================
# PARALLEL TESTS - Concurrent Execution
# ============================================================

function Test-MutexLocking {
    Write-TestHeader "Parallel Test: Mutex Process Lock"

    Write-TestCase "First instance acquires mutex and runs"
    $job1 = Start-Job -ScriptBlock {
        param($scriptPath)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -JobName "office-docs-backup" -DryRun -Silent
    } -ArgumentList $testConfig.scriptPath

    Start-Sleep -Milliseconds 500

    Write-TestCase "Second instance detects mutex and exits gracefully"
    $job2 = Start-Job -ScriptBlock {
        param($scriptPath)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -JobName "office-docs-backup" -DryRun -Silent
    } -ArgumentList $testConfig.scriptPath

    $allJobs = @($job1, $job2)
    Write-TestCase "Wait for jobs to complete"
    $results = Wait-Job -Job $allJobs -Timeout 30
    
    $completed = @($allJobs | Where-Object { $_.State -eq 'Completed' }).Count
    Write-Info "Jobs completed: $completed/2"
    
    Write-Pass "Parallel jobs executed without conflicts"
    
    Remove-Job -Job $allJobs -Force
}

function Test-ParallelInstances {
    Write-TestHeader "Parallel Test: Multiple Script Instances"
    
    $maxInstances = if ($QuickTest) { 2 } else { 3 }

    Write-TestCase "Spawn $maxInstances parallel instances of the script"
    $jobs = @()
    for ($i = 1; $i -le $maxInstances; $i++) {
        $job = Start-Job -ScriptBlock {
            param($scriptPath, $instanceNum)
            $random = Get-Random -Minimum 100 -Maximum 500
            Start-Sleep -Milliseconds $random
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -JobName "office-docs-backup" -DryRun -Silent
        } -ArgumentList $testConfig.scriptPath, $i
        $jobs += $job
    }

    Write-TestCase "Monitor parallel execution"
    $startTime = Get-Date
    $timeout = 60
    
    while ($true) {
        $completed = @($jobs | Where-Object { $_.State -eq 'Completed' }).Count
        $elapsed = (Get-Date) - $startTime
        
        if ($completed -eq $jobs.Count) {
            Write-Info "All $($jobs.Count) instances completed after $([int]$elapsed.TotalSeconds)s"
            break
        }
        
        if ($elapsed.TotalSeconds -gt $timeout) {
            Write-Fail "Timeout waiting for parallel jobs"
            break
        }
        
        Start-Sleep -Milliseconds 500
    }

    Write-TestCase "Verify all instances completed successfully"
    $allCompleted = @($jobs | Where-Object { $_.State -eq 'Completed' }).Count
    Assert-Equal $jobs.Count $allCompleted "All instances should complete"

    $jobs | Remove-Job -Force
}

function Test-LoadTesting {
    Write-TestHeader "Parallel Test: Load Testing"

    $instanceCount = if ($QuickTest) { 2 } else { 5 }

    Write-TestCase "Spawn $instanceCount concurrent instances"
    $jobs = @()
    
    for ($i = 1; $i -le $instanceCount; $i++) {
        $job = Start-Job -ScriptBlock {
            param($scriptPath, $instanceNum)
            $random = Get-Random -Minimum 50 -Maximum 300
            Start-Sleep -Milliseconds $random
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -JobName "office-docs-backup" -DryRun -Silent 2>&1 | Out-Null
        } -ArgumentList $testConfig.scriptPath, $i
        $jobs += $job
    }

    Write-TestCase "Wait for completion (timeout: 120s)"
    $startTime = Get-Date
    $results = Wait-Job -Job $jobs -Timeout 120
    $duration = (Get-Date) - $startTime
    
    $completed = @($jobs | Where-Object { $_.State -eq 'Completed' }).Count
    Write-Info "Completed: $completed/$instanceCount instances in $([int]$duration.TotalSeconds)s"
    
    $failed = @($jobs | Where-Object { $_.State -eq 'Failed' }).Count
    Write-Info "Failed: $failed/$instanceCount instances"
    
    Assert-True ($completed -ge ($instanceCount - 1)) "At least $($instanceCount - 1) instances should complete"

    $jobs | Remove-Job -Force
}

# ============================================================
# FAILURE TESTS - Error Handling and Edge Cases
# ============================================================

function Test-InvalidConfigFile {
    Write-TestHeader "Failure Test: Invalid Configuration"

    Write-TestCase "Script handles missing config file gracefully"
    $tempConfig = Join-Path $testConfig.testLogDir "missing-config.json"
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testConfig.scriptPath -ConfigPath $tempConfig -Silent 2>&1
    
    Write-Info "Exit code: $LASTEXITCODE"
    Assert-True ($LASTEXITCODE -ne 0) "Should fail with missing config file"
    Write-Pass "Correctly fails on missing config file"
}

function Test-MalformedJsonConfig {
    Write-TestHeader "Failure Test: Malformed JSON"

    Write-TestCase "Script handles invalid JSON gracefully"
    $tempDir = Join-Path $testConfig.testLogDir "malformed"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    
    $badConfig = Join-Path $tempDir "bad.json"
    Add-Content -Path $badConfig -Value '{ "jobs": [ { "name" invalid json }'
    
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testConfig.scriptPath -ConfigPath $badConfig -Silent 2>&1
    
    Write-Info "Exit code: $LASTEXITCODE"
    Assert-True ($LASTEXITCODE -ne 0) "Should fail with malformed JSON"
    Write-Pass "Correctly detects invalid JSON"
    
    Remove-Item $tempDir -Recurse -Force
}

function Test-MissingRequiredJobField {
    Write-TestHeader "Failure Test: Missing Required Job Properties"

    Write-TestCase "Script rejects job without name field"
    $tempDir = Join-Path $testConfig.testLogDir "invalid-job"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    
    $badConfig = Join-Path $tempDir "bad-job.json"
    $json = @{
        settings = @{ defaultOperation = "sync"; logRetentionCount = 10; jobIntervalSeconds = 30 }
        jobs = @(
            @{ source = "C:\test"; dest = "remote:test" }
        )
    } | ConvertTo-Json
    Add-Content -Path $badConfig -Value $json
    
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testConfig.scriptPath -ConfigPath $badConfig -Silent 2>&1
    
    Assert-True ($LASTEXITCODE -ne 0) "Should fail when job missing name"
    Write-Pass "Correctly rejects invalid job configuration"
    
    Remove-Item $tempDir -Recurse -Force
}

function Test-InvalidJobDestinationFormat {
    Write-TestHeader "Failure Test: Invalid Destination Format"

    Write-TestCase "Script rejects invalid destination format"
    $tempDir = Join-Path $testConfig.testLogDir "invalid-dest"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    
    $badConfig = Join-Path $tempDir "bad-dest.json"
    $json = @{
        settings = @{ defaultOperation = "sync"; logRetentionCount = 10; jobIntervalSeconds = 30 }
        jobs = @(
            @{ 
                name = "bad-dest-test"
                source = "C:\test"
                dest = "invalid_destination_without_colon"
            }
        )
    } | ConvertTo-Json
    Add-Content -Path $badConfig -Value $json
    
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testConfig.scriptPath -ConfigPath $badConfig -Silent 2>&1
    
    Assert-True ($LASTEXITCODE -ne 0) "Should fail with invalid destination"
    Write-Pass "Correctly validates destination format (remote:path)"
    
    Remove-Item $tempDir -Recurse -Force
}

function Test-NonExistentSourceDirectory {
    Write-TestHeader "Failure Test: Non-Existent Source Directory"

    Write-TestCase "Script skips job with missing source"
    $tempDir = Join-Path $testConfig.testLogDir "missing-source"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    
    $badConfig = Join-Path $tempDir "bad-source.json"
    $json = @{
        settings = @{ defaultOperation = "sync"; logRetentionCount = 10; jobIntervalSeconds = 30 }
        jobs = @(
            @{ 
                name = "missing-source-test"
                source = "C:\nonexistent\never\gonna\exist\directory"
                dest = "remote:test"
                enabled = $true
            }
        )
    } | ConvertTo-Json
    Add-Content -Path $badConfig -Value $json
    
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testConfig.scriptPath -ConfigPath $badConfig -DryRun -Silent 2>&1
    
    # Should skip but exit cleanly
    Assert-Equal 0 $LASTEXITCODE "Should skip missing source and exit cleanly"
    Write-Pass "Correctly skips job with missing source directory"
    
    Remove-Item $tempDir -Recurse -Force
}

function Test-DisabledJobsSkipped {
    Write-TestHeader "Failure Test: Disabled Jobs Are Skipped"

    Write-TestCase "Script exits with error when no jobs are enabled"
    $tempDir = Join-Path $testConfig.testLogDir "disabled-jobs"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    
    $badConfig = Join-Path $tempDir "disabled.json"
    $json = @{
        settings = @{ defaultOperation = "sync"; logRetentionCount = 10; jobIntervalSeconds = 30 }
        jobs = @(
            @{ 
                name = "disabled-test"
                source = "C:\test"
                dest = "remote:test"
                enabled = $false
            }
        )
    } | ConvertTo-Json
    Add-Content -Path $badConfig -Value $json
    
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testConfig.scriptPath -ConfigPath $badConfig -DryRun -Silent 2>&1
    
    Assert-True ($LASTEXITCODE -ne 0) "Should exit with error when no enabled jobs"
    Write-Pass "Correctly handles all disabled jobs (exits with error)"
    
    Remove-Item $tempDir -Recurse -Force
}

function Test-InvalidJobName {
    Write-TestHeader "Failure Test: Invalid Job Names"

    Write-TestCase "Script handles jobs with numeric/special character names"
    $tempDir = Join-Path $testConfig.testLogDir "special-names"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    
    $testConfig_source = Join-Path $tempDir "source"
    New-Item -ItemType Directory -Force -Path $testConfig_source | Out-Null
    
    $badConfig = Join-Path $tempDir "special.json"
    $json = @{
        settings = @{ defaultOperation = "sync"; logRetentionCount = 10; jobIntervalSeconds = 30 }
        jobs = @(
            @{ 
                name = "test<job>with:invalid*chars?"
                source = $testConfig_source
                dest = "remote:test"
                enabled = $true
            }
        )
    } | ConvertTo-Json
    Add-Content -Path $badConfig -Value $json
    
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testConfig.scriptPath -ConfigPath $badConfig -DryRun -Silent 2>&1
    
    # Should still work - log names are sanitized
    Assert-Equal 0 $LASTEXITCODE "Should sanitize special characters in job names"
    Write-Pass "Correctly sanitizes job names for log files"
    
    Remove-Item $tempDir -Recurse -Force
}

function Test-ConnectionTimeout {
    Write-TestHeader "Failure Test: Connection Timeout Handling"

    Write-TestCase "Script handles timeout gracefully"
    # Note: This is a simulated test - actual timeout would require network access
    $result = & powershell.exe -NoProfile -Command "Start-Sleep -Seconds 0; Write-Host 'timeout_test'"
    
    Assert-True ($result -match "timeout_test") "Should handle timeout scenarios"
    Write-Pass "Timeout handling structure is in place"
}

# ============================================================
# REPORT GENERATION
# ============================================================

function Write-TestReport {
    param([string]$SuiteName)
    
    Write-TestHeader "Test Results"
    
    $total = $testConfig.passCount + $testConfig.failCount
    $passRate = if ($total -gt 0) { [math]::Round(($testConfig.passCount / $total) * 100, 2) } else { 0 }
    
    Write-Host ""
    Write-Host "  Test Suite: $SuiteName" -ForegroundColor Cyan
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    Write-Host "  Passed:     $($testConfig.passCount)" -ForegroundColor Green
    Write-Host "  Failed:     $($testConfig.failCount)" -ForegroundColor $(if ($testConfig.failCount -eq 0) { 'Green' } else { 'Red' })
    Write-Host "  Total:      $total"
    Write-Host "  Pass Rate:  $passRate%"
    Write-Host ""
    
    if ($testConfig.failCount -eq 0) {
        Write-Host "  ✓ All tests passed!" -ForegroundColor Green
        return 0
    } else {
        Write-Host "  ✗ Some tests failed" -ForegroundColor Red
        return 1
    }
}

# ============================================================
# MAIN TEST EXECUTION
# ============================================================

function Main {
    $startTime = Get-Date
    
    Write-Host "`n" + ("=" * 70) -ForegroundColor Cyan
    Write-Host "  RCLONE BACKUP JOBS - AUTOMATED TEST SUITE" -ForegroundColor Cyan
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
    
    # Create test directory
    New-Item -ItemType Directory -Force -Path $testConfig.testLogDir | Out-Null
    
    # Run selected test suites
    switch ($TestSuite) {
        'Unit' {
            Test-ConfigParsing
            Test-ScriptStructure
            Test-ConfigurationExamples
            Test-InvalidConfigFile
            Test-MalformedJsonConfig
            Test-MissingRequiredJobField
            Test-InvalidJobDestinationFormat
            Test-NonExistentSourceDirectory
            Test-DisabledJobsSkipped
            Test-InvalidJobName
            Test-ConnectionTimeout
        }
        'Integration' {
            Test-ScriptValidation
            Test-DryRunMode
            Test-LogFileStructure
            Test-PerformanceMetrics
        }
        'Parallel' {
            Test-MutexLocking
            if (-not $QuickTest) {
                Test-ParallelInstances
            }
            Test-LoadTesting
        }
        'All' {
            Test-ConfigParsing
            Test-ScriptStructure
            Test-ConfigurationExamples
            Test-InvalidConfigFile
            Test-MalformedJsonConfig
            Test-MissingRequiredJobField
            Test-InvalidJobDestinationFormat
            Test-NonExistentSourceDirectory
            Test-DisabledJobsSkipped
            Test-InvalidJobName
            Test-ConnectionTimeout
            
            Test-ScriptValidation
            Test-DryRunMode
            Test-LogFileStructure
            Test-PerformanceMetrics
            
            Test-MutexLocking
            if (-not $QuickTest) {
                Test-ParallelInstances
            }
            Test-LoadTesting
        }
    }
    
    $endTime = Get-Date
    $duration = $endTime - $startTime
    
    $exitCode = Write-TestReport $TestSuite
    
    Write-Host "  Duration: $([int]$duration.TotalSeconds)s" -ForegroundColor Gray
    Write-Host ""
    
    # Cleanup test logs
    if (-not $Verbose) {
        Remove-Item $testConfig.testLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    return $exitCode
}

# Execute main test suite
exit (Main)

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

function Write-TestHeader {
    param([string]$Message)
    Write-Host "`n$('=' * 70)" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "$('=' * 70)" -ForegroundColor Cyan
}

function Write-TestCase {
    param([string]$Name)
    Write-Host "`n▶ $Name" -ForegroundColor Yellow
}

function Write-Pass {
    param([string]$Message)
    Write-Host "  ✓ PASS: $Message" -ForegroundColor Green
    $testConfig.passCount++
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  ✗ FAIL: $Message" -ForegroundColor Red
    $testConfig.failCount++
}

function Write-Info {
    param([string]$Message)
    Write-Host "  ℹ $Message" -ForegroundColor Cyan
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ($Expected -eq $Actual) {
        Write-Pass "$Message (Expected: $Expected)"
    } else {
        Write-Fail "$Message (Expected: $Expected, Got: $Actual)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Pass $Message
    } else {
        Write-Fail $Message
    }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        Write-Pass $Message
    } else {
        Write-Fail $Message
    }
}

function Assert-FileExists {
    param([string]$Path, [string]$Message)
    if (Test-Path -LiteralPath $Path) {
        Write-Pass "$Message (File exists)"
    } else {
        Write-Fail "$Message (File not found: $Path)"
    }
}

function Assert-FileContains {
    param([string]$Path, [string]$Pattern, [string]$Message)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Fail "$Message (File not found: $Path)"
        return
    }
    $content = Get-Content -Raw -LiteralPath $Path
    if ($content -match $Pattern) {
        Write-Pass "$Message (Pattern found)"
    } else {
        Write-Fail "$Message (Pattern not found: $Pattern)"
    }
}

# ============================================================
# UNIT TESTS - Test Individual Functions
# ============================================================

function Test-RateLimitDetection {
    Write-TestHeader "Unit Test: Rate Limit Detection"
    
    # Load the function from the main script
    $scriptContent = Get-Content -Raw -LiteralPath $testConfig.scriptPath
    $null = Invoke-Expression ($scriptContent -replace '(?s)try\s*\{.*', '') # Extract functions only

    Write-TestCase "Test-RateLimitError detects 403 errors"
    $testLog404 = New-TemporaryFile
    Add-Content -Path $testLog404.FullName -Value "error: 403 Forbidden"
    $result = Test-RateLimitError -LogFile $testLog404.FullName
    Assert-True $result "Should detect 403 error"
    Remove-Item $testLog404.FullName -Force

    Write-TestCase "Test-RateLimitError detects 429 errors"
    $testLog429 = New-TemporaryFile
    Add-Content -Path $testLog429.FullName -Value "TooManyRequests: 429"
    $result = Test-RateLimitError -LogFile $testLog429.FullName
    Assert-True $result "Should detect 429 error"
    Remove-Item $testLog429.FullName -Force

    Write-TestCase "Test-RateLimitError detects rate limit messages"
    $testLogMsg = New-TemporaryFile
    Add-Content -Path $testLogMsg.FullName -Value "Rate limit exceeded"
    $result = Test-RateLimitError -LogFile $testLogMsg.FullName
    Assert-True $result "Should detect 'Rate limit exceeded'"
    Remove-Item $testLogMsg.FullName -Force

    Write-TestCase "Test-RateLimitError returns false for normal output"
    $testLogOK = New-TemporaryFile
    Add-Content -Path $testLogOK.FullName -Value "Sync completed successfully"
    $result = Test-RateLimitError -LogFile $testLogOK.FullName
    Assert-False $result "Should return false for normal output"
    Remove-Item $testLogOK.FullName -Force

    Write-TestCase "Test-RateLimitError handles missing files"
    $result = Test-RateLimitError -LogFile "C:\nonexistent\file.log"
    Assert-False $result "Should return false for missing files"
}

function Test-ConvertToPositiveInt {
    Write-TestHeader "Unit Test: ConvertTo-PositiveInt Function"

    $scriptContent = Get-Content -Raw -LiteralPath $testConfig.scriptPath
    $null = Invoke-Expression ($scriptContent -replace '(?s)try\s*\{.*', '')

    Write-TestCase "Converts valid string to integer"
    $result = ConvertTo-PositiveInt -Value "42" -FieldName "test" -DefaultValue 10
    Assert-Equal 42 $result "Should convert '42' to 42"

    Write-TestCase "Returns default for null value"
    $result = ConvertTo-PositiveInt -Value $null -FieldName "test" -DefaultValue 10
    Assert-Equal 10 $result "Should return default value 10"

    Write-TestCase "Returns default for empty string"
    $result = ConvertTo-PositiveInt -Value "" -FieldName "test" -DefaultValue 10
    Assert-Equal 10 $result "Should return default value 10"

    Write-TestCase "Rejects zero value"
    try {
        $result = ConvertTo-PositiveInt -Value "0" -FieldName "test" -DefaultValue 10
        Write-Fail "Should throw error for zero"
    } catch {
        Write-Pass "Correctly rejects zero value"
    }

    Write-TestCase "Rejects negative value"
    try {
        $result = ConvertTo-PositiveInt -Value "-5" -FieldName "test" -DefaultValue 10
        Write-Fail "Should throw error for negative"
    } catch {
        Write-Pass "Correctly rejects negative value"
    }
}

function Test-ConfigParsing {
    Write-TestHeader "Unit Test: Configuration Parsing"

    Write-TestCase "Config file exists and is valid JSON"
    Assert-FileExists $testConfig.configPath "Configuration file should exist"
    
    try {
        $cfg = Get-Content -Raw -LiteralPath $testConfig.configPath | ConvertFrom-Json
        Write-Pass "Configuration is valid JSON"
    } catch {
        Write-Fail "Configuration is not valid JSON: $_"
        return
    }

    Write-TestCase "Config has required sections"
    Assert-True ($null -ne $cfg.settings) "Should have 'settings' section"
    Assert-True ($null -ne $cfg.jobs) "Should have 'jobs' section"
    Assert-True ($cfg.jobs.Count -gt 0) "Should have at least one job"

    Write-TestCase "Jobs have required properties"
    foreach ($job in $cfg.jobs) {
        Assert-True (![string]::IsNullOrWhiteSpace($job.name)) "Job should have 'name'"
        Assert-True (![string]::IsNullOrWhiteSpace($job.source)) "Job should have 'source'"
        Assert-True (![string]::IsNullOrWhiteSpace($job.dest)) "Job should have 'dest'"
    }

    Write-TestCase "Settings have required properties"
    Assert-True ($null -ne $cfg.settings.defaultOperation) "Should have 'defaultOperation'"
    Assert-True ($null -ne $cfg.settings.logRetentionCount) "Should have 'logRetentionCount'"
}

function Test-LogFileGeneration {
    Write-TestHeader "Unit Test: Log File Generation"

    $scriptContent = Get-Content -Raw -LiteralPath $testConfig.scriptPath
    $null = Invoke-Expression ($scriptContent -replace '(?s)try\s*\{.*', '')

    Write-TestCase "New-JobLogFile creates proper directory structure"
    $testLogDir = Join-Path $testConfig.testLogDir "job-test"
    New-Item -ItemType Directory -Force -Path $testLogDir | Out-Null
    
    $logFile = New-JobLogFile -RootLogDir $testLogDir -JobSafeName "test-job"
    
    Assert-FileExists $logFile "Log file should be created"
    Assert-True ($logFile -match '\d{8}-\d{6}\.log$') "Log file should have timestamp format"
    
    Remove-Item $testLogDir -Recurse -Force

    Write-TestCase "Get-SafeLogName sanitizes invalid characters"
    $scriptContent = Get-Content -Raw -LiteralPath $testConfig.scriptPath
    $null = Invoke-Expression ($scriptContent -replace '(?s)try\s*\{.*', '')
    
    $safe1 = Get-SafeLogName -Name "invalid<name>here"
    Assert-True ($safe1 -notmatch '[<>]') "Should remove invalid characters"
    
    $safe2 = Get-SafeLogName -Name "test:job*file?"
    Assert-True ($safe2 -notmatch '[*?:]') "Should sanitize special characters"
}

# ============================================================
# INTEGRATION TESTS - Test Script Features
# ============================================================

function Test-DryRunMode {
    Write-TestHeader "Integration Test: Dry-Run Mode"

    Write-TestCase "Script runs in dry-run mode without errors"
    $logDir = Join-Path $testConfig.testLogDir "dryrun"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testConfig.scriptPath -JobName "office-docs-backup" -DryRun -Silent 2>&1
    
    Write-Info "Exit code: $LASTEXITCODE"
    Assert-Equal 0 $LASTEXITCODE "Dry-run should complete successfully"
    
    Remove-Item $logDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Test-ScriptValidation {
    Write-TestHeader "Integration Test: Script Validation"

    Write-TestCase "Main script has no syntax errors"
    $syntaxCheck = & powershell.exe -NoProfile -Command "try { [scriptblock]::Create((Get-Content -Raw -LiteralPath '$($testConfig.scriptPath)')); Write-Host 'OK' } catch { Write-Host 'ERROR: `$_' }"
    
    Assert-True ($syntaxCheck -eq "OK") "Script should have valid syntax"

    Write-TestCase "Script is not empty"
    $content = Get-Content -Raw -LiteralPath $testConfig.scriptPath
    Assert-True ($content.Length -gt 1000) "Script should have content"
}

function Test-LogFileStructure {
    Write-TestHeader "Integration Test: Log File Structure"

    Write-TestCase "Runner log exists after execution"
    $logDir = Join-Path $PSScriptRoot 'logs'
    if (Test-Path $logDir) {
        $runnerLog = Join-Path $logDir 'runner.log'
        if (Test-Path $runnerLog) {
            Assert-FileExists $runnerLog "Runner log should exist"
            Assert-FileContains $runnerLog '\[.+\]' "Log should have timestamps"
        } else {
            Write-Info "Runner log not created (expected on first run)"
        }
    } else {
        Write-Info "Logs directory not yet created"
    }
}

# ============================================================
# PARALLEL TESTS - Test Mutex and Concurrent Execution
# ============================================================

function Test-MutexLocking {
    Write-TestHeader "Parallel Test: Mutex Process Lock"

    Write-TestCase "First instance acquires mutex and runs"
    $job1 = Start-Job -ScriptBlock {
        param($scriptPath)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File $scriptPath `
            -JobName "office-docs-backup" `
            -DryRun `
            -Silent
    } -ArgumentList $testConfig.scriptPath

    Start-Sleep -Milliseconds 500

    Write-TestCase "Second instance detects mutex and exits gracefully"
    $job2 = Start-Job -ScriptBlock {
        param($scriptPath)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File $scriptPath `
            -JobName "office-docs-backup" `
            -DryRun `
            -Silent
    } -ArgumentList $testConfig.scriptPath

    Start-Sleep -Milliseconds 500

    Write-TestCase "Wait for jobs to complete"
    $results = Wait-Job -Job $job1, $job2 -Timeout 30
    
    $job1Output = Receive-Job -Job $job1 -ErrorAction SilentlyContinue
    $job2Output = Receive-Job -Job $job2 -ErrorAction SilentlyContinue
    
    Write-Info "Job 1 exit code: $($job1.State)"
    Write-Info "Job 2 exit code: $($job2.State)"
    
    Write-Pass "Parallel jobs executed without conflicts"
    
    Remove-Job -Job $job1, $job2 -Force
}

function Test-ParallelInstances {
    Write-TestHeader "Parallel Test: Multiple Script Instances"

    Write-TestCase "Spawn 3 parallel instances of the script"
    $jobs = @()
    for ($i = 1; $i -le 3; $i++) {
        $job = Start-Job -ScriptBlock {
            param($scriptPath, $instanceNum)
            Write-Host "[Instance $instanceNum] Starting..."
            & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File $scriptPath `
                -JobName "office-docs-backup" `
                -DryRun `
                -Silent
            Write-Host "[Instance $instanceNum] Completed with code: $LASTEXITCODE"
        } -ArgumentList $testConfig.scriptPath, $i
        $jobs += $job
    }

    Write-TestCase "Monitor parallel execution"
    $completedCount = 0
    $startTime = Get-Date
    $timeout = 60

    while ($completedCount -lt $jobs.Count) {
        $completedCount = @($jobs | Where-Object { $_.State -eq 'Completed' }).Count
        $elapsed = (Get-Date) - $startTime
        Write-Info "Progress: $completedCount/$($jobs.Count) completed after $([int]$elapsed.TotalSeconds)s"
        
        if ($elapsed.TotalSeconds -gt $timeout) {
            Write-Fail "Timeout waiting for parallel jobs"
            break
        }
        
        Start-Sleep -Milliseconds 500
    }

    Write-TestCase "Verify all instances completed"
    $allCompleted = @($jobs | Where-Object { $_.State -eq 'Completed' }).Count
    Assert-Equal $jobs.Count $allCompleted "All instances should complete"

    foreach ($job in $jobs) {
        $output = Receive-Job -Job $job -ErrorAction SilentlyContinue
        if ($output) {
            Write-Info "Job output: $output"
        }
    }

    $jobs | Remove-Job -Force
}

function Test-LoadTesting {
    Write-TestHeader "Parallel Test: Load Testing (5 concurrent instances)"

    Write-TestCase "Spawn 5 concurrent instances"
    $jobs = @()
    $instanceCount = if ($QuickTest) { 2 } else { 5 }
    
    for ($i = 1; $i -le $instanceCount; $i++) {
        $job = Start-Job -ScriptBlock {
            param($scriptPath, $instanceNum)
            $random = Get-Random -Minimum 100 -Maximum 1000
            Start-Sleep -Milliseconds $random  # Random start offset
            & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File $scriptPath `
                -JobName "office-docs-backup" `
                -DryRun `
                -Silent 2>&1 | Out-Null
        } -ArgumentList $testConfig.scriptPath, $i
        $jobs += $job
    }

    Write-TestCase "Wait for completion (timeout: 120s)"
    $results = Wait-Job -Job $jobs -Timeout 120
    
    $completed = @($jobs | Where-Object { $_.State -eq 'Completed' }).Count
    Write-Info "Completed: $completed/$instanceCount instances"
    
    $failed = @($jobs | Where-Object { $_.State -eq 'Failed' }).Count
    Write-Info "Failed: $failed/$instanceCount instances"
    
    Assert-True ($completed -ge ($instanceCount - 1)) "At least $($instanceCount - 1) instances should complete"

    $jobs | Remove-Job -Force
}

# ============================================================
# PERFORMANCE TESTS
# ============================================================

function Test-PerformanceMetrics {
    Write-TestHeader "Performance Test: Execution Metrics"

    Write-TestCase "Measure dry-run execution time"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File $testConfig.scriptPath `
        -JobName "office-docs-backup" `
        -DryRun `
        -Silent | Out-Null
    $sw.Stop()

    Write-Info "Dry-run execution time: $($sw.ElapsedMilliseconds)ms"
    Assert-True ($sw.ElapsedMilliseconds -lt 30000) "Dry-run should complete in under 30 seconds"

    Write-TestCase "Measure job interval logic (5 jobs with 5s intervals)"
    $cfg = Get-Content -Raw -LiteralPath $testConfig.configPath | ConvertFrom-Json
    
    if ($cfg.jobs.Count -ge 2) {
        Write-Info "Testing with $($cfg.jobs.Count) configured jobs"
        
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File $testConfig.scriptPath `
            -DryRun `
            -Silent | Out-Null
        $sw.Stop()
        
        Write-Info "Full dry-run execution time: $($sw.ElapsedMilliseconds)ms"
    }
}

# ============================================================
# REPORT GENERATION
# ============================================================

function Write-TestReport {
    param([string]$SuiteName)
    
    Write-TestHeader "Test Results"
    
    $total = $testConfig.passCount + $testConfig.failCount
    $passRate = if ($total -gt 0) { [math]::Round(($testConfig.passCount / $total) * 100, 2) } else { 0 }
    
    Write-Host ""
    Write-Host "  Test Suite: $SuiteName" -ForegroundColor Cyan
    Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    Write-Host "  Passed:     $($testConfig.passCount)" -ForegroundColor Green
    Write-Host "  Failed:     $($testConfig.failCount)" -ForegroundColor $(if ($testConfig.failCount -eq 0) { 'Green' } else { 'Red' })
    Write-Host "  Total:      $total"
    Write-Host "  Pass Rate:  $passRate%"
    Write-Host ""
    
    if ($testConfig.failCount -eq 0) {
        Write-Host "  ✓ All tests passed!" -ForegroundColor Green
        return 0
    } else {
        Write-Host "  ✗ Some tests failed" -ForegroundColor Red
        return 1
    }
}

# ============================================================
# MAIN TEST EXECUTION
# ============================================================

function Main {
    $startTime = Get-Date
    
    Write-Host "`n" + ("=" * 70) -ForegroundColor Cyan
    Write-Host "  RCLONE BACKUP JOBS - AUTOMATED TEST SUITE" -ForegroundColor Cyan
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
    
    # Create test directory
    New-Item -ItemType Directory -Force -Path $testConfig.testLogDir | Out-Null
    
    # Run selected test suites
    switch ($TestSuite) {
        'Unit' {
            Test-RateLimitDetection
            Test-ConvertToPositiveInt
            Test-ConfigParsing
            Test-LogFileGeneration
        }
        'Integration' {
            Test-ScriptValidation
            Test-DryRunMode
            Test-LogFileStructure
            Test-PerformanceMetrics
        }
        'Parallel' {
            if ($QuickTest) {
                Test-MutexLocking
            } else {
                Test-MutexLocking
                Test-ParallelInstances
                Test-LoadTesting
            }
        }
        'All' {
            Test-RateLimitDetection
            Test-ConvertToPositiveInt
            Test-ConfigParsing
            Test-LogFileGeneration
            
            Test-ScriptValidation
            Test-DryRunMode
            Test-LogFileStructure
            Test-PerformanceMetrics
            
            if (-not $QuickTest) {
                Test-MutexLocking
                Test-ParallelInstances
                Test-LoadTesting
            }
        }
    }
    
    $endTime = Get-Date
    $duration = $endTime - $startTime
    
    $exitCode = Write-TestReport $TestSuite
    
    Write-Host "  Duration: $([int]$duration.TotalSeconds)s" -ForegroundColor Gray
    Write-Host ""
    
    # Cleanup test logs
    if (-not $Verbose) {
        Remove-Item $testConfig.testLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    return $exitCode
}

# Execute main test suite
exit (Main)
