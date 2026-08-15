#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - Hardware Diagnostic Suite (PCHealth) v1.1
.DESCRIPTION
    Comprehensive hardware health assessment that runs the moment you touch
    a machine. Checks CPU, RAM, disk health, battery, thermals, drivers,
    network, security posture, and Windows Update history.

    Outputs:
      - Live color-coded console results
      - Professional HTML Health Card (E:\REPORTS\)
      - JSON data file (E:\LOGS\)
      - Session integration (findings auto-recorded)

    This is not a tool launcher. This is a diagnostic engine.
    Author: Ousman Dorley | EU Deployment | FieldOps Pro
#>

# ==============================================================================
# PATH SETUP
# ==============================================================================
$_scriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
$_scriptsDir = Split-Path $_scriptDir -Parent
$_usbRoot    = Split-Path $_scriptsDir -Parent
$_coreDir    = Join-Path $_scriptsDir 'Core'
$_logRoot    = Join-Path $_usbRoot 'LOGS'
$_reportRoot = Join-Path $_usbRoot 'REPORTS'
$_configRoot = Join-Path $_usbRoot 'CONFIG'

# Ensure output directories exist
if (-not (Test-Path $_logRoot))    { New-Item $_logRoot    -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $_reportRoot)) { New-Item $_reportRoot -ItemType Directory -Force | Out-Null }

# ==============================================================================
# LOAD MODULES
# ==============================================================================
$_profileMod  = Join-Path $_coreDir 'MachineProfile.psm1'
$_sessionMod  = Join-Path $_coreDir 'SessionManager.psm1'
$_loggerMod   = Join-Path $_coreDir 'Logger.psm1'

if (Test-Path $_profileMod) { Import-Module $_profileMod -Force -DisableNameChecking -EA SilentlyContinue }
if (Test-Path $_sessionMod) { Import-Module $_sessionMod -Force -DisableNameChecking -EA SilentlyContinue }
if (Test-Path $_loggerMod)  { Import-Module $_loggerMod  -Force -DisableNameChecking -EA SilentlyContinue }

# Load technician config
$_tech = $null
$_techFile = Join-Path $_configRoot 'technician.json'
if (Test-Path $_techFile) {
    try { $_tech = Get-Content $_techFile -Raw | ConvertFrom-Json } catch {}
}

# ==============================================================================
# COLOR HELPERS
# ==============================================================================
function c  ($text, $fg = 'White', $bg = 'Black') { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg -NoNewline }
function cn ($text, $fg = 'White', $bg = 'Black') { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg }
function nl { Write-Host '' }
function sep { cn ('  ' + ('-' * 76)) DarkGray }

function Status {
    param([string]$Label, [string]$Value, [string]$Color = 'White', [string]$Badge = '')
    $badgeStr = switch ($Badge) {
        'PASS'     { '[PASS]    ' }
        'WARN'     { '[WARNING] ' }
        'FAIL'     { '[CRITICAL]' }
        'INFO'     { '[INFO]    ' }
        default    { '          ' }
    }
    $bc = switch ($Badge) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'INFO' { 'Cyan' }
        default { 'DarkGray' }
    }
    c "  $badgeStr " $bc
    c ("{0,-24}" -f $Label) DarkGray
    cn $Value $Color
}

# ==============================================================================
# FINDINGS COLLECTOR
# ==============================================================================
$script:findings = @()
$script:checks   = @()

function Add-Check {
    param([string]$Category, [string]$Item, [string]$Status, [string]$Detail, [string]$Recommendation = '')
    $script:checks += [PSCustomObject]@{
        Category       = $Category
        Item           = $Item
        Status         = $Status    # Pass, Warning, Critical, Info
        Detail         = $Detail
        Recommendation = $Recommendation
    }
    if ($Status -eq 'Warning' -or $Status -eq 'Critical') {
        $script:findings += [PSCustomObject]@{
            Severity = $Status
            Component = $Category
            Finding = "$Item -- $Detail"
            Recommendation = $Recommendation
        }
        # Record in session if available
        try {
            if (Get-Command Add-SessionFinding -EA SilentlyContinue) {
                Add-SessionFinding -Severity $Status -Component $Category -Finding "$Item -- $Detail" -Recommendation $Recommendation
            }
        } catch {}
    }
}

