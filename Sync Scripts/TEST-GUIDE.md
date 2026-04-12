# Automated Test Suite for Run-RcloneJobs

Complete testing framework for the rclone backup jobs script with unit tests, integration tests, parallel execution tests, and load testing.

## Quick Start

```powershell
# Run all tests
.\Test-RcloneJobs.ps1

# Run specific test suite
.\Test-RcloneJobs.ps1 -TestSuite Unit
.\Test-RcloneJobs.ps1 -TestSuite Integration
.\Test-RcloneJobs.ps1 -TestSuite Parallel

# Quick test (fewer parallel instances)
.\Test-RcloneJobs.ps1 -QuickTest

# Keep test logs for inspection
.\Test-RcloneJobs.ps1 -Verbose
```

## Test Suites

### Unit Tests

Isolated tests of individual functions and components.

**Tests included:**
- `Test-ConfigParsing`: Validates JSON configuration loading and structure
- `Test-ScriptStructure`: Verifies required functions and mechanisms
- `Test-ConfigurationExamples`: Checks configuration examples
- `Test-InvalidConfigFile`: Tests error handling for missing config
- `Test-MalformedJsonConfig`: Tests invalid JSON detection
- `Test-MissingRequiredJobField`: Tests validation of required fields
- `Test-InvalidJobDestinationFormat`: Tests destination validation
- `Test-NonExistentSourceDirectory`: Tests missing source handling
- `Test-DisabledJobsSkipped`: Tests disabled job handling
- `Test-InvalidJobName`: Tests special character sanitization
- `Test-ConnectionTimeout`: Tests timeout handling

**Run:**

```powershell
.\Test-RcloneJobs.ps1 -TestSuite Unit
```

### Integration Tests

Tests script features as a whole with the main script invocation.

**Tests included:**
- `Test-ScriptValidation`: Checks PowerShell syntax validity
- `Test-DryRunMode`: Executes script in dry-run mode to ensure no errors
- `Test-LogFileStructure`: Validates log file structure after execution
- `Test-PerformanceMetrics`: Measures execution time and performance

**Run:**

```powershell
.\Test-RcloneJobs.ps1 -TestSuite Integration
```

### Parallel Tests

Tests concurrent execution, mutex locking, and race conditions.

**Tests included:**
- `Test-MutexLocking`: Verifies first instance gets mutex, others exit gracefully
- `Test-ParallelInstances`: Spawns 3 concurrent instances and monitors execution
- `Test-LoadTesting`: 5 concurrent instances with random start delays (2 in quick mode)

**Run:**

```powershell
.\Test-RcloneJobs.ps1 -TestSuite Parallel

# Quick version with 2 instances
.\Test-RcloneJobs.ps1 -TestSuite Parallel -QuickTest
```

### All Tests (Default)

Runs all three suites in sequence.

```powershell
.\Test-RcloneJobs.ps1                        # Full suite
.\Test-RcloneJobs.ps1 -QuickTest            # Reduced parallel tests
```

## Command Line Options

| Option | Type | Description |
|--------|------|-------------|
| `-TestSuite` | All, Unit, Integration, Parallel | Which test suite to run (default: All) |
| `-QuickTest` | Switch | Run reduced parallel tests (2 instead of 5 instances) |
| `-Verbose` | Switch | Keep test logs directory for inspection (default: cleanup) |

## Test Output

### Pass/Fail Indicators

```
✓ PASS: Description of what passed
✗ FAIL: Description of what failed
ℹ INFO: Additional context information
```

### Example Output

```
======================================================================
  Unit Test: Rate Limit Detection
======================================================================

▶ Test-RateLimitError detects 403 errors
  ✓ PASS: Should detect 403 error

▶ Test-RateLimitError detects 429 errors
  ✓ PASS: Should detect 429 error

▶ Test-RateLimitError returns false for normal output
  ✓ PASS: Should return false for normal output

======================================================================
  Test Results
======================================================================

  Test Suite: Unit
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Passed:     12
  Failed:     0
  Total:      12
  Pass Rate:  100%

  ✓ All tests passed!
```

## Test Scenarios Covered

### Rate Limit Detection

- Detects HTTP 403 errors
- Detects HTTP 429 errors
- Detects "TooManyRequests" message
- Detects "Rate limit exceeded" message
- Detects "Throttled" message
- Returns false for normal output
- Handles missing files gracefully

### Configuration & Validation

- Config file exists and loads
- Valid JSON format
- Has required sections (settings, jobs, profiles)
- Jobs have required properties (name, source, dest)
- Settings have required properties
- Log file structure is valid

### Error Handling

- Rejects missing config file
- Detects malformed JSON
- Validates required job fields
- Checks destination format (remote:path)
- Skips jobs with missing source directories
- Handles disabled jobs correctly
- Sanitizes special characters in job names
- Handles timeouts gracefully

