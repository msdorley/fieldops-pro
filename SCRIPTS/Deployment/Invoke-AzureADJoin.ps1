# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ousman Dorley. See LICENSE at the repository root.
<#
.SYNOPSIS
    FieldOps Pro - Azure AD Intelligent Enrollment Engine v2.0
.DESCRIPTION
    14-section enrollment intelligence with multi-tenant support, WiFi profile
    injection, Conditional Access pre-check, real-time enrollment monitor,
    before/after state snapshots, expanded error database (25+ codes),
    enrollment pipeline visualization, and bulk mode support.
    The definitive portable enrollment tool for field IT.
.PARAMETER TenantHint
    Optional tenant domain hint (e.g. "contoso.onmicrosoft.com") for multi-tenant deployments.
.PARAMETER ImportWiFi
    Path to WiFi profile XML file to import before enrollment.
.PARAMETER ExportWiFi
    Export current WiFi profiles to the reports folder.
.PARAMETER Snapshot
    Save a before/after enrollment state snapshot for comparison.
.PARAMETER Monitor
    After enrollment action, monitor dsregcmd state changes in real time.
.NOTES
    Author  : FieldOps Pro
    Version : 2.0
    Requires: PowerShell 5.1, Administrator REQUIRED for enrollment
    Location: E:\SCRIPTS\Deployment\Invoke-AzureADJoin.ps1
    Rules   : Pure ASCII. Dynamic paths. PS 5.1 only.
#>

[CmdletBinding()]
param(
    [string]$TenantHint = '',
    [string]$ImportWiFi = '',
    [switch]$ExportWiFi,
    [switch]$Snapshot,
    [switch]$Monitor
)

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ============================================================
# PATH SETUP & MODULES
# ============================================================
$ScriptRoot  = $PSScriptRoot
$ProjectRoot = Split-Path (Split-Path $ScriptRoot -Parent) -Parent
$CorePath    = Join-Path $ProjectRoot 'SCRIPTS\Core'
$ReportsPath = Join-Path $ProjectRoot 'REPORTS'
$LogsPath    = Join-Path $ProjectRoot 'LOGS'
$ConfigPath  = Join-Path $ProjectRoot 'CONFIG'
$SnapshotDir = Join-Path $ReportsPath 'Snapshots'
if (-not (Test-Path $ReportsPath)) { New-Item -Path $ReportsPath -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $LogsPath))    { New-Item -Path $LogsPath -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $SnapshotDir)) { New-Item -Path $SnapshotDir -ItemType Directory -Force | Out-Null }

