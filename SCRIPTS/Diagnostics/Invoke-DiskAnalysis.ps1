# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - Disk Analysis Engine v3.0
.DESCRIPTION
    Comprehensive disk analysis with interactive remediation.
    Every finding includes smart fix commands. Console offers live fix menu.
    HTML report has copy-to-clipboard fix blocks and remediation script generator.
.NOTES
    Author  : FieldOps Pro
    Version : 3.0
    Requires: PowerShell 5.1, Administrator privileges recommended
    Location: E:\SCRIPTS\Diagnostics\Invoke-DiskAnalysis.ps1
    Rules   : Pure ASCII only. All paths dynamic via $PSScriptRoot. PS 5.1 only.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ============================================================
# PATH SETUP
# ============================================================
$ScriptRoot  = $PSScriptRoot
$ProjectRoot = Split-Path (Split-Path $ScriptRoot -Parent) -Parent
$CorePath    = Join-Path $ProjectRoot 'SCRIPTS\Core'
$ReportsPath = Join-Path $ProjectRoot 'REPORTS'
$LogsPath    = Join-Path $ProjectRoot 'LOGS'

if (-not (Test-Path $ReportsPath)) { New-Item -Path $ReportsPath -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogsPath))    { New-Item -Path $LogsPath -ItemType Directory -Force | Out-Null }

# ============================================================
# IMPORT SHARED MODULES
# ============================================================
$LoggerPath = Join-Path $CorePath 'Logger.psm1'
$UtilsPath  = Join-Path $CorePath 'Utils.psm1'

if (Test-Path $LoggerPath) {
    Import-Module $LoggerPath -Force -DisableNameChecking
} else {
    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Write-Host "[$ts] [$Level] $Message"
    }
}
if (Test-Path $UtilsPath) { Import-Module $UtilsPath -Force -DisableNameChecking }

# ============================================================
# CONFIGURATION
# ============================================================
$Config = @{
    TempBloatWarningMB    = 2048
    TempBloatFailMB       = 5120
    DiskSpaceWarningPct   = 20
    DiskSpaceFailPct      = 10
    LargeFileCount        = 20
    DupMinSizeMB          = 1
    DupMaxFiles           = 5000
    DupWasteWarningMB     = 1024
    DupWasteFailMB        = 5120
    SmartTempWarningC     = 55
    SmartTempFailC        = 70
    SmartNVMeTempWarningC = 65
    SmartNVMeTempFailC    = 80
    TempCleanAgeDays      = 7
}

# ============================================================
# RESULTS ENGINE
# ============================================================
$script:Results    = [System.Collections.ArrayList]::new()
$script:Findings   = [System.Collections.ArrayList]::new()
$script:VolumeData = [System.Collections.ArrayList]::new()
$script:CheckCount = 0
$script:Stopwatch  = [System.Diagnostics.Stopwatch]::StartNew()

function Convert-StatusToLogLevel {
    param([string]$Status)
    switch ($Status) {
        'Pass'    { return 'OK' }
        'Warning' { return 'WARN' }
        'Fail'    { return 'ERROR' }
        default   { return 'INFO' }
    }
}

function Add-Check {
    param([string]$Category, [string]$Check, [string]$Status, [string]$Value, [string]$Detail)
    $script:CheckCount++
    $null = $script:Results.Add([PSCustomObject]@{
        Number = $script:CheckCount; Category = $Category; Check = $Check
        Status = $Status; Value = $Value; Detail = $Detail
    })
    $icon = switch ($Status) { 'Pass' {'[PASS]'} 'Warning' {'[WARN]'} 'Fail' {'[FAIL]'} default {'[INFO]'} }
    Write-Host "  $icon $Check : $Value" -ForegroundColor $(
        switch ($Status) { 'Pass' {'Green'} 'Warning' {'Yellow'} 'Fail' {'Red'} default {'Cyan'} }
    )
    Write-Log -Message "$icon $Check = $Value | $Detail" -Level (Convert-StatusToLogLevel $Status)
}

function Add-Finding {
    param(
        [string]$Severity,
        [string]$Title,
        [string]$Detail,
        [string]$Action,
        [array]$FixCommands  # Array of @{ Desc='...'; Cmd='...' }
    )
    $null = $script:Findings.Add([PSCustomObject]@{
        Severity    = $Severity
        Title       = $Title
        Detail      = $Detail
        Action      = $Action
        FixCommands = $FixCommands
    })
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return '{0:N0} B' -f $Bytes
}

# ============================================================
# HEADER
# ============================================================
$Hostname  = $env:COMPUTERNAME
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$DateHuman = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  FieldOps Pro - Disk Analysis Engine v3.0' -ForegroundColor Cyan
Write-Host "  Host: $Hostname | $DateHuman" -ForegroundColor Gray
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

