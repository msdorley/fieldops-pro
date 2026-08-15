#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - Enterprise Software Deployment Engine v4.0
.DESCRIPTION
    - RESILIENT: Never fails due to missing optional folders (05_Procedures etc.)
    - AUTO-DOWNLOAD: Fetches official installers directly to USB when missing
    - SMART DISCOVERY: Scans entire USB for installers automatically
    - Pre-flight system validation
    - Post-install verification
    - Full JSON + HTML report
    Author: Ousman Dorley | EU Deployment | FieldOps Pro v4.0
#>

# ==============================================================================
# PATH RESOLUTION -- derived, never hardcoded, never fragile
# ==============================================================================
$scriptsRoot = Split-Path $PSScriptRoot -Parent        # E:\SCRIPTS
$usbRoot     = Split-Path $scriptsRoot  -Parent        # E:\
$deployRoot  = Join-Path $usbRoot 'TOOLS\Deploy'       # E:\TOOLS\Deploy (PRIMARY)
$logRoot     = Join-Path $usbRoot 'LOGS'               # E:\LOGS
$reportRoot  = Join-Path $usbRoot 'REPORTS'            # E:\REPORTS

# OPTIONAL bonus discovery folders -- system works fine if these don't exist
# We scan for them dynamically rather than hardcoding names
$bonusScanRoots = @()
try {
    Get-ChildItem $usbRoot -Directory -EA SilentlyContinue | ForEach-Object {
        # Any folder at USB root that isn't a system folder is a bonus source
        if ($_.Name -notin @('SCRIPTS','TOOLS','DRIVERS','DOCS','LOGS','REPORTS','ISO','DRIVERS','etc')) {
            $bonusScanRoots += $_.FullName
        }
    }
} catch {}

Import-Module (Join-Path $scriptsRoot 'Core\Logger.psm1') -Force -DisableNameChecking -EA SilentlyContinue
Import-Module (Join-Path $scriptsRoot 'Core\Utils.psm1')  -Force -DisableNameChecking -EA SilentlyContinue

# ==============================================================================
# COLOR HELPERS
# ==============================================================================
function c  ($text, $fg = 'White', $bg = 'Black') { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg -NoNewline }
function cn ($text, $fg = 'White', $bg = 'Black') { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg }
function nl { Write-Host '' }
function sep { cn ('  ' + ('-' * 74)) DarkGray }

