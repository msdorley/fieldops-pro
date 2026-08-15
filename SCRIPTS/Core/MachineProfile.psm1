#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - Machine Auto-Discovery Profile Engine
.DESCRIPTION
    Builds a comprehensive machine profile in under 10 seconds.
    Every FieldOps script references $Global:MachineProfile instead of
    re-querying WMI/CIM. Profile is built once at Launcher startup and
    available everywhere.

    Author: Ousman Dorley | EU Deployment | FieldOps Pro
#>

function Get-MachineProfile {
    <#
    .SYNOPSIS
        Discovers hardware, OS, network, security, and storage details.
        Returns a PSCustomObject stored as $Global:MachineProfile.
    #>

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # -- Identity ---------------------------------------------------------------
    $cs  = Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -EA SilentlyContinue
    $os  = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -EA SilentlyContinue | Select-Object -First 1
    $bat = Get-CimInstance Win32_Battery -EA SilentlyContinue | Select-Object -First 1

    # -- Azure AD / Intune status -----------------------------------------------
    $aadState = 'Unknown'
    $intuneState = 'Unknown'
    try {
        $dsreg = (dsregcmd /status 2>$null) -join "`n"
        if     ($dsreg -match 'AzureAdJoined\s*:\s*YES')   { $aadState = 'Azure AD Joined' }
        elseif ($dsreg -match 'DomainJoined\s*:\s*YES' -and $dsreg -match 'AzureAdJoined\s*:\s*YES') { $aadState = 'Hybrid Joined' }
        elseif ($dsreg -match 'WorkplaceJoined\s*:\s*YES')  { $aadState = 'Workplace Joined' }
        elseif ($dsreg -match 'DomainJoined\s*:\s*YES')     { $aadState = 'Domain Joined' }
        else                                                 { $aadState = 'Not Joined' }

        # Intune enrollment check
        $mdmUrl = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -EA SilentlyContinue |
                   Where-Object { $_.ProviderID -eq 'MS DM Server' }).DMPServerUrl
        if ($mdmUrl) { $intuneState = 'Enrolled' } else { $intuneState = 'Not Enrolled' }
    } catch {}

    # -- Network ----------------------------------------------------------------
    $adapters = @()
    try {
        Get-CimInstance Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
        Where-Object { $_.IPEnabled } | ForEach-Object {
            $adapters += [PSCustomObject]@{
                Name        = $_.Description
                IP          = ($_.IPAddress | Select-Object -First 1)
                Subnet      = ($_.IPSubnet | Select-Object -First 1)
                Gateway     = ($_.DefaultIPGateway | Select-Object -First 1)
                DNS         = ($_.DNSServerSearchOrder -join ', ')
                DHCP        = $_.DHCPEnabled
                MAC         = $_.MACAddress
            }
        }
    } catch {}

    $primaryIP = if ($adapters.Count -gt 0) { $adapters[0].IP } else { 'No IP' }

    # -- Storage ----------------------------------------------------------------
    $disks = @()
    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -EA SilentlyContinue | ForEach-Object {
            $totalGB = [math]::Round($_.Size / 1GB, 1)
            $freeGB  = [math]::Round($_.FreeSpace / 1GB, 1)
            $usedPct = if ($_.Size -gt 0) { [math]::Round((($_.Size - $_.FreeSpace) / $_.Size) * 100) } else { 0 }
            $disks += [PSCustomObject]@{
                Drive    = $_.DeviceID
                Label    = $_.VolumeName
                TotalGB  = $totalGB
                FreeGB   = $freeGB
                UsedPct  = $usedPct
                FileSystem = $_.FileSystem
            }
        }
    } catch {}

    # -- SMART quick check (requires CrystalDiskInfo or WMI) --------------------
    $smartStatus = @()
    try {
        Get-CimInstance -Namespace 'root\wmi' -Class MSStorageDriver_FailurePredictStatus -EA SilentlyContinue |
        ForEach-Object {
            $smartStatus += [PSCustomObject]@{
                InstanceName = $_.InstanceName
                PredictFailure = $_.PredictFailure
                Reason = $_.Reason
            }
        }
    } catch {}

    # -- RAM details ------------------------------------------------------------
    $ramModules = @()
    try {
        Get-CimInstance Win32_PhysicalMemory -EA SilentlyContinue | ForEach-Object {
            $ramModules += [PSCustomObject]@{
                Slot     = $_.DeviceLocator
                SizeGB   = [math]::Round($_.Capacity / 1GB, 1)
                Speed    = $_.Speed
                Type     = $_.MemoryType
                Manufacturer = $_.Manufacturer
            }
        }
    } catch {}

    $totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeRAM  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)

    # -- Security posture -------------------------------------------------------
    $defenderStatus = 'Unknown'
    $defenderDefs   = 'Unknown'
    try {
        $mpStatus = Get-MpComputerStatus -EA SilentlyContinue
        if ($mpStatus) {
            $defenderStatus = if ($mpStatus.RealTimeProtectionEnabled) { 'Active' } else { 'Disabled' }
            $defenderDefs   = $mpStatus.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd HH:mm')
        }
    } catch {}

    $firewallStatus = @()
    try {
        Get-NetFirewallProfile -EA SilentlyContinue | ForEach-Object {
            $firewallStatus += [PSCustomObject]@{
                Profile = $_.Name
                Enabled = $_.Enabled
            }
        }
    } catch {}

    # -- BitLocker --------------------------------------------------------------
    $bitlockerStatus = @()
    try {
        Get-BitLockerVolume -EA SilentlyContinue | ForEach-Object {
            $bitlockerStatus += [PSCustomObject]@{
                Drive      = $_.MountPoint
                Status     = $_.ProtectionStatus.ToString()
                Encryption = $_.EncryptionPercentage
                Method     = $_.EncryptionMethod.ToString()
            }
        }
    } catch {}

    # -- Battery health ---------------------------------------------------------
    $batteryHealth = $null
    if ($bat) {
        try {
            $designCap = (Get-CimInstance -Namespace 'root\wmi' -Class BatteryStaticData -EA SilentlyContinue).DesignedCapacity
            $fullCap   = (Get-CimInstance -Namespace 'root\wmi' -Class BatteryFullChargedCapacity -EA SilentlyContinue).FullChargedCapacity
            $healthPct = if ($designCap -and $designCap -gt 0) { [math]::Round(($fullCap / $designCap) * 100) } else { 0 }
            $cycleCount = (Get-CimInstance -Namespace 'root\wmi' -Class BatteryCycleCount -EA SilentlyContinue).CycleCount
            $batteryHealth = [PSCustomObject]@{
                CurrentCharge   = $bat.EstimatedChargeRemaining
                HealthPercent   = $healthPct
                CycleCount      = $cycleCount
                DesignCapacity   = $designCap
                FullChargeCapacity = $fullCap
                Status          = $bat.BatteryStatus
            }
        } catch {
            $batteryHealth = [PSCustomObject]@{
                CurrentCharge = $bat.EstimatedChargeRemaining
                HealthPercent = 0
                CycleCount    = 0
                Status        = $bat.BatteryStatus
            }
        }
    }

    # -- Uptime -----------------------------------------------------------------
    $lastBoot = $os.LastBootUpTime
    $uptime   = (Get-Date) - $lastBoot

    # -- Thermal ----------------------------------------------------------------
    $thermalZones = @()
    try {
        Get-CimInstance -Namespace 'root\wmi' -Class MSAcpi_ThermalZoneTemperature -EA SilentlyContinue |
        ForEach-Object {
            $celsius = [math]::Round(($_.CurrentTemperature / 10) - 273.15, 1)
            $thermalZones += [PSCustomObject]@{
                Zone    = $_.InstanceName
                TempC   = $celsius
                Warning = ($celsius -gt 80)
            }
        }
    } catch {}

    # -- Driver age audit -------------------------------------------------------
    $oldDrivers = @()
    try {
        Get-CimInstance Win32_PnPSignedDriver -EA SilentlyContinue |
        Where-Object { $_.DriverDate -and $_.DeviceName } |
        Sort-Object DriverDate |
        Select-Object -First 10 |
        ForEach-Object {
            $age = ((Get-Date) - $_.DriverDate).Days
            $oldDrivers += [PSCustomObject]@{
                Device    = $_.DeviceName.Substring(0, [Math]::Min(50, $_.DeviceName.Length))
                Version   = $_.DriverVersion
                Date      = $_.DriverDate.ToString('yyyy-MM-dd')
                AgeDays   = $age
                AgeYears  = [math]::Round($age / 365, 1)
            }
        }
    } catch {}

    # -- Windows Update recent failures -----------------------------------------
    $updateFailures = @()
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            $searcher.QueryHistory(0, [Math]::Min($count, 50)) | Where-Object { $_.ResultCode -eq 4 -or $_.ResultCode -eq 5 } |
            Select-Object -First 5 | ForEach-Object {
                $updateFailures += [PSCustomObject]@{
                    Title  = $_.Title
                    Date   = $_.Date.ToString('yyyy-MM-dd')
                    Result = switch ($_.ResultCode) { 4 { 'Failed' } 5 { 'Aborted' } default { $_.ResultCode } }
                }
            }
        }
    } catch {}

    # -- Installed software summary ---------------------------------------------
    $installedCount = 0
    try {
        $installedCount = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                           'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -EA SilentlyContinue |
                          Where-Object { $_.DisplayName }).Count
    } catch {}

    $stopwatch.Stop()

    # -- Assemble profile -------------------------------------------------------
    $profile = [PSCustomObject]@{
        # Identity
        Hostname        = $env:COMPUTERNAME
        Manufacturer    = $cs.Manufacturer
        Model           = $cs.Model
        SerialNumber    = $bios.SerialNumber
        BIOSVersion     = $bios.SMBIOSBIOSVersion

        # OS
        OSName          = ($os.Caption -replace 'Microsoft ','')
        OSVersion       = $os.Version
        OSBuild         = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue).DisplayVersion
        OSArchitecture  = $os.OSArchitecture
        InstallDate     = $os.InstallDate

        # CPU
        CPUName         = $cpu.Name -replace '\s+',' '
        CPUCores        = $cpu.NumberOfCores
        CPUThreads      = $cpu.NumberOfLogicalProcessors
        CPULoad         = $cpu.LoadPercentage

        # RAM
        TotalRAMGB      = $totalRAM
        FreeRAMGB       = $freeRAM
        UsedRAMPct      = [math]::Round((($totalRAM - $freeRAM) / $totalRAM) * 100)
        RAMModules      = $ramModules

        # Storage
        Disks           = $disks
        SMARTStatus     = $smartStatus
        BitLocker       = $bitlockerStatus

        # Network
        PrimaryIP       = $primaryIP
        Adapters        = $adapters

        # Security
        AADState        = $aadState
        IntuneState     = $intuneState
        DefenderStatus  = $defenderStatus
        DefenderDefs    = $defenderDefs
        Firewall        = $firewallStatus

        # Battery
        Battery         = $batteryHealth
        HasBattery      = ($null -ne $bat)

        # Thermal
        ThermalZones    = $thermalZones

        # Health indicators
        Uptime          = [PSCustomObject]@{
            Hours   = [int]$uptime.TotalHours
            Minutes = $uptime.Minutes
            LastBoot = $lastBoot.ToString('yyyy-MM-dd HH:mm')
        }
        OldestDrivers   = $oldDrivers
        UpdateFailures  = $updateFailures
        InstalledSoftwareCount = $installedCount

        # Meta
        ProfileDate     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        ScanDurationMs  = $stopwatch.ElapsedMilliseconds
    }

    return $profile
}