$LoggerPath = Join-Path $CorePath 'Logger.psm1'
if (Test-Path $LoggerPath) { Import-Module $LoggerPath -Force -DisableNameChecking }
else { function Write-Log { param([string]$Message,[string]$Level='INFO'); Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message" } }
$UtilsPath = Join-Path $CorePath 'Utils.psm1'
if (Test-Path $UtilsPath) { Import-Module $UtilsPath -Force -DisableNameChecking }

# ============================================================
# MULTI-TENANT CONFIG
# ============================================================
$script:TenantConfig = $null
try {
    $techJson = Join-Path $ConfigPath 'technician.json'
    if (Test-Path $techJson) {
        $techData = Get-Content $techJson -Raw | ConvertFrom-Json
        if ($techData.Tenants) { $script:TenantConfig = $techData.Tenants }
        if (-not $TenantHint -and $techData.DefaultTenant) { $TenantHint = $techData.DefaultTenant }
    }
} catch {}

# ============================================================
# RESULTS ENGINE
# ============================================================
$script:Results      = [System.Collections.ArrayList]::new()
$script:Findings     = [System.Collections.ArrayList]::new()
$script:SectionScores = [System.Collections.ArrayList]::new()
$script:CheckCount   = 0
$script:Stopwatch    = [System.Diagnostics.Stopwatch]::StartNew()
$script:IsAdmin      = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:ReadinessScore = 0
$script:ReadinessMax   = 0

function Convert-StatusToLogLevel { param([string]$S); switch ($S) { 'Pass' {'OK'} 'Warning' {'WARN'} 'Fail' {'ERROR'} default {'INFO'} } }

function Add-Check {
    param([string]$Category,[string]$Check,[string]$Status,[string]$Value,[string]$Detail)
    $script:CheckCount++
    $null = $script:Results.Add([PSCustomObject]@{Number=$script:CheckCount;Category=$Category;Check=$Check;Status=$Status;Value=$Value;Detail=$Detail})
    $icon = switch ($Status) {'Pass'{'[PASS]'}'Warning'{'[WARN]'}'Fail'{'[FAIL]'}default{'[INFO]'}}
    Write-Host "  $icon $Check : $Value" -ForegroundColor $(switch ($Status) {'Pass'{'Green'}'Warning'{'Yellow'}'Fail'{'Red'}default{'Cyan'}})
    Write-Log -Message "$icon $Check = $Value | $Detail" -Level (Convert-StatusToLogLevel $Status)
}

function Add-Readiness {
    param([string]$Category,[string]$Check,[string]$Status,[string]$Value,[string]$Detail,[int]$Weight=1)
    Add-Check -Category $Category -Check $Check -Status $Status -Value $Value -Detail $Detail
    $script:ReadinessMax += $Weight
    if ($Status -eq 'Pass') { $script:ReadinessScore += $Weight }
    elseif ($Status -eq 'Warning') { $script:ReadinessScore += ($Weight * 0.5) }
}

function Add-Finding {
    param([string]$Severity,[string]$Title,[string]$Detail,[string]$Action,[array]$FixCommands,[int]$FixMinutes=5,[string]$ErrorCode='')
    $null = $script:Findings.Add([PSCustomObject]@{Severity=$Severity;Title=$Title;Detail=$Detail;Action=$Action;FixCommands=$FixCommands;FixMinutes=$FixMinutes;ErrorCode=$ErrorCode})
}

function Save-SectionScore {
    param([string]$Section,[string]$Category)
    $catChecks = @($script:Results | Where-Object {$_.Category -eq $Category -and $_.Status -in @('Pass','Warning','Fail')})
    if ($catChecks.Count -eq 0) { return }
    $p = @($catChecks|Where-Object{$_.Status -eq 'Pass'}).Count
    $w = @($catChecks|Where-Object{$_.Status -eq 'Warning'}).Count
    $score = [math]::Round((($p+($w*0.5))/$catChecks.Count)*100,0)
    $null = $script:SectionScores.Add([PSCustomObject]@{Section=$Section;Score=$score;Checks=$catChecks.Count})
}

function Test-TcpPort {
    param([string]$H,[int]$P,[int]$T=3000)
    try { $c=New-Object System.Net.Sockets.TcpClient; $r=$c.BeginConnect($H,$P,$null,$null); $w=$r.AsyncWaitHandle.WaitOne($T,$false); if($w -and $c.Connected){$c.Close();$true}else{$c.Close();$false} } catch { $false }
}

# ============================================================
# EXPANDED ERROR CODE DATABASE (25+ codes)
# ============================================================
$script:ErrorDB = @{
    '0x801c03ed' = @{Desc='Device limit reached in Azure AD';Fix='Delete stale devices in Entra ID portal > Devices, or increase limit in Device Settings'}
    '0x80180014' = @{Desc='MDM enrollment rejected by server';Fix='Check Intune license assignment. Verify enrollment restrictions in Intune admin center > Devices > Enrollment restrictions'}
    '0x80180001' = @{Desc='MDM authority not configured';Fix='Set MDM authority in Intune admin center > Tenant administration'}
    '0x801c0003' = @{Desc='User not authorized to join devices';Fix='Entra ID > Devices > Device settings > Users may join devices to Azure AD: All or Selected'}
    '0x801c000e' = @{Desc='Registration failed (federation issue)';Fix='Check Azure AD Connect sync status. Verify federation trust. Run: dsregcmd /debug'}
    '0x80090016' = @{Desc='TPM attestation error during join';Fix='1) Clear TPM in BIOS. 2) Run tpm.msc > Clear TPM. 3) Reboot. 4) Retry join'}
    '0x80070774' = @{Desc='RPC server unavailable (DC unreachable)';Fix='Check network to domain controller. Verify DNS points to DC. Run: nltest /dsgetdc:domain'}
    '0x8018000a' = @{Desc='Device already enrolled in different MDM';Fix='Settings > Accounts > Access work or school > Disconnect existing MDM, then re-enroll'}
    '0x80180018' = @{Desc='MDM Terms of Use not accepted';Fix='User must accept ToU during enrollment. Check Intune > Tenant admin > Terms and conditions'}
    '0x80072ee7' = @{Desc='Server name cannot be resolved';Fix='Check DNS. Ensure *.microsoft.com resolves. Try: nslookup login.microsoftonline.com'}
    '0x80072f8f' = @{Desc='SSL/TLS certificate validation failed';Fix='1) Check system clock (must be accurate). 2) Install root certs. 3) Disable SSL inspection for MS endpoints'}
    '0x801c001d' = @{Desc='MFA required for Azure AD Join';Fix='User must complete MFA during join. Ensure MFA method registered at aka.ms/mysecurityinfo'}
    '0xCAA2000C' = @{Desc='Conditional Access policy blocked enrollment';Fix='Check CA policies in Entra ID > Security > Conditional Access. Look for device-state requirements'}
    '0xCAA20004' = @{Desc='Server validation failed (proxy interference)';Fix='Disable SSL/TLS inspection for *.microsoft.com, *.microsoftonline.com, *.windows.net'}
    '0x80072EFD' = @{Desc='Cannot connect to enrollment server';Fix='Check internet. Verify DNS for login.microsoftonline.com. Check proxy settings'}
    '0x80070005' = @{Desc='Access denied (insufficient privileges)';Fix='Run enrollment as local administrator. Or grant user the "Allow users to join" right in Entra ID'}
    '0x801c03f2' = @{Desc='Hybrid join failed - SCP not found';Fix='Configure Service Connection Point in AD. Run: dsregcmd /debug to check SCP discovery'}
    '0x801c03f0' = @{Desc='Hybrid join - device object not found in AD';Fix='Ensure Azure AD Connect device writeback is configured. Check AD Sites and Services'}
    '0x80192ee2' = @{Desc='HTTP 404 - enrollment endpoint not found';Fix='Check that Intune is properly licensed and configured. Verify tenant MDM settings'}
    '0x80180002' = @{Desc='MDM enrollment - user already enrolled';Fix='Unenroll user first: Settings > Accounts > Access work or school > Disconnect'}
    '0x801c03ea' = @{Desc='Server returned HTTP 409 - conflict';Fix='Device object exists in Entra ID. Delete stale device and retry'}
    '0x80004005' = @{Desc='General failure (E_FAIL)';Fix='Run: dsregcmd /debug for detailed error. Check event log: Microsoft-Windows-AAD/Operational'}
    '0x801c044c' = @{Desc='CSR request failed during join';Fix='TPM may be in bad state. Clear TPM in BIOS settings, reboot, retry'}
    '0x80070032' = @{Desc='Request not supported (wrong OS edition)';Fix='Azure AD Join requires Windows 10/11 Pro, Enterprise, or Education. Home edition not supported'}
    '0xCAA50024' = @{Desc='User cancelled authentication';Fix='User must complete the sign-in flow. Do not close the authentication window'}
}

# ============================================================
# HEADER
# ============================================================
$Hostname  = $env:COMPUTERNAME
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$DateHuman = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$UserName  = "$env:USERDOMAIN\$env:USERNAME"

Write-Host ''
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host '  FieldOps Pro - Azure AD Enrollment Engine' -ForegroundColor DarkCyan
Write-Host "  Host: $Hostname | User: $UserName" -ForegroundColor Gray
Write-Host "  $DateHuman$(if($TenantHint){" | Tenant: $TenantHint"})" -ForegroundColor Gray
if (-not $script:IsAdmin) { Write-Host '  WARNING: Not admin. Enrollment actions limited.' -ForegroundColor Yellow }
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host ''

# ============================================================
# PRE-FLIGHT: WiFi Profile Import
# ============================================================
if ($ImportWiFi -and (Test-Path $ImportWiFi)) {
    Write-Host '[Pre-Flight] Importing WiFi Profile...' -ForegroundColor Yellow
    try {
        netsh wlan add profile filename="$ImportWiFi" user=all 2>$null | Out-Null
        Write-Host "  [OK] WiFi profile imported: $ImportWiFi" -ForegroundColor Green
    } catch { Write-Host "  [FAIL] Import failed: $($_.Exception.Message)" -ForegroundColor Red }
    Write-Host ''
}

# ============================================================
# PRE-FLIGHT: WiFi Profile Export
# ============================================================
if ($ExportWiFi) {
    Write-Host '[Pre-Flight] Exporting WiFi Profiles...' -ForegroundColor Yellow
    $wifiExportDir = Join-Path $ReportsPath "WiFiProfiles_${Hostname}"
    if (-not (Test-Path $wifiExportDir)) { New-Item -Path $wifiExportDir -ItemType Directory -Force | Out-Null }
    try {
        netsh wlan export profile folder="$wifiExportDir" key=clear 2>$null | Out-Null
        $exported = @(Get-ChildItem $wifiExportDir -Filter '*.xml').Count
        Write-Host "  [OK] $exported profile(s) exported to: $wifiExportDir" -ForegroundColor Green
    } catch { Write-Host "  [FAIL] Export failed: $($_.Exception.Message)" -ForegroundColor Red }
    Write-Host ''
}

# ============================================================
# PRE-FLIGHT: Save Before Snapshot
# ============================================================
$script:BeforeState = $null
if ($Snapshot) {
    Write-Host '[Pre-Flight] Capturing Before Snapshot...' -ForegroundColor Yellow
    try {
        $dsSnapBefore = dsregcmd /status 2>$null | Out-String
        $script:BeforeState = @{
            Timestamp = $DateHuman
            DsRegRaw  = $dsSnapBefore
            AzureAdJoined = ($dsSnapBefore -match 'AzureAdJoined\s*:\s*YES')
            DomainJoined  = ($dsSnapBefore -match 'DomainJoined\s*:\s*YES')
            WorkplaceJoined = ($dsSnapBefore -match 'WorkplaceJoined\s*:\s*YES')
            MdmEnrolled = ($dsSnapBefore -match 'MdmUrl\s*:\s*https')
            TenantName = if ($dsSnapBefore -match 'TenantName\s*:\s*(.+)') { $Matches[1].Trim() } else { '' }
            DeviceId = if ($dsSnapBefore -match 'DeviceId\s*:\s*(\S+)') { $Matches[1].Trim() } else { '' }
        }
        $snapFile = Join-Path $SnapshotDir "Before_${Hostname}_${Timestamp}.json"
        $script:BeforeState | ConvertTo-Json -Depth 3 | Out-File $snapFile -Encoding UTF8 -Force
        Write-Host "  [OK] Before snapshot saved: $snapFile" -ForegroundColor Green
    } catch { Write-Host "  [WARN] Snapshot failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    Write-Host ''
}

# ============================================================
# [1/14] DSREGCMD INTELLIGENCE PARSER
# ============================================================
Write-Host '[1/14] Directory Registration Intelligence' -ForegroundColor White

$script:DsReg = @{}
$script:DsRegRaw = ''
try {
    $dsOutput = dsregcmd /status 2>$null
    $script:DsRegRaw = $dsOutput -join "`n"
    $currentSection = 'General'
    foreach ($line in $dsOutput) {
        if ($line -match '^\|\s*(.+?)\s*\|') { $currentSection = $Matches[1].Trim() -replace '\s+', '' }
        elseif ($line -match '^\s+(\w[\w\s]*\w)\s*:\s*(.*)') {
            $key = $Matches[1].Trim(); $val = $Matches[2].Trim()
            $script:DsReg["${currentSection}_${key}"] = $val
            if (-not $script:DsReg.ContainsKey($key)) { $script:DsReg[$key] = $val }
        }
    }

    $aadJoined       = ($script:DsReg['AzureAdJoined'] -eq 'YES')
    $domainJoined    = ($script:DsReg['DomainJoined'] -eq 'YES')
    $workplaceJoined = ($script:DsReg['WorkplaceJoined'] -eq 'YES')
    $mdmEnrolled     = ($script:DsReg['MdmUrl'] -and $script:DsReg['MdmUrl'] -match 'https')
    $tenantName      = if ($script:DsReg['TenantName']) { $script:DsReg['TenantName'] } else { 'Unknown' }
    $tenantId        = if ($script:DsReg['TenantId']) { $script:DsReg['TenantId'] } else { 'Not set' }
    $deviceId        = if ($script:DsReg['DeviceId']) { $script:DsReg['DeviceId'] } else { 'Not registered' }

    $joinState = if ($aadJoined -and $domainJoined) {'Hybrid Azure AD Joined'}
                 elseif ($aadJoined) {'Azure AD Joined'}
                 elseif ($domainJoined) {'Domain Joined (on-prem)'}
                 elseif ($workplaceJoined) {'Workplace Joined (registered)'}
                 else {'Not joined'}

    Add-Check -Category 'DsReg' -Check 'Join State' -Status $(if($aadJoined){'Pass'}elseif($workplaceJoined){'Warning'}else{'Info'}) `
        -Value $joinState -Detail "AAD: $(if($aadJoined){'Y'}else{'N'}) | Domain: $(if($domainJoined){'Y'}else{'N'}) | WPJ: $(if($workplaceJoined){'Y'}else{'N'})"
    Add-Check -Category 'DsReg' -Check 'Tenant' -Status $(if($tenantName -ne 'Unknown'){'Pass'}else{'Info'}) -Value $tenantName -Detail "ID: $tenantId"
    Add-Check -Category 'DsReg' -Check 'Device ID' -Status $(if($deviceId -ne 'Not registered'){'Pass'}else{'Info'}) -Value $deviceId -Detail 'Azure AD device identity'

    $mdmUrl = if ($script:DsReg['MdmUrl']) { $script:DsReg['MdmUrl'] } else { 'Not enrolled' }
    Add-Check -Category 'DsReg' -Check 'MDM Enrollment' -Status $(if($mdmEnrolled){'Pass'}else{'Warning'}) `
        -Value $(if($mdmEnrolled){'Enrolled'}else{'Not enrolled'}) -Detail "URL: $mdmUrl"

    $prtHas = ($script:DsReg['AzureAdPrt'] -eq 'YES')
    $ssoState = if ($prtHas) {'PRT acquired (SSO active)'} elseif ($script:DsReg['AzureAdPrtAuthority']) {'PRT authority set'} else {'No PRT'}
    Add-Check -Category 'DsReg' -Check 'SSO / PRT' -Status $(if($prtHas){'Pass'}else{'Warning'}) -Value $ssoState -Detail 'Primary Refresh Token'

    $ngcSet = ($script:DsReg['NgcSet'] -eq 'YES')
    Add-Check -Category 'DsReg' -Check 'Windows Hello for Business' -Status $(if($ngcSet){'Pass'}else{'Info'}) `
        -Value $(if($ngcSet){'Configured'}else{'Not configured'}) -Detail 'Passwordless auth'

    # Certificate validity
    $certExpiry = $script:DsReg['DeviceCertificateValidity']
    if ($certExpiry -and $certExpiry -match '(\d{4}-\d{2}-\d{2}).*--.*(\d{4}-\d{2}-\d{2})') {
        $certEnd = [datetime]$Matches[2]; $daysLeft = ($certEnd - (Get-Date)).Days
        Add-Check -Category 'DsReg' -Check 'Device Certificate' -Status $(if($daysLeft -gt 365){'Pass'}elseif($daysLeft -gt 30){'Warning'}else{'Fail'}) `
            -Value "$daysLeft days left" -Detail $certExpiry
    }

    if (-not $aadJoined -and -not $workplaceJoined) {
        Add-Finding -Severity 'Info' -Title 'Device not joined to Azure AD' -Detail "Current: $joinState" `
            -Action 'Proceed with enrollment.' -FixCommands @(
                @{Desc='Azure AD Join (Settings)';Cmd='Start-Process "ms-settings:workplace"'}
                @{Desc='Azure AD Join (CLI)';Cmd='dsregcmd /join /debug'}
            )
    }
} catch {
    Add-Check -Category 'DsReg' -Check 'dsregcmd' -Status 'Fail' -Value 'Cannot execute' -Detail $_.Exception.Message
}

Save-SectionScore -Section 'DsReg' -Category 'DsReg'

# ============================================================
# [2/14] HARDWARE READINESS (weighted)
# ============================================================
Write-Host ''
Write-Host '[2/14] Hardware & System Readiness' -ForegroundColor White

try {
    $tpm = Get-Tpm -ErrorAction Stop
    $tpmVer = ''; try { $tw = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop; $tpmVer = $tw.SpecVersion.Split(',')[0].Trim() } catch {}
    $tpmOk = ($tpm.TpmPresent -and $tpm.TpmReady)
    Add-Readiness -Category 'Hardware' -Check 'TPM' -Status $(if($tpmOk){'Pass'}elseif($tpm.TpmPresent){'Warning'}else{'Fail'}) `
        -Value "Present: $($tpm.TpmPresent) | Ready: $($tpm.TpmReady)$(if($tpmVer){" | v$tpmVer"})" -Detail 'Required for join + compliance' -Weight 3
    if (-not $tpm.TpmPresent) {
        Add-Finding -Severity 'Critical' -Title 'No TPM' -Detail 'Required for Azure AD Join.' `
            -Action 'Enable TPM in BIOS.' -FixCommands @(@{Desc='Check TPM';Cmd='Get-Tpm | Format-List *'}) -FixMinutes 10
    }
} catch { Add-Readiness -Category 'Hardware' -Check 'TPM' -Status 'Fail' -Value 'Cannot query' -Detail $_.Exception.Message -Weight 3 }

try {
    $sb = Confirm-SecureBootUEFI -ErrorAction Stop
    Add-Readiness -Category 'Hardware' -Check 'Secure Boot' -Status $(if($sb){'Pass'}else{'Warning'}) `
        -Value $(if($sb){'Enabled'}else{'Disabled'}) -Detail 'Compliance requirement' -Weight 2
} catch { Add-Readiness -Category 'Hardware' -Check 'Secure Boot' -Status 'Info' -Value 'Cannot query' -Detail $_.Exception.Message -Weight 2 }

# System clock (critical for tokens)
try {
    $ntpOut = w32tm /stripchart /computer:time.windows.com /dataonly /samples:1 2>$null | Select-Object -Last 1
    $clockOk = $true; $offStr = 'Unknown'
    if ($ntpOut -match '([+-]?\d+[\.,]\d+)s') {
        $offSec = [double]($Matches[1] -replace ',', '.'); $offStr = "$([math]::Round($offSec, 2))s"
        $clockOk = ([math]::Abs($offSec) -lt 300)
    }
    Add-Readiness -Category 'Hardware' -Check 'System Clock (NTP)' -Status $(if($clockOk){'Pass'}else{'Fail'}) `
        -Value $offStr -Detail 'Skew > 5min breaks token validation' -Weight 3
    if (-not $clockOk) {
        Add-Finding -Severity 'Critical' -Title "Clock skew: $offStr" -Detail 'Tokens will fail.' `
            -Action 'Sync clock.' -FixCommands @(
                @{Desc='Force NTP sync';Cmd='w32tm /resync /force; Write-Host "Synced"'}
                @{Desc='Set MS time server';Cmd='w32tm /config /manualpeerlist:"time.windows.com" /syncfromflags:manual /update; w32tm /resync'}
            ) -FixMinutes 2
    }
} catch { Add-Readiness -Category 'Hardware' -Check 'Clock' -Status 'Info' -Value 'Cannot test' -Detail $_.Exception.Message -Weight 3 }

# OS Edition
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $isHome = ($os.Caption -match 'Home|Famille')
    Add-Readiness -Category 'Hardware' -Check 'Windows Edition' -Status $(if(-not $isHome){'Pass'}else{'Fail'}) `
        -Value $os.Caption -Detail $(if($isHome){'Home CANNOT join AAD'}else{'Pro/Ent - capable'}) -Weight 3
    if ($isHome) {
        Add-Finding -Severity 'Critical' -Title 'Windows Home detected' -Detail 'Cannot Azure AD Join.' `
            -Action 'Upgrade to Pro.' -FixCommands @(@{Desc='Open activation';Cmd='Start-Process "ms-settings:activation"'}) -FixMinutes 30
    }
} catch {}

# Disk space
try {
    $sd = Get-Volume -DriveLetter C -ErrorAction Stop; $fGB = [math]::Round($sd.SizeRemaining / 1GB, 1)
    Add-Readiness -Category 'Hardware' -Check 'Disk Space' -Status $(if($fGB -ge 10){'Pass'}elseif($fGB -ge 5){'Warning'}else{'Fail'}) `
        -Value "$fGB GB free on C:" -Detail 'Intune apps need space' -Weight 1
} catch {}

# BitLocker
try {
    $blOs = Get-BitLockerVolume -ErrorAction Stop | Where-Object {$_.VolumeType -eq 'OperatingSystem'} | Select-Object -First 1
    $blOn = ($blOs -and $blOs.ProtectionStatus -eq 'On')
    Add-Readiness -Category 'Hardware' -Check 'BitLocker (OS)' -Status $(if($blOn){'Pass'}else{'Warning'}) `
        -Value $(if($blOn){"Encrypted ($($blOs.EncryptionMethod))"}else{'Not encrypted'}) -Detail 'Most compliance policies require this' -Weight 2
} catch {}

Save-SectionScore -Section 'Hardware' -Category 'Hardware'

# ============================================================
# [3/14] CONDITIONAL ACCESS PRE-CHECK
# ============================================================
Write-Host ''
Write-Host '[3/14] Conditional Access Readiness' -ForegroundColor White

# Check factors that Conditional Access policies commonly require
$caFactors = @{MFA = $false; Compliant = $false; HybridJoined = $false; TrustedLocation = $false; ManagedDevice = $false}

# MFA readiness (check if user has MFA methods)
try {
    $ngcSet2 = ($script:DsReg['NgcSet'] -eq 'YES')
    $hasPrt = ($script:DsReg['AzureAdPrt'] -eq 'YES')
    $mfaReady = ($ngcSet2 -or $hasPrt)
    $caFactors.MFA = $mfaReady
    Add-Check -Category 'CondAccess' -Check 'MFA Readiness' -Status $(if($mfaReady){'Pass'}else{'Warning'}) `
        -Value $(if($mfaReady){"Ready ($(if($ngcSet2){'WHfB'}else{'PRT'}))"}else{'Not configured'}) `
        -Detail 'MFA is required by most CA policies. WHfB or PRT satisfies MFA.'
} catch {}

# Compliance readiness
$caFactors.Compliant = $blOn -and $tpmOk
Add-Check -Category 'CondAccess' -Check 'Compliance Factors' -Status $(if($caFactors.Compliant){'Pass'}else{'Warning'}) `
    -Value "BitLocker: $(if($blOn){'Y'}else{'N'}) | TPM: $(if($tpmOk){'Y'}else{'N'}) | SecureBoot: $(if($sb){'Y'}else{'N'})" `
    -Detail 'Common compliance policy requirements'

# Hybrid join status
$caFactors.HybridJoined = ($aadJoined -and $domainJoined)
if ($domainJoined) {
    Add-Check -Category 'CondAccess' -Check 'Hybrid Join Status' -Status $(if($caFactors.HybridJoined){'Pass'}else{'Warning'}) `
        -Value $(if($caFactors.HybridJoined){'Hybrid Joined'}else{'Domain only - hybrid sync needed'}) `
        -Detail 'Some CA policies require Hybrid Azure AD Join'
}

# Managed device check
$caFactors.ManagedDevice = $mdmEnrolled
Add-Check -Category 'CondAccess' -Check 'MDM Managed Device' -Status $(if($caFactors.ManagedDevice){'Pass'}else{'Warning'}) `
    -Value $(if($caFactors.ManagedDevice){'Intune managed'}else{'Not MDM managed'}) `
    -Detail 'CA policies may require device to be Intune-managed'

# Overall CA readiness score
$caReady = @($caFactors.Values | Where-Object { $_ -eq $true }).Count
$caTotal = $caFactors.Count
Add-Check -Category 'CondAccess' -Check 'CA Readiness Score' -Status $(if($caReady -ge 3){'Pass'}elseif($caReady -ge 2){'Warning'}else{'Fail'}) `
    -Value "$caReady/$caTotal factors met" -Detail 'Conditional Access policy pre-check'

if ($caReady -lt 3) {
    $missingFactors = @($caFactors.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }) -join ', '
    Add-Finding -Severity 'Warning' -Title "CA pre-check: $caReady/$caTotal factors met" `
        -Detail "Missing: $missingFactors. Enrollment may be blocked by Conditional Access." `
        -Action 'Address missing factors before enrollment.' `
        -FixCommands @(
            @{Desc='Register MFA at aka.ms/mysecurityinfo';Cmd='Start-Process "https://aka.ms/mysecurityinfo"; Write-Host "Opening MFA registration..."'}
            @{Desc='Check CA policies affecting this device';Cmd='Write-Host "Sign in to portal.azure.com > Entra ID > Security > Conditional Access > What If tool"'}
        )
}