# ==============================================================================
# ENVIRONMENT DETECTION
# ==============================================================================
function Get-Environment {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
    $os      = (Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).Caption
    $freeGB  = [math]::Round((Get-PSDrive C -EA SilentlyContinue).Free / 1GB, 2)
    $usbFreeGB = [math]::Round((Get-PSDrive ($usbRoot.TrimEnd('\')[0]) -EA SilentlyContinue).Free / 1GB, 2)
    $isWinPE = Test-Path 'X:\Windows\System32\wpeinit.exe'

    $pendingReboot = $false
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
            $pendingReboot = $true
        }
        if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -EA SilentlyContinue).PendingFileRenameOperations) {
            $pendingReboot = $true
        }
    } catch {}

    $aadStatus = 'Unknown'
    try {
        $d = (dsregcmd /status 2>$null) -join ' '
        if     ($d -match 'AzureAdJoined\s*:\s*YES')   { $aadStatus = 'Azure AD Joined' }
        elseif ($d -match 'WorkplaceJoined\s*:\s*YES') { $aadStatus = 'Workplace Joined' }
        else                                            { $aadStatus = 'Not Joined' }
    } catch {}

    $sophosRunning = $false
    try { $sophosRunning = ($null -ne (Get-Process 'SophosUI','SAVService' -EA SilentlyContinue | Select-Object -First 1)) } catch {}

    $hasInternet = $false
    try {
        $ping = Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -EA SilentlyContinue
        $hasInternet = [bool]$ping
    } catch {}

    return [PSCustomObject]@{
        IsAdmin       = $isAdmin
        IsWinPE       = $isWinPE
        OS            = $os
        Hostname      = $env:COMPUTERNAME
        FreeGB        = $freeGB
        UsbFreeGB     = $usbFreeGB
        PendingReboot = $pendingReboot
        AADStatus     = $aadStatus
        SophosRunning = $sophosRunning
        HasInternet   = $hasInternet
        Timestamp     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
}

# ==============================================================================
# SMART USB SCANNER
# Recursively finds installer files anywhere on the USB matching known patterns
# This makes the system RESILIENT to folder renames/moves
# ==============================================================================
function Find-InstallerOnUSB {
    param([string[]]$FilePatterns)
    $found = @()
    foreach ($pattern in $FilePatterns) {
        try {
            $results = Get-ChildItem $usbRoot -Recurse -Filter $pattern -EA SilentlyContinue |
                       Select-Object -First 1
            if ($results) { $found += $results.FullName }
        } catch {}
    }
    return ($found | Select-Object -First 1)
}

# ==============================================================================
# PACKAGE REGISTRY
# InstallerPaths   = explicit known paths (fastest lookup)
# USBSearchPatterns = filename patterns for smart USB scan (resilient fallback)
# DownloadURL      = official direct download URL (used when no file found)
# DownloadPage     = official download PAGE (opened in browser as last resort)
# ==============================================================================
function Get-PackageRegistry {
    return @(

        [PSCustomObject]@{
            ID               = 'chrome'
            Name             = 'Google Chrome'
            Category         = 'Browser'
            Priority         = 10
            InstallerPaths   = @("$deployRoot\Chrome\ChromeSetup.exe")
            USBSearchPatterns= @('ChromeSetup.exe','chrome_installer.exe')
            InstallerType    = 'EXE'
            SilentArgs       = '/silent /install'
            DetectKey        = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
            DetectFile       = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
            MinDiskGB        = 1.0
            DownloadURL      = 'https://dl.google.com/chrome/install/ChromeSetup.exe'
            DownloadPage     = 'https://www.google.com/chrome/'
            DownloadDest     = "$deployRoot\Chrome\ChromeSetup.exe"
            PostActionID     = $null
        },

        [PSCustomObject]@{
            ID               = '7zip'
            Name             = '7-Zip (x64)'
            Category         = 'Utility'
            Priority         = 20
            InstallerPaths   = @("$deployRoot\7Zip\7z2600-x64.exe")
            USBSearchPatterns= @('7z*-x64.exe','7z*.exe')
            InstallerType    = 'EXE'
            SilentArgs       = '/S'
            DetectKey        = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip'
            DetectFile       = 'C:\Program Files\7-Zip\7z.exe'
            MinDiskGB        = 0.1
            DownloadURL      = 'https://www.7-zip.org/a/7z2301-x64.exe'
            DownloadPage     = 'https://www.7-zip.org/download.html'
            DownloadDest     = "$deployRoot\7Zip\7z-x64.exe"
            PostActionID     = $null
        },

        [PSCustomObject]@{
            ID               = 'notepadpp'
            Name             = 'Notepad++'
            Category         = 'Utility'
            Priority         = 21
            InstallerPaths   = @("$deployRoot\NotepadPP\npp.Installer.x64.exe")
            USBSearchPatterns= @('npp.*.Installer.x64.exe','notepad++*.exe')
            InstallerType    = 'EXE'
            SilentArgs       = '/S'
            DetectKey        = 'HKLM:\SOFTWARE\Notepad++'
            DetectFile       = 'C:\Program Files\Notepad++\notepad++.exe'
            MinDiskGB        = 0.1
            DownloadURL      = $null
            DownloadPage     = 'https://notepad-plus-plus.org/downloads/'
            DownloadDest     = "$deployRoot\NotepadPP\npp.Installer.x64.exe"
            PostActionID     = $null
        },

        [PSCustomObject]@{
            ID               = 'pdf24'
            Name             = 'PDF24 Creator'
            Category         = 'Office'
            Priority         = 30
            InstallerPaths   = @("$deployRoot\AdobeReader\Reader_fr_install.exe")
            USBSearchPatterns= @('Reader_fr_install.exe','pdf24*.exe','pdf24-creator*.exe')
            InstallerType    = 'EXE'
            SilentArgs       = '/S'
            DetectKey        = 'HKLM:\SOFTWARE\PDF24'
            DetectFile       = 'C:\Program Files\PDF24\pdf24-DocTool.exe'
            MinDiskGB        = 0.3
            DownloadURL      = 'https://download.pdf24.org/pdf24-creator-latest-x64.exe'
            DownloadPage     = 'https://tools.pdf24.org/en/creator'
            DownloadDest     = "$deployRoot\AdobeReader\pdf24-creator-x64.exe"
            PostActionID     = $null
        },

        [PSCustomObject]@{
            ID               = 'vlc'
            Name             = 'VLC Media Player'
            Category         = 'Media'
            Priority         = 40
            InstallerPaths   = @(
                "$deployRoot\VLC\vlc-x64.exe",
                "$deployRoot\VLC\vlc-win64.exe",
                "$deployRoot\VLC\vlc.exe"
            )
            USBSearchPatterns= @('vlc-*-win64.exe','vlc-x64.exe','vlc*.exe')
            InstallerType    = 'EXE'
            SilentArgs       = '/S /L=1036'
            DetectKey        = 'HKLM:\SOFTWARE\VideoLAN\VLC'
            DetectFile       = 'C:\Program Files\VideoLAN\VLC\vlc.exe'
            MinDiskGB        = 0.3
            DownloadURL      = $null
            DownloadPage     = 'https://www.videolan.org/vlc/download-windows.html'
            DownloadDest     = "$deployRoot\VLC\vlc-x64.exe"
            PostActionID     = $null
        },

        [PSCustomObject]@{
            ID               = 'globalprotect'
            Name             = 'GlobalProtect VPN'
            Category         = 'Network'
            Priority         = 50
            InstallerPaths   = @("$deployRoot\GlobalProtect\GlobalProtect64-6.2.2.msi")
            USBSearchPatterns= @('GlobalProtect*.msi','GlobalProtect*.exe')
            InstallerType    = 'MSI'
            SilentArgs       = '/qn /norestart REBOOT=ReallySuppress'
            DetectKey        = 'HKLM:\SOFTWARE\Palo Alto Networks\GlobalProtect'
            DetectFile       = 'C:\Program Files\Palo Alto Networks\GlobalProtect\PanGPA.exe'
            MinDiskGB        = 0.2
            DownloadURL      = $null
            DownloadPage     = 'https://support.paloaltonetworks.com/support/Home'
            DownloadDest     = "$deployRoot\GlobalProtect\GlobalProtect64.msi"
            PostActionID     = $null
        },

        [PSCustomObject]@{
            ID               = 'teams'
            Name             = 'Microsoft Teams'
            Category         = 'Collaboration'
            Priority         = 60
            InstallerPaths   = @(
                "$deployRoot\Teams\Teams_windows_x64.exe",
                "$deployRoot\Teams\TeamsSetup.exe",
                "$deployRoot\Teams\MSTeams-x64.msix"
            )
            USBSearchPatterns= @('Teams_windows_x64.exe','MSTeams-x64.msix','TeamsSetup.exe')
            InstallerType    = 'EXE'
            SilentArgs       = '--silent'
            DetectKey        = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Teams'
            DetectFile       = "$env:LOCALAPPDATA\Microsoft\Teams\current\Teams.exe"
            MinDiskGB        = 0.5
            DownloadURL      = 'https://go.microsoft.com/fwlink/p/?linkid=2196106'
            DownloadPage     = 'https://www.microsoft.com/en-us/microsoft-teams/download-app'
            DownloadDest     = "$deployRoot\Teams\Teams_windows_x64.exe"
            PostActionID     = $null
        },

        [PSCustomObject]@{
            ID               = 'sophos'
            Name             = 'Sophos Cloud Endpoint'
            Category         = 'Security'
            Priority         = 70
            InstallerPaths   = @("$deployRoot\Sophos\SophosSetup.exe")
            USBSearchPatterns= @('SophosSetup.exe','SophosInstall.exe')
            InstallerType    = 'EXE'
            SilentArgs       = '--quiet'
            DetectKey        = 'HKLM:\SOFTWARE\Sophos\AutoUpdate'
            DetectFile       = 'C:\Program Files\Sophos\Sophos Endpoint Agent\SophosUI.exe'
            MinDiskGB        = 0.5
            DownloadURL      = $null
            DownloadPage     = 'https://central.sophos.com'
            DownloadDest     = "$deployRoot\Sophos\SophosSetup.exe"
            PostActionID     = $null
        },

        [PSCustomObject]@{
            ID               = 'dcu'
            Name             = 'Dell Command Update'
            Category         = 'Dell'
            Priority         = 80
            InstallerPaths   = @(
                "$deployRoot\DellCommandUpdate\Dell-Command-Update-Application_x64.exe",
                "$deployRoot\DellCommandUpdate\DCU.exe"
            )
            USBSearchPatterns= @('Dell-Command-Update*.exe','DCU*.exe')
            InstallerType    = 'EXE'
            SilentArgs       = '/s'
            DetectKey        = 'HKLM:\SOFTWARE\Dell\UpdateService'
            DetectFile       = 'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe'
            MinDiskGB        = 0.3
            DownloadURL      = $null
            DownloadPage     = 'https://www.dell.com/support/kbdoc/en-us/000177325/dell-command-update'
            DownloadDest     = "$deployRoot\DellCommandUpdate\Dell-Command-Update-x64.exe"
            PostActionID     = 'dcu_scan'
        },

        [PSCustomObject]@{
            ID               = 'canon_pcl6'
            Name             = 'Canon PCL6 Printer Driver'
            Category         = 'Printer'
            Priority         = 90
            InstallerPaths   = @("$deployRoot\CanonPCL6\Setup.exe")
            USBSearchPatterns= @('GPlus_PCL6*\x64\Setup.exe','CanonPCL6*\Setup.exe')
            InstallerType    = 'EXE'
            SilentArgs       = '/S /L=French'
            DetectKey        = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Environments\Windows x64\Drivers\Version-3\Canon Generic Plus PCL6'
            DetectFile       = $null
            MinDiskGB        = 0.2
            DownloadURL      = $null
            DownloadPage     = 'https://www.canon-europe.com/support/consumer_products/products/printers/'
            DownloadDest     = "$deployRoot\CanonPCL6\Setup.exe"
            PostActionID     = $null
        }
    )
}

# ==============================================================================
# POST-INSTALL ACTIONS
# ==============================================================================
function Invoke-PostAction {
    param([string]$ActionID)
    switch ($ActionID) {
        'dcu_scan' {
            $dcu = 'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe'
            if (Test-Path $dcu) {
                cn '      [>] Running Dell driver scan...' Cyan
                try { Start-Process $dcu -ArgumentList '/scan -silent' -Wait -EA SilentlyContinue } catch {}
            }
        }
    }
}

# ==============================================================================
# RESILIENT INSTALLER FINDER
# Priority order:
#   1. Explicit InstallerPaths (fastest)
#   2. Smart USB-wide scan using filename patterns (resilient to folder moves)
#   3. Returns $null if nothing found (never crashes)
# ==============================================================================
function Find-Installer {
    param([PSCustomObject]$pkg)

    # 1 -- Explicit paths
    foreach ($path in $pkg.InstallerPaths) {
        if ($path -and (Test-Path $path)) { return $path }
    }

    # 2 -- Smart USB scan (handles renamed/moved folders automatically)
    if ($pkg.USBSearchPatterns) {
        $found = Find-InstallerOnUSB -FilePatterns $pkg.USBSearchPatterns
        if ($found) { return $found }
    }

    return $null
}

# ==============================================================================
# DOWNLOAD ENGINE
# ==============================================================================
function Get-DownloadStatus {
    param([PSCustomObject]$pkg, [PSCustomObject]$sysEnv)
    if ($null -ne (Find-Installer $pkg)) {
        return [PSCustomObject]@{ CanDownload=$false; CanOpenPage=$false; Reason='File already on USB' }
    }
    if ($sysEnv.HasInternet) {
        return [PSCustomObject]@{
            CanDownload = ($null -ne $pkg.DownloadURL)
            CanOpenPage = ($null -ne $pkg.DownloadPage)
            Reason      = if ($pkg.DownloadURL) { 'Direct download available' } else { 'Download page available' }
        }
    }
    return [PSCustomObject]@{ CanDownload=$false; CanOpenPage=$false; Reason='No internet' }
}

function Invoke-DirectDownload {
    param([PSCustomObject]$pkg, [PSCustomObject]$sysEnv)

    if (-not $sysEnv.HasInternet) {
        cn '  [X] No internet connection detected.' Red
        return $false
    }
    if (-not $pkg.DownloadURL) {
        cn '  [!] No direct download URL for this package. Opening download page...' Yellow
        Invoke-OpenDownloadPage -pkg $pkg
        return $false
    }

    $destDir = Split-Path $pkg.DownloadDest -Parent
    if (-not (Test-Path $destDir)) { New-Item $destDir -ItemType Directory -Force | Out-Null }

    cn "  [>] Downloading $($pkg.Name)..." Cyan
    cn "      From: $($pkg.DownloadURL)" DarkGray
    cn "      To:   $($pkg.DownloadDest)" DarkGray
    nl

    try {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        # Use BITS if available (faster, resumable), fall back to WebRequest
        $bitsAvailable = $null -ne (Get-Command Start-BitsTransfer -EA SilentlyContinue)

        if ($bitsAvailable) {
            Start-BitsTransfer -Source $pkg.DownloadURL -Destination $pkg.DownloadDest -EA Stop
        } else {
            # WebRequest with progress
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'FieldOpsPro/4.0 Enterprise IT Toolkit')

            $global:dlProgress = 0
            $wc.DownloadProgressChanged += {
                $pct = $EventArgs.ProgressPercentage
                if ($pct -ne $global:dlProgress) {
                    $global:dlProgress = $pct
                    Show-ProgressBar -Current $pct -Total 100 -Label "$pct%  downloading..."
                }
            }
            $wc.DownloadFileCompleted += { $global:dlDone = $true }
            $global:dlDone = $false
            $wc.DownloadFileAsync([Uri]$pkg.DownloadURL, $pkg.DownloadDest)
            while (-not $global:dlDone) { Start-Sleep -Milliseconds 200 }
        }

        $stopwatch.Stop()
        $sizeKB = [math]::Round((Get-Item $pkg.DownloadDest -EA SilentlyContinue).Length / 1KB, 0)
        $secs   = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        nl
        cn "  [OK] Downloaded: $sizeKB KB in $($secs)s" Green
        cn "       Saved to: $($pkg.DownloadDest)" DarkGray
        return $true

    } catch {
        nl
        cn "  [X] Download failed: $_" Red
        cn "  [>] Opening download page instead..." Yellow
        Invoke-OpenDownloadPage -pkg $pkg
        return $false
    }
}