# ============================================================
# SECTION 1: DISK INVENTORY
# ============================================================
Write-Host '[Section 1/8] Disk Inventory' -ForegroundColor White
$script:PhysicalDiskData = [System.Collections.ArrayList]::new()
try {
    $PhysicalDisks = @(Get-PhysicalDisk -ErrorAction Stop)
    foreach ($disk in $PhysicalDisks) {
        try {
            $sizeBytes = $disk.Size
            $sizeStr   = Format-Size -Bytes $sizeBytes
            $mediaType = if ($disk.MediaType) { $disk.MediaType } else { 'Unknown' }
            $busType   = if ($disk.BusType)   { $disk.BusType }   else { 'Unknown' }
            $health    = if ($disk.HealthStatus) { $disk.HealthStatus } else { 'Unknown' }
            $model     = if ($disk.FriendlyName) { $disk.FriendlyName } else { 'Unknown' }

            $null = $script:PhysicalDiskData.Add([PSCustomObject]@{
                DeviceId = $disk.DeviceId; Model = $model; SizeBytes = $sizeBytes
                SizeStr = $sizeStr; MediaType = $mediaType; BusType = $busType; Health = $health
            })

            $status = switch ($health) {
                'Healthy' { 'Pass' } 'Warning' { 'Warning' } 'Degraded' { 'Warning' } default { 'Info' }
            }
            Add-Check -Category 'Disk Inventory' -Check "Disk $($disk.DeviceId): $model" `
                -Status $status -Value "$sizeStr | $mediaType | $busType" `
                -Detail "Health: $health, FW: $($disk.FirmwareVersion)"

            if ($health -notin @('Healthy','Unknown',$null,'')) {
                Add-Finding -Severity 'Critical' -Title "Disk $($disk.DeviceId) health: $health" `
                    -Detail "$model reports $health status" `
                    -Action 'Back up data immediately. Schedule disk replacement.' `
                    -FixCommands @(
                        @{ Desc = 'Create emergency backup of user data to D:\BACKUP'; Cmd = "New-Item -Path 'D:\BACKUP' -ItemType Directory -Force; robocopy `"$env:USERPROFILE`" 'D:\BACKUP\UserProfile' /E /R:1 /W:1 /XJ /NP /LOG:D:\BACKUP\backup.log" }
                        @{ Desc = 'Run chkdsk repair scan (requires reboot)'; Cmd = 'chkdsk C: /F /R /X' }
                    )
            }
        } catch {
            Add-Check -Category 'Disk Inventory' -Check "Disk $($disk.DeviceId)" `
                -Status 'Info' -Value 'Could not read' -Detail $_.Exception.Message
        }
    }
} catch {
    Add-Check -Category 'Disk Inventory' -Check 'Physical Disk Enumeration' `
        -Status 'Info' -Value 'Could not enumerate' -Detail $_.Exception.Message
}

# ============================================================
# SECTION 2: PARTITION LAYOUT
# ============================================================
Write-Host ''
Write-Host '[Section 2/8] Partition Layout' -ForegroundColor White
$script:PartitionData = [System.Collections.ArrayList]::new()
try {
    $Partitions = @(Get-Partition -ErrorAction Stop | Sort-Object DiskNumber, PartitionNumber)
    foreach ($p in $Partitions) {
        try {
            $sizeStr  = Format-Size -Bytes $p.Size
            $typeName = if ($p.Type) { $p.Type } else { 'Unknown' }
            $driveLtr = if ($p.DriveLetter -and $p.DriveLetter -ne [char]0) { "$($p.DriveLetter):" } else { '--' }
            $null = $script:PartitionData.Add([PSCustomObject]@{
                Disk = $p.DiskNumber; Partition = $p.PartitionNumber; Drive = $driveLtr
                Size = $sizeStr; SizeBytes = $p.Size; Type = $typeName
                IsBoot = $p.IsBoot; IsActive = $p.IsActive
            })
            Add-Check -Category 'Partition Layout' -Check "Disk $($p.DiskNumber) Part $($p.PartitionNumber) [$driveLtr]" `
                -Status 'Info' -Value "$sizeStr | $typeName" -Detail "Boot=$($p.IsBoot) Active=$($p.IsActive)"
        } catch {
            Add-Check -Category 'Partition Layout' -Check "Disk $($p.DiskNumber) Part $($p.PartitionNumber)" `
                -Status 'Info' -Value 'Could not read' -Detail $_.Exception.Message
        }
    }
} catch {
    Add-Check -Category 'Partition Layout' -Check 'Partition Enumeration' `
        -Status 'Info' -Value 'Could not enumerate' -Detail $_.Exception.Message
}

# ============================================================
# SECTION 3: VOLUME SPACE ANALYSIS
# ============================================================
Write-Host ''
Write-Host '[Section 3/8] Volume Space Analysis' -ForegroundColor White
try {
    $Volumes = @(Get-Volume -ErrorAction Stop | Where-Object {
        $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0
    } | Sort-Object DriveLetter)

    foreach ($vol in $Volumes) {
        try {
            $totalGB = [math]::Round($vol.Size / 1GB, 2)
            $freeGB  = [math]::Round($vol.SizeRemaining / 1GB, 2)
            $usedGB  = [math]::Round(($vol.Size - $vol.SizeRemaining) / 1GB, 2)
            $freePct = if ($vol.Size -gt 0) { [math]::Round(($vol.SizeRemaining / $vol.Size) * 100, 1) } else { 0 }
            $usedPct = [math]::Round(100 - $freePct, 1)
            $label   = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { 'No Label' }
            $dl      = $vol.DriveLetter

            $null = $script:VolumeData.Add([PSCustomObject]@{
                DriveLetter = $dl; Label = $label; TotalGB = $totalGB; FreeGB = $freeGB
                UsedGB = $usedGB; FreePct = $freePct; UsedPct = $usedPct; FileSystem = $vol.FileSystem
            })

            $status = if ($freePct -lt $Config.DiskSpaceFailPct) { 'Fail' }
                      elseif ($freePct -lt $Config.DiskSpaceWarningPct) { 'Warning' }
                      else { 'Pass' }

            Add-Check -Category 'Volume Space' -Check "${dl}: [$label]" `
                -Status $status -Value "$freeGB GB free of $totalGB GB ($freePct%)" `
                -Detail "Used: $usedGB GB | FS: $($vol.FileSystem)"

            if ($status -eq 'Fail' -or $status -eq 'Warning') {
                $sevTxt = if ($status -eq 'Fail') { 'Critical' } else { 'Warning' }
                $dlStr = "$dl"
                Add-Finding -Severity $sevTxt -Title "Drive ${dlStr}: $freePct% free space ($freeGB GB)" `
                    -Detail "Volume ${dlStr}: has $usedGB GB used of $totalGB GB" `
                    -Action 'Free up disk space using the commands below.' `
                    -FixCommands @(
                        @{ Desc = "Run Disk Cleanup on ${dlStr}:"; Cmd = "cleanmgr /d $dlStr /VERYLOWDISK" }
                        @{ Desc = 'Clear user temp files older than 7 days'; Cmd = "Get-ChildItem -Path `"`$env:TEMP`" -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { `$_.LastWriteTime -lt (Get-Date).AddDays(-$($Config.TempCleanAgeDays)) } | Remove-Item -Force -ErrorAction SilentlyContinue" }
                        @{ Desc = 'Clear Windows temp files'; Cmd = "Get-ChildItem -Path `"`$env:SystemRoot\Temp`" -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { `$_.LastWriteTime -lt (Get-Date).AddDays(-$($Config.TempCleanAgeDays)) } | Remove-Item -Force -ErrorAction SilentlyContinue" }
                        @{ Desc = 'Empty Recycle Bin'; Cmd = 'Clear-RecycleBin -Force -ErrorAction SilentlyContinue' }
                        @{ Desc = 'Check for Windows.old and remove'; Cmd = "if (Test-Path '${dlStr}:\Windows.old') { `$m = (Get-ChildItem '${dlStr}:\Windows.old' -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum -ErrorAction SilentlyContinue); `$s = if (`$m.Sum) { `$m.Sum } else { 0 }; Write-Host ('Windows.old found: ' + [math]::Round(`$s / 1GB, 2) + ' GB'); Write-Host 'Run: cleanmgr /d ${dlStr} and select Previous Windows Installation' } else { Write-Host 'No Windows.old found' }" }
                        @{ Desc = 'Analyze space with TreeSize-style breakdown'; Cmd = "Get-ChildItem -Path '${dlStr}:\' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { `$m = (Get-ChildItem `$_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum -ErrorAction SilentlyContinue); `$size = if (`$m.Sum) { `$m.Sum } else { 0 }; [PSCustomObject]@{ Folder = `$_.Name; SizeGB = [math]::Round(`$size / 1GB, 2) } } | Sort-Object SizeGB -Descending | Select-Object -First 15 | Format-Table -AutoSize" }
                    )
            }
        } catch {
            Add-Check -Category 'Volume Space' -Check "Volume $($vol.DriveLetter):" `
                -Status 'Info' -Value 'Could not read' -Detail $_.Exception.Message
        }
    }
} catch {
    Add-Check -Category 'Volume Space' -Check 'Volume Enumeration' `
        -Status 'Info' -Value 'Could not enumerate' -Detail $_.Exception.Message
}