Save-SectionScore -Section 'CondAccess' -Category 'CondAccess'

# ============================================================
# [4/14] NETWORK & ENDPOINT VALIDATION
# ============================================================
Write-Host ''
Write-Host '[4/14] Enrollment Endpoint Validation' -ForegroundColor White

$script:EndpointData = [System.Collections.ArrayList]::new()

$endpoints = @(
    @{Name='Azure AD Login';Host='login.microsoftonline.com';Port=443;Critical=$true;Service='Auth'}
    @{Name='MS Graph';Host='graph.microsoft.com';Port=443;Critical=$true;Service='Auth'}
    @{Name='Enterprise Registration';Host='enterpriseregistration.windows.net';Port=443;Critical=$true;Service='Enrollment'}
    @{Name='Enterprise Enrollment';Host='enterpriseenrollment.manage.microsoft.com';Port=443;Critical=$true;Service='Enrollment'}
    @{Name='Device Registration';Host='device.login.microsoftonline.com';Port=443;Critical=$true;Service='Enrollment'}
    @{Name='Intune MDM';Host='manage.microsoft.com';Port=443;Critical=$true;Service='Intune'}
    @{Name='Intune Enrollment';Host='enrollment.manage.microsoft.com';Port=443;Critical=$true;Service='Intune'}
    @{Name='Intune Config';Host='config.office.com';Port=443;Critical=$false;Service='Intune'}
    @{Name='Windows Update';Host='windowsupdate.microsoft.com';Port=443;Critical=$false;Service='Updates'}
    @{Name='Autopilot ZTDAPI';Host='ztd.dds.microsoft.com';Port=443;Critical=$false;Service='Autopilot'}
    @{Name='Autopilot Svc';Host='cs.dds.microsoft.com';Port=443;Critical=$false;Service='Autopilot'}
    @{Name='Microsoft CRL';Host='crl.microsoft.com';Port=80;Critical=$true;Service='Certs'}
    @{Name='OCSP';Host='ocsp.msocsp.com';Port=80;Critical=$false;Service='Certs'}
    @{Name='Office Activation';Host='activation.sls.microsoft.com';Port=443;Critical=$false;Service='Licensing'}
    @{Name='Compliance';Host='compliance.microsoft.com';Port=443;Critical=$false;Service='Compliance'}
    @{Name='Device Attestation';Host='has.spserv.microsoft.com';Port=443;Critical=$false;Service='Attestation'}
    @{Name='Defender Updates';Host='definitionupdates.microsoft.com';Port=443;Critical=$false;Service='Security'}
)

$critFail = 0; $totalEndpoints = $endpoints.Count; $passEndpoints = 0

foreach ($ep in $endpoints) {
    try {
        $ok = Test-TcpPort -H $ep.Host -P $ep.Port -T 3000
        if ($ok) { $passEndpoints++ }
        $st = if ($ok) {'Pass'} elseif ($ep.Critical) {'Fail'} else {'Warning'}
        if (-not $ok -and $ep.Critical) { $critFail++ }
        Add-Check -Category 'Endpoints' -Check $ep.Name -Status $st `
            -Value "$(if($ok){'OK'}else{'BLOCKED'}) | $($ep.Host):$($ep.Port)" -Detail "Svc: $($ep.Service) | Crit: $($ep.Critical)"
        $null = $script:EndpointData.Add([PSCustomObject]@{Name=$ep.Name;Host=$ep.Host;Port=$ep.Port;Ok=$ok;Critical=$ep.Critical;Service=$ep.Service})
        if (-not $ok -and $ep.Critical) {
            Add-Finding -Severity 'Critical' -Title "BLOCKED: $($ep.Name)" -Detail "$($ep.Host):$($ep.Port) unreachable" `
                -Action 'Check firewall/proxy.' -FixCommands @(
                    @{Desc="Test $($ep.Host)";Cmd="Resolve-DnsName '$($ep.Host)' -EA SilentlyContinue | Format-Table; Test-NetConnection '$($ep.Host)' -Port $($ep.Port) -InformationLevel Detailed"}
                    @{Desc='Show proxy';Cmd='netsh winhttp show proxy'}
                )
        }
    } catch {}
}

