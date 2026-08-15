#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro -- Unified Operations Dashboard v3.1
.DESCRIPTION
    Bulletproof rewrite. Every data collector is isolated in its own
    try/catch and returns a safe default on failure. The HTML renderer
    only reads from a pre-validated $state object and cannot crash due
    to missing/empty/null data.

    Architecture:
        PHASE 1 - Safety helpers (Get-SafeSize / Get-SafeProp / Invoke-SafeGather)
        PHASE 2 - Gather all data into $state
        PHASE 3 - Render HTML from $state
        PHASE 4 - Report any gather failures as a visible banner

.PARAMETER OpenDashboard
    Open the generated dashboard in the default browser.
.PARAMETER NoProtocol
    Disable fieldops:// links (force click-to-copy mode).
#>
[CmdletBinding()]
param(
    [switch]$OpenDashboard,
    [switch]$NoProtocol,
    [string]$Language = ''
)

# CRITICAL: never set StrictMode here. PS 5.1 StrictMode treats $null.Property
# as a fatal error; our safety layer is built on the assumption that PS's
# default lenient mode is in use. Callers can still set strict mode in their
# own shell; this script only affects its own scope.
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# ==============================================================
# PHASE 1 -- SAFETY LAYER
# ==============================================================

# Collected gather errors -- rendered as a banner at the bottom of the dashboard
$script:gatherErrors = [System.Collections.Generic.List[string]]::new()

function Invoke-SafeGather {
    <#
    .SYNOPSIS
        Run a data-gathering scriptblock with a safety net.
        On ANY failure (exception, strict-mode violation, null deref)
        returns $Default and logs the failure to $script:gatherErrors.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Block,
        $Default = $null
    )
    try {
        $result = & $Block
        if ($null -eq $result) { return $Default }
        return $result
    } catch {
        $msg = "$Name : $($_.Exception.Message)"
        $script:gatherErrors.Add($msg) | Out-Null
        Write-Host "    [WARN] $Name failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $Default
    }
}

function Get-SafeSize {
    # Returns the total size (bytes) of a collection. Handles $null, empty
    # arrays, and mixed object types. Never throws.
    param($Items)
    if ($null -eq $Items) { return [int64]0 }
    $arr = @($Items)
    if ($arr.Count -eq 0) { return [int64]0 }
    $total = [int64]0
    foreach ($it in $arr) {
        if ($null -eq $it) { continue }
        try {
            $len = $it.Length
            if ($null -ne $len) { $total += [int64]$len }
        } catch { }
    }
    return $total
}

function Get-SafeCount {
    # Returns .Count safely: 0 for $null or non-collections, actual count otherwise.
    param($Items)
    if ($null -eq $Items) { return 0 }
    if ($Items -is [array]) { return $Items.Count }
    try { return @($Items).Count } catch { return 0 }
}

function Get-SafeProp {
    # Returns an object property or $Default if missing/null/error.
    param($Object, [string]$PropName, $Default = '')
    if ($null -eq $Object) { return $Default }
    try {
        $v = $Object.$PropName
        if ($null -eq $v) { return $Default }
        $s = "$v".Trim()
        if ($s -eq '') { return $Default }
        return $v
    } catch { return $Default }
}

function Get-SafeString {
    # Same as Get-SafeProp but always returns a string.
    param($Object, [string]$PropName, [string]$Default = '')
    $v = Get-SafeProp $Object $PropName $Default
    return "$v"
}

function Format-Size {
    # Formats a byte count as human-readable with safe fallback.
    param([int64]$Bytes, [string]$Unit = 'Auto')
    if ($Bytes -le 0) { return '0' }
    switch ($Unit) {
        'MB' { return "$([math]::Round($Bytes / 1MB, 1)) MB" }
        'GB' { return "$([math]::Round($Bytes / 1GB, 2)) GB" }
        'KB' { return "$([math]::Round($Bytes / 1KB, 1)) KB" }
        default {
            if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB, 2)) GB" }
            if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 1)) MB" }
            return "$([math]::Round($Bytes / 1KB, 1)) KB"
        }
    }
}

function Escape-Html {
    param([string]$Text)
    if ($null -eq $Text -or $Text -eq '') { return '' }
    return $Text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
}

# ==============================================================
# PATHS & CONSTANTS
# ==============================================================
$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsDir   = Split-Path -Parent $scriptDir
$usbRoot      = Split-Path -Parent $scriptsDir
$reportsDir   = Join-Path $usbRoot 'REPORTS'
$snapshotDir  = Join-Path $reportsDir 'Snapshots'
$configDir    = Join-Path $usbRoot 'CONFIG'
$playbooksDir = Join-Path $usbRoot 'PLAYBOOKS'
$isoDir       = Join-Path $usbRoot 'ISO'
$driversDir   = Join-Path $usbRoot 'DRIVERS'
$toolsDir     = Join-Path $usbRoot 'TOOLS'
$docsDir      = Join-Path $usbRoot 'DOCS'

$VERSION  = '3.2'
$NOW      = Get-Date
$HOSTNAME = $env:COMPUTERNAME

# ==============================================================
# LOCALIZATION -- load FieldOps-Locale module if present
# ==============================================================
# Graceful degradation: if the locale module isn't installed, we fall back
# to hardcoded English strings via the Get-Default function.
$script:LocaleLoaded = $false
$script:CurrentLocale = 'en'

$localeModule = Join-Path $scriptDir 'FieldOps-Locale.psm1'
if (Test-Path $localeModule) {
    try {
        Import-Module $localeModule -Force -ErrorAction Stop
        $script:CurrentLocale = Initialize-Locale -Language $Language -ConfigDir $configDir
        $script:LocaleLoaded = $true
    } catch {
        Write-Host "  [WARN] Locale module failed to load: $_" -ForegroundColor Yellow
    }
}

# T() = Translate shortcut. Returns localized string if module loaded,
# otherwise returns the provided default. Every string in the dashboard
# goes through this function so the script works with or without locale files.
function T {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Default,
        [hashtable]$Vars = @{}
    )
    if ($script:LocaleLoaded) {
        $s = Get-LocaleString -Key $Key -Vars $Vars -Default $Default
        if ($s -and $s -ne $Key) { return $s }
    }
    # Manual variable substitution for the Default fallback
    $out = $Default
    if ($Vars.Count -gt 0) {
        foreach ($vk in $Vars.Keys) {
            $out = $out -replace "\{$vk\}", "$($Vars[$vk])"
        }
    }
    return $out
}

# Detect protocol handler registration
$protocolRegistered = $false
if (-not $NoProtocol) {
    $protocolRegistered = Invoke-SafeGather 'Protocol Check' {
        Test-Path 'HKLM:\SOFTWARE\Classes\fieldops' -ErrorAction SilentlyContinue
    } -Default $false
}