function Show-ProfileSummary {
    <#
    .SYNOPSIS
        Prints a one-line summary bar from the machine profile.
    #>
    param($Profile)
    if (-not $Profile) { return }

    $diskWarn = ($Profile.Disks | Where-Object { $_.UsedPct -gt 90 }).Count -gt 0
    $ramWarn  = $Profile.UsedRAMPct -gt 85
    $batWarn  = $Profile.HasBattery -and $Profile.Battery.HealthPercent -lt 50
    $smartWarn = ($Profile.SMARTStatus | Where-Object { $_.PredictFailure }).Count -gt 0

    $warnings = @()
    if ($diskWarn)  { $warnings += 'DISK' }
    if ($ramWarn)   { $warnings += 'RAM' }
    if ($batWarn)   { $warnings += 'BATTERY' }
    if ($smartWarn) { $warnings += 'SMART' }

    $warnStr = if ($warnings.Count -gt 0) { " [!] WARNINGS: $($warnings -join ', ')" } else { '' }

    Write-Host "  $($Profile.Manufacturer) $($Profile.Model) | SN: $($Profile.SerialNumber) | $($Profile.OSName) $($Profile.OSBuild) | $($Profile.CPUName)" -ForegroundColor DarkGray
    if ($warnStr) { Write-Host $warnStr -ForegroundColor Red }
}

Export-ModuleMember -Function Get-MachineProfile, Show-ProfileSummary