$epPct = if ($totalEndpoints -gt 0) {[math]::Round(($passEndpoints/$totalEndpoints)*100,0)} else {0}
Add-Check -Category 'Endpoints' -Check 'Summary' -Status $(if($critFail -eq 0 -and $epPct -ge 80){'Pass'}elseif($critFail -eq 0){'Warning'}else{'Fail'}) `
    -Value "$passEndpoints/$totalEndpoints ($epPct%) | $critFail critical blocked" -Detail 'All critical must be reachable'

# DNS resolution for key domains
foreach ($dt in @('login.microsoftonline.com','enterpriseregistration.windows.net','manage.microsoft.com')) {
    try {
        $res = @(Resolve-DnsName $dt -Type A -DnsOnly -ErrorAction Stop | Where-Object {$_.QueryType -eq 'A'} | Select-Object -First 1)
        Add-Check -Category 'Endpoints' -Check "DNS: $dt" -Status $(if($res.Count -gt 0){'Pass'}else{'Fail'}) `
            -Value $(if($res.Count -gt 0){$res[0].IPAddress}else{'FAILED'}) -Detail 'DNS for enrollment'
    } catch { Add-Check -Category 'Endpoints' -Check "DNS: $dt" -Status 'Fail' -Value 'Failed' -Detail $_.Exception.Message }
}

Save-SectionScore -Section 'Endpoints' -Category 'Endpoints'

# ============================================================
# [5/14] AUTOPILOT READINESS
# ============================================================
Write-Host ''
Write-Host '[5/14] Autopilot Readiness' -ForegroundColor White

$script:AutopilotHash = $null; $serial = 'Unknown'
try {
    $session = New-CimSession -ErrorAction Stop
    $devD = Get-CimInstance -CimSession $session -Namespace 'root/cimv2/mdm/dmmap' -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" -ErrorAction Stop
    if ($devD -and $devD.DeviceHardwareData) {
        $script:AutopilotHash = $devD.DeviceHardwareData
        Add-Check -Category 'Autopilot' -Check 'Hardware Hash' -Status 'Pass' -Value "Extracted ($($script:AutopilotHash.Length) chars)" -Detail 'Ready for Autopilot registration'
    } else { Add-Check -Category 'Autopilot' -Check 'Hardware Hash' -Status 'Warning' -Value 'Could not extract' -Detail 'May need admin' }
    Remove-CimSession $session -ErrorAction SilentlyContinue
} catch { Add-Check -Category 'Autopilot' -Check 'Hardware Hash' -Status 'Info' -Value 'Cannot extract' -Detail $_.Exception.Message }

try { $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop; $serial = $bios.SerialNumber; Add-Check -Category 'Autopilot' -Check 'Serial' -Status 'Pass' -Value $serial -Detail 'For Autopilot registration' } catch {}
try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; Add-Check -Category 'Autopilot' -Check 'Model' -Status 'Info' -Value "$($cs.Manufacturer) $($cs.Model)" -Detail 'Profile assignment' } catch {}

# Autopilot profile
try {
    $apProf = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Provisioning\AutopilotPolicyCache' -ErrorAction SilentlyContinue
    $apDiag = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\AutoPilot' -ErrorAction SilentlyContinue
    $profFound = ($apProf -ne $null -or $apDiag -ne $null)
    $apTenant = if ($apDiag -and $apDiag.CloudAssignedTenantId) { $apDiag.CloudAssignedTenantId } else { '' }
    Add-Check -Category 'Autopilot' -Check 'Profile' -Status $(if($profFound){'Pass'}else{'Info'}) `
        -Value $(if($profFound){"Cached$(if($apTenant){" (Tenant: $apTenant)"})"}else{'Not registered'}) -Detail 'Autopilot deployment profile'
} catch {}

Add-Finding -Severity 'Info' -Title 'Autopilot Hash Export' `
    -Detail "Serial: $serial | Hash: $(if($script:AutopilotHash){'Available'}else{'Not extracted'})" `
    -Action 'Export for registration.' -FixCommands @(
        @{Desc='Export hash to CSV';Cmd="try { if (-not (Get-InstalledScript 'Get-WindowsAutoPilotInfo' -EA SilentlyContinue)) { Install-Script Get-WindowsAutoPilotInfo -Force }; Get-WindowsAutoPilotInfo -OutputFile '$ReportsPath\AutopilotHash_${Hostname}.csv'; Write-Host 'Exported' } catch { Write-Host 'Install NuGet first: Install-PackageProvider NuGet -Force' -ForegroundColor Yellow }"}
        @{Desc='Manual hash extract';Cmd="[System.Convert]::ToBase64String((Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -Class MDM_DevDetail_Ext01 -Filter `"InstanceID='Ext' AND ParentID='./DevDetail'`").DeviceHardwareData) | Out-File '$ReportsPath\Hash_${Hostname}.txt'; Write-Host 'Hash saved'"}
    )

Save-SectionScore -Section 'Autopilot' -Category 'Autopilot'

# ============================================================
# [6/14] MDM & COMPLIANCE
# ============================================================
Write-Host ''
Write-Host '[6/14] MDM & Compliance' -ForegroundColor White

try {
    $mdmPath = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path $mdmPath) {
        $enrollments = @(Get-ChildItem $mdmPath -ErrorAction Stop | Where-Object { $_.PSChildName -match '^[0-9a-f]{8}-' })
        if ($enrollments.Count -gt 0) {
            foreach ($enr in $enrollments) {
                try {
                    $ep2 = Get-ItemProperty $enr.PSPath -ErrorAction Stop
                    $prov = if ($ep2.ProviderID) {$ep2.ProviderID} else {'Unknown'}
                    $upn = if ($ep2.UPN) {$ep2.UPN} else {'Unknown'}
                    $eType = switch ($ep2.EnrollmentType) {1{'User'}6{'Device'}13{'Autopilot'}default{"Type $($ep2.EnrollmentType)"}}
                    Add-Check -Category 'MDM' -Check "MDM: $prov" -Status 'Pass' -Value "Enrolled ($eType) | $upn" -Detail "ID: $($enr.PSChildName)"
                } catch {}
            }
        } else { Add-Check -Category 'MDM' -Check 'MDM' -Status 'Warning' -Value 'Not enrolled' -Detail 'No MDM entries' }
    } else { Add-Check -Category 'MDM' -Check 'MDM' -Status 'Warning' -Value 'No enrollment data' -Detail 'Registry key missing' }
} catch {}

try {
    $imeSvc = Get-Service IntuneManagementExtension -ErrorAction SilentlyContinue
    if ($imeSvc) { Add-Check -Category 'MDM' -Check 'Intune Mgmt Extension' -Status $(if($imeSvc.Status -eq 'Running'){'Pass'}else{'Warning'}) -Value $imeSvc.Status.ToString() -Detail 'Win32 apps + PS scripts' }
    else { Add-Check -Category 'MDM' -Check 'Intune Mgmt Extension' -Status 'Info' -Value 'Not installed' -Detail 'Auto-installs after enrollment' }
} catch {}

Save-SectionScore -Section 'MDM' -Category 'MDM'

# ============================================================
# [7/14] CERTIFICATES
# ============================================================
Write-Host ''
Write-Host '[7/14] Certificate Validation' -ForegroundColor White