# ============================================================
# SECTION 4: BITLOCKER DEEP STATUS
# ============================================================
Write-Host ''
Write-Host '[Section 4/8] BitLocker Deep Status' -ForegroundColor White
$script:BitLockerData = [System.Collections.ArrayList]::new()
$bitlockerAvailable = $false
try { $null = Get-Command Get-BitLockerVolume -ErrorAction Stop; $bitlockerAvailable = $true } catch {
    Add-Check -Category 'BitLocker' -Check 'BitLocker Module' -Status 'Info' `
        -Value 'Not available' -Detail 'BitLocker cmdlets not found.'
}

if ($bitlockerAvailable) {
    try {
        $blVolumes = @(Get-BitLockerVolume -ErrorAction Stop)
        foreach ($bv in $blVolumes) {
            try {
                $protStatus = $bv.ProtectionStatus
                $encStatus  = $bv.VolumeStatus
                $encMethod  = if ($bv.EncryptionMethod) { $bv.EncryptionMethod.ToString() } else { 'None' }
                $keyProts   = if ($bv.KeyProtector) {
                    ($bv.KeyProtector | ForEach-Object { $_.KeyProtectorType.ToString() }) -join ', '
                } else { 'None' }
                $volType    = $bv.VolumeType
                $lockStatus = $bv.LockStatus
                $mountPoint = $bv.MountPoint
                $mp         = $mountPoint -replace '[:\\]', ''

                $isOsDrive   = ($volType -eq 'OperatingSystem')
                $isEncrypted = ($protStatus -eq 'On')

                $status = if ($isEncrypted) { 'Pass' }
                          elseif ($isOsDrive) { 'Fail' }
                          else { 'Warning' }

                $null = $script:BitLockerData.Add([PSCustomObject]@{
                    MountPoint = $mountPoint; VolumeType = $volType; Protection = $protStatus
                    Encryption = $encStatus; Method = $encMethod; KeyProtectors = $keyProts
                    LockStatus = $lockStatus
                })

                Add-Check -Category 'BitLocker' -Check "BitLocker $mountPoint ($volType)" `
                    -Status $status -Value "Protection: $protStatus | $encMethod" `
                    -Detail "Keys: $keyProts | Lock: $lockStatus | Volume: $encStatus"

                if (-not $isEncrypted -and $isOsDrive) {
                    Add-Finding -Severity 'Critical' -Title "OS drive $mountPoint not encrypted" `
                        -Detail 'Operating system drive has no BitLocker protection' `
                        -Action 'Enable BitLocker on OS drive with TPM.' `
                        -FixCommands @(
                            @{ Desc = 'Check TPM status'; Cmd = 'Get-Tpm | Format-List TpmPresent, TpmReady, TpmEnabled' }
                            @{ Desc = "Enable BitLocker on $mountPoint with TPM + recovery password"; Cmd = "Enable-BitLocker -MountPoint '$mountPoint' -EncryptionMethod Aes256 -TpmProtector; Add-BitLockerKeyProtector -MountPoint '$mountPoint' -RecoveryPasswordProtector" }
                            @{ Desc = 'Back up recovery key to Azure AD'; Cmd = "`$blv = Get-BitLockerVolume -MountPoint '$mountPoint'; `$rp = `$blv.KeyProtector | Where-Object { `$_.KeyProtectorType -eq 'RecoveryPassword' }; if (`$rp) { BackupToAAD-BitLockerKeyProtector -MountPoint '$mountPoint' -KeyProtectorId `$rp.KeyProtectorId }" }
                        )
                } elseif (-not $isEncrypted) {
                    Add-Finding -Severity 'Warning' -Title "Drive $mountPoint not encrypted" `
                        -Detail "Data drive ($volType) has no BitLocker protection" `
                        -Action 'Consider enabling BitLocker for compliance.' `
                        -FixCommands @(
                            @{ Desc = "Enable BitLocker on $mountPoint with password"; Cmd = "Enable-BitLocker -MountPoint '$mountPoint' -EncryptionMethod Aes256 -PasswordProtector" }
                            @{ Desc = 'Check current BitLocker status'; Cmd = "manage-bde -status $mountPoint" }
                        )
                }
            } catch {
                Add-Check -Category 'BitLocker' -Check "BitLocker $($bv.MountPoint)" `
                    -Status 'Info' -Value 'Could not read' -Detail $_.Exception.Message
            }
        }
    } catch {
        Add-Check -Category 'BitLocker' -Check 'BitLocker Query' `
            -Status 'Info' -Value 'Query failed (elevation required?)' -Detail $_.Exception.Message
    }
}

# ============================================================
# SECTION 5: TEMP FILE BLOAT CALCULATOR
# ============================================================
Write-Host ''
Write-Host '[Section 5/8] Temp File Bloat Calculator' -ForegroundColor White
$script:TempBloatData = [System.Collections.ArrayList]::new()
$totalTempBytes = 0

$tempPaths = @(
    @{ Name = 'User Temp';       Path = $env:TEMP }
    @{ Name = 'Windows Temp';    Path = "$env:SystemRoot\Temp" }
    @{ Name = 'Prefetch';        Path = "$env:SystemRoot\Prefetch" }
    @{ Name = 'Windows Update';  Path = "$env:SystemRoot\SoftwareDistribution\Download" }
    @{ Name = 'Delivery Optim.'; Path = "$env:SystemRoot\SoftwareDistribution\DeliveryOptimization" }
    @{ Name = 'Installer Temp';  Path = ($env:SystemRoot + '\Installer\' + '$PatchCache$') }
    @{ Name = 'Recent Items';    Path = "$env:APPDATA\Microsoft\Windows\Recent" }
    @{ Name = 'Thumbnail Cache'; Path = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" }
    @{ Name = 'Crash Dumps';     Path = "$env:LOCALAPPDATA\CrashDumps" }
    @{ Name = 'Edge Cache';      Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache" }
    @{ Name = 'Chrome Cache';    Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache" }
    @{ Name = 'Teams Cache';     Path = "$env:LOCALAPPDATA\Microsoft\Teams\Cache" }
    @{ Name = 'Teams Blob';      Path = "$env:LOCALAPPDATA\Microsoft\Teams\blob_storage" }
)

foreach ($tp in $tempPaths) {
    if (Test-Path $tp.Path) {
        try {
            $files = @(Get-ChildItem -Path $tp.Path -Recurse -File -Force -ErrorAction SilentlyContinue)
            $folderBytes = 0
            if ($files.Count -gt 0) {
                $measure = $files | Measure-Object -Property Length -Sum
                if ($measure.Sum) { $folderBytes = $measure.Sum }
            }
            $totalTempBytes += $folderBytes
            $null = $script:TempBloatData.Add([PSCustomObject]@{
                Name = $tp.Name; Path = $tp.Path; Size = Format-Size -Bytes $folderBytes
                SizeBytes = $folderBytes; Files = $files.Count
            })
        } catch {
            $null = $script:TempBloatData.Add([PSCustomObject]@{
                Name = $tp.Name; Path = $tp.Path; Size = 'Access Denied'; SizeBytes = 0; Files = 0
            })
        }
    }
}

$totalTempMB = [math]::Round($totalTempBytes / 1MB, 1)
$tempStatus = if ($totalTempMB -ge $Config.TempBloatFailMB) { 'Fail' }
              elseif ($totalTempMB -ge $Config.TempBloatWarningMB) { 'Warning' }
              else { 'Pass' }

Add-Check -Category 'Temp Bloat' -Check 'Total Temporary File Bloat' `
    -Status $tempStatus `
    -Value "$(Format-Size -Bytes $totalTempBytes) across $($script:TempBloatData.Count) locations" `
    -Detail "Scanned: $($tempPaths.Count) known temp paths"

if ($tempStatus -ne 'Pass') {
    $sevTxt = if ($tempStatus -eq 'Fail') { 'Critical' } else { 'Warning' }
    # Build per-location cleanup commands for the top bloaters
    $topBloaters = @($script:TempBloatData | Where-Object { $_.SizeBytes -gt 50MB } | Sort-Object SizeBytes -Descending)
    $tempFixCmds = [System.Collections.ArrayList]::new()
    $null = $tempFixCmds.Add(@{ Desc = 'Run Disk Cleanup with all options'; Cmd = 'cleanmgr /d C /VERYLOWDISK' })
    foreach ($tb in $topBloaters) {
        $cleanPath = $tb.Path
        $cleanName = $tb.Name
        $null = $tempFixCmds.Add(@{
            Desc = "Clean $cleanName ($($tb.Size))"
            Cmd  = "Get-ChildItem -Path '$cleanPath' -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { `$_.LastWriteTime -lt (Get-Date).AddDays(-$($Config.TempCleanAgeDays)) } | Remove-Item -Force -ErrorAction SilentlyContinue; Write-Host 'Cleaned: $cleanName'"
        })
    }
    $null = $tempFixCmds.Add(@{ Desc = 'Empty Recycle Bin'; Cmd = 'Clear-RecycleBin -Force -ErrorAction SilentlyContinue' })

    Add-Finding -Severity $sevTxt -Title "Temp file bloat: $(Format-Size -Bytes $totalTempBytes)" `
        -Detail "$($script:TempBloatData.Count) locations scanned, $(@($topBloaters).Count) over 50 MB" `
        -Action 'Clean temp locations using the targeted commands below.' `
        -FixCommands @($tempFixCmds)
}

# ============================================================
# SECTION 6: LARGE FILE FINDER (TOP 20)
# ============================================================
Write-Host ''
Write-Host '[Section 6/8] Large File Finder (Top 20)' -ForegroundColor White
$script:LargeFileData = [System.Collections.ArrayList]::new()

try {
    $systemDrive = $env:SystemDrive
    $userProfile = $env:USERPROFILE
    $scanPaths = @($userProfile, "$systemDrive\Program Files", "$systemDrive\Program Files (x86)",
        "$systemDrive\ProgramData", "$systemDrive\Users\Public") | Where-Object { Test-Path $_ }
    Write-Host "  Scanning $($scanPaths.Count) directories..." -ForegroundColor Gray
    $allLargeFiles = [System.Collections.ArrayList]::new()
    foreach ($scanPath in $scanPaths) {
        try {
            $found = @(Get-ChildItem -Path $scanPath -Recurse -File -Force -ErrorAction SilentlyContinue |
                Sort-Object Length -Descending | Select-Object -First $Config.LargeFileCount)
            foreach ($f in $found) { if ($f -and $f.FullName) { $null = $allLargeFiles.Add($f) } }
        } catch { }
    }
    $topFiles = @($allLargeFiles | Sort-Object Length -Descending | Select-Object -First $Config.LargeFileCount)
    foreach ($f in $topFiles) {
        $null = $script:LargeFileData.Add([PSCustomObject]@{
            Name = $f.Name; Path = $f.FullName; Size = Format-Size -Bytes $f.Length
            SizeBytes = $f.Length; Modified = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            Extension = $f.Extension.ToUpper()
        })
    }
    $topSize = if ($script:LargeFileData.Count -gt 0) { $script:LargeFileData[0].Size } else { 'N/A' }
    Add-Check -Category 'Large Files' -Check "Top $($Config.LargeFileCount) Largest Files" `
        -Status 'Info' -Value "Largest: $topSize | Found $($script:LargeFileData.Count) files" `
        -Detail "Scanned: $($scanPaths -join ', ')"
} catch {
    Add-Check -Category 'Large Files' -Check 'Large File Scan' `
        -Status 'Info' -Value 'Scan incomplete' -Detail $_.Exception.Message
}

# ============================================================
# SECTION 7: DUPLICATE DETECTION
# ============================================================
Write-Host ''
Write-Host '[Section 7/8] Duplicate Detection' -ForegroundColor White
$script:DuplicateData  = [System.Collections.ArrayList]::new()
$totalDupWaste         = 0
$dupScanComplete       = $false
$dupCandidateCount     = 0
$dupScanPathCount      = 0
$hashCount             = 0

try {
    $userProfile  = $env:USERPROFILE
    $dupScanPaths = @(
        (Join-Path $userProfile 'Downloads'), (Join-Path $userProfile 'Documents'),
        (Join-Path $userProfile 'Desktop'), (Join-Path $userProfile 'Pictures'),
        (Join-Path $userProfile 'Videos')
    ) | Where-Object { Test-Path $_ }
    $dupScanPathCount = $dupScanPaths.Count
    Write-Host "  Scanning $dupScanPathCount directories..." -ForegroundColor Gray
    $minSizeBytes = $Config.DupMinSizeMB * 1MB

    $dupCandidateList = [System.Collections.ArrayList]::new()
    foreach ($sp in $dupScanPaths) {
        $found = @(Get-ChildItem -Path $sp -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge $minSizeBytes })
        foreach ($item in $found) {
            if ($dupCandidateList.Count -ge $Config.DupMaxFiles) { break }
            $null = $dupCandidateList.Add($item)
        }
        if ($dupCandidateList.Count -ge $Config.DupMaxFiles) { break }
    }
    $dupCandidateCount = $dupCandidateList.Count
    Write-Host "  Found $dupCandidateCount files >= $($Config.DupMinSizeMB) MB. Grouping..." -ForegroundColor Gray

    $sizeGroups = @($dupCandidateList | Group-Object -Property Length | Where-Object { $_.Count -ge 2 })
    foreach ($group in $sizeGroups) {
        $ht = @{}
        foreach ($file in $group.Group) {
            try {
                $hash = (Get-FileHash -Path $file.FullName -Algorithm MD5 -ErrorAction Stop).Hash
                $hashCount++
                if ($ht.ContainsKey($hash)) { $ht[$hash] = @($ht[$hash]) + @($file) }
                else { $ht[$hash] = @($file) }
            } catch { }
        }
        foreach ($key in @($ht.Keys)) {
            $dg = @($ht[$key])
            if ($dg.Count -ge 2) {
                $wasteBytes = $dg[0].Length * ($dg.Count - 1)
                $totalDupWaste += $wasteBytes
                $filePaths = ($dg | ForEach-Object { $_.FullName }) -join ' | '
                $null = $script:DuplicateData.Add([PSCustomObject]@{
                    Hash = $key.Substring(0,12) + '...'; Size = Format-Size -Bytes $dg[0].Length
                    SizeBytes = $dg[0].Length; Count = $dg.Count; WasteBytes = $wasteBytes
                    Waste = Format-Size -Bytes $wasteBytes; Files = $filePaths
                    FileList = @($dg | ForEach-Object { $_.FullName })
                })
            }
        }
    }
    $dupScanComplete = $true
} catch {
    Add-Check -Category 'Duplicates' -Check 'Duplicate Detection' `
        -Status 'Info' -Value 'Scan incomplete' -Detail $_.Exception.Message
}

if ($dupScanComplete) {
    $dupWasteMB = [math]::Round($totalDupWaste / 1MB, 1)
    $dupStatus  = if ($dupWasteMB -ge $Config.DupWasteFailMB) { 'Fail' }
                  elseif ($dupWasteMB -ge $Config.DupWasteWarningMB) { 'Warning' }
                  else { 'Pass' }
    Add-Check -Category 'Duplicates' -Check 'Duplicate File Detection' `
        -Status $dupStatus `
        -Value "$($script:DuplicateData.Count) groups | Wasted: $(Format-Size -Bytes $totalDupWaste)" `
        -Detail "Hashed $hashCount files from $dupCandidateCount candidates"
    if ($dupStatus -ne 'Pass' -and $script:DuplicateData.Count -gt 0) {
        # Build targeted removal commands (keep newest, remove older copies)
        $dupFixCmds = [System.Collections.ArrayList]::new()
        $null = $dupFixCmds.Add(@{
            Desc = 'Review duplicates before deleting (DRY RUN - lists what would be removed)'
            Cmd  = "# Dry run: shows which duplicates would be removed (keeps newest)`nWrite-Host 'Duplicate removal dry run:' -ForegroundColor Yellow"
        })
        $groupNum = 0
        foreach ($dd in $script:DuplicateData) {
            $groupNum++
            if ($groupNum -gt 10) {
                $null = $dupFixCmds.Add(@{ Desc = "... and $($script:DuplicateData.Count - 10) more groups"; Cmd = '# Review full duplicate list in the report' })
                break
            }
            $fList = $dd.FileList
            # Keep the first (newest by discovery order), remove the rest
            $toRemove = @($fList | Select-Object -Skip 1)
            $removeStr = ($toRemove | ForEach-Object { "Remove-Item -LiteralPath '$_' -Force -WhatIf" }) -join "`n"
            $null = $dupFixCmds.Add(@{
                Desc = "Group $groupNum ($($dd.Size) x $($dd.Count) copies, waste $($dd.Waste))"
                Cmd  = "# Keep: $($fList[0])`n$removeStr"
            })
        }
        $null = $dupFixCmds.Add(@{
            Desc = 'Execute removal (remove -WhatIf to actually delete)'
            Cmd  = '# IMPORTANT: Review the dry run output above first, then re-run commands without -WhatIf'
        })

        Add-Finding -Severity $dupStatus -Title "Duplicate files wasting $(Format-Size -Bytes $totalDupWaste)" `
            -Detail "$($script:DuplicateData.Count) groups of identical files found" `
            -Action 'Review and remove duplicates using the commands below.' `
            -FixCommands @($dupFixCmds)
    }
}

# ============================================================
# SECTION 8: SMART DEEP ANALYSIS
# ============================================================
Write-Host ''
Write-Host '[Section 8/8] SMART Deep Analysis' -ForegroundColor White
$script:SmartData = [System.Collections.ArrayList]::new()

try {
    $physDisks = @(Get-PhysicalDisk -ErrorAction Stop)
    foreach ($pd in $physDisks) {
        $diskLabel = "Disk $($pd.DeviceId) - $($pd.FriendlyName)"
        $isNVMe   = ($pd.BusType -eq 'NVMe')
        $warnTemp = if ($isNVMe) { $Config.SmartNVMeTempWarningC } else { $Config.SmartTempWarningC }
        $failTemp = if ($isNVMe) { $Config.SmartNVMeTempFailC }   else { $Config.SmartTempFailC }

        try {
            $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
            $tempC = $rel.Temperature; $poh = $rel.PowerOnHours; $wear = $rel.Wear
            $readErrs = $rel.ReadErrorsUncorrected; $writeErrs = $rel.WriteErrorsUncorrected

            if ($null -ne $tempC -and $tempC -gt 0) {
                $busLabel   = if ($isNVMe) { 'NVMe' } else { 'SATA' }
                $tempStatus = if ($tempC -ge $failTemp) { 'Fail' } elseif ($tempC -ge $warnTemp) { 'Warning' } else { 'Pass' }
                Add-Check -Category 'SMART' -Check "$diskLabel - Temperature" `
                    -Status $tempStatus -Value "$tempC C ($busLabel)" `
                    -Detail "Thresholds: Warn ${warnTemp}C, Fail ${failTemp}C"
                if ($tempStatus -ne 'Pass') {
                    Add-Finding -Severity $tempStatus -Title "$diskLabel running hot (${tempC}C)" `
                        -Detail "Temperature above $busLabel threshold" `
                        -Action 'Check airflow and cooling.' `
                        -FixCommands @(
                            @{ Desc = 'Check system fan status'; Cmd = "Get-CimInstance -Namespace root/cimv2 -ClassName Win32_Fan -ErrorAction SilentlyContinue | Format-Table Name, DesiredSpeed, Status" }
                            @{ Desc = 'Monitor temperature over 60 seconds'; Cmd = "1..6 | ForEach-Object { `$t = (Get-PhysicalDisk | Get-StorageReliabilityCounter).Temperature; Write-Host `"[`$(Get-Date -Format 'HH:mm:ss')] Temps: `$(`$t -join ', ')C`"; Start-Sleep 10 }" }
                            @{ Desc = 'Check power plan (high performance = hotter)'; Cmd = 'powercfg /getactivescheme' }
                        )
                }
            } else {
                Add-Check -Category 'SMART' -Check "$diskLabel - Temperature" `
                    -Status 'Info' -Value 'Not reported' -Detail 'No temperature counter'
            }

            if ($null -ne $poh -and $poh -gt 0) {
                $pohYears = [math]::Round($poh / 8760, 1)
                $pohStatus = if ($poh -gt 43800) { 'Warning' } else { 'Pass' }
                Add-Check -Category 'SMART' -Check "$diskLabel - Power-On Hours" `
                    -Status $pohStatus -Value "$poh hrs ($pohYears yrs)" -Detail "$([math]::Round($poh / 24, 0)) days"
            }
            if ($null -ne $wear -and $wear -gt 0) {
                $wearStatus = if ($wear -gt 80) { 'Fail' } elseif ($wear -gt 50) { 'Warning' } else { 'Pass' }
                Add-Check -Category 'SMART' -Check "$diskLabel - SSD Wear" `
                    -Status $wearStatus -Value "$wear%" -Detail 'Endurance consumed'
            }
            if ($null -ne $readErrs -and $readErrs -gt 0) {
                Add-Check -Category 'SMART' -Check "$diskLabel - Read Errors" `
                    -Status 'Fail' -Value "$readErrs uncorrected" -Detail 'Data at risk'
                Add-Finding -Severity 'Critical' -Title "${diskLabel} - $readErrs uncorrected read errors" `
                    -Detail 'Drive media degrading' -Action 'Back up immediately and replace drive.' `
                    -FixCommands @(
                        @{ Desc = 'Emergency backup to D:\BACKUP'; Cmd = "robocopy `"$env:USERPROFILE`" 'D:\BACKUP\UserProfile' /E /R:1 /W:1 /XJ /NP" }
                        @{ Desc = 'Run chkdsk surface scan'; Cmd = 'chkdsk C: /R /X' }
                    )
            }
            if ($null -ne $writeErrs -and $writeErrs -gt 0) {
                Add-Check -Category 'SMART' -Check "$diskLabel - Write Errors" `
                    -Status 'Fail' -Value "$writeErrs uncorrected" -Detail 'Write failures'
                Add-Finding -Severity 'Critical' -Title "${diskLabel} - $writeErrs uncorrected write errors" `
                    -Detail 'Data loss possible' -Action 'Replace drive immediately.' `
                    -FixCommands @(
                        @{ Desc = 'Emergency backup'; Cmd = "robocopy `"$env:USERPROFILE`" 'D:\BACKUP\UserProfile' /E /R:1 /W:1 /XJ /NP" }
                    )
            }

            $null = $script:SmartData.Add([PSCustomObject]@{
                Disk = $diskLabel; TempC = $tempC; WarnTemp = $warnTemp; FailTemp = $failTemp
                BusType = $(if ($isNVMe) { 'NVMe' } else { 'SATA' })
                PowerOnHrs = $poh; Wear = $wear; ReadErrors = if ($readErrs) { $readErrs } else { 0 }
                WriteErrors = if ($writeErrs) { $writeErrs } else { 0 }
            })
        } catch {
            Add-Check -Category 'SMART' -Check "$diskLabel - SMART Counters" `
                -Status 'Info' -Value 'Not available' -Detail 'Use CrystalDiskInfo for deeper SMART.'
        }
    }
} catch {
    Add-Check -Category 'SMART' -Check 'SMART Analysis' `
        -Status 'Info' -Value 'Could not query' -Detail $_.Exception.Message
}

# ============================================================
# SCORING
# ============================================================
$script:Stopwatch.Stop()
$ElapsedSec = [math]::Round($script:Stopwatch.Elapsed.TotalSeconds, 1)

$scoredChecks = @($script:Results | Where-Object { $_.Status -in @('Pass','Warning','Fail') })
$totalScored  = $scoredChecks.Count
$passCount = @($scoredChecks | Where-Object { $_.Status -eq 'Pass' }).Count
$warnCount = @($scoredChecks | Where-Object { $_.Status -eq 'Warning' }).Count
$failCount = @($scoredChecks | Where-Object { $_.Status -eq 'Fail' }).Count
$infoCount = @($script:Results | Where-Object { $_.Status -eq 'Info' }).Count

$scorePct = if ($totalScored -gt 0) {
    [math]::Round((($passCount + ($warnCount * 0.5)) / $totalScored) * 100, 0)
} else { 0 }

$grade = if ($scorePct -ge 95) { 'A+' } elseif ($scorePct -ge 90) { 'A' }
         elseif ($scorePct -ge 85) { 'A-' } elseif ($scorePct -ge 80) { 'B+' }
         elseif ($scorePct -ge 75) { 'B' } elseif ($scorePct -ge 70) { 'C+' }
         elseif ($scorePct -ge 65) { 'C' } elseif ($scorePct -ge 60) { 'D' } else { 'F' }

$gradeColor = if ($scorePct -ge 80) { '#4caf50' } elseif ($scorePct -ge 60) { '#ff9800' } else { '#f44336' }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "  DISK ANALYSIS COMPLETE" -ForegroundColor Cyan
Write-Host "  Grade: $grade ($scorePct%) | $($script:CheckCount) checks in $ElapsedSec sec" -ForegroundColor $(
    if ($scorePct -ge 80) { 'Green' } elseif ($scorePct -ge 60) { 'Yellow' } else { 'Red' }
)
Write-Host "  Pass: $passCount | Warn: $warnCount | Fail: $failCount | Info: $infoCount" -ForegroundColor Gray
Write-Host '============================================================' -ForegroundColor Cyan

# ============================================================
# EXECUTIVE SUMMARY
# ============================================================
$nvmeCount    = @($script:PhysicalDiskData | Where-Object { $_.BusType -eq 'NVMe' }).Count
$diskPhrase   = "$($script:PhysicalDiskData.Count) disk(s) ($nvmeCount NVMe)"
$spacePhrase  = if ($script:VolumeData.Count -gt 0) {
    $tf = [math]::Round(($script:VolumeData | Measure-Object FreeGB -Sum).Sum, 0)
    $tc = [math]::Round(($script:VolumeData | Measure-Object TotalGB -Sum).Sum, 0)
    "$tf GB free across $tc GB"
} else { 'N/A' }
$blEnc = @($script:BitLockerData | Where-Object { $_.Protection -eq 'On' }).Count
$blTot = $script:BitLockerData.Count
$ExecSummary = "This machine has $diskPhrase with $spacePhrase. " +
    "$blEnc of $blTot volumes encrypted. Temp bloat: $(Format-Size -Bytes $totalTempBytes). " +
    "$($script:DuplicateData.Count) duplicate groups ($(Format-Size -Bytes $totalDupWaste) wasted). " +
    "$(if ($script:Findings.Count -eq 0) { 'No issues found.' } else { "$($script:Findings.Count) finding(s) with fix commands below." })"

# ============================================================
# INTERACTIVE CONSOLE FIX MENU
# ============================================================
$actionableFindings = @($script:Findings | Where-Object { $_.FixCommands -and $_.FixCommands.Count -gt 0 })

if ($actionableFindings.Count -gt 0) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  INTERACTIVE REMEDIATION MENU' -ForegroundColor Yellow
    Write-Host "  $($actionableFindings.Count) finding(s) with fix commands available" -ForegroundColor Gray
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host ''

    $fixIndex = 0
    foreach ($af in $actionableFindings) {
        $fixIndex++
        $sevColor = switch ($af.Severity) { 'Critical' { 'Red' } 'Warning' { 'Yellow' } default { 'Cyan' } }
        Write-Host "  [$fixIndex] $($af.Severity.ToUpper()): $($af.Title)" -ForegroundColor $sevColor
        Write-Host "      $($af.Detail)" -ForegroundColor Gray
        $cmdIdx = 0
        foreach ($fc in $af.FixCommands) {
            $cmdIdx++
            Write-Host "      ${fixIndex}.${cmdIdx} - $($fc.Desc)" -ForegroundColor DarkCyan
        }
        Write-Host ''
    }

    Write-Host '  Options:' -ForegroundColor White
    Write-Host '    Type a fix number (e.g. 1.2) to run that specific command' -ForegroundColor Gray
    Write-Host '    Type ALL to generate a combined remediation script' -ForegroundColor Gray
    Write-Host '    Type SKIP to skip and just view the HTML report' -ForegroundColor Gray
    Write-Host ''

    $keepAsking = $true
    while ($keepAsking) {
        $choice = Read-Host '  Enter choice'
        $choiceTrimmed = $choice.Trim().ToUpper()

        if ($choiceTrimmed -eq 'SKIP' -or $choiceTrimmed -eq '') {
            Write-Host '  Skipping remediation.' -ForegroundColor Gray
            $keepAsking = $false
        }
        elseif ($choiceTrimmed -eq 'ALL') {
            # Generate combined script file
            $remScriptPath = Join-Path $ReportsPath "Remediation_${Hostname}_${Timestamp}.ps1"
            $remLines = [System.Collections.ArrayList]::new()
            $null = $remLines.Add("# FieldOps Pro - Remediation Script")
            $null = $remLines.Add("# Generated: $DateHuman | Host: $Hostname")
            $null = $remLines.Add("# Review each command before running. Some require elevation.")
            $null = $remLines.Add("#Requires -RunAsAdministrator")
            $null = $remLines.Add("")
            $fIdx = 0
            foreach ($af in $actionableFindings) {
                $fIdx++
                $null = $remLines.Add("# ============================================================")
                $null = $remLines.Add("# FIX $fIdx - $($af.Severity.ToUpper()): $($af.Title)")
                $null = $remLines.Add("# $($af.Detail)")
                $null = $remLines.Add("# ============================================================")
                foreach ($fc in $af.FixCommands) {
                    $null = $remLines.Add("")
                    $null = $remLines.Add("# $($fc.Desc)")
                    $null = $remLines.Add($fc.Cmd)
                }
                $null = $remLines.Add("")
            }
            ($remLines -join "`r`n") | Out-File -FilePath $remScriptPath -Encoding UTF8 -Force
            Write-Host "  Remediation script saved: $remScriptPath" -ForegroundColor Green
            Write-Host '  Review and run: notepad "' -NoNewline -ForegroundColor Gray
            Write-Host $remScriptPath -NoNewline -ForegroundColor Yellow
            Write-Host '"' -ForegroundColor Gray
            $keepAsking = $false
        }
        elseif ($choiceTrimmed -match '^(\d+)\.(\d+)$') {
            $fNum = [int]$Matches[1]
            $cNum = [int]$Matches[2]
            if ($fNum -ge 1 -and $fNum -le $actionableFindings.Count) {
                $targetFinding = $actionableFindings[$fNum - 1]
                if ($cNum -ge 1 -and $cNum -le $targetFinding.FixCommands.Count) {
                    $targetCmd = $targetFinding.FixCommands[$cNum - 1]
                    Write-Host ''
                    Write-Host "  Running: $($targetCmd.Desc)" -ForegroundColor Yellow
                    Write-Host '  Command:' -ForegroundColor Gray
                    Write-Host "  $($targetCmd.Cmd)" -ForegroundColor DarkGray
                    Write-Host ''
                    $confirm = Read-Host '  Execute? (Y/N)'
                    if ($confirm.Trim().ToUpper() -eq 'Y') {
                        try {
                            Invoke-Expression $targetCmd.Cmd
                            Write-Host '  Done.' -ForegroundColor Green
                        } catch {
                            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    } else {
                        Write-Host '  Skipped.' -ForegroundColor Gray
                    }
                    Write-Host ''
                } else {
                    Write-Host "  Invalid command number. Finding $fNum has $($targetFinding.FixCommands.Count) commands." -ForegroundColor Red
                }
            } else {
                Write-Host "  Invalid finding number. Range: 1-$($actionableFindings.Count)" -ForegroundColor Red
            }
        }
        else {
            Write-Host '  Invalid input. Use format: 1.2, ALL, or SKIP' -ForegroundColor Red
        }
    }
}

# ============================================================
# HTML REPORT v3.0 -- VISUAL + INTERACTIVE FIXES
# ============================================================
Write-Host ''
Write-Host 'Generating HTML report...' -ForegroundColor Gray

$ReportFile = Join-Path $ReportsPath "DiskAnalysis_${Hostname}_${Timestamp}.html"

# --- SVG Donuts ---
$donutHtml = ''
foreach ($v in $script:VolumeData) {
    $r = 54; $circ = [math]::Round(2 * [math]::PI * $r, 2)
    $usedDash = [math]::Round(($v.UsedPct / 100) * $circ, 2)
    $dc = if ($v.FreePct -lt 10) { '#f44336' } elseif ($v.FreePct -lt 20) { '#ff9800' } else { '#4caf50' }
    $donutHtml += @"
<div class="donut-card">
  <svg viewBox="0 0 130 130" class="donut-svg">
    <circle cx="65" cy="65" r="$r" fill="none" stroke="#1a1a3a" stroke-width="12"/>
    <circle cx="65" cy="65" r="$r" fill="none" stroke="$dc" stroke-width="12"
      stroke-dasharray="$usedDash $circ" stroke-linecap="round" transform="rotate(-90 65 65)"/>
    <text x="65" y="60" text-anchor="middle" class="donut-pct">$($v.UsedPct)%</text>
    <text x="65" y="76" text-anchor="middle" class="donut-label">used</text>
  </svg>
  <div class="donut-info">
    <div class="donut-drive">$($v.DriveLetter): [$($v.Label)]</div>
    <div class="donut-detail">$($v.FreeGB) GB free / $($v.TotalGB) GB</div>
    <div class="donut-detail">$($v.FileSystem)</div>
  </div>
</div>
"@
}

# --- Partition Map ---
$partMapHtml = ''
$diskGroups = $script:PartitionData | Group-Object -Property Disk | Sort-Object Name
foreach ($dg in $diskGroups) {
    $dn = $dg.Name; $parts = $dg.Group
    $diskTotal = ($parts | Measure-Object -Property SizeBytes -Sum).Sum
    if ($diskTotal -le 0) { continue }
    $pdm = $script:PhysicalDiskData | Where-Object { $_.DeviceId -eq $dn } | Select-Object -First 1
    $dModel = if ($pdm) { $pdm.Model } else { "Disk $dn" }
    $dSize  = if ($pdm) { $pdm.SizeStr } else { Format-Size -Bytes $diskTotal }
    $segs = foreach ($pt in $parts) {
        $wp = [math]::Max([math]::Round(($pt.SizeBytes / $diskTotal) * 100, 1), 0.5)
        $sc = switch ($pt.Type) { 'System' {'#5c6bc0'} 'Reserved' {'#78909c'} 'Recovery' {'#ab47bc'} 'Basic' {'#26a69a'} default {'#546e7a'} }
        $sl = if ($pt.Drive -ne '--') { $pt.Drive } else { $pt.Type }
        "<div class='part-seg' style='width:${wp}%;background:$sc' title='$sl $($pt.Size)'>$sl</div>"
    }
    $legend = foreach ($pt in $parts) {
        $sc = switch ($pt.Type) { 'System' {'#5c6bc0'} 'Reserved' {'#78909c'} 'Recovery' {'#ab47bc'} 'Basic' {'#26a69a'} default {'#546e7a'} }
        $sl = if ($pt.Drive -ne '--') { "$($pt.Drive) " } else { '' }
        "<span class='legend-item'><span class='legend-dot' style='background:$sc'></span>${sl}$($pt.Type) $($pt.Size)</span>"
    }
    $partMapHtml += "<div class='partmap-disk'><div class='partmap-header'>Disk ${dn}: $dModel ($dSize)</div><div class='partmap-bar'>$($segs -join '')</div><div class='partmap-legend'>$($legend -join '')</div></div>`n"
}

# --- Gauges ---
$gaugeHtml = ''
foreach ($sm in $script:SmartData) {
    if ($null -eq $sm.TempC) { continue }
    $tv = $sm.TempC; $mx = $sm.FailTemp + 20
    $pct = [math]::Min([math]::Round(($tv / $mx) * 100, 0), 100)
    $r2 = 50; $al = [math]::Round([math]::PI * $r2, 2); $fl = [math]::Round(($pct / 100) * $al, 2)
    $gc = if ($tv -ge $sm.FailTemp) { '#f44336' } elseif ($tv -ge $sm.WarnTemp) { '#ff9800' } else { '#4caf50' }
    $gaugeHtml += @"
<div class="gauge-card">
  <svg viewBox="0 0 120 75" class="gauge-svg">
    <path d="M 10 65 A 50 50 0 0 1 110 65" fill="none" stroke="#1a1a3a" stroke-width="10" stroke-linecap="round"/>
    <path d="M 10 65 A 50 50 0 0 1 110 65" fill="none" stroke="$gc" stroke-width="10" stroke-linecap="round" stroke-dasharray="$fl $al"/>
    <text x="60" y="58" text-anchor="middle" class="gauge-val">${tv}C</text>
  </svg>
  <div class="gauge-label">$($sm.Disk)</div>
  <div class="gauge-sub">$($sm.BusType) | Warn $($sm.WarnTemp)C | Max $($sm.FailTemp)C</div>
</div>
"@
}

# --- Treemap ---
$treemapHtml = ''
$sortedTemp = @($script:TempBloatData | Where-Object { $_.SizeBytes -gt 0 } | Sort-Object SizeBytes -Descending)
if ($sortedTemp.Count -gt 0 -and $totalTempBytes -gt 0) {
    $tmColors = @('#ef5350','#ff7043','#ffa726','#ffca28','#66bb6a','#42a5f5','#ab47bc','#78909c','#8d6e63','#26c6da','#ec407a','#7e57c2','#5c6bc0')
    $treemapHtml = foreach ($t in $sortedTemp) {
        $pct = [math]::Max([math]::Round(($t.SizeBytes / $totalTempBytes) * 100, 1), 1)
        $ci = $sortedTemp.IndexOf($t) % $tmColors.Count
        $tc = $tmColors[$ci]
        "<div class='tm-block' style='flex-basis:${pct}%;background:${tc}20;border-color:$tc' title='$($t.Name): $($t.Size) ($($t.Files) files)'><div class='tm-name'>$($t.Name)</div><div class='tm-size'>$($t.Size)</div></div>"
    }
    $treemapHtml = $treemapHtml -join "`n"
}

# --- Findings with Fix Commands ---
$findingsHtml = ''
$fIdx = 0
if ($script:Findings.Count -gt 0) {
    foreach ($f in $script:Findings) {
        $fIdx++
        $sevClass = switch ($f.Severity) { 'Critical' {'finding-critical'} 'Warning' {'finding-warning'} default {'finding-info'} }
        $sevIcon = switch ($f.Severity) { 'Critical' {'&#10007;'} 'Warning' {'&#9888;'} default {'&#8505;'} }

        $fixBlockHtml = ''
        if ($f.FixCommands -and $f.FixCommands.Count -gt 0) {
            $cmdItems = ''
            $cmdAll   = ''
            $cIdx = 0
            foreach ($fc in $f.FixCommands) {
                $cIdx++
                $cmdId = "fix-${fIdx}-${cIdx}"
                $escapedCmd = $fc.Cmd -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
                $cmdItems += @"
<div class="fix-item">
  <div class="fix-desc">$($fc.Desc)</div>
  <div class="fix-cmd-wrap">
    <pre class="fix-cmd" id="$cmdId">$escapedCmd</pre>
    <button class="copy-btn" onclick="copyCmd('$cmdId')" title="Copy to clipboard">Copy</button>
  </div>
</div>
"@
                $cmdAll += "# $($fc.Desc)`n$($fc.Cmd)`n`n"
            }
            $allId = "fix-${fIdx}-all"
            $escapedAll = $cmdAll -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
            $fixBlockHtml = @"
<div class="fix-block">
  <div class="fix-header" onclick="toggleFix(this)">
    <span class="fix-arrow">&#9654;</span> $($f.FixCommands.Count) Fix Command(s) Available
    <button class="copy-all-btn" onclick="event.stopPropagation();copyCmd('$allId')" title="Copy all commands">Copy All</button>
  </div>
  <div class="fix-body" style="display:none">
    $cmdItems
    <textarea id="$allId" class="hidden-textarea">$escapedAll</textarea>
  </div>
</div>
"@
        }

        $findingsHtml += @"
<div class="finding-card $sevClass">
  <div class="finding-title">$sevIcon $($f.Severity.ToUpper()): $($f.Title)</div>
  <div class="finding-detail">$($f.Detail)</div>
  <div class="finding-action"><strong>Recommended:</strong> $($f.Action)</div>
  $fixBlockHtml
</div>
"@
    }
} else {
    $findingsHtml = '<div class="finding-card finding-info"><div class="finding-title">&#10003; No issues detected</div></div>'
}

# --- Tables ---
$blRowsHtml = foreach ($bl in $script:BitLockerData) {
    $pc = if ($bl.Protection -eq 'On') { 'status-pass' } else { 'status-warn' }
    "<tr><td>$($bl.MountPoint)</td><td>$($bl.VolumeType)</td><td class='$pc'>$($bl.Protection)</td><td>$($bl.Method)</td><td>$($bl.KeyProtectors)</td></tr>"
}
$largeRowsHtml = foreach ($lf in $script:LargeFileData) {
    "<tr><td>$($lf.Name)</td><td class='mono'>$($lf.Size)</td><td>$($lf.Extension)</td><td>$($lf.Modified)</td><td class='detail-cell'>$($lf.Path)</td></tr>"
}
$dupRowsHtml = foreach ($d in $script:DuplicateData) {
    $fd = ($d.Files -split ' \| ' | ForEach-Object { "<div class='dup-path'>$_</div>" }) -join ''
    "<tr><td>$($d.Hash)</td><td class='mono'>$($d.Size)</td><td>$($d.Count)</td><td class='mono'>$($d.Waste)</td><td class='detail-cell'>$fd</td></tr>"
}
$checkRowsHtml = foreach ($r in $script:Results) {
    $sc = switch ($r.Status) { 'Pass' {'status-pass'} 'Warning' {'status-warn'} 'Fail' {'status-fail'} default {'status-info'} }
    $si = switch ($r.Status) { 'Pass' {'&#10003;'} 'Warning' {'&#9888;'} 'Fail' {'&#10007;'} default {'&#8505;'} }
    "<tr><td>$($r.Number)</td><td>$($r.Category)</td><td>$($r.Check)</td><td class='$sc'>$si $($r.Status)</td><td>$($r.Value)</td><td class='detail-cell'>$($r.Detail)</td></tr>"
}

# ============================================================
# COMPOSE HTML
# ============================================================
$HtmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>FieldOps Pro - Disk Analysis | $Hostname</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#08081a;color:#d8dce6;padding:28px;line-height:1.55}
.rc{max-width:1200px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#0c1638,#162450);border-radius:14px;padding:30px 34px;margin-bottom:26px;border:1px solid #253068}
.hdr-title{font-size:1.65em;font-weight:800;color:#82b1ff}
.hdr-sub{font-size:0.9em;color:#7888aa;margin-top:2px}
.hdr-bar{display:flex;flex-wrap:wrap;gap:22px;margin-top:18px;padding-top:16px;border-top:1px solid #253068}
.hdr-item{font-size:0.82em}.hdr-lbl{color:#5a7090}.hdr-val{color:#b8c8e0;font-weight:600}
.grade{background:linear-gradient(135deg,#0e1030,#141840);border-radius:14px;padding:26px 34px;margin-bottom:26px;border:1px solid #1e2858;display:flex;align-items:center;gap:34px}
.grade-circle{width:96px;height:96px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:2.2em;font-weight:900;flex-shrink:0;border:5px solid}
.grade-det{flex:1}.grade-score{font-size:1.15em;font-weight:700}
.grade-track{width:100%;height:16px;background:#141430;border-radius:8px;overflow:hidden;margin:10px 0}
.grade-fill{height:100%;border-radius:8px}
.grade-stats{display:flex;gap:22px;font-size:0.83em;margin-top:6px}
.st-p{color:#4caf50}.st-w{color:#ff9800}.st-f{color:#f44336}.st-i{color:#64b5f6}
.exec{background:#0c0c26;border:1px solid #1c1c48;border-radius:12px;padding:20px 26px;margin-bottom:26px;font-size:0.92em;color:#a0b0c8;line-height:1.7}
.exec-title{font-weight:700;color:#82b1ff;margin-bottom:8px}
.stitle{font-size:1.1em;font-weight:700;color:#82b1ff;margin:28px 0 14px;padding-bottom:8px;border-bottom:1px solid #1e1e48;display:flex;align-items:center;gap:10px}
.stitle .badge{background:#1e2858;color:#7888aa;font-size:0.7em;padding:2px 8px;border-radius:10px}
.donut-row{display:flex;flex-wrap:wrap;gap:20px;margin-bottom:24px}
.donut-card{background:#0e0e28;border:1px solid #1e1e48;border-radius:12px;padding:18px;display:flex;align-items:center;gap:16px;flex:1;min-width:260px}
.donut-svg{width:100px;height:100px;flex-shrink:0}
.donut-pct{fill:#e0e0e0;font-size:20px;font-weight:800}.donut-label{fill:#666;font-size:11px}
.donut-drive{font-weight:700;color:#c8d8f0}.donut-detail{font-size:0.82em;color:#7888aa;margin-top:2px}
.partmap-disk{background:#0e0e28;border:1px solid #1e1e48;border-radius:10px;padding:16px;margin-bottom:14px}
.partmap-header{font-weight:600;color:#b0c0d8;margin-bottom:10px;font-size:0.9em}
.partmap-bar{display:flex;height:34px;border-radius:6px;overflow:hidden;gap:2px}
.part-seg{display:flex;align-items:center;justify-content:center;color:#fff;font-size:0.72em;font-weight:600;min-width:24px}
.partmap-legend{margin-top:10px;display:flex;flex-wrap:wrap;gap:12px;font-size:0.75em;color:#7888aa}
.legend-item{display:flex;align-items:center;gap:4px}.legend-dot{width:10px;height:10px;border-radius:3px}
.gauge-row{display:flex;flex-wrap:wrap;gap:18px;margin-bottom:24px}
.gauge-card{background:#0e0e28;border:1px solid #1e1e48;border-radius:12px;padding:16px;text-align:center;flex:1;min-width:200px}
.gauge-svg{width:120px;height:75px;margin:0 auto;display:block}
.gauge-val{fill:#e0e0e0;font-size:18px;font-weight:800}
.gauge-label{font-size:0.8em;color:#b0c0d8;font-weight:600;margin-top:6px}.gauge-sub{font-size:0.72em;color:#5a7090;margin-top:2px}
.tm-container{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:24px}
.tm-block{border-radius:8px;padding:10px 12px;border-left:4px solid;min-width:100px;flex-grow:1}
.tm-name{font-size:0.78em;font-weight:600;color:#c0c8d8}.tm-size{font-size:0.72em;color:#7888aa;margin-top:2px}
.finding-card{border-radius:10px;padding:14px 18px;margin-bottom:12px;border-left:5px solid}
.finding-critical{background:#18080c;border-color:#f44336}
.finding-warning{background:#18140a;border-color:#ff9800}
.finding-info{background:#081018;border-color:#64b5f6}
.finding-title{font-weight:700;margin-bottom:4px;font-size:0.95em}
.finding-detail{font-size:0.85em;color:#8898aa}
.finding-action{font-size:0.82em;color:#a0b0c0;margin-top:6px}
/* Fix blocks */
.fix-block{margin-top:10px;border:1px solid #1e2848;border-radius:8px;overflow:hidden}
.fix-header{background:#0c1430;padding:10px 14px;cursor:pointer;font-size:0.85em;font-weight:600;color:#64b5f6;display:flex;align-items:center;gap:8px;user-select:none}
.fix-header:hover{background:#101838}
.fix-arrow{font-size:0.7em;transition:transform 0.2s;display:inline-block}
.fix-arrow.open{transform:rotate(90deg)}
.fix-body{padding:12px 14px;background:#080c20}
.fix-item{margin-bottom:12px}
.fix-desc{font-size:0.82em;color:#90a4c4;font-weight:600;margin-bottom:4px}
.fix-cmd-wrap{position:relative}
.fix-cmd{background:#060a18;border:1px solid #1a2040;border-radius:6px;padding:10px 12px;font-family:'Cascadia Code','Consolas',monospace;font-size:0.78em;color:#a8d0a8;white-space:pre-wrap;word-break:break-all;margin:0;overflow-x:auto}
.copy-btn{position:absolute;top:6px;right:6px;background:#1e2858;color:#82b1ff;border:1px solid #2a3a6e;border-radius:4px;padding:3px 10px;font-size:0.72em;cursor:pointer}
.copy-btn:hover{background:#2a3a6e}
.copy-btn.copied{background:#2e7d32;color:#fff;border-color:#4caf50}
.copy-all-btn{margin-left:auto;background:#1e2858;color:#82b1ff;border:1px solid #2a3a6e;border-radius:4px;padding:3px 12px;font-size:0.72em;cursor:pointer}
.copy-all-btn:hover{background:#2a3a6e}
.hidden-textarea{position:absolute;left:-9999px;opacity:0;height:0;width:0}
/* Generate script button */
.gen-script-wrap{text-align:center;margin:20px 0}
.gen-script-btn{background:linear-gradient(135deg,#1a3a6e,#2a4a8e);color:#fff;border:2px solid #3a5aae;border-radius:10px;padding:14px 32px;font-size:1em;font-weight:700;cursor:pointer;letter-spacing:0.3px}
.gen-script-btn:hover{background:linear-gradient(135deg,#2a4a8e,#3a5aae)}
/* Tables */
table{width:100%;border-collapse:collapse;margin-bottom:16px;font-size:0.82em}
th{background:#101030;color:#7eb8ff;padding:10px 12px;text-align:left;font-weight:600;border-bottom:2px solid #252560;position:sticky;top:0}
td{padding:8px 12px;border-bottom:1px solid #151538;vertical-align:top}
tr:hover{background:#0e0e2a}
.detail-cell{max-width:320px;word-break:break-all;color:#6878a0;font-size:0.9em}
.dup-path{padding:2px 0;color:#6878a0;font-size:0.88em;word-break:break-all}
.mono{font-family:'Cascadia Code','Consolas',monospace;color:#a8b8d0}
.status-pass{color:#4caf50;font-weight:600}.status-warn{color:#ff9800;font-weight:600}
.status-fail{color:#f44336;font-weight:600}.status-info{color:#64b5f6;font-weight:600}
details{background:#0c0c24;border:1px solid #1a1a44;border-radius:10px;margin-bottom:18px;overflow:hidden}
summary{cursor:pointer;padding:14px 20px;font-weight:600;color:#90a4c4;font-size:0.95em;user-select:none;list-style:none;display:flex;align-items:center;gap:8px}
summary:hover{background:#101038}
summary::-webkit-details-marker{display:none}
summary::before{content:'\\25B6';font-size:0.7em;transition:transform 0.2s;display:inline-block;color:#5070a0}
details[open] summary::before{transform:rotate(90deg)}
details .sect-body{padding:16px 20px;overflow-x:auto}
.ftr{text-align:center;padding:22px;color:#2a3a5a;font-size:0.78em;border-top:1px solid #151538;margin-top:30px}
@media print{
  body{background:#fff!important;color:#222!important;padding:10px}
  .hdr,.grade,.exec,details,.finding-card,.donut-card,.partmap-disk,.gauge-card,.tm-block,.fix-block{background:#f8f8fc!important;border-color:#ddd!important;color:#222!important;-webkit-print-color-adjust:exact;print-color-adjust:exact}
  .fix-cmd{background:#f0f0f0!important;color:#1a3a1a!important;border-color:#ccc!important}
  .fix-header{background:#eef!important;color:#1a3a6a!important}
  .hdr-title,.stitle,.grade-score,.exec-title,.donut-drive,.fix-desc{color:#1a3a6a!important}
  .hdr-sub,.hdr-lbl,.donut-detail,.gauge-sub,.finding-detail,.finding-action,.detail-cell,.dup-path{color:#555!important}
  .donut-pct,.gauge-val{fill:#222!important}.donut-label{fill:#888!important}
  th{background:#eef!important;color:#1a3a6a!important}
  td{border-color:#ddd!important;color:#333!important}
  .status-pass{color:#1b7a1b!important}.status-warn{color:#b36b00!important}
  .status-fail{color:#c62828!important}.status-info{color:#1565c0!important}
  .copy-btn,.copy-all-btn,.gen-script-btn{display:none!important}
  .part-seg{color:#fff!important;-webkit-print-color-adjust:exact;print-color-adjust:exact}
}
</style>
</head>
<body>
<div class="rc">

<div class="hdr">
  <div class="hdr-title">FieldOps Pro -- Disk Analysis Report</div>
  <div class="hdr-sub">Comprehensive storage health, encryption, space analysis &amp; remediation</div>
  <div class="hdr-bar">
    <div class="hdr-item"><span class="hdr-lbl">Hostname</span> <span class="hdr-val">$Hostname</span></div>
    <div class="hdr-item"><span class="hdr-lbl">Date</span> <span class="hdr-val">$DateHuman</span></div>
    <div class="hdr-item"><span class="hdr-lbl">Checks</span> <span class="hdr-val">$($script:CheckCount)</span></div>
    <div class="hdr-item"><span class="hdr-lbl">Duration</span> <span class="hdr-val">${ElapsedSec}s</span></div>
    <div class="hdr-item"><span class="hdr-lbl">Engine</span> <span class="hdr-val">v3.0</span></div>
  </div>
</div>

<div class="grade">
  <div class="grade-circle" style="background:${gradeColor}18;border-color:$gradeColor;color:$gradeColor">$grade</div>
  <div class="grade-det">
    <div class="grade-score">Disk Health Score: $scorePct%</div>
    <div class="grade-track"><div class="grade-fill" style="width:${scorePct}%;background:linear-gradient(90deg,$gradeColor,${gradeColor}66)"></div></div>
    <div class="grade-stats"><span class="st-p">$passCount Passed</span><span class="st-w">$warnCount Warnings</span><span class="st-f">$failCount Failed</span><span class="st-i">$infoCount Info</span></div>
  </div>
</div>

<div class="exec"><div class="exec-title">Executive Summary</div>$ExecSummary</div>

<div class="stitle">Findings &amp; Remediation <span class="badge">$($script:Findings.Count) finding(s)</span></div>
$findingsHtml

$(if ($actionableFindings.Count -gt 0) {
'<div class="gen-script-wrap"><button class="gen-script-btn" onclick="generateScript()">Generate Combined Remediation Script</button></div>'
})

<div class="stitle">Volume Space <span class="badge">$($script:VolumeData.Count) volume(s)</span></div>
<div class="donut-row">$donutHtml</div>

<div class="stitle">Partition Layout <span class="badge">$($script:PartitionData.Count) partition(s)</span></div>
$partMapHtml

$(if ($gaugeHtml.Length -gt 0) {
@"
<div class="stitle">Drive Temperatures <span class="badge">SMART</span></div>
<div class="gauge-row">$gaugeHtml</div>
"@
})

<div class="stitle">Temp File Bloat <span class="badge">$(Format-Size -Bytes $totalTempBytes)</span></div>
<div class="tm-container">$treemapHtml</div>

<details open>
  <summary>BitLocker ($($script:BitLockerData.Count) volumes)</summary>
  <div class="sect-body">
$(if ($script:BitLockerData.Count -gt 0) { "<table><tr><th>Mount</th><th>Type</th><th>Protection</th><th>Method</th><th>Key Protectors</th></tr>$($blRowsHtml -join '')</table>" } else { '<p style="color:#5a7090">Not available.</p>' })
  </div>
</details>

<details>
  <summary>Top $($Config.LargeFileCount) Largest Files ($($script:LargeFileData.Count) found)</summary>
  <div class="sect-body">
$(if ($script:LargeFileData.Count -gt 0) { "<table><tr><th>Filename</th><th>Size</th><th>Type</th><th>Modified</th><th>Path</th></tr>$($largeRowsHtml -join '')</table>" } else { '<p style="color:#5a7090">None found.</p>' })
  </div>
</details>

<details>
  <summary>Duplicates ($($script:DuplicateData.Count) groups, $(Format-Size -Bytes $totalDupWaste) reclaimable)</summary>
  <div class="sect-body">
$(if ($script:DuplicateData.Count -gt 0) { "<table><tr><th>Hash</th><th>Size</th><th>Copies</th><th>Wasted</th><th>Paths</th></tr>$($dupRowsHtml -join '')</table>" } else { '<p style="color:#5a7090">None found.</p>' })
  </div>
</details>

<details>
  <summary>All Checks ($($script:CheckCount))</summary>
  <div class="sect-body">
    <table><tr><th>#</th><th>Category</th><th>Check</th><th>Status</th><th>Value</th><th>Detail</th></tr>$($checkRowsHtml -join '')</table>
  </div>
</details>

<div class="ftr">FieldOps Pro -- Disk Analysis Engine v3.0 | $DateHuman | $($script:CheckCount) checks in ${ElapsedSec}s | $Hostname</div>

</div>

<script>
function copyCmd(id){
  var el=document.getElementById(id);
  var text=el.tagName==='TEXTAREA'?el.value:el.textContent;
  if(navigator.clipboard){navigator.clipboard.writeText(text).then(function(){
    var btns=el.closest('.fix-cmd-wrap')||el.closest('.fix-block');
    if(btns){var b=event.target;b.textContent='Copied!';b.classList.add('copied');setTimeout(function(){b.textContent=b.classList.contains('copy-all-btn')?'Copy All':'Copy';b.classList.remove('copied')},2000)}
  })}else{var ta=document.createElement('textarea');ta.value=text;document.body.appendChild(ta);ta.select();document.execCommand('copy');document.body.removeChild(ta)}
}
function toggleFix(header){
  var body=header.nextElementSibling;
  var arrow=header.querySelector('.fix-arrow');
  if(body.style.display==='none'){body.style.display='block';arrow.classList.add('open')}
  else{body.style.display='none';arrow.classList.remove('open')}
}
function generateScript(){
  var cmds='# FieldOps Pro - Combined Remediation Script\n# Generated: $DateHuman | Host: $Hostname\n# Review each command before running.\n\n';
  document.querySelectorAll('.fix-cmd').forEach(function(el){cmds+=el.textContent+'\n\n'});
  if(navigator.clipboard){navigator.clipboard.writeText(cmds).then(function(){
    var btn=document.querySelector('.gen-script-btn');btn.textContent='Copied to Clipboard!';btn.style.background='linear-gradient(135deg,#2e7d32,#4caf50)';
    setTimeout(function(){btn.textContent='Generate Combined Remediation Script';btn.style.background=''},3000)
  })}
}
</script>
</body>
</html>
"@

$HtmlContent | Out-File -FilePath $ReportFile -Encoding UTF8 -Force

Write-Host ''
Write-Host "  Report saved: $ReportFile" -ForegroundColor Green
Write-Host ''
Write-Host 'To open the report:' -ForegroundColor Gray
Write-Host "  Start-Process `"$ReportFile`"" -ForegroundColor Yellow
Write-Host ''
