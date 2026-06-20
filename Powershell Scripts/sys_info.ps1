$ErrorActionPreference = 'Continue'

$LogFile = "$env:USERPROFILE\Desktop\sys_info_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss")
Start-Transcript -Path $LogFile -Append | Out-Null

$PSDefaultParameterValues['Format-Table:AutoSize'] = $true
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Section($Title) {
    $line = "=" * 60
    Write-Host "`n$line" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "$line" -ForegroundColor Cyan
}

Section "WINDOWS"
Get-ComputerInfo |
    Select-Object WindowsProductName, WindowsVersion, OsBuildNumber,
                  OsHardwareAbstractionLayer, CsName, OsArchitecture |
    Format-List

Section "SYSTEM"
Get-CimInstance Win32_ComputerSystem |
    Select-Object Manufacturer, Model, SystemType,
                  TotalPhysicalMemory, NumberOfLogicalProcessors, NumberOfProcessors |
    Format-List

Section "CPU"
Get-CimInstance Win32_Processor |
    Select-Object Name, Manufacturer, SocketDesignation, NumberOfCores,
                  NumberOfLogicalProcessors, MaxClockSpeed, CurrentClockSpeed,
                  L2CacheSize, L3CacheSize |
    Format-List

Section "BIOS"
Get-CimInstance Win32_BIOS |
    Select-Object Manufacturer, SMBIOSBIOSVersion, SerialNumber, ReleaseDate |
    Format-List

Section "MOTHERBOARD"
Get-CimInstance Win32_BaseBoard |
    Select-Object Manufacturer, Product, SerialNumber |
    Format-List

Section "MEMORY"
Get-CimInstance Win32_PhysicalMemory |
    Select-Object BankLabel, Manufacturer, PartNumber,
                  @{N="Capacity_GB"; E={[math]::Round($_.Capacity/1GB,1)}},
                  Speed, ConfiguredClockSpeed, SerialNumber |
    Format-Table

Get-CimInstance Win32_OperatingSystem |
    Select-Object @{N="TotalRAM_GB"; E={[math]::Round($_.TotalVisibleMemorySize/1MB,2)}},
                  @{N="FreeRAM_GB";  E={[math]::Round($_.FreePhysicalMemory/1MB,2)}},
                  LastBootUpTime |
    Format-List

Section "GPU"
Get-CimInstance Win32_VideoController |
    Select-Object Name, DriverVersion,
                  @{N="VRAM_GB"; E={[math]::Round($_.AdapterRAM/1GB,1)}},
                  CurrentHorizontalResolution, CurrentVerticalResolution,
                  CurrentRefreshRate |
    Format-List

Section "DISKS"
Get-CimInstance Win32_DiskDrive |
    Select-Object Model, InterfaceType, MediaType,
                  @{N="Size_GB"; E={[math]::Round($_.Size/1GB,1)}} |
    Format-Table

try {
    Get-PhysicalDisk |
        Select-Object FriendlyName, MediaType,
                      @{N="Size_GB"; E={[math]::Round($_.Size/1GB,1)}},
                      HealthStatus, OperationalStatus |
        Format-Table
} catch {
    Write-Host "Get-PhysicalDisk not available: $_"
}

Get-Volume |
    Where-Object { $_.DriveLetter } |
    Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus,
                  @{N="Free_GB";  E={[math]::Round($_.SizeRemaining/1GB,2)}},
                  @{N="Total_GB"; E={[math]::Round($_.Size/1GB,2)}} |
    Format-Table

Section "ACTIVE POWER SCHEME"
powercfg /getactivescheme

Section "PROCESSOR POWER SETTINGS"
powercfg /query SCHEME_CURRENT SUB_PROCESSOR

Section "POWER CAPABILITIES"
powercfg /a

Section "VBS / HYPERVISOR"
try {
    Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
                    -ClassName Win32_DeviceGuard -ErrorAction Stop |
        Select-Object SecurityServicesConfigured, SecurityServicesRunning,
                      VirtualizationBasedSecurityStatus,
                      RequiredSecurityProperties, AvailableSecurityProperties |
        Format-List
} catch {
    Write-Host "Win32_DeviceGuard not available: $_"
}

Write-Host "`nRegistry checks:"
try {
    Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -ErrorAction Stop |
        Select-Object EnableVirtualizationBasedSecurity, RequirePlatformSecurityFeatures |
        Format-List
} catch {
    Write-Host "DeviceGuard registry key not found."
}

try {
    Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -ErrorAction Stop |
        Select-Object RunAsPPL, RunAsPPLBoot, LsaCfgFlags |
        Format-List
} catch {
    Write-Host "LSA registry key not found."
}

Section "WINDOWS FEATURES"
try {
    Get-WindowsOptionalFeature -Online -ErrorAction Stop |
        Where-Object { $_.FeatureName -match "Hyper|VirtualMachinePlatform|Subsystem|Sandbox|Containers" } |
        Select-Object FeatureName, State |
        Format-Table
} catch {
    Write-Host "Could not query optional features (requires elevation): $_"
}

Section "NETWORK ADAPTERS"
Get-NetAdapter |
    Select-Object Name, Status, LinkSpeed, InterfaceDescription |
    Format-Table

Section "RUNNING PROCESSES (Top 25 by CPU)"
Get-Process |
    Sort-Object CPU -Descending |
    Select-Object -First 25 `
        ProcessName, Id, CPU,
        @{N="WorkingSet_MB"; E={[math]::Round($_.WorkingSet64/1MB,1)}},
        @{N="Paged_MB";      E={[math]::Round($_.PagedMemorySize64/1MB,1)}} |
    Format-Table

Section "RUNNING SERVICES (Top 40)"
Get-Service |
    Where-Object { $_.Status -eq "Running" } |
    Select-Object -First 40 Name, DisplayName, Status |
    Format-Table

Stop-Transcript | Out-Null
Write-Host "`nReport saved to: $LogFile" -ForegroundColor Green
