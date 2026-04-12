param(
    [string]$ConfigPath = (Join-Path (Get-Location) 'backup-jobs.json'),
    [switch]$Interactive,
    [switch]$AddJob,
    [string]$JobName,
    [string]$Source,
    [string]$Dest,
    [string]$PresetName = 'default',
    [ValidateSet('copy', 'sync')][string]$Operation,
    [int]$Interval = 0,
    [switch]$Disabled,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Test-RcloneDestFormat {
    param([string]$Value)
    return $Value -match '^[^:]+:.+'
}

function Set-MissingProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function New-DefaultConfig {
    return [pscustomobject]@{
        settings = [pscustomobject]@{
            continueOnJobError = $true
            defaultOperation = 'sync'
            logRetentionCount = 10
            jobIntervalSeconds = 30
            defaultExtraArgs = @('--retries', '15', '--retries-sleep', '30s')
        }
        profiles = [pscustomobject]@{
            default = [pscustomobject]@{
                operation = 'sync'
                extraArgs = @('--fast-list', '--transfers', '8')
            }
        }
        jobs = @()
    }
}

function Get-OrCreateConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warn "Config file not found at $Path. Creating a new one."
        $cfg = New-DefaultConfig
        Save-Config -Path $Path -Config $cfg
        return $cfg
    }

    try {
        $cfg = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        throw "Config file is not valid JSON: $Path"
    }

    Set-MissingProperty -Object $cfg -Name 'settings' -Value ([pscustomobject]@{})
    Set-MissingProperty -Object $cfg -Name 'profiles' -Value ([pscustomobject]@{})
    Set-MissingProperty -Object $cfg -Name 'jobs' -Value @()

    Set-MissingProperty -Object $cfg.settings -Name 'continueOnJobError' -Value $true
    Set-MissingProperty -Object $cfg.settings -Name 'defaultOperation' -Value 'sync'
    Set-MissingProperty -Object $cfg.settings -Name 'logRetentionCount' -Value 10
    Set-MissingProperty -Object $cfg.settings -Name 'jobIntervalSeconds' -Value 30
    Set-MissingProperty -Object $cfg.settings -Name 'defaultExtraArgs' -Value @('--retries', '15', '--retries-sleep', '30s')

    return $cfg
}

