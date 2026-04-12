param(
    [string]$InstallPath,
    [string]$RepoOwner = 'ruZeph',
    [string]$RepoName = 'Nexus',
    [string]$RepoBranch = 'main',
    [switch]$SkipRcloneInstall,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "[STEP] $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Get-CommandPath {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $null
    }

    if ($cmd.PSObject.Properties.Name -contains 'Source' -and $cmd.Source) {
        return $cmd.Source
    }

    if ($cmd.PSObject.Properties.Name -contains 'Path' -and $cmd.Path) {
        return $cmd.Path
    }

    return $cmd.Definition
}

function Invoke-DownloadFile {
    param(
        [string]$Uri,
        [string]$OutFile,
        [int]$Retries = 3
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Invoke-RestMethod -Uri $Uri -OutFile $OutFile -TimeoutSec 60
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt $Retries) {
                $waitSeconds = 2 * $attempt
                Write-Warn "Download failed ($attempt/$Retries): $Uri. Retrying in ${waitSeconds}s."
                Start-Sleep -Seconds $waitSeconds
            }
        }
    }

    throw "Failed to download after $Retries attempts: $Uri. Error: $($lastError.Exception.Message)"
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [switch]$IgnoreExitCode
    )

    & $Command @Arguments
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        throw ([string]::Format("Command failed with exit code {0}: {1} {2}", $exitCode, $Command, ($Arguments -join ' ')))
    }

    return $exitCode
}

function Resolve-InstallPath {
    param(
        [AllowNull()][string]$RequestedPath,
        [bool]$PromptUser = $true
    )

    $defaultPath = (Get-Location).ProviderPath
    $selectedPath = $RequestedPath

    if ([string]::IsNullOrWhiteSpace($selectedPath) -and $PromptUser -and [Environment]::UserInteractive) {
        $inputPath = Read-Host "Install path [$defaultPath]"
        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            $selectedPath = $defaultPath
        }
        else {
            $selectedPath = $inputPath
        }
    }

    if ([string]::IsNullOrWhiteSpace($selectedPath)) {
        $selectedPath = $defaultPath
    }

    if (-not [System.IO.Path]::IsPathRooted($selectedPath)) {
        $selectedPath = Join-Path $defaultPath $selectedPath
    }

    return [System.IO.Path]::GetFullPath($selectedPath)
}

function Get-SetupSelections {
    param([bool]$DefaultForce)

    $selection = [pscustomobject]@{
        ConfigMode = 'default'
        Force = $DefaultForce
    }

    if (-not [Environment]::UserInteractive) {
        return $selection
    }

    Write-Host ''
    Write-Step 'Setup Options (multi-choice)'
    Write-Host '  1) Use repository sample config (default is blank config)' -ForegroundColor Gray
    Write-Host '  2) Overwrite existing setup files/config' -ForegroundColor Gray

    $inputValue = Read-Host 'Select options (comma-separated, Enter for defaults)'
    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        return $selection
    }

    $tokens = @($inputValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($token in $tokens) {
        switch ($token) {
            '1' { $selection.ConfigMode = 'copy' }
            '2' { $selection.Force = $true }
            default { Write-Warn "Unknown setup option '$token' ignored." }
        }
    }

    return $selection
}

function Initialize-InstallLayout {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Overwrite
    )

    Write-Step "Preparing install directory: $Path"
    New-Item -ItemType Directory -Force -Path $Path | Out-Null

    $existingItems = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    $isFirstTime = ($existingItems.Count -eq 0)

    if (-not $isFirstTime -and -not $Overwrite -and [Environment]::UserInteractive) {
        $answer = Read-Host "Install directory is not empty. Continue and reuse existing files? (Y/n)"
        if (-not [string]::IsNullOrWhiteSpace($answer) -and $answer.Trim().ToLowerInvariant() -in @('n', 'no')) {
            throw 'Setup cancelled by user because install directory is not empty.'
        }
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'logs') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'src') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'tools') | Out-Null
}

function New-BlankConfig {
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

function Initialize-ConfigFile {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$ConfigUrl,
        [ValidateSet('default', 'copy')][string]$Mode = 'default',
        [switch]$Overwrite
    )

    if ((Test-Path -LiteralPath $ConfigPath) -and -not $Overwrite) {
        Write-Info "Keeping existing config file: $ConfigPath"
        return
    }

    if ($Mode -eq 'copy') {
        Write-Info 'Creating config from repository sample (explicitly requested).'
        Invoke-DownloadFile -Uri $ConfigUrl -OutFile $ConfigPath
        Write-Ok "Saved: $ConfigPath"
        return
    }

    Write-Info 'Creating blank starter config (default behavior).'
    $blank = New-BlankConfig
    $blank | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-Ok "Saved: $ConfigPath"
}