# ==============================================================================
# MAIN DIAGNOSTIC ENGINE
# ==============================================================================
function Invoke-PCHealth {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $hostname  = $env:COMPUTERNAME

    Clear-Host; nl
    cn '  +============================================================================+' Cyan
    cn '  |                                                                            |' Cyan
    cn '  |     FIELDOPS PRO -- HARDWARE DIAGNOSTIC SUITE (PCHealth) v1.1              |' Cyan
    cn '  |                                                                            |' Cyan
    cn '  +============================================================================+' Cyan
    nl
    if ($_tech) {
        c '  Technician: ' DarkGray; cn "$($_tech.Name) | $($_tech.Region) | $($_tech.EmployeeID)" White
    }
    c '  Target:     ' DarkGray; cn "$hostname | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" Yellow
    nl; sep; nl

    # Record session start
    try {
        if (Get-Command Add-SessionScript -EA SilentlyContinue) {
            Add-SessionAction -Category 'Diagnostic' -Action 'Started PCHealth diagnostic' -Result 'Running'
        }
    } catch {}

    # ------------------------------------------------------------------
    # SECTION 1: SYSTEM IDENTITY
    # ------------------------------------------------------------------
    cn '  [1/9] SYSTEM IDENTITY' Cyan; nl

    $cs   = Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -EA SilentlyContinue
    $os   = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue

    Status 'Manufacturer' $cs.Manufacturer 'White' 'INFO'
    Status 'Model' $cs.Model 'White' 'INFO'
    Status 'Serial Number' $bios.SerialNumber 'Yellow' 'INFO'
    Status 'BIOS Version' $bios.SMBIOSBIOSVersion 'White' 'INFO'
    Status 'OS' "$($os.Caption -replace 'Microsoft ','') ($(($os).Version))" 'White' 'INFO'

    $osBuild = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue).DisplayVersion
    Status 'OS Build' $osBuild 'White' 'INFO'

    Add-Check 'Identity' 'System Identified' 'Pass' "$($cs.Manufacturer) $($cs.Model) | SN: $($bios.SerialNumber)"

    nl; sep; nl

    # ------------------------------------------------------------------
    # SECTION 2: CPU
    # ------------------------------------------------------------------
    cn '  [2/9] CPU HEALTH' Cyan; nl

    $cpu = Get-CimInstance Win32_Processor -EA SilentlyContinue | Select-Object -First 1
    Status 'Processor' ($cpu.Name -replace '\s+',' ') 'Cyan' 'INFO'
    Status 'Cores / Threads' "$($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T" 'White' 'INFO'

    $load = $cpu.LoadPercentage
    $loadBadge = if ($load -gt 90) { 'FAIL' } elseif ($load -gt 70) { 'WARN' } else { 'PASS' }
    $loadColor = if ($load -gt 90) { 'Red' } elseif ($load -gt 70) { 'Yellow' } else { 'Green' }
    Status 'CPU Load' "$load%" $loadColor $loadBadge

    if ($load -gt 90) {
        Add-Check 'CPU' 'CPU Load' 'Critical' "Load at $load% -- system under heavy stress" 'Check running processes, consider reboot'
    } elseif ($load -gt 70) {
        Add-Check 'CPU' 'CPU Load' 'Warning' "Load at $load% -- elevated" 'Monitor for sustained high usage'
    } else {
        Add-Check 'CPU' 'CPU Load' 'Pass' "Load at $load% -- normal"
    }

    # Thermal check
    $thermalWarn = $false
    try {
        Get-CimInstance -Namespace 'root\wmi' -Class MSAcpi_ThermalZoneTemperature -EA SilentlyContinue |
        ForEach-Object {
            $celsius = [math]::Round(($_.CurrentTemperature / 10) - 273.15, 1)
            $tBadge = if ($celsius -gt 85) { 'FAIL' } elseif ($celsius -gt 70) { 'WARN' } else { 'PASS' }
            $tColor = if ($celsius -gt 85) { 'Red' } elseif ($celsius -gt 70) { 'Yellow' } else { 'Green' }
            Status 'Temperature' "${celsius}C" $tColor $tBadge
            if ($celsius -gt 85) {
                Add-Check 'CPU' 'Temperature' 'Critical' "${celsius}C -- thermal throttling likely" 'Clean fans, check thermal paste, improve ventilation'
                $thermalWarn = $true
            } elseif ($celsius -gt 70) {
                Add-Check 'CPU' 'Temperature' 'Warning' "${celsius}C -- running hot" 'Monitor airflow and fan operation'
                $thermalWarn = $true
            }
        }
    } catch {}
    if (-not $thermalWarn) {
        Add-Check 'CPU' 'Temperature' 'Pass' 'Within normal range'
    }

    nl; sep; nl

    # ------------------------------------------------------------------
    # SECTION 3: MEMORY
    # ------------------------------------------------------------------
    cn '  [3/9] MEMORY' Cyan; nl

    $totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeRAM  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $usedRAM  = [math]::Round($totalRAM - $freeRAM, 1)
    $ramPct   = [math]::Round(($usedRAM / $totalRAM) * 100)

    $ramBadge = if ($ramPct -gt 90) { 'FAIL' } elseif ($ramPct -gt 75) { 'WARN' } else { 'PASS' }
    $ramColor = if ($ramPct -gt 90) { 'Red' } elseif ($ramPct -gt 75) { 'Yellow' } else { 'Green' }
    Status 'Total RAM' "${totalRAM} GB" 'White' 'INFO'
    Status 'Usage' "${usedRAM}GB / ${totalRAM}GB ($ramPct%)" $ramColor $ramBadge

    if ($ramPct -gt 90) {
        Add-Check 'Memory' 'RAM Usage' 'Critical' "$ramPct% used -- system may be swapping" 'Close unnecessary apps or upgrade RAM'
    } elseif ($ramPct -gt 75) {
        Add-Check 'Memory' 'RAM Usage' 'Warning' "$ramPct% used -- elevated" 'Monitor for memory pressure'
    } else {
        Add-Check 'Memory' 'RAM Usage' 'Pass' "$ramPct% used -- healthy"
    }

    # RAM module details
    try {
        Get-CimInstance Win32_PhysicalMemory -EA SilentlyContinue | ForEach-Object {
            $sizeGB = [math]::Round($_.Capacity / 1GB, 1)
            Status "  $($_.DeviceLocator)" "${sizeGB}GB @ $($_.Speed)MHz ($($_.Manufacturer))" 'DarkGray' 'INFO'
        }
    } catch {}

    nl; sep; nl

    # ------------------------------------------------------------------
    # SECTION 4: STORAGE
    # ------------------------------------------------------------------
    cn '  [4/9] STORAGE & DISK HEALTH' Cyan; nl

    # Logical drives
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -EA SilentlyContinue | ForEach-Object {
        $totalGB = [math]::Round($_.Size / 1GB, 1)
        $freeGB  = [math]::Round($_.FreeSpace / 1GB, 1)
        $usedPct = if ($_.Size -gt 0) { [math]::Round((($_.Size - $_.FreeSpace) / $_.Size) * 100) } else { 0 }

        $dBadge = if ($usedPct -gt 95) { 'FAIL' } elseif ($usedPct -gt 85) { 'WARN' } else { 'PASS' }
        $dColor = if ($usedPct -gt 95) { 'Red' } elseif ($usedPct -gt 85) { 'Yellow' } else { 'Green' }

        $bar   = '#' * [math]::Round($usedPct / 5)
        $empty = '-' * (20 - [math]::Round($usedPct / 5))
        Status "$($_.DeviceID)\" "[$bar$empty] ${freeGB}GB free / ${totalGB}GB ($usedPct%)" $dColor $dBadge

        if ($usedPct -gt 95) {
            Add-Check 'Storage' "$($_.DeviceID) Space" 'Critical' "$usedPct% full -- only ${freeGB}GB free" 'Run Disk Cleanup, delete temp files, move data'
        } elseif ($usedPct -gt 85) {
            Add-Check 'Storage' "$($_.DeviceID) Space" 'Warning' "$usedPct% full" 'Consider cleanup or archiving'
        } else {
            Add-Check 'Storage' "$($_.DeviceID) Space" 'Pass' "${freeGB}GB free ($usedPct% used)"
        }
    }

    # SMART status
    nl; cn '  SMART Predictive Failure:' DarkGray
    $smartFail = $false
    try {
        Get-CimInstance -Namespace 'root\wmi' -Class MSStorageDriver_FailurePredictStatus -EA SilentlyContinue |
        ForEach-Object {
            $name = $_.InstanceName.Split('\')[-1]
            if ($_.PredictFailure) {
                Status "  $name" 'FAILURE PREDICTED' 'Red' 'FAIL'
                Add-Check 'Storage' "SMART $name" 'Critical' 'Drive is predicting imminent failure' 'REPLACE THIS DRIVE IMMEDIATELY. Backup all data now.'
                $smartFail = $true
            } else {
                Status "  $name" 'Healthy' 'Green' 'PASS'
            }
        }
    } catch { cn '    (SMART data not available via WMI)' DarkGray }
    if (-not $smartFail) {
        Add-Check 'Storage' 'SMART Status' 'Pass' 'No drives predicting failure'
    }

    # BitLocker
    nl; cn '  BitLocker Encryption:' DarkGray
    try {
        Get-BitLockerVolume -EA SilentlyContinue | ForEach-Object {
            $blStatus = $_.ProtectionStatus.ToString()
            $blBadge  = if ($blStatus -eq 'On') { 'PASS' } else { 'WARN' }
            $blColor  = if ($blStatus -eq 'On') { 'Green' } else { 'Yellow' }
            Status "  $($_.MountPoint)" "Protection: $blStatus | $($_.EncryptionPercentage)% encrypted" $blColor $blBadge

            if ($blStatus -ne 'On') {
                Add-Check 'Storage' "BitLocker $($_.MountPoint)" 'Warning' "Not encrypted" 'Enable BitLocker for data protection compliance'
            } else {
                Add-Check 'Storage' "BitLocker $($_.MountPoint)" 'Pass' 'Encrypted and protected'
            }
        }
    } catch { cn '    (BitLocker not available or not admin)' DarkGray }

    nl; sep; nl

    # ------------------------------------------------------------------
    # SECTION 5: BATTERY
    # ------------------------------------------------------------------
    cn '  [5/9] BATTERY HEALTH' Cyan; nl

    $bat = Get-CimInstance Win32_Battery -EA SilentlyContinue | Select-Object -First 1
    if ($bat) {
        Status 'Current Charge' "$($bat.EstimatedChargeRemaining)%" 'White' 'INFO'

        try {
            $designCap = (Get-CimInstance -Namespace 'root\wmi' -Class BatteryStaticData -EA SilentlyContinue).DesignedCapacity
            $fullCap   = (Get-CimInstance -Namespace 'root\wmi' -Class BatteryFullChargedCapacity -EA SilentlyContinue).FullChargedCapacity
            $cycleCount = (Get-CimInstance -Namespace 'root\wmi' -Class BatteryCycleCount -EA SilentlyContinue).CycleCount

            if ($designCap -and $designCap -gt 0) {
                # Normal path: design capacity available
                $healthPct = [math]::Round(($fullCap / $designCap) * 100)
                $hBadge = if ($healthPct -lt 40) { 'FAIL' } elseif ($healthPct -lt 65) { 'WARN' } else { 'PASS' }
                $hColor = if ($healthPct -lt 40) { 'Red' } elseif ($healthPct -lt 65) { 'Yellow' } else { 'Green' }
                Status 'Battery Health' "$healthPct% of design capacity" $hColor $hBadge
                Status 'Cycle Count' "$cycleCount cycles" 'White' 'INFO'
                Status 'Design Capacity' "${designCap} mWh" 'DarkGray' 'INFO'
            } else {
                # Fallback: DesignedCapacity is null (known issue on some Acer/OEM hardware)
                $healthPct = -1
                $fullCapStr = if ($fullCap -and $fullCap -gt 0) { "${fullCap} mWh" } else { 'Unknown' }
                Status 'Battery Health' "Design capacity unavailable (full charge: $fullCapStr)" 'Yellow' 'INFO'
                Status 'Cycle Count' "$cycleCount cycles" 'White' 'INFO'
                Status 'Design Capacity' 'Unavailable (WMI returned null)' 'DarkGray' 'INFO'
            }
            Status 'Full Charge Now' "${fullCap} mWh" 'DarkGray' 'INFO'

            if ($healthPct -eq -1) {
                # Design capacity unavailable -- report info, not failure
                Add-Check 'Battery' 'Battery Health' 'Info' "Design capacity unavailable, full charge $fullCapStr ($cycleCount cycles)" 'WMI DesignedCapacity null on this hardware'
            } elseif ($healthPct -lt 40) {
                Add-Check 'Battery' 'Battery Health' 'Critical' "Only $healthPct% capacity remaining ($cycleCount cycles)" 'Battery needs replacement'
            } elseif ($healthPct -lt 65) {
                Add-Check 'Battery' 'Battery Health' 'Warning' "$healthPct% capacity ($cycleCount cycles)" 'Battery degrading -- plan replacement'
            } else {
                Add-Check 'Battery' 'Battery Health' 'Pass' "$healthPct% capacity ($cycleCount cycles)"
            }
        } catch {
            cn '    (Detailed battery data not available)' DarkGray
            Add-Check 'Battery' 'Battery Health' 'Info' 'Detailed WMI battery data unavailable'
        }
    } else {
        Status 'Battery' 'Desktop / No battery detected' 'DarkGray' 'INFO'
        Add-Check 'Battery' 'Battery' 'Pass' 'No battery (desktop or docked)'
    }

    nl; sep; nl

    # ------------------------------------------------------------------
    # SECTION 6: NETWORK
    # ------------------------------------------------------------------
    cn '  [6/9] NETWORK' Cyan; nl

    Get-CimInstance Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
    Where-Object { $_.IPEnabled } | ForEach-Object {
        $descShort = $_.Description.Substring(0, [Math]::Min(45, $_.Description.Length))
        Status $descShort ($_.IPAddress -join ', ') 'Cyan' 'INFO'
        if ($_.DHCPEnabled) {
            Status '  DHCP Server' $_.DHCPServer 'DarkGray' 'INFO'
        }
        Status '  Gateway' ($_.DefaultIPGateway -join ', ') 'DarkGray' 'INFO'
        Status '  DNS' ($_.DNSServerSearchOrder -join ', ') 'DarkGray' 'INFO'

        # APIPA check
        $ip = $_.IPAddress | Select-Object -First 1
        if ($ip -and $ip.StartsWith('169.254')) {
            Add-Check 'Network' $descShort 'Critical' "APIPA address ($ip) -- DHCP failure" 'Check network cable, DHCP server, or configure static IP'
        } else {
            Add-Check 'Network' $descShort 'Pass' "IP: $ip"
        }
    }

    # Quick connectivity test
    nl; cn '  Connectivity:' DarkGray
    $targets = @(
        @{ Name = 'Default Gateway'; Test = { $gw = (Get-CimInstance Win32_NetworkAdapterConfiguration -EA SilentlyContinue | Where-Object { $_.DefaultIPGateway }).DefaultIPGateway | Select-Object -First 1; if ($gw) { Test-Connection $gw -Count 1 -Quiet -EA SilentlyContinue } else { $false } } },
        @{ Name = 'DNS (Google)';     Test = { Test-Connection '8.8.8.8' -Count 1 -Quiet -EA SilentlyContinue } },
        @{ Name = 'Internet (MS)';    Test = { Test-Connection 'www.microsoft.com' -Count 1 -Quiet -EA SilentlyContinue } }
    )
    foreach ($t in $targets) {
        $result = try { & $t.Test } catch { $false }
        $badge = if ($result) { 'PASS' } else { 'FAIL' }
        $color = if ($result) { 'Green' } else { 'Red' }
        Status "  $($t.Name)" $(if ($result) { 'Reachable' } else { 'UNREACHABLE' }) $color $badge
        if (-not $result) {
            Add-Check 'Network' $t.Name 'Warning' 'Connectivity test failed' 'Check network configuration'
        }
    }

    nl; sep; nl

    # ------------------------------------------------------------------
    # SECTION 7: SECURITY POSTURE
    # ------------------------------------------------------------------
    cn '  [7/9] SECURITY POSTURE' Cyan; nl

    # Azure AD / Domain
    $aadState = 'Unknown'
    try {
        $dsreg = (dsregcmd /status 2>$null) -join ' '
        if     ($dsreg -match 'AzureAdJoined\s*:\s*YES')   { $aadState = 'Azure AD Joined' }
        elseif ($dsreg -match 'WorkplaceJoined\s*:\s*YES')  { $aadState = 'Workplace Joined' }
        elseif ($dsreg -match 'DomainJoined\s*:\s*YES')     { $aadState = 'Domain Joined' }
        else { $aadState = 'Not Joined' }
    } catch {}
    $aadColor = if ($aadState -match 'Joined') { 'Green' } else { 'Yellow' }
    Status 'Directory Status' $aadState $aadColor 'INFO'

    # Defender
    try {
        $mpStatus = Get-MpComputerStatus -EA SilentlyContinue
        if ($mpStatus) {
            $rtpBadge = if ($mpStatus.RealTimeProtectionEnabled) { 'PASS' } else { 'FAIL' }
            $rtpColor = if ($mpStatus.RealTimeProtectionEnabled) { 'Green' } else { 'Red' }
            Status 'Defender Realtime' $(if ($mpStatus.RealTimeProtectionEnabled) { 'Active' } else { 'DISABLED' }) $rtpColor $rtpBadge

            $defsAge = ((Get-Date) - $mpStatus.AntivirusSignatureLastUpdated).Days
            $defsBadge = if ($defsAge -gt 7) { 'FAIL' } elseif ($defsAge -gt 3) { 'WARN' } else { 'PASS' }
            $defsColor = if ($defsAge -gt 7) { 'Red' } elseif ($defsAge -gt 3) { 'Yellow' } else { 'Green' }
            Status 'Definitions Age' "$defsAge days old ($($mpStatus.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd')))" $defsColor $defsBadge

            if (-not $mpStatus.RealTimeProtectionEnabled) {
                Add-Check 'Security' 'Defender RTP' 'Critical' 'Real-time protection is DISABLED' 'Enable Windows Defender immediately'
            } else {
                Add-Check 'Security' 'Defender RTP' 'Pass' 'Active'
            }
            if ($defsAge -gt 7) {
                Add-Check 'Security' 'Defender Definitions' 'Critical' "$defsAge days out of date" 'Run Windows Update or manual definition update'
            } elseif ($defsAge -gt 3) {
                Add-Check 'Security' 'Defender Definitions' 'Warning' "$defsAge days old" 'Update definitions soon'
            } else {
                Add-Check 'Security' 'Defender Definitions' 'Pass' "Updated $defsAge days ago"
            }
        }
    } catch { cn '    (Defender status unavailable)' DarkGray }

    # Firewall
    try {
        Get-NetFirewallProfile -EA SilentlyContinue | ForEach-Object {
            $fwBadge = if ($_.Enabled) { 'PASS' } else { 'FAIL' }
            $fwColor = if ($_.Enabled) { 'Green' } else { 'Red' }
            Status "  Firewall ($($_.Name))" $(if ($_.Enabled) { 'Enabled' } else { 'DISABLED' }) $fwColor $fwBadge
            if (-not $_.Enabled) {
                Add-Check 'Security' "Firewall $($_.Name)" 'Critical' 'Firewall profile is DISABLED' 'Enable firewall immediately'
            }
        }
    } catch {}

    # Local admin accounts
    try {
        $admins = (Get-LocalGroupMember -Group 'Administrators' -EA SilentlyContinue).Name
        $adminCount = $admins.Count
        $adminBadge = if ($adminCount -gt 5) { 'WARN' } else { 'PASS' }
        Status 'Local Admins' "$adminCount accounts" $(if ($adminCount -gt 5) { 'Yellow' } else { 'Green' }) $adminBadge
        if ($adminCount -gt 5) {
            Add-Check 'Security' 'Local Admins' 'Warning' "$adminCount admin accounts -- excessive" 'Review and remove unnecessary admin accounts'
        } else {
            Add-Check 'Security' 'Local Admins' 'Pass' "$adminCount accounts"
        }
    } catch {}

    nl; sep; nl

    # ------------------------------------------------------------------
    # SECTION 8: DRIVERS & UPDATES
    # ------------------------------------------------------------------
    cn '  [8/9] DRIVERS & WINDOWS UPDATE' Cyan; nl

    # Oldest drivers
    cn '  Oldest 5 drivers:' DarkGray
    try {
        Get-CimInstance Win32_PnPSignedDriver -EA SilentlyContinue |
        Where-Object { $_.DriverDate -and $_.DeviceName -and $_.DriverDate -gt [datetime]'2000-01-01' } |
        Sort-Object DriverDate |
        Select-Object -First 5 |
        ForEach-Object {
            $ageYears = [math]::Round(((Get-Date) - $_.DriverDate).Days / 365, 1)
            $drvBadge = if ($ageYears -gt 4) { 'WARN' } else { 'PASS' }
            $drvColor = if ($ageYears -gt 4) { 'Yellow' } else { 'DarkGray' }
            $shortName = $_.DeviceName.Substring(0, [Math]::Min(40, $_.DeviceName.Length))
            Status "  $shortName" "$($_.DriverDate.ToString('yyyy-MM-dd')) (${ageYears}y old)" $drvColor $drvBadge
            if ($ageYears -gt 4) {
                Add-Check 'Drivers' $shortName 'Warning' "${ageYears} years old" 'Consider updating this driver'
            }
        }
    } catch {}

    # Recent Windows Update failures
    nl; cn '  Recent Update Failures:' DarkGray
    $updateFails = @()
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            $searcher.QueryHistory(0, [Math]::Min($count, 50)) |
            Where-Object { $_.ResultCode -eq 4 -or $_.ResultCode -eq 5 } |
            Select-Object -First 5 | ForEach-Object {
                $updateFails += $_
                Status "  $($_.Date.ToString('yyyy-MM-dd'))" $_.Title 'Red' 'FAIL'
                Add-Check 'Updates' $_.Title 'Warning' "Failed on $($_.Date.ToString('yyyy-MM-dd'))" 'Retry via Windows Update or WSUS'
            }
        }
    } catch {}
    if ($updateFails.Count -eq 0) {
        cn '    No recent failures.' Green
        Add-Check 'Updates' 'Windows Update' 'Pass' 'No recent failures detected'
    }

    nl; sep; nl

    # ------------------------------------------------------------------
    # SECTION 9: UPTIME & PROCESSES
    # ------------------------------------------------------------------
    cn '  [9/9] UPTIME & TOP PROCESSES' Cyan; nl

    $lastBoot = $os.LastBootUpTime
    $uptime   = (Get-Date) - $lastBoot
    $uptimeDays = [int]$uptime.TotalDays
    $uptimeBadge = if ($uptimeDays -gt 14) { 'WARN' } elseif ($uptimeDays -gt 30) { 'FAIL' } else { 'PASS' }
    Status 'Uptime' "$([int]$uptime.TotalHours)h $($uptime.Minutes)m ($uptimeDays days)" $(if ($uptimeDays -gt 14) { 'Yellow' } else { 'Green' }) $uptimeBadge
    Status 'Last Boot' $lastBoot.ToString('yyyy-MM-dd HH:mm') 'DarkGray' 'INFO'

    if ($uptimeDays -gt 14) {
        Add-Check 'System' 'Uptime' 'Warning' "$uptimeDays days since last reboot" 'Recommend restarting to apply pending updates'
    } else {
        Add-Check 'System' 'Uptime' 'Pass' "$uptimeDays days"
    }

    nl; cn '  Top 5 CPU consumers:' DarkGray
    try {
        Get-Process -EA SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 5 |
        ForEach-Object {
            $cpuSec = [math]::Round($_.CPU, 1)
            $memMB  = [math]::Round($_.WorkingSet / 1MB, 1)
            c "    $($_.Name.PadRight(28))" White
            c "CPU: $($cpuSec.ToString().PadLeft(8))s  " DarkGray
            cn "RAM: $memMB MB" DarkGray
        }
    } catch {}

    # ==================================================================
    # RESULTS SUMMARY
    # ==================================================================
    $sw.Stop()

    $critCount = ($script:checks | Where-Object { $_.Status -eq 'Critical' }).Count
    $warnCount = ($script:checks | Where-Object { $_.Status -eq 'Warning' }).Count
    $passCount = ($script:checks | Where-Object { $_.Status -eq 'Pass' }).Count
    $totalChecks = $script:checks.Count

    nl; nl
    cn '  +============================================================================+' Cyan
    cn '  |                         DIAGNOSTIC SUMMARY                                 |' Cyan
    cn '  +============================================================================+' Cyan
    nl

    $overallGrade = if ($critCount -gt 0) { 'CRITICAL' } elseif ($warnCount -gt 0) { 'WARNING' } else { 'HEALTHY' }
    $gradeColor   = if ($critCount -gt 0) { 'Red' } elseif ($warnCount -gt 0) { 'Yellow' } else { 'Green' }

    c  '  Overall Status:  ' DarkGray; cn $overallGrade $gradeColor
    c  '  Checks Run:      ' DarkGray; cn "$totalChecks" White
    c  '  ' DarkGray; c "PASS: $passCount  " Green; c "WARNING: $warnCount  " Yellow; cn "CRITICAL: $critCount" Red
    c  '  Duration:        ' DarkGray; cn "$([math]::Round($sw.Elapsed.TotalSeconds, 1)) seconds" DarkGray
    nl

    if ($script:findings.Count -gt 0) {
        cn '  Issues Found:' Yellow
        foreach ($f in $script:findings) {
            $fc = if ($f.Severity -eq 'Critical') { 'Red' } else { 'Yellow' }
            cn "    [$($f.Severity)] $($f.Component) -- $($f.Finding)" $fc
            if ($f.Recommendation) { cn "      -> $($f.Recommendation)" DarkGray }
        }
    }

    nl; sep; nl

    # ==================================================================
    # GENERATE HTML REPORT
    # ==================================================================
    cn '  Generating HTML Health Card...' Yellow

    $htmlFile = Join-Path $_reportRoot "PCHealth_${hostname}_${timestamp}.html"
    $jsonFile = Join-Path $_logRoot "PCHealth_${hostname}_${timestamp}.json"

    # Save JSON data
    $reportData = [PSCustomObject]@{
        Hostname   = $hostname
        Timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Technician = if ($_tech) { $_tech.Name } else { $env:USERNAME }
        Grade      = $overallGrade
        Duration   = "$([math]::Round($sw.Elapsed.TotalSeconds, 1))s"
        Summary    = @{ Total = $totalChecks; Pass = $passCount; Warning = $warnCount; Critical = $critCount }
        Checks     = $script:checks
        Findings   = $script:findings
    }
    $reportData | ConvertTo-Json -Depth 10 | Set-Content $jsonFile -Encoding UTF8 -Force

    # Build HTML
    $techName = if ($_tech) { $_tech.Name } else { $env:USERNAME }
    $techRegion = if ($_tech) { $_tech.Region } else { '' }
    $brandColor = if ($_tech -and $_tech.BrandColor) { $_tech.BrandColor } else { '#6C3FC5' }

    $checksHtml = ''
    foreach ($check in $script:checks) {
        $rowClass = switch ($check.Status) {
            'Critical' { 'critical' }
            'Warning'  { 'warning' }
            'Pass'     { 'pass' }
            default    { 'info' }
        }
        $statusIcon = switch ($check.Status) {
            'Critical' { '&#10060;' }
            'Warning'  { '&#9888;' }
            'Pass'     { '&#9989;' }
            default    { '&#8505;' }
        }
        $recHtml = if ($check.Recommendation) { "<br><small>$($check.Recommendation)</small>" } else { '' }
        $checksHtml += "
        <tr class=`"$rowClass`">
            <td>$statusIcon $($check.Status)</td>
            <td>$($check.Category)</td>
            <td>$($check.Item)</td>
            <td>$($check.Detail)$recHtml</td>
        </tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PCHealth Report - $hostname</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; background: #0a0a0f; color: #e0e0e0; }
  .header { background: linear-gradient(135deg, $brandColor 0%, #1a1a2e 100%); padding: 40px; color: white; }
  .header h1 { font-size: 28px; font-weight: 300; letter-spacing: 2px; }
  .header .subtitle { font-size: 14px; opacity: 0.8; margin-top: 8px; }
  .header .meta { display: flex; gap: 40px; margin-top: 20px; font-size: 13px; }
  .header .meta span { opacity: 0.9; }
  .grade-bar { display: flex; align-items: center; gap: 20px; padding: 24px 40px; background: #12121a; border-bottom: 1px solid #222; }
  .grade { font-size: 36px; font-weight: 700; letter-spacing: 3px; }
  .grade.healthy { color: #4ade80; }
  .grade.warning { color: #facc15; }
  .grade.critical { color: #f87171; }
  .stats { display: flex; gap: 24px; }
  .stat { text-align: center; }
  .stat .num { font-size: 24px; font-weight: 600; }
  .stat .label { font-size: 11px; text-transform: uppercase; opacity: 0.5; }
  .stat.pass .num { color: #4ade80; }
  .stat.warn .num { color: #facc15; }
  .stat.crit .num { color: #f87171; }
  .content { padding: 30px 40px; }
  table { width: 100%; border-collapse: collapse; margin-top: 12px; }
  th { text-align: left; padding: 10px 12px; font-size: 11px; text-transform: uppercase; letter-spacing: 1px; color: #888; border-bottom: 1px solid #333; }
  td { padding: 10px 12px; border-bottom: 1px solid #1a1a2e; font-size: 13px; }
  tr.critical td { border-left: 3px solid #f87171; }
  tr.warning td { border-left: 3px solid #facc15; }
  tr.pass td { border-left: 3px solid #4ade80; }
  tr.info td { border-left: 3px solid #38bdf8; }
  tr:hover { background: #16162a; }
  small { color: #888; }
  .footer { padding: 20px 40px; border-top: 1px solid #222; font-size: 11px; color: #555; }
  .findings { background: #1a1018; border: 1px solid #3a2020; border-radius: 8px; padding: 20px; margin-bottom: 24px; }
  .findings h3 { color: #f87171; margin-bottom: 12px; }
  .finding { padding: 8px 0; border-bottom: 1px solid #2a1a1a; font-size: 13px; }
  .finding:last-child { border-bottom: none; }
  .finding .sev { font-weight: 600; }
  .finding .rec { color: #888; font-size: 12px; margin-top: 4px; }
  @media print { body { background: white; color: black; } .header { background: $brandColor; } td, th { border-color: #ccc; } }
</style>
</head>
<body>

<div class="header">
  <h1>FIELDOPS PRO -- PC HEALTH REPORT</h1>
  <div class="subtitle">Hardware Diagnostic Suite v1.0</div>
  <div class="meta">
    <span><strong>Machine:</strong> $hostname</span>
    <span><strong>Serial:</strong> $($bios.SerialNumber)</span>
    <span><strong>Technician:</strong> $techName</span>
    <span><strong>Date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm')</span>
    <span><strong>Region:</strong> $techRegion</span>
  </div>
</div>

<div class="grade-bar">
  <div class="grade $($overallGrade.ToLower())">$overallGrade</div>
  <div class="stats">
    <div class="stat pass"><div class="num">$passCount</div><div class="label">Pass</div></div>
    <div class="stat warn"><div class="num">$warnCount</div><div class="label">Warnings</div></div>
    <div class="stat crit"><div class="num">$critCount</div><div class="label">Critical</div></div>
    <div class="stat"><div class="num">$totalChecks</div><div class="label">Total Checks</div></div>
  </div>
</div>

<div class="content">
$(if ($script:findings.Count -gt 0) {
@"
  <div class="findings">
    <h3>&#9888; Issues Requiring Attention</h3>
    $(foreach ($f in $script:findings) {
        "<div class='finding'><span class='sev'>[$($f.Severity)]</span> <strong>$($f.Component)</strong> -- $($f.Finding)$(if ($f.Recommendation) { "<div class='rec'>Recommendation: $($f.Recommendation)</div>" })</div>"
    })
  </div>
"@
})

  <table>
    <thead>
      <tr><th>Status</th><th>Category</th><th>Check</th><th>Detail</th></tr>
    </thead>
    <tbody>
      $checksHtml
    </tbody>
  </table>
</div>

<div class="footer">
  Generated by FieldOps Pro v2.0 | $techName | $techRegion | Duration: $([math]::Round($sw.Elapsed.TotalSeconds, 1))s | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
</div>

</body>
</html>
"@

    $html | Set-Content $htmlFile -Encoding UTF8 -Force
    cn "  [OK] HTML report: $htmlFile" Green
    cn "  [OK] JSON data:   $jsonFile" Green

    # Record in session
    try {
        if (Get-Command Add-SessionScript -EA SilentlyContinue) {
            Add-SessionScript -ScriptName 'Invoke-PCHealth' -Duration "$([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -Result $overallGrade
            Add-SessionAction -Category 'Diagnostic' -Action 'PCHealth complete' -Result $overallGrade -Detail "$totalChecks checks: $passCount pass, $warnCount warn, $critCount critical"
        }
    } catch {}

    nl
    cn '  Open the HTML report in your browser for a printable version.' DarkGray
    nl
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================
Invoke-PCHealth