function Save-Config {
    param(
        [string]$Path,
        [object]$Config
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $json = $Config | ConvertTo-Json -Depth 30
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Set-ProfileIfMissing {
    param(
        [object]$Config,
        [string]$ProfileName,
        [string]$FallbackOperation
    )

    if ([string]::IsNullOrWhiteSpace($ProfileName)) {
        return
    }

    $profileProp = $Config.profiles.PSObject.Properties[$ProfileName]
    if ($null -eq $profileProp) {
        $operation = if ([string]::IsNullOrWhiteSpace($FallbackOperation)) { 'sync' } else { $FallbackOperation }
        $Config.profiles | Add-Member -MemberType NoteProperty -Name $ProfileName -Value ([pscustomobject]@{
            operation = $operation
            extraArgs = @('--fast-list')
        })
        Write-Warn "Profile '$ProfileName' did not exist. Created it with safe defaults."
    }
}

function Add-ValidatedJob {
    param(
        [object]$Config,
        [string]$Name,
        [string]$JobSource,
        [string]$JobDest,
        [string]$ProfileName,
        [string]$JobOperation,
        [int]$JobInterval,
        [bool]$Enabled,
        [switch]$Overwrite
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'Job name is required.'
    }

    if ([string]::IsNullOrWhiteSpace($JobSource)) {
        throw "Job '$Name' requires source."
    }

    if (-not (Test-Path -LiteralPath $JobSource -PathType Container)) {
        throw "Job '$Name' source path does not exist or is not a directory: $JobSource"
    }

    if ([string]::IsNullOrWhiteSpace($JobDest)) {
        throw "Job '$Name' requires dest."
    }

    if (-not (Test-RcloneDestFormat -Value $JobDest)) {
        throw "Job '$Name' has invalid dest '$JobDest'. Expected format remote:path"
    }

    if ($JobInterval -lt 0) {
        throw "Job '$Name' interval cannot be negative."
    }

    $existing = @($Config.jobs | Where-Object { $_.name -eq $Name })
    if ($existing.Count -gt 0 -and -not $Overwrite) {
        throw "A job named '$Name' already exists. Use -Force to replace it."
    }

    Set-ProfileIfMissing -Config $Config -ProfileName $ProfileName -FallbackOperation $JobOperation

    $newJob = [pscustomobject]@{
        name = $Name
        enabled = $Enabled
        source = $JobSource
        dest = $JobDest
        profile = $ProfileName
    }

    if (-not [string]::IsNullOrWhiteSpace($JobOperation)) {
        $newJob | Add-Member -MemberType NoteProperty -Name 'operation' -Value $JobOperation
    }

    if ($JobInterval -gt 0) {
        $newJob | Add-Member -MemberType NoteProperty -Name 'interval' -Value $JobInterval
    }

    $remaining = @($Config.jobs | Where-Object { $_.name -ne $Name })
    $Config.jobs = @($remaining + $newJob)
}

function Read-RequiredInput {
    param(
        [string]$Prompt,
        [scriptblock]$Validator,
        [string]$ErrorMessage,
        [string]$DefaultValue = ''
    )

    while ($true) {
        $text = if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
            Read-Host $Prompt
        }
        else {
            $value = Read-Host "$Prompt [$DefaultValue]"
            if ([string]::IsNullOrWhiteSpace($value)) { $DefaultValue } else { $value }
        }

        if (& $Validator $text) {
            return $text
        }

        Write-Warn $ErrorMessage
    }
}

function Start-InteractiveWizard {
    param([object]$Config)

    Write-Info 'Interactive job configuration wizard'

    $name = Read-RequiredInput -Prompt 'Job name' -DefaultValue 'documents-backup' -Validator {
        param($value)
        -not [string]::IsNullOrWhiteSpace($value)
    } -ErrorMessage 'Job name cannot be empty.'

    $source = Read-RequiredInput -Prompt 'Source folder path' -Validator {
        param($value)
        -not [string]::IsNullOrWhiteSpace($value) -and (Test-Path -LiteralPath $value -PathType Container)
    } -ErrorMessage 'Source folder must exist and be a directory.'

    $dest = Read-RequiredInput -Prompt 'Destination (remote:path)' -Validator {
        param($value)
        Test-RcloneDestFormat -Value $value
    } -ErrorMessage 'Destination must be in remote:path format.'

    $profileName = Read-RequiredInput -Prompt 'Profile name' -DefaultValue 'default' -Validator {
        param($value)
        -not [string]::IsNullOrWhiteSpace($value)
    } -ErrorMessage 'Profile cannot be empty.'

    $operation = Read-Host 'Operation copy/sync (blank = resolve from config)'
    if (-not [string]::IsNullOrWhiteSpace($operation)) {
        $opNormalized = $operation.Trim().ToLowerInvariant()
        if ($opNormalized -notin @('copy', 'sync')) {
            throw "Operation '$operation' is invalid. Use copy or sync."
        }
        $operation = $opNormalized
    }

    $intervalText = Read-Host 'Interval seconds between jobs (blank = default)'
    $jobInterval = 0
    if (-not [string]::IsNullOrWhiteSpace($intervalText)) {
        if (-not [int]::TryParse($intervalText, [ref]$jobInterval)) {
            throw 'Interval must be an integer.'
        }
        if ($jobInterval -lt 0) {
            throw 'Interval cannot be negative.'
        }
    }

    $enabledText = Read-Host 'Enable this job? (Y/n)'
    $enabled = $true
    if (-not [string]::IsNullOrWhiteSpace($enabledText) -and $enabledText.Trim().ToLowerInvariant() -in @('n', 'no')) {
        $enabled = $false
    }

    Add-ValidatedJob -Config $Config -Name $name -JobSource $source -JobDest $dest -ProfileName $profileName -JobOperation $operation -JobInterval $jobInterval -Enabled $enabled -Overwrite:$Force
    Write-Ok "Job '$name' configured."
}

try {
    if (-not $PSBoundParameters.ContainsKey('Interactive') -and -not $AddJob -and [string]::IsNullOrWhiteSpace($JobName)) {
        $Interactive = $true
    }

    $cfg = Get-OrCreateConfig -Path $ConfigPath

    if ($Interactive) {
        Start-InteractiveWizard -Config $cfg
    }
    else {
        if ([string]::IsNullOrWhiteSpace($JobName) -or [string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Dest)) {
            throw 'Non-interactive mode requires -JobName, -Source, and -Dest.'
        }

        Add-ValidatedJob -Config $cfg -Name $JobName -JobSource $Source -JobDest $Dest -ProfileName $PresetName -JobOperation $Operation -JobInterval $Interval -Enabled:(-not $Disabled) -Overwrite:$Force
        Write-Ok "Job '$JobName' configured in non-interactive mode."
    }

    Save-Config -Path $ConfigPath -Config $cfg
    Write-Ok "Saved configuration: $ConfigPath"
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
