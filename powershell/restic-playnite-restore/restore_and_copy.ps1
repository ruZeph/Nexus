# ============================
# Restic Restore Script
# ============================
# Phase 1.5: takeown + icacls to handle ACL-blocked paths before robocopy.
# Run twice per plan: once on the staged temp restore (so robocopy can read
# it) and once on the real destination after a live copy (so ownership is
# reset to the current user instead of being left on whatever SID the backup
# was originally taken under — otherwise apps can be blocked from opening
# the restored files even though the copy itself succeeded).
# Robocopy flags: /COPY:DT /DCOPY:DT (data + timestamps only, no ACL copying,
# which is exactly why the destination still needs its own unlock pass).

param(
    [switch]$DryRun,
    [string]$ResticPassword = ""
)

# ----- Admin Rights Check & Auto-Prompt -----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "`nAdministrator privileges are required to restore system-level path metadata." -ForegroundColor Yellow
    $elevate = Read-Host "Relaunch script as Administrator now? (Y/N)"
    if ($elevate -match "^Y") {
        $scriptPath = $MyInvocation.MyCommand.Path
        $argList = @()
        if ($DryRun) { $argList += "-DryRun" }
        if (-not [string]::IsNullOrWhiteSpace($ResticPassword)) { $argList += "-ResticPassword `"$ResticPassword`"" }
        
        Start-Process powershell -Verb RunAs -ArgumentList "-File `"$scriptPath`" $argList"
        exit
    }
    else {
        Write-Host "Execution cancelled by user. Exiting." -ForegroundColor Red
        exit
    }
}

# ----- Configuration -----
$ResticExe    = "restic.exe"
$Repository   = "D:\Backups\Restic"
$RestoreRoot  = "C:\ResticRestoreTemp"


# ----- Password -----
$BSTR = [IntPtr]::Zero

if (-not [string]::IsNullOrWhiteSpace($ResticPassword)) {
    Write-Host "Using Restic password provided via script parameter."
    $env:RESTIC_PASSWORD = $ResticPassword
}
else {
    $SecurePass = Read-Host "Enter Restic Password" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass)
    $env:RESTIC_PASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
}

# ----- Logging -----
$LogTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $RestoreRoot "restore_log_$LogTimestamp.txt"
New-Item -ItemType Directory -Force -Path $RestoreRoot | Out-Null
Start-Transcript -Path $LogFile -Append | Out-Null

# ----- Phase 1.5: Take ownership + grant full control on a path -----
function Invoke-UnlockPath {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Write-Host "  [Phase 1.5] Taking ownership: $Path"
    takeown /F $Path /R /D Y 2>&1 | Out-Null
    Write-Host "  [Phase 1.5] Granting full control: $Path"
    icacls $Path /grant "${env:USERNAME}:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
}