### Process Locking (Mutex)

- First instance acquires exclusive lock
- Second instance exits gracefully with message
- No deadlocks or race conditions
- Mutex released on script exit

### Concurrency

- 3 parallel instances run without conflicts
- 5 parallel instances with load testing
- Random start delays prevent timing issues
- All instances complete successfully

### Performance

- Dry-run completes in under 30 seconds
- Execution time is measured and logged
- No memory leaks or resource exhaustion

## Expected Test Results

### Full Suite (Normal)

- ~50+ tests total
- Unit Tests: ~22 tests (including 7 failure tests)
- Integration Tests: ~7 tests
- Parallel Tests: ~3 major test groups
- **Expected Pass Rate: 100%**
- **Total Time: 60-120 seconds**

### Quick Mode

- Reduced parallel tests
- **Total Time: 30-60 seconds**
- **Expected Pass Rate: 100%**

## Interpreting Results

### All Tests Pass ✓

```
  Passed:     50+
  Failed:     0
  Total:      50+
  Pass Rate:  100%

  ✓ All tests passed!
```

The script is functioning correctly with:
- Proper error handling
- Mutex locking working
- No race conditions detected
- Ready for production use

### Some Tests Fail ✗

Check failure messages for:

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Test Rclone Jobs

on: [push, pull_request]

jobs:
  test:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v2
      - name: Run tests
        run: |
          cd "Sync Scripts"
          .\Test-RcloneJobs.ps1 -TestSuite Unit
          .\Test-RcloneJobs.ps1 -TestSuite Integration
          .\Test-RcloneJobs.ps1 -TestSuite Parallel -QuickTest
```

### Local CI Example (PowerShell)

```powershell
# Run full test suite and exit with appropriate code
.\Test-RcloneJobs.ps1
exit $LASTEXITCODE
```

## Troubleshooting Tests

### Test Hangs

- Check for rclone processes still running
- Verify mutex is not stuck: `Get-Process | grep PowerShell`
- Increase timeout values if system is slow

### Parallel Tests Timeout

- Run with `-QuickTest` flag first
- Check system resources (CPU, memory)
- Verify no other scripts are running

### Log File Tests Fail

- Ensure `logs/` directory has proper permissions
- Check disk space for log generation
- Verify no antivirus blocking file operations

### Rate Limit Test Fails

- Function extraction may fail with syntax changes
- Recreate test file: `Remove-Item Test-RcloneJobs.ps1; ./create-tests.ps1`

## Extending Tests

### Add New Unit Test

```powershell
function Test-MyFeature {
    Write-TestHeader "Unit Test: My Feature"
    
    Write-TestCase "Test description"
    $result = My-Function -Param "value"
    Assert-Equal "expected" $result "Should do something"
}
```

### Add New Integration Test

```powershell
function Test-MyIntegration {
    Write-TestHeader "Integration Test: My Feature"
    
    Write-TestCase "Running script with new parameter"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File $testConfig.scriptPath `
        -MyParam value
    Assert-Equal 0 $LASTEXITCODE "Should succeed"
}
```

### Register Test in Main()

```powershell
switch ($TestSuite) {
    'Unit' {
        Test-MyFeature
        # ... other tests
    }
}
```

## Performance Expectations

| Operation | Expected Time | Max Acceptable |
|-----------|---|---|
| Unit tests | 5-10s | 15s |
| Integration tests | 20-40s | 60s |
| Parallel tests (3 instances) | 15-30s | 45s |
| Load tests (5 instances) | 25-45s | 90s |
| Full suite | 60-120s | 180s |
| Full suite (quick) | 30-60s | 90s |

## Report Files

When running with `-Verbose`:

- All test logs stored in: `test-logs/`
- Test logs automatically deleted without `-Verbose`
- Use `test-logs/` to debug failures

### Test Report Includes

- ✓/✗ Pass/fail indicators
- ℹ Information messages
- Execution time measurements
- Job completion status
- Mutex lock state

## Best Practices

1. **Run Unit Tests First**: Quick validation of core functions
2. **Run Integration Tests Next**: Full script functionality
3. **Run Parallel Tests Last**: Most resource intensive
4. **Use QuickTest for CI/CD**: Faster feedback loop
5. **Run Full Suite Regularly**: Comprehensive validation
6. **Monitor Performance**: Track execution times over releases

## Maintenance

- Update tests when adding new features
- Verify tests pass before committing changes
- Keep test data in sync with config examples
- Monitor and optimize slow tests
- Document any known test limitations

## Support

For test failures or improvements, check:

1. PowerShell version (`$PSVersionTable.PSVersion`)
2. Rclone installation and PATH
3. Disk space and permissions
4. Network connectivity for actual backup tests
5. System resources during parallel tests