function Invoke-OpenDownloadPage {
    param([PSCustomObject]$pkg)
    if (-not $pkg.DownloadPage) {
        cn '  [X] No download page configured for this package.' Red
        return
    }
    cn "  [>] Opening official download page for $($pkg.Name)..." Cyan
    cn "      $($pkg.DownloadPage)" DarkGray
    try {
        Start-Process $pkg.DownloadPage
        cn '  [OK] Browser opened. Download the installer and save it to:' Green
        $destDir = Split-Path $pkg.DownloadDest -Parent
        cn "       $destDir" Yellow
        cn '       Then return here and press [R] to rescan.' DarkGray
    } catch {
        cn "  [X] Could not open browser: $_" Red
        cn "  [>] Manually visit: $($pkg.DownloadPage)" Yellow
    }
}

# ==============================================================================
# DETECTION ENGINE
# ==============================================================================
function Test-PackageInstalled {
    param([PSCustomObject]$pkg)
    if ($pkg.DetectKey  -and (Test-Path $pkg.DetectKey))  { return $true }
    if ($pkg.DetectFile -and (Test-Path $pkg.DetectFile)) { return $true }
    return $false
}

function Get-InstalledVersion {
    param([PSCustomObject]$pkg)
    try {
        if ($pkg.DetectFile -and (Test-Path $pkg.DetectFile)) {
            $v = (Get-Item $pkg.DetectFile -EA SilentlyContinue).VersionInfo.ProductVersion
            if ($v) { return $v.Trim() }
        }
    } catch {}
    return 'Unknown'
}

