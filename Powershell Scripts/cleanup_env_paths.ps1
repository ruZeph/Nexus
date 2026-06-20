# 1. Fetch the current User PATH string and split it into an array
$currentPathString = [Environment]::GetEnvironmentVariable("Path", "User")
$pathList = $currentPathString -split ';'

$cleanPaths = [System.Collections.Generic.List[string]]::new()
$removalReasons = [System.Collections.Generic.List[PSCustomObject]]::new()

# 2. Iterate through paths and evaluate with reasons
foreach ($path in $pathList) {
    $trimmedPath = $path.Trim()
    
    # Handle empty or whitespace entries (e.g., trailing semicolons)
    if ([string]::IsNullOrWhiteSpace($trimmedPath)) { 
        continue 
    }

    # Reason 1: Check for duplicates
    if ($cleanPaths -contains $trimmedPath) {
        $removalReasons.Add([PSCustomObject]@{
            Path   = $trimmedPath
            Type   = "Duplicate"
            Reason = "This path is already included earlier in your PATH variable. Redundant entries waste character space."
        })
        continue
    }

    # Reason 2: Check if the folder physically exists
    if (-not (Test-Path -Path $trimmedPath)) {
        # Check if it's an unexpanded environment variable like %USERPROFILE%
        if ($trimmedPath -like "%*%") {
            $reasonText = "Contains unexpanded Windows environment variables (like %USERPROFILE%). The system cannot verify this path format safely via this script."
        } else {
            $reasonText = "The directory does not exist on your hard drive. The software was likely uninstalled or moved, leaving a 'dead' reference."
        }

        $removalReasons.Add([PSCustomObject]@{
            Path   = $trimmedPath
            Type   = "Dead/Invalid"
            Reason = $reasonText
        })
        continue
    }

    # If it passes both checks, keep it
    $cleanPaths.Add($trimmedPath)
}

# 3. Reconstruct the new cleaned PATH string
$newPathString = $cleanPaths -join ';'

# 4. Determine safety color before writing to host
$color = "Green"
if ($newPathString.Length -ge 2047) { $color = "Red" }

# 5. Display Summary Report
Write-Host "`n=== PATH OPTIMIZATION REPORT ===" -ForegroundColor Cyan
Write-Host "Original Length : $($currentPathString.Length) characters"
Write-Host "New Length      : $($newPathString.Length) characters (Limit is 2047)" -ForegroundColor $color
Write-Host "--------------------------------"

# 6. Print detailed breakdown of removals and reasons
if ($removalReasons.Count -gt 0) {
    Write-Host "`n[MODIFICATIONS BREAKDOWN]:" -ForegroundColor Yellow
    foreach ($item in $removalReasons) {
        if ($item.Type -eq "Duplicate") {
            Write-Host "[-] Path  : $($item.Path)" -ForegroundColor Yellow
            Write-Host "    Type  : $($item.Type)" -ForegroundColor Yellow
            Write-Host "    Reason: $($item.Reason)`n" -ForegroundColor Gray
        } else {
            Write-Host "[-] Path  : $($item.Path)" -ForegroundColor Red
            Write-Host "    Type  : $($item.Type)" -ForegroundColor Red
            Write-Host "    Reason: $($item.Reason)`n" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "No redundant or broken paths detected. Your PATH is clean!" -ForegroundColor Green
}

# 7. Safe Prompt Before Commit
Write-Host "--------------------------------"
$choice = Read-Host "Do you want to apply these changes to your User PATH? (Y/N)"
if ($choice -eq 'Y' -or $choice -eq 'y') {
    [Environment]::SetEnvironmentVariable("Path", $newPathString, "User")
    Write-Host "Successfully updated your User PATH environment variable!" -ForegroundColor Green
    Write-Host "Please restart any open terminal windows or applications for changes to take effect." -ForegroundColor Yellow
} else {
    Write-Host "Operation cancelled. No changes were made." -ForegroundColor Gray
}