function Initialize-Rclone {
    param([switch]$SkipInstall)

    $rclonePath = Get-CommandPath -Name 'rclone'
    if (-not [string]::IsNullOrWhiteSpace($rclonePath)) {
        Write-Ok "rclone found: $rclonePath"
        return
    }

    if ($SkipInstall) {
        throw 'rclone is not installed and -SkipRcloneInstall was provided. Install rclone first, then re-run setup.'
    }

    $installed = $false
    $wingetPath = Get-CommandPath -Name 'winget'
    $chocoPath = Get-CommandPath -Name 'choco'

    if (-not [string]::IsNullOrWhiteSpace($wingetPath)) {
        Write-Step 'Installing rclone using winget'
        try {
            Invoke-NativeCommand -Command $wingetPath -Arguments @('install', '--id', 'Rclone.Rclone', '-e', '--accept-source-agreements', '--accept-package-agreements') -IgnoreExitCode
        }
        catch {
            Write-Warn "winget install failed: $($_.Exception.Message)"
        }

        $rclonePath = Get-CommandPath -Name 'rclone'
        if (-not [string]::IsNullOrWhiteSpace($rclonePath)) {
            $installed = $true
        }
    }

    if (-not $installed -and -not [string]::IsNullOrWhiteSpace($chocoPath)) {
        Write-Step 'Installing rclone using chocolatey'
        try {
            Invoke-NativeCommand -Command $chocoPath -Arguments @('install', 'rclone', '-y') -IgnoreExitCode
        }
        catch {
            Write-Warn "choco install failed: $($_.Exception.Message)"
        }

        $rclonePath = Get-CommandPath -Name 'rclone'
        if (-not [string]::IsNullOrWhiteSpace($rclonePath)) {
            $installed = $true
        }
    }

    if (-not $installed) {
        throw 'Unable to install rclone automatically. Install manually from https://rclone.org/downloads/ and ensure it is on PATH.'
    }

    Write-Ok 'rclone installed successfully.'
}

function Initialize-RcloneRemote {
    $rclonePath = Get-CommandPath -Name 'rclone'
    if ([string]::IsNullOrWhiteSpace($rclonePath)) {
        throw 'rclone is not available on PATH.'
    }

    $hasRemote = $false
    try {
        $output = & $rclonePath 'listremotes' 2>$null
        if ($LASTEXITCODE -eq 0 -and @($output).Count -gt 0) {
            $hasRemote = $true
        }
    }
    catch {
        $hasRemote = $false
    }

    if ($hasRemote) {
        Write-Ok 'At least one rclone remote is configured.'
        return
    }

    Write-Warn 'No rclone remotes found. You must configure one before backup jobs can run.'
    if ([Environment]::UserInteractive) {
        $answer = Read-Host 'Run rclone config now? (y/N)'
        if ($answer.Trim().ToLowerInvariant() -in @('y', 'yes')) {
            & $rclonePath 'config'
            if ($LASTEXITCODE -ne 0) {
                throw 'rclone config failed. Configure a remote manually and rerun setup.'
            }
        }
    }
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "PowerShell 5.1+ is required. Detected: $($PSVersionTable.PSVersion)"
    }

    $selections = Get-SetupSelections -DefaultForce:$Force
    $selectedConfigMode = [string]$selections.ConfigMode
    $overwriteExisting = [bool]$selections.Force

    $InstallPath = Resolve-InstallPath -RequestedPath $InstallPath -PromptUser $true
    Initialize-InstallLayout -Path $InstallPath -Overwrite:$overwriteExisting

    Initialize-Rclone -SkipInstall:$SkipRcloneInstall

    $baseUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoBranch/Sync%20Scripts"
    $files = @(
        @{ Source = 'Launch-Runner.ps1'; Required = $true; Target = 'Launch-Runner.ps1' },
        @{ Source = 'src/Run-RcloneJobs.ps1'; Required = $true; Target = 'src/Run-RcloneJobs.ps1' },
        @{ Source = 'tools/Test-RcloneJobs.ps1'; Required = $true; Target = 'tools/Test-RcloneJobs.ps1' },
        @{ Source = 'tools/New-RcloneJobConfig.ps1'; Required = $true; Target = 'tools/New-RcloneJobConfig.ps1' },
        @{ Source = 'README.md'; Required = $false; Target = 'README.md' }
    )

    Write-Step 'Downloading setup files'
    foreach ($file in $files) {
        $targetPath = Join-Path $InstallPath $file.Target
        $exists = Test-Path -LiteralPath $targetPath

        if ($exists -and -not $overwriteExisting) {
            Write-Info "Keeping existing file: $targetPath"
            continue
        }

        $url = "$baseUrl/$($file.Source)"
        Write-Info "Downloading $($file.Source)"
        try {
            $targetDir = Split-Path -Parent $targetPath
            if (-not [string]::IsNullOrWhiteSpace($targetDir)) {
                New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
            }
            Invoke-DownloadFile -Uri $url -OutFile $targetPath
            Write-Ok "Saved: $targetPath"
        }
        catch {
            if ($file.Required) {
                throw
            }
            Write-Warn "Optional file download failed: $url"
        }
    }

    $configPath = Join-Path $InstallPath 'backup-jobs.json'
    $configUrl = "$baseUrl/backup-jobs.json"
    Initialize-ConfigFile -ConfigPath $configPath -ConfigUrl $configUrl -Mode $selectedConfigMode -Overwrite:$overwriteExisting

    Initialize-RcloneRemote

    $helperPath = Join-Path $InstallPath 'tools/New-RcloneJobConfig.ps1'

    if ([Environment]::UserInteractive) {
        Write-Step 'Launching job configuration helper'
        & $helperPath -ConfigPath $configPath -Interactive -Force:$overwriteExisting
        if ($LASTEXITCODE -ne 0) {
            throw 'Job configuration helper failed.'
        }
    }
    else {
        Write-Warn 'Non-interactive session detected. Skipping interactive job helper launch.'
    }

    Write-Ok 'Quick start setup completed successfully.'
    Write-Host ''
    Write-Host 'Next commands:' -ForegroundColor Cyan
    Write-Host "  cd `"$InstallPath`""
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\Launch-Runner.ps1 -Mode dryrun'
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\Launch-Runner.ps1 -Mode monitor -IdleTimeSeconds 10'
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\New-RcloneJobConfig.ps1 -ConfigPath .\backup-jobs.json -Interactive'
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