# ==============================================================================
# PROGRESS BAR -- pure ASCII
# ==============================================================================
function Show-ProgressBar {
    param([int]$Current, [int]$Total, [string]$Label, [int]$Width = 40)
    $pct    = if ($Total -gt 0) { [math]::Round(($Current / $Total) * 100) } else { 0 }
    $filled = [math]::Round(($pct / 100) * $Width)
    $empty  = $Width - $filled
    $bar    = ('#' * $filled) + ('-' * $empty)
    c "`r  [" DarkGray; c $bar Cyan; c '] ' DarkGray
    c ("{0,3}%" -f $pct) Yellow
    c "  $Label" White
    if ($Current -ge $Total) { nl }
}

# ==============================================================================
# AV MANAGEMENT
# ==============================================================================
function Suspend-AVProtection {
    param([PSCustomObject]$sysEnv)
    if ($sysEnv.SophosRunning) {
        try {
            cn '  [AV] Pausing Sophos...' DarkYellow
            Stop-Service 'Sophos Anti-Virus','SAVService' -Force -EA SilentlyContinue
            return $true
        } catch {}
    }
    return $false
}

function Resume-AVProtection {
    param([bool]$wasPaused)
    if ($wasPaused) {
        try {
            cn '  [AV] Resuming Sophos...' DarkYellow
            Start-Service 'SAVService','Sophos Anti-Virus' -EA SilentlyContinue
        } catch {}
    }
}