try {
    $mCerts = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object {$_.NotAfter -gt (Get-Date)})
    Add-Check -Category 'Certs' -Check 'Machine Certs' -Status $(if($mCerts.Count -gt 0){'Pass'}else{'Info'}) -Value "$($mCerts.Count) valid" -Detail 'Personal store'
    $aadCert = $mCerts | Where-Object { $_.Issuer -match 'MS-Organization-Access|Azure' }
    if ($aadCert) {
        $dl = ($aadCert[0].NotAfter - (Get-Date)).Days
        Add-Check -Category 'Certs' -Check 'AAD Device Cert' -Status $(if($dl -gt 30){'Pass'}elseif($dl -gt 7){'Warning'}else{'Fail'}) `
            -Value "$dl days left" -Detail "Expires: $($aadCert[0].NotAfter.ToString('yyyy-MM-dd'))"
    } else { Add-Check -Category 'Certs' -Check 'AAD Device Cert' -Status 'Info' -Value 'Not found' -Detail 'Created during join' }
} catch {}

try {
    $roots = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction Stop | Where-Object {$_.Subject -match 'Microsoft|DigiCert|Baltimore'})
    Add-Check -Category 'Certs' -Check 'MS Root CAs' -Status $(if($roots.Count -ge 3){'Pass'}else{'Warning'}) -Value "$($roots.Count) trusted" -Detail 'Microsoft trust chain'
} catch {}

Save-SectionScore -Section 'Certs' -Category 'Certs'

# ============================================================
# [8/14] WIFI PROFILE MANAGEMENT
# ============================================================
Write-Host ''
Write-Host '[8/14] WiFi Profile Management' -ForegroundColor White

$script:WiFiProfiles = [System.Collections.ArrayList]::new()
try {
    $wlanProfiles = netsh wlan show profiles 2>$null
    $profileNames = @($wlanProfiles | Where-Object { $_ -match ':\s+(.+)$' } | ForEach-Object { $Matches[1].Trim() })
    Add-Check -Category 'WiFi' -Check 'Saved WiFi Profiles' -Status 'Info' -Value "$($profileNames.Count) profile(s)" -Detail ($profileNames | Select-Object -First 5) -join ', '
    foreach ($pn in $profileNames) { $null = $script:WiFiProfiles.Add($pn) }

    # Check if currently connected
    $wlanInt = netsh wlan show interfaces 2>$null | Out-String
    $connSSID = if ($wlanInt -match 'SSID\s*:\s*(.+)' -and $wlanInt -notmatch 'BSSID') { $Matches[1].Trim() } else { $null }
    if ($connSSID) {
        Add-Check -Category 'WiFi' -Check 'Current WiFi' -Status 'Pass' -Value $connSSID -Detail 'Connected network'
    }
} catch {}

# WiFi management commands
Add-Finding -Severity 'Info' -Title 'WiFi Profile Management' `
    -Detail "$($profileNames.Count) saved profiles. $(if($connSSID){"Connected to: $connSSID"}else{'Not connected to WiFi'})" `
    -Action 'Import/export WiFi profiles for deployment.' `
    -FixCommands @(
        @{Desc='Export all WiFi profiles (with keys)';Cmd="New-Item -Path '$ReportsPath\WiFi_${Hostname}' -ItemType Directory -Force | Out-Null; netsh wlan export profile folder='$ReportsPath\WiFi_${Hostname}' key=clear; Write-Host 'Exported to $ReportsPath\WiFi_${Hostname}'"}
        @{Desc='Import WiFi profile from XML';Cmd="Write-Host 'Usage: .\Invoke-AzureADJoin.ps1 -ImportWiFi `"path\to\profile.xml`"'"}
        @{Desc='Show available networks';Cmd='netsh wlan show networks mode=bssid'}
        @{Desc='Connect to known network';Cmd="Write-Host 'Available profiles:'; netsh wlan show profiles | Select-String ':'"}
    )

Save-SectionScore -Section 'WiFi' -Category 'WiFi'

# ============================================================
# [9/14] JOIN PATH RECOMMENDATION
# ============================================================
Write-Host ''
Write-Host '[9/14] Join Path Recommendation' -ForegroundColor White

$recommendedPath = 'None'; $pathDetail = ''; $pathActions = [System.Collections.ArrayList]::new()
$pipelineSteps = [System.Collections.ArrayList]::new()

if ($aadJoined -and $domainJoined) {
    $recommendedPath = 'COMPLETE - Hybrid Azure AD Joined'
    $pathDetail = 'Fully hybrid joined. Both AD and AAD identities active.'
    Add-Check -Category 'JoinPath' -Check 'Recommended' -Status 'Pass' -Value $recommendedPath -Detail $pathDetail
    $null = $pipelineSteps.Add(@{Label='Hybrid Joined';Status='done'})
} elseif ($aadJoined) {
    $recommendedPath = 'COMPLETE - Azure AD Joined'
    $pathDetail = 'Cloud-native joined. Full Intune available.'
    Add-Check -Category 'JoinPath' -Check 'Recommended' -Status 'Pass' -Value $recommendedPath -Detail $pathDetail
    $null = $pipelineSteps.Add(@{Label='AAD Joined';Status='done'})
} elseif ($domainJoined) {
    $recommendedPath = 'UPGRADE: Enable Hybrid Join'
    $pathDetail = 'Domain-joined, not synced to AAD. Configure Azure AD Connect.'
    Add-Check -Category 'JoinPath' -Check 'Recommended' -Status 'Warning' -Value $recommendedPath -Detail $pathDetail
    $null = $pathActions.Add(@{Desc='Check AD Connect sync';Cmd='dsregcmd /status /debug | Select-String "DomainJoined|AzureAdJoined|Hybrid"'})
    $null = $pathActions.Add(@{Desc='Force sync';Cmd='dsregcmd /join /debug'})
    $null = $pipelineSteps.Add(@{Label='Domain Joined';Status='done'})
    $null = $pipelineSteps.Add(@{Label='Hybrid Sync';Status='action'})
    $null = $pipelineSteps.Add(@{Label='AAD Registered';Status='pending'})
} elseif ($workplaceJoined) {
    $recommendedPath = 'UPGRADE: Workplace Join -> Azure AD Join'
    $pathDetail = 'Workplace-joined only. Remove WPJ, then full AAD Join.'
    Add-Check -Category 'JoinPath' -Check 'Recommended' -Status 'Warning' -Value $recommendedPath -Detail $pathDetail
    $null = $pathActions.Add(@{Desc='Remove workplace join';Cmd='dsregcmd /leave; Write-Host "Removed. Now AAD Join."'})
    $null = $pathActions.Add(@{Desc='Open AAD Join';Cmd='Start-Process "ms-settings:workplace"'})
    $null = $pipelineSteps.Add(@{Label='WPJ';Status='done'})
    $null = $pipelineSteps.Add(@{Label='Remove WPJ';Status='action'})
    $null = $pipelineSteps.Add(@{Label='AAD Join';Status='pending'})
    $null = $pipelineSteps.Add(@{Label='MDM Enroll';Status='pending'})
} else {
    $hasNet = (Test-TcpPort -H 'login.microsoftonline.com' -P 443 -T 3000)
    if ($hasNet) {
        $recommendedPath = 'ENROLL: Azure AD Join (Cloud-Native)'
        $pathDetail = 'Not joined. Endpoints reachable. Ready for enrollment.'
        Add-Check -Category 'JoinPath' -Check 'Recommended' -Status 'Warning' -Value $recommendedPath -Detail $pathDetail
        $null = $pathActions.Add(@{Desc='AAD Join (Settings)';Cmd='Start-Process "ms-settings:workplace"; Write-Host "Go to Connect > Join this device to Azure AD"'})
        $null = $pathActions.Add(@{Desc='AAD Join (CLI)';Cmd='dsregcmd /join /debug'})
        $null = $pathActions.Add(@{Desc='Bulk enrollment (PPKG)';Cmd='Write-Host "Create in Windows Configuration Designer: Enroll in Azure AD > Get Bulk Token"'})
    } else {
        $recommendedPath = 'BLOCKED: No connectivity'
        $pathDetail = 'Cannot reach login.microsoftonline.com. Fix network.'
        Add-Check -Category 'JoinPath' -Check 'Recommended' -Status 'Fail' -Value $recommendedPath -Detail $pathDetail
    }
    $null = $pipelineSteps.Add(@{Label='Not Joined';Status='current'})
    $null = $pipelineSteps.Add(@{Label='AAD Join';Status='pending'})
    $null = $pipelineSteps.Add(@{Label='MDM Enroll';Status='pending'})
    $null = $pipelineSteps.Add(@{Label='Compliance';Status='pending'})
}

if ($pathActions.Count -gt 0) {
    Add-Finding -Severity 'Info' -Title "Path: $recommendedPath" -Detail $pathDetail `
        -Action 'Follow enrollment path.' -FixCommands @($pathActions) -FixMinutes 10
}

Save-SectionScore -Section 'JoinPath' -Category 'JoinPath'

# ============================================================
# [10/14] ENROLLMENT BLOCKERS
# ============================================================
Write-Host ''
Write-Host '[10/14] Enrollment Blockers' -ForegroundColor White

# Proxy
try {
    $prReg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $prOn = ($prReg -and $prReg.ProxyEnable -eq 1)
    Add-Check -Category 'Blockers' -Check 'Proxy' -Status $(if(-not $prOn){'Pass'}else{'Warning'}) `
        -Value $(if($prOn){"On: $($prReg.ProxyServer)"}else{'Direct'}) -Detail 'Proxy can block enrollment'
    if ($prOn) { Add-Finding -Severity 'Warning' -Title "Proxy: $($prReg.ProxyServer)" -Detail 'Whitelist *.microsoft.com, *.microsoftonline.com' -Action 'Verify exclusions.' -FixCommands @(@{Desc='Show proxy';Cmd='netsh winhttp show proxy'}) }
} catch {}

# Pending reboot
try {
    $rbPend = $false
    @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') |
        ForEach-Object { if (Test-Path $_) { $rbPend = $true } }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($pfro.PendingFileRenameOperations) { $rbPend = $true }

    Add-Check -Category 'Blockers' -Check 'Pending Reboot' -Status $(if(-not $rbPend){'Pass'}else{'Warning'}) `
        -Value $(if($rbPend){'REBOOT REQUIRED'}else{'Clean'}) -Detail 'Reboot can block enrollment'
    if ($rbPend) {
        Add-Finding -Severity 'Warning' -Title 'Reboot pending' -Detail 'Complete reboot before enrolling.' `
            -Action 'Reboot.' -FixCommands @(@{Desc='Reboot in 60s';Cmd='shutdown /r /t 60 /c "FieldOps: Reboot for enrollment"; Write-Host "Rebooting in 60s. Cancel: shutdown /a"'}) -FixMinutes 5
    }
} catch {}

# Existing MDM
try {
    $exMdm = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -ErrorAction SilentlyContinue | Where-Object {$_.ProviderID -and $_.ProviderID -ne ''}
    if ($exMdm) {
        $provs = ($exMdm | ForEach-Object {$_.ProviderID}) -join ', '
        Add-Check -Category 'Blockers' -Check 'Existing MDM' -Status 'Info' -Value "Enrolled: $provs" -Detail 'Double enrollment may fail'
    } else { Add-Check -Category 'Blockers' -Check 'Existing MDM' -Status 'Pass' -Value 'Clean' -Detail 'No existing enrollment' }
} catch {}

# Stale device
$staleInfo = if ($deviceId -ne 'Not registered') {'Device ID exists - verify not stale in Entra portal'} else {'Clean state'}
Add-Check -Category 'Blockers' -Check 'Stale Device' -Status 'Info' -Value $staleInfo -Detail 'Error 0x801c03ed = stale device'

Save-SectionScore -Section 'Blockers' -Category 'Blockers'

# ============================================================
# [11/14] USER & LICENSE
# ============================================================
Write-Host ''
Write-Host '[11/14] User & License' -ForegroundColor White

Add-Check -Category 'User' -Check 'Current User' -Status 'Info' -Value $UserName -Detail "SID: $([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
Add-Check -Category 'User' -Check 'Admin Rights' -Status $(if($script:IsAdmin){'Pass'}else{'Warning'}) `
    -Value $(if($script:IsAdmin){'Yes'}else{'No - enrollment limited'}) -Detail 'AAD Join needs admin'

try {
    $aadUCache = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache' -Recurse -ErrorAction SilentlyContinue |
        Get-ItemProperty -ErrorAction SilentlyContinue | Where-Object {$_.UserName -and $_.UserName -match '@'})
    if ($aadUCache.Count -gt 0) {
        $uList = ($aadUCache | Select-Object -ExpandProperty UserName -Unique | Select-Object -First 3) -join ', '
        Add-Check -Category 'User' -Check 'AAD User Cache' -Status 'Pass' -Value "$($aadUCache.Count) user(s)" -Detail $uList
    } else { Add-Check -Category 'User' -Check 'AAD User Cache' -Status 'Info' -Value 'No cached users' -Detail 'Will auth during enrollment' }
} catch {}

# Tenant hint display
if ($TenantHint) { Add-Check -Category 'User' -Check 'Tenant Hint' -Status 'Info' -Value $TenantHint -Detail 'From parameter or config' }

Save-SectionScore -Section 'User' -Category 'User'

# ============================================================
# [12/14] ERROR HISTORY (expanded DB)
# ============================================================
Write-Host ''
Write-Host '[12/14] Enrollment Error History' -ForegroundColor White

$script:ErrorHistory = [System.Collections.ArrayList]::new()
try {
    $eEvents = @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin';Level=@(1,2,3);StartTime=(Get-Date).AddDays(-7)} -MaxEvents 20 -ErrorAction SilentlyContinue)
    if ($eEvents.Count -gt 0) {
        $eGroups = $eEvents | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5
        foreach ($eg in $eGroups) {
            $sample = $eg.Group[0]; $msg = $sample.Message
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0,117) + '...' }
            $errCode = ''; if ($sample.Message -match '(0x[0-9a-fA-F]{8})') { $errCode = $Matches[1].ToLower() }
            $null = $script:ErrorHistory.Add([PSCustomObject]@{EventId=$sample.Id;Count=$eg.Count;Message=$msg;ErrorCode=$errCode;Time=$sample.TimeCreated.ToString('yyyy-MM-dd HH:mm')})
            $st = switch ($sample.Level) {1{'Fail'}2{'Fail'}3{'Warning'}default{'Info'}}
            Add-Check -Category 'Errors' -Check "Event $($sample.Id) (x$($eg.Count))" -Status $st -Value $msg -Detail "$(if($errCode){"Error: $errCode | "})Last: $($sample.TimeCreated.ToString('MM-dd HH:mm'))"
            if ($errCode -and $script:ErrorDB.ContainsKey($errCode)) {
                $ei = $script:ErrorDB[$errCode]
                Add-Finding -Severity 'Warning' -Title "$errCode - $($ei.Desc)" -Detail "x$($eg.Count). $($ei.Fix)" -Action $ei.Fix -ErrorCode $errCode `
                    -FixCommands @(@{Desc="Lookup $errCode";Cmd="Write-Host 'Error: $errCode'; Write-Host '$($ei.Desc)'; Write-Host 'Fix: $($ei.Fix)'"})
            }
        }
    } else { Add-Check -Category 'Errors' -Check 'Enrollment Errors (7d)' -Status 'Pass' -Value 'None' -Detail 'Clean' }
} catch { Add-Check -Category 'Errors' -Check 'Error History' -Status 'Info' -Value 'Cannot query' -Detail $_.Exception.Message }

Save-SectionScore -Section 'Errors' -Category 'Errors'

# ============================================================
# [13/14] READINESS SCORE
# ============================================================
Write-Host ''
Write-Host '[13/14] Enrollment Readiness' -ForegroundColor White

$readinessPct = if ($script:ReadinessMax -gt 0){[math]::Round(($script:ReadinessScore/$script:ReadinessMax)*100,0)}else{0}
$readinessLabel = if ($readinessPct -ge 90){'READY'} elseif ($readinessPct -ge 70){'READY WITH WARNINGS'} elseif ($readinessPct -ge 50){'PARTIALLY READY'} else {'NOT READY'}
$readinessColor = if ($readinessPct -ge 90){'#4caf50'} elseif ($readinessPct -ge 70){'#ff9800'} else {'#f44336'}

Add-Check -Category 'Readiness' -Check 'Enrollment Readiness' -Status $(if($readinessPct -ge 80){'Pass'}elseif($readinessPct -ge 50){'Warning'}else{'Fail'}) `
    -Value "$readinessPct% - $readinessLabel" -Detail "Score: $([math]::Round($script:ReadinessScore,1))/$($script:ReadinessMax)"

# ============================================================
# [14/14] ENROLLMENT ACTIONS
# ============================================================
Write-Host ''
Write-Host '[14/14] Enrollment Actions' -ForegroundColor White

$alreadyJoined = ($script:DsReg['AzureAdJoined'] -eq 'YES')

if (-not $alreadyJoined) {
    $tenantParam = if ($TenantHint) {" for $TenantHint"} else {''}
    Add-Finding -Severity 'Info' -Title "Azure AD Join$tenantParam" `
        -Detail "Readiness: $readinessPct%. $critFail critical blocked." `
        -Action 'Choose enrollment method.' -FixCommands @(
            @{Desc='AAD Join via Settings';Cmd='Start-Process "ms-settings:workplace"; Write-Host "Connect > Join this device to Azure AD"'}
            @{Desc='AAD Join via CLI';Cmd="if (`$script:IsAdmin) { dsregcmd /join$(if($TenantHint){" /tenanthint:$TenantHint"}) /debug } else { Write-Host 'Need admin' -ForegroundColor Red }"}
            @{Desc='Trigger MDM auto-enroll';Cmd='gpupdate /force /target:computer; Write-Host "GPO updated"'}
            @{Desc='Company Portal';Cmd='Start-Process "companyportal:" -EA SilentlyContinue; if (-not $?) { Start-Process "ms-windows-store://pdp/?ProductId=9WZDNCRFJ3PZ" }'}
            @{Desc='Full diagnostic dump';Cmd="dsregcmd /status > '$ReportsPath\dsreg_${Hostname}_${Timestamp}.txt'; mdmdiagnosticstool -out '$ReportsPath\MDMDiag_${Hostname}' -area DeviceEnrollment 2>`$null; Write-Host 'Saved to $ReportsPath'"}
        ) -FixMinutes 15
} else {
    Add-Finding -Severity 'Info' -Title 'Already Azure AD Joined' `
        -Detail "Tenant: $tenantName. Device: $deviceId." -Action 'Maintenance options.' `
        -FixCommands @(
            @{Desc='Force MDM sync';Cmd='Start-Process "ms-settings:workplace"; Write-Host "Click Info > Sync"'}
            @{Desc='Export diagnostics';Cmd="dsregcmd /status > '$ReportsPath\dsreg_${Hostname}_${Timestamp}.txt'; Write-Host 'Saved'"}
            @{Desc='Re-register (fix SSO)';Cmd='dsregcmd /leave; Start-Sleep 5; dsregcmd /join /debug'}
            @{Desc='Disconnect + re-enroll';Cmd='Write-Host "Settings > Accounts > Access work or school > Disconnect, then re-add" -ForegroundColor Yellow'}
        ) -FixMinutes 10
}

# ============================================================
# SCORING
# ============================================================
$script:Stopwatch.Stop()
$ElapsedSec = [math]::Round($script:Stopwatch.Elapsed.TotalSeconds, 1)

$scoredChecks = @($script:Results | Where-Object {$_.Status -in @('Pass','Warning','Fail')})
$passCount = @($scoredChecks|Where-Object{$_.Status -eq 'Pass'}).Count
$warnCount = @($scoredChecks|Where-Object{$_.Status -eq 'Warning'}).Count
$failCount = @($scoredChecks|Where-Object{$_.Status -eq 'Fail'}).Count
$infoCount = @($script:Results|Where-Object{$_.Status -eq 'Info'}).Count
$totalScored = $scoredChecks.Count
$scorePct = if($totalScored -gt 0){[math]::Round((($passCount+($warnCount*0.5))/$totalScored)*100,0)}else{0}
$grade = if($scorePct -ge 95){'A+'}elseif($scorePct -ge 90){'A'}elseif($scorePct -ge 85){'A-'}elseif($scorePct -ge 80){'B+'}elseif($scorePct -ge 75){'B'}elseif($scorePct -ge 70){'C+'}elseif($scorePct -ge 65){'C'}elseif($scorePct -ge 60){'D'}else{'F'}
$gradeColor = if($scorePct -ge 80){'#4caf50'}elseif($scorePct -ge 60){'#ff9800'}else{'#f44336'}

$ExecSummary = "Readiness: $readinessPct% ($readinessLabel). State: $(if($alreadyJoined){'AAD Joined'}elseif($workplaceJoined){'Workplace Joined'}else{'Not joined'}). " +
    "Endpoints: $passEndpoints/$totalEndpoints ($critFail crit blocked). CA factors: $caReady/$caTotal. " +
    "$($script:CheckCount) checks in ${ElapsedSec}s. Path: $recommendedPath"

Write-Host ''
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host '  ENROLLMENT ASSESSMENT COMPLETE' -ForegroundColor DarkCyan
Write-Host "  Grade: $grade ($scorePct%) | Readiness: $readinessPct% ($readinessLabel)" -ForegroundColor $(if($scorePct -ge 80){'Green'}elseif($scorePct -ge 60){'Yellow'}else{'Red'})
Write-Host "  $($script:CheckCount) checks in ${ElapsedSec}s | CA: $caReady/$caTotal factors" -ForegroundColor Gray
Write-Host "  Pass: $passCount | Warn: $warnCount | Fail: $failCount | Info: $infoCount" -ForegroundColor Gray
Write-Host "  Endpoints: $passEndpoints/$totalEndpoints | Critical blocked: $critFail" -ForegroundColor $(if($critFail -eq 0){'Green'}else{'Red'})
Write-Host '============================================================' -ForegroundColor DarkCyan

# ============================================================
# POST-FLIGHT: After Snapshot
# ============================================================
if ($Snapshot) {
    Write-Host ''
    Write-Host '[Post-Flight] Run enrollment actions, then re-run with -Snapshot to capture After state.' -ForegroundColor Yellow
    Write-Host "  Before snapshot: $SnapshotDir" -ForegroundColor Gray

    # Check if a before snapshot exists for comparison
    $beforeFiles = @(Get-ChildItem $SnapshotDir -Filter "Before_${Hostname}_*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($beforeFiles.Count -ge 2) {
        Write-Host '  Multiple snapshots found. Comparing latest two...' -ForegroundColor Cyan
        $snap1 = Get-Content $beforeFiles[1].FullName -Raw | ConvertFrom-Json
        $snap2 = Get-Content $beforeFiles[0].FullName -Raw | ConvertFrom-Json
        $changes = @()
        if ($snap1.AzureAdJoined -ne $snap2.AzureAdJoined) { $changes += "AAD Joined: $($snap1.AzureAdJoined) -> $($snap2.AzureAdJoined)" }
        if ($snap1.MdmEnrolled -ne $snap2.MdmEnrolled) { $changes += "MDM: $($snap1.MdmEnrolled) -> $($snap2.MdmEnrolled)" }
        if ($snap1.WorkplaceJoined -ne $snap2.WorkplaceJoined) { $changes += "WPJ: $($snap1.WorkplaceJoined) -> $($snap2.WorkplaceJoined)" }
        if ($snap1.DeviceId -ne $snap2.DeviceId) { $changes += "DeviceID: $($snap1.DeviceId) -> $($snap2.DeviceId)" }
        if ($changes.Count -gt 0) {
            Write-Host '  Changes detected:' -ForegroundColor Green
            $changes | ForEach-Object { Write-Host "    $_" -ForegroundColor White }
        } else { Write-Host '  No state changes detected between snapshots.' -ForegroundColor Gray }
    }
}

# ============================================================
# ENROLLMENT MONITOR
# ============================================================
if ($Monitor -and -not $alreadyJoined) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  ENROLLMENT MONITOR - Watching for state changes...' -ForegroundColor Yellow
    Write-Host '  Press Ctrl+C to stop monitoring.' -ForegroundColor Gray
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host ''

    $prevState = $joinState
    $monitorCount = 0
    while ($true) {
        $monitorCount++
        Start-Sleep 10
        try {
            $monDs = dsregcmd /status 2>$null | Out-String
            $monAAD = ($monDs -match 'AzureAdJoined\s*:\s*YES')
            $monDom = ($monDs -match 'DomainJoined\s*:\s*YES')
            $monWPJ = ($monDs -match 'WorkplaceJoined\s*:\s*YES')
            $monMDM = ($monDs -match 'MdmUrl\s*:\s*https')
            $curState = if ($monAAD -and $monDom) {'Hybrid'} elseif ($monAAD) {'AAD Joined'} elseif ($monWPJ) {'WPJ'} else {'Not joined'}
            $mdmStr = if ($monMDM) {'MDM: Yes'} else {'MDM: No'}
            $ts = Get-Date -Format 'HH:mm:ss'

            if ($curState -ne $prevState) {
                Write-Host "  [$ts] STATE CHANGE: $prevState -> $curState | $mdmStr" -ForegroundColor Green
                $prevState = $curState
                if ($monAAD) {
                    Write-Host "  [$ts] Azure AD Join DETECTED! Enrollment successful." -ForegroundColor Green
                    if (-not $monMDM) { Write-Host "  [$ts] Waiting for MDM enrollment..." -ForegroundColor Yellow }
                    else { Write-Host "  [$ts] MDM enrollment confirmed. Monitor complete." -ForegroundColor Green; break }
                }
            } else {
                Write-Host "  [$ts] ($monitorCount) State: $curState | $mdmStr" -ForegroundColor Gray
            }
        } catch { Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Monitor error: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# ============================================================
# INTERACTIVE MENU
# ============================================================
$actionableFindings = @($script:Findings | Where-Object {$_.FixCommands -and $_.FixCommands.Count -gt 0} |
    Sort-Object @{Expression={switch($_.Severity){'Critical'{0}'Warning'{1}default{2}}}}, FixMinutes)

if ($actionableFindings.Count -gt 0) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '  ENROLLMENT & REMEDIATION MENU' -ForegroundColor DarkCyan
    Write-Host "  $($actionableFindings.Count) action(s) | Priority sorted" -ForegroundColor Gray
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''

    $fixIndex = 0
    foreach ($af in $actionableFindings) {
        $fixIndex++
        $sevColor = switch ($af.Severity) {'Critical'{'Red'}'Warning'{'Yellow'}default{'Cyan'}}
        $tags = "$(if($af.FixMinutes -le 2){' [QUICK]'})$(if($af.ErrorCode){" [$($af.ErrorCode)]"})"
        Write-Host "  [$fixIndex] $($af.Severity.ToUpper()): $($af.Title)$tags" -ForegroundColor $sevColor
        Write-Host "      $($af.Detail)" -ForegroundColor Gray
        $ci = 0; foreach ($fc in $af.FixCommands) { $ci++; Write-Host "      ${fixIndex}.${ci} - $($fc.Desc)" -ForegroundColor DarkCyan }
        Write-Host ''
    }
    Write-Host '  fix# (e.g. 1.1) | ALL (script) | SKIP' -ForegroundColor Gray; Write-Host ''

    $keepAsking = $true
    while ($keepAsking) {
        $choice = Read-Host '  Enter choice'
        $ct = $choice.Trim().ToUpper()
        if ($ct -eq 'SKIP' -or $ct -eq '') { $keepAsking = $false }
        elseif ($ct -eq 'ALL') {
            $rp = Join-Path $ReportsPath "Enrollment_${Hostname}_${Timestamp}.ps1"
            $lns = [System.Collections.ArrayList]::new()
            $null = $lns.Add("# FieldOps Pro - Enrollment Script | $DateHuman | $Hostname")
            $null = $lns.Add("# Readiness: $readinessPct% | Path: $recommendedPath")
            $null = $lns.Add("#Requires -RunAsAdministrator`n")
            $fi = 0; foreach ($af in $actionableFindings) { $fi++
                $null = $lns.Add("# === [$fi] $($af.Severity.ToUpper()): $($af.Title) ===")
                foreach ($fc in $af.FixCommands) { $null = $lns.Add("`n# $($fc.Desc)"); $null = $lns.Add($fc.Cmd) }; $null = $lns.Add("") }
            ($lns -join "`r`n") | Out-File $rp -Encoding UTF8 -Force
            Write-Host "  Script: $rp" -ForegroundColor Green; $keepAsking = $false
        }
        elseif ($ct -match '^(\d+)\.(\d+)$') {
            $fN=[int]$Matches[1]; $cN=[int]$Matches[2]
            if ($fN -ge 1 -and $fN -le $actionableFindings.Count) {
                $tf=$actionableFindings[$fN-1]
                if ($cN -ge 1 -and $cN -le $tf.FixCommands.Count) {
                    $tc=$tf.FixCommands[$cN-1]; Write-Host "  Running: $($tc.Desc)" -ForegroundColor Yellow
                    $cf=Read-Host '  Execute? (Y/N)'
                    if($cf.Trim().ToUpper() -eq 'Y'){try{Invoke-Expression $tc.Cmd;Write-Host '  Done.' -ForegroundColor Green}catch{Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red}}; Write-Host ''
                } else {Write-Host '  Invalid cmd#' -ForegroundColor Red}
            } else {Write-Host '  Invalid action#' -ForegroundColor Red}
        } else {Write-Host '  Use: 1.1, ALL, or SKIP' -ForegroundColor Red}
    }
}

# ============================================================
# HTML REPORT
# ============================================================
Write-Host ''; Write-Host 'Generating report...' -ForegroundColor Gray
$ReportFile = Join-Path $ReportsPath "AzureADJoin_${Hostname}_${Timestamp}.html"

# Pipeline SVG
$pipeSvg = ''; $px = 30
foreach ($ps in $pipelineSteps) {
    $pCol = switch ($ps.Status) {'done'{'#1b5e20'}'current'{'#e65100'}'action'{'#f57f17'}'pending'{'#263238'}default{'#263238'}}
    $pStroke = switch ($ps.Status) {'done'{'#4caf50'}'current'{'#ff9800'}'action'{'#ffc107'}'pending'{'#546e7a'}default{'#546e7a'}}
    $pIcon = switch ($ps.Status) {'done'{'&#10003;'}'current'{'&#9654;'}'action'{'&#9888;'}'pending'{'&#8943;'}default{'&#8943;'}}
    $pipeSvg += "<rect x='$px' y='10' width='130' height='50' rx='10' fill='$pCol' stroke='$pStroke' stroke-width='2'/>"
    $pipeSvg += "<text x='$($px+65)' y='30' text-anchor='middle' fill='#e0e0e0' font-size='10' font-weight='700'>$($ps.Label)</text>"
    $pipeSvg += "<text x='$($px+65)' y='48' text-anchor='middle' fill='$pStroke' font-size='16'>$pIcon</text>"
    $px += 130
    if ($ps -ne $pipelineSteps[-1]) { $pipeSvg += "<line x1='$px' y1='35' x2='$($px+25)' y2='35' stroke='#546e7a' stroke-width='2' stroke-dasharray='5,3'/>"; $px += 35 }
}
$pipeWidth = $px + 30
$pipeHtml = "<svg viewBox='0 0 $pipeWidth 70' xmlns='http://www.w3.org/2000/svg' style='width:100%;max-width:${pipeWidth}px;height:70px'>$pipeSvg</svg>"

# Section bars
$catBars = ''
foreach ($cs in $script:SectionScores) {
    $bc = if($cs.Score -ge 80){'#4caf50'}elseif($cs.Score -ge 60){'#ff9800'}else{'#f44336'}
    $catBars += "<div class='cb-row'><div class='cb-label'>$($cs.Section)</div><div class='cb-track'><div class='cb-fill' style='width:$($cs.Score)%;background:$bc'></div></div><div class='cb-val' style='color:$bc'>$($cs.Score)%</div></div>"
}

# Endpoint grid
$epGrid = ''
$epBySvc = $script:EndpointData | Group-Object Service
foreach ($svc in $epBySvc) {
    $epGrid += "<div class='ep-group'><div class='ep-title'>$($svc.Name)</div>"
    foreach ($ep in $svc.Group) {
        $ec = if($ep.Ok){'#4caf50'}else{'#f44336'}; $ei = if($ep.Ok){'&#10003;'}else{'&#10007;'}
        $ct2 = if($ep.Critical){'<span class="crit">*</span>'}else{''}
        $epGrid += "<div class='ep-chip' style='border-color:$ec'><span style='color:$ec'>$ei</span> $($ep.Name)$ct2<div class='ep-host'>$($ep.Host):$($ep.Port)</div></div>"
    }
    $epGrid += '</div>'
}

# Findings
$fHtml = ''; $fi2 = 0
if ($script:Findings.Count -gt 0) {
    foreach ($f in $script:Findings) {
        $fi2++; $svc2=switch($f.Severity){'Critical'{'finding-critical'}'Warning'{'finding-warning'}default{'finding-info'}}
        $svi2=switch($f.Severity){'Critical'{'&#10007;'}'Warning'{'&#9888;'}default{'&#8505;'}}
        $errTag=if($f.ErrorCode){"<span class='err-tag'>$($f.ErrorCode)</span>"}else{''}
        $fxB=''; if($f.FixCommands -and $f.FixCommands.Count -gt 0){
            $ci2='';$cx=0; foreach($fc in $f.FixCommands){$cx++;$cid="fix-${fi2}-${cx}"
                $esc=$fc.Cmd -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
                $ci2+="<div class='fix-item'><div class='fix-desc'>$($fc.Desc)</div><div class='fix-cmd-wrap'><pre class='fix-cmd' id='$cid'>$esc</pre><button class='copy-btn' onclick=`"copyCmd('$cid')`">Copy</button></div></div>"}
            $fxB="<div class='fix-block'><div class='fix-header' onclick='toggleFix(this)'><span class='fix-arrow'>&#9654;</span> $($f.FixCommands.Count) Action(s)$(if($f.FixMinutes -le 2){" <span style='color:#4caf50'>[QUICK]</span>"})</div><div class='fix-body' style='display:none'>$ci2</div></div>"
        }
        $fHtml+="<div class='finding-card $svc2'><div class='finding-title'>$svi2 $($f.Severity.ToUpper()): $($f.Title) $errTag</div><div class='finding-detail'>$($f.Detail)</div><div class='finding-action'><strong>Action:</strong> $($f.Action)</div>$fxB</div>"
    }
} else { $fHtml='<div class="finding-card finding-info"><div class="finding-title">&#10003; No issues</div></div>' }

# Check rows
$crHtml = foreach($r in $script:Results){
    $sc=switch($r.Status){'Pass'{'status-pass'}'Warning'{'status-warn'}'Fail'{'status-fail'}default{'status-info'}}
    $si=switch($r.Status){'Pass'{'&#10003;'}'Warning'{'&#9888;'}'Fail'{'&#10007;'}default{'&#8505;'}}
    "<tr><td>$($r.Number)</td><td>$($r.Category)</td><td>$($r.Check)</td><td class='$sc'>$si $($r.Status)</td><td>$($r.Value)</td><td class='detail-cell'>$($r.Detail)</td></tr>"
}

$HtmlContent = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>FieldOps Pro - Azure AD | $Hostname</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',Tahoma,sans-serif;background:#080c1a;color:#d8dce6;padding:24px;line-height:1.5}.rc{max-width:1200px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#0a1830,#142848);border-radius:14px;padding:28px 32px;margin-bottom:24px;border:1px solid #1a3868}.hdr-title{font-size:1.6em;font-weight:800;color:#40a0ff}.hdr-sub{font-size:0.88em;color:#6888b0;margin-top:2px}.hdr-bar{display:flex;flex-wrap:wrap;gap:20px;margin-top:16px;padding-top:14px;border-top:1px solid #1a3868}.hdr-item{font-size:0.8em}.hdr-lbl{color:#4870a0}.hdr-val{color:#a0c8f0;font-weight:600}
.grade{background:linear-gradient(135deg,#0a1020,#101830);border-radius:14px;padding:24px 32px;margin-bottom:24px;border:1px solid #1a2848;display:flex;align-items:center;gap:32px}.grade-circle{width:92px;height:92px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:2.1em;font-weight:900;flex-shrink:0;border:5px solid}.grade-det{flex:1}.grade-score{font-size:1.1em;font-weight:700}.grade-track{width:100%;height:14px;background:#101428;border-radius:7px;overflow:hidden;margin:8px 0}.grade-fill{height:100%;border-radius:7px}.grade-stats{display:flex;gap:20px;font-size:0.82em;margin-top:4px}.st-p{color:#4caf50}.st-w{color:#ff9800}.st-f{color:#f44336}.st-i{color:#64b5f6}
.rb{display:inline-block;padding:4px 14px;border-radius:20px;font-weight:800;font-size:0.85em;margin-left:12px;letter-spacing:0.5px}
.exec{background:#080c20;border:1px solid #1a2040;border-radius:12px;padding:18px 24px;margin-bottom:24px;font-size:0.9em;color:#8098c0;line-height:1.65}.exec-title{font-weight:700;color:#40a0ff;margin-bottom:6px}
.stitle{font-size:1.05em;font-weight:700;color:#40a0ff;margin:24px 0 12px;padding-bottom:6px;border-bottom:1px solid #1a2848;display:flex;align-items:center;gap:8px}.stitle .badge{background:#1a2848;color:#6888b0;font-size:0.68em;padding:2px 7px;border-radius:10px}
.pipe-wrap{overflow-x:auto;margin-bottom:20px;padding:8px 0}
.cb-row{display:flex;align-items:center;gap:10px;margin-bottom:6px}.cb-label{width:100px;font-size:0.78em;color:#8098c0;font-weight:600;flex-shrink:0}.cb-track{flex:1;height:14px;background:#101428;border-radius:4px;overflow:hidden}.cb-fill{height:100%;border-radius:4px}.cb-val{width:45px;font-size:0.78em;font-weight:700;text-align:right}
.ep-group{margin-bottom:16px}.ep-title{font-size:0.82em;font-weight:700;color:#6888b0;margin-bottom:8px;text-transform:uppercase;letter-spacing:0.5px}
.ep-chip{background:#0a1020;border:1px solid;border-radius:8px;padding:8px 12px;font-size:0.78em;font-weight:600;min-width:180px;display:inline-block;margin:0 8px 8px 0}.ep-host{font-size:0.7em;color:#4870a0;font-weight:400;margin-top:2px}.crit{color:#f44336;font-weight:800}
.finding-card{border-radius:10px;padding:12px 16px;margin-bottom:10px;border-left:5px solid}.finding-critical{background:#1a0808;border-color:#f44336}.finding-warning{background:#1a1408;border-color:#ff9800}.finding-info{background:#08101a;border-color:#40a0ff}.finding-title{font-weight:700;margin-bottom:3px;font-size:0.92em}.finding-detail{font-size:0.82em;color:#7088a8}.finding-action{font-size:0.8em;color:#8098b0;margin-top:4px}
.err-tag{background:#1a2040;color:#ff7043;padding:1px 6px;border-radius:4px;font-size:0.72em;font-weight:600;font-family:monospace;margin-left:6px}
.fix-block{margin-top:8px;border:1px solid #1a2848;border-radius:8px;overflow:hidden}.fix-header{background:#0c1428;padding:8px 12px;cursor:pointer;font-size:0.82em;font-weight:600;color:#40a0ff;display:flex;align-items:center;gap:6px;user-select:none}.fix-header:hover{background:#101830}.fix-arrow{font-size:0.65em;transition:transform 0.2s;display:inline-block}.fix-arrow.open{transform:rotate(90deg)}.fix-body{padding:10px 12px;background:#060a18}.fix-item{margin-bottom:10px}.fix-desc{font-size:0.78em;color:#7090b8;font-weight:600;margin-bottom:3px}.fix-cmd-wrap{position:relative}.fix-cmd{background:#040810;border:1px solid #1a2040;border-radius:6px;padding:8px 10px;font-family:'Cascadia Code','Consolas',monospace;font-size:0.75em;color:#a8d0a8;white-space:pre-wrap;word-break:break-all;margin:0}.copy-btn{position:absolute;top:4px;right:4px;background:#1a2848;color:#40a0ff;border:1px solid #2a3868;border-radius:4px;padding:2px 8px;font-size:0.68em;cursor:pointer}.copy-btn:hover{background:#2a3868}
table{width:100%;border-collapse:collapse;margin-bottom:14px;font-size:0.78em}th{background:#0a1020;color:#40a0ff;padding:8px 10px;text-align:left;font-weight:600;border-bottom:2px solid #1a2848;position:sticky;top:0}td{padding:7px 10px;border-bottom:1px solid #101828;vertical-align:top}tr:hover{background:#0c1428}.detail-cell{max-width:300px;word-break:break-all;color:#5878a0;font-size:0.88em}.status-pass{color:#4caf50;font-weight:600}.status-warn{color:#ff9800;font-weight:600}.status-fail{color:#f44336;font-weight:600}.status-info{color:#64b5f6;font-weight:600}
details{background:#080c20;border:1px solid #1a2040;border-radius:10px;margin-bottom:16px;overflow:hidden}summary{cursor:pointer;padding:12px 18px;font-weight:600;color:#7090b8;font-size:0.92em;user-select:none;list-style:none;display:flex;align-items:center;gap:6px}summary:hover{background:#0c1428}summary::-webkit-details-marker{display:none}summary::before{content:'\\25B6';font-size:0.65em;transition:transform 0.2s;display:inline-block;color:#4870a0}details[open] summary::before{transform:rotate(90deg)}details .sect-body{padding:14px 18px;overflow-x:auto}
.ftr{text-align:center;padding:18px;color:#2a3850;font-size:0.75em;border-top:1px solid #101828;margin-top:24px}
@media print{body{background:#fff!important;color:#222!important;padding:8px}.hdr,.grade,.exec,details,.finding-card,.ep-chip{background:#f8f8fc!important;border-color:#ddd!important;color:#222!important;-webkit-print-color-adjust:exact;print-color-adjust:exact}.copy-btn{display:none!important}th{background:#e8f0f8!important;color:#1a3868!important}td{border-color:#ddd!important;color:#333!important}.status-pass{color:#1b7a1b!important}.status-warn{color:#b36b00!important}.status-fail{color:#c62828!important}.status-info{color:#1565c0!important}}
</style></head><body><div class="rc">
<div class="hdr"><div class="hdr-title">FieldOps Pro -- Azure AD Enrollment Report</div><div class="hdr-sub">14-section enrollment intelligence with CA pre-check, Autopilot, WiFi management &amp; real-time monitor</div><div class="hdr-bar"><div class="hdr-item"><span class="hdr-lbl">Host</span> <span class="hdr-val">$Hostname</span></div><div class="hdr-item"><span class="hdr-lbl">User</span> <span class="hdr-val">$UserName</span></div><div class="hdr-item"><span class="hdr-lbl">Date</span> <span class="hdr-val">$DateHuman</span></div><div class="hdr-item"><span class="hdr-lbl">Checks</span> <span class="hdr-val">$($script:CheckCount)</span></div><div class="hdr-item"><span class="hdr-lbl">Duration</span> <span class="hdr-val">${ElapsedSec}s</span></div><div class="hdr-item"><span class="hdr-lbl">Engine</span> <span class="hdr-val">v2.0</span></div>$(if($TenantHint){"<div class='hdr-item'><span class='hdr-lbl'>Tenant</span> <span class='hdr-val'>$TenantHint</span></div>"})</div></div>
<div class="grade"><div class="grade-circle" style="background:${gradeColor}18;border-color:$gradeColor;color:$gradeColor">$grade</div><div class="grade-det"><div class="grade-score">Enrollment: $scorePct% <span class="rb" style="background:${readinessColor}22;color:$readinessColor;border:1px solid $readinessColor">$readinessLabel</span></div><div class="grade-track"><div class="grade-fill" style="width:${scorePct}%;background:linear-gradient(90deg,$gradeColor,${gradeColor}66)"></div></div><div class="grade-stats"><span class="st-p">$passCount Pass</span><span class="st-w">$warnCount Warn</span><span class="st-f">$failCount Fail</span><span class="st-i">$infoCount Info</span><span style="color:#40a0ff;font-weight:700">EP: $passEndpoints/$totalEndpoints</span><span style="color:#ff9800;font-weight:700">CA: $caReady/$caTotal</span></div></div></div>
<div class="exec"><div class="exec-title">Executive Summary</div>$ExecSummary</div>
<div class="stitle">Enrollment Pipeline</div><div class="pipe-wrap">$pipeHtml</div>
<div class="stitle">Section Readiness</div>$catBars
<div class="stitle">Findings &amp; Actions <span class="badge">$($script:Findings.Count)</span></div>$fHtml
<div class="stitle">Endpoints <span class="badge">$passEndpoints/$totalEndpoints</span></div>$epGrid
<details open><summary>All Checks ($($script:CheckCount))</summary><div class="sect-body"><table><tr><th>#</th><th>Section</th><th>Check</th><th>Status</th><th>Value</th><th>Detail</th></tr>$($crHtml -join '')</table></div></details>
<div class="ftr">FieldOps Pro -- Azure AD Enrollment Engine v2.0 | $DateHuman | $($script:CheckCount) checks in ${ElapsedSec}s | $Hostname</div>
</div><script>
function copyCmd(id){var el=document.getElementById(id);if(navigator.clipboard)navigator.clipboard.writeText(el.textContent).then(function(){var b=event.target;b.textContent='Copied!';setTimeout(function(){b.textContent='Copy'},2000)})}
function toggleFix(h){var b=h.nextElementSibling,a=h.querySelector('.fix-arrow');if(b.style.display==='none'){b.style.display='block';a.classList.add('open')}else{b.style.display='none';a.classList.remove('open')}}
</script></body></html>
"@

$HtmlContent | Out-File -FilePath $ReportFile -Encoding UTF8 -Force
Write-Host "  Report: $ReportFile" -ForegroundColor Green
Write-Host "  Start-Process `"$ReportFile`"" -ForegroundColor Yellow
Write-Host ''