try {
    Write-Host "`nFetching snapshots..."
    $snapshotJson = & $ResticExe -r $Repository snapshots --json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read repository."
    }
    $snapshots = $snapshotJson | ConvertFrom-Json

    # Build latest snapshot for each plan tag
    $latestPlans = @{}
    foreach ($snap in $snapshots) {
        foreach ($tag in $snap.tags) {
            if ($tag -like "plan:*") {
                if (-not $latestPlans.ContainsKey($tag) -or ([datetime]$snap.time -gt [datetime]$latestPlans[$tag].time)) {
                    $latestPlans[$tag] = $snap
                }
            }
        }
    }

    if ($latestPlans.Count -eq 0) {
        throw "No plan:* tags found."
    }

    # ----- Pre-Execution Summary Block -----
    Write-Host "`n========================================================"
    Write-Host "         RESTORE PLAN & TARGET MAPPING SUMMARY"
    Write-Host "========================================================`n"

    foreach ($plan in $latestPlans.Keys | Sort-Object) {
        $snap = $latestPlans[$plan]
        $restoreTemp  = Join-Path $RestoreRoot ($plan.Replace(":", "_"))

        $planPaths = $snap.paths
        $displayPath = $planPaths -join ', '

        # Destination comes directly from snapshot metadata — never hardcoded.
        $roboDest = $planPaths[0]

        # Construct the deep folder path Restic will create inside the temp dir
        # by stripping only the colon from the original path (drive-letter agnostic).
        $relativePath = $roboDest -replace ':', ''
        $relativePath = $relativePath.TrimStart('\', '/')

        $roboSource = Join-Path $restoreTemp $relativePath

        Write-Host ("[{0}]" -f $plan) -ForegroundColor Cyan
        Write-Host ("  Snapshot        : {0}" -f $snap.short_id)
        Write-Host ("  Plan Path(s)    : {0}" -f $displayPath)
        Write-Host ("  Robocopy Source : {0}" -f $roboSource) -ForegroundColor Yellow
        Write-Host ("  Robocopy Dest   : {0}`n" -f $roboDest) -ForegroundColor Green
    }

    if ($DryRun) {
        Write-Host "========================================================" -ForegroundColor Yellow
        Write-Host "*** DRY RUN MODE SUMMARY & EXECUTION PLAN ***" -ForegroundColor Yellow
        Write-Host "1. Extraction:   Files will extract to '$RestoreRoot'." -ForegroundColor Yellow
        Write-Host "2. Permissions:  Phase 1.5 (takeown/icacls) will run on temporary files." -ForegroundColor Yellow
        Write-Host "3. Robocopy:     Will run in /L (List-Only) mode." -ForegroundColor Yellow
        Write-Host "                 Output will show exact directory routing from inner folders." -ForegroundColor Yellow
        Write-Host "4. Destination:  NO FILES WILL BE WRITTEN TO REAL TARGET PATHS." -ForegroundColor Yellow
        Write-Host "5. Cleanup:      All temporary extracted folders will be completely deleted." -ForegroundColor Yellow
        Write-Host "========================================================`n" -ForegroundColor Yellow
    }

    $confirm = Read-Host "Continue? (Y/N)"
    if ($confirm -notmatch "^Y") {
        Write-Host "Cancelled."
        exit
    }

    foreach ($plan in $latestPlans.Keys | Sort-Object) {
        $snap = $latestPlans[$plan]
        $restoreTemp  = Join-Path $RestoreRoot ($plan.Replace(":", "_"))

        # Destination comes directly from snapshot metadata — never hardcoded.
        $roboDest = $snap.paths[0]

        # Calculate the deep source path by stripping only the colon from the original path
        $relativePath = $roboDest -replace ':', ''
        $relativePath = $relativePath.TrimStart('\', '/')
        $roboSource = Join-Path $restoreTemp $relativePath

        Write-Host "`n========================================"
        Write-Host "Processing $plan"
        Write-Host "Snapshot: $($snap.short_id)"
        Write-Host "========================================"

        # Clear stale temp dir before beginning
        if (Test-Path $restoreTemp) {
            Invoke-UnlockPath -Path $restoreTemp
            Remove-Item $restoreTemp -Force -Recurse -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        New-Item -ItemType Directory -Force -Path $restoreTemp | Out-Null

        # --- 1. Restic restore to temp ---
        Write-Host "`n[1/3] Extracting files to temporary directory..."
        $resticOutput = & $ResticExe -r $Repository restore $snap.short_id --target $restoreTemp 2>&1
        $resticOutput | ForEach-Object { Write-Host $_ }

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Restic restore failed for $plan. Skipping copy."
            continue
        }

        if (-not (Test-Path $roboSource)) {
            throw "Expected restore source not found: $roboSource"
        }

        # --- 2. Phase 1.5: unlock restored files ---
        Write-Host "`n[2/3] Unlocking ACLs..."
        Invoke-UnlockPath -Path $restoreTemp

        # --- 3. Robocopy Execution ---
        Write-Host "`n[3/3] Robocopy logic targeting: $roboDest"
        
        $roboArgs = @(
            $roboSource,
            $roboDest,
            "/E",
            "/COPY:DT",
            "/DCOPY:DT",
            "/R:1",
            "/W:1",
            "/MT:16",
            "/BYTES",
            "/NP",
            "/NFL"  # Suppresses individual file names to stop console spam
        )

        if ($DryRun) {
            $roboArgs += "/L"
            
            # Execute and parse Robocopy output
            $roboOutput = & robocopy $roboArgs
            $rc = $LASTEXITCODE

            Write-Host "`n      --- TARGET DIRECTORY MAPPING ---" -ForegroundColor Magenta
            $summaryFound = $false

            foreach ($line in $roboOutput) {
                # Look for newly created directories in the Robocopy log
                if ($line -match "New Dir\s+(.*)") {
                    $sourcePath = $matches[1].Trim()
                    
                    # Swap the deep inner source path out for the real destination path
                    $destPath = $sourcePath.Replace($roboSource, $roboDest)
                    $destPath = $destPath -replace "\\\\", "\"
                    
                    Write-Host "      [Will Create/Merge] $destPath" -ForegroundColor Magenta
                }
                # Detect the start of the summary block
                elseif ($line -match "Total\s+Copied\s+Skipped") {
                    $summaryFound = $true
                    Write-Host "`n      --- SUMMARY ---" -ForegroundColor Cyan
                }
                
                # Print the summary block
                if ($summaryFound) {
                    Write-Host $line
                }
            }

            if ($rc -le 7) {
                Write-Host "`n[DryRun Result] Robocopy diff comparison successful (Exit code: $rc)." -ForegroundColor Green
            } else {
                Write-Warning "`nRobocopy returned error exit code $rc for $plan."
            }

        } else {
            # Live Run: Suppress directory list as well, run normally
            $roboArgs += "/NDL"
            $roboOutput = & robocopy $roboArgs
            $rc = $LASTEXITCODE

            $roboOutput | ForEach-Object { Write-Host $_ }

            if ($rc -le 7) {
                Write-Host "`nRobocopy copy completed successfully (Exit code: $rc)." -ForegroundColor Green
            } else {
                Write-Warning "`nRobocopy returned error exit code $rc for $plan."
            }

            # --- 3.5 Destination unlock ---
            # /COPY:DT deliberately does not copy security descriptors, so any
            # foreign ownership already sitting on $roboDest (e.g. a leftover
            # SID from the machine the backup was originally taken on) survives
            # the copy untouched and can leave apps unable to open the restored
            # files. Re-run the same takeown/icacls pass against the real
            # destination so the current user ends up with clean ownership.
            Write-Host "`n[3.5] Unlocking destination for current user: $roboDest"
            Invoke-UnlockPath -Path $roboDest
        }

        # --- 4. Temp Cleanup ---
        Write-Host "`nCleaning up temporary directory..."
        Invoke-UnlockPath -Path $restoreTemp
        Remove-Item $restoreTemp -Force -Recurse -ErrorAction SilentlyContinue
    }

    Write-Host "`n========================================"
    Write-Host "All tasks complete."
    Write-Host "========================================"
}
finally {
    Remove-Item Env:RESTIC_PASSWORD -ErrorAction SilentlyContinue
    if ($null -ne $BSTR -and $BSTR -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
    Write-Host "`nLog saved to: $LogFile"
    Stop-Transcript | Out-Null
}