# ==============================================================================
# INSTALL ENGINE
# ==============================================================================
function Install-Package {
    param([PSCustomObject]$pkg, [PSCustomObject]$sysEnv, [switch]$Force)

    $result = [PSCustomObject]@{
        ID            = $pkg.ID
        Name          = $pkg.Name
        Category      = $pkg.Category
        Status        = 'Pending'
        ExitCode      = $null
        InstallerUsed = $null
        TimeSec       = 0
        Message       = ''
        Verified      = $false
    }

    if (-not $Force -and (Test-PackageInstalled $pkg)) {
        $ver            = Get-InstalledVersion $pkg
        $result.Status  = 'AlreadyInstalled'
        $result.Message = "v$ver already installed"
        $result.Verified= $true
        return $result
    }

    $installer = Find-Installer $pkg
    if (-not $installer) {
        $result.Status  = 'NoFile'
        $result.Message = 'Not on USB -- use [D] to download'
        return $result
    }

    if ($sysEnv.FreeGB -lt $pkg.MinDiskGB) {
        $result.Status  = 'InsufficientDisk'
        $result.Message = "Need $($pkg.MinDiskGB) GB, have $($sysEnv.FreeGB) GB"
        return $result
    }

    $result.InstallerUsed = $installer
    $avPaused  = Suspend-AVProtection -sysEnv $sysEnv
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $logFile = Join-Path $logRoot ("install_$($pkg.ID)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log")

        if ($pkg.InstallerType -eq 'MSI') {
            $msiArgs = "/i `"$installer`" $($pkg.SilentArgs) /log `"$logFile`""
            $proc    = Start-Process 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -WindowStyle Hidden
        } else {
            $proc = Start-Process $installer -ArgumentList $pkg.SilentArgs -Wait -PassThru -WindowStyle Hidden
        }

        $stopwatch.Stop()
        $result.ExitCode = $proc.ExitCode
        $result.TimeSec  = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)

        if ($result.ExitCode -in @(0, 3010, 1641)) {
            $result.Status  = if ($result.ExitCode -in @(3010,1641)) { 'SuccessRebootNeeded' } else { 'Success' }
        } else {
            $result.Status  = 'Failed'
            $result.Message = "Exit code: $($result.ExitCode)"
        }
    } catch {
        $stopwatch.Stop()
        $result.Status  = 'Error'
        $result.Message = $_.Exception.Message
        $result.TimeSec = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    } finally {
        Resume-AVProtection -wasPaused $avPaused
    }

    Start-Sleep -Seconds 2
    $result.Verified = Test-PackageInstalled $pkg

    if ($result.Status -eq 'Success' -and -not $result.Verified) {
        $result.Status  = 'UnverifiedInstall'
        $result.Message = 'Exit 0 but detection failed -- check manually'
    }

    if ($result.Verified -and $pkg.PostActionID) {
        Invoke-PostAction -ActionID $pkg.PostActionID
    }

    return $result
}

