Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-UnixMilliseconds {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    try {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Value).LocalDateTime
    }
    catch {
        return $null
    }
}

function Get-BackrestOperationStatusDetails {
    param([Parameter(Mandatory = $true)][object]$Operation)

    $rawStatus = $null
    foreach ($propertyName in @('status', 'state', 'result', 'phase')) {
        if ($Operation.PSObject.Properties.Match($propertyName).Count -gt 0) {
            $candidate = [string]$Operation.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $rawStatus = $candidate.Trim()
                break
            }
        }
    }

    $normalizedStatus = if ($null -ne $rawStatus) { $rawStatus.ToLowerInvariant() } else { '' }

    $successStatuses = @('success', 'succeeded', 'completed', 'complete', 'done', 'finished', 'ok', 'passed')
    $failureStatuses = @('failed', 'failure', 'error', 'canceled', 'cancelled', 'aborted', 'timeout', 'timedout')
    $activeStatuses = @('queued', 'pending', 'running', 'in-progress', 'inprogress', 'processing', 'started', 'starting', 'scheduled', 'waiting', 'active')

    $hasTerminalMarker = $false
    foreach ($propertyName in @('unixTimeEndMs', 'endUnixTimeMs', 'endedAt', 'finishedAt', 'completedAt', 'completionTime', 'timeEnded', 'endTime')) {
        if ($Operation.PSObject.Properties.Match($propertyName).Count -gt 0) {
            $candidate = $Operation.$propertyName
            if ($null -ne $candidate -and -not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $hasTerminalMarker = $true
                break
            }
        }
    }

    $outcome = 'pending'
    $isTerminal = $false

    if ($failureStatuses -contains $normalizedStatus -or $normalizedStatus -match '(fail|error|cancel|abort|timeout)') {
        $outcome = 'failed'
        $isTerminal = $true
    }
    elseif ($successStatuses -contains $normalizedStatus) {
        $outcome = 'success'
        $isTerminal = $true
    }
    elseif ($activeStatuses -contains $normalizedStatus) {
        $outcome = 'pending'
        $isTerminal = $false
    }
    elseif ($hasTerminalMarker) {
        $outcome = 'success'
        $isTerminal = $true
    }

    return [pscustomobject]@{
        RawStatus = $rawStatus
        NormalizedStatus = $normalizedStatus
        HasTerminalMarker = $hasTerminalMarker
        IsTerminal = $isTerminal
        Outcome = $outcome
    }
}

function Wait-BackrestOperationFinalStatus {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$OperationFetcher,
        [Parameter(Mandatory = $true)][string]$PlanId,
        [Parameter(Mandatory = $true)][datetime]$Since,
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [hashtable]$Headers = @{},
        [int]$TimeoutSeconds = 1800,
        [int]$PollIntervalSeconds = 5,
        [int]$CorrelationSkewSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $correlationFloor = $Since.AddSeconds(-1 * [math]::Abs($CorrelationSkewSeconds))

    do {
        $latestOperation = & $OperationFetcher -PlanId $PlanId -Endpoint $Endpoint -Headers $Headers
        if ($null -ne $latestOperation) {
            $startTime = ConvertFrom-UnixMilliseconds $latestOperation.unixTimeStartMs
            $endTime = $null
            foreach ($propertyName in @('unixTimeEndMs', 'endUnixTimeMs')) {
                if ($latestOperation.PSObject.Properties.Match($propertyName).Count -gt 0) {
                    $endTime = ConvertFrom-UnixMilliseconds $latestOperation.$propertyName
                    if ($null -ne $endTime) { break }
                }
            }

            $isCorrelated = $false
            if ($null -eq $startTime) {
                # Some Backrest payloads omit/rename start timestamps; do not hard-fail correlation.
                $isCorrelated = $true
            }
            elseif ($startTime -ge $correlationFloor) {
                $isCorrelated = $true
            }
            elseif ($null -ne $endTime -and $endTime -ge $correlationFloor) {
                # Allow terminal operations that started slightly earlier but completed in our window.
                $isCorrelated = $true
            }

            if ($isCorrelated) {
                $statusDetails = Get-BackrestOperationStatusDetails -Operation $latestOperation
                if ($statusDetails.IsTerminal) {
                    return [pscustomobject]@{
                        Operation = $latestOperation
                        StartTime = $startTime
                        EndTime = $endTime
                        RawStatus = $statusDetails.RawStatus
                        NormalizedStatus = $statusDetails.NormalizedStatus
                        Outcome = $statusDetails.Outcome
                    }
                }
            }
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    } while ((Get-Date) -lt $deadline)

    return $null
}