# Detect elevation -- several collectors (SecureBoot, BitLocker) require admin
$isElevated = $false
try {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [System.Security.Principal.WindowsPrincipal]::new($id)
    $isElevated = $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# ==============================================================
# PHASE 2 -- GATHER ALL DATA INTO $state
# ==============================================================
$state = [ordered]@{
    Config        = $null
    Sys           = $null
    Engines       = [ordered]@{}
    MasterReport  = $null
    AllReports    = @()
    AllSnapshots  = @()
    SnapTotalMB   = 0
    FleetHosts    = @()
    AllTools      = @()
    ToolsByFolder = @{}
    Playbooks     = $null
    ISOs          = @()
    IsoTotalGB    = 0
    Drivers       = @()
    DriverTotalMB = 0
    PortableTools = $null
    DocsCount     = 0
}

Write-Host ''
Write-Host "  FIELDOPS PRO -- $(T 'dashboard.generating' 'GENERATING UNIFIED DASHBOARD') v$VERSION" -ForegroundColor Cyan
if ($script:LocaleLoaded) {
    Write-Host "    Locale     : $script:CurrentLocale" -ForegroundColor DarkGray
}
Write-Host ''
$protoLabel = if ($protocolRegistered) {
    T 'dashboard.protocolRegistered' 'REGISTERED (fieldops://)'
} else {
    T 'dashboard.protocolNotRegistered' 'NOT REGISTERED (click-to-copy)'
}
Write-Host "    Protocol   : $protoLabel" -ForegroundColor $(if($protocolRegistered){'Green'}else{'Yellow'})

# --- Config ---
$state.Config = Invoke-SafeGather 'Config Load' {
    $techName = if ($env:USERNAME) { $env:USERNAME } else { 'Field Technician' }
    $orgName  = 'FieldOps Pro'
    $brand    = '#06b6d4'

    $candidates = @(
        (Join-Path $configDir 'technician.json'),
        (Join-Path $configDir 'FieldOps.config.json')
    )
    $cfgFile = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($cfgFile) {
        $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($f in @('TechnicianName','Technician','TechName','Name','FullName')) {
            $v = Get-SafeProp $cfg $f ''; if ("$v" -ne '') { $techName = "$v".Trim(); break }
        }
        foreach ($f in @('OrgName','Organisation','Organization','Company')) {
            $v = Get-SafeProp $cfg $f ''; if ("$v" -ne '') { $orgName = "$v".Trim(); break }
        }
        foreach ($f in @('BrandColor','Color')) {
            $v = Get-SafeProp $cfg $f ''; if ("$v" -ne '') { $brand = "$v".Trim(); break }
        }
    }
    return [PSCustomObject]@{ TechName = $techName; OrgName = $orgName; Brand = $brand }
} -Default ([PSCustomObject]@{ TechName = $env:USERNAME; OrgName = 'FieldOps Pro'; Brand = '#06b6d4' })

# --- System Info (every sub-collector isolated) ---
Write-Host ("    " + (T 'dashboard.gatheringSysInfo' 'Gathering system info...')) -ForegroundColor DarkGray

$sys = [ordered]@{
    Hostname=$HOSTNAME; Model='Unknown'; Manufacturer=''; Serial='N/A'; BIOS=''
    OS=''; OSBuild=''; CPU=''; Cores=''; RAM=''
    IPAddress=''; MACAddress=''; Domain=''; JoinStatus=''
    Uptime=''; LastBoot=''; BitLocker=''; TPM=''; SecureBoot=''
}

# OS
$osData = Invoke-SafeGather 'OS Info' { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
if ($osData) {
    $sys.OS      = Get-SafeString $osData 'Caption'
    $sys.OSBuild = Get-SafeString $osData 'Version'
    $boot = Get-SafeProp $osData 'LastBootUpTime' $null
    if ($boot) {
        $sys.LastBoot = $boot.ToString('yyyy-MM-dd HH:mm')
        $up = $NOW - $boot
        $sys.Uptime = "$([math]::Floor($up.TotalDays))d $($up.Hours)h"
    }
}

# Computer System
$csData = Invoke-SafeGather 'Computer System' { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
if ($csData) {
    $sys.Model        = Get-SafeString $csData 'Model' 'Unknown'
    $sys.Manufacturer = Get-SafeString $csData 'Manufacturer'
    $mem = Get-SafeProp $csData 'TotalPhysicalMemory' 0
    if ($mem -gt 0) { $sys.RAM = "$([math]::Round($mem / 1GB, 1)) GB" }
    $pod = Get-SafeProp $csData 'PartOfDomain' $false
    $sys.Domain = if ($pod) { Get-SafeString $csData 'Domain' } else { 'Workgroup' }
}

# Serial with 3-level fallback
$biosData = Invoke-SafeGather 'BIOS' { Get-CimInstance Win32_BIOS -ErrorAction Stop }
if ($biosData) {
    $sys.BIOS = Get-SafeString $biosData 'SMBIOSBIOSVersion'
    $sn = Get-SafeString $biosData 'SerialNumber'
    if ($sn -ne '' -and $sn -notmatch 'To Be Filled|System Serial|Default|None') { $sys.Serial = $sn }
}
if ($sys.Serial -eq 'N/A') {
    $encData = Invoke-SafeGather 'SystemEnclosure' { Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop }
    if ($encData) {
        $sn = Get-SafeString $encData 'SerialNumber'
        if ($sn -ne '' -and $sn -notmatch 'None|Default') { $sys.Serial = $sn }
    }
}
if ($sys.Serial -eq 'N/A') {
    $bbData = Invoke-SafeGather 'BaseBoard' { Get-CimInstance Win32_BaseBoard -ErrorAction Stop }
    if ($bbData) {
        $sn = Get-SafeString $bbData 'SerialNumber'
        if ($sn -ne '') { $sys.Serial = "MB:$sn" }
    }
}

# CPU
$cpuData = Invoke-SafeGather 'CPU' { Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 }
if ($cpuData) {
    $name = Get-SafeString $cpuData 'Name'
    if ($name) { $sys.CPU = $name.Trim() }
    $nc = Get-SafeProp $cpuData 'NumberOfCores' 0
    $nl = Get-SafeProp $cpuData 'NumberOfLogicalProcessors' 0
    if ($nc -gt 0) { $sys.Cores = "$($nc)C/$($nl)T" }
}

# Network IP
$sys.IPAddress = Invoke-SafeGather 'IP Address' {
    $nic = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
           Where-Object { $_.IPAddress -notmatch '^127\.|^169\.254' -and $_.PrefixOrigin -ne 'WellKnown' } |
           Select-Object -First 1
    if ($nic) { return "$($nic.IPAddress)" }
    return ''
} -Default ''

# MAC Address
$sys.MACAddress = Invoke-SafeGather 'MAC Address' {
    $mac = Get-NetAdapter -ErrorAction Stop |
           Where-Object { $_.Status -eq 'Up' -and $_.MacAddress } |
           Select-Object -First 1
    if ($mac) { return "$($mac.MacAddress)" }
    return ''
} -Default ''

# Join Status
$sys.JoinStatus = Invoke-SafeGather 'Join Status' {
    $ds = dsregcmd /status 2>$null
    if (-not $ds) { return 'Unknown' }
    if ($ds | Select-String 'AzureAdJoined\s*:\s*YES') { return 'Azure AD Joined' }
    if ($ds | Select-String 'DomainJoined\s*:\s*YES') { return 'Domain Joined' }
    if ($ds | Select-String 'WorkplaceJoined\s*:\s*YES') { return 'Workplace Joined' }
    return 'Not Joined'
} -Default 'Unknown'

# TPM
$sys.TPM = Invoke-SafeGather 'TPM' {
    $tpm = Get-Tpm -ErrorAction Stop
    if ($null -eq $tpm) { return 'N/A' }
    $present = Get-SafeProp $tpm 'TpmPresent' $false
    $ready   = Get-SafeProp $tpm 'TpmReady' $false
    if ($present -and $ready) { return 'Ready' }
    if ($present) { return 'Present (Not Ready)' }
    return 'Absent'
} -Default 'N/A'

# Secure Boot -- requires admin. Access-denied is a KNOWN state, not a failure.
# We catch manually here so it doesn't register in $gatherErrors as a real problem.
$lblAdminReq = T 'common.adminRequired' 'Admin required'
$lblNA       = T 'common.notAvailable'  'N/A'
$lblEnabled  = T 'common.enabled'       'Enabled'
$lblDisabled = T 'common.disabled'      'Disabled'

$sys.SecureBoot = try {
    if (Confirm-SecureBootUEFI -ErrorAction Stop) { $lblEnabled } else { $lblDisabled }
} catch {
    if ("$_" -match 'Acc.s refus|Access.*denied|privileges') { $lblAdminReq }
    else { $lblNA }
}

# BitLocker -- same story, admin required for the C: volume query
$sys.BitLocker = try {
    $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    if ($null -eq $bl) { $lblNA }
    else {
        $prot = Get-SafeProp $bl 'ProtectionStatus' 'Unknown'
        $enc  = Get-SafeProp $bl 'EncryptionMethod' 'Unknown'
        "$prot ($enc)"
    }
} catch {
    if ("$_" -match 'Acc.s refus|Access.*denied|privileges') { $lblAdminReq }
    else { $lblNA }
}

$state.Sys = $sys
Write-Host "    $($sys.Hostname) | $($sys.Manufacturer) $($sys.Model) | SN:$($sys.Serial)" -ForegroundColor DarkGray

# --- Report Scanner with bulletproof grade extraction ---
Write-Host ("    " + (T 'dashboard.scanningReports' 'Scanning reports...')) -ForegroundColor DarkGray

function Get-LatestReport {
    param([string]$Pattern)
    return Invoke-SafeGather "Scan $Pattern" {
        $files = @(Get-ChildItem -Path $reportsDir -Filter $Pattern -ErrorAction Stop |
                   Sort-Object LastWriteTime -Descending)
        if ($files.Count -eq 0) { return $null }
        $f = $files[0]
        $grade = '--'; $score = 0

        # v3.1.2 EXTRACTION based on diagnostic of ACTUAL report formats:
        #
        # DiskAnalysis  : "A Disk Health Score: 93%"
        # NetRepair     : "A+ Network Health: 98%"
        # SecurityScan  : "B Security Score: 79%"  (also "B (79%)" in summary)
        # AzureADJoin   : "B+ Enrollment: 83%"
        # FieldOps_Mstr : "A- Unified: 85%" OR "Grade: A- (85%)"
        # ComplianceDiff: IMPROVED|DEGRADED|NEUTRAL|SUSPICIOUS (no letter grade)
        # PCHealth      : uses CSS class .grade.healthy / .grade.warning /
        #                 .grade.critical rather than a letter grade
        try {
            $whole = Get-Content -Path $f.FullName -Raw -ErrorAction Stop

            # --- PCHealth special-case: derive grade from CSS class ---
            # Look for <div class="grade healthy"> or similar -- inspect the
            # RAW HTML (not stripped) to catch the class attribute
            if ($Pattern -like 'PCHealth_*') {
                # Try to find the specific class used on the grade element.
                # The report has: .grade.healthy = green, .warning = amber, .critical = red
                if ($whole -match 'class="[^"]*\bgrade[^"]*\bhealthy\b[^"]*"') {
                    $grade = 'A'
                } elseif ($whole -match 'class="[^"]*\bgrade[^"]*\bwarning\b[^"]*"') {
                    $grade = 'C'
                } elseif ($whole -match 'class="[^"]*\bgrade[^"]*\bcritical\b[^"]*"') {
                    $grade = 'F'
                }
                # Try to pick up a percentage from the report body
                $plainTmp = ($whole -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '\s+',' ')
                # Look for "Health: NN%" or "Score: NN%" specifically
                if ($plainTmp -match '(?i)(?:Health|Score)[:\s]+(\d{1,3})\s*%') {
                    $score = [int]$Matches[1]
                }
            }

            # --- Common case for all other engines ---
            if ($grade -eq '--') {
                $plain = ($whole -replace '<[^>]+>',' ' -replace '&nbsp;',' ' -replace '&amp;','&' -replace '\s+',' ')

                # TIER 1 (highest priority): Letter grade followed by 1-3
                # words and then "Score/Health/Enrollment/Unified: NN%".
                # Examples that must match:
                #   "A Disk Health Score: 93%"     (2 middle words)
                #   "A+ Network Health: 98%"        (1 middle word)
                #   "B Security Score: 79%"         (1 middle word)
                $m1 = [regex]::Match($plain, '(?i)(?:^|[\s>])([A-F][+-]?)(?:\s+\w{2,20}){1,3}\s+(?:Score|Health|Enrollment|Unified|Grade)[:\s]+(\d{1,3})\s*%')
                if ($m1.Success) {
                    $grade = $m1.Groups[1].Value.ToUpper()
                    $score = [int]$m1.Groups[2].Value
                }

                # TIER 2: Shorter variant -- "A- Unified: 85%" (no middle word)
                if ($grade -eq '--') {
                    $m2 = [regex]::Match($plain, '(?i)(?:^|[\s>])([A-F][+-]?)\s+(?:Unified|Score|Health|Enrollment)[:\s]+(\d{1,3})\s*%')
                    if ($m2.Success) {
                        $grade = $m2.Groups[1].Value.ToUpper()
                        $score = [int]$m2.Groups[2].Value
                    }
                }

                # TIER 3: Explicit "Grade: X (NN%)" -- Master report alt format
                if ($grade -eq '--') {
                    $m3 = [regex]::Match($plain, '(?i)\bGrade[:\s]+([A-F][+-]?)\s*\(\s*(\d{1,3})\s*%\s*\)')
                    if ($m3.Success) {
                        $grade = $m3.Groups[1].Value.ToUpper()
                        $score = [int]$m3.Groups[2].Value
                    }
                }

                # TIER 4: Letter-paren-percent anywhere ("B (79%)")
                if ($grade -eq '--') {
                    $m4 = [regex]::Match($plain, '(?:^|[\s>])([A-F][+-]?)\s*\(\s*(\d{1,3})\s*%\s*\)')
                    if ($m4.Success) {
                        $grade = $m4.Groups[1].Value.ToUpper()
                        $score = [int]$m4.Groups[2].Value
                    }
                }

                # TIER 5: Assessment words (ComplianceDiff)
                if ($grade -eq '--') {
                    $m5 = [regex]::Match($plain, '\b(IMPROVED|DEGRADED|NEUTRAL|SUSPICIOUS)\b')
                    if ($m5.Success) { $grade = $m5.Groups[1].Value }
                }
            }
        } catch { }

        return [PSCustomObject]@{
            File = $f.Name; Path = $f.FullName
            Date = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            Grade = $grade; Score = $score
            SizeKB = [math]::Round($f.Length / 1KB, 1)
            Count = $files.Count
        }
    } -Default $null
}

$state.Engines = [ordered]@{
    PCHealth       = @{ Label=(T 'engines.pcHealth'   'PC Health');  Icon='&#9881;';   Desc=(T 'engines.pcHealthDesc'   'Hardware, CPU, RAM, battery'); Report = Get-LatestReport 'PCHealth_*.html' }
    DiskAnalysis   = @{ Label=(T 'engines.disk'       'Disk');       Icon='&#128190;'; Desc=(T 'engines.diskDesc'       'Storage, SMART, BitLocker');   Report = Get-LatestReport 'DiskAnalysis_*.html' }
    NetRepair      = @{ Label=(T 'engines.network'    'Network');    Icon='&#127760;'; Desc=(T 'engines.networkDesc'    'Connectivity, DNS, VPN');      Report = Get-LatestReport 'NetRepair_*.html' }
    SecurityScan   = @{ Label=(T 'engines.security'   'Security');   Icon='&#128737;'; Desc=(T 'engines.securityDesc'   'Defender, ASR, posture');      Report = Get-LatestReport 'SecurityScan_*.html' }
    AzureADJoin    = @{ Label=(T 'engines.identity'   'Identity');   Icon='&#128272;'; Desc=(T 'engines.identityDesc'   'Entra ID, Autopilot');         Report = Get-LatestReport 'AzureADJoin_*.html' }
    ComplianceDiff = @{ Label=(T 'engines.compliance' 'Compliance'); Icon='&#128203;'; Desc=(T 'engines.complianceDesc' 'Diff, MITRE, risk score');     Report = Get-LatestReport 'ComplianceDiff_*.html' }
}
$state.MasterReport = Get-LatestReport 'FieldOps_Master_*.html'

$state.AllReports = Invoke-SafeGather 'All Reports' {
    @(Get-ChildItem -Path $reportsDir -Filter "*.html" -ErrorAction Stop |
      Sort-Object LastWriteTime -Descending | Select-Object -First 50)
} -Default @()

$state.AllSnapshots = Invoke-SafeGather 'Snapshots' {
    @(Get-ChildItem -Path $snapshotDir -ErrorAction Stop |
      Where-Object { $_.Name -match '\.(json|json\.gz)$' -and $_.Name -notmatch '\.sha256$' } |
      Sort-Object LastWriteTime -Descending)
} -Default @()

$state.SnapTotalMB = [math]::Round((Get-SafeSize $state.AllSnapshots) / 1MB, 1)
$state.FleetHosts = @($state.AllSnapshots | ForEach-Object { ($_.Name -split '_')[0] } | Select-Object -Unique)

# --- Tools across all SCRIPTS subfolders ---
Write-Host ("    " + (T 'dashboard.scanningTools' 'Scanning all SCRIPTS subfolders...')) -ForegroundColor DarkGray

$state.AllTools = Invoke-SafeGather 'Tools Scan' {
    @(Get-ChildItem -Path $scriptsDir -Filter "Invoke-*.ps1" -Recurse -File -ErrorAction Stop |
      Where-Object { $_.Name -ne 'Invoke-FieldOpsHandler.ps1' } |
      Sort-Object Name)
} -Default @()

$tbf = @{}
foreach ($t in $state.AllTools) {
    try {
        $rel = $t.FullName.Substring($scriptsDir.Length).TrimStart('\')
        $folder = Split-Path -Parent $rel
        if (-not $folder) { $folder = 'Core' }
        if (-not $tbf.ContainsKey($folder)) { $tbf[$folder] = @() }
        $tbf[$folder] += $t
    } catch { }
}
$state.ToolsByFolder = $tbf

Write-Host "    $(Get-SafeCount $state.AllTools) tools across $($tbf.Keys.Count) folders" -ForegroundColor DarkGray

# --- USB Resource Inventory ---
Write-Host ("    " + (T 'dashboard.inventorying' 'Inventorying USB resources...')) -ForegroundColor DarkGray

# Playbooks
$state.Playbooks = Invoke-SafeGather 'Playbooks' {
    if (-not (Test-Path $playbooksDir)) { return $null }
    $items = @(Get-ChildItem -Path $playbooksDir -File -ErrorAction Stop | Sort-Object Name | Select-Object -First 50)
    return [PSCustomObject]@{
        Items = $items
        Count = $items.Count
        TotalMB = [math]::Round((Get-SafeSize $items) / 1MB, 1)
    }
} -Default ([PSCustomObject]@{ Items = @(); Count = 0; TotalMB = 0 })

# ISOs (both E:\ISO\ and USB root level)
$state.ISOs = Invoke-SafeGather 'ISOs' {
    $list = @()
    if (Test-Path $isoDir) {
        $list += @(Get-ChildItem -Path $isoDir -Filter "*.iso" -File -ErrorAction SilentlyContinue)
    }
    $list += @(Get-ChildItem -Path $usbRoot -Filter "*.iso" -File -ErrorAction SilentlyContinue)
    $unique = @($list | Sort-Object Name -Unique)
    return $unique
} -Default @()
$state.IsoTotalGB = [math]::Round((Get-SafeSize $state.ISOs) / 1GB, 1)

# Drivers (subfolders)
$state.Drivers = Invoke-SafeGather 'Drivers' {
    if (-not (Test-Path $driversDir)) { return @() }
    $subs = @(Get-ChildItem -Path $driversDir -Directory -ErrorAction Stop | Sort-Object Name)
    $out = @()
    foreach ($d in $subs) {
        $files = @(Get-ChildItem -Path $d.FullName -Recurse -File -ErrorAction SilentlyContinue)
        $out += [PSCustomObject]@{
            Name = $d.Name
            FileCount = (Get-SafeCount $files)
            SizeMB = [math]::Round((Get-SafeSize $files) / 1MB, 0)
        }
    }
    return $out
} -Default @()

# Portable Tools
$state.PortableTools = Invoke-SafeGather 'Portable Tools' {
    if (-not (Test-Path $toolsDir)) { return $null }
    $items = @(Get-ChildItem -Path $toolsDir -File -Recurse -ErrorAction Stop | Select-Object -First 30)
    return [PSCustomObject]@{
        Items = $items
        Count = (Get-SafeCount $items)
        TotalMB = [math]::Round((Get-SafeSize $items) / 1MB, 1)
    }
} -Default ([PSCustomObject]@{ Items = @(); Count = 0; TotalMB = 0 })

# Docs
$state.DocsCount = Invoke-SafeGather 'Docs' {
    if (-not (Test-Path $docsDir)) { return 0 }
    return (Get-SafeCount (Get-ChildItem -Path $docsDir -File -Recurse -ErrorAction SilentlyContinue))
} -Default 0

Write-Host "    Playbooks: $($state.Playbooks.Count) | ISOs: $(Get-SafeCount $state.ISOs) ($($state.IsoTotalGB) GB) | Drivers: $(Get-SafeCount $state.Drivers) | Portable: $($state.PortableTools.Count) | Docs: $($state.DocsCount)" -ForegroundColor DarkGray

# ==============================================================
# PHASE 3 -- RENDER HTML FROM $state
# ==============================================================
# Every helper below reads only from $state. If $state.Playbooks.Items is
# empty, the renderer produces an empty <div>. Nothing throws.

function Get-ActionHtml {
    param([string]$ScriptName, [string]$ArgString = '', [string]$DisplayCmd)
    if ($protocolRegistered) {
        $url = "fieldops://run?script=$ScriptName"
        if ($ArgString) {
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ArgString))
            $url += "&args=$b64"
        }
        return "href=`"$url`""
    } else {
        $esc = $DisplayCmd -replace "'","\\'"
        return "href=`"javascript:void(0)`" onclick=`"copyCmd(this,'$esc')`""
    }
}

# Tool descriptions
$toolDesc = @{
    'Invoke-AutoFix.ps1'            = (T 'tools.autoFix'          'Self-healing engine: auto-remediates 40+ issues')
    'Invoke-AzureADJoin.ps1'        = (T 'tools.azureADJoin'      'Entra ID enrollment and readiness check')
    'Invoke-ComplianceDiff.ps1'     = (T 'tools.complianceDiff'   'Compliance diff with MITRE mapping')
    'Invoke-Dashboard.ps1'          = (T 'tools.dashboard'        'This dashboard')
    'Invoke-DiskAnalysis.ps1'       = (T 'tools.diskAnalysis'     'Storage, SMART, BitLocker, duplicates')
    'Invoke-FieldOps.ps1'           = (T 'tools.fieldOps'         'Master command center (all 5 engines)')
    'Invoke-FleetReport.ps1'        = (T 'tools.fleetReport'      'Fleet intelligence report')
    'Invoke-NetRepair.ps1'          = (T 'tools.netRepair'        'Network diagnostics and repair')
    'Invoke-PCHealth.ps1'           = (T 'tools.pcHealth'         'Hardware health check')
    'Invoke-Playbook.ps1'           = (T 'tools.playbook'         'Automated deployment playbook runner')
    'Invoke-SecurityScan.ps1'       = (T 'tools.securityScan'     'Security posture audit')
    'Invoke-SoftwareDeploy.ps1'     = (T 'tools.softwareDeploy'   'Software deployment + download center')
    'Invoke-VPNSetup.ps1'           = (T 'tools.vpnSetup'         'GlobalProtect VPN setup')
    'Register-FieldOpsProtocol.ps1' = (T 'tools.registerProtocol' 'Register fieldops:// (run once as admin)')
}

# --- Master hero block ---
$mr = $state.MasterReport
$mGrade = if ($mr) { $mr.Grade } else { '' }
$mScore = if ($mr) { $mr.Score } else { 0 }
$mDate  = if ($mr) { $mr.Date } else { '' }
$mColor = if ($mGrade -match '^A') {'#22c55e'} elseif ($mGrade -match '^B') {'#38bdf8'} elseif ($mGrade -match '^C') {'#eab308'} else {'#475569'}
$mClick = if ($mr) { "onclick=""window.open('file:///$(($mr.Path) -replace '\\','/')')""" } else { '' }

# --- Engine cards ---
$eCardsHtml = ''
foreach ($key in $state.Engines.Keys) {
    $e = $state.Engines[$key]
    $r = $e.Report
    $hasData = $null -ne $r
    $grade = if ($hasData) { $r.Grade } else { '--' }
    $score = if ($hasData) { $r.Score } else { 0 }
    $date  = if ($hasData) { $r.Date } else { 'Never' }
    $cnt   = if ($hasData -and $r.Count -gt 1) { " ($($r.Count) runs)" } else { '' }
    $gc = if ($grade -match '^A|IMPROVED') {'#22c55e'} elseif ($grade -match '^B') {'#38bdf8'} elseif ($grade -match '^C|NEUTRAL|MEDIUM') {'#eab308'} elseif ($grade -eq '--') {'#334155'} elseif ($grade -match 'DEGRADED|SUSPICIOUS|HIGH|CRITICAL|^F') {'#ef4444'} else {'#f97316'}
    $click = if ($hasData) { "onclick=""window.open('file:///$(($r.Path) -replace '\\','/')')""" } else { '' }
    $cur = if ($hasData) { 'cursor:pointer' } else { 'cursor:default;opacity:0.4' }
    $scoreTxt = if ($hasData -and $score -gt 0) { "$score%" } else { '&nbsp;' }

    $eCardsHtml += "<div class='ec' style='$cur' $click><div class='ec-top'><span class='ec-i'>$($e.Icon)</span><span class='ec-l'>$($e.Label)</span></div><div class='ec-g' style='color:$gc'>$grade</div><div class='ec-s'>$scoreTxt</div><div class='ec-d'>$($e.Desc)</div><div class='ec-dt'>$date$cnt</div></div>`n"
}

# --- Quick Launch ---
$quickCmds = @(
    @{L=(T 'quickCmds.fullScan'   'Full Scan');  S='Invoke-FieldOps.ps1';       C='.\Invoke-FieldOps.ps1';                                                                                 D=(T 'quickCmds.fullScanDesc'   'Run all 5 engines'); X='#eab308'}
    @{L=(T 'quickCmds.compliance' 'Compliance'); S='Invoke-ComplianceDiff.ps1'; C='.\Invoke-ComplianceDiff.ps1';                                                                           D=(T 'quickCmds.complianceDesc' 'Interactive menu');  X='#ec4899'}
    @{L=(T 'quickCmds.quickDiff'  'Quick Diff'); S='Invoke-ComplianceDiff.ps1'; C='.\Invoke-ComplianceDiff.ps1 -Mode QuickDiff -Action ".\Invoke-AutoFix.ps1" -OpenReport'; A='-Mode QuickDiff -Action .\Invoke-AutoFix.ps1 -OpenReport'; D=(T 'quickCmds.quickDiffDesc' 'Before+Fix+After'); X='#22c55e'}
    @{L=(T 'quickCmds.autoFix'    'Auto Fix');   S='Invoke-AutoFix.ps1';        C='.\Invoke-AutoFix.ps1';                                                                                  D=(T 'quickCmds.autoFixDesc'    'Self-heal issues');  X='#38bdf8'}
    @{L=(T 'quickCmds.security'   'Security');   S='Invoke-SecurityScan.ps1';   C='.\Invoke-SecurityScan.ps1';                                                                             D=(T 'quickCmds.securityDesc'   'Posture audit');     X='#f97316'}
    @{L=(T 'quickCmds.refresh'    'Refresh');    S='Invoke-Dashboard.ps1';      C='.\Invoke-Dashboard.ps1 -OpenDashboard'; A='-OpenDashboard';                                              D=(T 'quickCmds.refreshDesc'    'Update dashboard');  X='#06b6d4'}
)
$qHtml = ''
foreach ($q in $quickCmds) {
    $argStr = if ($q.ContainsKey('A')) { $q.A } else { '' }
    $action = Get-ActionHtml -ScriptName $q.S -ArgString $argStr -DisplayCmd $q.C
    $qHtml += "<a class='qc' $action title='$(Escape-Html $q.C)'><div class='qcl' style='color:$($q.X)'>$($q.L)</div><div class='qcd'>$($q.D)</div><div class='qcc'>$(Escape-Html $q.C)</div></a>`n"
}

# --- System info grid ---
$sysHtml = ''
$sysDisplay = [ordered]@{}
$sysDisplay[(T 'sysInfo.hostname'   'Hostname')]    = $state.Sys.Hostname
$sysDisplay[(T 'sysInfo.model'      'Model')]       = "$($state.Sys.Manufacturer) $($state.Sys.Model)"
$sysDisplay[(T 'sysInfo.serial'     'Serial')]      = $state.Sys.Serial
$sysDisplay[(T 'sysInfo.bios'       'BIOS')]        = $state.Sys.BIOS
$sysDisplay[(T 'sysInfo.os'         'OS')]          = $state.Sys.OS
$sysDisplay[(T 'sysInfo.build'      'Build')]       = $state.Sys.OSBuild
$sysDisplay[(T 'sysInfo.cpu'        'CPU')]         = $state.Sys.CPU
$sysDisplay[(T 'sysInfo.cores'      'Cores')]       = $state.Sys.Cores
$sysDisplay[(T 'sysInfo.ram'        'RAM')]         = $state.Sys.RAM
$sysDisplay[(T 'sysInfo.ip'         'IP')]          = $state.Sys.IPAddress
$sysDisplay[(T 'sysInfo.mac'        'MAC')]         = $state.Sys.MACAddress
$sysDisplay[(T 'sysInfo.domain'     'Domain')]      = $state.Sys.Domain
$sysDisplay[(T 'sysInfo.directory'  'Directory')]   = $state.Sys.JoinStatus
$sysDisplay[(T 'sysInfo.uptime'     'Uptime')]      = $state.Sys.Uptime
$sysDisplay[(T 'sysInfo.lastBoot'   'Last Boot')]   = $state.Sys.LastBoot
$sysDisplay[(T 'sysInfo.bitlocker'  'BitLocker')]   = $state.Sys.BitLocker
$sysDisplay[(T 'sysInfo.tpm'        'TPM')]         = $state.Sys.TPM
$sysDisplay[(T 'sysInfo.secureBoot' 'Secure Boot')] = $state.Sys.SecureBoot
foreach ($k in $sysDisplay.Keys) {
    $v = $sysDisplay[$k]
    if ($null -eq $v -or "$v" -eq '') { continue }
    $vs = "$v"
    $vc = '#cbd5e1'
    # Color logic: match English + French keywords + localized strings.
    # Green = positive state, amber = admin-gated, orange = negative/missing
    if ($vs -match 'Enabled|Ready|Joined|On |Active|Activ|Pr.t|Joint') { $vc = '#22c55e' }
    elseif ($vs -eq $lblAdminReq -or $vs -match 'Admin required|droits admin|admin requis') { $vc = '#fbbf24' }
    elseif ($vs -match 'Disabled|Not |N/A|N/D|Unknown|Inconnu|Workgroup|Off|Absent|D.sactiv|Non ') { $vc = '#f97316' }
    $sysHtml += "<div class='si'><span class='sl'>$k</span><span class='sv' style='color:$vc'>$(Escape-Html $vs)</span></div>`n"
}

# --- Tools by folder ---
$tHtml = ''
foreach ($folder in ($state.ToolsByFolder.Keys | Sort-Object)) {
    $folderTools = $state.ToolsByFolder[$folder]
    $tcount = Get-SafeCount $folderTools
    $tHtml += "<div class='tf'><div class='tfh'>$folder <span class='tfc'>($tcount)</span></div>"
    foreach ($t in $folderTools) {
        $desc = if ($toolDesc.ContainsKey($t.Name)) { $toolDesc[$t.Name] } else { '' }
        $cmd = ".\$($t.Name)"
        $nm = $t.Name -replace 'Invoke-','' -replace '\.ps1',''
        $action = Get-ActionHtml -ScriptName $t.Name -DisplayCmd $cmd
        $tHtml += "<a class='tr' $action><div class='tn'>$nm</div><div class='td'>$(Escape-Html $desc)</div><div class='tc'>$cmd</div></a>`n"
    }
    $tHtml += "</div>`n"
}

# --- Reports table ---
$rHtml = ''
# Internal type key (English) -> localized display label
$tDisplay = @{
    'Health'     = (T 'reportTypes.health'     'Health')
    'Disk'       = (T 'reportTypes.disk'       'Disk')
    'Network'    = (T 'reportTypes.network'    'Network')
    'Security'   = (T 'reportTypes.security'   'Security')
    'Identity'   = (T 'reportTypes.identity'   'Identity')
    'Compliance' = (T 'reportTypes.compliance' 'Compliance')
    'Master'     = (T 'reportTypes.master'     'Master')
    'Rollback'   = (T 'reportTypes.rollback'   'Rollback')
    'Fleet'      = (T 'reportTypes.fleet'      'Fleet')
    'Incident'   = (T 'reportTypes.incident'   'Incident')
    'Deploy'     = (T 'reportTypes.deploy'     'Deploy')
    'Dashboard'  = (T 'reportTypes.dashboard'  'Dashboard')
    'Other'      = (T 'reportTypes.other'      'Other')
}
$tMap = @{'PCHealth'='Health';'DiskAnal'='Disk';'NetRepair'='Network';'Security'='Security';'AzureAD'='Identity';'Compliance'='Compliance';'FieldOps'='Master';'Rollback'='Rollback';'Fleet'='Fleet';'Incident'='Incident';'SoftwareDeploy'='Deploy';'Dashboard'='Dashboard'}
$cMap = @{'Health'='#22c55e';'Disk'='#38bdf8';'Network'='#a78bfa';'Security'='#f97316';'Identity'='#06b6d4';'Compliance'='#ec4899';'Master'='#eab308';'Rollback'='#ef4444';'Fleet'='#14b8a6';'Incident'='#f43f5e';'Deploy'='#8b5cf6';'Dashboard'='#06b6d4'}
foreach ($r in $state.AllReports) {
    $rtKey = 'Other'; $rc = '#64748b'
    foreach ($p in $tMap.Keys) { if ($r.Name -match "^$p") { $rtKey = $tMap[$p]; $rc = $cMap[$rtKey]; break } }
    $rt = if ($tDisplay.ContainsKey($rtKey)) { $tDisplay[$rtKey] } else { $rtKey }
    $fp = $r.FullName -replace '\\','/'
    $rKB = [math]::Round($r.Length / 1KB, 1)
    $rHtml += "<tr class='rr' onclick=""window.open('file:///$fp')""><td><span style='color:$rc;font-weight:600'>$rt</span></td><td style='color:#94a3b8'>$($r.Name)</td><td>$($r.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))</td><td>${rKB}KB</td></tr>`n"
}

# --- Snapshots table ---
$sHtml = ''
$snapBefore = T 'snapTypes.before' 'Before'
$snapAfter  = T 'snapTypes.after'  'After'
$snapOther  = T 'snapTypes.snapshot' 'Snap'
$snaps = @($state.AllSnapshots)
$sLim = [math]::Min($snaps.Count, 15)
for ($i = 0; $i -lt $sLim; $i++) {
    $s = $snaps[$i]
    $st = if ($s.Name -match '_Before_') { $snapBefore } elseif ($s.Name -match '_After_') { $snapAfter } else { $snapOther }
    $tc = if ($s.Name -match '_Before_') { '#22c55e' } else { '#38bdf8' }
    $cf = if ($s.Name -match '\.gz$') { 'GZip' } else { 'JSON' }
    $sMB = [math]::Round($s.Length / 1MB, 1)
    $sHtml += "<tr><td><span style='color:$tc;font-weight:600'>$st</span></td><td style='color:#94a3b8;font-size:11px'>$($s.Name)</td><td>$($s.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))</td><td>${sMB}MB</td><td>$cf</td></tr>`n"
}

# --- Fleet ---
$fHtml = ''
if ((Get-SafeCount $state.FleetHosts) -gt 1) {
    foreach ($fh in $state.FleetHosts) {
        $hs = @($state.AllSnapshots | Where-Object { $_.Name -like "$fh`_*" })
        $hl = if ($hs.Count -gt 0) { $hs[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { 'N/A' }
        $hm = [math]::Round((Get-SafeSize $hs) / 1MB, 1)
        $fHtml += "<div class='fh'><div class='fn'>$fh</div><div class='fi'>$($hs.Count) snaps ($hm MB) | Last: $hl</div></div>`n"
    }
}

# --- Playbooks ---
$pbHtml = ''
$pbList = @()
if ($state.Playbooks -and $state.Playbooks.Items) { $pbList = @($state.Playbooks.Items) }
foreach ($pb in $pbList) {
    $pbName = $pb.Name
    $pbAction = if ($protocolRegistered) {
        "href=`"fieldops://playbook?name=$([System.Uri]::EscapeDataString($pbName))`""
    } else {
        $fp = $pb.FullName -replace '\\','/'
        "href=`"file:///$fp`""
    }
    $pbExt = $pb.Extension.TrimStart('.').ToUpper()
    $pbKB = [math]::Round($pb.Length / 1KB, 1)
    $pbHtml += "<a class='pb' $pbAction><div class='pb-name'>$(Escape-Html $pb.BaseName)</div><div class='pb-meta'>$pbExt &middot; ${pbKB} KB</div></a>`n"
}

# --- ISOs ---
$isoHtml = ''
foreach ($iso in $state.ISOs) {
    $isoGB = [math]::Round($iso.Length / 1GB, 2)
    $isoHtml += "<div class='iso'><span class='iso-name'>$(Escape-Html $iso.Name)</span><span class='iso-size'>${isoGB} GB</span></div>`n"
}

# --- Drivers ---
$drvHtml = ''
foreach ($d in $state.Drivers) {
    $drvHtml += "<div class='drv'><span class='drv-name'>$(Escape-Html $d.Name)</span><span class='drv-meta'>$($d.FileCount) files &middot; $($d.SizeMB) MB</span></div>`n"
}

# --- Gather error banner (if any) ---
$errBanner = ''
if ($script:gatherErrors.Count -gt 0) {
    $errList = ($script:gatherErrors | ForEach-Object { "<li>$(Escape-Html $_)</li>" }) -join ''
    $errPre = T 'dashboard.collectorsFailedPre' 'data collector(s) failed (dashboard still rendered):'
    $errBanner = "<div class='err-banner'><strong>$($script:gatherErrors.Count) $errPre</strong><ul>$errList</ul></div>"
}

$protocolBanner = if ($protocolRegistered) {
    $msg = T 'dashboard.protocolActive' 'fieldops:// protocol active &mdash; clicks run scripts directly'
    "<div class=""pb-ok"">&#10003; $msg</div>"
} else {
    $msg = T 'dashboard.protocolInactive' 'fieldops:// NOT registered &mdash; clicks copy commands only. Run <code>Register-FieldOpsProtocol.ps1</code> as Admin to enable direct execution.'
    "<div class=""pb-warn"">&#9888; $msg</div>"
}

$elevationBanner = if ($isElevated) { '' } else {
    $msg = T 'dashboard.elevationWarn' 'Running without Administrator &mdash; some collectors (BitLocker, Secure Boot, TPM details) require elevation. Re-run as Admin for complete data.'
    "<div class=""pb-warn"">&#9888; $msg</div>"
}

# ==============================================================
# PHASE 3 -- ASSEMBLE HTML
# ==============================================================
$dashPath = Join-Path $reportsDir 'Dashboard.html'
$cfg = $state.Config
$techName = $cfg.TechName
$orgName  = $cfg.OrgName
$brandColor = $cfg.Brand

# Precompute all localized UI labels (for use inside the HTML here-string)
$htmlLang          = $script:CurrentLocale
$uiTitle           = T 'dashboard.title'            'OPERATIONS DASHBOARD'
$uiMasterAssess    = T 'dashboard.masterAssessment' 'Master Assessment'
$uiRunFullScan     = T 'dashboard.runFullScan'      'Run Full Scan to generate Master grade'
$uiEngineScores    = T 'dashboard.engineScores'     'Engine Scores'
$uiAllTools        = T 'dashboard.allTools'         'All Tools'
$uiPlaybooks       = T 'dashboard.playbooks'        'Playbooks'
$uiBootableIsos    = T 'dashboard.bootableIsos'     'Bootable ISOs'
$uiDrivers         = T 'dashboard.drivers'          'Drivers'
$uiReports         = T 'dashboard.reportLibrary'    'Reports'
$uiFleet           = T 'dashboard.fleet'            'Fleet'
$uiSnapshots       = T 'dashboard.snapshots'        'Snapshots'
$uiIn              = T 'common.in'                  'in'
$uiFolders         = T 'common.folders'             'folders'
$uiHosts           = T 'common.hosts'               'hosts'
$uiColType         = T 'common.type'                'Type'
$uiColFile         = T 'common.file'                'File'
$uiColDate         = T 'common.date'                'Date'
$uiColSize         = T 'common.size'                'Size'
$uiColFmt          = T 'common.format'              'Fmt'

$html = @"
<!DOCTYPE html>
<html lang="$htmlLang">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>FieldOps Pro Dashboard v$VERSION</title>
<link href="https://fonts.googleapis.com/css2?family=DM+Mono:wght@300;400;500&family=Outfit:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#060a12; --bg2:#0c1220; --bg3:#111b2e; --br:#1a2744; --br2:#243352;
  --t1:#e8ecf4; --t2:#8b97b0; --t3:#4a5872;
  --ac:$brandColor; --green:#22c55e; --amber:#eab308; --red:#ef4444;
  --fm:'DM Mono',monospace; --fd:'Outfit',sans-serif;
}
body{background:var(--bg);color:var(--t1);font-family:var(--fm);font-size:13px;line-height:1.6;min-height:100vh}
body::before{content:'';position:fixed;inset:0;background:radial-gradient(ellipse at 50% 0%,rgba(6,182,212,0.04) 0%,transparent 60%);pointer-events:none}
.w{max-width:1480px;margin:0 auto;padding:20px 24px;position:relative;z-index:1}
a{color:inherit;text-decoration:none}

.hd{display:flex;align-items:center;justify-content:space-between;padding:16px 0 20px;border-bottom:1px solid var(--br);margin-bottom:16px}
.ho{font-family:var(--fd);font-size:10px;color:var(--t3);letter-spacing:3px;text-transform:uppercase}
.ht{font-family:var(--fd);font-size:24px;font-weight:700;color:var(--ac);letter-spacing:1px}
.hr{text-align:right}
.hr div:first-child{font-family:var(--fd);font-size:13px;color:var(--t2)}
.hr div:last-child{font-size:11px;color:var(--t3)}

.pb-ok{background:rgba(34,197,94,0.08);border:1px solid rgba(34,197,94,0.3);color:#86efac;padding:8px 14px;border-radius:6px;font-size:11px;margin-bottom:16px;text-align:center}
.pb-warn{background:rgba(234,179,8,0.08);border:1px solid rgba(234,179,8,0.3);color:#fde047;padding:8px 14px;border-radius:6px;font-size:11px;margin-bottom:16px;text-align:center}
.pb-warn code{background:var(--bg);padding:1px 6px;border-radius:3px;color:var(--ac)}
.err-banner{background:rgba(239,68,68,0.08);border:1px solid rgba(239,68,68,0.3);color:#fca5a5;padding:12px 16px;border-radius:6px;font-size:11px;margin-bottom:16px}
.err-banner ul{margin:6px 0 0 20px}

.qg{display:grid;grid-template-columns:repeat(6,1fr);gap:8px;margin-bottom:20px}
.qc{background:var(--bg2);border:1px solid var(--br);border-radius:8px;padding:11px 13px;cursor:pointer;transition:all .15s;position:relative;overflow:hidden;display:block}
.qc:hover{border-color:var(--br2);background:var(--bg3);transform:translateY(-1px)}
.qc:active::after{content:'LAUNCHED';position:absolute;inset:0;display:flex;align-items:center;justify-content:center;background:rgba(34,197,94,0.92);color:#fff;font-family:var(--fd);font-weight:700;font-size:12px;letter-spacing:2px;border-radius:7px}
.qcl{font-family:var(--fd);font-size:13px;font-weight:600}
.qcd{font-size:10px;color:var(--t3);margin:2px 0}
.qcc{font-size:9px;color:var(--ac);opacity:.55;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}

.tp{display:grid;grid-template-columns:260px 1fr;gap:14px;margin-bottom:20px}
.hero{background:var(--bg2);border:1px solid var(--br);border-radius:10px;padding:24px;text-align:center;display:flex;flex-direction:column;align-items:center;justify-content:center;cursor:pointer;transition:all .15s;position:relative}
.hero:hover{border-color:var(--br2)}
.hero::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:linear-gradient(90deg,var(--ac),var(--green),var(--amber));border-radius:10px 10px 0 0}
.htag{font-family:var(--fd);font-size:10px;color:var(--t3);letter-spacing:2px;text-transform:uppercase}
.hg{font-family:var(--fd);font-size:60px;font-weight:800;line-height:1;margin:6px 0}
.hsub{font-size:11px;color:var(--t3)}
.sg{background:var(--bg2);border:1px solid var(--br);border-radius:10px;padding:14px;display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:0;align-content:start}
.si{padding:5px 10px;border-bottom:1px solid rgba(26,39,68,0.4)}
.sl{font-size:9px;color:var(--t3);text-transform:uppercase;letter-spacing:.5px;display:block}
.sv{font-size:12px;display:block;margin-top:1px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}

.st{font-family:var(--fd);font-size:11px;color:var(--ac);letter-spacing:3px;text-transform:uppercase;margin:24px 0 10px;padding-bottom:6px;border-bottom:1px solid var(--br)}

.eg{display:grid;grid-template-columns:repeat(auto-fit,minmax(165px,1fr));gap:8px;margin-bottom:20px}
.ec{background:var(--bg2);border:1px solid var(--br);border-radius:8px;padding:14px;text-align:center;transition:all .15s}
.ec:hover{border-color:var(--br2);background:var(--bg3);transform:translateY(-1px)}
.ec-top{display:flex;align-items:center;justify-content:center;gap:5px;margin-bottom:6px}
.ec-i{font-size:16px;opacity:.7}
.ec-l{font-family:var(--fd);font-size:11px;color:var(--t2);font-weight:500}
.ec-g{font-family:var(--fd);font-size:30px;font-weight:800;margin:2px 0;letter-spacing:1px}
.ec-s{font-size:11px;color:var(--t3);font-weight:600;min-height:16px}
.ec-d{font-size:10px;color:var(--t3)}
.ec-dt{font-size:9px;color:var(--t3);margin-top:4px;opacity:.5}

.tg{display:grid;grid-template-columns:1fr;gap:14px;margin-bottom:20px}
.tf{background:var(--bg2);border:1px solid var(--br);border-radius:8px;overflow:hidden}
.tfh{font-family:var(--fd);font-size:11px;font-weight:600;color:var(--ac);letter-spacing:2px;text-transform:uppercase;padding:10px 14px;background:var(--bg);border-bottom:1px solid var(--br)}
.tfc{color:var(--t3);font-weight:400;margin-left:6px}
.tr{display:grid;grid-template-columns:140px 1fr auto;gap:10px;align-items:center;padding:7px 14px;border-bottom:1px solid rgba(26,39,68,0.3);transition:background .1s}
.tr:hover{background:var(--bg3)}
.tr:last-child{border-bottom:none}
.tn{font-family:var(--fd);font-size:12px;font-weight:500;color:var(--t1)}
.td{font-size:11px;color:var(--t3)}
.tc{font-size:11px;color:var(--ac);background:var(--bg);padding:3px 10px;border-radius:4px;border:1px solid var(--br);transition:all .15s;white-space:nowrap}
.tr:hover .tc{border-color:var(--ac);background:rgba(6,182,212,0.1)}

.bx{background:var(--bg2);border:1px solid var(--br);border-radius:8px;overflow:hidden;margin-bottom:20px}
table{width:100%;border-collapse:collapse}
th{text-align:left;padding:6px 12px;font-size:9px;color:var(--t3);text-transform:uppercase;letter-spacing:1px;border-bottom:1px solid var(--br);background:var(--bg)}
td{padding:5px 12px;border-bottom:1px solid rgba(26,39,68,0.3);font-size:12px;color:var(--t2)}
.rr{cursor:pointer;transition:background .1s}
.rr:hover td{background:var(--bg3)}

.pbg{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:8px;margin-bottom:20px}
.pb{background:var(--bg2);border:1px solid var(--br);border-left:3px solid var(--amber);border-radius:6px;padding:12px 14px;transition:all .15s;display:block}
.pb:hover{border-color:var(--br2);border-left-color:var(--amber);background:var(--bg3);transform:translateX(2px)}
.pb-name{font-family:var(--fd);font-size:13px;font-weight:600;color:var(--t1)}
.pb-meta{font-size:10px;color:var(--t3);margin-top:3px}

.isog{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:6px;margin-bottom:20px}
.iso{background:var(--bg2);border:1px solid var(--br);border-radius:6px;padding:8px 12px;display:flex;justify-content:space-between;align-items:center;font-size:11px}
.iso-name{color:var(--t2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;margin-right:8px}
.iso-size{color:var(--ac);font-weight:600;white-space:nowrap}

.drvg{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:8px;margin-bottom:20px}
.drv{background:var(--bg2);border:1px solid var(--br);border-radius:6px;padding:10px 14px;display:flex;justify-content:space-between;align-items:center}
.drv-name{font-family:var(--fd);font-size:12px;font-weight:500;color:var(--t1)}
.drv-meta{font-size:10px;color:var(--t3)}

.fg{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:8px;margin-bottom:20px}
.fh{background:var(--bg2);border:1px solid var(--br);border-left:3px solid var(--ac);border-radius:6px;padding:12px}
.fn{font-family:var(--fd);font-size:14px;font-weight:600;color:var(--ac)}
.fi{font-size:11px;color:var(--t3);margin-top:3px}

.ft{text-align:center;color:var(--t3);font-size:10px;padding:18px 0;margin-top:32px;border-top:1px solid var(--br)}

.toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%) translateY(60px);background:var(--green);color:#fff;font-family:var(--fd);font-size:12px;font-weight:600;padding:10px 24px;border-radius:6px;letter-spacing:1px;opacity:0;transition:all .25s;z-index:99;pointer-events:none;box-shadow:0 8px 32px rgba(0,0,0,0.5)}
.toast.show{opacity:1;transform:translateX(-50%) translateY(0)}

@media(max-width:900px){
  .tp{grid-template-columns:1fr}
  .qg{grid-template-columns:repeat(3,1fr)}
  .tr{grid-template-columns:1fr}
  .td{display:none}
}
</style>
</head>
<body>
<div class="w">

<div class="hd">
  <div>
    <div class="ho">$(Escape-Html $orgName)</div>
    <div class="ht">$uiTitle</div>
  </div>
  <div class="hr">
    <div>$(Escape-Html $techName)</div>
    <div>$($NOW.ToString('yyyy-MM-dd HH:mm')) &middot; v$VERSION</div>
  </div>
</div>

$protocolBanner
$elevationBanner
$errBanner

<div class="qg">
$qHtml
</div>

<div class="tp">
  <div class="hero" $mClick>
$(if ($mGrade -and $mGrade -ne '--') {
    "<div class='htag'>$uiMasterAssess</div><div class='hg' style='color:$mColor'>$mGrade</div><div class='hsub'>$mScore% &middot; $mDate</div>"
} else {
    "<div class='htag' style='margin:20px 0'>$uiRunFullScan</div>"
})
  </div>
  <div class="sg">
$sysHtml
  </div>
</div>

<div class="st">$uiEngineScores</div>
<div class="eg">
$eCardsHtml
</div>

<div class="st">$uiAllTools ($(Get-SafeCount $state.AllTools) $uiIn $($state.ToolsByFolder.Keys.Count) $uiFolders)</div>
<div class="tg">
$tHtml
</div>

$(if ($pbHtml) { @"
<div class="st">$uiPlaybooks ($($state.Playbooks.Count))</div>
<div class="pbg">
$pbHtml
</div>
"@ })

$(if ($isoHtml) { @"
<div class="st">$uiBootableIsos ($(Get-SafeCount $state.ISOs) &middot; $($state.IsoTotalGB) GB)</div>
<div class="isog">
$isoHtml
</div>
"@ })

$(if ($drvHtml) { @"
<div class="st">$uiDrivers</div>
<div class="drvg">
$drvHtml
</div>
"@ })

<div class="st">$uiReports ($(Get-SafeCount $state.AllReports))</div>
<div class="bx">
<table>
<thead><tr><th>$uiColType</th><th>$uiColFile</th><th>$uiColDate</th><th>$uiColSize</th></tr></thead>
<tbody>
$rHtml
</tbody>
</table>
</div>

$(if ($fHtml) { @"
<div class="st">$uiFleet ($((Get-SafeCount $state.FleetHosts)) $uiHosts)</div>
<div class="fg">
$fHtml
</div>
"@ })

<div class="st">$uiSnapshots ($(Get-SafeCount $state.AllSnapshots) &middot; $($state.SnapTotalMB) MB)</div>
<div class="bx">
<table>
<thead><tr><th>$uiColType</th><th>$uiColFile</th><th>$uiColDate</th><th>$uiColSize</th><th>$uiColFmt</th></tr></thead>
<tbody>
$sHtml
</tbody>
</table>
</div>

<div class="ft">
FieldOps Pro v$VERSION &middot; $(Escape-Html $techName) &middot; $($state.Sys.Hostname) &middot; $(Escape-Html "$($state.Sys.Manufacturer) $($state.Sys.Model)") &middot; SN:$(Escape-Html $state.Sys.Serial) &middot; $($NOW.ToString('yyyy-MM-dd HH:mm:ss'))
</div>

</div>

<div class="toast" id="toast"></div>

<script>
function copyCmd(el, cmd) {
  navigator.clipboard.writeText(cmd).then(function() {
    var t = document.getElementById('toast');
    t.textContent = 'COPIED: ' + cmd;
    t.classList.add('show');
    setTimeout(function() { t.classList.remove('show'); }, 2000);
  });
  return false;
}
</script>
</body>
</html>
"@

# ==============================================================
# PHASE 4 -- WRITE FILE AND REPORT
# ==============================================================
Invoke-SafeGather 'Write Dashboard' {
    $html | Set-Content -Path $dashPath -Encoding UTF8
    return $true
} -Default $false | Out-Null

$dKB = 0
if (Test-Path $dashPath) {
    try { $dKB = [math]::Round((Get-Item $dashPath).Length / 1KB, 1) } catch { }
}

$lblGenerated = T 'dashboard.generated' 'DASHBOARD GENERATED'
$lblFile      = T 'summary.file'      'File'
$lblEngines   = T 'summary.engines'   'Engines'
$lblTools     = T 'summary.tools'     'Tools'
$lblReports   = T 'summary.reports'   'Reports'
$lblSnapshots = T 'summary.snapshots' 'Snapshots'
$lblPlaybooks = T 'summary.playbooks' 'Playbooks'
$lblISOs      = T 'summary.isos'      'ISOs'
$lblDrivers   = T 'summary.drivers'   'Drivers'
$lblMachine   = T 'summary.machine'   'Machine'
$lblProtocol  = T 'summary.protocol'  'Protocol'
$lblWarnings  = T 'summary.warnings'  'WARNINGS'
$lblAcross    = T 'summary.across'    'across'
$lblFolders   = T 'summary.folders'   'folders'
$lblWithData  = T 'summary.withData'  'with data'
$lblActive    = T 'summary.protoActive'   'ACTIVE (fieldops://)'
$lblInactive  = T 'summary.protoInactive' 'INACTIVE (copy mode)'
$lblNone      = T 'common.none' 'none'
$lblFailedMsg = T 'summary.collectorsFailed' 'collector(s) failed (shown as banner in dashboard)'

Write-Host ''
Write-Host '  ======================================================================' -ForegroundColor Cyan
Write-Host "  $lblGenerated" -ForegroundColor Green
Write-Host '  ======================================================================' -ForegroundColor Cyan
Write-Host "  $($lblFile.PadRight(9)): $dashPath ($dKB KB)"
Write-Host "  $($lblEngines.PadRight(9)): $(@($state.Engines.Keys | Where-Object { $null -ne $state.Engines[$_].Report }).Count) / $(Get-SafeCount $state.Engines.Keys) $lblWithData"
Write-Host "  $($lblTools.PadRight(9)): $(Get-SafeCount $state.AllTools) $lblAcross $($state.ToolsByFolder.Keys.Count) $lblFolders"
Write-Host "  $($lblReports.PadRight(9)): $(Get-SafeCount $state.AllReports) | $($lblSnapshots): $(Get-SafeCount $state.AllSnapshots) ($($state.SnapTotalMB) MB)"
Write-Host "  $($lblPlaybooks.PadRight(9)): $($state.Playbooks.Count) | $($lblISOs): $(Get-SafeCount $state.ISOs) ($($state.IsoTotalGB) GB) | $($lblDrivers): $(Get-SafeCount $state.Drivers)"
Write-Host "  $($lblMachine.PadRight(9)): $($state.Sys.Manufacturer) $($state.Sys.Model) | SN: $($state.Sys.Serial)"
Write-Host "  $($lblProtocol.PadRight(9)): $(if($protocolRegistered){$lblActive}else{$lblInactive})"
if ($script:gatherErrors.Count -gt 0) {
    Write-Host "  $($lblWarnings.PadRight(9)): $($script:gatherErrors.Count) $lblFailedMsg" -ForegroundColor Yellow
} else {
    Write-Host "  $($lblWarnings.PadRight(9)): $lblNone" -ForegroundColor Green
}
Write-Host '  ======================================================================' -ForegroundColor Cyan
Write-Host ''

if ($OpenDashboard -and (Test-Path $dashPath)) { Start-Process $dashPath }
