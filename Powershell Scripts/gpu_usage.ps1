$gpuProcesses = Get-Counter -Counter "\GPU Process Memory(*)\Dedicated Usage" -ErrorAction SilentlyContinue

$results = foreach ($counter in $gpuProcesses.CounterSamples) {
    # Extract the full instance name inside the parentheses
    if ($counter.Path -match '\(([^)]+)\)') {
        $instanceName = $Matches[1]
        
        # Use Regex to explicitly capture the numbers after 'pid_'
        if ($instanceName -match 'pid_(\d+)') {
            $pidPart = $Matches[1]
            
            if ($counter.CookedValue -gt 0) {
                $process = Get-Process -Id ([int]$pidPart) -ErrorAction SilentlyContinue
                if ($process) {
                    [PSCustomObject]@{
                        ProcessName = $process.ProcessName
                        PID         = $process.Id
                        VRAM_MB     = [Math]::Round($counter.CookedValue / 1MB, 2)
                    }
                }
            }
        }
    }
}

# Group by PID so we sum up apps utilizing multiple GPU engine contexts
if ($results) {
    $results | Group-Object PID | ForEach-Object {
        [PSCustomObject]@{
            ProcessName   = $_.Group[0].ProcessName
            PID           = $_.Name
            Total_VRAM_MB = [Math]::Round(($_.Group | Measure-Object VRAM_MB -Sum).Sum, 2)
        }
    } | Sort-Object Total_VRAM_MB -Descending | Format-Table -AutoSize
} else {
    Write-Host "No active VRAM footprint detected via Windows Performance Counters." -ForegroundColor Yellow
}