# ==============================================================================
# REPORT GENERATOR
# ==============================================================================
function New-DeploymentReport {
    param([array]$Results, [PSCustomObject]$SysEnv)
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $hn = $SysEnv.Hostname

    $jsonPath = Join-Path $logRoot "${ts}_${hn}_SoftwareDeploy.json"
    [PSCustomObject]@{
        GeneratedAt = $SysEnv.Timestamp; Hostname = $hn
        OS = $SysEnv.OS; AAD = $SysEnv.AADStatus
        FreeGB = $SysEnv.FreeGB; Results = $Results
    } | ConvertTo-Json -Depth 10 | Out-File $jsonPath -Encoding UTF8 -Force

    $htmlPath = Join-Path $reportRoot "${ts}_${hn}_DeployReport.html"
    $rows = $Results | ForEach-Object {
        $color = switch ($_.Status) {
            'Success'             { '#00cc44' }
            'SuccessRebootNeeded' { '#ffaa00' }
            'AlreadyInstalled'    { '#4488ff' }
            'NoFile'              { '#888888' }
            'Failed'              { '#ff4444' }
            default               { '#aaaaaa' }
        }
        $tsec = "$($_.TimeSec)s"
        "<tr><td>$($_.Name)</td><td style='color:$color;font-weight:bold'>$($_.Status)</td>
         <td style='color:#aaa'>$($_.Message)</td>
         <td style='text-align:center'>$(if($_.Verified){'OK'}else{'--'})</td>
         <td style='color:#aaa'>$tsec</td></tr>"
    }
    @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>FieldOps Pro Deploy Report</title>
<style>body{background:#0d0d0d;color:#e0e0e0;font-family:Consolas,monospace;padding:20px}
h1{color:#00ccff;border-bottom:2px solid #00ccff;padding-bottom:10px}
table{width:100%;border-collapse:collapse;margin-top:20px}
th{background:#1a1a2e;color:#00ccff;padding:10px;text-align:left}
td{padding:8px;border-bottom:1px solid #222}
.meta{background:#111;border:1px solid #333;padding:15px;border-radius:4px;margin-bottom:20px}
.meta span{color:#00ccff}</style></head><body>
<h1>FIELDOPS PRO v4.0 -- DEPLOYMENT REPORT</h1>
<div class='meta'>
<span>Host:</span> $hn &nbsp;<span>Date:</span> $($SysEnv.Timestamp) &nbsp;
<span>OS:</span> $($SysEnv.OS) &nbsp;<span>AAD:</span> $($SysEnv.AADStatus) &nbsp;
<span>Free C:</span> $($SysEnv.FreeGB) GB</div>
<table><tr><th>Application</th><th>Status</th><th>Message</th><th>Verified</th><th>Time</th></tr>
$($rows -join "`n")</table>
<p style='color:#444;font-size:12px;text-align:center;margin-top:30px'>FieldOps Pro v4.0</p>
</body></html>
"@ | Out-File $htmlPath -Encoding UTF8 -Force

    return [PSCustomObject]@{ JSON = $jsonPath; HTML = $htmlPath }
}

# ==============================================================================
# PRE-FLIGHT DISPLAY
# ==============================================================================
function Show-PreFlight {
    param([PSCustomObject]$sysEnv)
    Clear-Host; nl
    cn '  +--------------------------------------------------------------------------+' Cyan
    cn '  |   FIELDOPS PRO -- SOFTWARE DEPLOYMENT ENGINE v4.0                       |' Cyan
    cn '  +--------------------------------------------------------------------------+' Cyan

    $at  = if ($sysEnv.IsAdmin)       { 'Administrator [OK]' }          else { 'NOT ADMIN -- installs may fail' }
    $ac  = if ($sysEnv.IsAdmin)       { 'Green' } else { 'Red' }
    $dc  = if ($sysEnv.FreeGB -gt 5)  { 'Green' } elseif ($sysEnv.FreeGB -gt 2) { 'Yellow' } else { 'Red' }
    $rc  = if ($sysEnv.PendingReboot) { 'Red' }   else { 'Green' }
    $rt  = if ($sysEnv.PendingReboot) { 'PENDING REBOOT -- reboot first' } else { 'No pending reboot [OK]' }
    $aac = if ($sysEnv.AADStatus -eq 'Azure AD Joined') { 'Green' } else { 'Yellow' }
    $ic  = if ($sysEnv.HasInternet)   { 'Green' } else { 'Red' }
    $it  = if ($sysEnv.HasInternet)   { 'Connected -- auto-download available [OK]' } else { 'OFFLINE -- auto-download unavailable' }

    c '  | Privileges:   ' DarkGray; cn $at $ac
    c '  | Free Disk C:  ' DarkGray; cn "$($sysEnv.FreeGB) GB" $dc
    c '  | Reboot:       ' DarkGray; cn $rt $rc
    c '  | Azure AD:     ' DarkGray; cn $sysEnv.AADStatus $aac
    c '  | Internet:     ' DarkGray; cn $it $ic
    c '  | USB Free:     ' DarkGray; cn "$($sysEnv.UsbFreeGB) GB on USB" DarkGray
    c '  | Time:         ' DarkGray; cn $sysEnv.Timestamp DarkGray
    cn '  +--------------------------------------------------------------------------+' Cyan
    nl
}

# ==============================================================================
# PACKAGE MENU
# ==============================================================================
function Show-PackageMenu {
    param([array]$packages, [PSCustomObject]$sysEnv)
    nl
    cn '  +----+--------------------------------+------------+----------+---------------+' Cyan
    cn '  |  # | Application                    | Category   | File     | Status        |' DarkCyan
    cn '  +----+--------------------------------+------------+----------+---------------+' Cyan

    $i   = 1
    $map = @{}

    foreach ($pkg in ($packages | Sort-Object Priority)) {
        $installer = Find-Installer $pkg
        $installed = Test-PackageInstalled $pkg
        $dlStatus  = Get-DownloadStatus -pkg $pkg -sysEnv $sysEnv

        $fileStr = if ($installer) { '  OK      ' } else {
            if ($dlStatus.CanDownload) { ' DL AVAIL ' }
            elseif ($dlStatus.CanOpenPage) { ' WEB PAGE ' }
            else { '  MISSING  ' }
        }
        $fileCol = if ($installer) { 'Green' } elseif ($dlStatus.CanDownload -or $dlStatus.CanOpenPage) { 'Yellow' } else { 'DarkGray' }
        $instStr = if ($installed) { 'INSTALLED    ' } else { 'NOT INSTALLED' }
        $instCol = if ($installed) { 'Cyan' } elseif ($installer) { 'White' } else { 'DarkGray' }

        c  '  | '  Cyan
        c  (' {0,-2}' -f $i) Yellow
        c  ' | '    Cyan
        c  (' {0,-30}' -f $pkg.Name) White
        c  ' | '    Cyan
        c  (' {0,-10}' -f $pkg.Category) DarkCyan
        c  ' | '    Cyan
        c  $fileStr $fileCol
        c  ' | '    Cyan
        cn $instStr $instCol

        $map[$i.ToString()] = $pkg
        $i++
    }

    cn '  +----+--------------------------------+------------+----------+---------------+' Cyan
    nl
    c '  | '; c '[A]' Green;    cn ' Install ALL packages available on USB                        |' White
    c '  | '; c '[M]' Yellow;   cn ' Install MISSING only (skip installed)                        |' White
    c '  | '; c '[F]' Red;      cn ' Force reinstall ALL (ignore detection)                       |' White
    c '  | '; c '[D]' Cyan;     cn ' Download missing packages (auto or browser)                  |' White
    c '  | '; c '[U]' Magenta;  cn ' Uninstall a package                                          |' White
    c '  | '; c '[R]' DarkGray; cn ' Refresh / rescan everything                                  |' White
    c '  | '; c '[Q]' Red;      cn ' Return to main menu                                          |' White
    cn '  +--------------------------------------------------------------------------+' Cyan
    nl
    c '  Select option: ' DarkGray

    return $map
}

# ==============================================================================
# DOWNLOAD MENU
# ==============================================================================
function Show-DownloadMenu {
    param([array]$packages, [PSCustomObject]$sysEnv)
    Clear-Host; nl
    cn '  +--------------------------------------------------------------------------+' Cyan
    cn '  |   DOWNLOAD CENTER -- Get missing installers directly to USB              |' Cyan
    cn '  +--------------------------------------------------------------------------+' Cyan
    nl

    if (-not $sysEnv.HasInternet) {
        cn '  [X] No internet connection detected.' Red
        cn '      Connect to internet then press [R] to rescan.' DarkGray
        nl; cn '  Press any key...' DarkGray
        $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return
    }

    $missing = $packages | Where-Object { $null -eq (Find-Installer $_) } | Sort-Object Priority
    if ($missing.Count -eq 0) {
        cn '  [OK] All registered packages have installers on the USB.' Green
        nl; cn '  Press any key...' DarkGray
        $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return
    }

    $i   = 1
    $map = @{}
    foreach ($pkg in $missing) {
        $dl = Get-DownloadStatus -pkg $pkg -sysEnv $sysEnv
        c "  [$i] " Yellow
        c (' {0,-28}' -f $pkg.Name) White
        if ($dl.CanDownload) {
            c '  [AUTO-DL]  ' Green
            cn "Direct download available" DarkGray
        } elseif ($dl.CanOpenPage) {
            c '  [BROWSER]  ' Yellow
            cn "Opens official download page" DarkGray
        } else {
            c '  [MANUAL]   ' DarkGray
            cn "No download configured" DarkGray
        }
        $map[$i.ToString()] = $pkg
        $i++
    }

    nl
    cn "  [A]  Download / open ALL missing packages" Cyan
    cn "  [Q]  Back" DarkGray
    nl
    c '  Choice: ' DarkGray
    $choice = (Read-Host).Trim().ToUpper()

    if ($choice -eq 'Q') { return }

    $toDownload = if ($choice -eq 'A') { $missing } elseif ($map.ContainsKey($choice)) { @($map[$choice]) } else { @() }

    foreach ($pkg in $toDownload) {
        nl
        c '  Package: ' DarkGray; cn $pkg.Name Cyan
        $dl = Get-DownloadStatus -pkg $pkg -sysEnv $sysEnv
        if ($dl.CanDownload) {
            $downloaded = Invoke-DirectDownload -pkg $pkg -sysEnv $sysEnv
            if ($downloaded) {
                cn "  [>] Ready to install. Go back and press [M] to install." Green
            }
        } elseif ($dl.CanOpenPage) {
            Invoke-OpenDownloadPage -pkg $pkg
        } else {
            cn "  [!] No download method available." DarkGray
        }
        nl
    }

    sep; cn '  Press any key to return...' DarkGray
    $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ==============================================================================
# RESULT DISPLAY
# ==============================================================================
function Show-InstallResult {
    param([PSCustomObject]$result)
    $icon  = switch ($result.Status) {
        'Success'             { '[OK]     ' }
        'SuccessRebootNeeded' { '[REBOOT] ' }
        'AlreadyInstalled'    { '[SKIP]   ' }
        'NoFile'              { '[NO FILE]' }
        'Failed'              { '[FAIL]   ' }
        'Error'               { '[ERROR]  ' }
        default               { '[?]      ' }
    }
    $color = switch ($result.Status) {
        'Success'             { 'Green' }
        'SuccessRebootNeeded' { 'Yellow' }
        'AlreadyInstalled'    { 'Cyan' }
        'NoFile'              { 'DarkGray' }
        'Failed'              { 'Red' }
        'Error'               { 'Red' }
        default               { 'Gray' }
    }
    c ('  {0}' -f $icon) $color
    c (' {0,-28}' -f $result.Name) White
    c (' {0,-22}' -f $result.Status) $color
    c $result.Message DarkGray
    if ($result.TimeSec -gt 0) { c "  ($($result.TimeSec)s)" DarkGray }
    nl
}

# ==============================================================================
# BATCH INSTALL
# ==============================================================================
function Invoke-BatchInstall {
    param([array]$pkgList, [PSCustomObject]$sysEnv, [switch]$Force)
    $results = [System.Collections.ArrayList]@()
    $total   = $pkgList.Count
    $current = 0
    nl; cn '  Installing...' DarkGray; sep; nl

    foreach ($pkg in ($pkgList | Sort-Object Priority)) {
        $current++
        Show-ProgressBar -Current $current -Total $total -Label "[$current/$total] $($pkg.Name)..."
        $r = Install-Package -pkg $pkg -sysEnv $sysEnv -Force:$Force
        Show-InstallResult -result $r
        [void]$results.Add($r)
    }

    nl; sep
    $ok     = ($results | Where-Object { $_.Status -in @('Success','SuccessRebootNeeded','AlreadyInstalled') }).Count
    $fail   = ($results | Where-Object { $_.Status -in @('Failed','Error','UnverifiedInstall') }).Count
    $nofile = ($results | Where-Object { $_.Status -eq 'NoFile' }).Count
    $reboot = ($results | Where-Object { $_.Status -eq 'SuccessRebootNeeded' }).Count
    nl
    c '  SUMMARY:  ' DarkGray; c "$ok OK  " Green
    if ($fail   -gt 0) { c "$fail FAILED  " Red }
    if ($nofile -gt 0) { c "$nofile NO FILE  " DarkGray }
    if ($reboot -gt 0) { c "($reboot need reboot)" Yellow }
    nl
    return $results.ToArray()
}

# ==============================================================================
# UNINSTALL MENU
# ==============================================================================
function Invoke-UninstallMenu {
    param([array]$packages)
    Clear-Host; nl
    cn '  UNINSTALL:' Yellow; nl
    $installed = $packages | Where-Object { Test-PackageInstalled $_ } | Sort-Object Priority
    if ($installed.Count -eq 0) {
        cn '  No registered packages detected as installed.' DarkGray
        nl; cn '  Press any key...' DarkGray
        $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return
    }
    $i = 1; $map = @{}
    foreach ($pkg in $installed) {
        c "  [$i] " Yellow; cn $pkg.Name White
        $map[$i.ToString()] = $pkg; $i++
    }
    nl; c '  Package number (or Q): ' DarkGray
    $choice = (Read-Host).Trim()
    if ($choice.ToUpper() -eq 'Q') { return }
    if ($map.ContainsKey($choice)) {
        $pkg = $map[$choice]
        cn "  Uninstalling $($pkg.Name)..." Yellow
        try {
            if ($pkg.InstallerType -eq 'MSI') {
                $ins = Find-Installer $pkg
                if ($ins) { Start-Process 'msiexec.exe' -ArgumentList "/x `"$ins`" /qn /norestart" -Wait -WindowStyle Hidden }
            } else {
                $unStr = (Get-ItemProperty $pkg.DetectKey -EA SilentlyContinue).UninstallString
                if ($unStr) { Start-Process 'cmd.exe' -ArgumentList "/c $unStr /S /silent" -Wait -WindowStyle Hidden }
                else { cn '  [!] No uninstall string. Manual removal required.' Red }
            }
            if (-not (Test-PackageInstalled $pkg)) { cn '  Removed [OK]' Green }
            else { cn '  Still detected -- may need manual removal.' Yellow }
        } catch { cn "  [X] Error: $_" Red }
    }
    nl; cn '  Press any key...' DarkGray
    $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================
foreach ($dir in @($logRoot, $reportRoot)) {
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
}

$sysEnv   = Get-Environment
$packages = Get-PackageRegistry

Show-PreFlight -sysEnv $sysEnv

while ($true) {
    $pkgMap = Show-PackageMenu -packages $packages -sysEnv $sysEnv
    $choice = (Read-Host).Trim().ToUpper()

    switch ($choice) {
        'Q' { return }
        'R' { $sysEnv = Get-Environment; $packages = Get-PackageRegistry }

        'D' { Show-DownloadMenu -packages $packages -sysEnv $sysEnv }

        'A' {
            $toInstall = $packages | Where-Object { $null -ne (Find-Installer $_) }
            $results   = Invoke-BatchInstall -pkgList $toInstall -sysEnv $sysEnv
            $report    = New-DeploymentReport -Results $results -SysEnv $sysEnv
            nl; cn "  Report: $($report.HTML)" DarkGray
            nl; cn '  Press any key...' DarkGray
            $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
        'M' {
            $toInstall = $packages | Where-Object { $null -ne (Find-Installer $_) -and -not (Test-PackageInstalled $_) }
            if ($toInstall.Count -eq 0) { nl; cn '  All available packages already installed.' Cyan; Start-Sleep 2 }
            else {
                $results = Invoke-BatchInstall -pkgList $toInstall -sysEnv $sysEnv
                $report  = New-DeploymentReport -Results $results -SysEnv $sysEnv
                nl; cn "  Report: $($report.HTML)" DarkGray
                nl; cn '  Press any key...' DarkGray
                $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            }
        }
        'F' {
            cn '  Force reinstall all available? (Y/N): ' Yellow
            if ((Read-Host).Trim().ToUpper() -eq 'Y') {
                $toInstall = $packages | Where-Object { $null -ne (Find-Installer $_) }
                $results   = Invoke-BatchInstall -pkgList $toInstall -sysEnv $sysEnv -Force
                $report    = New-DeploymentReport -Results $results -SysEnv $sysEnv
                nl; cn "  Report: $($report.HTML)" DarkGray
                nl; cn '  Press any key...' DarkGray
                $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            }
        }
        'U' { Invoke-UninstallMenu -packages $packages }

        default {
            if ($pkgMap.ContainsKey($choice)) {
                $pkg = $pkgMap[$choice]
                Clear-Host; nl
                c '  Installing: ' Cyan; cn $pkg.Name Yellow; nl
                $r = Install-Package -pkg $pkg -sysEnv $sysEnv
                Show-InstallResult -result $r
                New-DeploymentReport -Results @($r) -SysEnv $sysEnv | Out-Null
                nl; cn '  Press any key...' DarkGray
                $null = $HOST.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            } else {
                cn '  [!] Invalid option.' Red; Start-Sleep 1
            }
        }
    }
}
